# Bundled Ark12 fusion font resources

These files are the fused Ark Pixel 12px resources used by `run_rinachan_unifont.ps1`.

- `ark12_fusion.json`: strict-format bitmap glyph table for LittleFS LED text rasterization.
- `ark12_base.woff2`: original Ark Pixel 12px browser font layer.
- `ark12_fallback.woff2`: fusion fallback layer containing glyphs missing from Ark12, including 然 / 燃 / 滚 / 滾.

The upload script copies these into `data/resources/fonts` when needed and validates the target characters before upload.
