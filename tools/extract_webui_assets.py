#!/usr/bin/env python3
"""Extract static data tables from the legacy ESP32 WebUI (app.js / resources/)
into standalone JSON resource files for the iOS app.

Usage:
    python3 extract_webui_assets.py --app-js PATH/to/app.js \
        --resources-dir PATH/to/resources --out PATH/to/output_dir

The script is read-only with respect to its inputs: it never modifies app.js,
index.html or the resources/ directory. All generated files are written under
--out (created if missing).
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


# --------------------------------------------------------------------------
# Tolerant JS object-literal -> JSON conversion
# --------------------------------------------------------------------------


def _find_literal_span(text: str, const_name: str) -> tuple[int, int]:
    """Find the (start, end) character span of the object/array literal bound
    to `const <const_name> = ...;` in `text`. Handles an optional
    `Object.freeze(...)` wrapper. Returns indices such that
    text[start:end] is exactly the literal (e.g. `{...}` or `[...]`),
    with no wrapper or trailing semicolon.
    """
    marker = f"const {const_name} ="
    idx = text.index(marker)
    pos = idx + len(marker)

    # Skip whitespace and an optional "Object.freeze(" wrapper.
    while text[pos].isspace():
        pos += 1
    if text.startswith("Object.freeze(", pos):
        pos += len("Object.freeze(")
        while text[pos].isspace():
            pos += 1

    if text[pos] not in "{[":
        raise ValueError(f"Expected '{{' or '[' after `{marker}`, found {text[pos]!r}")

    open_ch = text[pos]
    close_ch = "}" if open_ch == "{" else "]"
    depth = 0
    i = pos
    in_string: str | None = None  # None, '"', "'", or "`"
    escaped = False
    in_line_comment = False
    in_block_comment = False
    start = pos

    while i < len(text):
        ch = text[i]

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_block_comment:
            if ch == "*" and text[i + 1 : i + 2] == "/":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == in_string:
                in_string = None
            i += 1
            continue

        if ch == "/" and text[i + 1 : i + 2] == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and text[i + 1 : i + 2] == "*":
            in_block_comment = True
            i += 2
            continue
        if ch in "\"'`":
            in_string = ch
            i += 1
            continue

        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return start, i + 1
        i += 1

    raise ValueError(f"Unbalanced literal for `{const_name}` (never reached depth 0)")


def js_literal_to_json_text(app_js_text: str, const_name: str) -> str:
    """Extract a top-level `const NAME = <literal>;` from app.js text and
    return it re-serialized as compact JSON text, using Node.js to evaluate
    the JS object/array literal (handles unquoted keys, trailing commas,
    single-quoted strings, numeric keys, comments, etc. natively).
    """
    start, end = _find_literal_span(app_js_text, const_name)
    literal = app_js_text[start:end]

    node = shutil.which("node")
    if node is None:
        raise RuntimeError(
            "node is required to convert JS object literals but was not found on PATH"
        )

    script = f"const __X = {literal};\nprocess.stdout.write(JSON.stringify(__X));\n"
    result = subprocess.run(
        [node, "-e", script],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"node failed to evaluate literal for `{const_name}`:\n{result.stderr}"
        )
    return result.stdout


def extract_js_const(app_js_text: str, const_name: str):
    """Extract a `const NAME = <literal>;` from app.js and return it as a
    Python object (via json.loads on the Node-normalised JSON text)."""
    return json.loads(js_literal_to_json_text(app_js_text, const_name))


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def write_json(path: Path, data, compact: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if compact:
        text = json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    else:
        text = json.dumps(data, sort_keys=True, indent=1, ensure_ascii=False)
    path.write_text(text + "\n", encoding="utf-8")


def normalise_hex_color(value: str) -> str:
    v = value.strip().lstrip("#").lower()
    if len(v) != 6 or any(c not in "0123456789abcdef" for c in v):
        raise ValueError(f"Not a 6-digit hex color: {value!r}")
    return f"#{v}"


# --------------------------------------------------------------------------
# Matrix geometry (ported from app.js ~L3257-L3290)
# --------------------------------------------------------------------------


def build_matrix_geometry(matrix: dict) -> dict:
    cols = matrix["cols"]
    rows = matrix["rows"]
    total_leds = matrix["num_leds"]
    row_ranges = matrix["row_valid_x_ranges"]
    serpentine = bool(matrix.get("serpentine"))
    serpentine_odd_rows_reversed = matrix.get("serpentine_odd_rows_reversed") is not False

    xy_to_index = [[-1 for _ in range(cols)] for _ in range(rows)]
    index_to_xy = [None] * total_leds
    led_index = 0
    for y in range(rows):
        x0, x1 = row_ranges[y]
        for x in range(x0, x1 + 1):
            xy_to_index[y][x] = led_index
            index_to_xy[led_index] = [x, y]
            led_index += 1

    if led_index != total_leds:
        raise ValueError(
            f"Row ranges produced {led_index} LEDs, expected num_leds={total_leds}"
        )

    def logical_to_physical_index(index: int) -> int:
        xy = index_to_xy[index]
        if xy is None or not serpentine:
            return index
        x, y = xy
        if not serpentine_odd_rows_reversed or (y & 1) == 0:
            return index
        x0, x1 = row_ranges[y]
        return xy_to_index[y][x0 + x1 - x]

    physical_to_logical_index = [-1] * total_leds
    for logical in range(total_leds):
        physical_to_logical_index[logical_to_physical_index(logical)] = logical

    return {
        "cols": cols,
        "rows": rows,
        "num_leds": total_leds,
        "row_lengths": matrix.get("row_lengths"),
        "row_valid_x_ranges": row_ranges,
        "serpentine": serpentine,
        "serpentine_odd_rows_reversed": serpentine_odd_rows_reversed,
        "xy_to_index": xy_to_index,
        "index_to_xy": index_to_xy,
        "physical_to_logical_index": physical_to_logical_index,
    }


def frame_hex_from_strip_indices(strip_indices, total_leds: int, physical_to_logical) -> str:
    """Pack LED indices into the same 94-hex-char, 47-byte, LSB-first bitfield
    documented by EXPRESSION_PARTS.encoding.frame: LED i lives in byte i>>3,
    mask 1<<(i&7). `strip_indices` are documented as *physical* serpentine
    locations (app.js orPartIntoFrame() legacy fallback path), so they must
    be mapped back to logical indices via physical_to_logical_index before
    packing (matches app.js physicalToLogicalIndex())."""
    num_bytes = (total_leds + 7) // 8
    buf = bytearray(num_bytes)
    for phys_idx in strip_indices:
        logical = physical_to_logical[phys_idx] if 0 <= phys_idx < len(physical_to_logical) else phys_idx
        if 0 <= logical < total_leds:
            buf[logical >> 3] |= 1 << (logical & 7)
    return buf.hex()


def cross_check_parts_frames(expression_parts: dict, physical_to_logical) -> dict:
    total_leds = expression_parts["matrix"]["num_leds"]
    parts = expression_parts["parts"]
    mismatches = []
    checked = 0
    for part_id, part in parts.items():
        checked += 1
        expected = frame_hex_from_strip_indices(
            part.get("strip_indices", []), total_leds, physical_to_logical
        )
        actual = str(part.get("frame", "")).lower()
        if expected != actual:
            mismatches.append(
                {
                    "id": part_id,
                    "name": part.get("name"),
                    "expected_frame": expected,
                    "actual_frame": actual,
                }
            )
    return {"checked": checked, "mismatches": mismatches}


# --------------------------------------------------------------------------
# Extraction steps
# --------------------------------------------------------------------------


def extract_expression_parts(app_js_text: str, out_dir: Path) -> dict:
    expression_parts = extract_js_const(app_js_text, "EXPRESSION_PARTS")

    parts = expression_parts.get("parts", {})
    if len(parts) != 92:
        print(f"WARNING: expected 92 parts, found {len(parts)}", file=sys.stderr)

    call_ids = expression_parts.get("call", {}).get("ids", {})
    expected_groups = {"leye", "reye", "mouth", "cheek"}
    found_groups = set(call_ids.keys())
    if found_groups != expected_groups:
        print(
            f"WARNING: call.ids groups mismatch. expected {expected_groups}, found {found_groups}",
            file=sys.stderr,
        )

    def check_ids(group: str, expected: list[str]) -> None:
        actual = call_ids.get(group, [])
        if list(actual) != expected:
            print(
                f"WARNING: call.ids.{group} mismatch.\n  expected={expected}\n  actual={actual}",
                file=sys.stderr,
            )

    check_ids("leye", ["0"] + [str(n) for n in range(101, 128)])
    check_ids("reye", ["0"] + [str(n) for n in range(201, 228)])
    check_ids("mouth", ["0"] + [str(n) for n in range(301, 333)])
    check_ids("cheek", [str(n) for n in range(400, 406)])

    if "matrix" not in expression_parts:
        print("WARNING: EXPRESSION_PARTS.matrix block missing", file=sys.stderr)

    required_fields = {"row_hex", "placement", "frame", "strip_indices", "lit_count", "bbox"}
    for part_id, part in parts.items():
        missing = required_fields - set(part.keys())
        if missing:
            print(f"WARNING: part {part_id} missing fields: {missing}", file=sys.stderr)
        frame = part.get("frame", "")
        if not (isinstance(frame, str) and len(frame) == 94 and all(c in "0123456789abcdefABCDEF" for c in frame)):
            print(f"WARNING: part {part_id} frame is not 94 hex chars: {frame!r}", file=sys.stderr)

    write_json(out_dir / "expression_parts.json", expression_parts)
    return expression_parts


def extract_color_presets(app_js_text: str, out_dir: Path) -> None:
    parents_raw = extract_js_const(app_js_text, "parent_color_groups")
    children_raw = extract_js_const(app_js_text, "child_color_groups")

    parents = []
    for p in parents_raw:
        parents.append(
            {
                "id": p["id"],
                "name": p["name"],
                "color": normalise_hex_color(p["color"]),
                "desc": p.get("desc", ""),
            }
        )
    if len(parents) != 6:
        print(f"WARNING: expected 6 parent color groups, found {len(parents)}", file=sys.stderr)

    children = {}
    total_children = 0
    for parent_id, rows in children_raw.items():
        entries = []
        for row in rows:
            name, hexval = row[0], row[1]
            entries.append({"name": name, "hex": normalise_hex_color(hexval)})
        children[str(parent_id)] = entries
        total_children += len(entries)

    if total_children != 67:
        print(f"WARNING: expected 67 total child colors, found {total_children}", file=sys.stderr)

    write_json(out_dir / "color_presets.json", {"parents": parents, "children": children})


def extract_webui_config(app_js_text: str, out_dir: Path) -> dict:
    webui_config = extract_js_const(app_js_text, "WEBUI_CONFIG")
    write_json(out_dir / "webui_config.json", webui_config)
    return webui_config


def extract_matrix_geometry(expression_parts: dict, out_dir: Path) -> dict:
    matrix = expression_parts["matrix"]
    geometry = build_matrix_geometry(matrix)

    check = cross_check_parts_frames(expression_parts, geometry["physical_to_logical_index"])

    geometry_out = dict(geometry)
    write_json(out_dir / "matrix_geometry.json", geometry_out)
    return check


def copy_default_faces(resources_dir: Path, out_dir: Path) -> None:
    src = resources_dir / "saved_faces.json"
    data = json.loads(src.read_text(encoding="utf-8"))
    write_json(out_dir / "default_faces.json", data)


def copy_ark12(resources_dir: Path, out_dir: Path) -> dict:
    src = resources_dir / "fonts" / "ark12.json"
    data = json.loads(src.read_text(encoding="utf-8"))

    # ark12.json is large (~2.5MB); keep it byte-for-byte reasonable but
    # deterministic (sorted keys, compact separators) rather than re-indenting.
    out_path = out_dir / "ark12.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    glyphs = data.get("glyphs", {})
    encoding_variants = set()
    for g in glyphs.values():
        if isinstance(g, list):
            encoding_variants.add("tuple_packed_rows_hex_slash_joined")
        elif isinstance(g, dict):
            if "rowsHex" in g:
                encoding_variants.add("object_rowsHex_slash_joined")
            elif "rows" in g:
                encoding_variants.add("object_rows_raw_bit_strings")
            else:
                encoding_variants.add("object_unknown")

    meta = {
        "format": data.get("format"),
        "source": data.get("source"),
        "family": data.get("family"),
        "rows": data.get("rows"),
        "lineHeight": data.get("lineHeight"),
        "ascent": data.get("ascent"),
        "descent": data.get("descent"),
        "defaultAdvance": data.get("defaultAdvance"),
        "glyphCount": len(glyphs),
        "rowsEncodingVariantsFound": sorted(encoding_variants),
        "rowsEncodingNote": (
            "app.js loadArkPixelFontTable()/decodePackedGlyphRows(): glyph entries may be "
            "either a packed tuple [advance,width,height,xOffset,yOffset,dstY,rowsHex] where "
            "rowsHex is N '/'-joined hex nibble rows decoded MSB-first into bit strings "
            "truncated to `width` bits (the format used by this ark12.json snapshot), or a "
            "legacy object form carrying either `rowsHex` (same slash-joined hex format) or "
            "already-decoded `rows` as raw '0'/'1' bit strings. Only the packed tuple form "
            "was found in this snapshot."
        ),
    }
    write_json(out_dir / "ark12_meta.json", meta)
    return meta


def copy_images(resources_dir: Path, out_dir: Path) -> None:
    images_dir = out_dir / "Images"
    images_dir.mkdir(parents=True, exist_ok=True)
    pairs = [
        (resources_dir / "pictures" / "rinaboard.png", images_dir / "rinaboard.png"),
        (
            resources_dir / "loading" / "rina_icon1_default.png",
            images_dir / "rina_icon1_default.png",
        ),
        (
            resources_dir / "loading" / "rina_icon2_hover.png",
            images_dir / "rina_icon2_hover.png",
        ),
    ]
    for src, dst in pairs:
        shutil.copyfile(src, dst)


def extract_scroll_text_defaults(app_js_text: str, index_html_text: str, webui_config: dict, out_dir: Path) -> dict:
    m = re.search(
        r'<textarea id="scroll-text"[^>]*>\s*\n?(.*?)</textarea',
        index_html_text,
        re.DOTALL,
    )
    if not m:
        raise RuntimeError("Could not find #scroll-text default text in index.html")
    default_text = m.group(1).strip("\n")
    expected = "RinaChanBoard 370 LED こんにちは 璃奈ちゃんボード"
    if default_text != expected:
        print(
            f"WARNING: default scroll text mismatch.\n  expected={expected!r}\n  actual={default_text!r}",
            file=sys.stderr,
        )

    m_font = re.search(r'const TEXT_SCROLL_FONT_MODEL\s*=\s*WEBUI_CONFIG\.textScroll\.fontModel', app_js_text)
    if not m_font:
        print("WARNING: could not confirm fontId is WEBUI_CONFIG.textScroll.fontModel", file=sys.stderr)
    font_id = webui_config["textScroll"]["fontModel"]

    m_gen = re.search(r'const SCROLL_GENERATOR_VERSION\s*=\s*"([^"]+)"', app_js_text)
    if not m_gen:
        raise RuntimeError("Could not find SCROLL_GENERATOR_VERSION in app.js")
    generator_version = m_gen.group(1)

    m_brightness = re.search(
        r'"brightness-presets",\s*\[([^\]]+)\]', app_js_text
    )
    if not m_brightness:
        raise RuntimeError("Could not find brightness presets in app.js")
    brightness_presets = [int(x.strip()) for x in m_brightness.group(1).split(",") if x.strip()]

    scroll_cfg = webui_config["scroll"]
    auto_interval_cfg = webui_config["autoInterval"]

    data = {
        "defaultText": default_text,
        "maxChars": scroll_cfg["maxTextChars"],
        "maxBytes": 4096,
        "fpsDefault": scroll_cfg["defaultFps"],
        "fpsMin": scroll_cfg["fpsMin"],
        "fpsMax": scroll_cfg["fpsMax"],
        "fpsPresets": scroll_cfg["fpsPresets"],
        "brightnessPresets": brightness_presets,
        "autoIntervalPresetsMs": auto_interval_cfg["presetsMs"],
        "fontId": font_id,
        "generatorVersion": generator_version,
    }

    expected_auto_presets = [500, 1000, 2000, 3000, 5000, 7500, 10000]
    if data["autoIntervalPresetsMs"] != expected_auto_presets:
        print(
            f"WARNING: autoIntervalPresetsMs mismatch: {data['autoIntervalPresetsMs']}",
            file=sys.stderr,
        )
    if data["maxBytes"] != 4096:
        print("WARNING: maxBytes hardcoded value drifted from 4096", file=sys.stderr)

    write_json(out_dir / "scroll_text_defaults.json", data)
    return data


README_TEMPLATE = """# RinaBoard iOS Resources

