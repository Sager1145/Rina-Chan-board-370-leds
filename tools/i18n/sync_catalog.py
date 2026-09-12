#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Add strings that exist in the code but are missing from the catalog.

Two sources, because neither is complete on its own:

1. `*.stringsdata` under DerivedData. `xcodebuild` writes these for every literal
   the compiler recognises (`Text("口型")`, `String(localized:)`, ...), but —
   unlike the Xcode IDE — it never writes newly discovered keys back into
   `Localizable.xcstrings`.
2. `NSLocalizedString("...")` call sites, scanned out of the Swift sources.
   The compiler does **not** put these in stringsdata at all, so a build-only
   check silently misses them; the app then ships those strings untranslated in
   every language. Roughly a quarter of this app's strings are this form.

Run a build first, then:
  python3 tools/i18n/sync_catalog.py [--check] [--objroot PATH]
"""
import glob, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, "ios/RinaBoard/Resources/Localizable.xcstrings")
PROJECT = os.path.join(ROOT, "ios/RinaBoard.xcodeproj")


def objroot():
    out = subprocess.check_output(
        ["xcodebuild", "-project", PROJECT, "-scheme", "RinaBoard",
         "-destination", "platform=iOS Simulator,name=iPhone 17 Pro",
         "-showBuildSettings", "-json"],
        stderr=subprocess.DEVNULL,
    )
    for target in json.loads(out):
        settings = target.get("buildSettings", {})
        if settings.get("OBJROOT"):
            return settings["OBJROOT"]
    sys.exit("could not determine OBJROOT from xcodebuild")


def keys_in_code(root):
    found = {}
    for path in glob.glob(os.path.join(root, "**", "*.stringsdata"), recursive=True):
        with open(path, encoding="utf-8") as fh:
            try:
                data = json.load(fh)
            except ValueError:
                continue
        # Only the Localizable table: Info.plist keys live in InfoPlist.xcstrings.
        for rows in [data.get("tables", {}).get("Localizable", [])]:
            for row in rows:
                key = row.get("key")
                if key:
                    found.setdefault(key, row.get("comment") or None)
    return found


NSLOCALIZED = re.compile(r'NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)"', re.S)
# RinaCore is scanned too: its NSLocalizedString calls resolve against
# Bundle.main, so those keys belong in the app's catalog.
SOURCE_ROOTS = (os.path.join(ROOT, "ios/RinaBoard"),
                os.path.join(ROOT, "ios/Packages/RinaCore/Sources"))


def keys_in_sources():
    """NSLocalizedString literals, which never reach stringsdata."""
    found = {}
    for root in SOURCE_ROOTS:
        for base, _, files in os.walk(root):
            for name in files:
                if not name.endswith(".swift"):
                    continue
                with open(os.path.join(base, name), encoding="utf-8") as fh:
                    text = fh.read()
                for match in NSLOCALIZED.finditer(text):
                    found.setdefault(json.loads('"%s"' % match.group(1)), None)
    return found


def main():
    check = "--check" in sys.argv
    if "--objroot" in sys.argv:
        try:
            override = sys.argv[sys.argv.index("--objroot") + 1]
        except IndexError:
            sys.exit("--objroot requires a path")
        stringsdata_root = os.path.abspath(override)
    else:
        stringsdata_root = objroot()
    found = keys_in_code(stringsdata_root)
    for key, comment in keys_in_sources().items():
        found.setdefault(key, comment)
    if not found:
        sys.exit("no .stringsdata found — build the app first")

    with open(CATALOG, encoding="utf-8") as fh:
        catalog = json.load(fh)
    strings = catalog["strings"]

    missing = sorted(k for k in found if k not in strings)
    print("%d key(s) in code, %d missing from the catalog" % (len(found), len(missing)))
    for key in missing:
        print("  %s" % key)
    if check or not missing:
        return 0

    for key in missing:
        entry = {}
        if found[key]:
            entry["comment"] = found[key]
        strings[key] = entry
    tmp = CATALOG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(catalog, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, CATALOG)
    print("added %d key(s); now add translations and run apply_translations.py" % len(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
