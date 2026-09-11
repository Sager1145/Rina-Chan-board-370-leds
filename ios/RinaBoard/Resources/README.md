# RinaBoard iOS Resources

Static data tables extracted from the legacy ESP32 WebUI (`esp32s3_firmware/data/`)
by `tools/extract_webui_assets.py`. Regenerate with:

```
python3 tools/extract_webui_assets.py \
  --app-js <legacy>/esp32s3_firmware/data/app.js \
  --resources-dir <legacy>/esp32s3_firmware/data/resources \
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