Static data tables extracted from the legacy ESP32 WebUI (`esp32s3_firmware/data/`)
by `tools/extract_webui_assets.py`. Regenerate with:

```
python3 tools/extract_webui_assets.py \\
  --app-js <legacy>/esp32s3_firmware/data/app.js \\
  --resources-dir <legacy>/esp32s3_firmware/data/resources \\
  --out ios/RinaBoard/Resources
```

Do not hand-edit the generated JSON files; edit the legacy WebUI source and
re-run the script instead.

## Files

- **expression_parts.json** — full `EXPRESSION_PARTS` object literal
  (app.js `const EXPRESSION_PARTS = {{...}}`, ~L203-L2995). Schema:
  `format`, `version`, `matrix` (cols/rows/num_leds/row_lengths/
  row_valid_x_ranges/serpentine flags), `encoding` (doc strings), `layout`
  (group placement rects), `call` (fields/default_face/ids/map/counts),
  `parts` (keyed by numeric id string; each part has `id`, `name`, `type`,
  `size`, `row_hex`, `preview`, `placement`, `frame` (94 hex chars, 47-byte
  LSB-first packed bitfield), `strip_indices`, `lit_count`, `bbox`). 92 parts
  total across groups `eye_left`/`eye_right`/`mouth`/`cheek`/`empty`,
  matching call-id lists `"0","101"-"127"`, `"0","201"-"227"`,
  `"0","301"-"332"`, `"400"-"405"`.

