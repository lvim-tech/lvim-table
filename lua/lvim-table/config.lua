-- lvim-table: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it IN PLACE (via
-- lvim-utils.utils.merge), so every require("lvim-table.config") reader sees the effective
-- values. Only OPTIONS live here — table-mode runtime state (which buffers are active, their
-- debounce timers, realign snapshots) is in lvim-table.state, never in this file.
--
---@module "lvim-table.config"

---@class LvimTableRealignConfig
---@field insert_leave boolean  Realign the table block under the cursor on InsertLeave
---@field text_changed boolean  Realign (debounced) on TextChanged — normal-mode edits
---@field debounce     integer  Milliseconds the TextChanged realign is debounced
---@field on_save      boolean  Realign EVERY table block in the buffer on BufWritePre (table
---   mode buffers only — saving is the moment a half-typed table must leave the file aligned)

---@class LvimTableFormulaConfig
---@field precision integer  Decimal places for non-integer formula results (trailing zeros trimmed)

---@class LvimTableKeysConfig
---@field realign    string  Realign the table block under the cursor
---@field row_insert string  Insert an empty row below the cursor row
---@field row_insert_above string  Insert an empty row above the cursor row
---@field row_delete string  Delete the cursor row
---@field col_insert string  Insert an empty column after the cursor column
---@field col_insert_before string  Insert an empty column before the cursor column
---@field col_delete string  Delete the cursor column
---@field row_up     string  Move the cursor row up
---@field row_down   string  Move the cursor row down
---@field col_left   string  Move the cursor column left
---@field col_right  string  Move the cursor column right
---@field eval       string  Evaluate the table's formula line (:LvimTable eval)

---@class LvimTableTextobjConfig
---@field cell_inner  string  Text object: the trimmed cell content
---@field cell_around string  Text object: the whole cell between its pipes (padding included)
---@field prev_cell   string  Motion: previous cell (wraps to the row above)
---@field next_cell   string  Motion: next cell (wraps to the row below)
---@field cell_up     string  Motion: same column, first data row above
---@field cell_down   string  Motion: same column, first data row below

---@class LvimTableIconsConfig
---@field table string  The table glyph used in the hud chip / notifications (Nerd Font)

---@class LvimTableConfig
---@field syntax           table<string, "markdown"|"org">  Per-filetype table syntax
---@field default_syntax   "markdown"|"org"                 Syntax for filetypes not listed in `syntax`
---@field padding          integer                          Spaces around each cell's content
---@field realign          LvimTableRealignConfig           When the as-you-edit realign fires
---@field expand_separator boolean                          `||` typed on its own line expands to a separator row
---@field continue_rows    boolean                          Insert-mode Enter inside a table continues with an empty row
---@field decorations      boolean                          Highlight header/separator rows while table mode is on
---@field hud_chip         boolean                          Show a "󰓫 TABLE" chip on the lvim-hud overlay while active
---@field formula          LvimTableFormulaConfig           Formula evaluation options
---@field map_default_keys boolean                          Map `keys` buffer-locally while table mode is on
---@field keys             LvimTableKeysConfig              The normal-mode keys used when `map_default_keys`
---@field textobj          LvimTableTextobjConfig           Cell text objects / motions (always mapped in table mode)
---@field icons            LvimTableIconsConfig             Glyphs

---@type LvimTableConfig
return {
    -- Table syntax per filetype; anything not listed uses `default_syntax`. "markdown" writes
    -- `|---|---|` separators with `:` alignment markers; "org" writes `|---+---|` junction rows.
    syntax = { markdown = "markdown", org = "org" },
    default_syntax = "markdown",
    -- Spaces between a cell's content and its pipes. The separator row always fills the whole
    -- cell width (content + 2×padding), so `padding` only shapes the text rows.
    padding = 1,
    realign = {
        insert_leave = true,
        text_changed = true,
        -- The TextChanged burst (put, repeat, plugins) is coalesced into one realign. A snapshot
        -- guard additionally skips the reformat entirely when the block did not actually change.
        debounce = 80,
        on_save = true,
    },
    -- Typing `||` on an otherwise empty line directly under a table row expands into a full
    -- separator row matching that table's columns (the quickest way to close a header).
    expand_separator = true,
    -- <CR> in insert mode inside a table row appends an aligned empty row and puts the cursor in
    -- its first cell; <CR> on an all-empty row ends the table (the row becomes a blank line).
    continue_rows = true,
    -- While table mode is on: header rows get LvimTableHeader, separator rows LvimTableSeparator
    -- (extmark decoration, cleared with the mode).
    decorations = true,
    -- Publish a "󰓫 TABLE" chip to the lvim-hud statusline overlay while the CURRENT buffer has
    -- table mode on (cross-plugin optional — silently skipped when lvim-hud is absent).
    -- OFF by default: the lvim-hud OVERLAY is transient by contract (finder/echo takeovers) and
    -- showing a persistent chip there REPLACES the whole statusline for the session (measured —
    -- "table mode hides the statusline"). The persistent seam is a statusline SEGMENT reading
    -- `require("lvim-table").is_active(buf)`, refreshed by the `User LvimTableMode` event.
    hud_chip = false,
    formula = {
        precision = 2,
    },
    -- The row/column operations are always available as <Plug> mappings and :LvimTable
    -- subcommands; set this to also map `keys` buffer-locally while table mode is on.
    map_default_keys = false,
    keys = {
        realign = "<leader>ta",
        row_insert = "<leader>tir",
        row_insert_above = "<leader>tiR",
        row_delete = "<leader>tdr",
        col_insert = "<leader>tic",
        col_insert_before = "<leader>tiC",
        col_delete = "<leader>tdc",
        row_up = "<leader>tK",
        row_down = "<leader>tJ",
        col_left = "<leader>tH",
        col_right = "<leader>tL",
        eval = "<leader>te",
    },
    -- Cell text objects + motions, mapped buffer-locally while table mode is on (removed with
    -- the mode). Set an entry to false to skip that mapping.
    textobj = {
        cell_inner = "i|",
        cell_around = "a|",
        prev_cell = "[|",
        next_cell = "]|",
        cell_up = "{|",
        cell_down = "}|",
    },
    icons = {
        table = "󰓫",
    },
}
