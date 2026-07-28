-- lvim-table: painless text tables — a per-buffer TABLE MODE that realigns pipe tables as you
-- edit, plus row/column operations, cell text objects/motions, tableize (delimited text ⇄
-- table) and an org-lite formula calculator.
--
-- The mode is deliberately event-driven, not keystroke-driven: realignment fires on
-- InsertLeave and (debounced) TextChanged, and a SNAPSHOT guard skips the reformat when the
-- block text did not actually change — so large files never pay a parse per keystroke, and our
-- own rewrite (which fires TextChanged again) short-circuits instead of looping. The two
-- insert-mode conveniences pick their seams for burst/macro correctness: `||` → separator row
-- rides InsertCharPre (per-character, committed-text state — an expr `|` map would read lines
-- Vim's insert fast path has not flushed yet, see on_insert_char), and <CR> → next row is a
-- NON-expr callback mapping (no textlock, so the edit happens synchronously and queued keys
-- land in the new row) that CHAINS whatever <CR> did before table mode shadowed it, so a
-- completion plugin's confirm keeps working.
--
---@module "lvim-table"

local api = vim.api
local uv = vim.uv
local config = require("lvim-table.config")
local state = require("lvim-table.state")
local detect = require("lvim-table.detect")
local fmt = require("lvim-table.fmt")
local ops = require("lvim-table.ops")
local textobj = require("lvim-table.textobj")
local tableize = require("lvim-table.tableize")
local formula = require("lvim-table.formula")
local highlights = require("lvim-table.highlights")
local hl = require("lvim-utils.highlight")
local merge = require("lvim-utils.utils").merge

local M = {}

---@type boolean  one-time setup (highlight bind, <Plug> maps, command) done
local registered = false

-- ─── hud chip ──────────────────────────────────────────────────────────────────

--- Show/clear the "󰓫 TABLE" chip on the lvim-hud statusline overlay (cross-plugin optional —
--- silently absent without lvim-hud). Cleared only when the chip is OURS (title match), so a
--- finder that took the overlay over is never clobbered.
---@param on boolean
---@return nil
local function chip(on)
    if not config.hud_chip then
        return
    end
    local ok, overlay = pcall(require, "lvim-hud.overlay")
    if not ok then
        return
    end
    if on then
        overlay.set({ icon = config.icons.table, title = "TABLE" })
    else
        local s = overlay.get()
        if s.active and s.title == "TABLE" then
            overlay.clear()
        end
    end
end

-- ─── decorations ───────────────────────────────────────────────────────────────

--- Re-scan the buffer and decorate every table block: the header row (a cells row directly
--- above the block's first separator position, i.e. row 1 when row 2 is a separator) gets
--- LvimTableHeader, every separator row LvimTableSeparator. Extmarks track edits between
--- refreshes, so the scan only needs to run when we realign anyway.
---@param buf integer
---@return nil
local function decorate(buf)
    api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
    if not config.decorations then
        return
    end
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local i = 1
    while i <= #lines do
        if detect.is_row(lines[i]) then
            local s = i
            while i <= #lines and detect.is_row(lines[i]) do
                i = i + 1
            end
            local e = i - 1
            if e > s and detect.is_separator(lines[s + 1]) and not detect.is_separator(lines[s]) then
                api.nvim_buf_set_extmark(buf, state.ns, s - 1, 0, {
                    end_col = #lines[s],
                    hl_group = "LvimTableHeader",
                    priority = 110,
                })
            end
            for l = s, e do
                if detect.is_separator(lines[l]) then
                    api.nvim_buf_set_extmark(buf, state.ns, l - 1, 0, {
                        end_col = #lines[l],
                        hl_group = "LvimTableSeparator",
                        priority = 110,
                    })
                end
            end
        else
            i = i + 1
        end
    end
end

-- ─── the realign trigger ───────────────────────────────────────────────────────

--- Realign the block under the cursor NOW, guarded by the snapshot: when the block's text
--- equals what the last realign produced, nothing changed and the whole parse is skipped —
--- this is also what stops the realign→TextChanged→realign loop after our own rewrite.
---@param buf integer
---@return nil
local function realign_now(buf)
    local st = state.buffers[buf]
    if not st or not api.nvim_buf_is_valid(buf) or api.nvim_get_current_buf() ~= buf then
        return
    end
    if api.nvim_get_mode().mode:find("^i") then
        return -- mid-insert (a late timer): InsertLeave will realign
    end
    local lnum = api.nvim_win_get_cursor(0)[1]
    local srow, erow = detect.block(buf, lnum)
    local changed = false
    if srow and erow then
        local old = api.nvim_buf_get_lines(buf, srow - 1, erow, false)
        if table.concat(old, "\n") ~= st.snapshot then
            local new = fmt.align(old, { syntax = fmt.syntax_for(buf), padding = config.padding })
            changed = fmt.write(buf, srow, old, new)
            st.snapshot = table.concat(new, "\n")
        end
    end
    -- Only rescan/repaint the whole buffer when the realign ACTUALLY rewrote something. The initial
    -- decoration (M.enable) and post-op decorations call decorate() themselves, so a no-op
    -- InsertLeave/TextChanged (snapshot match, or cursor not in a table) skips the O(N) namespace
    -- rebuild — which is exactly what the module header promised ("the scan runs when we realign").
    if changed then
        decorate(buf)
    end
end

--- Debounced realign: the TextChanged burst (a put, a repeat, a plugin edit) coalesces into
--- one pass `config.realign.debounce` ms after the last event.
---@param buf integer
---@return nil
local function schedule_realign(buf)
    local st = state.buffers[buf]
    if not st then
        return
    end
    if st.timer then
        st.timer:stop()
    else
        st.timer = uv.new_timer()
    end
    st.timer:start(
        config.realign.debounce,
        0,
        vim.schedule_wrap(function()
            realign_now(buf)
        end)
    )
end

-- ─── insert-mode conveniences ──────────────────────────────────────────────────

--- Replace the freshly typed "||" on `lnum` with a separator row matching the table ABOVE,
--- realign the block and leave the cursor at the line's end (still in insert). Runs scheduled
--- (after the second `|` was inserted); the line is RE-CHECKED against the committed text
--- first, so a stale decision can never eat real content.
---@param buf integer
---@param lnum integer
---@return nil
local function expand_separator(buf, lnum)
    if not (api.nvim_buf_is_valid(buf) and state.buffers[buf]) then
        return
    end
    local line = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
    if not (line and line:match("^%s*||$")) then
        return
    end
    local srow = detect.block(buf, lnum - 1)
    if not srow or srow >= lnum then
        return
    end
    local above = api.nvim_buf_get_lines(buf, srow - 1, lnum - 1, false)
    local parsed = detect.parse(above)
    if parsed.ncols == 0 then
        return
    end
    local indent = above[#above]:match("^%s*") or ""
    -- Minimal markers only — the realign right below stretches them to the column widths.
    api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { indent .. "|" .. string.rep("---|", parsed.ncols) })
    fmt.realign(buf, lnum)
    local new = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
    pcall(api.nvim_win_set_cursor, 0, { lnum, #new })
end

--- Continue the table below the cursor row and put the cursor in the new row's first cell.
--- Three shapes, by context: an ALL-EMPTY row ENDS the table (the row becomes a blank line);
--- a one-row block (the just-typed header) gets the SEPARATOR row plus an empty row in one go;
--- anything else gets a plain aligned empty row. Called SYNCHRONOUSLY from the <CR> callback,
--- so keys typed right after the <CR> land inside the new row even in a burst/macro.
---@param buf integer
---@return nil
local function continue_row(buf)
    if not (api.nvim_buf_is_valid(buf) and state.buffers[buf]) then
        return
    end
    local pos = api.nvim_win_get_cursor(0)
    local lnum = pos[1]
    local line = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
    if not detect.is_row(line) then
        return
    end

    if not detect.is_separator(line) then
        local _, cells = detect.split_cells(line)
        local empty = #cells > 0
        for _, cell in ipairs(cells) do
            if cell.text ~= "" then
                empty = false
                break
            end
        end
        if empty then
            api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { "" })
            pcall(api.nvim_win_set_cursor, 0, { lnum, 0 })
            return
        end
    end

    local srow, erow = detect.block(buf, lnum)
    if not srow or not erow then
        return
    end
    local lines = api.nvim_buf_get_lines(buf, srow - 1, erow, false)
    local parsed = detect.parse(lines)
    local at = lnum - srow + 2
    local indent = parsed.rows[at - 1].indent
    -- <CR> at the end of a ONE-row block finishes a header: separator + empty row in one go.
    if #parsed.rows == 1 and parsed.rows[1].kind == "cells" then
        table.insert(parsed.rows, { kind = "sep", indent = indent, cells = {}, align = {} })
        at = 3
    end
    local cells = {}
    for i = 1, parsed.ncols do
        cells[i] = { text = "", s = 0, e = 0, rs = 0, re = 0 }
    end
    table.insert(parsed.rows, at, { kind = "cells", indent = indent, cells = cells, align = {} })
    local new = fmt.render(parsed, { syntax = fmt.syntax_for(buf), padding = config.padding })
    api.nvim_buf_set_lines(buf, srow - 1, erow, false, new)
    local _, ncells = detect.split_cells(new[at])
    if ncells[1] then
        -- An empty cell's `s` sits right after the pipe; typing should start after the padding.
        pcall(api.nvim_win_set_cursor, 0, { srow + at - 1, ncells[1].rs + config.padding })
    end
end

--- The InsertCharPre watcher for the `||` idiom: when the `|` about to be inserted completes a
--- lone `||` directly under a table row, schedule the separator expansion (the pipe itself
--- still inserts — the scheduled rewrite replaces the whole line, so nothing needs
--- suppressing). InsertCharPre — not an expr `|` mapping — on purpose: Vim's insert fast path
--- BATCHES typed characters, so during a burst (macro replay, fed keys) an expr mapping reads a
--- line the earlier keystrokes are not committed to yet; InsertCharPre fires per actually
--- inserted character with the buffer up to date (and its presence disables the batching).
---@param buf integer
---@return nil
local function on_insert_char(buf)
    if vim.v.char ~= "|" or not config.expand_separator then
        return
    end
    local pos = api.nvim_win_get_cursor(0)
    local line = api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1]
    if pos[1] > 1 and line:match("^%s*|$") and pos[2] == #line then
        local prev = api.nvim_buf_get_lines(buf, pos[1] - 2, pos[1] - 1, false)[1]
        if detect.is_row(prev) and not detect.is_separator(prev) then
            vim.schedule(function()
                expand_separator(buf, pos[1])
            end)
        end
    end
end

--- Re-play the <CR> that table mode shadowed: run the captured prior mapping faithfully, or
--- feed a plain noremap <CR>. Every fed key uses the "i" (insert BEFORE typeahead) flag so the
--- newline lands in the right order even when more keys are already queued behind the <CR>.
---@param prior table?  the vim.fn.maparg() dict captured at enable time
---@return nil
local function cr_fallback(prior)
    if prior and prior.expr == 1 and prior.callback then
        local ok, keys = pcall(prior.callback)
        if ok and type(keys) == "string" and keys ~= "" then
            if prior.replace_keycodes == 1 then
                keys = api.nvim_replace_termcodes(keys, true, true, true)
            end
            api.nvim_feedkeys(keys, "in", false)
        end
        return
    end
    if prior and prior.expr == 1 and prior.rhs and prior.rhs ~= "" then
        local ok, keys = pcall(api.nvim_eval, prior.rhs)
        if ok and type(keys) == "string" and keys ~= "" then
            api.nvim_feedkeys(keys, "in", false)
        end
        return
    end
    if prior and prior.callback then
        -- A non-expr Lua mapping: we are in an equivalent mapping context — call it directly.
        pcall(prior.callback)
        return
    end
    if prior and prior.rhs and prior.rhs ~= "" then
        local keys = api.nvim_replace_termcodes(prior.rhs, true, true, true)
        api.nvim_feedkeys(keys, prior.noremap == 1 and "in" or "im", false)
        return
    end
    api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, true, true), "in", false)
