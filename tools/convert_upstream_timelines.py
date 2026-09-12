#!/usr/bin/env python3
"""Convert 738NGX/RinaChanBoard keyframe timelines into RinaBoard `.rinalive` scripts.

Upstream (AGPL-3.0) stores each performance as a bare JSON array:

    [{"frame": 0, "face": {"leye": 101, "reye": 201, "mouth": 304, "cheek": 400}}, ...]

`frame` is an index at a fixed **10 fps**, derived from the playing audio clock,
not from a render loop — `MusicPage.cs:31` is `int frame =
Mathf.FloorToInt(musicSource.time * 10);`, and `MediaTool.ConvertFramesToTime`
divides by 600 for minutes. Lookup is exact-match against a dictionary built as
`contentHash[unit.Frame] = index`, i.e. a face is held until the next listed
frame, and when a frame is listed twice the **last** entry wins. This script
reproduces both rules.

The face-module ids need no remapping at all: upstream's `FaceModuleDb.json`
and our `expression_parts.json` both descend from the same original Rina-chan
board part set, so `leye` 101-127, `reye` 201-227, `mouth` 301-332, `cheek`
400-405 and the blank `0` mean the same bitmaps on both sides. Every id is
still validated against our own parts library before anything is written — a
silent mismatch would show as a wrong face, not as an error.

**No audio is converted or redistributed.** Upstream's `.ogg`/`.mp4` assets are
commercial Love Live! recordings shipped without any licence grant; only the
timing data, which is upstream's own authored work, is ported here. The app
pairs a built-in timeline with an audio file the user supplies themselves.

Usage:
    python3 tools/convert_upstream_timelines.py --download
    python3 tools/convert_upstream_timelines.py --source <dir-of-json>
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
INDEX_FILE = OUTPUT_DIR / "preset_live_catalog.json"

UPSTREAM_BASE = (
    "https://raw.githubusercontent.com/738NGX/RinaChanBoard/main/"
    "RinaChanBoardOperationCenter/Assets/Resources/Database"
)
COVERS = ["tkmk", "lumf", "solo0", "solo1", "solo2", "solo3", "solo4", "solo5"]

FPS = 10
GROUP_KEYS = ["leye", "reye", "mouth", "cheek"]


def download(destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    targets = [("MusicDb.json", f"{UPSTREAM_BASE}/MusicDb.json")]
    targets += [(f"{c}.json", f"{UPSTREAM_BASE}/MusicTimeLineDb/{c}.json") for c in COVERS]
    for name, url in targets:
        with urllib.request.urlopen(url) as response:
            (destination / name).write_bytes(response.read())
        print(f"  fetched {name}")


def load_valid_ids() -> dict[str, set[str]]:
    parts = json.loads(PARTS_JSON.read_text())
    return {group: set(ids) for group, ids in parts["call"]["ids"].items()}


def normalize(entries: list[dict]) -> list[tuple[int, dict]]:
    """Sort by frame and collapse duplicates, last entry winning.

    Upstream builds a dict keyed by frame, so a repeated frame silently keeps
    whichever entry was appended last (`solo0.json` ends with its final frame
    listed twice). Our own format requires strictly increasing frames, so the
    collapse has to happen here rather than being rejected at import time.
    """
    by_frame: dict[int, dict] = {}
    for entry in entries:
        by_frame[int(entry["frame"])] = entry["face"]
    return sorted(by_frame.items())


def convert(name: str, source: Path, metadata: dict, valid: dict[str, set[str]]) -> tuple[str, dict]:
    entries = json.loads((source / f"{name}.json").read_text())
    keyframes = normalize(entries)
    if not keyframes:
        raise SystemExit(f"{name}: no keyframes")

    problems: list[str] = []
    lines: list[str] = []
    for frame, face in keyframes:
        values = []
        for key in GROUP_KEYS:
            value = str(face[key])
            if value not in valid[key]:
                problems.append(f"frame {frame}: {key}={value} is not in expression_parts.json")
            values.append(value)
        lines.append(f"{frame}!{','.join(values)}")

    if problems:
        for problem in problems[:10]:
            print(f"  !! {name}: {problem}", file=sys.stderr)
        raise SystemExit(f"{name}: {len(problems)} unknown part id(s); refusing to write")

    # Upstream appends a translation, e.g. "私はマグネット (我是磁石)"; keep only the original title.
    title = re.sub(r"\s*\([^()]*\)\s*$", "", metadata.get("title", name))
    artist = metadata.get("artist", "")
    duration_ms = keyframes[-1][0] * 1000 // FPS

    header = [
        "# Converted from 738NGX/RinaChanBoard (AGPL-3.0) by",
        "# tools/convert_upstream_timelines.py — timing data only, no audio.",
        f"# Timed to: {title}" + (f" — {artist}" if artist else ""),
        "# Supply your own copy of the track; none is bundled with this app.",
        f"#fps {FPS}",
        f"#title {title}",
    ]
    body = "\n".join(header + lines) + "\n"

    return body, {
        "file": f"performance_{name}",
        # The audio is fetched separately by tools/fetch_preset_live_audio.sh
        # and is .gitignore'd, so this entry may name a file that is simply not
        # in the bundle. The app treats that as "no audio yet", not an error.
        "audio": f"audio_{name}",
        "audioExtension": "m4a",
        "title": title,
        "artist": artist,
        "keyframes": len(keyframes),
        "durationMs": duration_ms,
        "source": "738NGX/RinaChanBoard",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=None,
                        help="directory holding the upstream JSON (default: a temp dir + --download)")
    parser.add_argument("--download", action="store_true", help="fetch the upstream JSON first")
    args = parser.parse_args()

    source = args.source or (REPO_ROOT / "build" / "upstream_timelines")
    if args.download or not source.exists():
        print(f"downloading upstream timelines into {source}")
        download(source)

    valid = load_valid_ids()
    catalog = []
    for name in COVERS:
        body, entry = convert(name, source, music_metadata(source, name), valid)
        target = OUTPUT_DIR / f"performance_{name}.rinalive"
        target.write_text(body)
        print(f"  wrote {target.relative_to(REPO_ROOT)} "
              f"({entry['keyframes']} keyframes, {entry['durationMs'] / 1000:.1f}s) — {entry['title']}")
        catalog.append(entry)

    INDEX_FILE.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"  wrote {INDEX_FILE.relative_to(REPO_ROOT)} ({len(catalog)} performances)")


def music_metadata(source: Path, cover: str) -> dict:
    database = json.loads((source / "MusicDb.json").read_text())
    for record in database:
        if record.get("cover") == cover:
            return record
    return {}


if __name__ == "__main__":
    main()
