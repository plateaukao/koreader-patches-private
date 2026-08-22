-- Headless smoke test for ../2-selection-highlight-style.lua.
--
-- Stubs the four KOReader modules the patch requires, loads the patch, then
-- replays the paging (temp boxes) and crengine (tracked xpointer range) paths,
-- asserting what reaches ReaderView:drawHighlightRect() and that the crengine
-- calls are made with native selection drawing suppressed.
--
-- Run:  luajit test/test_selection_highlight_style.lua

local repo = (arg and arg[0] or "test/x.lua"):gsub("[/\\]?test[/\\][^/\\]*$", "")
if repo == "" then repo = "." end

-- ── stubs ────────────────────────────────────────────────────────────────────
local drawn = {}
local ReaderView = {}
function ReaderView:drawHighlightRect(bb, x, y, rect, drawer, color, mark)
    -- emulate upstream's "selection opacity" branch so we can assert temp was blanked
    local temp_active = self.highlight.temp and next(self.highlight.temp) and true or false
    table.insert(drawn, { rect = rect, drawer = drawer, color = color, mark = mark, temp_active = temp_active })
end
function ReaderView:pageToScreenTransform(page, rect) return rect end
function ReaderView:drawTempHighlight() error("stock drawTempHighlight should be replaced") end
local paintTo_calls = 0
function ReaderView:paintTo(bb, x, y)
    paintTo_calls = paintTo_calls + 1
    if self.highlight.temp and next(self.highlight.temp) then self:drawTempHighlight(bb, x, y) end
    self.dialog.dithered = nil
end

local ReaderHighlight = {}
function ReaderHighlight:extendSelection()
    self.ui.document:getTextFromXPointers("p0", "p9", true) -- native draw, as upstream does
    self.selected_text = { pos0 = "p0", pos1 = "p9", text = "ext" }
end

local cre_calls = {}
local CreDocument = {}
function CreDocument:getWordFromPosition(pos, do_not_draw)
    table.insert(cre_calls, { "word", do_not_draw })
    return { word = "w", pos0 = "xp.w0", pos1 = "xp.w1", sbox = { x = 1, y = 1, w = 5, h = 5 } }
end
function CreDocument:getTextFromPositions(pos0, pos1, do_not_draw)
    table.insert(cre_calls, { "text", do_not_draw })
    if pos1 and pos1.miss then return nil end
    return { text = "t", pos0 = "xp.t0", pos1 = "xp.t1", sboxes = {} }
end
function CreDocument:getTextFromXPointers(p0, p1, draw)
    table.insert(cre_calls, { "xp", draw })
    return "ext"
end
function CreDocument:clearSelection() table.insert(cre_calls, { "clear" }) end
function CreDocument:getScreenBoxesFromPositions(p0, p1, seg)
    table.insert(cre_calls, { "boxes", p0, p1, seg })
    return { { x = 0, y = 0, w = 10, h = 10 }, { x = 0, y = 10, w = 3, h = 0 } }
end
function CreDocument:getCurrentPos() return 100 end
function CreDocument:getPosFromXPointer(xp) return xp == "far" and 99999 or 150 end
function CreDocument:getVisiblePageCount() return 1 end

local colors_seen = {}
local Blitbuffer = {
    colorFromName = function(name)
        if name == "yellow" then return { name = "yellow" } end
        return nil
    end,
    isColor8 = function(c) return c == nil or c.gray == true end,
}
local logger = { warn = function(...) print("WARN", ...) end, dbg = function() end }

package.preload["apps/reader/modules/readerview"] = function() return ReaderView end
package.preload["apps/reader/modules/readerhighlight"] = function() return ReaderHighlight end
package.preload["document/credocument"] = function() return CreDocument end
package.preload["ffi/blitbuffer"] = function() return Blitbuffer end
package.preload["logger"] = function() return logger end

assert(loadfile(repo .. "/2-selection-highlight-style.lua"))()

local function mkview(opts)
    local v = setmetatable({
        highlight = { temp = {}, saved_drawer = opts.drawer, saved_color = opts.color, temp_drawer = "invert" },
        ui = { paging = opts.paging, rolling = not opts.paging, dimen = { h = 800 } },
        dialog = {},
        view_mode = "page",
    }, { __index = ReaderView })
    v.document = setmetatable({}, { __index = CreDocument })
    return v
end

