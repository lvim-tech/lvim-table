-- lvim-table.textobj: cell text objects (i| inner / a| around) and cell motions ([| ]| prev/next
-- cell, {| }| the cell above/below in the same column). Objects select by BYTE positions from
-- detect's cell geometry; the only subtlety is the selection END — visual charwise selection is
-- inclusive of the character whose FIRST byte the cursor lands on, so a multibyte last character
-- must be entered at its lead byte, not its final one.
--
---@module "lvim-table.textobj"

local api = vim.api
local detect = require("lvim-table.detect")

local M = {}

--- The 0-based byte index of the FIRST byte of the character containing byte `b`
--- (walk left over UTF-8 continuation bytes 0x80..0xBF).
---@param line string
---@param b integer  0-based byte index
---@return integer
local function char_start(line, b)
    while b > 0 do
        local byte = line:byte(b + 1)
        if byte and byte >= 0x80 and byte < 0xC0 then
            b = b - 1
        else
            break
        end
    end
    return b
end

--- Charwise-select [s, e] (0-based byte cols, e = last byte of the last char's sequence) on
--- `lnum`. Restarts visual mode when already in it (the standard custom-object shape), which
--- also gives operator-pending mode its region.
---@param lnum integer
---@param s integer
---@param e integer
---@return nil
local function select_range(lnum, s, e)
    local mode = api.nvim_get_mode().mode
    if mode:find("^[vV\22]") then
        vim.cmd("normal! \27") -- leave the caller's visual so ours defines the region
    end
    api.nvim_win_set_cursor(0, { lnum, s })
    vim.cmd("normal! v")
    api.nvim_win_set_cursor(0, { lnum, e })
end

--- Select the cell under the cursor: inner = the trimmed content, around = everything between
--- the two pipes (padding included). An EMPTY inner cell falls back to its padding region so
--- `ci|` still lands inside the cell instead of aborting the operator.
---@param inner boolean
---@return nil
function M.select_cell(inner)
    local pos = api.nvim_win_get_cursor(0)
    local line = api.nvim_buf_get_lines(0, pos[1] - 1, pos[1], false)[1]
    if not detect.is_row(line) then
        return
    end
    local idx = detect.cursor_cell(line, pos[2])
    local _, cells = detect.split_cells(line)
    local cell = cells[idx]
    if not cell then
        return
    end
    local s, e
    if inner and cell.text ~= "" then
        s, e = cell.s, char_start(line, cell.e - 1)
    else
        if cell.re <= cell.rs then
            return -- a zero-width `||` region: nothing selectable without eating a pipe
        end
        s, e = cell.rs, char_start(line, cell.re - 1)
    end
    select_range(pos[1], s, e)
end

--- Put the cursor at the content start of cell `idx` on line `lnum` (clamped into the row).
---@param lnum integer
---@param idx integer
---@return nil
local function goto_cell(lnum, idx)
    local line = api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
    local _, cells = detect.split_cells(line)
    local cell = cells[math.max(1, math.min(idx, #cells))]
    if cell then
        pcall(api.nvim_win_set_cursor, 0, { lnum, cell.s })
    end
end

--- Move to the next/previous CELL: along the row first, wrapping to the adjacent data row
--- (separator rows are skipped — there is no cell to land in). Honors v:count1.
---@param dir integer  1 = next, -1 = previous
---@return nil
function M.move_cell(dir)
    for _ = 1, vim.v.count1 do
        local buf = api.nvim_get_current_buf()
        local pos = api.nvim_win_get_cursor(0)
        local srow, erow = detect.block(buf, pos[1])
        if not srow or not erow then
            return
        end
        local line = api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1]
        local idx = detect.cursor_cell(line, pos[2])
        local _, cells = detect.split_cells(line)
        local target_row, target_idx = pos[1], idx + dir
        if target_idx < 1 or target_idx > #cells then
            -- Wrap to the adjacent CELLS row (skipping separators) — its first or last cell.
            repeat
                target_row = target_row + dir
                if target_row < srow or target_row > erow then
                    return
                end
                line = api.nvim_buf_get_lines(buf, target_row - 1, target_row, false)[1]
            until not detect.is_separator(line)
            local _, tcells = detect.split_cells(line)
            target_idx = dir > 0 and 1 or #tcells
        end
        goto_cell(target_row, target_idx)
    end
end

--- Move to the same COLUMN in the first data row above/below (separators skipped). Honors
--- v:count1.
---@param dir integer  1 = down, -1 = up
---@return nil
function M.move_row(dir)
    for _ = 1, vim.v.count1 do
        local buf = api.nvim_get_current_buf()
        local pos = api.nvim_win_get_cursor(0)
        local srow, erow = detect.block(buf, pos[1])
        if not srow or not erow then
            return
        end
        local line = api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1]
        local idx = detect.cursor_cell(line, pos[2])
        local target = pos[1]
        repeat
            target = target + dir
            if target < srow or target > erow then
                return
            end
            line = api.nvim_buf_get_lines(buf, target - 1, target, false)[1]
        until not detect.is_separator(line)
        goto_cell(target, idx)
    end
end

return M
