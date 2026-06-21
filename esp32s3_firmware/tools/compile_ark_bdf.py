#!/usr/bin/env python3
# 本脚本把 Ark BDF 字体编译成项目使用的紧凑字形资源；必要 English 参数名保持和 CLI/API 一致。
"""Compile Ark Pixel Font 12px monospaced BDF into a compact WebUI bitmap table.

The WebUI does not render text through Canvas fonts for scrolling.  Instead, it
reads this JSON table and blits the original BDF glyph bitmap bits into the
370-LED text-scroll frame generator.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict, List, Optional


# 中文块：hex_to_bits 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
def hex_to_bits(row_hex: str, width: int) -> str:
    row_hex = "".join(ch for ch in row_hex.strip() if ch in "0123456789abcdefABCDEF")
    bits = "".join(f"{int(ch, 16):04b}" for ch in row_hex)
    return bits[: max(0, width)].ljust(max(0, width), "0")


# 中文块：bits_to_hex 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
def bits_to_hex(bits: str) -> str:
    if not bits:
        return ""
    pad = (-len(bits)) % 4
    bits = bits + ("0" * pad)
    out = []
    for i in range(0, len(bits), 4):
        out.append(f"{int(bits[i:i+4], 2):X}")
    return "".join(out)


# 中文块：parse_bdf 负责解析输入数据，并转换成后续步骤可使用的结构。
def parse_bdf(path: Path, max_codepoint: Optional[int] = None) -> dict:
    lines = path.read_text("utf-8", errors="replace").splitlines()
    font = {
        "format": "rina_ark_pixel_font_bitmap_v1",
        "source": path.name,
        "family": "Ark Pixel 12px Monospaced",
        "rows": 12,
        "lineHeight": 12,
        "ascent": 10,
        "descent": 2,
        "defaultAdvance": 12,
        "glyphs": {},
    }

    # 说明 Ark BDF 编译 中当前代码块的职责和维护约束。
    for line in lines:
        if line.startswith("FONT_ASCENT "):
            font["ascent"] = int(line.split()[1])
        elif line.startswith("FONT_DESCENT "):
            font["descent"] = int(line.split()[1])
        elif line.startswith("PIXEL_SIZE "):
            font["rows"] = int(line.split()[1])
            font["lineHeight"] = int(line.split()[1])
        elif line.startswith("FONTBOUNDINGBOX "):
            parts = line.split()
            if len(parts) >= 3:
                font["rows"] = int(parts[2])
                font["lineHeight"] = int(parts[2])

    glyph_count = 0
    i = 0
    n = len(lines)
    while i < n:
        if not lines[i].startswith("STARTCHAR"):
            i += 1
            continue
        encoding = None
        dwidth = font["defaultAdvance"]
        bbx = [0, 0, 0, 0]  # 说明 Ark BDF 编译 中当前代码块的职责和维护约束。
        bitmap_rows: List[str] = []
        i += 1
        while i < n and not lines[i].startswith("ENDCHAR"):
            line = lines[i]
            if line.startswith("ENCODING "):
                try:
                    encoding = int(line.split()[1])
                except Exception:
                    encoding = None
            elif line.startswith("DWIDTH "):
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        dwidth = int(parts[1])
                    except Exception:
                        pass
            elif line.startswith("BBX "):
                parts = line.split()
                if len(parts) >= 5:
                    bbx = [int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4])]
            elif line == "BITMAP":
                width, height, _xoff, _yoff = bbx
                bitmap_rows = []
                for j in range(height):
                    if i + 1 + j < n:
                        bitmap_rows.append(hex_to_bits(lines[i + 1 + j], width))
                i += height
            i += 1

        if encoding is not None and encoding >= 0 and (max_codepoint is None or encoding <= max_codepoint):
            width, height, xoff, yoff = bbx
            # 处理 LED 矩阵、灯带刷新或硬件时序约束。
            dst_y = int(font["ascent"]) - int(yoff) - int(height)
            packed_rows = "/".join(bits_to_hex(row) for row in bitmap_rows)
            cp_key = f"{encoding:04X}" if encoding <= 0xFFFF else f"{encoding:X}"
            # 说明字体、字形、Unicode 范围或 Web font 资源处理。
            font["glyphs"][cp_key] = [int(dwidth), int(width), int(
                height), int(xoff), int(yoff), int(dst_y), packed_rows]
            glyph_count += 1
        i += 1

    if glyph_count == 0:
        raise RuntimeError(f"No glyphs parsed from {path}")
    return font


# 中文块：main 是脚本流程中的独立处理单元，处理对应输入、转换或输出。
def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="Ark Pixel Font BDF file")
    ap.add_argument("--output", required=True, help="Output compact JSON table")
    ap.add_argument("--max-codepoint", default="0xFFFF",
                    help="Limit output codepoints to keep LittleFS resource size bounded")
    args = ap.parse_args()

    max_cp = None if args.max_codepoint.lower() in {"none", "all"} else int(args.max_codepoint, 0)
    data = parse_bdf(Path(args.input), max_cp)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), "utf-8")
    print(
        f"[compile_ark_bdf] wrote {out} ({out.stat().st_size} bytes, {len(data['glyphs'])} glyphs)")


if __name__ == "__main__":
    main()
