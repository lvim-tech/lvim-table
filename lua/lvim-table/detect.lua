-- lvim-table.detect: table-block detection + row parsing — the pure half of the core (no buffer
-- writes). A table BLOCK is the maximal run of consecutive lines whose first non-blank character
-- is `|`, found by plain line scanning around a position: no treesitter, deliberately, because
-- tables live in comments, docstrings and plain text too, and a line scan is trivially fast.
--
-- Parsing is BYTE-position aware: every cell records where its raw region and trimmed content
-- start/end in bytes, because that is what the cursor, extmarks and nvim_win_set_cursor speak.
-- Display WIDTH (multibyte/CJK/nerd glyphs) is a formatting concern and lives in fmt.lua —
-- here only byte geometry. Cell splitting is escape-aware: `\|` never splits a cell.
--
---@module "lvim-table.detect"

local api = vim.api

local M = {}

---@class LvimTableCell
---@field text string   The trimmed cell content (escapes kept as written, e.g. "\|")
---@field s    integer  0-based byte column where the trimmed content starts (for an empty cell:
---                     where content WOULD start — the first byte after the opening pipe)
---@field e    integer  0-based byte column one PAST the trimmed content's last byte
---@field rs   integer  0-based byte column of the raw region start (right after the opening pipe)
---@field re   integer  0-based byte column one PAST the raw region end (the closing pipe)

---@class LvimTableRow
---@field kind   "cells"|"sep"
---@field indent string                                  Leading whitespace of the line
---@field cells  LvimTableCell[]                         (kind == "cells") the parsed cells
---@field align  ("left"|"center"|"right"|"default")[]   (kind == "sep") per-cell alignment markers

---@class LvimTableParsed
---@field rows  LvimTableRow[]
---@field ncols integer   Max cell count over the CELLS rows (separator junctions don't count)
---@field align ("left"|"center"|"right"|"default")[]  Column alignment from the FIRST separator row
---@field sep   integer?  Index (into rows) of the first separator row, when one exists

--- Whether a line is a table row: its first non-blank character is a pipe.
---@param line string?
---@return boolean
function M.is_row(line)
    return line ~= nil and line:match("^%s*|") ~= nil
end

--- Whether a line is a SEPARATOR row: a table row whose body consists only of `-`, `:`, `+`,
--- `|` and spaces, with at least one dash. Covers markdown (`|:---|---:|`) and org (`|---+---|`).
---@param line string?
---@return boolean
function M.is_separator(line)
    if not M.is_row(line) then
        return false
    end
    local body = vim.trim(line)
    return body:match("^[%-%+:%s|]+$") ~= nil and body:find("-", 1, true) ~= nil
end

--- The table block around a line: scan up and down while lines are table rows.
---@param buf integer
---@param lnum integer  1-based line the cursor is on
---@return integer? srow, integer? erow  1-based inclusive block bounds, nil when `lnum` is not in a table
function M.block(buf, lnum)
    local total = api.nvim_buf_line_count(buf)
    if lnum < 1 or lnum > total then
        return nil, nil
    end
    local function line(n)
        return api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
    end
    if not M.is_row(line(lnum)) then
        return nil, nil
    end
    local srow, erow = lnum, lnum
    while srow > 1 and M.is_row(line(srow - 1)) do
        srow = srow - 1
    end
    while erow < total and M.is_row(line(erow + 1)) do
        erow = erow + 1
    end
    return srow, erow
end

--- Split a table row into cells with byte positions. The split walks bytes so `\|` (an escaped
--- pipe inside a cell) never splits; a row without a closing pipe still yields its last cell.
---@param line string
---@return string indent, LvimTableCell[] cells
function M.split_cells(line)
    local indent = line:match("^%s*") or ""
    ---@type LvimTableCell[]
    local cells = {}
    local n = #line

    --- Record the raw region [s, e] (1-based inclusive byte bounds; empty when s > e).
    ---@param s integer
    ---@param e integer
    local function push(s, e)
        local raw = line:sub(s, e)
        local text = vim.trim(raw)
        local cs, ce
        if text == "" then
            cs, ce = s - 1, s - 1 -- content WOULD start right after the pipe
        else
            local first = raw:find("%S") --[[@as integer]]
            cs = s + first - 2 -- to 0-based
            ce = cs + #text
        end
        cells[#cells + 1] = { text = text, s = cs, e = ce, rs = s - 1, re = e }
    end

    local start = #indent + 2 -- first content byte, after the opening pipe
    local j = start
    while j <= n do
        local ch = line:sub(j, j)
        if ch == "\\" then
            j = j + 2 -- the escaped byte can never terminate a cell
        elseif ch == "|" then
            push(start, j - 1)
            start = j + 1
            j = j + 1
        else
            j = j + 1
        end
    end
    if start <= n then
        push(start, n) -- unclosed row: the trailing text is still a cell
    end
    return indent, cells
end

--- Alignment marker of one separator cell: `:--` left, `:-:` center, `--:` right, plain default.
---@param text string
---@return "left"|"center"|"right"|"default"
local function marker(text)
    local starts = text:sub(1, 1) == ":"
    local ends = text:sub(-1) == ":"
    if starts and ends then
        return "center"
    elseif ends then
        return "right"
    elseif starts then
        return "left"
    end
    return "default"
end

--- Parse a whole block of lines into the row matrix.
---@param lines string[]
---@return LvimTableParsed
function M.parse(lines)
    ---@type LvimTableParsed
    local parsed = { rows = {}, ncols = 0, align = {}, sep = nil }
    for i, line in ipairs(lines) do
        local indent, cells = M.split_cells(line)
        if M.is_separator(line) then
            ---@type ("left"|"center"|"right"|"default")[]
            local align = {}
            for c, cell in ipairs(cells) do
                align[c] = marker(cell.text)
            end
            parsed.rows[i] = { kind = "sep", indent = indent, cells = cells, align = align }
            if not parsed.sep then
                parsed.sep = i
                parsed.align = align
            end
        else
            parsed.rows[i] = { kind = "cells", indent = indent, cells = cells, align = {} }
            if #cells > parsed.ncols then
                parsed.ncols = #cells
            end
        end
    end
    -- A block that is ONLY separator rows still needs a column count to render.
    if parsed.ncols == 0 and parsed.sep then
        parsed.ncols = math.max(1, #parsed.rows[parsed.sep].cells)
    end
    return parsed
end

--- The cell the cursor is in: 1-based cell index + byte offset inside the trimmed content
--- (clamped to [0, #text]). Before the first pipe → cell 1, offset 0; past the last cell →
--- the last cell at its end.
---@param line string
---@param col integer  0-based byte column (nvim_win_get_cursor)
---@return integer idx, integer offset
function M.cursor_cell(line, col)
    local _, cells = M.split_cells(line)
    if #cells == 0 then
        return 1, 0
    end
    for i, cell in ipairs(cells) do
        if col < cell.re or i == #cells then
            local offset = math.max(0, math.min(col - cell.s, #cell.text))
            return i, offset
        end
    end
    return #cells, #cells[#cells].text
end

return M
