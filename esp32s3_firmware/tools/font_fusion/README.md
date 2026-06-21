# Bundled Ark12 fusion font resources

These files are the fused Ark Pixel 12px resources used by `run_rinachan_unifont.ps1` / `run_rinachan_unifont.sh`.

- `ark12_fusion.json`: strict-format bitmap glyph table for LittleFS LED text rasterization, including patched CJK glyphs (然 / 燃 / 滚 / 滾) and Mona12 monochrome emoji.
- `ark12_base.woff2`: single merged browser font layer (Ark Pixel 12px base + fused fallback CJK glyphs + Mona12 emoji in one CFF webfont).

The previous split `ark12_fallback.woff2` layer no longer exists; its glyphs were merged into `ark12_base.woff2`. `data/styles.css` no longer carries the merged cmap as a giant `unicode-range`; `tools/sync_ark12_css_glyphs.py` validates the WOFF2 cmap against the JSON glyph table instead.

The upload script copies these into `data/resources/fonts` when needed and validates the target characters before upload.
