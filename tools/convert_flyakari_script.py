#!/usr/bin/env python3
"""Convert flyAkari/RinaChanBoard's preset-live script into a `.rinalive` file.

Unlike 738NGX's timelines, whose ids are already ours, flyAkari's script stores
*sprite indices* into the three tables baked into its ESP8266 firmware
(`EYES[21]`, `MOUTHES[15]`, `CHEEKS[5]` in `ESP8266_Arduino/RinaChanBoard/src/
main.cpp`). Those indices mean nothing to us, so this derives the mapping by
**matching the actual bitmaps** rather than assuming index order lines up.

How the upstream bitmaps decode (from `main.cpp`'s own blit functions):

    byte row = (image >> i * 8) & 0xFF;        // row i is the i-th byte, LSB byte first
    setMemory(i, j + 2, bitRead(row, j));      // bit j is column j, LSB leftmost

    setLeftEye   -> cols 2..9,  sprite as-is
    setRightEye  -> cols 21..14, i.e. the sprite mirrored
    setMouth     -> cols 4..11 plus a mirror at 19..12, so the visible mouth is
                    16 wide and symmetric; its middle 8 columns are exactly the
                    8-wide shape our own mouth parts use
    setCheeks    -> only sprite rows 3..4, drawn at board rows 8..9 and mirrored

Decoding that way and scoring every upstream sprite against every one of our
parts by intersection-over-union turns out to give an *exact* (IoU 1.0) match
for almost every index the script actually uses — the two projects draw the
same artwork. The two that are not exact are recorded in `OVERRIDES` with the
reason. Anything used by the script that scores below `MIN_IOU` and has no
override stops the conversion rather than silently producing a wrong face.

No audio is redistributed. `tools/fetch_preset_live_audio.sh` fetches the track
locally into a .gitignore'd path.

Usage:
    python3 tools/convert_flyakari_script.py [--source <dir>] [--report]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PARTS_JSON = REPO_ROOT / "ios/RinaBoard/Resources/expression_parts.json"
OUTPUT_DIR = REPO_ROOT / "ios/RinaBoard/Resources"
CATALOG = OUTPUT_DIR / "preset_live_catalog.json"

RAW_BASE = "https://raw.githubusercontent.com/flyAkari/RinaChanBoard/main"
FIRMWARE = f"{RAW_BASE}/ESP8266_Arduino/RinaChanBoard/src/main.cpp"
SCRIPT = f"{RAW_BASE}/Android/RinaChanBoardController/app/src/main/res/raw/poppin_up_code.txt"

NAME = "poppin_up"
# `PresetLiveActivity.java:39` — `private final static int fps = 10;`
FPS = 10
# Below this an automatic bitmap match is not trustworthy enough to ship.
MIN_IOU = 0.85

# Hand-adjudicated cases where no exact equivalent exists. Keyed by
# (group, upstream index) -> (our id, reason).
OVERRIDES = {
    ("mouth", 9): ("320", "upstream is two full-width bars; 320 is the nearest we have (IoU 0.89, 2 LEDs apart)"),
    ("cheek", 4): ("404", "upstream is a single row of two dots, which is equally 403's lower row and 404's upper row; "
                          "404 keeps it visually distinct from cheek 2 -> 403"),
    ("cheek", 0): ("400", "blank cheek; an all-zero bitmap matches nothing by IoU, so it is named explicitly"),
}

BLANK_ID = {"leye": "0", "reye": "0", "mouth": "0", "cheek": "400"}


def fetch(url: str, destination: Path) -> None:
    if destination.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url) as response:
        destination.write_bytes(response.read())


def parse_tables(source: str) -> dict[str, list[int]]:
    tables = {}
    for name in ("EYES", "MOUTHES", "CHEEKS"):
        match = re.search(r"const uint64_t " + name + r"\[\] = \{(.*?)\};", source, re.S)
        if not match:
            raise SystemExit(f"could not find {name}[] in main.cpp")
        tables[name] = [int(v, 16) for v in re.findall(r"0x([0-9a-fA-F]+)", match.group(1))]
    return tables


def sprite(image: int) -> list[list[int]]:
    """Row i is the i-th byte (LSB byte first); column j is bit j (LSB leftmost)."""
    return [[(image >> (i * 8) >> j) & 1 for j in range(8)] for i in range(8)]


def mirrored(grid: list[list[int]]) -> list[list[int]]:
    return [list(reversed(row)) for row in grid]


def mouth_shape(image: int) -> list[list[int]]:
    """The middle 8 columns of the 16-wide mirrored mouth the board draws."""
    half = sprite(image)
    full = [row + list(reversed(row)) for row in half]
    return [row[4:12] for row in full]


def cheek_shape(image: int) -> list[list[int]]:
    """`setCheeks` only uses sprite rows 3 and 4."""
    grid = sprite(image)
    return [grid[3], grid[4]]


def our_grid(parts: dict, part_id: str) -> list[list[int]] | None:
    part = parts["parts"].get(str(part_id))
    if not part:
        return None
    return [[1 if c == "#" else 0 for c in row] for row in part["preview"]]


def best_match(target: list[list[int]], candidates: list[str], parts: dict,
               shift: int = 4) -> tuple[float, str]:
    best_score, best_id = 0.0, ""
    for part_id in candidates:
        grid = our_grid(parts, part_id)
        if grid is None:
            continue
        height, width = len(grid), len(grid[0])
        rows, cols = max(len(target), height), max(len(target[0]), width)
        for dy in range(-shift, shift + 1):
            for dx in range(-shift, shift + 1):
                intersection = union = 0
                for y in range(rows):
                    for x in range(cols):
                        a = target[y][x] if y < len(target) and x < len(target[0]) else 0
                        yy, xx = y + dy, x + dx
                        b = grid[yy][xx] if 0 <= yy < height and 0 <= xx < width else 0
                        if a or b:
                            union += 1
                        if a and b:
                            intersection += 1
                if union:
                    score = intersection / union
                    if score > best_score:
                        best_score, best_id = score, part_id
    return best_score, best_id


def build_mapping(tables: dict[str, list[int]], parts: dict, used: dict[str, set[int]],
                  report: bool) -> dict[str, dict[int, str]]:
    ids = parts["call"]["ids"]
    mapping: dict[str, dict[int, str]] = {"leye": {}, "reye": {}, "mouth": {}, "cheek": {}}
    problems: list[str] = []

    plans = [
        ("leye", tables["EYES"], ids["leye"], lambda image: sprite(image)),
        ("reye", tables["EYES"], ids["reye"], lambda image: mirrored(sprite(image))),
        ("mouth", tables["MOUTHES"], ids["mouth"], mouth_shape),
        ("cheek", tables["CHEEKS"], ids["cheek"], cheek_shape),
    ]

    for group, table, candidates, shape in plans:
        for index in sorted(used[group]):
            if index >= len(table):
                problems.append(f"{group} index {index} is past the end of the upstream table")
                continue
            override = OVERRIDES.get((group, index))
            if override:
                mapping[group][index] = override[0]
                if report:
                    print(f"  {group:5} {index:2d} -> {override[0]}  (override: {override[1]})")
                continue
            if table[index] == 0:
                mapping[group][index] = BLANK_ID[group]
                if report:
                    print(f"  {group:5} {index:2d} -> {BLANK_ID[group]}  (blank sprite)")
                continue
            score, part_id = best_match(shape(table[index]), candidates, parts)
            if score < MIN_IOU:
                problems.append(f"{group} index {index}: best match {part_id} scores only {score:.2f}")
                continue
            mapping[group][index] = part_id
            if report:
                flag = "" if score >= 0.999 else f"  <-- approximate"
                print(f"  {group:5} {index:2d} -> {part_id}  (IoU {score:.2f}){flag}")

    if problems:
        for problem in problems:
            print(f"  !! {problem}", file=sys.stderr)
        raise SystemExit("refusing to write a script with unresolved sprites")
    return mapping


def parse_script(text: str) -> list[tuple[int, tuple[int, int, int, int]]]:
    keyframes: dict[int, tuple[int, int, int, int]] = {}
    for number, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        if "!" not in line:
            raise SystemExit(f"line {number}: no '!' separator: {line!r}")
        frame_text, code = line.split("!", 1)
        values = [v for v in code.split(",") if v.strip() != ""]
        if len(values) != 4:
            raise SystemExit(f"line {number}: expected 4 values, got {len(values)}: {line!r}")
        keyframes[int(frame_text)] = tuple(int(v) for v in values)
    # Upstream's own data has one out-of-order frame (639 sits between 692 and
    # 694); its player reads lines sequentially and simply never fires that one.
    # Sorting is the faithful repair: the keyframe lands where its timestamp
    # says it belongs, and our format requires increasing frames anyway.
    return sorted(keyframes.items())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=REPO_ROOT / "build" / "flyakari")
    parser.add_argument("--report", action="store_true", help="print the derived sprite mapping")
    args = parser.parse_args()

    fetch(FIRMWARE, args.source / "main.cpp")
    fetch(SCRIPT, args.source / "poppin_up_code.txt")

    tables = parse_tables((args.source / "main.cpp").read_text(errors="replace"))
    keyframes = parse_script((args.source / "poppin_up_code.txt").read_text())
    parts = json.loads(PARTS_JSON.read_text())

    used = {
        "leye": {k[0] for _, k in keyframes},
        "reye": {k[1] for _, k in keyframes},
        "mouth": {k[2] for _, k in keyframes},
        "cheek": {k[3] for _, k in keyframes},
    }
    if args.report:
        print("Derived sprite mapping (upstream index -> our part id):")
    mapping = build_mapping(tables, parts, used, args.report)

    lines = []
    for frame, (left, right, mouth, cheek) in keyframes:
        lines.append(f"{frame}!{mapping['leye'][left]},{mapping['reye'][right]},"
                     f"{mapping['mouth'][mouth]},{mapping['cheek'][cheek]}")

    title = "Poppin' Up!"
    header = [
        "# Converted from flyAkari/RinaChanBoard (GPL-3.0) by",
        "# tools/convert_flyakari_script.py — timing data only, no audio.",
        "# Upstream sprite indices were resolved to our part ids by bitmap",
        "# matching against expression_parts.json; run with --report to see it.",
        f"# Timed to: {title} (track identity inferred from the upstream commit title)",
        "# Supply your own copy of the track; none is distributed with this app.",
        f"#fps {FPS}",
        f"#title {title}",
    ]
    target = OUTPUT_DIR / f"performance_{NAME}.rinalive"
    target.write_text("\n".join(header + lines) + "\n")

    duration_ms = keyframes[-1][0] * 1000 // FPS
    print(f"  wrote {target.relative_to(REPO_ROOT)} "
          f"({len(keyframes)} keyframes, {duration_ms / 1000:.1f}s) — {title}")

    entry = {
        "file": f"performance_{NAME}",
        "audio": f"audio_{NAME}",
        "audioExtension": "mp3",
        "title": title,
        "artist": "中須かすみ",
        "keyframes": len(keyframes),
        "durationMs": duration_ms,
        "source": "flyAkari/RinaChanBoard",
    }
    catalog = json.loads(CATALOG.read_text()) if CATALOG.exists() else []
    catalog = [e for e in catalog if e["file"] != entry["file"]] + [entry]
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"  updated {CATALOG.relative_to(REPO_ROOT)} ({len(catalog)} performances)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
