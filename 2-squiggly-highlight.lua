-- patches/2-squiggly-highlight.lua  — adds a "Squiggly" wavy-underline highlight style
local userpatch       = require("userpatch")
local ReaderView      = require("apps/reader/modules/readerview")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local Blitbuffer      = require("ffi/blitbuffer")
local Size            = require("ui/size")
local _               = require("gettext")

-- 1. Register the new style in the selectable list (shared upvalue table)
local hl_styles = userpatch.getUpValue(ReaderHighlight.addToMainMenu, "highlight_style")
if hl_styles then
    local found
    for _, v in ipairs(hl_styles) do if v[2] == "squiggly" then found = true break end end
    if not found then table.insert(hl_styles, { _("Squiggly"), "squiggly" }) end
end

-- 2. Render it
local orig_drawHighlightRect = ReaderView.drawHighlightRect
function ReaderView:drawHighlightRect(bb, _x, _y, rect, drawer, color, draw_note_mark)
    if drawer ~= "squiggly" then
        return orig_drawHighlightRect(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
    end
    -- Let the original handle note marks (it draws no line for an unknown drawer)
    orig_drawHighlightRect(self, bb, _x, _y, rect, drawer, color, draw_note_mark)

    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    local c     = color or Blitbuffer.COLOR_GRAY_4
    local is8   = Blitbuffer.isColor8(c)
    local thick = Size.line.thick
    local amp   = math.max(2, math.floor(thick + 0.5))   -- wave amplitude (px)
    local wlen  = amp * 6                                 -- wavelength (px)
    local mid   = y + h - 1 - amp                         -- vertical center of the wave
    local tau   = 2 * math.pi
    for i = 0, w - 1 do
        local py = mid + math.floor(amp * math.sin(tau * i / wlen) + 0.5)
        if is8 then
            bb:paintRect(x + i, py, 1, thick, c)
        else
            bb:paintRectRGB32(x + i, py, 1, thick, c)
        end
    end
end
