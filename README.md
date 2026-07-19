# lvim-table

Painless text tables for the **lvim-tech** set — a per-buffer **table mode** that keeps
markdown/org pipe tables aligned as you edit, plus row/column operations, cell text objects and
motions, tableize (delimited text ⇄ table) and a small formula calculator.

Column widths are computed in **display cells** (`strdisplaywidth`), so CJK text, Nerd Font
glyphs and escaped pipes (`\|`) align correctly where byte-counting formatters produce sawtooth
columns. Alignment markers in the separator row are honoured and preserved: `:--` left, `:-:`
center, `--:` right.

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-table/blob/main/LICENSE)

## Requirements

Requires **Neovim >= 0.10** and [lvim-utils](https://github.com/lvim-tech/lvim-utils) (the
palette + the shared merge). [lvim-hud](https://github.com/lvim-tech/lvim-hud) is optional —
with it, an active table mode shows a `󰓫 TABLE` chip on the statusline overlay.

## Installation

### lvim-installer (recommended)

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin
manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-table" },
})
require("lvim-table").setup({})
```

## Table mode

Table mode is **per buffer**:

```vim
:LvimTable toggle    " also plain :LvimTable
:LvimTable on
:LvimTable off
```

While the mode is on:

- **Realign as you edit** — leaving insert mode (`InsertLeave`) or a normal-mode change
  (`TextChanged`, debounced) realigns the table block under the cursor. A snapshot guard skips
  the reformat when the block did not actually change, so large files never pay a parse per
  keystroke. The cursor stays in its cell across a reflow.
- **`||` expands a separator** — typing `||` on an otherwise empty line directly under a table
  row expands into a full separator row matching that table's columns.
- **`<CR>` continues the table** — in insert mode inside a table row, `<CR>` appends an aligned
  empty row and puts the cursor in its first cell. On a **one-row block** (a just-typed header)
  it inserts the separator row *and* the empty row in one go; on an **all-empty row** it ends
  the table (the row becomes a blank line). Outside a table (or with the completion menu open),
  `<CR>` falls through to whatever it did before — a completion plugin's confirm keeps working.
- **Decorations** — the header row and separator rows are tinted (`LvimTableHeader`,
  `LvimTableSeparator`) while the mode is on; cleared with it.
- **Hud chip** — with lvim-hud installed, the statusline overlay shows `󰓫 TABLE` while the
  current buffer has table mode on. `require("lvim-table").is_active(buf)` is public for your
  own statusline components.

A table **block** is the maximal run of consecutive lines whose first non-blank character is
`|` — plain line scanning, no treesitter, so tables in comments, docstrings and plain text work
the same. Per-filetype **syntax**: `markdown` writes `|---|---|` separators with `:` alignment
markers, `org` writes `|---+---|` junction rows.

## Formatting without the mode

`:LvimTable format` realigns the table block under the cursor once, in any buffer — table mode
does not need to be on.

## Row / column operations

All operations work on the parsed cell matrix and re-render the block — alignment, escapes and
separator markers never drift. Each is **dot-repeatable** (`.`).

| Subcommand                       | `<Plug>` mapping                  | Effect                             |
| -------------------------------- | --------------------------------- | ---------------------------------- |
| `:LvimTable row-insert`          | `<Plug>(LvimTableRowInsert)`      | empty row below the cursor row     |
| `:LvimTable row-insert-above`    | `<Plug>(LvimTableRowInsertAbove)` | empty row above the cursor row     |
| `:LvimTable row-delete`          | `<Plug>(LvimTableRowDelete)`      | delete the cursor row              |
| `:LvimTable col-insert`          | `<Plug>(LvimTableColInsert)`      | empty column after the cursor one  |
| `:LvimTable col-insert-before`   | `<Plug>(LvimTableColInsertBefore)`| empty column before the cursor one |
| `:LvimTable col-delete`          | `<Plug>(LvimTableColDelete)`      | delete the cursor column           |
| `:LvimTable row-up` / `row-down` | `<Plug>(LvimTableRowUp/Down)`     | move the cursor row                |
| `:LvimTable col-left` / `col-right` | `<Plug>(LvimTableColLeft/Right)` | move the cursor column          |
| `:LvimTable format`              | `<Plug>(LvimTableRealign)`        | realign the block                  |
| `:LvimTable eval`                | `<Plug>(LvimTableEval)`           | evaluate the formula line          |

Nothing is mapped by default. Either map the `<Plug>` targets yourself, or set
`map_default_keys = true` to get the `keys` table below mapped buffer-locally while table mode
is on.

## Cell text objects & motions

Mapped buffer-locally while table mode is on (each entry can be disabled with `false`):

| Key  | Action                                                 |
| ---- | ------------------------------------------------------ |
| `i\|` | inner cell (the trimmed content) — visual + operator  |
| `a\|` | around cell (everything between the pipes)            |
| `]\|` | next cell (wraps to the row below)                    |
| `[\|` | previous cell (wraps to the row above)                |
| `{\|` | same column, first data row above                     |
| `}\|` | same column, first data row below                     |

Motions honour a count and skip separator rows.

## Tableize

Turn delimited text into a table and back, over a range:

```vim
:'<,'>LvimTable from            " split on ',' (default)
:'<,'>LvimTable from ;          " a Lua pattern as the delimiter (escape magic chars: %. %- etc.)
:'<,'>LvimTable to              " flatten back, joined with ', '
:'<,'>LvimTable to ;
```

`from` makes the first line the header and inserts a separator row under it; literal pipes in
the data arrive escaped (`\|`) so they survive realignment. `to` drops separator rows and
unescapes.

## Formulas

A formula line directly under a table assigns a **column** for every data row (the rows below
the first separator):

```markdown
| a   | b   | sum | avg |
| --- | --- | --- | --- |
| 2   | 3   | 5   | 2.5 |

<!-- tmf: $3 = $1 + $2; $4 = avg($1..$2) -->
```

`:LvimTable eval` recomputes. `$N` is column N of the current row; `sum($a..$b)` / `avg($a..$b)`
aggregate a column range within the row; non-numeric cells count as 0. Both comment styles are
accepted anywhere: `<!-- tmf: ... -->` and `#+tblfm: ...`. Deliberately a calculator, not a
spreadsheet — plain arithmetic only, evaluated in an empty sandbox after a charset check.

## Default configuration

```lua
require("lvim-table").setup({
    -- table syntax per filetype; anything not listed uses `default_syntax`
    syntax = { markdown = "markdown", org = "org" },
    default_syntax = "markdown",
    -- spaces between a cell's content and its pipes
    padding = 1,
    realign = {
        insert_leave = true, -- realign on InsertLeave
        text_changed = true, -- realign (debounced) on TextChanged
        debounce = 80, -- ms the TextChanged realign is coalesced
    },
    expand_separator = true, -- `||` on its own line expands to a separator row
    continue_rows = true, -- <CR> in insert inside a table continues with an empty row
    decorations = true, -- highlight header/separator rows while the mode is on
    hud_chip = true, -- show `󰓫 TABLE` on the lvim-hud overlay while active
    formula = {
        precision = 2, -- decimals for non-integer results (trailing zeros trimmed)
    },
    map_default_keys = false, -- map `keys` buffer-locally while table mode is on
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
    -- cell text objects + motions (always mapped in table mode; false disables one)
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
})
```

## API

```lua
local lt = require("lvim-table")

lt.setup({}) -- merge options, bind highlights, register <Plug> maps + :LvimTable
lt.enable(buf) -- turn table mode on (buf defaults to the current buffer)
lt.disable(buf) -- turn it off
lt.toggle(buf) -- toggle; returns the new state
lt.is_active(buf) -- true while table mode is on (for statusline components)
lt.realign() -- realign the block under the cursor once (mode not required)
```

## Highlights

Self-themed from the lvim-utils palette (re-derived on ColorScheme / palette sync):

- `LvimTableHeader` — the header row (blue, bold)
- `LvimTableSeparator` — separator rows (fg dimmed toward the background)

## Health

```vim
:checkhealth lvim-table
```

Reports the lvim-utils dependency, the optional lvim-hud chip, config validation, and a live
CJK round-trip through the align engine.
