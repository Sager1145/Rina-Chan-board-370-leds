#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# This script builds the Unifont subset used by the WebUI from the PNG glyph table; necessary English parameter names are kept consistent with CLI/API.
"""
Build and embed the small offline GNU Unifont WebUI WOFF2 subset from an
official GNU Unifont BMP PNG glyph sheet.

Outputs:
    A WOFF2 subset file written to --out. In the current (standalone) mode the
    run script writes it to data/resources/fonts/unifont.woff2 and rewrites the
    GNU Unifont @font-face in data/styles.css to reference that file via url()
    (see --external-css / --external-href).

    The legacy --embed-index mode (base64 data: URL inlined into the CSS) is
    still supported for backward compatibility, but the WebUI now prefers the
    standalone LittleFS file /resources/fonts/unifont.woff2, which index.html
    preloads first so it loads before the rest of the WebUI fonts.

The character set is collected from the current WebUI files, filtered to glyphs
that can actually be produced from the BMP PNG sheet, and verified after build.
Unsupported characters, such as non-BMP emoji, are reported and intentionally
not added to the subset.
"""
from __future__ import annotations

import argparse
import base64
import re
import sys
import unicodedata
from pathlib import Path
from typing import Iterable, Sequence, Set

try:
    from PIL import Image
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib import TTFont
except Exception as exc:  # pragma: no cover - user-facing dependency error, keep test coverage tool directive.
    print(
        "[unifont-build] Missing Python dependency. Install with: "
        "python -m pip install --user pillow fonttools brotli",
        file=sys.stderr,
    )
    print(f"[unifont-build] Import error: {exc}", file=sys.stderr)
    raise SystemExit(20)

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / ".font_cache/unifont_webui_embedded_tmp.woff2"
DEFAULT_INDEX = ROOT / "data/index.html"
DEFAULT_TEXT_FILES = [
    ROOT / "data/index.html",
    ROOT / "data/styles.css",
    ROOT / "data/app.js",
    ROOT / "data/resources/saved_faces.json",
    ROOT / "data/resources/runtime_settings.json",
    ROOT / "data/resources/battery_calib.json",
]

XOFF = 32
YOFF = 64
CELL = 16
COLS = 256
ROWS = 256
UPM = 16
ASCENT = 14
DESCENT = -2
BMP_MAX = 0xFFFF

INTENTIONAL_BLANKS = {
    0x0020,
    0x00A0,
    0x3000,
}

VARIATION_SELECTOR_RANGES = (
    range(0xFE00, 0xFE10),
)

FONT_DATA_URL_RE = re.compile(r"data:font/woff2;base64,[A-Za-z0-9+/=\r\n]+")
STYLE_OPEN_RE = re.compile(r"(<style[^>]*>\s*)", re.I)
UNIFONT_FACE_BLOCK_RE = re.compile(
    r"@font-face\s*\{(?=[^{}]*font-family\s*:\s*['\"]GNU Unifont['\"])[^{}]*\}",
    re.S,
)
UNIFONT_FACE_DATA_RE = re.compile(
    r"@font-face\s*\{(?=[^{}]*font-family\s*:\s*['\"]GNU Unifont['\"])(?=[^{}]*data:font/woff2;base64,([A-Za-z0-9+/=\r\n]+))[^{}]*\}",
    re.S,
)


def add_range(codepoints: Set[int], start: int, end: int) -> None:
    codepoints.update(range(start, end + 1))


def is_variation_selector(cp: int) -> bool:
    return any(cp in r for r in VARIATION_SELECTOR_RANGES)


def strip_embedded_font_payloads(text: str) -> str:
    return FONT_DATA_URL_RE.sub("data:font/woff2;base64,", text)


