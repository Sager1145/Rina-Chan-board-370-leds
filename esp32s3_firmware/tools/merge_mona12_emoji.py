#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 Mona12 monochrome emoji glyphs 合并进 Ark12 字体资源。

Mona12Emoji 的 1200 UPEM 与 Ark Pixel 12px 的 12 像素网格对齐，脚本会把
emoji 当作 12x12 全宽字形处理，并同步更新 ark12.json、ark12.woff2 和
styles.css 的 unicode-range。已有 Ark 字形不会被覆盖。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from fontTools.ttLib import TTFont
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.transformPen import TransformPen

UPEM = 1200
PX = 100  # 处理 LED 矩阵、灯带刷新或硬件时序约束。
CELL = 12
ASCENT_PX = 10  # 说明字体、字形、Unicode 范围或 Web font 资源处理。
EMOJI_BITMAP_Y_OFFSET = -1
EMOJI_OUTLINE_Y_SHIFT_UNITS = -PX
CACHE_BUST = "20260612-emoji-input-v3"

# 处理 LED 矩阵、灯带刷新或硬件时序约束。
ZERO_WIDTH_RANGES = (
    (0xFE00, 0xFE0F),    # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    (0x200D, 0x200D),    # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    (0x1F3FB, 0x1F3FF),  # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    (0xE0000, 0xE007F),  # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
)


# 中文块：判断 codepoint 是否是 emoji 序列中的零宽控制字符。
def is_zero_width_control(cp: int) -> bool:
    return any(lo <= cp <= hi for lo, hi in ZERO_WIDTH_RANGES)


# 中文块：把 Unicode codepoint 格式化成 ark12.json 使用的十六进制 key。
def hex_key(cp: int) -> str:
    return f"{cp:04X}" if cp <= 0xFFFF else f"{cp:X}"


# ---------------------------------------------------------------------------
# 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
# 轮廓采样流程，把 Mona 字体的 polygon outline 转成 12x12 LED bitmap。
# ---------------------------------------------------------------------------

# 中文块：读取 Mona glyph 的 polygon contours，并拒绝带曲线控制点的字形。
def glyph_contours(glyf, name) -> List[List[Tuple[int, int]]]:
    g = glyf[name]
    if g.numberOfContours <= 0:
        return []
    coords, end_pts, flags = g.getCoordinates(glyf)
    if any(not (f & 1) for f in flags):
        raise RuntimeError(f"glyph {name} has off-curve points; expected pure polygons")
    contours = []
    start = 0
    for end in end_pts:
        contours.append([tuple(coords[i]) for i in range(start, end + 1)])
        start = end + 1
    return contours


# 中文块：用 nonzero winding rule 判断采样点是否落在轮廓内部。
def winding_contains(contours, px: float, py: float) -> bool:
    winding = 0
    for contour in contours:
        n = len(contour)
        for i in range(n):
            x1, y1 = contour[i]
            x2, y2 = contour[(i + 1) % n]
            if y1 == y2:
                continue
            if (y1 <= py < y2) or (y2 <= py < y1):
                t = (py - y1) / (y2 - y1)
                xi = x1 + t * (x2 - x1)
                if xi > px:
                    winding += 1 if y2 > y1 else -1
    return winding != 0


