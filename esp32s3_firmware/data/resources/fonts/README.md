# Font resources

- `ark12.json` is the fused Ark Pixel 12px bitmap glyph table for LittleFS LED text rasterization. It keeps the original `rina_ark_pixel_font_bitmap_v1` structure and includes patched CJK glyphs such as `然 / 燃 / 滚 / 滾` plus Mona12 monochrome emoji (one 12x12 glyph per codepoint, same cell/advance as a kanji).
- `ark12.json.gz` is generated temporarily during LittleFS upload/image creation and deleted afterward. Keep edits in `ark12.json`.
- `ark12.woff2` is the single merged browser font for the text-scroll input/browser preview: Ark Pixel 12px base + fused fallback CJK glyphs + Mona12 emoji, all in one CFF webfont. No separate `ark12_fallback.woff2` exists anymore; its glyphs are merged in. `styles.css` intentionally omits the giant Ark `unicode-range`; the upload scripts validate the WOFF2 cmap against `ark12.json`.
- Emoji glyphs are forced to the full-width kanji advance (1200/1200 em). Emoji format controls (VS15/VS16, ZWJ, skin-tone modifiers, tag characters) are zero-width.
- GNU Unifont is not stored here as `unifont.woff2`. The WebUI Unifont subset is embedded directly inside `data/styles.css` as a `data:font/woff2;base64,...` URL.
- `run_rinachan_unifont.ps1` (Windows) / `run_rinachan_unifont.sh` (macOS) validate the fused Ark12 resources before upload and copy the bundled files from `tools/font_fusion` if needed.
- To re-merge addon glyphs into both the JSON table and the webfont, use `tools/merge_mona12_emoji.py` (see its docstring; supports `--extra-addon path:prefix`).
