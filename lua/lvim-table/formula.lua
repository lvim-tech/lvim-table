-- lvim-table.formula: the org-lite calculator. A formula line directly under a table —
-- `<!-- tmf: $3 = $1 + $2 -->` (markdown) or `#+tblfm: $3 = $1 + $2` (org) — assigns a COLUMN:
-- for every data row (the cells rows below the first separator), the target column is
-- recomputed from that row's other columns. `sum($a..$b)` / `avg($a..$b)` aggregate a column
-- RANGE within the row; non-numeric cells count as 0. Deliberately a calculator, not a
-- spreadsheet: no cross-row references, no strings, no functions beyond sum/avg.
--
-- Evaluation is a two-step substitute-then-load: refs are replaced with plain numbers, the
-- result is charset-VALIDATED (digits + arithmetic operators only) and only then compiled with
-- an empty environment — so a formula can compute, never call.
--
---@module "lvim-table.formula"

local api = vim.api
local detect = require("lvim-table.detect")
local fmt = require("lvim-table.fmt")
local config = require("lvim-table.config")

local M = {}

--- Find the formula spec under a block: the first non-blank line after `erow`, in either
--- comment style (both accepted regardless of syntax — tables travel between file types).
---@param buf integer
---@param erow integer  1-based last block line
---@return string? spec, integer? lnum
function M.find(buf, erow)
    local total = api.nvim_buf_line_count(buf)
    for lnum = erow + 1, math.min(erow + 2, total) do
        local line = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
        if vim.trim(line) ~= "" then
            local spec = line:match("<!%-%-%s*tmf:%s*(.-)%s*%-%->")
                or line:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:%s*(.-)%s*$")
            return spec, spec and lnum or nil
        end
    end
    return nil, nil
end

--- Numeric value of a row's column (0 when absent or not a number).
---@param row LvimTableRow
---@param col integer
---@return number
local function value(row, col)
    local cell = row.cells[col]
    return cell and tonumber(cell.text) or 0
end

--- Substitute sum()/avg() ranges and $N refs with this row's numbers.
---@param expr string
---@param row LvimTableRow
---@return string
local function substitute(expr, row)
    expr = expr:gsub("(%a+)%(%s*%$(%d+)%s*%.%.%s*%$(%d+)%s*%)", function(fn, a, b)
        local lo, hi =
            tonumber(a), --[[@as integer]]
            tonumber(b) --[[@as integer]]
        if lo > hi then
            lo, hi = hi, lo
        end
        local total = 0
        for col = lo, hi do
            total = total + value(row, col)
        end
        if fn == "avg" then
            return tostring(total / math.max(1, hi - lo + 1))
        end
        return tostring(total) -- any other name means sum (only the two are documented)
    end)
    expr = expr:gsub("%$(%d+)", function(n)
        return tostring(value(row, tonumber(n) --[[@as integer]]))
    end)
    return expr
end

--- Evaluate a substituted arithmetic expression. The charset gate is what makes the load safe:
--- after substitution only numbers may remain, so anything alphabetic (identifiers, keywords)
--- is rejected before it can reach the compiler; the empty environment removes every global.
---@param expr string
---@return number?
local function evaluate(expr)
    if not expr:match("^[%d%.%s%+%-%*/%%%^%(%)eE]+$") then
        return nil
    end
    local chunk = load("return " .. expr, "tmf", "t", {})
    if not chunk then
        return nil
    end
    local ok, result = pcall(chunk)
    if ok and type(result) == "number" then
        return result
    end
    return nil
end

--- Render a numeric result: integers plain, floats at config precision, trailing zeros trimmed.
---@param v number
---@return string
local function render_number(v)
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
        return ("%d"):format(v)
    end
    local s = ("%." .. config.formula.precision .. "f"):format(v)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s
end

--- Evaluate the formula line of the table under the cursor and rewrite the computed columns.
---@param buf integer
---@param lnum integer  1-based line inside the block
---@return boolean ok
function M.eval(buf, lnum)
    local srow, erow = detect.block(buf, lnum)
    if not srow or not erow then
        vim.notify("lvim-table: no table under the cursor", vim.log.levels.WARN)
        return false
    end
    local spec = M.find(buf, erow)
    if not spec then
        vim.notify(
            "lvim-table: no formula line under the table (<!-- tmf: ... --> / #+tblfm: ...)",
            vim.log.levels.WARN
        )
        return false
    end

    local old = api.nvim_buf_get_lines(buf, srow - 1, erow, false)
    local parsed = detect.parse(old)
    -- Data rows: everything below the first separator; without one, every cells row.
    local first_data = parsed.sep and (parsed.sep + 1) or 1

    for f in spec:gmatch("[^;]+") do
        local target, expr = f:match("^%s*%$(%d+)%s*=%s*(.-)%s*$")
        local col = tonumber(target)
        if not col or not expr or expr == "" then
            vim.notify(("lvim-table: bad formula %q (expected $N = expr)"):format(vim.trim(f)), vim.log.levels.ERROR)
            return false
        end
        for ri = first_data, #parsed.rows do
            local row = parsed.rows[ri]
            if row.kind == "cells" then
                local result = evaluate(substitute(expr, row))
                if result == nil then
                    vim.notify(("lvim-table: formula %q did not evaluate"):format(vim.trim(f)), vim.log.levels.ERROR)
                    return false
                end
                while #row.cells < col do
                    row.cells[#row.cells + 1] = { text = "", s = 0, e = 0, rs = 0, re = 0 }
                end
                row.cells[col].text = render_number(result)
            end
        end
        if col > parsed.ncols then
            parsed.ncols = col
        end
    end

    local new = fmt.render(parsed, { syntax = fmt.syntax_for(buf), padding = config.padding })
    fmt.write(buf, srow, old, new)
    return true
end

return M
