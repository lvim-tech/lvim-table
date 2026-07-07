-- lvim-table.ops: row/column operations over the parsed cell matrix — insert/delete row,
-- insert/delete/move column, move row. Every operation mutates the MATRIX and re-renders the
-- whole block through fmt (never regex surgery on individual lines), so alignment, escapes and
-- separator markers can't drift. All ops are dot-repeatable through the native operatorfunc
-- seam: the <Plug> mapping stashes the operation and runs `g@l`, so `.` replays it.
--
---@module "lvim-table.ops"

local api = vim.api
local detect = require("lvim-table.detect")
local fmt = require("lvim-table.fmt")
local config = require("lvim-table.config")

local M = {}

---@class LvimTableOpCtx
---@field buf    integer
---@field win    integer
---@field srow   integer            1-based first block line
---@field erow   integer            1-based last block line
---@field parsed LvimTableParsed
---@field ri     integer            cursor row index into parsed.rows
---@field ci     integer            cursor cell index (1-based)

--- The operation context at the cursor: block bounds + parsed matrix + cursor cell. Notifies
--- and returns nil when the cursor is not inside a table.
---@return LvimTableOpCtx?
local function ctx()
    local buf = api.nvim_get_current_buf()
    local win = api.nvim_get_current_win()
    local pos = api.nvim_win_get_cursor(win)
    local srow, erow = detect.block(buf, pos[1])
    if not srow or not erow then
        vim.notify("lvim-table: no table under the cursor", vim.log.levels.WARN)
        return nil
    end
    local lines = api.nvim_buf_get_lines(buf, srow - 1, erow, false)
    local parsed = detect.parse(lines)
    local ri = pos[1] - srow + 1
    local ci = detect.cursor_cell(lines[ri], pos[2])
    return { buf = buf, win = win, srow = srow, erow = erow, parsed = parsed, ri = ri, ci = ci }
end