end

--- The <CR> insert mapping — a NON-expr callback on purpose: a callback mapping runs without
--- textlock, so the row continuation edits the buffer SYNCHRONOUSLY and keys queued behind the
--- <CR> (a burst, a macro) are processed after the new row exists, in their intended cells.
--- Outside a table row (or with the pum open) it falls through to whatever <CR> did before.
---@param buf integer
---@return fun()
local function cr_handler(buf)
    return function()
        local st = state.buffers[buf]
        if config.continue_rows and vim.fn.pumvisible() == 0 then
            local pos = api.nvim_win_get_cursor(0)
            local line = api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1]
            if detect.is_row(line) then
                continue_row(buf)
                return
            end
        end
        cr_fallback(st and st.prior_cr)
    end
end

-- ─── mode lifecycle ────────────────────────────────────────────────────────────

--- Set a buffer-local mapping and remember it for teardown.
---@param buf integer
---@param mode string|string[]
---@param lhs string
---@param rhs string|fun()
---@param desc string
---@param opts table?
---@return nil
local function bufmap(buf, mode, lhs, rhs, desc, opts)
    opts = opts or {}
    opts.buffer = buf
    opts.desc = desc
    vim.keymap.set(mode, lhs, rhs, opts)
    local st = state.buffers[buf]
    st.maps[#st.maps + 1] = { mode = mode, lhs = lhs }
end

--- Normalize a buffer argument (nil / 0 → the current buffer).
---@param buf integer?
---@return integer
local function bufnr(buf)
    if buf and buf ~= 0 then
        return buf
    end
    return api.nvim_get_current_buf()
end

--- Whether table mode is on for a buffer (statusline components read this).
---@param buf integer?  defaults to the current buffer
---@return boolean
function M.is_active(buf)
    return state.buffers[bufnr(buf)] ~= nil
end

--- Turn table mode ON for a buffer: autocmds (realign triggers, chip, teardown), the
--- insert-mode conveniences, cell text objects/motions, optionally the default op keys — and
--- one immediate realign of the block under the cursor as feedback.
--- Realign EVERY table block in a buffer (the on-save pass): walk the lines, realign each
--- block once, hop over it.
---@param buf integer
---@return nil
local function realign_all(buf)
    local total = api.nvim_buf_get_lines(buf, 0, -1, false)
    local lnum = 1
    while lnum <= #total do
        if detect.is_row(total[lnum]) then
            local srow, erow = detect.block(buf, lnum)
            if srow ~= nil then
                fmt.realign(buf, srow)
                lnum = (erow or lnum) + 1
            else
                lnum = lnum + 1
            end
        else
            lnum = lnum + 1
        end
    end
end

---@param buf integer?  defaults to the current buffer
---@return nil
function M.enable(buf)
    buf = bufnr(buf)
    if state.buffers[buf] or not api.nvim_buf_is_valid(buf) then
        return
    end

    -- Capture what <CR> resolves to BEFORE our buffer-local map shadows it (buffer-local maps
    -- win maparg lookups, so this must happen first). maparg is evaluated in the CURRENT buffer's
    -- context, so run it inside the TARGET buffer — otherwise M.enable(other_buf) records the
    -- current buffer's <CR> (possibly lvim-table's own handler) as the prior mapping.
    local prior_cr = nil
    local m = {}
    api.nvim_buf_call(buf, function()
        m = vim.fn.maparg("<CR>", "i", false, true)
    end)
    if not vim.tbl_isempty(m) then
        prior_cr = m
    end

    local group = api.nvim_create_augroup("lvim-table-b" .. buf, { clear = true })
    state.buffers[buf] = { augroup = group, timer = nil, snapshot = nil, prior_cr = prior_cr, maps = {} }
    -- The persistent-state seam for statusline segments: fire on both transitions, so a segment
    -- keyed on `User LvimTableMode` repaints exactly when `is_active()` changes.
    api.nvim_exec_autocmds("User", { pattern = "LvimTableMode", modeline = false })

    api.nvim_create_autocmd("InsertLeave", {
        group = group,
        buffer = buf,
        desc = "lvim-table: realign on leaving insert",
        callback = function()
            if config.realign.insert_leave then
                realign_now(buf)
            end
        end,
    })
    api.nvim_create_autocmd("TextChanged", {
        group = group,
        buffer = buf,
        desc = "lvim-table: debounced realign on normal-mode change",
        callback = function()
            if config.realign.text_changed then
                schedule_realign(buf)
            end
        end,
    })
    api.nvim_create_autocmd("BufWritePre", {
        group = group,
        buffer = buf,
        desc = "lvim-table: realign every table block on save",
        callback = function()
            if config.realign.on_save then
                realign_all(buf)
                decorate(buf)
            end
        end,
    })
    api.nvim_create_autocmd("BufEnter", {
        group = group,
        buffer = buf,
        desc = "lvim-table: show the hud chip",
        callback = function()
            chip(true)
        end,
    })
    api.nvim_create_autocmd("BufLeave", {
        group = group,
        buffer = buf,
        desc = "lvim-table: hide the hud chip",
        callback = function()
            chip(false)
        end,
    })
    api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        buffer = buf,
        desc = "lvim-table: tear the mode down with the buffer",
        callback = function()
            M.disable(buf)
        end,
    })
    api.nvim_create_autocmd("InsertCharPre", {
        group = group,
        buffer = buf,
        desc = "lvim-table: || expands to a separator row",
        callback = function()
            on_insert_char(buf)
        end,
    })

    bufmap(buf, "i", "<CR>", cr_handler(buf), "lvim-table: continue row")

    local to = config.textobj
    if to.cell_inner then
        bufmap(buf, { "x", "o" }, to.cell_inner, function()
            textobj.select_cell(true)
        end, "lvim-table: inner cell")
    end
    if to.cell_around then
        bufmap(buf, { "x", "o" }, to.cell_around, function()
            textobj.select_cell(false)
        end, "lvim-table: around cell")
    end
    if to.next_cell then
        bufmap(buf, { "n", "x", "o" }, to.next_cell, function()
            textobj.move_cell(1)
        end, "lvim-table: next cell")
    end
    if to.prev_cell then
        bufmap(buf, { "n", "x", "o" }, to.prev_cell, function()
            textobj.move_cell(-1)
        end, "lvim-table: previous cell")
    end
    if to.cell_up then
        bufmap(buf, { "n", "x", "o" }, to.cell_up, function()
            textobj.move_row(-1)
        end, "lvim-table: cell above")
    end
    if to.cell_down then
        bufmap(buf, { "n", "x", "o" }, to.cell_down, function()
            textobj.move_row(1)
        end, "lvim-table: cell below")
    end

    if config.map_default_keys then
        local plug = {
            realign = "<Plug>(LvimTableRealign)",
            row_insert = "<Plug>(LvimTableRowInsert)",
            row_insert_above = "<Plug>(LvimTableRowInsertAbove)",
            row_delete = "<Plug>(LvimTableRowDelete)",
            col_insert = "<Plug>(LvimTableColInsert)",
            col_insert_before = "<Plug>(LvimTableColInsertBefore)",
            col_delete = "<Plug>(LvimTableColDelete)",
            row_up = "<Plug>(LvimTableRowUp)",
            row_down = "<Plug>(LvimTableRowDown)",
            col_left = "<Plug>(LvimTableColLeft)",
            col_right = "<Plug>(LvimTableColRight)",
            eval = "<Plug>(LvimTableEval)",
        }
        for name, rhs in pairs(plug) do
            local lhs = config.keys[name]
            if lhs and lhs ~= "" then
                bufmap(buf, "n", lhs, rhs, "lvim-table: " .. name:gsub("_", " "), { remap = true })
            end
        end
    end

    if api.nvim_get_current_buf() == buf then
        chip(true)
        realign_now(buf)
    else
        decorate(buf)
    end
