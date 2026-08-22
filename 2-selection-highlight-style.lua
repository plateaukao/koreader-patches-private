-- patches/2-selection-highlight-style.lua
--
-- Draw the in-progress text selection (long-press + drag) with the reader's
-- current *default highlight style and color* — exactly as the highlight will
-- look once saved — instead of KOReader's stock selection rendering (inverted
-- boxes on paged documents; crengine's flat gray fill on EPUB/reflowable ones).
--
-- How it works
--   * Paged documents (PDF/DjVu/CBZ): KOReader already keeps the drag boxes in
--     `ReaderView.highlight.temp` and paints them in `drawTempHighlight()` with
--     the hard-coded `temp_drawer` ("invert" on older builds). We override that
--     method to paint the same boxes with `highlight.saved_drawer` and
--     `highlight.saved_color` through the stock `drawHighlightRect()`, so every
--     style (lighten / underline / strikeout / invert / patched-in ones) and
--     color renders identically to a saved highlight.
--   * Reflowable documents (crengine): the engine draws the selection itself,
--     inside the page render (a solid fill behind the glyphs). We ask it NOT to
--     (the `do_not_draw_selection` flag of `getWordFromPosition` /
--     `getTextFromPositions`), remember the selected xpointer range on the
--     document object, and paint that range ourselves after `ReaderView:paintTo`
--     using `getScreenBoxesFromPositions()` — the same call the saved-highlight
--     painter uses — again through `drawHighlightRect()`.
--
-- Nothing else changes: text extraction, the highlight dialog, across-page
-- selection, search-result highlighting and the keyboard selection all keep
-- their stock behaviour.

local ReaderView      = require("apps/reader/modules/readerview")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local CreDocument     = require("document/credocument")
local Blitbuffer      = require("ffi/blitbuffer")
local logger          = require("logger")

-- Avoid double-wrapping if the patch is (re)loaded.
if ReaderView._selhl_patched then return end
ReaderView._selhl_patched = true

-- Current default highlight style and color (color nil = grayscale defaults,
-- which is what drawHighlightRect() uses for gray / unknown colors).
local function selectionStyle(view)
    local hl = view.highlight
    local drawer = hl.saved_drawer or hl.temp_drawer or "lighten"
    local color
    if drawer ~= "invert" and hl.saved_color and Blitbuffer.colorFromName then
        color = Blitbuffer.colorFromName(hl.saved_color)
    end
    return drawer, color
end

local function noteColorful(view, color)
    if color and not (Blitbuffer.isColor8 and Blitbuffer.isColor8(color)) then
        view._selhl_colorful = true
    end
end

-- Paint one screen box with the default highlight look. `highlight.temp` is
-- blanked for the call so newer builds use the regular highlight opacity
-- (`highlight_lighten_factor`) rather than the separate selection opacity.
local function paintBox(view, bb, x, y, rect, drawer, color)
    local hl = view.highlight
    local temp = hl.temp
    hl.temp = {}
    local ok, err = pcall(view.drawHighlightRect, view, bb, x, y, rect, drawer, color)
    hl.temp = temp
    if not ok then logger.warn("selection-highlight-style: drawHighlightRect failed:", err) end
end

-- ── Paged documents: restyle the stock temp boxes ─────────────────────────────

function ReaderView:drawTempHighlight(bb, x, y)
    -- On crengine docs the tracked xpointer range (below) already covers the
    -- selection; skip the boxes so nothing is painted twice.
    if self.ui and self.ui.rolling and self.document and self.document._selhl_range then
        return
    end
    local drawer, color = selectionStyle(self)
    noteColorful(self, color)
    for page, boxes in pairs(self.highlight.temp or {}) do
        for i = 1, #boxes do
            local rect = self:pageToScreenTransform(page, boxes[i])
            if rect then
                paintBox(self, bb, x, y, rect, drawer, color)
            end
        end
    end
end

