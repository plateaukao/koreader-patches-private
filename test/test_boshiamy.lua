-- Regression test for the Boshiamy candidate-bar logic in ../2-boshiamy.lua.
--
-- It loads the REAL KOReader generic_ime.lua (with its deps stubbed) and replays
-- the patch's tracker + commit code path against a fake inputbox, asserting the
-- resulting text buffer. This catches drift if upstream generic_ime changes the
-- composing-stack semantics our mirror depends on.
--
-- Run:  KOREADER_SRC=~/src/koreader luajit test/test_boshiamy.lua
-- (KOREADER_SRC defaults to ../koreader relative to this repo.)

local repo = (arg and arg[0] or "test/test_boshiamy.lua"):gsub("[/\\]?test[/\\][^/\\]*$", "")
if repo == "" then repo = "." end
local KO = os.getenv("KOREADER_SRC") or (repo .. "/../koreader")
local GENERIC_IME = KO .. "/frontend/ui/data/keyboardlayouts/generic_ime.lua"

local f = io.open(GENERIC_IME, "r")
if not f then
    io.stderr:write("Cannot find generic_ime.lua at: " .. GENERIC_IME ..
        "\nSet KOREADER_SRC to your KOReader checkout.\n")
    os.exit(2)
end
f:close()

-- ── minimal stubs for generic_ime's deps ─────────────────────────────────
local function utf8chars(s)
    local t = {}
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = c end
    return t
end

local util = {}
function util.splitToChars(s) return utf8chars(s) end
function util.arrayContains(t, v)
    for _, x in ipairs(t) do if x == v then return true end end
    return false
end
local WrappedFunction_mt = {
    __call = function(self, ...)
        if self.before_callback then self.before_callback(self.target_table, ...) end
        if self.func then return self.func(...) end
    end,
}
function util.wrapMethod(target_table, field, new_func, before_callback)
    local old_func = target_table[field]
    local wrapped = setmetatable({
        target_table = target_table, target_field_name = field, old_func = old_func,
        before_callback = before_callback, func = new_func or old_func,
        revert = function(self) self.target_table[self.target_field_name] = self.old_func end,
        raw_call = function(self, ...) if self.old_func then return self.old_func(...) end end,
        raw_method_call = function(self, ...) return self:raw_call(self.target_table, ...) end,
    }, WrappedFunction_mt)
    target_table[field] = wrapped
    return wrapped
end

local logger = setmetatable({}, { __index = function() return function() end end })
local Utf8Proc = { uppercase_dumb = function(c) return c end }

local stubs = { ["logger"] = logger, ["util"] = util, ["ffi/utf8proc"] = Utf8Proc }
local real_require = require
_G.require = function(name)
    if stubs[name] then return stubs[name] end
    if name == "ui/data/keyboardlayouts/generic_ime" then return dofile(GENERIC_IME) end
    return real_require(name)
end

local IME = require("ui/data/keyboardlayouts/generic_ime")

-- ── code map exercising the interesting shapes ───────────────────────────
local code_map = {
    a   = "對",
    aa  = { "寸", "丶" },
    aaa = { "鑫", "龘", "鑆" },
    l   = { "中", "串" },
    z   = { "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸", "子" }, -- 11 -> 2 pages
}

-- ── the patch's runtime (same shape as 2-boshiamy.lua) ────────────────────
local settings = { show_candi = false }
local ime = IME:new{
    code_map = code_map,
    keys_string = "abcdefghijklmnopqrstuvwxyz,.[]'",
    partial_separators = { " " },
    show_candi_callback = function() return settings.show_candi end,
    switch_char = "→", switch_char_prev = "←",
}

local SLOTS = 8
local units, page = {}, 1
local bar = {}
local current_inputbox

