--[[--
KOReader user patch: 嘸蝦米 (Boshiamy) Traditional-Chinese input method.

Drop this file *and* `boshiamy_data.lua` into your device's `koreader/patches/`
folder (both must sit side by side). After restart, enable it under:

    Settings → Keyboard → Keyboard layouts → 中文（嘸蝦米）(zh)

then switch to it from the globe key on the virtual keyboard.

The candidate table is built from a licensed boshiamy.lime export and is loaded
lazily (only when the layout is first used), so this patch costs nothing at
startup beyond registering the layout name.

Implementation notes:
- Reuses KOReader's built-in generic_ime engine (same one that drives the
  bundled pinyin/stroke keyboards), so candidate cycling, in-place hints,
  stepped backspace and the "show candidates" toggle all work for free.
- Faithful Boshiamy alphabet: a-z plus the , . [ ] ' selector keys all feed
  the IME (keys_string), so every code in the table is reachable -- including
  the kana and full-width-bracket codes. The , and . keys TAP to a composing
  code key; full-width Chinese punctuation is on their swipe directions. [ ] '
  are reached from the symbol layer / swipes (same as the stock en layout).
- Candidate bar: an extra row on top of the keyboard lists the candidates for
  the code being typed; tap one to commit it, or page with the ◀ / ▶ keys.
  The bar mirrors the IME's composing state (it reuses ime:getCandidates for
  lookups) and commits a tapped candidate through the IME's own delete helpers,
  so it stays in sync with the inline preview and ←/→ cycling. Inspired by
  QiuYukang/pinyinplus.koplugin, but it augments generic_ime rather than
  replacing it.
--]]--

local logger = require("logger")

-- Resolve this patch's own directory so we can find boshiamy_data.lua beside it.
local this_path = debug.getinfo(1, "S").source:match("^@?(.*)[/\\][^/\\]*$")
local data_file = (this_path or ".") .. "/boshiamy_data.lua"

local LANG = "zh_BS"
local LAYOUT = "boshiamy_keyboard"
local SETTING_NAME = "keyboard_boshiamy_settings"

-- 1. Display name for the menus.
local Language = require("ui/language")
Language.language_names[LANG] = "中文（嘸蝦米）"

-- 2. Register the layout so it appears in the keyboard-layouts menu and the
--    layout-specific settings submenu.
local VirtualKeyboard = require("ui/widget/virtualkeyboard")
VirtualKeyboard.lang_to_keyboard_layout[LANG] = LAYOUT
VirtualKeyboard.lang_has_submenu[LANG] = true