def collect_raw_codepoints(text_files: Iterable[Path]) -> Set[int]:
    codepoints: Set[int] = set()

    add_range(codepoints, 0x0020, 0x007E)
    add_range(codepoints, 0x00A0, 0x00FF)
    add_range(codepoints, 0x2000, 0x206F)
    add_range(codepoints, 0x2100, 0x214F)
    add_range(codepoints, 0x2190, 0x21FF)
    add_range(codepoints, 0x25A0, 0x25FF)
    add_range(codepoints, 0x2700, 0x27BF)
    add_range(codepoints, 0x3000, 0x303F)
    add_range(codepoints, 0x3040, 0x309F)
    add_range(codepoints, 0x30A0, 0x30FF)
    add_range(codepoints, 0x31F0, 0x31FF)
    add_range(codepoints, 0xFF00, 0xFFEF)

    for p in text_files:
        if not p.exists():
            continue
        text = p.read_text(encoding="utf-8", errors="ignore")
        if p.name.lower().endswith((".html", ".css", ".js")):
            text = strip_embedded_font_payloads(text)
        for ch in text:
            cp = ord(ch)
            if cp >= 0x20:
                codepoints.add(cp)

    return codepoints


def glyph_pixel_bounds(cp: int) -> tuple[int, int]:
    row = cp // COLS
    col = cp % COLS
    return XOFF + col * CELL, YOFF + row * CELL


def glyph_runs(px, cp: int):
    x0, y0 = glyph_pixel_bounds(cp)
    runs = []
    max_x = -1
    ink = 0
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
            ink += end - start
            max_x = max(max_x, end - 1)
    return runs, max_x, ink


def is_available_from_png(px, cp: int) -> bool:
    if cp < 0 or cp > BMP_MAX:
        return False
    if is_variation_selector(cp):
        return False
    row = cp // COLS
    if row >= ROWS:
        return False
    _runs, _max_x, ink = glyph_runs(px, cp)
    if ink > 0:
        return True
    if cp in INTENTIONAL_BLANKS:
        return True
    return unicodedata.category(chr(cp)).startswith("Z")


def filter_codepoints_for_png(px, raw: Set[int]) -> tuple[Set[int], Set[int]]:
    supported: Set[int] = set()
    skipped: Set[int] = set()
    for cp in raw:
        if is_available_from_png(px, cp):
            supported.add(cp)
        else:
            skipped.add(cp)
    return supported, skipped


def is_zero_advance_codepoint(cp: int) -> bool:
    return unicodedata.category(chr(cp)) == "Cf"


def is_fullwidth_codepoint(cp: int) -> bool:
    ch = chr(cp)
    if unicodedata.east_asian_width(ch) in {"F", "W"}:
        return True
    return (
        0x3040 <= cp <= 0x30FF
        or 0x31F0 <= cp <= 0x31FF
        or 0x3400 <= cp <= 0x9FFF
        or 0xF900 <= cp <= 0xFAFF
    )


def glyph_advance_width(cp: int, max_x: int) -> int:
    if is_zero_advance_codepoint(cp):
        return 0
    if cp == 0x3000 or is_fullwidth_codepoint(cp):
        return 16
    return 16 if max_x >= 8 else 8


def make_glyph(px, cp=None):
    pen = TTGlyphPen(None)
    if cp is None:
        return pen.glyph(), 8, 0
    runs, max_x, _ink = glyph_runs(px, cp)
    min_x = min((x1 for x1, _y1, _x2, _y2 in runs), default=0)
    for x1, y1, x2, y2 in runs:
        pen.moveTo((x1, UPM - y1))
        pen.lineTo((x2, UPM - y1))
        pen.lineTo((x2, UPM - y2))
        pen.lineTo((x1, UPM - y2))
        pen.closePath()
    width = glyph_advance_width(cp, max_x)
    lsb = min_x if width > 0 else 0
    return pen.glyph(), width, lsb


def cmap_codepoints(font_path: Path) -> Set[int]:
    font = TTFont(str(font_path))
    found: Set[int] = set()
    for table in font["cmap"].tables:
        found.update(table.cmap.keys())
    return found


