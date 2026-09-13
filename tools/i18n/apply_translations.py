#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fill zh-Hant / ja / en translations into Localizable.xcstrings.

The string catalog's source language is zh-Hans, so the keys are the Simplified
Chinese strings. This script reads translations.jsonl (one JSON object per line:
{"k": <source string>, "hant": ..., "ja": ..., "en": ..., "nt": true}) and writes
the translations into the catalog. "nt" marks a string that must not be
translated (pure format specifiers, numbers, product names).

It never overwrites a translation that is already there unless --force is given,
and it aborts if the catalog changes on disk while it runs, so it is safe to use
while other sessions are editing the project.

Usage:  python3 tools/i18n/apply_translations.py [--check] [--force]
"""
import json, os, sys

from xcstrings_io import CATALOG, load_xcstrings, write_xcstrings

DICT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "translations.jsonl")
# "hans" is only for key-style strings (e.g. "partGroup.leye") whose key is an
# identifier rather than the Simplified Chinese text: without an explicit
# zh-Hans value those would display the raw key to Simplified Chinese users.
LANGS = (("en", "en"), ("zh-Hans", "hans"), ("zh-Hant", "hant"), ("ja", "ja"))


def load_dict():
    out = {}
    with open(DICT, encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError as exc:
                sys.exit("translations.jsonl:%d: %s" % (line_no, exc))
            out[entry["k"]] = entry
    return out


def main():
    check = "--check" in sys.argv
    force = "--force" in sys.argv
    translations = load_dict()

    stamp = os.stat(CATALOG).st_mtime_ns
    catalog = load_xcstrings()

    strings = catalog["strings"]
    untranslated, changed = [], 0

    for key, entry in strings.items():
        if entry.get("extractionState") == "stale":
            continue
        source = translations.get(key)
        if source is None:
            untranslated.append(key)
            continue
        if source.get("nt"):
            # Leave any existing localizations alone: Xcode stores a zh-Hans
            # unit with positional specifiers for multi-argument format strings.
            if entry.get("shouldTranslate") is not False:
                entry["shouldTranslate"] = False
                changed += 1
            continue
        entry.pop("shouldTranslate", None)
        locs = entry.setdefault("localizations", {})
        for lang, field in LANGS:
            value = source.get(field)
            if not value:
                continue
            existing = locs.get(lang, {}).get("stringUnit", {}).get("value")
            if existing == value:
                continue
            if existing and not force:
                continue
            locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
            changed += 1

    if untranslated:
        print("%d string(s) have no entry in translations.jsonl:" % len(untranslated))
        for key in sorted(untranslated):
            print("  %s" % key)

    if check:
        print("check only: %d field(s) would change" % changed)
        return 1 if untranslated else 0

    if changed:
        if os.stat(CATALOG).st_mtime_ns != stamp:
            sys.exit("Localizable.xcstrings changed on disk while running; re-run.")
        write_xcstrings(catalog)
    print("updated %d field(s)" % changed)
    return 1 if untranslated else 0


if __name__ == "__main__":
    sys.exit(main())
