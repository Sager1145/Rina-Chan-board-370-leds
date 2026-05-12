#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build the small offline GNU Unifont WebUI WOFF2 subset from an official GNU
Unifont PNG glyph sheet.

No GNU Unifont binary font is shipped in this patch. The PowerShell runner
fetches the official PNG into .font_cache and calls this script to generate:

    data/resources/fonts/unifont.woff2

The subset covers the current WebUI text plus stable UI ranges so LittleFS does
not need a multi-megabyte full OTF/TTF font.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Iterable, Set

try:
    from PIL import Image
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
except Exception as exc:  # pragma: no cover - user-facing dependency error
    print(
        "[unifont-build] Missing Python dependency. Install with: "
        "python -m pip install --user pillow fonttools brotli",
        file=sys.stderr,
    )
    print(f"[unifont-build] Import error: {exc}", file=sys.stderr)
    raise SystemExit(20)

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "data/resources/fonts/unifont.woff2"
DEFAULT_TEXT_FILES = [
    ROOT / "data/index.html",
    ROOT / "data/resources/saved_faces.json",
    ROOT / "data/resources/runtime_settings.json",
    ROOT / "README.md",
    ROOT / "EXTERNAL_CODE_COMMENTS.txt",
    ROOT / "plan.md",
]

# GNU Unifont PNG layout for the BMP sheet published by GNU/Unifoundry.
XOFF = 32
YOFF = 64
CELL = 16
COLS = 256
UPM = 16
ASCENT = 14
DESCENT = -2


def add_range(codepoints: Set[int], start: int, end: int) -> None:
    codepoints.update(range(start, end + 1))


def collect_codepoints(text_files: Iterable[Path]) -> Set[int]:
    codepoints: Set[int] = set()

    # Stable UI/basic coverage. Keep these broad enough that future labels do
    # not immediately require regenerating a different subset recipe.
    add_range(codepoints, 0x0020, 0x007E)  # ASCII
    add_range(codepoints, 0x00A0, 0x00FF)  # Latin-1 punctuation/symbols
    add_range(codepoints, 0x2000, 0x206F)  # General punctuation
    add_range(codepoints, 0x2100, 0x214F)  # Letterlike symbols
    add_range(codepoints, 0x2190, 0x21FF)  # Arrows
    add_range(codepoints, 0x25A0, 0x25FF)  # Geometric shapes
    add_range(codepoints, 0x3000, 0x303F)  # CJK punctuation
    add_range(codepoints, 0x3040, 0x309F)  # Hiragana
    add_range(codepoints, 0x30A0, 0x30FF)  # Katakana
    add_range(codepoints, 0x31F0, 0x31FF)  # Katakana phonetic extensions
    add_range(codepoints, 0xFF00, 0xFFEF)  # Fullwidth forms

    for p in text_files:
        if not p.exists():
            continue
        text = p.read_text(encoding="utf-8", errors="ignore")
        for ch in text:
            cp = ord(ch)
            if 0x20 <= cp <= 0xFFFF:
                codepoints.add(cp)

    # Avoid browser emoji fallback artifacts from variation selectors.
    codepoints.discard(0xFE0F)
    return codepoints


def glyph_runs(px, cp: int):
    row = cp // COLS
    col = cp % COLS
    x0 = XOFF + col * CELL
    y0 = YOFF + row * CELL
    runs = []
    max_x = -1
    for y in range(CELL):
        x = 0
        while x < CELL:
            while x < CELL and px[x0 + x, y0 + y] != 0:
                x += 1
            if x >= CELL:
                break
            start = x
            while x < CELL and px[x0 + x, y0 + y] == 0:
                x += 1
            end = x
            runs.append((start, y, end, y + 1))
            max_x = max(max_x, end - 1)
    return runs, max_x


def make_glyph(px, cp=None):
    pen = TTGlyphPen(None)
    if cp is None:
        return pen.glyph(), 8
    runs, max_x = glyph_runs(px, cp)
    for x1, y1, x2, y2 in runs:
        # Convert image top-left coordinates to TrueType y-up coordinates.
        pen.moveTo((x1, UPM - y1))
        pen.lineTo((x2, UPM - y1))
        pen.lineTo((x2, UPM - y2))
        pen.lineTo((x1, UPM - y2))
        pen.closePath()
    width = 16 if max_x >= 8 else 8
    return pen.glyph(), width


def build_subset(png_path: Path, out_path: Path, version: str) -> None:
    if not png_path.exists():
        raise FileNotFoundError(f"GNU Unifont PNG is missing: {png_path}")

    im = Image.open(png_path).convert("1")
    required_width = XOFF + COLS * CELL
    required_height = YOFF + 256 * CELL
    if im.width < required_width or im.height < required_height:
        raise ValueError(
            f"Unexpected GNU Unifont PNG dimensions {im.width}x{im.height}; "
            f"expected at least {required_width}x{required_height}."
        )
    px = im.load()

    ordered = sorted(collect_codepoints(DEFAULT_TEXT_FILES))
    glyph_order = [".notdef"] + [f"u{cp:04X}" for cp in ordered]
    char_map = {cp: f"u{cp:04X}" for cp in ordered}

    glyphs = {}
    metrics = {}
    glyphs[".notdef"], _ = make_glyph(px, None)
    metrics[".notdef"] = (8, 0)
    for cp in ordered:
        name = char_map[cp]
        glyphs[name], width = make_glyph(px, cp)
        metrics[name] = (width, 0)

    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap(char_map)
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT)
    fb.setupOS2(
        sTypoAscender=ASCENT,
        sTypoDescender=DESCENT,
        usWinAscent=16,
        usWinDescent=2,
        sxHeight=8,
        sCapHeight=12,
        ulUnicodeRange1=0xFFFFFFFF,
        ulUnicodeRange2=0xFFFFFFFF,
        ulUnicodeRange3=0xFFFFFFFF,
        ulUnicodeRange4=0xFFFFFFFF,
    )
    fb.setupNameTable(
        {
            "familyName": "GNU Unifont",
            "styleName": "Regular",
            "uniqueFontIdentifier": f"GNU Unifont {version} WebUI Offline Subset",
            "fullName": "GNU Unifont WebUI Offline Subset",
            "psName": "GNUUnifont-WebUIOfflineSubset",
            "version": f"Version {version}-webui-offline-subset",
            "manufacturer": "Unifoundry / WebUI subset generated for RinaChanBoard",
            "licenseDescription": (
                "GNU Unifont is distributed under the SIL Open Font License 1.1 "
                "and GPLv2+ with font embedding exception."
            ),
        }
    )
    fb.setupPost()

    font = fb.font
    font["head"].macStyle = 0
    font["OS/2"].fsSelection = 0x40  # regular
    font.flavor = "woff2"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    font.save(str(out_path))
    print(f"[unifont-build] wrote {out_path} glyphs={len(glyph_order)} size={out_path.stat().st_size} bytes")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--png", required=True, help="Path to official GNU Unifont BMP PNG sheet.")
    ap.add_argument("--out", default=str(DEFAULT_OUT), help="Output WOFF2 path.")
    ap.add_argument("--version", default="17.0.04")
    args = ap.parse_args(argv)

    build_subset(Path(args.png).resolve(), Path(args.out).resolve(), args.version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
