#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fill zh-Hant / ja / en translations into Localizable.xcstrings.

The string catalog's source language is zh-Hans, so the keys are the Simplified
Chinese strings. This script reads translations.jsonl (one JSON object per line:
{"k": <source string>, "hant": ..., "ja": ..., "en": ..., "nt": true}) and writes
the translations into the catalog. "nt" marks a string that must not be
translated (pure format specifiers, numbers, product names).

Plurals: any of "en_plural", "hant_plural", "ja_plural", "hans_plural" may hold
an object of plural-category -> translated string, e.g.
{"k": "%lld 个面孔", "en_plural": {"one": "%lld face", "other": "%lld faces"}}.
Categories are those ICU/Xcode understands: zero, one, two, few, many, other;
"other" is required. A "*_plural" field takes precedence over the plain field
of the same language.

It never overwrites a translation that is already there unless --force is
given, and never changes the *shape* of an existing localization (a plain
value vs. plural variations) unless --force is given either. It aborts if the
catalog changes on disk while it runs, so it is safe to use while other
sessions are editing the project.

Usage:  python3 tools/i18n/apply_translations.py [--check] [--force] [--only KEY]...
"""
import json, os, re, sys

from xcstrings_io import CATALOG, load_xcstrings, write_xcstrings

DICT = os.environ.get("RINA_I18N_DICT") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "translations.jsonl")
# "hans" is only for key-style strings (e.g. "partGroup.leye") whose key is an
# identifier rather than the Simplified Chinese text: without an explicit
# zh-Hans value those would display the raw key to Simplified Chinese users.
LANGS = (("en", "en"), ("zh-Hans", "hans"), ("zh-Hant", "hant"), ("ja", "ja"))

PLURAL_CATEGORIES = {"zero", "one", "two", "few", "many", "other"}

CJK_RE = re.compile(r'[㐀-鿿]')


def is_source_text_key(key):
    """True for an ordinary zh-Hans source string (the key IS the text), as
    opposed to an identifier-style key (e.g. "partGroup.leye") that needs an
    explicit "hans" override -- see the README note on the "hans" field."""
    return bool(CJK_RE.search(key))

# %<position$><flags><width><.precision><length><conversion>. Length modifiers
# (h, hh, l, ll, q, z, t, L) don't change the argument type we care about.
SPEC_RE = re.compile(
    r'%(\d+\$)?[-+0 #]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|L)?([@dsifeEgGuxXoc%])')


def spec_type(conv):
    if conv == "@":
        return "object"
    if conv == "s":
        return "string"
    if conv in "fFeEgG":
        return "double"
    return "integer"  # d i u x X o c


def extract_specifiers(text):
    """[(position, type), ...] for every non-literal % conversion in text."""
    specs = []
    auto_index = 0
    for match in SPEC_RE.finditer(text):
        conv = match.group(2)
        if conv == "%":
            continue
        pos = match.group(1)
        if pos:
            position = int(pos[:-1])
        else:
            auto_index += 1
            position = auto_index
        specs.append((position, spec_type(conv)))
    return specs


def specs_compatible(source_specs, value_specs, allow_omit_count=False):
    """Same argument count & types as source_specs; positions may reorder."""
    if allow_omit_count and not value_specs and len(source_specs) == 1 \
            and source_specs[0][1] == "integer":
        return True
    if len(source_specs) != len(value_specs):
        return False
    s_sorted = sorted(source_specs)
    v_sorted = sorted(value_specs)
    if [p for p, _ in s_sorted] != [p for p, _ in v_sorted]:
        return False
    return {p: t for p, t in source_specs} == {p: t for p, t in value_specs}


def validate_plural(entry, field, line_no):
    value = entry.get(field)
    if value is None:
        return
    if not isinstance(value, dict):
        sys.exit("translations.jsonl:%d: %r must be an object of category -> string"
                  % (line_no, field))
    bad = set(value) - PLURAL_CATEGORIES
    if bad:
        sys.exit("translations.jsonl:%d: %r has unknown plural category(ies) %s"
                  % (line_no, field, sorted(bad)))
    if "other" not in value:
        sys.exit("translations.jsonl:%d: %r is missing the required \"other\" category"
                  % (line_no, field))


def load_dict():
    out = {}
    line_of = {}
    with open(DICT, encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError as exc:
                sys.exit("translations.jsonl:%d: %s" % (line_no, exc))
            key = entry["k"]
            if key in line_of:
                sys.exit("translations.jsonl:%d and %d: duplicate key %r"
                          % (line_of[key], line_no, key))
            line_of[key] = line_no
            for _, field in LANGS:
                validate_plural(entry, field + "_plural", line_no)
            out[key] = entry
    return out


def catalog_lang_value(entry, lang):
    """Existing translated value for `lang`, plain or plural "other", or None."""
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return None
    if "stringUnit" in loc:
        return loc["stringUnit"].get("value")
    variations = loc.get("variations", {}).get("plural", {})
    return variations.get("other", {}).get("stringUnit", {}).get("value")


def find_mismatches(strings, translations):
    mismatches = []
    for key, entry in strings.items():
        if entry.get("extractionState") == "stale":
            continue
        source = translations.get(key)
        if source is None or source.get("nt"):
            continue
        source_specs = extract_specifiers(key)
        for lang, field in LANGS:
            plural_val = source.get(field + "_plural")
            plain_val = source.get(field)
            if plural_val:
                for category, form in plural_val.items():
                    allow_omit = category == "one"
                    if not specs_compatible(source_specs, extract_specifiers(form), allow_omit):
                        mismatches.append((key, lang, category))
            elif plain_val:
                if not specs_compatible(source_specs, extract_specifiers(plain_val)):
                    mismatches.append((key, lang, None))
    return mismatches


def build_variations(plural_val):
    return {"variations": {"plural": {
        category: {"stringUnit": {"state": "translated", "value": value}}
        for category, value in plural_val.items()
    }}}


def parse_args(argv):
    check = "--check" in argv
    force = "--force" in argv
    only = set()
    i = 0
    while i < len(argv):
        if argv[i] == "--only":
            if i + 1 >= len(argv):
                sys.exit("--only requires a key")
            only.add(argv[i + 1])
            i += 2
        else:
            i += 1
    return check, force, only


def main():
    check, force, only = parse_args(sys.argv[1:])
    translations = load_dict()

    stamp = os.stat(CATALOG).st_mtime_ns
    catalog = load_xcstrings()
    strings = catalog["strings"]

    mismatches = find_mismatches(strings, translations)
    if mismatches:
        print("%d format-specifier mismatch(es):" % len(mismatches))
        for key, lang, category in mismatches:
            suffix = " (%s)" % category if category else ""
            print("  %s [%s]%s" % (key, lang, suffix))
        return 1

    untranslated, dictionary_missing, changed = [], [], 0

    for key, entry in strings.items():
        if entry.get("extractionState") == "stale":
            continue
        source = translations.get(key)
        if source is None:
            # No dictionary entry is only a missing translation when the
            # catalog itself lacks one; a catalog that is already complete
            # just means translations.jsonl lags behind it.
            skip_hans = is_source_text_key(key)
            complete = entry.get("shouldTranslate") is False or all(
                (lang == "zh-Hans" and skip_hans) or catalog_lang_value(entry, lang)
                for lang, _ in LANGS)
            (dictionary_missing if complete else untranslated).append(key)
            continue
        if source.get("nt"):
            if (only and key not in only):
                continue
            if entry.get("shouldTranslate") is not False:
                entry["shouldTranslate"] = False
                changed += 1
            continue
        if only and key not in only:
            continue
        entry.pop("shouldTranslate", None)
        locs = entry.setdefault("localizations", {})
        for lang, field in LANGS:
            plural_val = source.get(field + "_plural")
            plain_val = source.get(field)
            if plural_val:
                desired = build_variations(plural_val)
            elif plain_val:
                desired = {"stringUnit": {"state": "translated", "value": plain_val}}
            else:
                continue
            existing = locs.get(lang)
            if existing == desired:
                continue
            if existing is None:
                locs[lang] = desired
                changed += 1
                continue
            existing_is_variations = "variations" in existing
            desired_is_variations = "variations" in desired
            if existing_is_variations != desired_is_variations:
                if not force:
                    continue
                if existing_is_variations and not desired_is_variations:
                    print("warning: replacing plural variations with a plain "
                          "value for %r [%s]" % (key, lang))
                locs[lang] = desired
                changed += 1
            else:
                if not force:
                    continue
                locs[lang] = desired
                changed += 1

    if untranslated:
        print("%d string(s) have no entry in translations.jsonl and are "
              "missing a translation in the catalog:" % len(untranslated))
        for key in sorted(untranslated):
            print("  %s" % key)
    if dictionary_missing:
        print("%d string(s) are translated in the catalog but have no entry "
              "in translations.jsonl (not an error):" % len(dictionary_missing))
        for key in sorted(dictionary_missing):
            print("  %s" % key)

    gaps, orphans = [], []
    if check:
        for key, source in translations.items():
            if source.get("nt"):
                continue
            entry = strings.get(key)
            if entry is None:
                orphans.append(key)
                continue
            if entry.get("extractionState") == "stale":
                continue
            skip_hans = is_source_text_key(key)
            for lang, field in LANGS:
                if lang == "zh-Hans" and skip_hans:
                    continue
                if source.get(field + "_plural") or source.get(field):
                    continue
                if catalog_lang_value(entry, lang):
                    continue
                gaps.append((key, lang))
        if gaps:
            print("%d per-language gap(s):" % len(gaps))
            for key, lang in sorted(gaps):
                print("  %s [%s]" % (key, lang))
        if orphans:
            print("%d orphan key(s) in translations.jsonl not in the catalog:"
                  % len(orphans))
            for key in sorted(orphans):
                print("  %s" % key)

    if check:
        print("check only: %d field(s) would change" % changed)
        return 1 if (untranslated or gaps or changed) else 0

    if changed:
        if os.stat(CATALOG).st_mtime_ns != stamp:
            sys.exit("Localizable.xcstrings changed on disk while running; re-run.")
        write_xcstrings(catalog)
    print("updated %d field(s)" % changed)
    return 1 if untranslated else 0


if __name__ == "__main__":
    sys.exit(main())