-- ── Reflowable documents: paint the tracked xpointer range ────────────────────

local function rangeOnScreen(view, range)
    -- Cheap pre-check (same as drawXPointerSavedHighlight) before the costly
    -- getScreenBoxesFromPositions(): is any part of the range in the viewport?
    local doc = view.document
    if not (doc.getPosFromXPointer and doc.getCurrentPos) then return true end
    local ok, top = pcall(doc.getCurrentPos, doc)
    if not ok or type(top) ~= "number" then return true end
    local height = view.ui and view.ui.dimen and view.ui.dimen.h or 0
    if view.view_mode == "page" and doc.getVisiblePageCount and doc:getVisiblePageCount() > 1 then
        height = height * 2
    end
    local bottom = top + height
    local ok0, start_pos = pcall(doc.getPosFromXPointer, doc, range[1])
    local ok1, end_pos = pcall(doc.getPosFromXPointer, doc, range[2])
    if not (ok0 and ok1 and type(start_pos) == "number" and type(end_pos) == "number") then
        return true
    end
    return start_pos <= bottom and end_pos >= top
end

function ReaderView:selhlDrawRange(bb, x, y, range)
    if not rangeOnScreen(self, range) then return end
    local boxes = self.document:getScreenBoxesFromPositions(range[1], range[2], true)
    if not boxes then return end
    local drawer, color = selectionStyle(self)
    noteColorful(self, color)
    for _, box in ipairs(boxes) do
        if box.h ~= 0 then
            paintBox(self, bb, x, y, box, drawer, color)
        end
    end
end

local orig_paintTo = ReaderView.paintTo
function ReaderView:paintTo(bb, x, y)
    self._selhl_colorful = nil
    orig_paintTo(self, bb, x, y)
    local doc = self.document
    if self.ui and self.ui.rolling and doc and doc._selhl_range then
        local ok, err = pcall(self.selhlDrawRange, self, bb, x, y, doc._selhl_range)
        if not ok then logger.warn("selection-highlight-style: draw failed:", err) end
    end
    -- paintTo() sets dialog.dithered from the saved highlights only; keep it
    -- on when our selection is in color so the refresh is dithered too.
    if self._selhl_colorful and self.dialog then
        self.dialog.dithered = true
    end
end

-- ── crengine: suppress the native selection drawing, track the range ──────────

-- Mirrors crengine: a lookup that finds nothing leaves the previous selection
-- in place; only clearSelection() drops it.
local function track(doc, res)
    if res and res.pos0 and res.pos1 then
        doc._selhl_range = { res.pos0, res.pos1 }
    end
end

local orig_getWordFromPosition = CreDocument.getWordFromPosition
function CreDocument:getWordFromPosition(pos, do_not_draw_selection)
    local res = orig_getWordFromPosition(self, pos, true)
    if not do_not_draw_selection then track(self, res) end
    return res
end

local orig_getTextFromPositions = CreDocument.getTextFromPositions
function CreDocument:getTextFromPositions(pos0, pos1, do_not_draw_selection)
    local res = orig_getTextFromPositions(self, pos0, pos1, true)
    if not do_not_draw_selection then track(self, res) end
    return res
end

local orig_clearSelection = CreDocument.clearSelection
function CreDocument:clearSelection()
    self._selhl_range = nil
    return orig_clearSelection(self)
end

-- extendSelection() (long-press on a saved highlight, then select more text)
-- draws natively via getTextFromXPointers(pos0, pos1, true); drop that drawing
-- and track the extended range instead.
local orig_extendSelection = ReaderHighlight.extendSelection
if orig_extendSelection then
    function ReaderHighlight:extendSelection(...)
        local ret = orig_extendSelection(self, ...)
        local doc = self.ui and self.ui.document
        if self.ui and self.ui.rolling and doc and doc._document then
            doc._document:clearSelection()
            track(doc, self.selected_text)
        end
        return ret
    end
end
