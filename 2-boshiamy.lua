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
    local util = require("util")
    local _ = require("gettext")

    -- Base on the English QWERTY layout, like the bundled pinyin keyboard does.
    local kb = dofile("frontend/ui/data/keyboardlayouts/en_keyboard.lua")

    local code_map = dofile(data_file)
    local settings = G_reader_settings:readSetting(SETTING_NAME, { show_candi = true })

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

    -- ── IME glue (identical structure to zh_CN_keyboard.lua) ──────────────
    local function wrappedAddChars(inputbox, char)
        ime:wrappedAddChars(inputbox, char)
    end
    local function wrappedDelChar(inputbox)
        ime:wrappedDelChar(inputbox)
    end
    local function wrappedRightChar(inputbox)
        if ime:hasCandidates() then
            ime:wrappedAddChars(inputbox, "→")
        else
            ime:separate(inputbox)
            inputbox.rightChar:raw_method_call()
        end
    end
    local function wrappedLeftChar(inputbox)
        if ime:hasCandidates() then
            ime:wrappedAddChars(inputbox, "←")
        else
            ime:separate(inputbox)
            inputbox.leftChar:raw_method_call()
        end
    end
    local function separate(inputbox)
        ime:separate(inputbox)
    end
    local function clear_stack()
        ime:clear_stack()
    end

    kb.wrapInputBox = function(inputbox)
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
                text = _("Show character candidates"),
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
