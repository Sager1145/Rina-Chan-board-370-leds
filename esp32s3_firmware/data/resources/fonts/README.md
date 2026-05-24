# Font resources

- `ark12.json` is the fused Ark Pixel 12px bitmap glyph table for LittleFS LED text rasterization. It keeps the original `rina_ark_pixel_font_bitmap_v1` structure and includes patched glyphs such as `然 / 燃 / 滚 / 滾`.
- `ark12.json.gz` is the gzip sibling served when the browser accepts gzip. It must be regenerated whenever `ark12.json` changes.
- `ark12.woff2` is the base Ark Pixel 12px browser font layer for the text-scroll input/browser preview.
- `ark12_fallback.woff2` is the fused fallback browser font layer for Ark-missing CJK glyphs, including `然 / 燃 / 滚 / 滾`.
- GNU Unifont is not stored here as `unifont.woff2`. The WebUI Unifont subset is embedded directly inside `data/styles.css` as a `data:font/woff2;base64,...` URL.
- `run_rinachan_unifont.ps1` validates the fused Ark12 resources before upload and copies the bundled files from `tools/font_fusion` if needed.
