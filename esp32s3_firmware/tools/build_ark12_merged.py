#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# This script merges Ark Pixel BDF fonts and generates firmware/WebUI readable JSON; necessary English parameter names are kept consistent with CLI/API.
"""
Build a merged Ark Pixel 12px monospaced bitmap JSON for RinaChanBoard.

Default merge priority, low -> high:
  zh_cn  -> simplified Chinese base
  ja     -> Japanese glyphs fill/override simplified where zh_tw does not replace later
  zh_tw  -> traditional Chinese final authority for same Unicode codepoints

The output JSON uses the existing rina_ark_pixel_font_bitmap_v1 structure:
  glyphs[HEX_CODEPOINT] = [advance, width, height, xOffset, yOffset, dstY, "HEX/ROWS"]
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

EXPECTED_OFFICIAL_ARK12_MONO_COUNT = 24408

@dataclass
class BdfGlyph:
    codepoint: int
    dwidth_x: int
    dwidth_y: int
    bbx_w: int
    bbx_h: int
    bbx_xoff: int
    bbx_yoff: int
    rows: List[str]
    source: str

    def to_rina_entry(self, ascent: int = 10) -> List[object]:
        dst_y = int(ascent) - int(self.bbx_yoff) - int(self.bbx_h)
        return [
            self.dwidth_x,
            self.bbx_w,
            self.bbx_h,
            self.bbx_xoff,
            self.bbx_yoff,
            dst_y,
            "/".join(self.rows),
        ]


def _normalize_bitmap_row(raw_hex: str, width: int) -> str:
    """Convert a BDF row to the compact row format used by ark12.json.

    BDF rows are byte-aligned. For a 12-pixel glyph, rows are often 16 bits,
    but the firmware JSON stores only 12 significant bits, e.g. FFE not FFE0.
    """
    raw_hex = raw_hex.strip().upper()
    if width <= 0:
        return ""
    if not raw_hex:
        bits = "0" * width
    else:
        bits = bin(int(raw_hex, 16))[2:].zfill(len(raw_hex) * 4)[:width]
        if len(bits) < width:
            bits = bits.ljust(width, "0")
    out_bits_len = int(math.ceil(width / 4.0) * 4)
    bits = bits.ljust(out_bits_len, "0")
    nibbles = out_bits_len // 4
    if not bits:
        return "0" * max(1, nibbles)
    return f"{int(bits, 2):0{nibbles}X}"


def parse_bdf(path: Path, source_label: str) -> Dict[int, BdfGlyph]:
    glyphs: Dict[int, BdfGlyph] = {}
    lines = path.read_text(encoding="latin-1", errors="replace").splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line != "STARTCHAR":
            if not line.startswith("STARTCHAR"):
                i += 1
                continue
        codepoint: Optional[int] = None
        dwidth_x, dwidth_y = 0, 0
        bbx: Optional[Tuple[int, int, int, int]] = None
        bitmap: List[str] = []
        in_bitmap = False
        i += 1
        while i < len(lines):
            s = lines[i].strip()
            if s.startswith("ENCODING"):
                parts = s.split()
                if len(parts) >= 2:
                    try:
                        codepoint = int(parts[1])
                    except ValueError:
                        codepoint = None
            elif s.startswith("DWIDTH"):
                parts = s.split()
                if len(parts) >= 3:
                    try:
                        dwidth_x, dwidth_y = int(parts[1]), int(parts[2])
                    except ValueError:
                        dwidth_x, dwidth_y = 0, 0
            elif s.startswith("BBX"):
                parts = s.split()
                if len(parts) >= 5:
                    try:
                        bbx = tuple(int(p) for p in parts[1:5])
                    except ValueError:
                        bbx = None
            elif s == "BITMAP":
                in_bitmap = True
                bitmap = []
            elif s == "ENDCHAR":
                if codepoint is not None and codepoint >= 0 and bbx is not None:
                    w, h, xoff, yoff = bbx
                    rows = [_normalize_bitmap_row(r, w) for r in bitmap[:h]]
                    if len(rows) < h:
                        rows.extend(["0" * max(1, math.ceil(w / 4))] * (h - len(rows)))
                    glyphs[codepoint] = BdfGlyph(
                        codepoint=codepoint,
                        dwidth_x=dwidth_x,
                        dwidth_y=dwidth_y,
                        bbx_w=w,
                        bbx_h=h,
                        bbx_xoff=xoff,
                        bbx_yoff=yoff,
                        rows=rows,
                        source=source_label,
                    )
                break
            elif in_bitmap and re.fullmatch(r"[0-9A-Fa-f]+", s):
                bitmap.append(s)
            i += 1
        i += 1
    return glyphs


def find_bdf_for_language(bdf_root: Path, language: str) -> Optional[Path]:
    language = language.lower()
    candidates = sorted(bdf_root.rglob("*.bdf"))
    patterns = [
        re.compile(rf"(^|[-_]){re.escape(language)}($|[-_.])", re.IGNORECASE),
        re.compile(re.escape(language), re.IGNORECASE),
    ]
    for pat in patterns:
        matched = [p for p in candidates if pat.search(p.name)]
        if matched:
            matched.sort(key=lambda p: (
                0 if "monospaced" in str(p).lower() else 1,
                0 if "12" in str(p).lower() else 1,
                len(str(p)),
                str(p).lower(),
            ))
            return matched[0]
    return None


def merge_sources(source_files: List[Tuple[str, Path]]) -> Tuple[Dict[int, BdfGlyph], Dict[str, object]]:
    merged: Dict[int, BdfGlyph] = {}
    stats = {
        "sources": [],
        "total_overwrites": 0,
        "overwrites_by_source": {},
    }
    for label, path in source_files:
        glyphs = parse_bdf(path, label)
        overwrites = sum(1 for cp in glyphs if cp in merged)
        merged.update(glyphs)
        stats["sources"].append({
            "label": label,
            "path": path.name,
            "glyphs": len(glyphs),
            "overwrites": overwrites,
        })
        stats["total_overwrites"] = int(stats["total_overwrites"]) + overwrites
        stats["overwrites_by_source"][label] = overwrites
    return merged, stats


def hex_key(cp: int) -> str:
    return f"{cp:04X}" if cp <= 0xFFFF else f"{cp:X}"


def write_output_json(merged: Dict[int, BdfGlyph], out_path: Path, stats: Dict[str, object], release_version: str) -> None:
    ascent = 10
    glyph_items = {hex_key(cp): merged[cp].to_rina_entry(ascent=ascent) for cp in sorted(merged)}
    metadata = {
        "format": "rina_ark_pixel_font_bitmap_v1",
        "source": f"merged Ark Pixel 12px Monospaced BDF v{release_version}: zh_cn + ja + zh_tw; zh_tw overrides conflicts",
        "family": "Ark Pixel 12px Monospaced Merged Trad Priority",
        "rows": 12,
        "lineHeight": 12,
        "ascent": ascent,
        "descent": 2,
        "defaultAdvance": 12,
        "mergePolicy": {
            "priorityLowToHigh": [s["label"] for s in stats["sources"]],
            "conflictAuthority": "zh_tw",
            "description": "When the same Unicode codepoint appears in multiple sources, later sources replace earlier sources. Traditional Chinese zh_tw is applied last.",
        },
        "buildStats": stats,
        "glyphs": glyph_items,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(metadata, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def validate_json(path: Path, sample_text: str, strict_sample: bool = False) -> int:
    data = json.loads(path.read_text(encoding="utf-8"))
    glyphs = data.get("glyphs", {})
    missing = []
    for ch in sample_text:
        cp = ord(ch)
        key = hex_key(cp)
        if key not in glyphs:
            missing.append(f"U+{cp:04X} {ch}")
    count = len(glyphs)
    max_rows = max((len(entry[6].split('/')) for entry in glyphs.values()), default=0)
    non_12 = sum(1 for entry in glyphs.values() if len(entry[6].split('/')) != 12)
    print(f"[validate] glyph count: {count}")
    print(f"[validate] expected official Ark 12 mono count: about {EXPECTED_OFFICIAL_ARK12_MONO_COUNT}")
    print(f"[validate] max bitmap rows: {max_rows}; entries with rows != 12: {non_12}")
    if missing:
        print("[validate] sample missing glyphs:")
        for item in missing:
            print(f"  - {item}")
        if strict_sample:
            return 2
        print("[validate] WARNING: sample contains codepoints not covered by official Ark 12; build will continue.")
    else:
        print("[validate] sample text coverage: OK")
    if count < 24000:
        print("[validate] WARNING: glyph count is below 24000; check whether all three BDF sources were selected correctly.")
        return 1
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bdf-root", required=True, help="Folder containing extracted Ark Pixel 12px monospaced BDF files.")
    ap.add_argument("--out", required=True, help="Output merged JSON path.")
    ap.add_argument("--release-version", default="2026.05.07")
    ap.add_argument("--languages", default="zh_cn,ja,zh_tw", help="Merge priority low->high. Default: zh_cn,ja,zh_tw")
    ap.add_argument("--sample", default="English symbols !@#$ 你好 简体 繁體 日本語 こんにちは 璃奈ちゃんボード 國 龍 辺 高 髙")
    ap.add_argument("--strict-sample", action="store_true", help="Fail when any character in --sample is missing. Default is warning-only because Ark 12 is not a complete CJK font.")
    args = ap.parse_args(argv)

    bdf_root = Path(args.bdf_root).resolve()
    languages = [x.strip() for x in args.languages.split(",") if x.strip()]
    source_files: List[Tuple[str, Path]] = []
    missing_langs: List[str] = []
    for lang in languages:
        path = find_bdf_for_language(bdf_root, lang)
        if path is None:
            missing_langs.append(lang)
        else:
            source_files.append((lang, path))

    if missing_langs:
        print(f"[error] missing BDF source(s): {', '.join(missing_langs)}", file=sys.stderr)
        print(f"[error] searched under: {bdf_root}", file=sys.stderr)
        print("[error] available BDF files:", file=sys.stderr)
        for p in sorted(bdf_root.rglob("*.bdf"))[:80]:
            print(f"  - {p}", file=sys.stderr)
        return 10
    if not source_files:
        print("[error] no source BDF files selected", file=sys.stderr)
        return 11

    print("[merge] source order, low -> high priority:")
    for label, path in source_files:
        print(f"  - {label}: {path}")

    merged, stats = merge_sources(source_files)
    out_path = Path(args.out).resolve()
    write_output_json(merged, out_path, stats, args.release_version)
    print(f"[merge] wrote: {out_path}")
    print(f"[merge] glyphs: {len(merged)}")
    print(f"[merge] overwrites total: {stats['total_overwrites']}")
    for source in stats["sources"]:
        print(f"[merge] {source['label']}: glyphs={source['glyphs']} overwrites={source['overwrites']}")

    return validate_json(out_path, args.sample, args.strict_sample)


if __name__ == "__main__":
    raise SystemExit(main())
