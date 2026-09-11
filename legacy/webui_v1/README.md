# Legacy WebUI (v1) — archived, not part of the firmware

Snapshot of the browser-based control UI that the ESP32-S3 firmware served from LittleFS
until the RinaLink refactor (2026-09-11, commit 5e166dc and earlier). It is kept here for
reference only; the firmware no longer ships it and the iOS app (`ios/`) replaced it.

Contents
- `data/index.html`, `data/app.js` (14k lines), `data/styles.css` — the single-page app.
- `data/resources/fonts/` — ark12 bitmap glyph table + woff2 subsets used for scroll text.
- `data/resources/loading|pictures` — boot-loader icons and board photo.
- `src/web_api.cpp/.h` — the old HTTP/REST + static-file server.
- `scripts/` — gzip + WebServer-timeout build hooks; `tools/`, `run_rinachan_unifont.*` — font pipeline.

The feature list of this UI is documented in `docs/FEATURE_INVENTORY.md`; the data tables
were extracted into `ios/RinaBoard/Resources/` with `tools/extract_webui_assets.py`.
