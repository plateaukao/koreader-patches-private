# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of **KOReader user patches** — standalone Lua files copied into a device's
`koreader/patches/` directory. There is **no build, test, or lint step** and no package
manager. KOReader's `frontend/userpatch.lua` runs every `N-*.lua` file in that folder at
app startup, in ascending order of the leading number (`1-*` before `2-*`, etc.). The
number is a load-order priority, not a version.

"Testing" a change means copying the file(s) onto a device (or KOReader emulator) under
`koreader/patches/`, restarting, and exercising the feature by hand. There is nothing to
run in this repo itself.

## Current contents

- `2-boshiamy.lua` + `boshiamy_data.lua` — the 嘸蝦米 (Boshiamy) Traditional-Chinese
  keyboard IME. The two files are a unit: the patch locates `boshiamy_data.lua` *beside
  itself* via `debug.getinfo`, so both must be installed in the same folder.
- `2-selection-highlight-style.lua` — draws the drag text selection with the current
  default highlight style + color instead of the stock inverted/gray selection.
  Standalone; see "Selection patch" below.
- `README.md` — install/usage instructions and the full data-regeneration recipe.

## boshiamy_data.lua is proprietary — do not publish

`boshiamy_data.lua` is generated from a **licensed** `boshiamy.lime` export. The Boshiamy
table is proprietary: **never commit it to a public repo, redistribute it, or paste its
contents into anything externally visible.** This repo is private for that reason. It is
machine-generated (32,919 codes / 44,973 mappings) — never hand-edit it. To change its
contents, edit the OpenCC filter pipeline documented in `README.md` ("Source data" /
"Regenerate") and re-run it against a fresh `.lime` export. The two-pass filter (Big5-arbitrated
Traditional-only character filter, then per-code traditional-preferred dedup) is the design;
read that section before touching generation logic.

## How the Boshiamy patch is structured (the architecture that spans files)

The patch deliberately reuses KOReader's stock machinery rather than reimplementing an IME:

1. **Registration (cheap, at startup).** It sets the display name in `ui/language`, and
   registers the layout in `ui/widget/virtualkeyboard` (`lang_to_keyboard_layout` +
   `lang_has_submenu`). `LANG = "zh_BS"`, `LAYOUT = "boshiamy_keyboard"`.

2. **Lazy layout loading.** The actual keyboard module is installed into
   `package.preload["ui/data/keyboardlayouts/boshiamy_keyboard"]`. `require()` consults
   `package.preload` before the filesystem, so the heavy `boshiamy_data.lua` table is only
   `dofile`'d the first time the user opens the layout — startup cost is just the name
   registration.

