#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read and write .xcstrings catalogs in Xcode's own on-disk format.

`json.dump(..., indent=2, sort_keys=True)` reformats the whole catalog (~26k
changed lines), which collides with every other session editing it. Xcode's
format differs from Python's in four ways:

- key/value separator is " : " (space on both sides);
- the top-level "strings" keys keep Xcode's order, which is not code-point
  order ("·" sorts before "#RRGGBB"), so they are written in the order they
  were loaded and new keys go at the end; every other object is sorted;
- an empty object is "{", a blank line, then "}" at the parent's indent;
- there is no newline at the end of the file.

Self-test (load -> dump must reproduce the committed catalog byte-for-byte):
  python3 tools/i18n/xcstrings_io.py --selftest
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG_REL = "ios/RinaBoard/Resources/Localizable.xcstrings"
CATALOG = os.path.join(ROOT, CATALOG_REL)
INDENT = "  "


def load_xcstrings(path=CATALOG):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _encode(value, depth, keep_order):
    if isinstance(value, dict):
        pad = INDENT * depth
        if not value:
            return "{\n\n" + pad + "}"
        keys = list(value) if keep_order else sorted(value)
        inner = pad + INDENT
        items = [
            inner + json.dumps(key, ensure_ascii=False) + " : "
            # Only the catalog's "strings" map keeps its loaded order.
            + _encode(value[key], depth + 1, depth == 0 and key == "strings")
            for key in keys
        ]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        # No arrays in the catalog today; mirror the object layout.
        pad = INDENT * depth
        if not value:
            return "[\n\n" + pad + "]"
        items = [pad + INDENT + _encode(item, depth + 1, False) for item in value]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return json.dumps(value, ensure_ascii=False)


def dump_xcstrings(catalog):
    """Serialize a catalog exactly as Xcode writes it (no trailing newline)."""
    return _encode(catalog, 0, False)


def write_xcstrings(catalog, path=CATALOG):
    """Atomically replace `path` with the Xcode-formatted catalog."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(dump_xcstrings(catalog))
    os.replace(tmp, path)


def selftest():
    failures = 0
    head = subprocess.run(["git", "-C", ROOT, "show", "HEAD:" + CATALOG_REL],
                          capture_output=True, check=False)
    sources = [("HEAD", head.stdout.decode("utf-8"))] if head.returncode == 0 else []
    if not sources:
        print("skip HEAD: %s" % head.stderr.decode("utf-8", "replace").strip())
    with open(CATALOG, encoding="utf-8", newline="") as fh:
        sources.append(("working tree", fh.read()))
    for label, text in sources:
        out = dump_xcstrings(json.loads(text))
        if out == text:
            print("ok   %s: round-trip is byte-identical (%d bytes)" % (label, len(text)))
            continue
        failures += 1
        at = next((i for i, (a, b) in enumerate(zip(out, text)) if a != b),
                  min(len(out), len(text)))
        line = text.count("\n", 0, at) + 1
        print("FAIL %s: first difference at line %d\n  expected %r\n  got      %r"
              % (label, line, text[at - 40:at + 40], out[at - 40:at + 40]))
    return 1 if failures else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(__doc__)