-- ── 1. paging: temp boxes restyled with saved drawer + color ────────────────
do
    drawn = {}
    local v = mkview{ paging = true, drawer = "underscore", color = "yellow" }
    local box = { x = 5, y = 5, w = 50, h = 12 }
    v.highlight.temp[3] = { box }
    v:paintTo({}, 0, 0)
    assert(#drawn == 1, "one box drawn")
    assert(drawn[1].rect == box and drawn[1].drawer == "underscore", "saved drawer used")
    assert(drawn[1].color and drawn[1].color.name == "yellow", "saved color used")
    assert(drawn[1].temp_active == false, "temp blanked during draw (regular highlight opacity)")
    assert(v.highlight.temp[3] == nil or v.highlight.temp[3][1] == box, "temp restored")
    assert(next(v.highlight.temp) ~= nil, "temp table restored after draw")
    assert(v.dialog.dithered == true, "color selection marks the refresh as dithered")
end

-- 2. paging, gray/non-color device: no color object, style still honoured;
--    "invert" default style never gets a color
do
    drawn = {}
    local v = mkview{ paging = true, drawer = "lighten", color = "gray" }
    v.highlight.temp[1] = { { x = 0, y = 0, w = 1, h = 1 } }
    v:paintTo({}, 0, 0)
    assert(drawn[1].drawer == "lighten" and drawn[1].color == nil, "gray -> nil color")
    assert(not v.dialog.dithered, "gray selection is not colorful")

    drawn = {}
    v = mkview{ paging = true, drawer = "invert", color = "yellow" }
    v.highlight.temp[1] = { { x = 0, y = 0, w = 1, h = 1 } }
    v:paintTo({}, 0, 0)
    assert(drawn[1].drawer == "invert" and drawn[1].color == nil, "invert style gets no color")
end

-- ── 3. crengine: native drawing suppressed, range tracked and painted ───────
do
    drawn = {}; cre_calls = {}
    local v = mkview{ paging = false, drawer = "strikeout", color = "yellow" }
    local doc = v.document

    -- onHold: getWordFromPosition without the flag -> patch forces do_not_draw=true
    local w = doc:getWordFromPosition({ x = 1, y = 1 })
    assert(w.word == "w", "result passed through")
    assert(cre_calls[1][1] == "word" and cre_calls[1][2] == true, "native word selection suppressed")
    assert(doc._selhl_range[1] == "xp.w0" and doc._selhl_range[2] == "xp.w1", "word range tracked")

    -- paint: range drawn with saved style/color via getScreenBoxesFromPositions
    v:paintTo({}, 0, 0)
    assert(#drawn == 1, "zero-height segments skipped, one box drawn; got " .. #drawn)
    assert(drawn[1].drawer == "strikeout" and drawn[1].color.name == "yellow", "style+color on crengine")
    local last = cre_calls[#cre_calls - 0]
    assert(last[1] == "boxes" and last[2] == "xp.w0" and last[3] == "xp.w1" and last[4] == true, "segments fetched for tracked range")

    -- onHoldPan: getTextFromPositions updates the range; a miss keeps the old one
    doc:getTextFromPositions({ x = 1, y = 1 }, { x = 9, y = 9 })
    assert(doc._selhl_range[1] == "xp.t0" and doc._selhl_range[2] == "xp.t1", "pan range tracked")
    doc:getTextFromPositions({ x = 1, y = 1 }, { miss = true })
    assert(doc._selhl_range[1] == "xp.t0", "miss keeps previous range (mirrors crengine)")

    -- caller that explicitly asked for no drawing (dictionary/keyselection) must not track
    doc._selhl_range = nil
    doc:getWordFromPosition({ x = 1, y = 1 }, true)
    assert(doc._selhl_range == nil, "do_not_draw callers are not tracked")

    -- temp boxes on a crengine doc (stylus plugin) are not painted twice
    doc._selhl_range = { "a", "b" }
    drawn = {}
    v.highlight.temp[1] = { { x = 0, y = 0, w = 1, h = 1 } }
    v:paintTo({}, 0, 0)
    assert(#drawn == 1, "tracked range drawn once, temp boxes skipped on crengine; got " .. #drawn)
    v.highlight.temp = {}

    -- off-screen range: no expensive box lookup, nothing drawn
    doc._selhl_range = { "far", "far" }
    drawn = {}; cre_calls = {}
    v:paintTo({}, 0, 0)
    assert(#drawn == 0 and #cre_calls == 0, "off-screen range skipped cheaply")

    -- clearSelection drops the tracked range and still reaches crengine
    doc._selhl_range = { "a", "b" }
    cre_calls = {}
    doc:clearSelection()
    assert(doc._selhl_range == nil and cre_calls[1][1] == "clear", "clearSelection untracks + forwards")
end

-- ── 4. extendSelection: native draw dropped, extended range tracked ─────────
do
    cre_calls = {}
    local v = mkview{ paging = false, drawer = "lighten", color = "yellow" }
    local doc = v.document
    doc._document = { clearSelection = function() table.insert(cre_calls, { "raw-clear" }) end }
    local rh = setmetatable({ ui = { rolling = true, document = doc } }, { __index = ReaderHighlight })
    rh:extendSelection()
    assert(cre_calls[1][1] == "xp" and cre_calls[2][1] == "raw-clear", "native selection cleared after extend")
    assert(doc._selhl_range[1] == "p0" and doc._selhl_range[2] == "p9", "extended range tracked")
end

-- 5. idempotent: loading twice doesn't double-wrap
do
    local before_paint = ReaderView.paintTo
    assert(loadfile(repo .. "/2-selection-highlight-style.lua"))()
    assert(ReaderView.paintTo == before_paint, "second load is a no-op")
end

print("OK: selection-highlight-style smoke tests passed")