3. **Inside the preload factory:**
   - Starts from the stock English layout: `dofile(".../en_keyboard.lua")`, exactly as the
     bundled pinyin keyboard does.
   - Drives composition with the stock `generic_ime` engine — `code_map` is the data table,
     `keys_string = "abcdefghijklmnopqrstuvwxyz,.[]'"` defines which key taps are consumed
     as Boshiamy code keys vs. inserted literally. This gives candidate cycling, inline
     hints, stepped backspace, and the "show candidates" toggle for free.
   - **IME glue (`wrapInputBox`, `genMenuItems`) mirrors KOReader's `zh_CN_keyboard.lua`.**
     If you change this glue, diff against the current upstream `zh_CN_keyboard.lua` —
     it is the reference implementation and the structure is intentionally identical.
   - **Candidate bar.** An extra top row lists the candidates for the code being typed;
     tap to commit, `◀`/`▶` to page. It *augments* `generic_ime` (does not replace it,
     unlike the `pinyinplus.koplugin` it's modeled on): a small "tracker" mirrors the
     engine's composing stack (reusing `ime:getCandidates` for lookups) to know the
     current candidate list, and a tapped candidate is committed via the engine's own
     `getHintChars`/`delHintChars` helpers so it stays in sync with the inline preview
     and `←`/`→` cycling. The inline `[…]` hint defaults off now (bar supersedes it).

### Gotchas: the candidate bar

- **Row 1 must total 10 width-units.** `VirtualKeyboard:addKeys` derives `base_key_width`
  from `#self.KEYS[1]`, so the bar row is exactly 10 entries (`◀` + 8 slots + `▶`, each
  `width = 1.0`). Change the slot count and you must keep the row at 10 units or every
  QWERTY row's key widths break.
- **Build-time label is `" "`, not `""`.** A literal `""` label collides with
  `en_keyboard`'s `shiftmode_keys[""]`, turning every empty candidate key into a Shift
  key. Slots build with `" "`; real candidate text is written via `setText` *after* the
  build, in the `addKeys` hook.
- **The row is `table.insert`ed at the END of the factory**, after the `kb.keys[N]`
  punctuation tweaks — otherwise inserting at index 1 shifts those hard-coded row indices.
- **`VirtualKeyboard.addKeys` is monkey-patched** (once, gated on `self.KEYS == kb.keys`)
  to re-grab the live candidate `VirtualKey` widgets and re-render after every rebuild
  (layer changes rebuild the keys and reset their labels/callbacks).
- Logic is unit-tested headlessly against the real `generic_ime` — see the harness in
  the commit that added the bar (loads `generic_ime.lua` with stubbed deps, replays the
  tracker/commit path, asserts the resulting inputbox text).

### Gotcha: the `kb.keys[row][col][level]` coordinates are fragile

The block that customizes punctuation keys (e.g. `kb.keys[4][3][2]`, `kb.keys[3][10][2]`,
`kb.keys[5][4].label`) indexes by hard-coded position into the **stock `en_keyboard.lua`
key grid**. These coordinates are tied to upstream's current layout — if KOReader
reorganizes `en_keyboard.lua`, these indices silently land on the wrong keys. When editing
them, cross-reference the live `en_keyboard.lua` structure rather than guessing. The
intent: `,` and `.` must *tap* to their ASCII selves (so `generic_ime` treats them as code
keys), with full-width Chinese punctuation on the swipe directions (those glyphs aren't in
`keys_string`, so they insert literally).

## Selection patch (`2-selection-highlight-style.lua`)

Two render paths, because KOReader has two:

- **Paging (PDF/DjVu):** `ReaderView:drawTempHighlight` is replaced to paint
  `highlight.temp` boxes with `highlight.saved_drawer`/`saved_color` via the stock
  `drawHighlightRect`. `highlight.temp` is blanked during the call so newer builds use
  the regular `highlight_lighten_factor` (not `highlight_selection_lighten_factor`).
- **Rolling (crengine):** the engine paints the selection itself (`selectRange` with
  draw flags -> `FillRect` with `crengine.highlight.selection.color`, inside the page
  render) so it cannot be restyled from Lua. The patch wraps
  `CreDocument:getWordFromPosition/getTextFromPositions` to force
  `do_not_draw_selection = true` (the range is still set, flags 0 -> no marks; text and
  pos0/pos1 are unchanged), tracks `{pos0, pos1}` in `doc._selhl_range`, and paints it
  after `ReaderView:paintTo` via `getScreenBoxesFromPositions(pos0, pos1, true)` —
  clipped to the visible page by crengine, with the same cheap
  `getPosFromXPointer` viewport pre-check `drawXPointerSavedHighlight` uses.
  `CreDocument:clearSelection` clears the range. `ReaderHighlight:extendSelection`
  draws natively through `getTextFromXPointers(.., true)`; the wrapper clears that via
  the raw `_document:clearSelection()` (bypassing our wrapper) and tracks the range.
  `getTextFromXPointers` itself is deliberately NOT wrapped — search-result
  highlighting uses it and keeps its stock look.
- A lookup that returns nil keeps the previous range (mirrors crengine, which only
  replaces the selection on a hit). Callers passing `do_not_draw_selection = true`
  (dictionary, key selection) are never tracked.
- `drawTempHighlight` returns early on rolling docs when a range is tracked, so a
  plugin that also fills `highlight.temp` on EPUB (the pencil stylus plugin does)
  doesn't get painted twice.
- Headless tests: `luajit test/test_selection_highlight_style.lua` (stubbed modules,
  asserts what reaches `drawHighlightRect` and the draw-suppression flags).

## Conventions for new patches

- Name files `N-description.lua`; choose `N` for load order relative to existing patches.
- A patch that ships a companion data file should resolve its own directory with
  `debug.getinfo(1, "S").source` (see `2-boshiamy.lua`) so the pair stays self-contained.
- Prefer reusing KOReader subsystems (`generic_ime`, stock layouts, `util.wrapMethod`) over
  reimplementing them, and keep the patch's expensive work behind `package.preload`.