- **color_presets.json** — derived from `parent_color_groups` (app.js
  ~L3140-L3170) and `child_color_groups` (~L3171-L3249). Schema:
  `{{"parents": [{{id, name, color, desc}}, ...], "children": {{"<parentId>":
  [{{name, hex}}, ...]}}}}`. All colors normalised to lowercase `#rrggbb`.
  6 parents, 67 children total.

- **webui_config.json** — full `WEBUI_CONFIG` object (app.js
  `const WEBUI_CONFIG = Object.freeze({{...}})`, ~L26-L194). Kept whole;
  see nested keys (`faces`, `device`, `navigation`, `led`, `autoInterval`,
  `api`, `layout`, `firmwareQueues`, `scroll`, `textScroll`, `fonts`,
  `interaction`, `boot`, `power`).

- **matrix_geometry.json** — computed matrix/wiring lookup tables, ported
  from app.js `XY_TO_INDEX`/`INDEX_TO_XY`/`PHYSICAL_TO_LOGICAL_INDEX`
  (~L3257-L3290), seeded from `EXPRESSION_PARTS.matrix`. Schema: `cols`,
  `rows`, `num_leds`, `row_lengths`, `row_valid_x_ranges`, `serpentine`,
  `serpentine_odd_rows_reversed`, `xy_to_index` (rows x cols grid, -1 for
  invalid cells), `index_to_xy` (370 `[x, y]` pairs), and
  `physical_to_logical_index` (370 entries). Cross-checked against
  every part's `frame` vs `strip_indices` (see extraction script stdout /
  orchestrator report for pass/fail counts).

