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
export (40,208 codes / 60,296 mappings, candidates in frequency order). The
Boshiamy table is proprietary — **do not redistribute this file or this repo
publicly.**

Regenerate from a fresh `.lime` export with:

```sh
python3 - <<'PY'
import collections
raw = open('boshiamy.lime', encoding='utf-8-sig').read()
d = collections.OrderedDict()
for line in raw.split('\n'):
    if not line.strip(): continue
    code, ch = line.split('\t')
    d.setdefault(code, []).append(ch)
out = ['return {']
for code, vs in d.items():
    key = '["%s"]' % code
    out.append('%s=%s,' % (key, '"%s"' % vs[0] if len(vs) == 1
                           else '{%s}' % ','.join('"%s"' % v for v in vs)))
out.append('}')
open('boshiamy_data.lua', 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PY
```

All 40,208 codes are input-reachable: the IME consumes `a`–`z` plus `, . [ ] '`
(see `keys_string` in the patch). To make the `,`/`.` keys insert punctuation
*directly* instead of composing, remove those symbols from `keys_string` and
give the keys full-width primaries.
