#!/usr/bin/env python3
"""Synchronize and validate the fused Ark12 font assets.

The Ark text-scroll font is represented twice:

* data/resources/fonts/ark12.woff2 for browser text shaping/preview.
* data/resources/fonts/ark12.json for the LED bitmap rasterizer.

The WebUI no longer keeps a giant Ark @font-face unicode-range in CSS. This
tool makes the upload scripts prove that the WOFF2 cmap and JSON glyph table
still describe the same codepoint set before LittleFS is built. If a future
CSS unicode-range is present, it is treated as an extra constraint.

data/resources/fonts/ is the single source of truth; the former
tools/font_fusion bundle mirror was removed. To regenerate the assets, use
tools/merge_mona12_emoji.py / tools/build_ark12_merged.py.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable, Optional, Set

try:
    from fontTools.ttLib import TTFont
except Exception as exc:  # pragma: no cover - user-facing dependency error
    print(
        "[ark12-sync] Missing Python dependency. Install with: "
        "python -m pip install --user fonttools brotli",
        file=sys.stderr,
    )
    print(f"[ark12-sync] Import error: {exc}", file=sys.stderr)
    raise SystemExit(20)


ARK_FACE_RE = re.compile(
    r"@font-face\s*\{(?=[^{}]*ark12\.woff2)(?=[^{}]*font-family\s*:\s*['\"]Ark Pixel 12px Monospaced['\"])(.*?)\}",
    re.S,
)
UNICODE_RANGE_RE = re.compile(r"unicode-range\s*:\s*(.*?);", re.S)
RANGE_PART_RE = re.compile(r"U\+([0-9A-Fa-f]+)(?:-([0-9A-Fa-f]+))?")


def parse_css_codepoints(css_path: Path) -> Optional[Set[int]]:
    css = css_path.read_text(encoding="utf-8")
    face_match = ARK_FACE_RE.search(css)
    if not face_match:
        raise RuntimeError(f"Could not find Ark12 @font-face block in {css_path}")
    range_match = UNICODE_RANGE_RE.search(face_match.group(1))
    if not range_match:
        return None

    codepoints: Set[int] = set()
    for start_hex, end_hex in RANGE_PART_RE.findall(range_match.group(1)):
        start = int(start_hex, 16)
        end = int(end_hex, 16) if end_hex else start
        if end < start:
            raise RuntimeError(f"Invalid unicode range U+{start_hex}-{end_hex}")
        codepoints.update(range(start, end + 1))
    if not codepoints:
        raise RuntimeError(f"Ark12 unicode-range is empty in {css_path}")
    return codepoints


def load_json_codepoints(json_path: Path) -> Set[int]:
    data = json.loads(json_path.read_text(encoding="utf-8"))
    if data.get("format") != "rina_ark_pixel_font_bitmap_v1":
        raise RuntimeError(f"{json_path} is not a Rina Ark bitmap JSON file")
    if int(data.get("rows", 0)) != 12 or int(data.get("lineHeight", 0)) != 12:
        raise RuntimeError(f"{json_path} is not a 12px Ark bitmap table")
    if int(data.get("defaultAdvance", 0)) != 12:
        raise RuntimeError(f"{json_path} defaultAdvance is not 12")
    glyphs = data.get("glyphs")
    if not isinstance(glyphs, dict) or not glyphs:
        raise RuntimeError(f"{json_path} has no glyph map")
    return {int(key, 16) for key in glyphs}


def load_woff2_codepoints(woff2_path: Path) -> Set[int]:
    return set(TTFont(str(woff2_path)).getBestCmap())


def summarize(items: Iterable[int], limit: int = 24) -> str:
    values = sorted(items)
    head = ", ".join(f"U+{cp:04X}" for cp in values[:limit])
    if len(values) > limit:
        head += f", ... (+{len(values) - limit} more)"
    return head or "none"


def assert_same(label: str, expected_label: str, expected: Set[int], actual: Set[int]) -> None:
    missing = expected - actual
    extra = actual - expected
    if missing or extra:
        raise RuntimeError(
            f"{label} does not match {expected_label}: "
            f"missing {len(missing)} [{summarize(missing)}]; "
            f"extra {len(extra)} [{summarize(extra)}]"
        )


def validate(project_dir: Path) -> tuple[int, int, int, bool]:
    css_path = project_dir / "data" / "styles.css"
    font_dir = project_dir / "data" / "resources" / "fonts"
    css_cps = parse_css_codepoints(css_path)
    woff2_cps = load_woff2_codepoints(font_dir / "ark12.woff2")

    targets = [
        ("data/resources/fonts/ark12.json", load_json_codepoints(font_dir / "ark12.json")),
    ]

    for label, cps in targets:
        assert_same(label, "data/resources/fonts/ark12.woff2 cmap", woff2_cps, cps)
    if css_cps is not None:
        assert_same("data/styles.css unicode-range", "data/resources/fonts/ark12.woff2 cmap", woff2_cps, css_cps)
    return len(woff2_cps), len(targets) + 1, len(load_json_codepoints(font_dir / "ark12.json")), css_cps is not None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", default=".", help="esp32s3_firmware project root")
    args = parser.parse_args(argv)

    project_dir = Path(args.project_dir).resolve()
    glyph_count, target_count, json_count, css_range_present = validate(project_dir)
    css_note = "CSS unicode-range checked" if css_range_present else "CSS unicode-range omitted"
    print(
        f"[ark12-sync] OK: ark12.woff2 and ark12.json cover "
        f"{glyph_count} codepoints ({target_count} asset maps checked; json glyphs={json_count}; {css_note})."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[ark12-sync] ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
