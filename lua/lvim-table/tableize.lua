-- lvim-table.tableize: turn delimited text into a table and back. `from` splits each line of a
-- range on a Lua pattern (default ",") into cells, escapes literal pipes so the parser
-- round-trips them, and renders an aligned table with a header separator; `to` flattens table
-- rows back to delimited lines (separator rows dropped, escapes undone). Both replace the range
-- in one set_lines call — a single undo step.
--
---@module "lvim-table.tableize"

local api = vim.api
local detect = require("lvim-table.detect")
local fmt = require("lvim-table.fmt")
local config = require("lvim-table.config")

local M = {}

--- Build a table from delimited lines.
---@param buf integer
---@param srow integer  1-based first line of the range
---@param erow integer  1-based last line of the range
---@param delim string?  Lua pattern the fields are split on (default ",")
---@return nil
function M.from(buf, srow, erow, delim)
    delim = (delim and delim ~= "") and delim or ","
    local lines = api.nvim_buf_get_lines(buf, srow - 1, erow, false)
    local indent = (lines[1] or ""):match("^%s*") or ""

    ---@type LvimTableRow[]
    local rows = {}
    local ncols = 0
    for _, line in ipairs(lines) do
        if vim.trim(line) ~= "" then
            local cells = {}
            for _, field in ipairs(vim.split(vim.trim(line), delim)) do
                -- A literal pipe inside a field must arrive escaped, or it would split the cell
                -- on the very next realign.
                local text = vim.trim(field):gsub("|", "\\|")
                cells[#cells + 1] = { text = text, s = 0, e = 0, rs = 0, re = 0 }
            end
            rows[#rows + 1] = { kind = "cells", indent = indent, cells = cells, align = {} }
            if #cells > ncols then
                ncols = #cells
            end
        end
    end
    if #rows == 0 then
        vim.notify("lvim-table: nothing to tableize in the range", vim.log.levels.WARN)
        return
    end
    -- The first line becomes the header: a separator row goes right under it.
    table.insert(rows, 2, { kind = "sep", indent = indent, cells = {}, align = {} })

    ---@type LvimTableParsed
    local parsed = { rows = rows, ncols = ncols, align = {}, sep = 2 }
    local new = fmt.render(parsed, { syntax = fmt.syntax_for(buf), padding = config.padding })
    api.nvim_buf_set_lines(buf, srow - 1, erow, false, new)
end

--- Flatten table rows back to delimited text. Non-table lines in the range pass through
--- unchanged; separator rows are dropped.
---@param buf integer
---@param srow integer  1-based first line of the range
---@param erow integer  1-based last line of the range
---@param sep string?  the join separator (default ", ")
---@return nil
function M.to(buf, srow, erow, sep)
    sep = (sep and sep ~= "") and sep or ", "
    local lines = api.nvim_buf_get_lines(buf, srow - 1, erow, false)
    local out = {}
    for _, line in ipairs(lines) do
        if detect.is_separator(line) then
            -- dropped: the separator is table syntax, not data
        elseif detect.is_row(line) then
            local indent, cells = detect.split_cells(line)
            local fields = {}
            for i, cell in ipairs(cells) do
                fields[i] = (cell.text:gsub("\\|", "|"))
            end
            out[#out + 1] = indent .. table.concat(fields, sep)
        else
            out[#out + 1] = line
        end
    end
    api.nvim_buf_set_lines(buf, srow - 1, erow, false, out)
end

return M