end

--- Turn table mode OFF for a buffer: autocmds, mappings, decorations, timer and chip all go.
---@param buf integer?  defaults to the current buffer
---@return nil
function M.disable(buf)
    buf = bufnr(buf)
    local st = state.buffers[buf]
    if not st then
        return
    end
    state.buffers[buf] = nil
    pcall(api.nvim_del_augroup_by_id, st.augroup)
    if st.timer then
        st.timer:stop()
        st.timer:close()
    end
    if api.nvim_buf_is_valid(buf) then
        for _, mp in ipairs(st.maps) do
            pcall(vim.keymap.del, mp.mode, mp.lhs, { buffer = buf })
        end
        api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
    end
    -- Only clear the HUD chip if we are disabling the CURRENT buffer. Disabling a BACKGROUND buffer
    -- (e.g. :bdelete of a hidden table-mode buffer) must not wipe the chip of the buffer still shown.
    if api.nvim_get_current_buf() == buf then
        chip(false)
    end
    api.nvim_exec_autocmds("User", { pattern = "LvimTableMode", modeline = false })
end

--- Toggle table mode for a buffer.
---@param buf integer?  defaults to the current buffer
---@return boolean active  the NEW state
function M.toggle(buf)
    buf = bufnr(buf)
    if state.buffers[buf] then
        M.disable(buf)
        return false
    end
    M.enable(buf)
    return true
