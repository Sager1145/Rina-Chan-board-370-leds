# Localization

The app ships four languages: **简体中文 (zh-Hans, source)**, **繁體中文・台灣 (zh-Hant)**,
**日本語 (ja)** and **English (en)**.

- UI strings stay as Simplified Chinese literals in Swift (`Text("亮度")`,
  `String(localized:)`, `NSLocalizedString`). Xcode extracts them into
  `ios/RinaBoard/Resources/Localizable.xcstrings`, whose source language is `zh-Hans`,
  so the catalog keys *are* the Simplified Chinese strings.
- Translations live in `translations.jsonl`, one JSON object per line:
  `{"k": "<Simplified Chinese source>", "en": ..., "hant": ..., "ja": ...}`, or
  `{"k": ..., "nt": true}` for strings that must not be translated (bare format
  specifiers, numbers, product names).
- Info.plist permission prompts are localized in
  `ios/RinaBoard/Resources/InfoPlist.xcstrings` (edited by hand, keyed by Info.plist key).

## After adding new UI strings

A build alone is not enough to get new strings into the catalog, for two separate reasons —
`sync_catalog.py` covers both:

- `xcodebuild` extracts recognised literals into `*.stringsdata` under DerivedData, but —
  unlike the Xcode IDE — it does **not** write newly discovered keys back into
  `Localizable.xcstrings`.
- `NSLocalizedString("...")` never reaches `.stringsdata` at all. The compiler only records
  `Text("...")`, `String(localized:)` and friends, so a stringsdata-only check silently
  misses roughly a quarter of this app's strings. `sync_catalog.py` scans the Swift sources
  for `NSLocalizedString` call sites as well.

A string that is in the code but not in the catalog ships **untranslated in every language** —
and no amount of translating it in `translations.jsonl` helps, because `apply_translations.py`
only walks keys that are already in the catalog. Always run `sync_catalog.py` first.

```sh
# 1. build once so the compiler emits .stringsdata for the changed files
cd ios && xcodebuild -project RinaBoard.xcodeproj -scheme RinaBoard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO build

# 2. copy any keys the compiler found but the catalog lacks into the catalog
python3 tools/i18n/sync_catalog.py        # --check to only list them

# 3. see which strings still need translating
python3 tools/i18n/apply_translations.py --check

# 4. add those keys to tools/i18n/translations.jsonl, then fill the catalog
python3 tools/i18n/apply_translations.py
```

`apply_translations.py` never overwrites a translation that is already in the catalog
(pass `--force` to do that) and aborts if the catalog changes on disk while it runs,
so it is safe to run while other sessions are editing the project.

Both scripts are idempotent; a clean tree reports `0 missing` / `0 field(s) would change`.

### `sync_catalog.py` and xcodebuild

Without `--objroot`, `sync_catalog.py` asks `xcodebuild -showBuildSettings` (generic iOS
Simulator destination) where the build's intermediates live. That needs a full Xcode: if
`xcode-select` points at the Command Line Tools, either prefix the command with
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` or pass the directory
yourself with `--objroot ~/Library/Developer/Xcode/DerivedData/RinaBoard-*/Build/Intermediates.noindex`.

## Catalog format

Both scripts write the catalog through `xcstrings_io.py`, which reproduces Xcode's own
formatting byte-for-byte, so a run only changes the entries it actually touched (and
Xcode opening the file afterwards changes nothing). Don't write the catalog with
`json.dump(..., sort_keys=True)`: that rewrites all ~26k lines and conflicts with every other
session editing the catalog. The format:

- `" : "` between key and value, 2-space indent, non-ASCII written literally;
- top-level `strings` keys stay in Xcode's order (which is *not* code-point order), with
  new keys appended at the end; all other objects are sorted by key;
- an empty object is `{`, a blank line, then `}`; no newline at end of file.

After changing the writer, check that a load → dump round trip is still identical to both
the committed and the working-tree catalog:

```sh
python3 tools/i18n/xcstrings_io.py --selftest
```
