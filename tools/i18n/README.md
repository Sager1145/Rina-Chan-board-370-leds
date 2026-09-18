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

`sync_catalog.py --check` exits `1` if it finds keys missing from the catalog, or keys that
are still referenced from code but whose catalog entry has `"extractionState": "stale"`
("stale but still used" — Xcode marked it stale because a build didn't see it, but the
source scan below still does, so it needs re-extracting, not deleting). Both are reported in
either mode; `--check` never writes the catalog. The `NSLocalizedString` source scan is a
regex, not a Swift parser: it can miss calls split across lines in unusual ways or wrapped in
macros, so treat its findings as a floor, not a guarantee.

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

### `apply_translations.py` flags and exit codes

- `--check`: report only, never writes the catalog. Exits `1` if there are keys with no
  entry in `translations.jsonl` at all, per-language gaps (see below), or any
  format-specifier mismatch (see below); exits `0` otherwise.
- `--force`: overwrite a translation that already has a value, including changing its
  *shape* (a plain string vs. plural variations) or replacing plural variations with a
  plain value. Replacing plural variations with a plain value prints a warning line
  naming the key, since that's the more destructive direction (dropping per-language
  plural forms). Without `--force`, an existing localization of either shape is left alone.
- `--only KEY` (repeatable): restrict writes to the named key(s) — combine with `--force`
  to change a few specific entries without touching anything else in the same run.
  `--check`'s reports are not restricted by `--only`; it always reports on the whole catalog.
- Duplicate `"k"` values in `translations.jsonl` are rejected before anything else runs;
  the error names both line numbers.

In `--check` mode, besides the untranslated-key list, two more things are reported:

- **Per-language gaps**: keys that have an entry in `translations.jsonl` but no value
  (plain or plural) for one of the four languages, where the catalog doesn't already have
  a value for that language either. (An ordinary zh-Hans-text key never counts as a
  zh-Hans gap: for those the key itself *is* the Simplified Chinese text, per the `"hans"`
  note above. Only identifier-style keys need an explicit `"hans"` value.) These count
  toward the `--check` exit code.
- **Orphans**: keys in `translations.jsonl` that aren't in the catalog at all (e.g. a
  string that was renamed or removed from the code). Informational only — they don't
  affect the exit code.

### Plurals

Any of `"en_plural"`, `"hant_plural"`, `"ja_plural"`, `"hans_plural"` may hold an object
mapping a plural category (`zero`, `one`, `two`, `few`, `many`, `other` — `"other"` is
required) to a translated string. A `"*_plural"` field takes precedence over the plain
field of the same language. Example:

```json
{"k": "%lld 个面孔", "en_plural": {"one": "%lld face", "other": "%lld faces"}}
```

is written as:

```json
"localizations" : {
  "en" : {
    "variations" : {
      "plural" : {
        "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld face" } },
        "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld faces" } }
      }
    }
  }
}
```

### Format-specifier check

For every translated value (plain, and each plural form), `apply_translations.py` checks
that its `%`-format specifiers are compatible with the key's: same argument count and the
same type at each position (`%d`/`%lld`/`%ld`/`%i`/`%u`/`%x`/`%o`/`%c` are all "integer",
`%@` is "object", `%f`/`%.1f`/`%e`/`%g` are "double", `%s` is a C string). Positional forms
(`%1$lld`, `%2$@`, ...) may be reordered in translation as long as each position keeps its
original type. A plural `"one"` form may drop the integer count specifier entirely if it
is the string's only argument (e.g. `"one": "a face"` for a source with a single `%lld`).
A mismatch lists every offending key + language (and plural category, if applicable) and
exits `1` in both `--check` and write mode, before anything is written.

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

## Tests

`test_i18n_tools.py` is a plain-`unittest` suite (no third-party deps) covering duplicate-key
rejection, the plural write shape, variation-preserving without `--force`, the
format-specifier check (including allowed positional reordering), and `--only`. It runs each
script as a subprocess against a throwaway catalog + dictionary in a temp directory (pointed
at via `RINA_I18N_CATALOG` / `RINA_I18N_DICT`), so it never touches the real
`Localizable.xcstrings` or `translations.jsonl`:

```sh
python3 tools/i18n/test_i18n_tools.py -v
```

`RINA_I18N_CATALOG` / `RINA_I18N_DICT` work the same way for manual testing: set either to
redirect `apply_translations.py` and `xcstrings_io.py` at a copy of the catalog/dictionary
instead of the real files.