- **default_faces.json** — unchanged copy of `resources/saved_faces.json`.

- **ark12.json** — unchanged (re-serialized, compact/sorted-keys) copy of
  `resources/fonts/ark12.json` (~2.5MB Ark Pixel 12px bitmap font table).
  **ark12_meta.json** — header fields only: `format`, `source`, `family`,
  `rows`, `lineHeight`, `ascent`, `descent`, `defaultAdvance`, `glyphCount`,
  plus `rowsEncodingVariantsFound` / `rowsEncodingNote` documenting the
  glyph-row encoding variants app.js's `decodePackedGlyphRows()` /
  `loadArkPixelFontTable()` supports.

- **Images/rinaboard.png**, **Images/rina_icon1_default.png**,
  **Images/rina_icon2_hover.png** — plain-file copies of
  `resources/pictures/rinaboard.png` and `resources/loading/rina_icon*.png`
  (not placed in an .xcassets catalog).

- **scroll_text_defaults.json** — scroll/text defaults gathered from
  `index.html` (`#scroll-text` default value) and app.js (`WEBUI_CONFIG.scroll`,
  `WEBUI_CONFIG.autoInterval`, `SCROLL_GENERATOR_VERSION`, brightness preset
  button list, `TEXT_SCROLL_FONT_MODEL`). Schema: `defaultText`, `maxChars`,
  `maxBytes`, `fpsDefault`, `fpsMin`, `fpsMax`, `fpsPresets`,
  `brightnessPresets`, `autoIntervalPresetsMs`, `fontId`, `generatorVersion`.
