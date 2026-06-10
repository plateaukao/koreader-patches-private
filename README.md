# Private KOReader patches

User patches for KOReader, kept out of the main fork. Copy the files into your
device's `koreader/patches/` directory; KOReader runs every `N-*.lua` there at
startup (see `frontend/userpatch.lua`).

## 嘸蝦米 (Boshiamy) keyboard — `2-boshiamy.lua` + `boshiamy_data.lua`

Adds a Boshiamy Traditional-Chinese input method as a selectable virtual-keyboard
layout, built on KOReader's stock `generic_ime` engine (the same one behind the
bundled pinyin/stroke keyboards).

**Install:** copy **both** files into `koreader/patches/` (they must sit in the
same folder — the patch loads `boshiamy_data.lua` from beside itself). Restart,
then enable under **Settings → Keyboard → Keyboard layouts → 中文（嘸蝦米）(zh)**
and pick it from the globe key. The "Show character candidates" toggle lives in
**Layout-specific keyboard settings**.

**Usage:** type the lowercase Boshiamy code; candidates appear inline after the
character. `Space` commits the first/highlighted candidate, cycling is via the
← / → arrows, and `Backspace` removes one code key at a time.

The full Boshiamy alphabet feeds the IME: `a`–`z` plus the `, . [ ] '` selector
keys, so every code in the table is reachable (including the kana and full-width
bracket families). The `,` and `.` keys **tap** to a composing code key; their
**swipe** directions give full-width Chinese punctuation (，。、（）「」《》！？…
etc.) inserted directly. `[ ] '` come from the symbol layer / swipes, exactly
as on the stock English layout.

**Source data:** `boshiamy_data.lua` is generated from a *licensed* `boshiamy.lime`
export, then **filtered to Traditional Chinese only** — Simplified-Chinese,
Japanese kana and Japanese-shinjitai candidates are dropped, and any code left
with no candidates is removed. Result: 32,919 codes / 45,309 mappings (down from
40,208 / 60,296). The Boshiamy table is proprietary — **do not redistribute this
file or this repo publicly.**

The Traditional-only filter uses OpenCC (`pip install opencc`): a Han candidate
is kept iff it is Big5-encodable, or is left unchanged by both `s2t` and `jp2t`
(rescues rare Traditional chars Big5 lacks). Big5 is used as the arbiter so that
characters that are *both* a Simplified form and a legitimate Traditional
character (干, 后, 里, 范, 余 …) are kept rather than wrongly dropped. Punctuation
and other symbols are always kept; kana are always dropped.

Regenerate from a fresh `.lime` export with:

```sh
python3 - <<'PY'
import collections, opencc
s2t = opencc.OpenCC('s2t'); jp2t = opencc.OpenCC('jp2t')
def in_big5(c):
    try: c.encode('big5'); return True
    except UnicodeEncodeError: return False
def is_kana(c):
    o = ord(c)
    return (0x3040 <= o <= 0x30FF) or (0x31F0 <= o <= 0x31FF) or (0xFF66 <= o <= 0xFF9F) or o == 0xFF70
def is_cjk(c):
    o = ord(c)
    return (0x3400 <= o <= 0x4DBF) or (0x4E00 <= o <= 0x9FFF) or (0xF900 <= o <= 0xFAFF) or (0x20000 <= o <= 0x2FFFF)
def keep(c):
    if is_kana(c): return False
    if is_cjk(c):
        return in_big5(c) or (s2t.convert(c) == c and jp2t.convert(c) == c)
    return True  # punctuation / symbols
raw = open('boshiamy.lime', encoding='utf-8-sig').read()
d = collections.OrderedDict()
for line in raw.split('\n'):
    if not line.strip(): continue
    code, ch = line.split('\t')
    d.setdefault(code, []).append(ch)
out = ['return {']
for code, vs in d.items():
    vs = [v for v in vs if keep(v)]
    if not vs: continue
    key = '["%s"]' % code
    out.append('%s=%s,' % (key, '"%s"' % vs[0] if len(vs) == 1
                           else '{%s}' % ','.join('"%s"' % v for v in vs)))
out.append('}')
open('boshiamy_data.lua', 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PY
```

All remaining codes are input-reachable: the IME consumes `a`–`z` plus `, . [ ] '`
(see `keys_string` in the patch). To make the `,`/`.` keys insert punctuation
*directly* instead of composing, remove those symbols from `keys_string` and
give the keys full-width primaries.
