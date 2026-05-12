# Runtime font resources

This directory intentionally contains no distributed font binaries in this patch.

The root script `run_rinachan_unifont.ps1` prepares the LittleFS font files before build/upload:

- `unifont.woff2` — GNU Unifont WebUI subset generated locally from the official GNU Unifont PNG sheet.
- `ark12.woff2` — Ark Pixel Font 12px browser font for the text-scroll input only, copied from the official zh_tw WOFF2 package.
- `ark12.json` — merged Ark Pixel Font 12px bitmap table for LED text-scroll rasterization.

The text-scroll Ark12 bitmap merge order is:

1. `zh_cn`
2. `ja`
3. `zh_tw`

Later sources override earlier ones, so Traditional Chinese glyphs are the final authority for shared codepoints.
