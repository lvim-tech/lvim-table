-- Aligning a table is pure: lines in, lines out. So the properties that matter can be stated
-- exactly.
--
-- The one that bites in practice is DISPLAY width: a column holding `日本語` is six cells wide and
-- nine bytes long, and a formatter that pads by bytes leaves the pipes of every later row ragged.
-- The others are that the alignment markers follow the separator row, and that aligning an
-- already-aligned table changes nothing — the property the on-save realign depends on, since
-- otherwise every save would rewrite the block and spend an undo step.

local fmt = require("lvim-table.fmt")

local OPTS = { padding = 1, syntax = "markdown" }

---@param lines string[]
---@return string[]
local function align(lines)
    return fmt.align(lines, OPTS)
end

---@param line string
---@return integer
local function width(line)
    return vim.fn.strdisplaywidth(line)
end

describe("lvim-table.fmt.align: the shape of the result")

it("pads every column to its widest cell", function()
    local out = align({
        "| a | bbbb |",
        "| --- | --- |",
        "| cccc | d |",
    })
    eq({
        "| a    | bbbb |",
        "|------|------|",
        "| cccc | d    |",
    }, out, "the separator fills its column edge to edge; the text cells carry the padding")
end)

it("writes a separator of nothing but pipes, dashes and colons", function()
    local out = align({
        "| a | b |",
        "| :-- | --: |",
        "| 1 | 2 |",
    })
    truthy(out[2]:match("^[|%-:]+$") ~= nil, "a separator with something else in it: " .. out[2])
end)

it("gives every line of a block the same display width", function()
    local out = align({
        "| one | two |",
        "|---|---|",
        "| a | bbbbbbbb |",
        "| ccccc | d |",
    })
    local w = width(out[1])
    for i, line in ipairs(out) do
        eq(w, width(line), ("line %d: %q"):format(i, line))
    end
end)

it("measures DISPLAY cells, not bytes", function()
    -- `日本語` is 9 bytes and 6 cells; `abcdef` is 6 bytes and 6 cells. Both are the same width
    -- on screen, so both rows must come out identical in length.
    local out = align({
        "| 日本語 | x |",
        "| --- | --- |",
        "| abcdef | y |",
    })
    eq(width(out[1]), width(out[3]), ("%q vs %q"):format(out[1], out[3]))
    eq(width(out[1]), width(out[2]), "the separator too")
end)

it("handles Cyrillic, which is one cell per character but two bytes", function()
    local out = align({
        "| дясно | x |",
        "| --- | --- |",
        "| right | y |",
    })
    eq(width(out[1]), width(out[3]), ("%q vs %q"):format(out[1], out[3]))
end)

describe("lvim-table.fmt.align: alignment markers")

it("keeps left, centre and right as the separator asked", function()
    local out = align({
        "| a | b | c |",
        "| :--- | :---: | ---: |",
        "| 1 | 2 | 3 |",
    })
    truthy(out[2]:find(":%-+|") ~= nil, "a left marker survived: " .. out[2])
    truthy(out[2]:find(":%-+:") ~= nil, "a centre marker survived: " .. out[2])
    truthy(out[2]:find("%-+:|") ~= nil, "a right marker survived: " .. out[2])
end)

it("puts a right-aligned cell's content at the right edge", function()
    local out = align({
        "| head |",
        "| ---: |",
        "| x |",
    })
    truthy(out[3]:match("|%s+x |") ~= nil, "x should sit at the right: " .. out[3])
end)

it("puts a left-aligned cell's content at the left edge", function()
    local out = align({
        "| head |",
        "| :--- |",
        "| x |",
    })
    truthy(out[3]:match("| x%s+|") ~= nil, "x should sit at the left: " .. out[3])
end)

describe("lvim-table.fmt.align: stability")

it("leaves an already-aligned table untouched", function()
    -- The realign on save depends on this: a second pass that changed anything would rewrite the
    -- block and spend an undo step on every save.
    local once = align({
        "| a | bbbb |",
        "| --- | --- |",
        "| cccc | d |",
    })
    eq(once, align(once), "align is not idempotent")
end)

it("keeps the indent of the block", function()
    local out = align({
        "    | a | b |",
        "    | --- | --- |",
    })
    for _, line in ipairs(out) do
        truthy(vim.startswith(line, "    |"), "lost the indent: " .. line)
    end
end)

it("keeps an empty cell as an empty cell", function()
    local out = align({
        "| a |  |",
        "| --- | --- |",
        "|  | b |",
    })
    eq(3, #out)
    for _, line in ipairs(out) do
        eq(width(out[1]), width(line), line)
    end
end)

it("takes a row with fewer cells than the header", function()
    local out = align({
        "| a | b | c |",
        "| --- | --- | --- |",
        "| 1 |",
    })
    eq(3, #out)
    eq(width(out[1]), width(out[3]), "a short row is filled out: " .. out[3])
end)