# 中文块：计算窄 emoji 在 12px 全宽单元格内的水平居中偏移。
def centering_shift(advance: int) -> int:
    """Horizontal shift (font units, snapped to the pixel grid) that centers a
    narrower-than-full-width Mona glyph inside the 12px kanji cell."""
    if advance >= UPEM or advance <= 0:
        return 0
    return ((UPEM - advance) // 2) // PX * PX


# 中文块：把轮廓按 12x12 像素中心采样成 LED bitmap 行。
def sample_bitmap(contours, shift_units: int) -> List[str]:
    """Sample a Mona glyph into 12 binary rows (top row first), 12 bits each."""
    rows = []
    for r in range(CELL):
        y = (ASCENT_PX - r) * PX - PX // 2  # 说明字体、字形、Unicode 范围或 Web font 资源处理。
        row_val = 0
        for c in range(CELL):
            x = c * PX + PX // 2 - shift_units
            if winding_contains(contours, x, y):
                row_val |= 1 << (CELL - 1 - c)
        rows.append(f"{row_val:03X}")
    return rows


# ---------------------------------------------------------------------------
# 说明字体、字形、Unicode 范围或 Web font 资源处理。
# 第一阶段写入 ark12.json，让固件和文字滚动路径能读取 emoji bitmap。
# ---------------------------------------------------------------------------

# 中文块：把可用 emoji bitmap 写入 ark12.json，并记录 sourceAdditions 元数据。
def patch_bitmap_json(json_path: Path, mona: TTFont, out_path: Optional[Path] = None) -> Tuple[int, int]:
    data = json.loads(json_path.read_text(encoding="utf-8"))
    if data.get("format") != "rina_ark_pixel_font_bitmap_v1":
        raise RuntimeError(f"Unexpected Ark bitmap JSON format: {json_path}")
    glyphs = data.get("glyphs")
    if not isinstance(glyphs, dict) or not glyphs:
        raise RuntimeError(f"Ark bitmap JSON has no glyph map: {json_path}")

    cmap = mona.getBestCmap()
    glyf = mona["glyf"]
    hmtx = mona["hmtx"]

    added = 0
    zero_width = 0
    for cp in sorted(cmap):
        key = hex_key(cp)
        if is_zero_width_control(cp):
            if key not in glyphs:
                glyphs[key] = [0, 0, 0, 0, 0, 0, ""]
                zero_width += 1
            continue
        if key in glyphs:
            continue  # 说明字体、字形、Unicode 范围或 Web font 资源处理。
        name = cmap[cp]
        contours = glyph_contours(glyf, name)
        if not contours:
            continue
        shift = centering_shift(hmtx[name][0])
        rows = sample_bitmap(contours, shift)
        if all(v == "000" for v in rows):
            continue
        # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
        # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
        glyphs[key] = [CELL, CELL, CELL, 0, EMOJI_BITMAP_Y_OFFSET, 0, "/".join(rows)]
        added += 1

    additions = data.setdefault("sourceAdditions", {})
    additions["Mona12Emoji"] = {
        "source": "MonadABXY/mona-font web/Mona12Emoji.woff2",
        "license": "SIL Open Font License 1.1",
        "glyphs": added,
        "zeroWidthControls": zero_width,
        "description": (
            "single-codepoint 12x12 monochrome emoji glyphs treated like kanji "
            "(advance 12, same cell/baseline); emoji format controls stored as "
            "zero-width blanks"
        ),
    }

    target = out_path or json_path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(data, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(
        f"[mona-merge] wrote {target} added={added} zero_width_controls={zero_width} total_glyphs={len(glyphs)}")
    return added, zero_width


# ---------------------------------------------------------------------------
# 说明字体、字形、Unicode 范围或 Web font 资源处理。
# 第二阶段把 Mona glyf 轮廓追加到 Ark CFF webfont，供浏览器文本路径使用。
# ---------------------------------------------------------------------------

# 中文块：把 Mona glyph 追加进 Ark CFF webfont，并扩展 cmap/hmtx/vmtx。
# 说明字体、字形、Unicode 范围或 Web font 资源处理。
# 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
# 说明字体、字形、Unicode 范围或 Web font 资源处理。
# 说明字体、字形、Unicode 范围或 Web font 资源处理。
MODIFIED_TABLE_TAGS = ("hmtx", "vmtx", "hhea", "vhea", "maxp", "cmap", "OS/2", "CFF ")


def _t2_push(v: int, out: bytearray) -> None:
    """Encode one integer operand as raw Type2 charstring bytes."""
    if -107 <= v <= 107:
        out.append(v + 139)
    elif 108 <= v <= 1131:
        v -= 108
        out.append(247 + (v >> 8))
        out.append(v & 0xFF)
    elif -1131 <= v <= -108:
        v = -v - 108
        out.append(251 + (v >> 8))
        out.append(v & 0xFF)
    else:
        out.append(28)
        out.append((v >> 8) & 0xFF)
        out.append(v & 0xFF)


def build_t2_bytecode(contours: List[List[Tuple[int, int]]], shift: int, width: int, private) -> bytes:
    """Hand-assemble Type2 bytecode for a pure-polygon glyph.

    Much faster than the pen pipeline for thousands of glyphs, and the raw
    bytecode passes straight through the CFF compiler untouched.
    """
    out = bytearray()
    default_w = int(getattr(private, "defaultWidthX", 0) or 0)
    nominal_w = int(getattr(private, "nominalWidthX", 0) or 0)
    pending_width: Optional[int] = None if width == default_w else width - nominal_w

    def emit(vals: List[int], op: int) -> None:
        for v in vals:
            _t2_push(int(v), out)
        out.append(op)

    cx = cy = 0
    for contour in contours:
        pts = [(x + shift, y + EMOJI_OUTLINE_Y_SHIFT_UNITS) for x, y in contour]
        x0, y0 = pts[0]
        vals = [x0 - cx, y0 - cy]
        if pending_width is not None:
            vals = [pending_width] + vals
            pending_width = None
        emit(vals, 21)  # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
        cx, cy = x0, y0
        deltas: List[int] = []
        for x, y in pts[1:]:
            deltas.append(x - cx)
            deltas.append(y - cy)
            cx, cy = x, y
        for i in range(0, len(deltas), 48):  # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
            emit(deltas[i: i + 48], 5)  # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    if pending_width is not None:
        emit([pending_width], 14)  # 说明字体、字形、Unicode 范围或 Web font 资源处理。
    else:
        out.append(14)  # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    return bytes(out)


def prep_addon_payload(
    ark_path: Path,
    addons: List[Tuple[TTFont, str]],
    payload_path: Path,
    prep_range: Optional[Tuple[int, int]] = None,
) -> int:
    """Phase 'prep': precompute T2 bytecode for every addon glyph.

    The bytecode does not depend on the base font's Private dict values other
    than defaultWidthX/nominalWidthX, which we read from the base lazily.
    Output: pickle list of (cp, new_name, bytecode, advance, lsb).

    prep_range=(start, end) processes only that slice of the work list and
    writes a "<payload>.part_<start>_<end>" file, so very large addons can be
    prepared across several short runs; the merge phase reads all parts.
    """
    import pickle

    ark = TTFont(str(ark_path), lazy=True)
    ark_cmap_all = ark.getBestCmap()
    cff = ark["CFF "].cff
    private = cff[cff.fontNames[0]].Private

    work: List[Tuple[TTFont, str, int]] = []
    seen: set = set()
    for mona, name_prefix in addons:
        for cp in sorted(mona.getBestCmap()):
            if cp in ark_cmap_all or cp in seen:
                continue
            work.append((mona, name_prefix, cp))
            seen.add(cp)

    out_path = payload_path
    if prep_range is not None:
        start, end = prep_range
        work = work[start:end]
        out_path = payload_path.with_name(payload_path.name + f".part_{start}_{end}")

    entries: List[Tuple[int, str, bytes, int, int]] = []
    for mona, name_prefix, cp in work:
        mona_cmap = mona.getBestCmap()
        mona_glyf = mona["glyf"]
        mona_hmtx = mona["hmtx"]
        src_name = mona_cmap[cp]
        new_name = f"{name_prefix}{hex_key(cp)}"
        zero = is_zero_width_control(cp) or mona_glyf[src_name].numberOfContours <= 0
        width = 0 if zero else UPEM
        if zero:
            contours: List[List[Tuple[int, int]]] = []
            shift = 0
            lsb = 0
        else:
            shift = centering_shift(mona_hmtx[src_name][0])
            contours = glyph_contours(mona_glyf, src_name)
            lsb = mona_glyf[src_name].xMin + shift
        bytecode = build_t2_bytecode(contours, shift, width, private)
        entries.append((cp, new_name, bytecode, width, lsb))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    tmp.write_bytes(pickle.dumps(entries))
    tmp.replace(out_path)  # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    print(
        f"[mona-merge] wrote addon payload {out_path} ({len(entries)} glyphs of {len(seen)} total work items)")
    return len(entries)


def load_payload_entries(payload_path: Path) -> List[Tuple[int, str, bytes, int, int]]:
    """Load the payload pickle, or the union of its .part_* files."""
    import pickle

    if payload_path.exists():
        return pickle.loads(payload_path.read_bytes())
    parts = sorted(payload_path.parent.glob(payload_path.name + ".part_*"))
    if not parts:
        raise RuntimeError(
            f"No addon payload found: {payload_path}(.part_*) — run --woff2-phase prep first")
    entries: List[Tuple[int, str, bytes, int, int]] = []
    seen: set = set()
    for part in parts:
        for entry in pickle.loads(part.read_bytes()):
            if entry[0] not in seen:
                entries.append(entry)
                seen.add(entry[0])
    entries.sort(key=lambda e: e[0])
    return entries


def merge_webfont(ark_path: Path, payload_path: Path, blob_path: Path) -> List[int]:
    """Phase 'merge': splice precomputed addon charstrings into the Ark CFF."""
    import pickle

    from fontTools.misc.psCharStrings import T2CharString

    entries = load_payload_entries(payload_path)

    ark = TTFont(str(ark_path), lazy=True)
    ark.recalcBBoxes = False  # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    if "CFF " not in ark:
        raise RuntimeError(f"{ark_path} is not a CFF (OTTO) font")

    ark_cmap_all = ark.getBestCmap()

    cff = ark["CFF "].cff
    top_dict = cff[cff.fontNames[0]]
    char_strings = top_dict.CharStrings
    private = top_dict.Private
    glyph_order = ark.getGlyphOrder()
    existing_names = set(glyph_order)

    # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    kanji_name = ark_cmap_all.get(0x6C38) or next(iter(ark_cmap_all.values()))
    v_template = ark["vmtx"][kanji_name] if "vmtx" in ark else (UPEM, 0)

    added_map: Dict[int, str] = {}
    for cp, new_name, bytecode, advance, lsb in entries:
        if cp in ark_cmap_all or new_name in existing_names:
            continue
        charstring = T2CharString(
            bytecode=bytecode,
            private=private,
            globalSubrs=char_strings.globalSubrs,
        )
        char_strings.charStringsIndex.append(charstring)
        char_strings.charStrings[new_name] = len(char_strings.charStringsIndex) - 1
        # 说明字体、字形、Unicode 范围或 Web font 资源处理。
        # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
        if top_dict.charset is not glyph_order:
            top_dict.charset.append(new_name)
        glyph_order.append(new_name)
        existing_names.add(new_name)
        ark["hmtx"][new_name] = (advance, lsb)
        if "vmtx" in ark:
            ark["vmtx"][new_name] = v_template
        added_map[cp] = new_name

    added = sorted(added_map)
    ark.setGlyphOrder(glyph_order)
    ark["maxp"].numGlyphs = len(glyph_order)

    # 说明字体、字形、Unicode 范围或 Web font 资源处理。
    for table in ark["cmap"].tables:
        for cp, new_name in added_map.items():
            if table.format == 12 or (table.format == 4 and cp <= 0xFFFF):
                table.cmap[cp] = new_name

    # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    try:
        ark["OS/2"].ulUnicodeRange2 |= 1 << (57 - 32)
    except Exception:
        pass

    # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    import pickle

    blobs: Dict[str, bytes] = {}
    for tag in MODIFIED_TABLE_TAGS:
        if tag in ark:
            blobs[tag] = ark[tag].compile(ark)
    blob_path.parent.mkdir(parents=True, exist_ok=True)
    blob_path.write_bytes(pickle.dumps(blobs))
    print(
        f"[mona-merge] wrote intermediate {blob_path} (+{len(added)} glyphs, "
        f"{ark['maxp'].numGlyphs} total, tables: {', '.join(blobs)})"
    )
    return added


def compress_webfont(ark_path: Path, blob_path: Path, out_paths: List[Path]) -> None:
    """Splice the recompiled tables into the original sfnt and emit woff2."""
    import pickle
    import shutil
    from io import BytesIO
    from fontTools.ttLib.sfnt import SFNTReader, SFNTWriter
    from fontTools.ttLib.woff2 import compress as woff2_compress

    blobs: Dict[str, bytes] = pickle.loads(blob_path.read_bytes())
    with open(ark_path, "rb") as f:
        reader = SFNTReader(f)  # 说明字体、字形、Unicode 范围或 Web font 资源处理。
        tags = [t for t in reader.keys() if t != "GlyphOrder"]
        raw = {tag: (blobs.get(tag) or reader[tag]) for tag in tags}

    buf = BytesIO()
    writer = SFNTWriter(buf, len(tags), "OTTO")
    for tag in tags:
        writer[tag] = raw[tag]
    writer.close()  # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。

    tmp_otf = blob_path.with_suffix(".otf")
    tmp_otf.write_bytes(buf.getvalue())
    tmp_woff2 = blob_path.with_suffix(".woff2")
    woff2_compress(str(tmp_otf), str(tmp_woff2))

    for path in out_paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        # 处理 LED 矩阵、灯带刷新或硬件时序约束。
        tmp_target = path.with_suffix(path.suffix + ".tmp")
        shutil.copyfile(tmp_woff2, tmp_target)
        tmp_target.replace(path)
        print(f"[mona-merge] wrote {path} ({path.stat().st_size} bytes)")
    for p in (tmp_otf, tmp_woff2):
        try:
            p.unlink(missing_ok=True)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# 说明字体、字形、Unicode 范围或 Web font 资源处理。
# ---------------------------------------------------------------------------

# 中文块：把 codepoint 集合压缩成 CSS unicode-range 片段。
def format_unicode_ranges(cps: List[int]) -> str:
    cps = sorted(set(cps))
    ranges = []
    start = prev = cps[0]
    for cp in cps[1:]:
        if cp == prev + 1:
            prev = cp
            continue
        ranges.append((start, prev))
        start = prev = cp
    ranges.append((start, prev))
    parts = [f"U+{a:04X}" if a == b else f"U+{a:04X}-{b:04X}" for a, b in ranges]
    lines = []
    for i in range(0, len(parts), 8):
        lines.append("      " + ", ".join(parts[i: i + 8]))
    return ",\n".join(lines)


# 中文块：patch_styles_css 是 merge 流程中的独立处理步骤。
def patch_styles_css(css_path: Path, merged_woff2: Path, cache_bust: str = CACHE_BUST) -> None:
    css = css_path.read_text(encoding="utf-8")
    merged = TTFont(str(merged_woff2))
    cps = sorted(merged.getBestCmap())

    # 说明字体、字形、Unicode 范围或 Web font 资源处理。
    css, n_ver = re.subn(
        r'(/resources/fonts/ark12\.woff2\?v=)[0-9A-Za-z\-]+',
        r"\g<1>" + cache_bust + "-base",
        css,
    )
    if not n_ver:
        raise RuntimeError("Could not find ark12.woff2 ?v= cache-bust token in styles.css")

    # 说明字体、字形、Unicode 范围或 Web font 资源处理。
    face_re = re.compile(
        r'(@font-face\s*\{[^}]*?ark12\.woff2[^}]*?unicode-range:\n)(.*?)(;\n\s*\})',
        re.DOTALL,
    )
    m = face_re.search(css)
    if not m:
        raise RuntimeError(
            "Could not locate base ark12.woff2 @font-face unicode-range block in styles.css")
    css = css[: m.start(2)] + format_unicode_ranges(cps) + css[m.end(2):]

    css_path.write_text(css, encoding="utf-8")
    print(
        f"[mona-merge] patched {css_path}: cache-bust -> {cache_bust}-base, unicode-range rebuilt ({len(cps)} codepoints)")


# ---------------------------------------------------------------------------

# 中文块：解析 CLI 参数并依次执行 bitmap、webfont 和 CSS patch。
def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mona-font", required=True,
                    help="Input addon WOFF2/TTF (Mona12Emoji, ark12_fallback, ...). Must be a glyf font with pure polygon outlines on the 100-unit pixel grid.")
    ap.add_argument("--project-dir", default=".", help="esp32s3_firmware project root")
    ap.add_argument("--glyph-prefix", default="mona",
                    help="Prefix for new glyph names in the merged CFF (default: mona)")
    ap.add_argument(
        "--extra-addon",
        action="append",
        default=[],
        metavar="PATH:PREFIX",
        help="Additional addon font merged in the same webfont pass (e.g. ark12_fallback.woff2:fb). Repeatable.",
    )
    ap.add_argument("--cache-bust", default=CACHE_BUST,
                    help="Cache-bust token written into styles.css ?v= for ark12.woff2")
    ap.add_argument("--skip-json", action="store_true")
    ap.add_argument("--skip-woff2", action="store_true")
    ap.add_argument("--skip-css", action="store_true")
    ap.add_argument(
        "--woff2-phase",
        choices=["all", "prep", "merge", "compress"],
        default="all",
        help="Split the slow webfont step: 'prep' precomputes addon charstring bytecode, 'merge' splices it into the CFF and compiles the modified tables, 'compress' assembles the final sfnt and brotli-compresses it to the woff2 targets.",
    )
    ap.add_argument(
        "--prep-range",
        default=None,
        metavar="START:END",
        help="Process only this slice of the prep work list (writes a .part file). Useful on slow machines; merge reads all parts.",
    )
    args = ap.parse_args(argv)

    root = Path(args.project_dir).resolve()
    mona = TTFont(args.mona_font)

    json_targets = [
        root / "data" / "resources" / "fonts" / "ark12.json",
        root / "tools" / "font_fusion" / "ark12_fusion.json",
    ]
    woff2_main = root / "data" / "resources" / "fonts" / "ark12.woff2"
    woff2_targets = [woff2_main, root / "tools" / "font_fusion" / "ark12_base.woff2"]
    css_path = root / "data" / "styles.css"

    if not args.skip_json:
        for target in json_targets:
            if target.exists():
                patch_bitmap_json(target, mona)
            else:
                print(f"[mona-merge] skip missing {target}")

    # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    # 说明 Mona12 emoji 合并 中当前代码块的职责和维护约束。
    import tempfile

    tmp_dir = Path(tempfile.gettempdir())
    blob_path = tmp_dir / f"ark12_{args.glyph_prefix}_merged_tables.pickle"
    payload_path = tmp_dir / f"ark12_{args.glyph_prefix}_addon_payload.pickle"
    if not args.skip_woff2:
        if args.woff2_phase in ("all", "prep"):
            addons: List[Tuple[TTFont, str]] = [(mona, args.glyph_prefix)]
            for spec in args.extra_addon:
                path, _, prefix = spec.rpartition(":")
                if not path or not prefix:
                    raise SystemExit(f"--extra-addon expects PATH:PREFIX, got: {spec}")
                addons.append((TTFont(path), prefix))
            prep_range = None
            if args.prep_range:
                s, _, e = args.prep_range.partition(":")
                prep_range = (int(s), int(e))
            prep_addon_payload(woff2_main, addons, payload_path, prep_range=prep_range)
        if args.woff2_phase in ("all", "merge"):
            merge_webfont(woff2_main, payload_path, blob_path)
        if args.woff2_phase in ("all", "compress"):
            compress_webfont(woff2_main, blob_path, woff2_targets)
            for p in (blob_path, payload_path):
                try:
                    p.unlink(missing_ok=True)
                except OSError:
                    pass

    if not args.skip_css:
        patch_styles_css(css_path, woff2_main, cache_bust=args.cache_bust)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