local function tracker_reset() units = {}; page = 1 end
local function current_candidates() local u = units[#units]; return u and u.candi end
local function tracker_add(char)
    if char == ime.switch_char or char == ime.switch_char_prev then return end
    if char == ime.separator or (#units > 0 and util.arrayContains(ime.partial_separators, char)) then
        tracker_reset(); return
    end
    local key = ime.key_map[char]
    if key then
        local cur = units[#units]
        if cur then
            local grown = ime:getCandidates(cur.code .. key)
            if grown and #grown > 0 then cur.code = cur.code .. key; cur.candi = grown; page = 1; return end
        end
        local single = ime:getCandidates(key)
        if not single or #single == 0 then single = { char } end
        units[#units + 1] = { code = key, candi = single }; page = 1
    else
        tracker_reset()
    end
end
local function tracker_del()
    local cur = units[#units]
    if cur and #cur.code > 1 then
        cur.code = cur.code:sub(1, -2); cur.candi = ime:getCandidates(cur.code) or {}; page = 1
    elseif #units > 1 then
        units[#units] = nil; page = 1
    else
        tracker_reset()
    end
end
local function rawAddChars(ib, s) ib.addChars:raw_method_call(s) end
local function rawDelChar(ib) ib.delChar:raw_method_call() end

local commit
local function refresh()
    local list = current_candidates()
    local total = list and #list or 0
    local pages = math.max(1, math.ceil(total / SLOTS))
    if page > pages then page = pages end
    if page < 1 then page = 1 end
    bar = { prev = page > 1, next = page < pages, slots = {} }
    for i = 1, SLOTS do bar.slots[i] = list and list[(page - 1) * SLOTS + i] or nil end
end
commit = function(word)
    if not word or word == " " or word == "" then return end
    local ib = current_inputbox
    if not ib or #units == 0 then return end
    ime:getHintChars(); ime:delHintChars(ib); rawDelChar(ib); rawAddChars(ib, word)
    ime:clear_stack(); tracker_reset(); refresh()
end
local function wrappedAddChars(ib, char) ime:wrappedAddChars(ib, char); tracker_add(char); refresh() end
local function wrappedDelChar(ib) ime:wrappedDelChar(ib); tracker_del(); refresh() end

-- ── fake inputbox (charlist buffer, cursor at end) ───────────────────────
local function newInputbox()
    local ib = { buf = {} }
    function ib:addChars(s) for _, c in ipairs(utf8chars(s)) do self.buf[#self.buf + 1] = c end end
    function ib:delChar() self.buf[#self.buf] = nil end
    function ib:text() return table.concat(self.buf) end
    util.wrapMethod(ib, "addChars", wrappedAddChars, nil)
    util.wrapMethod(ib, "delChar", wrappedDelChar, nil)
    return ib
end

-- ── driver ────────────────────────────────────────────────────────────────
local function fresh()
    ime:clear_stack(); tracker_reset()
    local ib = newInputbox(); current_inputbox = ib; return ib
end
local function typestr(ib, s) for _, c in ipairs(utf8chars(s)) do ib:addChars(c) end end

local fails = 0
local function eq(label, got, want)
    if got ~= want then
        fails = fails + 1
        print(string.format("FAIL  %-32s got=%q want=%q", label, tostring(got), tostring(want)))
    else
        print(string.format("ok    %-32s = %q", label, tostring(got)))
    end
end
local function barslots()
    local t = {}
    for i = 1, SLOTS do t[i] = bar.slots[i] or "" end
    return table.concat(t, "|")
end

local ib = fresh(); typestr(ib, "a")
eq("single: inline box", ib:text(), "對")
eq("single: bar slots", barslots(), "對|||||||")

ib = fresh(); typestr(ib, "aa")
eq("list: inline box", ib:text(), "寸")
eq("list: bar slots", barslots(), "寸|丶||||||")
commit("寸"); eq("list: commit c1", ib:text(), "寸")

ib = fresh(); typestr(ib, "aa"); commit("丶")
eq("list: commit c2", ib:text(), "丶")

settings.show_candi = true
ib = fresh(); typestr(ib, "aa")
eq("bracket: inline box", ib:text(), "寸[丶]")
commit("丶"); eq("bracket: commit c2", ib:text(), "丶")
settings.show_candi = false

ib = fresh(); typestr(ib, "aaa")
eq("grow: box", ib:text(), "鑫")
eq("grow: bar", barslots(), "鑫|龘|鑆|||||")
wrappedDelChar(ib); eq("bksp -> aa", ib:text(), "寸")
wrappedDelChar(ib); eq("bksp -> a", ib:text(), "對")
wrappedDelChar(ib); eq("bksp -> empty", ib:text(), "")
eq("bksp: bar empty", barslots(), "|||||||")

ib = fresh(); typestr(ib, "a"); typestr(ib, "l")
eq("multi: box", ib:text(), "對中")
eq("multi: bar = last unit", barslots(), "中|串||||||")
commit("串"); eq("multi: commit keeps prefix", ib:text(), "對串")

ib = fresh(); typestr(ib, "z")
eq("page1: bar", barslots(), "甲|乙|丙|丁|戊|己|庚|辛")
eq("page1: has next", tostring(bar.next), "true")
page = page + 1; refresh()
eq("page2: bar", barslots(), "壬|癸|子|||||")
commit("癸"); eq("page2: commit", ib:text(), "癸")

ib = fresh(); typestr(ib, "aa"); typestr(ib, " ")
eq("space: clears units", tostring(#units), "0")

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURE(S)"))
os.exit(fails == 0 and 0 or 1)
