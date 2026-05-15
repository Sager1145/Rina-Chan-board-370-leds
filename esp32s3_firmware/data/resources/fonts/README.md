# Runtime font resources

This directory contains the runtime font resources uploaded to LittleFS.

- `unifont.woff2` — GNU Unifont WebUI subset generated locally from the official GNU Unifont BMP PNG sheet. The same WOFF2 is also embedded into `data/index.html` as a base64 `data:font/woff2` URL so the WebUI can use the embedded font immediately.
- `ark12.woff2` — Ark Pixel Font 12px browser font for the text-scroll input only, copied from the official zh_tw WOFF2 package.
- `ark12.json` — merged Ark Pixel Font 12px bitmap table for LED text-scroll rasterization.

The root script `run_rinachan_unifont.ps1` rebuilds/synchronizes the GNU Unifont WebUI subset before build/upload, then validates required LittleFS resources. Unsupported characters that cannot be produced from the BMP PNG sheet are reported and skipped rather than forced into the subset.

The text-scroll Ark12 bitmap merge order is:

1. `zh_cn`
2. `ja`
3. `zh_tw`

Later sources override earlier ones, so Traditional Chinese glyphs are the final authority for shared codepoints.
