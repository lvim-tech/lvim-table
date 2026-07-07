-- lvim-table.highlights: the decoration highlight groups, self-themed from the lvim-utils
-- palette. Two groups (the plan's canon): the header row reads emphasized (blue bold), the
-- separator rows recede (fg dimmed 0.6 toward the editor bg — table syntax, not table data).
-- build() must be a FUNCTION so each call reads the live palette; init binds it via
-- lvim-utils.highlight.bind so the groups re-derive on ColorScheme / palette sync.
--
---@module "lvim-table.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

local M = {}

--- The decoration groups from the live palette.
---@return table<string, table>
function M.build()
    return {
        LvimTableHeader = { fg = c.blue, bold = true },
        LvimTableSeparator = { fg = hl.blend(c.fg, c.bg, 0.6) },
    }
end

return M
