-- lvim-table.state: runtime state — which buffers have table mode ON and their per-buffer
-- machinery (debounce timer, realign snapshot, autocmd group, the <CR> mapping captured for
-- chaining). Kept separate from config on purpose: config holds OPTIONS the user set, state
-- holds what the plugin is DOING right now. Nothing here survives a restart.
--
---@module "lvim-table.state"

---@class LvimTableBufState
---@field augroup  integer          The buffer's autocmd group (cleared on disable)
---@field timer    uv.uv_timer_t?   The TextChanged debounce timer
---@field snapshot string?          The block text after the last realign — the guard that skips
---                                 a reformat when the block did not actually change
---@field prior_cr table?           vim.fn.maparg() dict of the <CR> insert mapping that existed
---                                 before table mode shadowed it (chained on fallthrough)
---@field maps     table[]          The buffer-local mappings installed by the mode: { mode, lhs }

local M = {}

--- Per-buffer mode state, keyed by buffer number. A buffer is in table mode iff it has an entry.
---@type table<integer, LvimTableBufState>
M.buffers = {}

--- The shared extmark namespace for the header/separator decorations.
---@type integer
M.ns = vim.api.nvim_create_namespace("lvim-table")

return M