def format_codepoints(codepoints: Sequence[int], limit: int = 40) -> str:
    shown = []
    for cp in list(codepoints)[:limit]:
        try:
            ch = chr(cp)
            name = unicodedata.name(ch, "UNNAMED")
            shown.append(f"U+{cp:04X} {ch!r} {name}")
        except ValueError:
            shown.append(f"U+{cp:04X}")
    if len(codepoints) > limit:
        shown.append(f"... +{len(codepoints) - limit} more")
    return "; ".join(shown)


def make_embedded_unifont_face(font_path: Path) -> str:
    encoded = base64.b64encode(font_path.read_bytes()).decode("ascii")
    return (
        '@font-face{font-family:"GNU Unifont";'
        f'src:url("data:font/woff2;base64,{encoded}") format("woff2");'
        'font-weight:400;font-style:normal;font-display:block;}'
    )


def embedded_unifont_bytes_from_html(html: str) -> bytes:
    match = UNIFONT_FACE_DATA_RE.search(html)
    if not match:
        raise RuntimeError("Embedded GNU Unifont data URL was not found in the target file.")
    return base64.b64decode(match.group(1))


def embed_font_in_index(index_path: Path, font_path: Path) -> None:
    html = index_path.read_text(encoding="utf-8")
    face = make_embedded_unifont_face(font_path)
    updated, count = UNIFONT_FACE_BLOCK_RE.subn(lambda _m: face, html, count=1)
    if count == 0:
        updated, count = STYLE_OPEN_RE.subn(lambda m: m.group(1) + face + "\n  ", html, count=1)
    if count != 1:
        raise RuntimeError(
            "Could not locate or insert the GNU Unifont @font-face block in the target file."
        )

    face_match = UNIFONT_FACE_BLOCK_RE.search(updated)
    if not face_match:
        raise RuntimeError("GNU Unifont @font-face block missing after embedding.")
    face_block = face_match.group(0)
    forbidden = ("local(", "resources/fonts/unifont.woff2", "/resources/fonts/unifont.woff2")
    if any(token in face_block for token in forbidden):
        raise RuntimeError("GNU Unifont @font-face still contains a local or external font source.")
    if embedded_unifont_bytes_from_html(updated) != font_path.read_bytes():
        raise RuntimeError("Embedded GNU Unifont bytes do not match the generated WOFF2 file.")

    with index_path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(updated)
    print(f"[unifont-build] embedded {font_path.name} into {index_path}")


def make_external_unifont_face(href: str) -> str:
    return (
        '@font-face{font-family:"GNU Unifont";'
        f'src:url("{href}") format("woff2");'
        'font-weight:400;font-style:normal;font-display:block;}'
    )


# And verify that no base64 data URI remains.
def set_external_font_in_css(css_path: Path, href: str) -> None:
    css = css_path.read_text(encoding="utf-8")
    face = make_external_unifont_face(href)
    updated, count = UNIFONT_FACE_BLOCK_RE.subn(lambda _m: face, css, count=1)
    if count != 1:
        raise RuntimeError(
            f"Could not locate the GNU Unifont @font-face block to rewrite in {css_path}."
        )
    block_match = UNIFONT_FACE_BLOCK_RE.search(updated)
    if not block_match:
        raise RuntimeError("GNU Unifont @font-face block missing after rewrite.")
    block = block_match.group(0)
    if "data:font/woff2;base64," in block:
        raise RuntimeError("GNU Unifont @font-face still contains an embedded data URL.")
    if href not in block:
        raise RuntimeError("GNU Unifont @font-face does not reference the external href.")
    with css_path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(updated)
    print(f"[unifont-build] pointed GNU Unifont @font-face at {href} in {css_path}")


