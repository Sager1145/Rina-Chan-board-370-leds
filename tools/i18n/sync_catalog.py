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

from xcstrings_io import CATALOG, ROOT, load_xcstrings, write_xcstrings

PROJECT = os.path.join(ROOT, "ios/RinaBoard.xcodeproj")
OBJROOT_HINT = (
    "pass the build's intermediates directory with --objroot PATH "
    "(e.g. ~/Library/Developer/Xcode/DerivedData/RinaBoard-*/Build/Intermediates.noindex), "
    "or point xcodebuild at a full Xcode with "
    "DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer"
)


def objroot():
    # A generic destination: OBJROOT does not depend on the device, and a named
    # simulator is ambiguous when several share the name.
    cmd = ["xcodebuild", "-project", PROJECT, "-scheme", "RinaBoard",
           "-destination", "generic/platform=iOS Simulator",
           "-showBuildSettings", "-json"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except OSError as exc:
        sys.exit("could not run xcodebuild (%s); %s" % (exc, OBJROOT_HINT))
    if result.returncode != 0:
        detail = (result.stderr.strip().splitlines() or ["exit %d" % result.returncode])[-1]
        sys.exit("xcodebuild -showBuildSettings failed: %s\n%s" % (detail, OBJROOT_HINT))
    try:
        targets = json.loads(result.stdout)
    except ValueError:
        targets = []
    for target in targets:
        settings = target.get("buildSettings", {})
        if settings.get("OBJROOT"):
            return settings["OBJROOT"]
    sys.exit("could not determine OBJROOT from xcodebuild; " + OBJROOT_HINT)


# Build directories whose stringsdata belong to another catalog: the watch
# app ships its own ios/RinaBoardWatch/Resources/Localizable.xcstrings
# (hand-maintained, see the README), so its keys must not land here.
FOREIGN_TARGET_DIRS = ("RinaBoardWatch.build",)


def keys_in_code(root):
    found = {}
    for path in glob.glob(os.path.join(root, "**", "*.stringsdata"), recursive=True):
        if any(part in FOREIGN_TARGET_DIRS for part in path.split(os.sep)):
            continue
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

    catalog = load_xcstrings()
    strings = catalog["strings"]

    missing = sorted(k for k in found if k not in strings)
    stale = sorted(k for k in found
                   if k in strings and strings[k].get("extractionState") == "stale")

    print("%d key(s) in code, %d missing from the catalog" % (len(found), len(missing)))
    for key in missing:
        print("  %s" % key)
    if stale:
        print("%d key(s) in code but marked stale in the catalog:" % len(stale))
        for key in stale:
            print("  %s" % key)

    if check:
        return 1 if (missing or stale) else 0
    if not missing:
        return 0

    # Appended in insertion order: the existing keys keep Xcode's order, so the
    # diff is only the new entries.
    for key in missing:
        entry = {}
        if found[key]:
            entry["comment"] = found[key]
        strings[key] = entry
    write_xcstrings(catalog)
    print("added %d key(s); now add translations and run apply_translations.py" % len(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
