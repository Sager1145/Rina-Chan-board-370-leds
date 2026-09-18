#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generates `ios/RinaBoard/Resources/PresetNames.xcstrings` from
`tools/i18n/preset_names.jsonl` (one JSON object per line:
`{"k","hans","hant","ja","en"}`), in Xcode's own on-disk catalog format
(see `xcstrings_io.py`).

Every entry is `"extractionState": "manual"` (there's no source code to
extract these keys from — they're preset names out of `color_presets.json`
and `default_faces.json`) with `"translated"` string units for en, zh-Hans,
zh-Hant and ja.

Usage: python3 tools/i18n/gen_preset_names.py
"""
import json
import os

from xcstrings_io import ROOT, INDENT, dump_xcstrings

JSONL = os.path.join(ROOT, "tools/i18n/preset_names.jsonl")
OUT = os.path.join(ROOT, "ios/RinaBoard/Resources/PresetNames.xcstrings")


def load_entries():
    entries = []
    seen = set()
    with open(JSONL, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            key = obj["k"]
            if key in seen:
                raise SystemExit("duplicate key %r at line %d" % (key, lineno))
            seen.add(key)
            entries.append(obj)
    return entries


def build_catalog(entries):
    strings = {}
    for obj in sorted(entries, key=lambda o: o["k"]):
        strings[obj["k"]] = {
            "extractionState": "manual",
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": obj["en"]}},
                "ja": {"stringUnit": {"state": "translated", "value": obj["ja"]}},
                "zh-Hans": {"stringUnit": {"state": "translated", "value": obj["hans"]}},
                "zh-Hant": {"stringUnit": {"state": "translated", "value": obj["hant"]}},
            },
        }
    return {
        "sourceLanguage": "zh-Hans",
        "strings": strings,
        "version": "1.0",
    }


def main():
    entries = load_entries()
    catalog = build_catalog(entries)
    text = dump_xcstrings(catalog)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    os.replace(tmp, OUT)
    print("wrote %d keys to %s" % (len(entries), OUT))


if __name__ == "__main__":
    main()