def build_subset(
    png_path: Path,
    out_path: Path,
    version: str,
    text_files: Iterable[Path],
    embed_index: Path | None,
    external_css: Path | None = None,
    external_href: str = "/resources/fonts/unifont.woff2",
) -> None:
    if not png_path.exists():
        raise FileNotFoundError(f"GNU Unifont PNG is missing: {png_path}")

    im = Image.open(png_path).convert("1")
    required_width = XOFF + COLS * CELL
    required_height = YOFF + ROWS * CELL
    if im.width < required_width or im.height < required_height:
        raise ValueError(
            f"Unexpected GNU Unifont PNG dimensions {im.width}x{im.height}; "
            f"expected at least {required_width}x{required_height}."
        )
    px = im.load()

    raw = collect_raw_codepoints(text_files)
    codepoints, skipped = filter_codepoints_for_png(px, raw)
    ordered = sorted(codepoints)
    glyph_order = [".notdef"] + [f"u{cp:04X}" for cp in ordered]
    char_map = {cp: f"u{cp:04X}" for cp in ordered}

    glyphs = {}
    metrics = {}
    glyphs[".notdef"], notdef_width, notdef_lsb = make_glyph(px, None)
    metrics[".notdef"] = (notdef_width, notdef_lsb)
    for cp in ordered:
        name = char_map[cp]
        glyphs[name], width, lsb = make_glyph(px, cp)
        metrics[name] = (width, lsb)

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
    font["OS/2"].fsSelection = 0x40
    font.flavor = "woff2"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    font.save(str(out_path))

    built_cmap = cmap_codepoints(out_path)
    missing = sorted(codepoints - built_cmap)
    if missing:
        raise RuntimeError(
            "Generated font is missing supported WebUI codepoints: "
            + format_codepoints(missing)
        )

    if embed_index is not None:
        embed_font_in_index(embed_index, out_path)
        html = embed_index.read_text(encoding="utf-8")
        probe = out_path.with_suffix(".embedded-check.woff2")
        try:
            probe.write_bytes(embedded_unifont_bytes_from_html(html))
            embedded_cmap = cmap_codepoints(probe)
        finally:
            probe.unlink(missing_ok=True)
        if embedded_cmap != built_cmap:
            raise RuntimeError("Embedded GNU Unifont cmap does not match generated font.")

    if external_css is not None:
        set_external_font_in_css(external_css, external_href)

    print(
        f"[unifont-build] wrote {out_path} glyphs={len(glyph_order)} "
        f"chars={len(codepoints)} size={out_path.stat().st_size} bytes"
    )
    if skipped:
        print(
            "[unifont-build] skipped unsupported/unusable codepoints: "
            + format_codepoints(sorted(skipped))
        )


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--png", required=True, help="Path to official GNU Unifont BMP PNG sheet.")
    ap.add_argument("--out", default=str(DEFAULT_OUT), help="Output WOFF2 path.")
    ap.add_argument("--version", default="17.0.04")
    ap.add_argument(
        "--text-file",
        action="append",
        default=None,
        help="File to scan for WebUI characters. Can be passed multiple times.",
    )
    ap.add_argument(
        "--embed-index",
        default=str(DEFAULT_INDEX),
        help="(legacy) CSS/HTML file whose GNU Unifont @font-face should be replaced with an "
             "inline base64 data: URL. Use empty string to disable. Ignored when --external-css is set.",
    )
    ap.add_argument(
        "--external-css",
        default="",
        help="CSS file whose GNU Unifont @font-face should be rewritten to reference the standalone "
             "WOFF2 via url(). When set, the standalone (non-embedded) mode is used and --embed-index "
             "is ignored.",
    )
    ap.add_argument(
        "--external-href",
        default="/resources/fonts/unifont.woff2",
        help="url() value written into the GNU Unifont @font-face when --external-css is used "
             "(may include a ?v= cache-busting query).",
    )
    args = ap.parse_args(argv)

    text_files = [Path(p).resolve() for p in args.text_file] if args.text_file else DEFAULT_TEXT_FILES
    external_css = Path(args.external_css).resolve() if args.external_css else None
    embed_index = None if external_css is not None else (
        Path(args.embed_index).resolve() if args.embed_index else None
    )
    build_subset(
        Path(args.png).resolve(),
        Path(args.out).resolve(),
        args.version,
        text_files,
        embed_index,
        external_css=external_css,
        external_href=args.external_href,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