end

--- Realign the table block under the cursor once (works with or without table mode).
---@return nil
function M.realign()
    local buf = api.nvim_get_current_buf()
    if not fmt.realign(buf, api.nvim_win_get_cursor(0)[1]) then
        vim.notify("lvim-table: no table under the cursor", vim.log.levels.WARN)
    elseif state.buffers[buf] then
        decorate(buf)
    end
end

-- ─── command + registration ────────────────────────────────────────────────────

---@type string[]
local SUBCOMMANDS = {
    "toggle",
    "on",
    "off",
    "format",
    "from",
    "to",
    "eval",
    "row-insert",
    "row-insert-above",
    "row-delete",
    "col-insert",
    "col-insert-before",
    "col-delete",
    "row-up",
    "row-down",
    "col-left",
    "col-right",
}

--- Handle :LvimTable <sub> [...].
---@param cmd table  the user-command callback dict
---@return nil
local function command(cmd)
    local sub = cmd.fargs[1] or "toggle"
    -- Everything after the subcommand, spaces preserved (a delimiter like ", " must survive).
    local rest = cmd.args:match("^%s*%S+%s+(.-)%s*$")
    local buf = api.nvim_get_current_buf()

    if sub == "toggle" then
        vim.notify("lvim-table: " .. (M.toggle(buf) and "on" or "off"))
    elseif sub == "on" or sub == "enable" then
        M.enable(buf)
        vim.notify("lvim-table: on")
    elseif sub == "off" or sub == "disable" then
        M.disable(buf)
        vim.notify("lvim-table: off")
    elseif sub == "format" or sub == "align" then
        M.realign()
    elseif sub == "from" then
        if cmd.range == 0 then
            vim.notify("lvim-table: from needs a range (:'<,'>LvimTable from [pattern])", vim.log.levels.WARN)
            return
        end
        tableize.from(buf, cmd.line1, cmd.line2, rest)
        if state.buffers[buf] then
            decorate(buf)
        end
    elseif sub == "to" then
        if cmd.range == 0 then
            vim.notify("lvim-table: to needs a range (:'<,'>LvimTable to [separator])", vim.log.levels.WARN)
            return
        end
        tableize.to(buf, cmd.line1, cmd.line2, rest)
        if state.buffers[buf] then
            decorate(buf)
        end
    elseif sub == "eval" then
        if formula.eval(buf, api.nvim_win_get_cursor(0)[1]) and state.buffers[buf] then
            decorate(buf)
        end
    elseif sub == "row-insert" then
        ops.row_insert()
    elseif sub == "row-insert-above" then
        ops.row_insert_above()
    elseif sub == "row-delete" then
        ops.row_delete()
    elseif sub == "col-insert" then
        ops.col_insert()
    elseif sub == "col-insert-before" then
        ops.col_insert_before()
    elseif sub == "col-delete" then
        ops.col_delete()
    elseif sub == "row-up" then
        ops.row_up()
    elseif sub == "row-down" then
        ops.row_down()
    elseif sub == "col-left" then
        ops.col_left()
    elseif sub == "col-right" then
        ops.col_right()
    else
        vim.notify("lvim-table: unknown subcommand " .. sub, vim.log.levels.WARN)
    end
