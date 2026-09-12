-- lvim-table: :checkhealth lvim-table.
-- Diagnoses what makes an as-you-edit table aligner misbehave invisibly: a config that is
-- internally inconsistent (bad syntax names, negative debounce/padding), the lvim-utils
-- dependency (palette + merge — without it setup() itself fails), whether the optional
-- lvim-hud chip can actually appear, and a live sanity run of the align engine so a broken
-- core is caught here rather than mid-edit. Read-only reporting — never mutates config/state.
--
---@module "lvim-table.health"

local config = require("lvim-table.config")
local state = require("lvim-table.state")
local fmt = require("lvim-table.fmt")

local M = {}

--- Validate the live config table; error on each violation, ok when clean.
---@param health table  the vim.health reporter
---@return nil
local function check_config(health)
    local problems = 0

    for ft, syn in pairs(config.syntax or {}) do
        if syn ~= "markdown" and syn ~= "org" then
            health.error(('syntax["%s"] must be "markdown" or "org" (got %s)'):format(ft, vim.inspect(syn)))
            problems = problems + 1
        end
    end
    if config.default_syntax ~= "markdown" and config.default_syntax ~= "org" then
        health.error(('default_syntax must be "markdown" or "org" (got %s)'):format(vim.inspect(config.default_syntax)))
        problems = problems + 1
    end

    if type(config.padding) ~= "number" or config.padding < 0 then
        health.error(("padding must be a number >= 0 (got %s)"):format(vim.inspect(config.padding)))
        problems = problems + 1
    end
    if type(config.realign) ~= "table" or type(config.realign.debounce) ~= "number" or config.realign.debounce < 0 then
        health.error("realign.debounce must be a number >= 0")
        problems = problems + 1
    end
    if
        type(config.formula) ~= "table"
        or type(config.formula.precision) ~= "number"
        or config.formula.precision < 0
    then
        health.error("formula.precision must be a number >= 0")
        problems = problems + 1
    end

    -- The chip glyph must be a real single-width Nerd Font codepoint, or the statusline shifts.
    local icon = config.icons and config.icons.table
    if type(icon) ~= "string" or icon == "" then
        health.error("icons.table must be a non-empty string")
        problems = problems + 1
    elseif vim.fn.strdisplaywidth(icon) ~= 1 then
        health.warn(
            ("icons.table %q is not single-width (strdisplaywidth=%d)"):format(icon, vim.fn.strdisplaywidth(icon))
        )
    end

    if problems == 0 then
        health.ok("config valid")
    end
end

--- A live round-trip through the align engine: a ragged 2×2 with a CJK cell must come out with
--- both columns at the CJK display width. Catches a broken strdisplaywidth path immediately.
---@param health table  the vim.health reporter
---@return nil
local function check_engine(health)
    local ok, out = pcall(
        fmt.align,
        { "| a | b |", "|---|---|", "| 日本語 | c |" },
        { syntax = "markdown", padding = 1 }
    )
    if not ok then
        health.error("align engine failed: " .. tostring(out))
        return
    end
    local w1 = vim.fn.strdisplaywidth(out[1])
    local w3 = vim.fn.strdisplaywidth(out[3])
    if w1 == w3 and out[3]:find("日本語", 1, true) then
        health.ok("align engine: display-width alignment (CJK) correct")
    else
        health.error(("align engine misaligns CJK (row widths %d vs %d)"):format(w1, w3))
    end
end

--- Run the health report.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-table")

    if vim.fn.has("nvim-0.12") == 1 then
        health.ok("Neovim >= 0.12")
    else
        health.error("Neovim >= 0.12 is required (the lvim-tech set targets 0.12; lvim-utils requires it)")
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    local ok_colors = pcall(require, "lvim-utils.colors")
    if ok_utils and ok_colors then
        health.ok("lvim-utils found (palette + merge)")
    else
        health.error("lvim-utils not found — lvim-table requires it (merge + self-theming highlights)")
    end

    if config.hud_chip then
        if pcall(require, "lvim-hud.overlay") then
            health.ok("lvim-hud found — the 󰓫 TABLE chip is available")
        else
            health.info("hud_chip is on but lvim-hud is not installed — the chip is silently skipped")
        end
    else
        health.info("hud_chip disabled")
    end

    check_config(health)
    check_engine(health)

    local active = vim.tbl_count(state.buffers)
    if active > 0 then
        local bufs = {}
        for buf in pairs(state.buffers) do
            bufs[#bufs + 1] = tostring(buf)
        end
        health.info(("table mode active in %d buffer(s): %s"):format(active, table.concat(bufs, ", ")))
    else
        health.info("table mode not active in any buffer (:LvimTable toggle)")
    end

    health.info(
        ("padding=%d  debounce=%dms  decorations=%s  map_default_keys=%s"):format(
            config.padding,
            config.realign.debounce,
            tostring(config.decorations),
            tostring(config.map_default_keys)
        )
    )
end

return M
