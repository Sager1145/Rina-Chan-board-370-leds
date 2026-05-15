# Font resources

- `ark12.woff2` and `ark12.json` are LittleFS runtime resources for the text-scroll input/browser preview and LED bitmap rasterizer.
- GNU Unifont is **not** stored here as `unifont.woff2`. The WebUI Unifont subset is embedded directly inside `data/index.html` as a `data:font/woff2;base64,...` URL.
- `run_rinachan_unifont.ps1` rebuilds the modified GNU Unifont subset from the GNU Unifont BMP sheet, embeds it into `index.html`, removes any forbidden external `unifont.woff2`, and validates that no external Unifont source is used.