"""


def write_readme(out_dir: Path) -> None:
    (out_dir / "README.md").write_text(README_TEMPLATE, encoding="utf-8")


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-js", required=True, type=Path)
    parser.add_argument("--resources-dir", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    app_js_path: Path = args.app_js
    resources_dir: Path = args.resources_dir
    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    app_js_text = app_js_path.read_text(encoding="utf-8")
    index_html_path = app_js_path.parent / "index.html"
    index_html_text = index_html_path.read_text(encoding="utf-8")

    expression_parts = extract_expression_parts(app_js_text, out_dir)
    extract_color_presets(app_js_text, out_dir)
    webui_config = extract_webui_config(app_js_text, out_dir)
    frame_check = extract_matrix_geometry(expression_parts, out_dir)
    copy_default_faces(resources_dir, out_dir)
    copy_ark12(resources_dir, out_dir)
    copy_images(resources_dir, out_dir)
    extract_scroll_text_defaults(app_js_text, index_html_text, webui_config, out_dir)
    write_readme(out_dir)

    print(
        f"matrix_geometry frame/strip_indices cross-check: "
        f"{frame_check['checked'] - len(frame_check['mismatches'])}/{frame_check['checked']} parts matched"
    )
    if frame_check["mismatches"]:
        print("Mismatches:")
        for mm in frame_check["mismatches"]:
            print(f"  id={mm['id']} name={mm['name']}")
            print(f"    expected={mm['expected_frame']}")
            print(f"    actual  ={mm['actual_frame']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