-- 3. Lazily provide the keyboard module under the name KOReader will require().
--    package.preload is consulted by require() before the filesystem searchers,
--    so the heavy data table is only parsed the first time the layout is opened.
package.preload["ui/data/keyboardlayouts/" .. LAYOUT] = function()
    local IME = require("ui/data/keyboardlayouts/generic_ime")
    local UIManager = require("ui/uimanager")
    local util = require("util")
    local _ = require("gettext")

    -- Base on the English QWERTY layout, like the bundled pinyin keyboard does.
    local kb = dofile("frontend/ui/data/keyboardlayouts/en_keyboard.lua")

    local code_map = dofile(data_file)
    -- show_candi controls the *inline* "[候選…]" hint. The candidate bar (below)
    -- is the primary candidate display now, so the inline hint defaults off; the
    -- layout-specific menu toggle can bring it back for those who want both.
    local settings = G_reader_settings:readSetting(SETTING_NAME, { show_candi = false })

    local ime = IME:new{
        code_map = code_map,
        -- Boshiamy's input alphabet: a-z plus the , . [ ] ' radical/selector keys.
        -- Anything in this string is consumed as a code key (fed to the lookup
        -- buffer); anything else is inserted literally.
        keys_string = "abcdefghijklmnopqrstuvwxyz,.[]'",
        partial_separators = { " " },
        show_candi_callback = function()
            return settings.show_candi
        end,
        switch_char = "→",
        switch_char_prev = "←",
    }

    -- The , and . keys must TAP to the ASCII symbol so they feed the IME as
    -- Boshiamy code keys. Full-width Chinese punctuation lives on the swipes
    -- (those glyphs aren't in keys_string, so they're inserted literally).
    kb.keys[4][3][2].alt_label = nil
    kb.keys[4][3][1].alt_label = nil
    kb.keys[3][10][2] = {
        ",",                 -- tap -> IME code key
        north = "，",
        alt_label = "，",
        northeast = "（",
        northwest = "「",
        east = "、",
        west = "《",
        south = "；",
        southeast = "【",
        southwest = "》",
    }
    kb.keys[5][3][2] = {
        ".",                 -- tap -> IME code key
        north = "。",
        alt_label = "。",
        northeast = "）",
        northwest = "」",
        east = "…",
        west = "：",
        south = "！",
        southeast = "】",
        southwest = "？",
    }
    kb.keys[1][2][3] = { alt_label = "「", north = "「", "‘" }
    kb.keys[1][3][3] = { alt_label = "」", north = "」", "’" }
    kb.keys[1][4][3] = { alt_label = "『", north = "『", "“" }
    kb.keys[1][5][3] = { alt_label = "』", north = "』", "”" }
    kb.keys[3][3][4] = "（"
    kb.keys[3][4][4] = "）"
    kb.keys[4][4][3] = "《"
    kb.keys[4][5][3] = "》"
    kb.keys[5][4].label = "空格"

    -- ── Candidate bar ────────────────────────────────────────────────────
    -- A faithful mirror of generic_ime's composing stack drives the bar. We
    -- only need the candidate *list* of the current composing unit (plus enough
    -- of the stack to track backspace across unit boundaries); candidate lookups
    -- reuse ime:getCandidates so the data is identical to the inline engine.
    local SLOTS = 8                 -- candidate keys per page (row = ◀ + 8 + ▶ = 10 units)
    local cand_keys = {}            -- references to the live candidate VirtualKey widgets
    local prev_key, next_key        -- references to the ◀ / ▶ nav VirtualKey widgets
    local current_keyboard          -- the live VirtualKeyboard while Boshiamy is shown
    local current_inputbox
    local units = {}                -- composing mirror: { {code=<str>, candi=<list>}, ... }
    local page = 1

    local function tracker_reset()
        units = {}
        page = 1
    end

    -- Candidate list of the current (last) composing unit, or nil when idle.
    local function current_candidates()
        local u = units[#units]
        return u and u.candi
    end

    -- Mirror IME:wrappedAddChars for the Boshiamy config (no wildcard / case /
    -- auto-separate). Keeps `units` tracking the same code & candidate list the
    -- inline engine is composing.
    local function tracker_add(char)
        if char == ime.switch_char or char == ime.switch_char_prev then
            return -- cycling only moves the selection; the candidate list is unchanged
        end
        if char == ime.separator
            or (#units > 0 and util.arrayContains(ime.partial_separators, char)) then
            tracker_reset()
            return
        end
        local key = ime.key_map[char]
        if key then
            local cur = units[#units]
            if cur then
                local grown = ime:getCandidates(cur.code .. key)
                if grown and #grown > 0 then
                    cur.code = cur.code .. key
                    cur.candi = grown
                    page = 1
                    return
                end
            end
            -- New composing unit (generic_ime pushes the key as a fresh stroke).
            local single = ime:getCandidates(key)
            if not single or #single == 0 then single = { char } end
            units[#units + 1] = { code = key, candi = single }
            page = 1
        else
            tracker_reset() -- non-code char: the IME separates and inserts it literally
        end
    end

    -- Mirror IME:wrappedDelChar's stepped deletion.
    local function tracker_del()
        local cur = units[#units]
        if cur and #cur.code > 1 then
            cur.code = cur.code:sub(1, -2)
            cur.candi = ime:getCandidates(cur.code) or {}
            page = 1
        elseif #units > 1 then
            units[#units] = nil
            page = 1
        else
            tracker_reset()
        end
    end

    local function rawAddChars(inputbox, s)
        local m = inputbox.addChars
        if type(m) == "table" and m.raw_method_call then
            m:raw_method_call(s)
        else
            inputbox:addChars(s)
        end
    end
    local function rawDelChar(inputbox)
        local m = inputbox.delChar
        if type(m) == "table" and m.raw_method_call then
            m:raw_method_call()
        else
            inputbox:delChar()
        end
    end

    -- Update a candidate/nav key's visible text and tap callback in place.
    -- (VirtualKey nesting: key[1]=FrameContainer, [1][1]=CenterContainer,
    --  [1][1][1]=the label TextWidget.)
    local function setKey(key, text, callback)
        if not key then return end
        key.label = text
        local tw = key[1] and key[1][1] and key[1][1][1]
        if tw and tw.setText then
            tw:setText(text)
        end
        key.callback = callback
    end

    local commit -- forward declaration (refresh's slot callbacks call it)

    local function refresh()
        if not cand_keys[1] then return end -- keyboard not built yet
        local list = current_candidates()
        local total = list and #list or 0
        local pages = math.max(1, math.ceil(total / SLOTS))
        if page > pages then page = pages end
        if page < 1 then page = 1 end

        setKey(prev_key, page > 1 and "◀" or " ",
            page > 1 and function() page = page - 1; refresh() end or nil)
        setKey(next_key, page < pages and "▶" or " ",
            page < pages and function() page = page + 1; refresh() end or nil)

        for i = 1, SLOTS do
            local word = list and list[(page - 1) * SLOTS + i]
            if word then
                setKey(cand_keys[i], word, function() commit(word) end)
            else
                setKey(cand_keys[i], " ", nil)
            end
        end

        if current_keyboard and current_keyboard.dimen then
            UIManager:setDirty(current_keyboard, function()
                return "ui", current_keyboard.dimen
            end)
        end
    end

    -- Commit a tapped candidate. We strip the IME's inline preview for the
    -- current unit (its "[…]" hint plus the single on-stage char) using the
    -- engine's own helpers -- which read the real composing stack, so any
    -- earlier units stay untouched -- then insert the chosen char and reset.
    commit = function(word)
        if not word or word == " " or word == "" then return end
        local inputbox = current_inputbox
        if not inputbox or #units == 0 then return end
        ime:getHintChars()              -- recompute hint_char_count / on_stage_char_count
        ime:delHintChars(inputbox)      -- delete only the inline "[…]" hint (0 when hidden)
        rawDelChar(inputbox)            -- delete the current unit's single on-stage char
        rawAddChars(inputbox, word)     -- insert the chosen candidate
        ime:clear_stack()
        tracker_reset()
        refresh()
    end

    -- ── IME glue (same structure as zh_CN_keyboard.lua) ──────────────────
    -- Each wrapper drives the inline engine, then mirrors the change into the
    -- candidate-bar tracker and re-renders the bar.
    local function wrappedAddChars(inputbox, char)
        ime:wrappedAddChars(inputbox, char)
        tracker_add(char)
        refresh()
    end
    local function wrappedDelChar(inputbox)
        ime:wrappedDelChar(inputbox)
        tracker_del()
        refresh()
    end
    local function separate(inputbox)
        ime:separate(inputbox)
        tracker_reset()
        refresh()
    end
    local function clear_stack()
        ime:clear_stack()
        tracker_reset()
        refresh()
    end
    local function wrappedRightChar(inputbox)
        if ime:hasCandidates() then
            ime:wrappedAddChars(inputbox, "→") -- cycles inline; bar list is unchanged
        else
            ime:separate(inputbox)
            inputbox.rightChar:raw_method_call()
            tracker_reset()
            refresh()
        end
    end
    local function wrappedLeftChar(inputbox)
        if ime:hasCandidates() then
            ime:wrappedAddChars(inputbox, "←")
        else
            ime:separate(inputbox)
            inputbox.leftChar:raw_method_call()
            tracker_reset()
            refresh()
        end
    end

    -- Prepend the candidate-bar row. It has exactly 10 entries (◀ + 8 slots + ▶,
    -- each 1.0 unit) so #KEYS[1] stays 10 and the QWERTY rows keep their widths.
    -- Build-time labels are " " (a literal "" would collide with shiftmode_keys);
    -- real text is filled in by refresh() after each addKeys.
    -- NOTE: inserted *after* the kb.keys[N] tweaks above so their row indices
    -- (1-5) still refer to the original English rows.
    local candidate_row = {}
    for i = 1, SLOTS + 2 do
        candidate_row[i] = { label = " ", width = 1.0 }
    end
    table.insert(kb.keys, 1, candidate_row)

    -- Re-grab the live candidate widgets after every keyboard (re)build.
    local function grabRefs(keyboard)
        local row = keyboard.layout and keyboard.layout[1]
        if not row or #row < SLOTS + 2 then return false end
        prev_key = row[1]
        for i = 1, SLOTS do
            cand_keys[i] = row[1 + i]
        end
        next_key = row[SLOTS + 2]
        return true
    end

    -- VirtualKeyboard:addKeys() rebuilds the key widgets on init and on every
    -- layer change, resetting our candidate keys' labels/callbacks. Hook it once
    -- to re-bind and re-render whenever *this* layout is the one being built.
    -- Gated on self.KEYS == kb.keys so no other layout is affected.
    if not VirtualKeyboard._boshiamy_bar_hooked then
        VirtualKeyboard._boshiamy_bar_hooked = true
        local orig_addKeys = VirtualKeyboard.addKeys
        VirtualKeyboard.addKeys = function(self, ...)
            orig_addKeys(self, ...)
            if self.KEYS == kb.keys then
                current_keyboard = self
                current_inputbox = self.inputbox
                if grabRefs(self) then
                    refresh()
                end
            end
        end
    end

    kb.wrapInputBox = function(inputbox)
        tracker_reset() -- fresh composing state whenever the layout (re)opens
        if inputbox._boshiamy_wrapped == nil then
            inputbox._boshiamy_wrapped = true
            local wrappers = {}
            table.insert(wrappers, util.wrapMethod(inputbox, "delChar", wrappedDelChar, nil))
            table.insert(wrappers, util.wrapMethod(inputbox, "delToStartOfLine", nil, clear_stack))
            table.insert(wrappers, util.wrapMethod(inputbox, "clear", nil, clear_stack))
            table.insert(wrappers, util.wrapMethod(inputbox, "upLine", nil, separate))
            table.insert(wrappers, util.wrapMethod(inputbox, "downLine", nil, separate))
            table.insert(wrappers, util.wrapMethod(inputbox, "unfocus", nil, separate))
            table.insert(wrappers, util.wrapMethod(inputbox, "onCloseKeyboard", nil, separate))
            table.insert(wrappers, util.wrapMethod(inputbox, "onTapTextBox", nil, separate))
            table.insert(wrappers, util.wrapMethod(inputbox, "onHoldTextBox", nil, separate))
            table.insert(wrappers, util.wrapMethod(inputbox, "onSwipeTextBox", nil, separate))
            table.insert(wrappers, util.wrapMethod(inputbox, "addChars", wrappedAddChars, nil))
            table.insert(wrappers, util.wrapMethod(inputbox, "leftChar", wrappedLeftChar, nil))
            table.insert(wrappers, util.wrapMethod(inputbox, "rightChar", wrappedRightChar, nil))
            return function()
                if inputbox._boshiamy_wrapped then
                    for _, wrapper in ipairs(wrappers) do
                        wrapper:revert()
                    end
                    inputbox._boshiamy_wrapped = nil
                end
            end
        end
    end

    kb.genMenuItems = function(self)
        return {
            {
                text = _("Show inline candidate hints"),
                checked_func = function()
                    return settings.show_candi
                end,
                callback = function()
                    settings.show_candi = not settings.show_candi
                    G_reader_settings:saveSetting(SETTING_NAME, settings)
                end,
            },
        }
    end

    return kb
end

logger.info("Boshiamy patch: registered", LANG, "->", LAYOUT, "(data:", data_file .. ")")
