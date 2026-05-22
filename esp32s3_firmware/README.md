# RinaChanBoard ESP32-S3 AP WebServer

This PlatformIO firmware starts an ESP32-S3 AP, serves `data/index.html` and `data/resources/saved_faces.json` from LittleFS, and accepts the WebUI firmware API:

- `POST /api/frame` with `M370:<93 hex>` frame data.
- `POST /api/scroll` with a complete M370 frame sequence plus frame interval / fps for firmware-side text scrolling.
- `POST /api/command` for color, brightness, A/M mode, text-scroll pause/resume/stop/interval, and debug commands.
- `GET/POST /api/saved_faces` for the unified `saved_faces.json`.
- `GET /api/status` for runtime state.

LED output is a 370 LED WS2812/NeoPixel chain on `GPIO2` with serpentine physical wiring: logical row 0 is forward, logical row 1 is reversed, and so on. M370 bit `0..369` remains the logical row-major display order; the firmware maps those logical bits to the physical serpentine LED index before writing NeoPixel data. Brightness is clamped to the project raw range `10..200`; the WebUI percentage is still `raw / 255`, so the capped maximum displays as about `78%`.

`/api/frame` only applies the M370 mask plus `reason` / `playback`. Color and brightness are global renderer state and should be changed through `/api/command`.

## Build / Upload

After extracting the ZIP, enter `esp32s3_firmware` and run the single root PowerShell script:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```

The script has no unzip/extraction logic. It only runs inside the already extracted project folder. Without upload switches, it runs a normal PlatformIO build:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1
```

Equivalent manual PlatformIO commands remain:

```sh
pio run
pio run -t upload
pio run -t uploadfs
```

If `uploadfs` is skipped or LittleFS fails to mount, the AP still starts and the root page returns a diagnostic message instead of a silent 404.

After boot, connect to:

- SSID: `RinaChanBoard-ESP32S3`
- Password: `rinachan`
- URL: `http://rina.io/`
- Original IP URL: `http://192.168.1.14/`

The AP runs a local DNS responder for `rina.io`; it resolves only while your browser/device is connected to the board's AP WiFi.

Default startup brightness: `50/255`.
After the startup sequence completes, the board displays the default face: `face_08_triangle_eyes_frown`.

## WebUI / text-scroll font resources

Normal WebUI page chrome now uses **GNU Unifont fully offline**. `data/index.html` defines `@font-face("GNU Unifont")` with an embedded base64 `data:font/woff2` URL. There is no `local()` source and no external Unifoundry URL in the WebUI CSS.

The WOFF2 is a WebUI-focused GNU Unifont subset generated at run time from the official GNU Unifont BMP PNG sheet downloaded or reused from `.font_cache`. The build tool scans the current WebUI files and runtime JSON resources, filters out characters that cannot be produced from the BMP PNG sheet, verifies the generated cmap, and embeds the generated font directly into the `@font-face` rule inside `data/index.html`.

The text-scroll textarea and the actual LED text-scroll rasterizer intentionally remain on `Ark Pixel 12px Monospaced`. The Ark12 bitmap table is merged in this priority order: `zh_cn -> ja -> zh_tw`, so Traditional Chinese glyphs are applied last when multiple regional forms share the same Unicode codepoint. The page preloads `/resources/fonts/ark12.woff2` from the `<head>` and actively calls `document.fonts.load()` during boot so the textarea font is requested immediately instead of waiting until the 6.4 page is first painted.

Expected LittleFS resources in `data/resources/fonts/`:

- `ark12.woff2` — Ark Pixel Font 12px browser font, used only by the text-scroll textarea.
- `ark12.json` — merged Ark Pixel Font 12px bitmap table used by the LED text-scroll rasterizer.

Only these two font files are needed in LittleFS. GNU Unifont is embedded in `data/index.html`, not stored as a separate LittleFS font file. The deliverable intentionally removes duplicate Ark source folders, old single-language/legacy font resources, and the duplicate `ark12_merged_trad_priority.json` copy.

The root script synchronizes the embedded `index.html` GNU Unifont font on every normal run, so WebUI text changes cannot leave the page using a stale subset. It downloads or reuses the official GNU Unifont PNG sheet and builds the subset locally using Python `pillow`, `fonttools`, and `brotli`. If the merged `ark12.woff2` and `ark12.json` already exist, the script does not download Ark resources; otherwise it downloads or reuses official Ark12 release archives, merges `zh_cn,ja,zh_tw`, and writes the canonical `ark12.json`. For fastest textarea rendering, upload LittleFS after these resources are prepared so `/resources/fonts/ark12.woff2` is served locally by the ESP32. The Python dependency probe is executed from a temporary `.py` file instead of `py -c` inline code, which avoids PowerShell quoting/native stderr failures on Windows.

### Font cache note

After uploading LittleFS, force a reload with a cache-busting URL such as `http://rina.io/?v=ark12-merged-trad1` or clear the browser cache for the ESP32 AP page. The original `http://192.168.1.14/` address still works.

## Text-scroll playback model

The 6.4 text-scroll page generates one M370 frame per horizontal LED-column offset. The default frame rate is **20 fps** (`intervalMs = 50 ms`). The frame-rate field is `fps`; changing it sends `intervalMs = round(1000 / fps)` to firmware. The WebUI uploads the complete M370 frame sequence to `/api/scroll`; firmware caches the sequence and plays it from a dedicated FreeRTOS render task pinned to Core 1, instead of advancing frames from the main WebServer loop.

The firmware render task uses elapsed-time compensation. Under normal load it advances one cached frame per interval; if WiFi/HTTP briefly delays scheduling, it catches up to the correct timeline rather than holding the last frame and then advancing only once.

The text-scroll controls are firmware-cache-first: the old **生成文字滚动** button was removed, **发送** prepares/uploads the full frame sequence and starts playback immediately, **暂停** is a pause/resume toggle, and **停止/清屏** sends `stop_scroll` with `clear:true` so the firmware actually writes a blank frame before returning to the saved-face M/A mode. Editing the text while playback is running only marks the timeline dirty; it no longer auto-uploads a new sequence until **发送** is clicked again.

During firmware text-scroll playback, the WebUI throttles `/api/status` polling and ignores stale `lastM370` fields so the browser preview does not jump back to an older static face while the LED matrix keeps scrolling.

The Ark Pixel 12 px glyph line is vertically centered inside the 18-row LED matrix before frame extraction.

## Saved faces model

Default faces, custom faces, and parts-combination faces all live in one file: `data/resources/saved_faces.json`.

- Default faces use `type: "default"`.
- Default faces cannot be deleted.
- Default faces can be renamed and manually sorted.
- User-saved faces use `type: "custom"`.
- Parts-combination saves use `type: "parts"`.
- Saved face `order` values are persisted 1-based, matching the WebUI list number.
- Default face ID numbers must start at 1.
- The current startup default remains the triangle-eyes face, persisted as `face_08_triangle_eyes_frown`.