end

--- Merge user options into the live config, bind the self-theming decoration groups, register
--- the <Plug> mappings and :LvimTable. Table mode itself stays per-buffer (:LvimTable toggle).
---@param opts LvimTableConfig?
---@return nil
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    if registered then
        return
    end
    registered = true

    hl.setup()
    hl.bind(highlights.build)

    local plugs = {
        ["<Plug>(LvimTableRealign)"] = ops.realign,
        ["<Plug>(LvimTableRowInsert)"] = ops.row_insert,
        ["<Plug>(LvimTableRowInsertAbove)"] = ops.row_insert_above,
        ["<Plug>(LvimTableRowDelete)"] = ops.row_delete,
        ["<Plug>(LvimTableColInsert)"] = ops.col_insert,
        ["<Plug>(LvimTableColInsertBefore)"] = ops.col_insert_before,
        ["<Plug>(LvimTableColDelete)"] = ops.col_delete,
        ["<Plug>(LvimTableColLeft)"] = ops.col_left,
        ["<Plug>(LvimTableColRight)"] = ops.col_right,
        ["<Plug>(LvimTableRowUp)"] = ops.row_up,
        ["<Plug>(LvimTableRowDown)"] = ops.row_down,
        ["<Plug>(LvimTableEval)"] = function()
            if formula.eval(api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1]) then
                local buf = api.nvim_get_current_buf()
                if state.buffers[buf] then
                    decorate(buf)
                end
            end
        end,
    }
    for lhs, rhs in pairs(plugs) do
        vim.keymap.set("n", lhs, rhs, { desc = "lvim-table: " .. lhs:match("%((.-)%)") })
    end

    api.nvim_create_user_command("LvimTable", command, {
        nargs = "*",
        range = true,
        complete = function(arglead, line)
            if line:match("^%s*%S+%s+%S+%s") then
                return {} -- only the subcommand completes; the rest is free-form
            end
            return vim.tbl_filter(function(s)
                return vim.startswith(s, arglead)
            end, SUBCOMMANDS)
        end,
        desc = "lvim-table: table mode, formatting, row/column ops, tableize, formulas",
    })
end

return M
