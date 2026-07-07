-- lvim-table.fmt: the align engine — column widths, padding, separator rendering, and the
-- minimal buffer rewrite. This is the half that thinks in DISPLAY cells: every width is
-- vim.fn.strdisplaywidth(), never #string, because a CJK character is one byte-string of 3
-- but occupies 2 screen cells and a nerd glyph 3 bytes for 1 cell — the exact reason
-- byte-counting aligners produce sawtooth columns. Byte positions (cursor, set_text) stay in
-- detect.lua; the two never mix units.
--
-- align() is pure (lines in, lines out) so the whole engine is unit-testable headlessly;
-- write() applies the result with minimal churn — only lines that actually changed are written,
-- and the cursor is put back into the same CELL at the same content offset (the cell is the
-- stable identity across a reflow, its byte column is not).
--
---@module "lvim-table.fmt"

local api = vim.api
local detect = require("lvim-table.detect")
local config = require("lvim-table.config")

local M = {}

--- A separator cell must hold at least `:-:`, so no column ever collapses below 3 dashes
--- (also what keeps the output valid GFM regardless of padding).
---@type integer
local MIN_SEP = 3

---@class LvimTableFmtOpts
---@field syntax  "markdown"|"org"
---@field padding integer

--- Per-column content widths in DISPLAY cells: the max strdisplaywidth over the cells rows,
--- floored so the separator fits its markers.
---@param parsed LvimTableParsed
---@param padding integer
---@return integer[]
function M.widths(parsed, padding)
    local widths = {}
    for c = 1, parsed.ncols do
        widths[c] = MIN_SEP - 2 * padding
        if widths[c] < 1 then
            widths[c] = 1
        end
    end
    for _, row in ipairs(parsed.rows) do
        if row.kind == "cells" then
            for c = 1, parsed.ncols do
                local cell = row.cells[c]
                local w = cell and vim.fn.strdisplaywidth(cell.text) or 0
                if w > widths[c] then
                    widths[c] = w
                end
            end
        end
    end
    return widths
end

--- One padded text cell: content placed by alignment, padded with spaces to `width` DISPLAY
--- cells (+ `padding` each side). The pad count is width − strdisplaywidth(text) — display
--- units on both sides of the subtraction.
---@param text string
---@param width integer
---@param align "left"|"center"|"right"|"default"
---@param padding integer
---@return string
local function pad_cell(text, width, align, padding)
    local gap = width - vim.fn.strdisplaywidth(text)
    if gap < 0 then
        gap = 0
    end
    local l, r
    if align == "right" then
        l, r = gap, 0
    elseif align == "center" then
        l = math.floor(gap / 2)
        r = gap - l
    else
        l, r = 0, gap
    end
    return string.rep(" ", padding + l) .. text .. string.rep(" ", r + padding)
end

--- One separator cell filling the WHOLE field (width + 2×padding) with dashes, the alignment
--- markers replacing the first/last dash. Explicit markers are preserved (":--" stays ":--",
--- a plain "---" stays plain), so a realign never invents or drops alignment intent.
---@param width integer
---@param align "left"|"center"|"right"|"default"
---@param padding integer
---@return string
local function sep_cell(width, align, padding)
    local total = width + 2 * padding
    if align == "center" then
        return ":" .. string.rep("-", total - 2) .. ":"
    elseif align == "right" then
        return string.rep("-", total - 1) .. ":"
    elseif align == "left" then
        return ":" .. string.rep("-", total - 1)
    end
    return string.rep("-", total)
end

--- Render the parsed matrix back to aligned lines.
---@param parsed LvimTableParsed
---@param opts LvimTableFmtOpts
---@return string[]
function M.render(parsed, opts)
    local widths = M.widths(parsed, opts.padding)
    local out = {}
    for i, row in ipairs(parsed.rows) do
        local parts = {}
        if row.kind == "sep" then
            for c = 1, parsed.ncols do
                -- Column alignment comes from the FIRST separator row for every separator in
                -- the block, so a stray second separator can't disagree with the header's.
                parts[c] = sep_cell(widths[c], parsed.align[c] or "default", opts.padding)
            end
            -- org junctions are `+`, and an org separator never carries alignment colons.
            local joint = opts.syntax == "org" and "+" or "|"
            out[i] = row.indent .. "|" .. table.concat(parts, joint) .. "|"
        else
            for c = 1, parsed.ncols do
                local cell = row.cells[c]
                parts[c] = pad_cell(cell and cell.text or "", widths[c], parsed.align[c] or "default", opts.padding)
            end
            out[i] = row.indent .. "|" .. table.concat(parts, "|") .. "|"
        end
    end
    return out
end

--- Align a block of lines (pure): parse + render.
---@param lines string[]
---@param opts LvimTableFmtOpts
---@return string[]
function M.align(lines, opts)
    return M.render(detect.parse(lines), opts)
end

--- Write an aligned block back with minimal churn: only lines whose text actually changed are
--- set (one nvim_buf_set_lines per changed line — cheap, and Neovim joins the edits into a
--- single undo step within this call). When the cursor sits inside the block in the current
--- window, it is restored into the SAME cell at the same content offset afterwards.
---@param buf integer
---@param srow integer     1-based first line of the block
---@param old string[]     the block's current lines (what align() was fed)
---@param new string[]     the aligned lines (same count)
---@return boolean changed
function M.write(buf, srow, old, new)
    -- Cursor identity (cell + offset) BEFORE the rewrite, byte columns get stale after it.
    local win, cell_idx, cell_off, cur_row
    if api.nvim_get_current_buf() == buf then
        win = api.nvim_get_current_win()
        local pos = api.nvim_win_get_cursor(win)
        local ri = pos[1] - srow + 1
        if old[ri] then
            cur_row = pos[1]
            cell_idx, cell_off = detect.cursor_cell(old[ri], pos[2])
        end
    end

    local changed = false
    for i = 1, #new do
        if new[i] ~= old[i] then
            api.nvim_buf_set_lines(buf, srow + i - 2, srow + i - 1, false, { new[i] })
            changed = true
        end
    end

    if changed and cur_row and cell_idx then
        local line = new[cur_row - srow + 1]
        local _, cells = detect.split_cells(line)
        local cell = cells[cell_idx] or cells[#cells]
        if cell then
            local col = cell.s + math.min(cell_off, #cell.text)
            pcall(api.nvim_win_set_cursor, win, { cur_row, col })
        end
    end
    return changed
end

--- The effective syntax for a buffer, per its filetype.
---@param buf integer
---@return "markdown"|"org"
function M.syntax_for(buf)
    local ft = vim.bo[buf].filetype
    return config.syntax[ft] or config.default_syntax
end

--- Realign the table block around a line: detect, align, write. The one-call driver used by
--- the mode autocmds, ops and the :LvimTable format subcommand.
---@param buf integer
---@param lnum integer  1-based line inside the (potential) block
---@return boolean found  whether a table block was found at `lnum`
---@return integer? srow, integer? erow  the block bounds when found
function M.realign(buf, lnum)
    local srow, erow = detect.block(buf, lnum)
    if not srow or not erow then
        return false, nil, nil
    end
    local old = api.nvim_buf_get_lines(buf, srow - 1, erow, false)
    local new = M.align(old, { syntax = M.syntax_for(buf), padding = config.padding })
    M.write(buf, srow, old, new)
    return true, srow, erow
end

return M