--- Render the (mutated) matrix and replace the whole block; then place the cursor into cell
--- (`row_idx`, `col_idx`) of the new block. Row count may have changed, hence the full-range
--- set_lines here (the per-line minimal write is fmt.write's job for pure realigns).
---@param c LvimTableOpCtx
---@param row_idx integer  target cursor row, as an index into the NEW rows
---@param col_idx integer  target cursor cell (1-based)
---@return nil
local function apply(c, row_idx, col_idx)
    local new = fmt.render(c.parsed, { syntax = fmt.syntax_for(c.buf), padding = config.padding })
    api.nvim_buf_set_lines(c.buf, c.srow - 1, c.erow, false, new)
    row_idx = math.max(1, math.min(row_idx, #new))
    local line = new[row_idx]
    local _, cells = detect.split_cells(line)
    local cell = cells[math.min(col_idx, #cells)]
    if cell then
        -- An empty cell's `s` sits right after the pipe; land after the padding instead.
        local col = cell.text == "" and (cell.rs + config.padding) or cell.s
        pcall(api.nvim_win_set_cursor, c.win, { c.srow + row_idx - 1, col })
    end
end

--- An empty cells row matching the matrix (used by row insert).
---@param parsed LvimTableParsed
---@param indent string
---@return LvimTableRow
local function empty_row(parsed, indent)
    local cells = {}
    for i = 1, parsed.ncols do
        cells[i] = { text = "", s = 0, e = 0, rs = 0, re = 0 }
    end
    return { kind = "cells", indent = indent, cells = cells, align = {} }
end

-- ─── dot-repeat ────────────────────────────────────────────────────────────────
-- The native repeat seam: setting 'operatorfunc' and feeding `g@l` makes the whole operation a
-- single change `.` replays — no repeat plugin, no redo-buffer games.

---@type fun()?
local pending = nil

--- The operatorfunc trampoline `g@` calls (public so v:lua can reach it).
---@return nil
function M._opfunc()
    if pending then
        pending()
    end
end

--- Wrap an operation so invoking it goes through g@ (and `.` repeats it).
---@param fn fun()
---@return fun()
local function repeatable(fn)
    return function()
        pending = fn
        vim.go.operatorfunc = "v:lua.require'lvim-table.ops'._opfunc"
        api.nvim_feedkeys("g@l", "n", false)
    end
end

-- ─── operations ────────────────────────────────────────────────────────────────

--- Insert an empty row below (or above) the cursor row.
---@param above boolean?
---@return nil
local function row_insert(above)
    local c = ctx()
    if not c then
        return
    end
    local at = above and c.ri or c.ri + 1
    table.insert(c.parsed.rows, at, empty_row(c.parsed, c.parsed.rows[c.ri].indent))
    apply(c, at, 1)
end

--- Delete the cursor row (the whole block when it is the last line).
---@return nil
local function row_delete()
    local c = ctx()
    if not c then
        return
    end
    if #c.parsed.rows == 1 then
        api.nvim_buf_set_lines(c.buf, c.srow - 1, c.erow, false, {})
        return
    end
    table.remove(c.parsed.rows, c.ri)
    apply(c, math.min(c.ri, #c.parsed.rows), c.ci)
end

--- Insert an empty column after (or before) the cursor column. Separator rows inherit a
--- default (plain) marker for the new column.
---@param before boolean?
---@return nil
local function col_insert(before)
    local c = ctx()
    if not c then
        return
    end
    local at = before and c.ci or c.ci + 1
    for _, row in ipairs(c.parsed.rows) do
        if row.kind == "cells" then
            -- Pad ragged rows first so the insert lands at the same visual column everywhere.
            while #row.cells < c.parsed.ncols do
                row.cells[#row.cells + 1] = { text = "", s = 0, e = 0, rs = 0, re = 0 }
            end
            table.insert(row.cells, at, { text = "", s = 0, e = 0, rs = 0, re = 0 })
        else
            table.insert(row.align, at, "default")
        end
    end
    table.insert(c.parsed.align, at, "default")
    c.parsed.ncols = c.parsed.ncols + 1
    apply(c, c.ri, at)
end

--- Delete the cursor column (refused on the last one — a zero-column table is no table).
---@return nil
local function col_delete()
    local c = ctx()
    if not c then
        return
    end
    if c.parsed.ncols <= 1 then
        vim.notify("lvim-table: cannot delete the last column", vim.log.levels.WARN)
        return
    end
    for _, row in ipairs(c.parsed.rows) do
        if row.kind == "cells" then
            table.remove(row.cells, c.ci)
        else
            table.remove(row.align, c.ci)
        end
    end
    table.remove(c.parsed.align, c.ci)
    c.parsed.ncols = c.parsed.ncols - 1
    apply(c, c.ri, math.min(c.ci, c.parsed.ncols))
end

--- Move the cursor column left/right by one; the cursor follows its column.
---@param delta integer  -1 or 1
---@return nil
local function col_move(delta)
    local c = ctx()
    if not c then
        return
    end
    local target = c.ci + delta
    if target < 1 or target > c.parsed.ncols then
        return
    end
    for _, row in ipairs(c.parsed.rows) do
        if row.kind == "cells" then
            while #row.cells < c.parsed.ncols do
                row.cells[#row.cells + 1] = { text = "", s = 0, e = 0, rs = 0, re = 0 }
            end
            row.cells[c.ci], row.cells[target] = row.cells[target], row.cells[c.ci]
        else
            row.align[c.ci], row.align[target] = row.align[target] or "default", row.align[c.ci] or "default"
        end
    end
    c.parsed.align[c.ci], c.parsed.align[target] =
        c.parsed.align[target] or "default", c.parsed.align[c.ci] or "default"
    apply(c, c.ri, target)
end

--- Move the cursor row up/down by one (within the block); the cursor follows its row.
---@param delta integer  -1 or 1
---@return nil
local function row_move(delta)
    local c = ctx()
    if not c then
        return
    end
    local target = c.ri + delta
    if target < 1 or target > #c.parsed.rows then
        return
    end
    c.parsed.rows[c.ri], c.parsed.rows[target] = c.parsed.rows[target], c.parsed.rows[c.ri]
    apply(c, target, c.ci)
end

--- Realign the block under the cursor (also what the mode autocmds run through init).
---@return nil
local function realign()
    local buf = api.nvim_get_current_buf()
    local lnum = api.nvim_win_get_cursor(0)[1]
    if not fmt.realign(buf, lnum) then
        vim.notify("lvim-table: no table under the cursor", vim.log.levels.WARN)
    end
end

--- The public operation table: plain callables (for commands/API) — each already wrapped for
--- dot-repeat, so a <Plug> mapping and a :LvimTable subcommand behave identically.
M.realign = repeatable(realign)
M.row_insert = repeatable(row_insert)
M.row_insert_above = repeatable(function()
    row_insert(true)
end)
M.row_delete = repeatable(row_delete)
M.col_insert = repeatable(col_insert)
M.col_insert_before = repeatable(function()
    col_insert(true)
end)
M.col_delete = repeatable(col_delete)
M.col_left = repeatable(function()
    col_move(-1)
end)
M.col_right = repeatable(function()
    col_move(1)
end)
M.row_up = repeatable(function()
    row_move(-1)
end)
M.row_down = repeatable(function()
    row_move(1)
end)

return M
