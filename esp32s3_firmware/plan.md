# Project Plan / Technical Specification — Rina-Chan Board (370-LED ESP32-S3)

> Fully rewritten 2026-07-02 (rev 2) as a reconstruction-ready implementation
> specification, verified line-by-line against the current source tree. The code in this
> repository is the source of truth; this document describes the implementation as it
> exists today, including known bugs, stale comments, and dead paths. A developer or AI
> agent should be able to rebuild the firmware, build scripts, and WebUI behavior from
> this document alone. Anything that could not be fully confirmed from the code is
> explicitly marked `Needs verification`.

---

## 1. Project overview

### 1.1 What the project does

The Rina-Chan board is a wearable/portable 370-LED face display (22×18 irregular matrix
of WS2812 LEDs) driven by an ESP32-S3. The firmware:

- renders single-color packed 1-bit frames ("faces") on the LED matrix,
- plays saved faces manually or on an auto-rotation timer,
- runs a firmware-side scrolling-text engine (17–1000 ms/frame) from a PSRAM frame cache,
- shows button-triggered LED overlay animations (mode A/M, brightness, auto-interval,
  battery pages),
- monitors battery/charger voltage via two ADC channels,
- hosts a Wi-Fi SoftAP + DNS captive domain + HTTP server serving a single-page WebUI
  and a JSON/binary API,
- persists faces, runtime settings, and battery calibration on LittleFS,
- exposes a USB-CDC serial console and structured serial logging (`RLOG_*`).

The WebUI (vanilla JS, no bundler, one 14k-line `app.js` served from LittleFS) provides
live LED preview, a pixel face editor, a parts-based face composer, text-scroll control
with a browser-side bitmap-font rasterizer, saved-face library management, and a debug
console page.

### 1.2 Target hardware / runtime environment

- MCU: ESP32-S3 (board `esp32-s3-devkitc-1`), 8 MB embedded OPI PSRAM, USB-CDC serial
  (`ARDUINO_USB_CDC_ON_BOOT=1`).
- LEDs: 370 × WS2812 (GRB wire order, 800 kHz) on GPIO 2, serpentine-wired irregular
  matrix.
- 6 hardware buttons (GPIO, `INPUT_PULLUP`, pressed = LOW).
- 2 ADC inputs: battery pack (2S Li-ion via 100k/57k divider) and charger detect
  (270k/47k divider).
- Framework: Arduino-ESP32 3.3.9 / ESP-IDF 5.5.4 via the pioarduino community platform
  55.03.39 (required for the new RMT TX driver `driver/rmt_tx.h`).
- Client: mobile-first WebUI in a browser connected to the board's SoftAP
  (`http://rina.io/` via captive DNS, or `http://192.168.1.14/`).

### 1.3 Main internal modules

| Layer | Module | Files |
|---|---|---|
| Firmware | Runtime state store (singleton) + scroll buffers | `src/state.h/.cpp` |
| Firmware | LED transport backends (Adafruit / RMT / RMT+DMA) | `src/led_driver.h/.cpp` |
| Firmware | Frame renderer, packed-frame queue, presented-frame telemetry | `src/led_renderer.h/.cpp`, `src/led_presentation.h` |
| Firmware | Scroll session (upload txn / playback / pause / step) | `src/scroll_session.h/.cpp` |
| Firmware | Core-1 render/scroll task | `src/scroll.h/.cpp` |
| Firmware | Modes, saved-face apply, auto playback, deferred restore | `src/faces.h/.cpp` |
| Firmware | Hardware buttons (debounce/combos/repeat) | `src/buttons.h/.cpp` |
| Firmware | Button/battery LED overlay animations | `src/button_animations.h/.cpp` |
| Firmware | Battery/charge ADC monitor + calibration persistence | `src/power_monitor.h/.cpp` |
| Firmware | HTTP API + static file server + AP/DNS | `src/web_api.h/.cpp` |
| Firmware | LittleFS mount + atomic JSON persistence | `src/storage.h/.cpp` |
| Firmware | 4 FreeRTOS mutexes + RAII lock helpers | `src/sync.h/.cpp` |
| Firmware | Structured serial log + LED command history ring | `src/serial_log.h/.cpp` |
| Firmware | Serial test console | `src/serial_console.h/.cpp` |
| Firmware | Parsing/time helpers, PSRAM JSON allocator | `src/utils.h/.cpp`, `src/psram_json.h` |
| WebUI | Single-page app | `data/index.html`, `data/app.js`, `data/styles.css` |
| Assets | Fonts, images, persisted JSON | `data/resources/**` |
| Build | PlatformIO envs + pre/post scripts | `platformio.ini`, `scripts/*.py` |
| Tooling | Font pipeline (BDF → bitmap JSON, woff2 subsets) | `tools/*.py`, `run_rinachan_unifont.ps1/.sh` |

### 1.4 Firmware ↔ WebUI relationship

- The firmware is the single source of truth for displayed state. The WebUI mirrors it
  by polling (`/api/status`, `/api/preview_sync`, `/api/power`) and pushes changes via
  `/api/frame`, `/api/command`, `/api/scroll`, `/api/saved_faces`.
- Scroll frames are generated **in the browser** from the `ark12.json` bitmap glyph
  table, uploaded in chunks into firmware RAM/PSRAM, and played back **by the firmware**.
  The WebUI runs a cosmetic local preview whose *speed* (never frame position jumps) is
  phase-locked to the LED's actually-presented frames reported by `/api/preview_sync`.
- `saved_faces.json` lives on LittleFS; the WebUI edits it in memory and POSTs the whole
  unified document back; the firmware validates, writes atomically, and hot-reloads.
- No localStorage/sessionStorage is used anywhere; all WebUI state is rebuilt from the
  firmware on every page load.

### 1.5 Compatibility baseline

All public endpoints, JSON field names, the 47-byte packed frame format, the
`rina_packed_faces_370_v2` schema, button semantics and timings, pin assignments,
defaults, and the WebUI↔firmware protocol in §6 must remain unchanged. Full checklist:
§16.

---

## 2. Repository structure

| Path | Type | Purpose | Important details |
|---|---|---|---|
| `platformio.ini` | config | Build environments | Default env `esp32s3-rmt-dma`; pioarduino platform 55.03.39; envs `esp32s3` (Adafruit), `esp32s3-test` (+`RINACHAN_VERBOSE_LOGS=1`), `esp32s3-rmt`, `esp32s3-rmt-dma` |
| `partitions.csv` | config | Flash layout | nvs 0x5000 @0x9000; otadata 0x2000 @0xe000; app0 factory 2 MB @0x10000; littlefs 0x5F0000 (~5.9 MB) @0x210000. No OTA slots |
| `src/config.h` | source | Every firmware constant | Pins, matrix layout, timings, limits, LED backend selection macros, feature gates (§5, §13) |
| `src/config.cpp` | source | AP IP constants | `AP_IP_ADDR` = 192.168.1.14, gateway 192.168.1.14, mask 255.255.255.0 |
| `src/main.cpp` | source | `setup()`/`loop()` | Boot sequence §4.2, cooperative loop §4.3; `g_syncReady` single-core fallback |
| `src/state.h/.cpp` | source | `RuntimeState`, `RuntimeFace`, `ScrollTimelineMeta`, `RuntimeStore` singleton | PSRAM-first allocation of 3072×47 B scroll cache + 4097 B sourceText buffer; `stateVersion`/`slowUiDirty` publish cursors |
| `src/sync.h/.cpp` | source | Frame/Scroll/Storage/HardwareBus mutexes | `lockStorage()` takes Storage **then** HardwareBus; unlock reverse. Nesting order Scroll → Frame → Storage → HardwareBus |
| `src/led_driver.h/.cpp` | source | WS2812 transport | Backend 0 Adafruit_NeoPixel; backend 1 ESP-IDF RMT TX (optional DMA), IRAM encoder, mem-symbol fallback 2046→1024→512→256→64 |
| `src/led_renderer.h/.cpp` | source | Packed-frame queue, render-to-strip, telemetry | `renderCurrentFrameToLedStrip()` non-reentrant (C3); queue depth 3; 33 ms min apply interval; serpentine map |
| `src/led_presentation.h` | source | Presented-frame telemetry types | `LedPresentationContext`, `LedPresentedSample`, `LedPresentationSource` enum + `ledPresentationSourceName()` |
| `src/scroll.h/.cpp` | source | Core-1 `led_scroll_render` task | Notify-driven 1 ms loop: scroll tick + all LED rendering |
| `src/scroll_session.h/.cpp` | source | Firmware scroll state machine | Upload txn begin/write/commit, start/stop/pause/step/tick, snapshot/meta copy |
| `src/faces.h/.cpp` | source | Modes, saved-face apply, auto playback, deferred restore | `setMode`, `toggleModeFromButtonAction`, `serviceAutoPlayback`, `serviceDeferredFaceRestore`, `stopFirmwareScroll`, `startFirmwareScroll` |
| `src/buttons.h/.cpp` | source | GPIO buttons | Debounce 25 ms; combos B3+B1/B3+B2; repeats; `runButtonAction()` single logical entry point |
| `src/button_animations.h/.cpp` | source | LED overlays | Mode A/M, interval, brightness, battery pages, edge flash; all glyph/icon bitmap tables live here |
| `src/power_monitor.h/.cpp` | source | ADC sampling + battery model | Non-blocking 16-sample trimmed mean, EMA, LUT percent, disconnect detection, calibration JSON |
| `src/web_api.h/.cpp` | source | All HTTP routes, AP/DNS, static files | `RinaWebServer` subclass with zero-copy `plainBody()`; gzip sibling serving; chunked storage-locked streaming (static 4 KB buffer) |
| `src/storage.h/.cpp` | source | LittleFS mount + JSON persistence | Atomic write via `.tmp` + rename; PSRAM-first read buffers; saved-faces validation/load |
| `src/serial_log.h/.cpp` | source | `RLOG_*` structured logging | Levels ERROR..TRACE, default INFO; single `Serial.write` per line ≤240 B; 16-entry LED command ring |
| `src/serial_console.h/.cpp` | source | USB serial console | Commands: `help`, `status`, `frame clear`, `frame hex <94 hex>`, `btn B1..B6`, `color #RRGGBB`, `bright 10..200` (see §3.6 known gap) |
| `src/utils.h/.cpp` | source | Helpers | `parseColorHex`, `formatColorHex`, `millisReached/millisElapsed` (wrap-safe), `jsonCapacityFor(n) = max(32768, 2n+4096)`, `hexNibble` |
| `src/psram_json.h` | source | `PsramJsonDocument` | ArduinoJson `BasicJsonDocument` with PSRAM-first allocator (internal-heap fallback) |
| `data/index.html` | asset (source) | SPA markup, all element IDs | ~610 lines, CRLF line endings; boot loader overlay; version-stamped asset URLs (see §2.1 anomaly) |
| `data/app.js` | asset (source) | Entire WebUI runtime | ~14,050 lines; ordered blocks: `WEBUI_CONFIG` → `EXPRESSION_PARTS` → runtime aliases/state → API client/queues → feature modules → `bootstrapWebUi()` |
| `data/styles.css` | asset (source) | All layout/visuals | ~3,290 lines; LED cell glow, glass top bars, boot keyframes, responsive breakpoints, `contain: layout paint` on matrix wraps |
| `data/resources/saved_faces.json` | data | Shipped face library | Schema §6.2; 11 default faces; `startupDefaultId: "face_08_triangle_eyes_frown"`; document `version: 4` |
| `data/resources/runtime_settings.json` | data | Persisted mode + auto interval | Schema §6.3 |
| `data/resources/battery_calib.json` | data | Battery min/max calibration | Schema §6.4 |
| `data/resources/fonts/ark12.json` | generated asset | Scroll bitmap font table (~2.5 MB) | Format `rina_ark_pixel_font_bitmap_v1` (§6.6); lazily fetched by the WebUI |
| `data/resources/fonts/ark12.woff2` | generated asset | Browser display font for the scroll input (~830 KB) | Warmed post-boot in the background |
| `data/resources/fonts/unifont.woff2` | generated asset | GNU Unifont WebUI UI-font subset | Preloaded first in `index.html`, `font-display: block` |
| `data/resources/loading/rina_icon1_default.png`, `rina_icon2_hover.png` | asset | Boot loader avatar images | Also used as favicon |
| `data/resources/pictures/rinaboard.png` | asset | LED preview background photo | 4000 px reference width; `preloadRinaboardImage()` gates the card reveal |
| `scripts/gzip_webui_assets.py` | script | LittleFS pre/post hook | §3.4 |
| `scripts/patch_webserver_timeout.py` | script | Pre-build framework patch | §3.4 |
| `tools/compile_ark_bdf.py` | script | Single BDF → bitmap JSON | §3.5 |
| `tools/build_ark12_merged.py` | script | Merge zh_cn+ja+zh_tw Ark BDFs | §3.5 |
| `tools/merge_mona12_emoji.py` | script | Merge Mona12 emoji into ark12 assets | §3.5 |
| `tools/build_unifont_webui_subset_from_png.py` | script | Build unifont.woff2 WebUI subset | §3.5 |
| `tools/sync_ark12_css_glyphs.py` | script | Validate woff2 cmap ⇔ JSON glyph set | §3.5 |
| `run_rinachan_unifont.ps1` / `.sh` | script | One-shot build pipeline runners (Windows / macOS bash 3.2) | §3.5 |
| `licenses/GNU_UNIFONT_WEBUI_SUBSET_NOTICE.txt` | doc | Font license notice | Keep when shipping the unifont subset |
| `.vscode/extensions.json` | config | Recommends PlatformIO IDE | — |

### 2.1 Known file anomalies (confirmed 2026-07-02)

- `data/index.html` **ends with an unclosed HTML comment followed by two NUL bytes**:
  the trailing comment advertises "Test instrumentation for AI agents … `data-testid` +
  `data-test-code` and exposes `window.__ui`", but no such script exists anywhere in the
  repo (`data-testid`/`__ui` appear only inside this comment). Browsers tolerate the
  unclosed comment because it is after all content. Treat the comment as stale; the
  instrumentation it references was never shipped or was removed.
- `WEBUI_CONFIG.textScroll.fontResource` is `"/resources/fonts/ark12.json?v=dev"` and
  its comment claims the `?v=dev` token is rewritten to a content hash at build time by
  `scripts/gzip_webui_assets.py` (`REWRITE_TARGETS`). The current script contains **no**
  rewrite step — the URL ships literally as `?v=dev`. Because the firmware serves
  `.json` under `Cache-Control: public, max-age=86400` (not immutable), this is
  functional but the comment is stale. `Needs verification` whether hash-rewrite should
  be restored.
- `src/serial_log.h` comments mention runtime `log on|off` / `log level …` serial
  commands and a `led command_history` command; `serial_console.cpp` implements **none
  of them** (only the commands listed in §3.6). `rinaLogSetEnabled/SetLevel`,
  `rinaLogCopyLedHistory` are currently dead API surface reachable only from code.
- `data/app.js` `MATRIX_VIEW_CONFIGS` registers a `matrix-parts` view, but no
  `#matrix-parts` element exists in `index.html`; `initMatrix()` silently returns for
  it. Only three matrix views materialize: `matrix-basic`, `matrix-custom-edit`
  (editable), `matrix-debug`. The parts page (6.2) shares `matrix-custom-edit`.
- `app.js` reads several fields the firmware never emits (forward-compatibility hooks,
  all currently inert): `data.scrollLimits.maxTextBytes`, `renderer.scrollMaxFrames`,
  `data.next_poll_ms`, `data.unchanged`, and it appends status query args
  (`?runtimeOnly=1&noFrame=1`, `since=`) that the firmware ignores (same full response
  either way).

---

## 3. Build, flash, and run process

### 3.1 Required tools

- PlatformIO CLI (`pio`), Python 3.
- Platform package:
  `https://github.com/pioarduino/platform-espressif32/releases/download/55.03.39/platform-espressif32.zip`
  (Arduino-ESP32 3.3.9 / IDF 5.5.4). The official `platformio/espressif32` platform will
  **not** compile the RMT backends (no `driver/rmt_tx.h`).
- `lib_deps`: `bblanchon/ArduinoJson@^6.21.5`, `adafruit/Adafruit NeoPixel@^1.12.3`.
- Font tooling (only for regenerating fonts): `pillow`, `fonttools`, `brotli`.

### 3.2 Build environments and flags

Common flags (base env `esp32s3`, inherited by all others):
`-D BOARD_HAS_PSRAM`, `-D ARDUINO_USB_CDC_ON_BOOT=1`, `-D RINACHAN_AP_ONLY=1`,
`-D ARDUINO_RUNNING_CORE=0 -D ARDUINO_EVENT_RUNNING_CORE=0` (with matching
`build_unflags` removing the `=1` defaults; pins Arduino/WiFi work to Core 0, reserving
Core 1 for the LED task), `-D HTTP_MAX_DATA_WAIT=200 -D HTTP_MAX_POST_WAIT=200 -D
HTTP_MAX_SEND_WAIT=200`, `-D ENABLE_SERIAL_DIAGNOSTICS=1 -D ENABLE_SERIAL_CONSOLE=1 -D
ENABLE_SERIAL_UART0_MIRROR=1`.
Board settings: `board_build.filesystem=littlefs`, `board_build.partitions=partitions.csv`,
`board_build.psram_type=opi`, `board_build.arduino.memory_type=qio_opi` (must match the
8 MB embedded OPI PSRAM or boot fails with a PSRAM ID read error).
`monitor_speed=115200`, `upload_speed=921600`.

| Env | Extra flags | LED backend |
|---|---|---|
| `esp32s3` | — | Adafruit_NeoPixel (baseline / safe fallback) |
| `esp32s3-test` | `RINACHAN_VERBOSE_LOGS=1` | Adafruit + chatty `LOGV` |
| `esp32s3-rmt` | `RINACHAN_LED_BACKEND=1`, `RINACHAN_LED_RMT_WITH_DMA=0` | RMT, no DMA |
| `esp32s3-rmt-dma` (default) | `RINACHAN_LED_BACKEND=1`, `RINACHAN_LED_RMT_WITH_DMA=1` | RMT + DMA (production, Wi-Fi-glitch-resistant) |

Config gates enforced at compile time (`config.h`): `ENABLE_SERIAL_CONSOLE=1` requires
`ENABLE_SERIAL_DIAGNOSTICS=1`; `ENABLE_SERIAL_UART0_MIRROR=1` requires
`ARDUINO_USB_CDC_ON_BOOT=1`.

### 3.3 Commands

```sh
pio run                            # build default env (esp32s3-rmt-dma)
pio run -e esp32s3 -t upload       # flash Adafruit baseline
pio run -e esp32s3-rmt-dma -t upload
pio run -t uploadfs                # build + flash LittleFS image (WebUI + resources)
pio device monitor                 # 115200 baud serial console/log
```

### 3.4 Build scripts (`extra_scripts` in platformio.ini)

| Script | Stage | Inputs | Outputs | Side effects / failure |
|---|---|---|---|---|
| `scripts/patch_webserver_timeout.py` | `pre:` | framework `WebServer.h` (in the installed PlatformIO package) | patched header | Replaces the `HTTP_MAX_DATA_WAIT`…(up to `HTTP_MAX_CLOSE_WAIT`) macro region with `#ifndef`-guarded 200 ms defaults so the `-D` build-flag overrides take effect. Skips with a WARNING if the file or macro region is missing. Idempotent; modifies the installed framework package, not the repo |
| `scripts/gzip_webui_assets.py` | pre+post actions on `$BUILD_DIR/littlefs.bin` | `data/index.html`, `data/app.js`, `data/styles.css`, `data/resources/fonts/ark12.json` | temporary `<file>.gz` siblings (gzip level 9) baked into the FS image, deleted after the image is built | mtime-based up-to-date check; skips missing files; only text assets (woff2/png untouched). Contains **no** `?v=` hash rewriting (§2.1) |

### 3.5 Font pipeline and convenience runners

`data/resources/fonts/` is the single source of truth for font assets (the former
`tools/font_fusion` mirror was removed).

| Script | Purpose | Key parameters / behavior |
|---|---|---|
| `tools/compile_ark_bdf.py` | Compile one Ark Pixel 12px monospaced BDF into the compact WebUI bitmap table | Output format `rina_ark_pixel_font_bitmap_v1`, `rows:12, lineHeight:12, ascent:10`; per-glyph rows stored as hex, decoded to bits |
| `tools/build_ark12_merged.py` | Merge multiple Ark Pixel BDF languages into one JSON | Merge priority low→high: `zh_cn → ja → zh_tw` (traditional wins conflicts). Glyph entry: `glyphs[HEX_CP] = [advance, width, height, xOffset, yOffset, dstY, "HEX/ROWS"]`. Sanity constant `EXPECTED_OFFICIAL_ARK12_MONO_COUNT = 24408` |
| `tools/merge_mona12_emoji.py` | Merge Mona12 monochrome emoji into `ark12.json` + `ark12.woff2` (+ CSS unicode-range if present) | UPEM 1200 = 12 px grid (100 units/px); emoji treated as 12×12 full-width glyphs, `ASCENT_PX=10`, `EMOJI_BITMAP_Y_OFFSET=-1`; zero-width controls skipped (FE00–FE0F, 200D, 1F3FB–1F3FF, E0000–E007F); existing Ark glyphs are never overwritten; `CACHE_BUST "20260612-emoji-input-v3"` |
| `tools/build_unifont_webui_subset_from_png.py` | Build the small offline GNU Unifont WOFF2 WebUI subset from an official BMP PNG glyph sheet | Charset collected from the current WebUI files, filtered to glyphs producible from the sheet, verified after build; standalone mode writes `data/resources/fonts/unifont.woff2` and rewrites the `@font-face` in `styles.css` (`--external-css`/`--external-href`); legacy `--embed-index` (base64 data URI) still supported. Non-BMP emoji intentionally excluded. Deps: pillow, fonttools, brotli |
| `tools/sync_ark12_css_glyphs.py` | Pre-upload validation | Proves `ark12.woff2` cmap and `ark12.json` glyph table describe the same codepoint set; a CSS unicode-range, if present, is an extra constraint |
| `run_rinachan_unifont.ps1` (Windows) / `run_rinachan_unifont.sh` (macOS, bash 3.2-compatible) | One-shot: prepare/verify fused Ark12 assets (download upstream sources into `.font_cache/` if missing), build unifont subset, gzip web assets, PlatformIO build, optional flash | Flags (sh / ps1): `--upload-firmware`/`-UploadFirmware`, `--upload-fs`/`-UploadFS`, `--skip-prepare-fonts`, `--no-download` (fail instead of downloading), `--check-only` (verify without pio), `--env <env>` / `-Environment` (default `esp32s3-rmt-dma`), `--monitor` (+`--monitor-baud`, default 115200), `--unifont-version` (default `17.0.04`), ps1-only `-ArkVersion` (default `2026.05.07`) and `-ArkLanguages` (default `zh_cn,ja,zh_tw`), `--version v1|v2` (default v2) — swaps every "V2" label to "V1" (and back) in `index.html`, `app.js`, `src/config.h` before building |

### 3.6 Manual steps / conventions

- After editing `app.js`/`styles.css`, bump the `?v=` stamps in `index.html`. Current
  stamps: `styles.css?v=20260702-matrix-contain-v1`,
  `app.js?v=20260702-perf-memo-poll-doc-v1`, `unifont.woff2?v=17.0.04-webui-2`. The
  firmware serves js/css/woff2 with `Cache-Control: public, max-age=31536000, immutable`;
  `index.html` itself is `no-cache`, so stamps are the only cache-bust mechanism.
- `pio run -t uploadfs` is required for any `data/` change to reach the device.
- Font regeneration (only when changing fonts): run the `tools/` pipeline (or a
  `run_rinachan_unifont.*` script), then bump `WEBUI_CONFIG.textScroll.fontModel`
  (§11.3 identity rules).
- Serial console commands actually implemented (`serial_console.cpp`): `help`, `status`,
  `frame clear`, `frame hex <94 hex chars>`, `btn <B1..B6|B3B1|B3B2>`,
  `color <#RRGGBB>`, `bright <10..200>`. Anything else prints
  `ERR unknown command; type help`.

---

## 4. Firmware / backend architecture

### 4.1 Core/task model

- **Core 0** — Arduino `loop()` cooperative scheduler (~1 kHz; `vTaskDelay(1 tick)` per
  pass): HTTP server + DNS, buttons, power monitor, packed-frame queue, auto playback,
  serial console, button-animation service, deferred face restore.
- **Core 1** — `led_scroll_render` task (`LED_RENDER_TASK_STACK_BYTES` 6144,
  priority `LED_RENDER_TASK_PRIORITY` 3, pinned to `LED_RENDER_TASK_CORE` 1 via
  `xTaskCreatePinnedToCore`): scroll tick cursor + **all** LED strip rendering. Woken by
  `xTaskNotifyGive` (from `requestLedRender()` / `notifyScrollRenderTask()`, ISR-safe) or
  a 1 ms `ulTaskNotifyTake` timeout.
- If mutex creation fails at boot (`initSyncPrimitives()` returns false), the render task
  is never started and Core 0's loop calls `renderCurrentFrameToLedStrip()` directly
  (single-core degraded mode, `g_syncReady=false`, FATAL log + FS-error LED pattern).

### 4.2 Boot sequence (`setup()`, `src/main.cpp`)

1. `pinMode(LED_PIN, OUTPUT); digitalWrite(LOW)`; hold `LED_BOOT_DATA_LOW_HOLD_MS`
   (20 ms) + `LED_SIGNAL_RESET_US` (300 µs) — clears floating-line random lit pixels.
2. `Serial.begin(115200)`, 200 ms delay, record `runtimeState().bootMs`.
3. `rinaLogInit()` (UART0 mirror init + LED-history reset; historical bug B4: this call
   was once missing) + `initSerialConsole()`; log `SYS event=boot stage=serial_ready`.
4. `initRuntimeScrollFrameBuffer()` — allocate 3072×47 = 144,384 B scroll cache
   (PSRAM-first via `heap_caps_malloc(MALLOC_CAP_SPIRAM)`, internal-SRAM fallback, WARN
   if neither → `/api/scroll` will return 507) and the 4097 B sourceText buffer.
5. `initSyncPrimitives()` — create the 4 mutexes; on failure print FATAL, show FS-error
   pattern, run single-core.
6. `initLedIndexMap()` — precompute the 370-entry logical→physical serpentine map.
7. `ledStripBegin()` — backend `begin()`, brightness=`DEFAULT_BRIGHTNESS` (50), clear,
   one locked `refresh()`; then hold `LED_BOOT_CLEAR_HOLD_MS` (350 ms).
8. `setColorStateNoRender(DEFAULT_COLOR)` (`#f971d4`).
9. `mountFilesystem()` (`LittleFS.begin(false, "/littlefs", 10, "littlefs")`); on
   failure `showFilesystemErrorPattern()` (first 12 LEDs red, color forced `#ff0000`,
   reason `littlefs_mount_failed`); on success `loadRuntimeSettings()` then
   `loadSavedFaces(true)` (applies the startup face: brightness reset to 50, playback
   set, `lastAutoSwitchMs` seeded in auto mode, frame queued with reason
   `startup_sequence_complete_saved_face`).
10. `renderCurrentFrameToLedStrip()` once + `consumeLedRenderRequest()` (prevents the
    task double-rendering the boot frame); settle `LED_BOOT_STARTUP_SETTLE_MS` (120 ms).
11. `startScrollRenderTask()` (if syncReady) → `initHardwareButtons()` →
    `initPowerMonitor()` (blocking first ADC sample, ~4 ms/pin) → `startAccessPoint()` →
    `startWebServer()`; log `stage=ready faces=<n> mode=<mode>`.

`startAccessPoint()`: `WIFI_AP` mode, `softAPConfig(192.168.1.14, …)`,
`softAP("RinaChanBoard-V2", "rinachan")`, **`WiFi.setSleep(false)`** (modem-sleep off —
its periodic interrupt-latency spikes corrupt RMT refills), DNS server on port 53 for
domain `rina.io` (TTL 60).

### 4.3 Main loop (`loop()`, order matters)

```
servicePackedFrameQueue();        // drain queued frames (rate-limited 33 ms)
if (!g_syncReady) renderCurrentFrameToLedStrip();   // single-core fallback only
webServerTick();                  // dnsServer.processNextRequest + server.handleClient
serviceRuntimeSlowStatePublish(); // slowUiDirty -> stateVersion bump (10 s window)
serviceHardwareButtons();         // debounce / combos / repeats + B6 overlay inputs
serviceSerialConsole();
serviceButtonAnimations();        // overlay expiry / phases / render requests
servicePowerMonitor();            // one ~100 µs ADC conversion per pass (non-blocking)
serviceDeferredFaceRestore();     // post-blank face restore (90 ms hold)
serviceAutoPlayback();            // auto face rotation
vTaskDelay(pdMS_TO_TICKS(1));
```

### 4.4 Core-1 task loop (`scrollRenderTask`, `src/scroll.cpp`)

Each iteration: (1) `consumeLedRenderRequest()`; (2) under the Scroll lock,
`scrollSessionTickCursorLocked(millis(), nextFrame)` — if a scroll frame is due, also
fill a `LedPresentationContext` (source `ScrollTick`, reason
`firmware_text_scroll_tick`, rateEligible=true) via
`scrollSessionFillPresentationContextLocked`; (3) if a scroll frame was produced, under
the Frame lock re-check the render request, copy the frame into `runtimeFrameBits()`
only if `firmwareScrollActive` is still true, `++framesAccepted`, set the pending
presentation context; (4) TRACE log rate-limited to ≤1/s; (5) if anything needs
rendering, `renderCurrentFrameToLedStrip()`; (6) `ulTaskNotifyTake(pdTRUE, 1 ms)`.

Scroll tick timing (`scrollSessionTickCursorLocked`): requires active && !paused &&
frameCount>0 && buffer ready. Advances `scrollFrameIndex = (i+1) % count` when
`now − lastScrollFrameMs ≥ intervalMs` (interval constrained 17..1000). Drift control:
if elapsed ≤ `SCROLL_DRIFT_RESET_INTERVALS` (4) × interval, `lastScrollFrameMs +=
interval` (keeps long-term rate exact); otherwise snap to `now`.

### 4.5 Rendering path (`renderCurrentFrameToLedStrip`, `src/led_renderer.cpp`)

- **Non-reentrant by design (C3)**: statics `overlayRgb[370*3]`,
  `lastAppliedBrightness`, `lastLedShowUs` are unguarded; callers are mutually exclusive
  by construction (setup() before the task starts; Core-1 task only afterwards; Core-0
  loop only in the no-mutex fallback). Do not add call sites.
- Steps: `consumePendingLedPresentationContext()` → snapshot frame bits + brightness +
  RGB under the Frame lock → enforce `LED_RENDER_MIN_GAP_US` (2500 µs) between latches
  (busy-wait the remainder) → `leddrv::setBrightness` only when changed → if
  `copyButtonAnimationOverlay(overlayRgb, 370)` returns true, push the full-RGB overlay
  through `logicalToPhysicalMap` and force `ctx.rateEligible=false`; else set each lit
  logical pixel to (colorR,G,B) and unlit to black → 300 µs reset gap →
  `withHardwareBusLock([]{ leddrv::refresh(); })` → `publishLedPresentedSample(ctx,…)`
  (only when `ctx.valid`; increments `presentedSeq`; TRACE log ≤1/s) → 300 µs reset gap.
- Plain renders without a context (brightness/color refreshes, queue flushes) publish
  nothing, so a stray refresh can never clobber the last good scroll sample.

LED driver backends (`leddrv::` namespace, compile-time selection via
`RINACHAN_LED_BACKEND`):

- **Adafruit** (`backendName()="adafruit"`): `Adafruit_NeoPixel strip(370, 2,
  NEO_GRB+NEO_KHZ800)`; brightness applied inside `show()`; byte-identical to the
  historical firmware.
- **RMT** (`"rmt"` / `"rmt-dma"`): static `sPixels[370*3]` in GRB order with brightness
  pre-scaled per component (`scale8: value*brightness/255`) in `setPixel`. Custom IRAM
  WS2812 encoder (bytes encoder + copy encoder for the reset code): bit0 = 0.3 µs H /
  0.9 µs L, bit1 = 0.9 µs H / 0.3 µs L at `RINACHAN_LED_RMT_RESOLUTION_HZ` 10 MHz,
  MSB-first, 50 µs reset symbol split across one `rmt_symbol_word_t`. Channel:
  `trans_queue_depth=4`, `intr_priority=3` (`RINACHAN_LED_RMT_INTR_PRIORITY`, driver max),
  DMA per env. `mem_block_symbols` fallback chain 2046→1024→512→256→64 (DMA hard cap
  2047 and must be even → 2046; non-DMA candidates >512 skipped; whole frame =
  370×24+1 = 8881 symbols never fits DMA, so refills still occur but are rare at 2046).
  `refresh()` = `rmt_transmit` + `rmt_tx_wait_all_done(100 ms)` — keeps synchronous
  `show()` semantics **required by the presented-sample telemetry**. Channel creation
  happens on the caller's stack (an earlier `esp_ipc_call_blocking` variant overflowed
  the ~1 KB IPC task stack and panicked). Diagnostics: `lastRefreshUs`, `maxRefreshUs`,
  `refreshFailCount`, `ready()`.

### 4.6 Packed-frame queue (`led_renderer.cpp`)

- `applyPackedFrameQueued(bits, reason, err)`: `validatePackedFrame` (§6.1) →
  `enqueuePackedFrame`: if the queue is empty and ≥`PACKED_FRAME_MIN_INTERVAL_MS`
  (33 ms) since the last apply, publish immediately; otherwise append to a
  `PACKED_FRAME_QUEUE_DEPTH` (3)-deep ring, overwriting the oldest (`framesDropped++`)
  when full. Publishing = copy into `runtimeFrameBits` under the Frame lock, set
  `lastReason` (reason strings capped to `PACKED_FRAME_REASON_CHARS` 64),
  `framesAccepted++`, `touchRuntimeState()`, `requestLedRender()`.
- `servicePackedFrameQueue()` (loop): dequeues one frame per pass when the 33 ms window
  allows (`framesDequeued++`).
- `applyPackedFrameImmediate(bits, reason, ctx)`: bypasses the queue (scroll start /
  step), optionally setting the presentation context first.
- `clearQueuedPackedFrames()`: drops the whole queue (`framesDropped += count`).
- `applyBlankFrame(reason)`: enqueues an all-zero frame.
- Counters `framesAccepted/Rejected/Queued/Dequeued/Dropped` surface in
  `/api/status.stats`.

### 4.7 Shared state and locking

Mutexes (`sync.cpp`): `Frame` (current frame bits + color/brightness), `Scroll` (scroll
session fields + PSRAM cache + timeline meta + sourceText), `Storage` (LittleFS I/O),
`HardwareBus` (WS2812 transmit). Global nesting order: **Scroll → Frame → Storage →
HardwareBus**. `lockStorage()` deliberately acquires Storage **then** HardwareBus
(unlock reverse) so every flash transaction is serialized with the WS2812 transmit —
flash-cache stalls corrupt WS2812 timing even with DMA.

Spinlocks (`portMUX_TYPE`): LED render-request flag, presentation
context/sample, power-status snapshot (`sPowerStatusMux`), button-animation state
(`sAnimMux`), LED command-history ring. `RuntimeState` scalar fields owned by the
Core-0 loop (mode/playback/auto counters/persistence counters) are written without
locks **by convention** — never write them from Core 1 or an ISR.

`stateVersion` (starts at 1; wraps skipping 0) increments via `touchRuntimeState()`; the
WebUI uses it for change detection. `touchRuntimeStateSlow()` only sets `slowUiDirty`,
which `serviceRuntimeSlowStatePublish()` folds into a version bump at most every
`POWER_WEB_SLOW_PUBLISH_MS` (10 s) — used for high-frequency low-priority changes
(brightness spam, rejected-frame counters).

### 4.8 Memory-sensitive buffers

| Buffer | Size | Location |
|---|---|---|
| Scroll frame cache | 3072 × 47 B = 144,384 B | PSRAM preferred, internal heap fallback |
| Scroll sourceText | 4,097 B | PSRAM preferred |
| Saved faces | 128 × `RuntimeFace` (String id/name + 47 B bits + order/jsonIndex/flags) | static inside `RuntimeStore` |
| Overlay RGB scratch | 1,110 B static | internal (`led_renderer.cpp`) |
| RMT pixel buffer | 1,110 B static | internal (`led_driver.cpp`) |
| Static-file stream buffer | 4,096 B static | internal (safe: single-request sync server) |
| JSON documents | payload-sized; `PsramJsonDocument` for large payloads (saved_faces POST/load, scroll meta) | PSRAM-first |
| `/api/status` doc | 3,072 B | heap (O5) |
| `/api/command` parse doc | `min(3·bodyLen+512, MAX_SCROLL_TEXT_BYTES+4096)` | heap (O4) |

### 4.9 Error handling / recovery (firmware)

- LittleFS mount failure → red 12-LED pattern; file-backed routes return 404/503.
- Scroll buffer unavailable → `/api/scroll` 507; `/api/scroll/meta` 507 if its staging
  alloc fails.
- Mutex creation failure → single-core degraded mode.
- HTTP client stalls capped at 200 ms (patched header + build flags) so a hung client
  cannot stall the loop or the scroll cadence.
- No custom watchdog or OTA; recovery is power-cycle. `micros()` wrap (~71 min) is
  handled on the WebUI side via `presentedSeq` ordering.

### 4.10 Key function contracts (selected)

| Function | File | Contract |
|---|---|---|
| `requestLedRender()` | led_renderer.cpp | ISR-safe; sets the flag under a spinlock + notifies the Core-1 task |
| `consumeLedRenderRequest()` | led_renderer.cpp | Test-and-clear of the render request flag |
| `readFrameStateSnapshot()` | led_renderer.cpp | Frame-locked copy: colorHex, brightness, lastReason, lit count (`countLitLedsLocked`, tail-masked popcount), framesAccepted |
| `validatePackedFrame(bits,&err)` | led_renderer.cpp | Rejects null and any non-zero unused bit above LED 369 (valid mask on byte 46 = `0x03`) |
| `setColor(String,&err)` | led_renderer.cpp | Accepts `#RRGGBB`/`RRGGBB`; updates hex+RGB under the Frame lock; slow-touch; render request |
| `setBrightness(int)` | led_renderer.cpp | `constrain(10..200)`; Frame lock; slow-touch; render request |
| `setMode(input, persist)` | faces.cpp | Normalizes `auto/a/自动/A`→auto, `manual/m/手动/M`→manual, else returns false. Force-stops scroll first when a scroll is displaying. auto: playback=`auto_saved_face`, unpause, reset `lastAutoSwitchMs`. manual: playback→`idle` if it was `auto_saved_face`; when persist, also clears `restoreAutoAfterScroll`. Persists `runtime_settings.json` when persist && mode changed |
| `setAutoInterval(ms, persist)` | faces.cpp | `constrain(500..10000)`; persist optional; no-op if unchanged |
| `applySavedFaceIndex(i, reason, playback)` | faces.cpp | `i % faceCount`; sets playback; queues the face frame; false when no faces / apply fails |
| `applyRelativeSavedFace(±1, reason)` | faces.cpp | Wrapping prev/next, playback `idle` |
| `toggleModeFromButtonAction(source)` | faces.cpp | Stops scroll (no clear/restore-default), clears restoreAuto, flips mode (persisted). If non-face output was active (`playbackIsNonFaceActivity()`): blank frame + deferred current-face restore; else applies the current saved face immediately |
| `stopFirmwareScroll(restoreAuto, clear=true, restoreDefault=true)` | faces.cpp | Cancels deferred restore; forces clear if a scroll is displaying; on clear schedules the startup-default-face restore `LED_STOP_CLEAR_BLANK_HOLD_MS` (90 ms) after the blank; else if restoreAuto → `setMode("auto", false)` |
| `startFirmwareScroll(intervalMs, uiFps)` | faces.cpp | Cancels deferred restore; `scrollSessionStart` (restoreAuto |= caller-was-auto); while scrolling `mode` is forced to `manual` |
| `serviceAutoPlayback()` | faces.cpp | auto && !paused && faces>0: advance index every `autoIntervalMs`, queue frame reason `firmware_auto_saved_face` |
| `serviceDeferredFaceRestore()` | faces.cpp | Fires once `deferredFaceRestoreDueMs` reached; skipped (cancelled) if a scroll became active; kinds: STARTUP_DEFAULT (startup-default face + mode restore) or CURRENT_FACE |
| `scrollSessionStart(interval, callerAuto, uiFps)` | scroll_session.cpp | Requires frames + buffer; clears the packed queue; index→0; interval constrained 17..1000; uiFps normalized (explicit clamp 1..60, else round(1000/interval) clamp 1..255); publishes frame 0 immediately with a ScrollStart context (never rate-eligible) |
| `scrollSessionStop(restoreAuto, clearDisplay)` | scroll_session.cpp | Resets all scroll runtime state; `clearDisplay` also wipes timeline meta + sourceText (`clearScrollTimelineMetaLocked`), else only invalidates upload progress (`invalidateScrollUploadLocked` — keeps sourceText/timelineId/fontId/generatorVersion for restore); clears the packed queue; on clear queues a blank frame reason `firmware_text_scroll_stop_clear` and reports `shouldRestoreDefault` |
| `scrollSessionStep(dir, out)` | scroll_session.cpp | ±1 modulo count; forces active + userPaused + paused; playback=`scroll_step` |
| `setFirmwareScrollPauseFlag(userFlag, paused)` | scroll_session.cpp | Split user/system pause flags; effective = user OR system; playback ↔ `scroll`/`scroll_paused`; on resume re-seeds `lastScrollFrameMs = millis()` |
| `scrollSessionBeginUpload/BeginAppend/WriteFrames/CommitUpload` | scroll_session.cpp | Non-append resets count/meta and stores timelineId/fontId/generatorVersion/sourceText/totalFrames/uiFps (IDs capped at 47 chars); WriteFrames validates the target range and does a single memcpy for the whole chunk under one lock cycle; Commit updates `framesReceived`, `nextChunkIndex`, sets `uploadComplete` when `framesReceived ≥ totalFramesExpected > 0` |
| `runButtonAction(button, source)` | buttons.cpp | Single logical entry for physical/serial/WebUI button actions; uppercases/trims code; logs one canonical `BUTTON … event=action handled=` line; see §9 |

---

## 5. Hardware configuration

### 5.1 Pins and electrical

| Function | Pin | Notes |
|---|---|---|
| WS2812 data | GPIO 2 (`LED_PIN`) | 370 LEDs, GRB order, 800 kHz |
| Button B1 (next face) | GPIO 17 | `INPUT_PULLUP`, pressed = LOW |
| Button B2 (prev face) | GPIO 16 | " |
| Button B3 (mode toggle / combo modifier) | GPIO 15 | " |
| Button B4 (brightness −) | GPIO 40 | " |
| Button B5 (brightness +) | GPIO 41 | " |
| Button B6 (battery overlay) | GPIO 42 | " |
| Battery ADC | GPIO 10 (`BATTERY_ADC_PIN`) | divider 100k/57k; `vbat = mV/1000 × 2.708333 + 0.2033` |
| Charger ADC | GPIO 1 (`CHARGE_ADC_PIN`) | divider 270k/47k; `vcharge = mV/1000 × 6.684982 + 0.0712` |

ADC: 12-bit resolution, `ADC_11db` attenuation on both pins, `analogReadMilliVolts`.

### 5.2 LED matrix geometry

- 22 columns × 18 rows, irregular row lengths:
  `ROW_LENGTHS = {18,20,20,20,22,22,22,22,22,22,22,22,22,20,20,20,18,16}` (sum 370);
  `ROW_OFFSETS = {0,18,38,58,78,100,122,144,166,188,210,232,254,276,296,316,336,354}`.
- Each row is horizontally centered: `leftPad = (22 − rowLength)/2`. Valid x ranges per
  row (WebUI `row_valid_x_ranges`): `[2,19],[1,20],[1,20],[1,20],[0,21]×9,[1,20],[1,20],
  [1,20],[2,19],[3,18]`.
- Serpentine wiring: `SERPENTINE_WIRING=true`, `SERPENTINE_ODD_ROWS_REVERSED=true` —
  odd rows map `physical = rowStart + (rowLength−1−localX)`. Precomputed once into
  `logicalToPhysicalMap[370]` (`initLedIndexMap`).
- Frame buffer: **packed 1-bit, 47 bytes (`FRAME_BYTES`), logical LED index, LSB-first**
  — LED *i* lives in byte `i>>3`, mask `1<<(i&7)`. The unused top 6 bits of byte 46 must
  be zero (static_assert `FRAME_BYTES == 47`).
- Color model: one global color (`#f971d4` firmware default) + global brightness
  (default 50, range 10–200) applied to all lit pixels. Overlays (§10.1) are full RGB
  and replace the frame; on the RMT backend overlay channels are still brightness-scaled
  in `setPixel`, on Adafruit inside `show()`.
- Update policy: event-driven renders only (no fixed refresh); ≥2500 µs between latches;
  frame applies rate-limited to 33 ms; scroll playback 17–1000 ms per frame.
- Boot blank-frame handling: data line held LOW 20 ms + 300 µs before anything else;
  350 ms hold after the first clear; 120 ms settle after the startup face (§4.2).

---

## 6. Data formats and protocols

### 6.1 Packed frame (universal unit)

47 bytes = 370 bits, logical LED index, LSB-first within each byte. Transport encodings:

- HTTP bodies: **base64** (the sync WebServer exposes POST bodies via `arg("plain")`
  which NUL-truncates; frames are mostly zeros). `/api/frame/current` returns base64
  text.
- `saved_faces.json`: `frameBytes` = array of exactly 47 integers 0..255.
- Serial console: 94 hex chars.

Validation everywhere (`validatePackedFrame` / WebUI `parsePackedFrameText`): decoded
length exactly 47 and unused tail bits zero.

### 6.2 `saved_faces.json` (`/resources/saved_faces.json`)

```json
{
  "format": "rina_packed_faces_370_v2",
  "version": 4,
  "category": "unified_saved_faces",
  "matrix": { "leds": 370, "frameBytes": 47, "frameEncoding": "packed-lsb-first" },
  "startupDefaultId": "face_08_triangle_eyes_frown",
  "updatedAt": "2026-06-20T00:00:00-04:00",
  "faces": [
    {
      "id": "face_01_surprised_winking_with_mouth",
      "name": "surprised / winking with mouth",
      "type": "default",              // "default" | "custom" | "parts"
      "frameBytes": [0, 0, "...47 ints 0..255"],
      "order": 1,                      // 1-based, required, >= 1
      "editable": true,
      "deletable": false,              // false for defaults
      "locked": true,                  // defaults only
      "is_startup_default": false,
      "sourceFile": "saved_faces.json",
      "savedAt": "ISO8601", "updatedAt": null,
      "call": null                     // parts faces: {leye,reye,mouth,cheek} ids
    }
  ]
}
```

Shipped file: 11 `type:"default"` faces, document `version: 4`;
`buildUnifiedFaceDocument()` in app.js also emits `version: 4` and the
`matrix{leds,frameBytes,frameEncoding}` block.

Firmware validation (`validateSavedFaces`): `category == "unified_saved_faces"`;
`faces` is an array with ≤ `MAX_AUTO_FACES` (128) entries; every face has int
`order ≥ 1` and a valid 47-byte frame; **at least one `type:"default"` face**; default
face ids matching `face_<digits>` must have a number ≥ 1 (≤9 digits).

Firmware load (`loadSavedFaces(applyStartupFace)`): PSRAM-buffered read + parse
(nesting limit 32); faces with invalid frames are skipped (jsonIndex still advances);
sort by `(order, original json index)`; startup selection: face with
`is_startup_default` or id == `startupDefaultId`, else first default, else index 0; on
hot reloads (applyStartupFace=false) the previously-displayed face id (or index) is
preserved when still present.

### 6.3 `runtime_settings.json`

```json
{ "format": "rina_runtime_settings_v1", "version": 1,
  "mode": "manual", "autoIntervalMs": 3000, "updatedAtMs": 0 }
```

Written atomically on persisted mode/interval changes; parse failure → rewritten with
defaults (`loadRuntimeSettings`).

### 6.4 `battery_calib.json`

```json
{ "format": "rina_battery_calibration_v1", "version": 1,
  "v_max": 8.0, "v_min": 6.2, "v_max_nominal": 8.0, "v_min_nominal": 6.2,
  "last_max_ms": 0, "last_min_ms": 0, "updated_at_ms": 0 }
```

Saved `BATTERY_CALIB_SAVE_DELAY_MS` (15 s) after a dirty mark (or immediately via
`markPowerCalibrationChanged` on manual reset). Sanitized: max ≥ 8.0 V, min ≤ 6.2 V,
span ≥ `BATTERY_CALIB_MIN_SPAN_V` (0.10 V). **Automatic running min/max calibration is
intentionally disabled** — only `reset_battery_min`/`reset_battery_max` change these.

### 6.5 HTTP API

All routes are registered `HTTP_ANY`; every handler answers `OPTIONS` with 204 + CORS
headers (`Access-Control-Allow-Origin: *`, methods GET/POST/OPTIONS, headers
Content-Type/Accept). JSON responses: `application/json; charset=utf-8`,
`Cache-Control: no-store`. Wrong-method → 400/405 JSON `{ok:false,error}`.

| Route | Method | Request | Response / behavior |
|---|---|---|---|
| `/api/status` | GET | — (WebUI appends `?runtimeOnly=1&noFrame=1` and `since=`; firmware ignores query args) | Full state: `ok, v, version (both = stateVersion), device:"RinaChanBoard", uptimeMs, ap{ssid,ip,domain,url,clients}, power{§13}, renderer{color,brightness,brightnessMin:10,brightnessMax:200,mode,playback,paused,autoIntervalMs,autoFaceCount,autoFaceIndex,frameEncoding:"packed-lsb-first",frameBytes:47,frameBits:370,frameQueueDepth:3,frameQueueCount,lit,lastReason,ledBackend,ledDma,ledRefreshUs,ledRefreshMaxUs,ledRefreshFail,autoFaceId?,autoFaceName?, + scroll fields §6.5a-list}, matrix{leds,frameBytes,frameEncoding}, endpoints{frame,currentFrame,command,scroll,savedFaces,power,status}, stats{framesAccepted,framesRejected,framesQueued,framesDequeued,framesDropped,commandsAccepted,commandsRejected}` |
| `/api/power` | GET | — | `{ok, power:{ok,charging,chargeValid,batteryValid,batteryPercent,vbat,vcharge,batteryPowered,batteryDisconnected,batteryLowVoltageUnpowered}}` |
| `/api/frame/current` | GET | — | `text/plain` base64 of the current 47-byte frame |
| `/api/frame` | GET | — | Same as `/api/frame/current` |
| `/api/frame` | POST | body = base64(47 B); query/form args `playback` (fallback `mode`, default `"idle"`), `reason` (default `"api_frame"`) | Validates; a non-scroll playback stops firmware scroll without restore (`stopFirmwareScroll(false)`); reasons starting `custom_`/`parts_`/`debug_` force mode→manual (not persisted); queues the frame. 200: `{ok,accepted,binary:true,v,frameBytes,frameEncoding,queued,queueCount,queueDepth,leds,color,brightness,reason,mode,playback,autoIntervalMs,autoFaceIndex,lit,autoFaceId?,autoFaceName?}`. 400 on bad base64 / length ≠ 47 / non-zero tail bits (`framesRejected++`) |
| `/api/scroll` | POST | body = base64(N × 47 B) sent as `application/octet-stream` text; query args: `append` (0/1), `start` (0/1), `intervalMs` **or** `fps`, `totalFrames`, `timelineId`, `fontId`, `generatorVersion`, `sourceText` (≤4096 B; **the current WebUI never sends sourceText here** — it goes via `start_scroll`), `chunkIndex`+`source` (informational, unread by firmware) | Non-append: `scrollSessionBeginUpload` resets the session and stores meta. Append: continues at the current frameCount. Every frame validated, then one memcpy writes the chunk; commit updates counters; `start=1` also calls `startFirmwareScroll`. 200: `{ok,frames,chunkFrames,append,started,timelineId,uploadComplete,frameBytes,scrollIntervalMs,uiFps,scrollFps}`. Errors: 400 (empty/decode/N×47/invalid frame), 413 (totalFrames > 3072, sourceText > 4096), 500 (write failed), 507 (no scroll buffer) |
| `/api/scroll/meta` | GET | — | `{ok, scrollTimelineId, hasSourceText, sourceText (full string when present), sourceTextBytes, fontId, generatorVersion, uiFps, scrollIntervalMs, frameCount, frameIndex, uploadComplete, firmwareScrollActive, firmwareScrollPaused}`. Text staged in a PSRAM-first heap buffer; doc sized `MAX_SCROLL_TEXT_BYTES+2048` (bug fixes B1/B2: the old 1 KB doc silently dropped sourceText). 507 if the staging alloc fails |
| `/api/preview_sync` | GET | — | Lightweight presented-frame telemetry (§6.5a). Polled 4 Hz while scrolling, 12.5 Hz idle |
| `/api/command` | POST | JSON `{cmd, payload?{…}}` — every payload field may also appear top-level; payload wins (`cstr/cint/cbool` helpers) | §6.5b. 200 reply (`reply()`): `{ok,v,cmd,color,brightness,mode,playback,paused,autoIntervalMs,autoFaceIndex,frameBytes,frameEncoding,queueCount,lastReason,lit,autoFaceId?,autoFaceName?, firmwareScrollActive,firmwareScrollPaused,firmwareScrollUserPaused,firmwareScrollSystemPaused,restoreAutoAfterScroll,scrollFrameCount,scrollFrameIndex,scrollIntervalMs,uiFps,scrollFps,scrollTimelineId,scrollUploadComplete,scrollHasSourceText}`. 400: invalid/oversized JSON, unknown cmd, failed action (`commandsRejected++`); success `commandsAccepted++` |
| `/api/saved_faces` | GET | — | Streams the raw `saved_faces.json` (chunked, storage-locked). 404 missing, 503 unmounted, 500 open failure |
| `/api/saved_faces` | POST | JSON: the document directly or wrapped as `{document:{…}}` (plus ignored extras like `path`, `reason`) | Validate (§6.2) → atomic write → `loadSavedFaces(false)` hot-reload. 200 `{ok,v,path,bytes}`; 400 invalid (PSRAM-sized parse doc, bug fix B3: the old fixed 16 KB doc capped uploads at ~15–20 faces); 500 write failure |
| `/` and any other GET | GET | — | Static file from LittleFS via `serveFile`; `/` → `/index.html`; prefers a `<path>.gz` sibling when the client sends `Accept-Encoding: gzip` (adds `Content-Encoding: gzip` + `Vary: Accept-Encoding`); content-type by extension; cache policy: `.html` `no-cache`, `.js/.css/.woff2` `public, max-age=31536000, immutable`, everything else `public, max-age=86400`. Chunked 4 KB storage-locked streaming (C2/F1). 404 JSON otherwise |

The firmware `collectHeaders` only `Accept-Encoding`.

#### 6.5a `/api/preview_sync` response

```json
{ "ok":true, "v":123, "mode":"manual", "playback":"scroll",
  "autoFaceIndex":0, "autoFaceCount":11, "lastReason":"...",
  "valid":true, "presentedSeq":4567, "source":"scroll_tick",
  "reason":"firmware_text_scroll_tick", "scrollTimelineId":"scroll-...",
  "presentedFrameIndex":42, "presentedFrameCount":300,
  "frameIndex":42, "frameCount":300,
  "presentedAtUs":123456789, "renderStartUs":123450000, "renderDurationUs":6789,
  "scrollIntervalMs":100, "uiFps":10,
  "firmwareScrollActive":true, "firmwareScrollPaused":false,
  "firmwareScrollUserPaused":false, "firmwareScrollSystemPaused":false,
  "rateEligible":true }
```

`source` ∈ `scroll_tick | scroll_start | scroll_step | manual_frame | clear | overlay |
unknown`. Only `rateEligible:true` samples (continuous ticks, no overlay covering the
frame) may feed fps estimation. `presentedAtUs` is device `micros()` (wraps ~71 min;
consumers rely on `presentedSeq` ordering + bounded windows). Never carries frame data
or sourceText.

#### 6.5b `/api/command` commands

| cmd | payload | Effect |
|---|---|---|
| `set_color` | `hex:"#RRGGBB"` | `setColor`; 400 on parse failure |
| `set_brightness` | `raw` (fallback `brightness`) | `setBrightness` (clamped 10..200) |
| `set_mode` | `mode:"auto"|"manual"` (+ aliases a/m/自动/手动/A/M) | `setMode(persist=true)`; 400 on unknown mode |
| `set_auto_interval` | `ms` | `setAutoInterval(clamped 500..10000, persist=true)` |
| `set_scroll_interval` | `intervalMs` and/or `fps`/`uiFps` | `scrollSessionSetInterval` (17..1000; uiFps normalized) |
| `start_scroll` | `intervalMs`/`fps`, optional `sourceText` (≤4096 B → stored in scroll meta via `scrollSessionSetSourceText`), `timelineId`/`source` ignored | `startFirmwareScroll` |
| `scroll_step` | `direction` (<0 = back, else forward) | Step + `clearQueuedPackedFrames` + immediate frame (reason `firmware_text_scroll_step`, ScrollStep context); latches user-pause |
| `pause_scroll` / `resume_scroll` | — | `scrollSessionSetUserPaused(true/false)` |
| `stop_scroll` | `restoreAuto?` (default = current restore flag), `clear?` (default true) | `stopFirmwareScroll(restoreAuto, clear, restoreDefault=true)` |
| `pause` | — | `paused=true`, playback=`"paused"` |
| `resume` | — | clears user scroll pause, `paused=false`, playback=`"idle"` |
| `apply_saved_face` | `index` (default current), `reason?` (default `webui_apply_saved_face`), `playback?` (default `idle`) | Stops scroll (no clear), clears restoreAuto, applies the face |
| `button` | `button:"B1".."B5"|"B3"|"B3B1"|"B3B2"` | `runButtonAction(source="api_button")` — same semantics as physical; `"B6"` (and unknown codes) return 400 because B6 is not a logical action |
| `terminate_other_activities` | `targetMode?` (default `"manual"`) | `stopFirmwareScroll(false, true, false)` + `setMode(targetMode, persist=false)` |
| `reset_battery_min` / `reset_battery_max` | — | Battery calibration reset (§13.2) |
| `battery_overlay` | `singleShot?` (default true) | `showBatteryOverlay` |
| anything else | — | 400 `unknown command: <cmd>` |

### 6.6 Font bitmap table `ark12.json`

`format:"rina_ark_pixel_font_bitmap_v1"`; header fields `rows:12, lineHeight:12,
ascent:10, descent:2, defaultAdvance:12`; merge policy zh_cn→ja→zh_tw. `glyphs` keyed
by uppercase hex codepoint (e.g. `"4E00"`); value = `[advance, width, height, xOffset,
yOffset, dstY, rows]` where rows are `/`-separated per-row strings — the WebUI accepts
either raw `"01"` bit strings or legacy hex rows (`normalizeGlyphRows` decodes both).
~2.5 MB, tens of thousands of glyphs (24,408 official Ark mono glyphs + merged emoji).
Missing-glyph fallback codepoint: `U+25A1` (□, `missingGlyphCodePoint`).

### 6.7 WebUI browser-side static data

- `EXPRESSION_PARTS` (embedded in app.js, lines ~203–3003): format
  `rina_expression_parts_370_runtime_v4`, version 4. Contains the matrix geometry mirror
  (`cols/rows/num_leds/row_lengths/row_valid_x_ranges/serpentine*`), part `layout` boxes
  (left eye 8×8 @(2,1); right eye 8×8 @(12,1); mouth 8×8 @(7,9); cheeks 4×4 @(2,9)
  mirrored + @(16,9)), `call` id lists (`leye` "0","101".."127"; `reye` "0","201".."227";
  `mouth` "0","301".."332"; `cheek` "400".."405" where 400 maps to empty), default face
  `{leye:101, reye:201, mouth:301, cheek:400}`, and 92 stored parts each with `row_hex`
  local bitmap, `placement`, precomputed 94-hex `frame`, `strip_indices` fallback,
  `lit_count`, `bbox`. Parts are OR-composited (`composePartsFrame`) and sent as
  ordinary packed frames.
- Color presets: `parent_color_groups` / `child_color_groups` drive the two custom
  dropdowns; UI default color `#ec3fc7` (intentionally different from the firmware
  default `#f971d4` — the firmware echo wins after first sync).

---

## 7. WebUI architecture

### 7.1 Files and load sequence

`index.html` → preload `unifont.woff2?v=17.0.04-webui-2` (first resource,
`font-display: block`) + `rina_icon1_default.png` → `styles.css?v=20260702-matrix-contain-v1`
→ boot overlay markup (`#loadingOverlay`, `#blurScreen`, `#avatarBefore/After`) →
sidebar/brand + `#top-page-nav` → three `<section class="page">` panels (`page-basic`
active, `page-parts`, `page-debug`) → `<script src="app.js?v=20260702-perf-memo-poll-doc-v1">`
at the end of body. `<html data-boot-phase="preload" data-scroll-lock="boot">` gates CSS
until boot completes. `app.js` executes `bootstrapWebUi()` immediately
(readyState-guarded).

### 7.2 `bootstrapWebUi()` order (do not reorder — loader smoothness depends on it)

1. `await window.rinaStartLoaderAnimation()` — defined in app.js (~line 6321): plays the
   avatar/halo loader per §10.2 timings.
2. `preloadRinaboardImage()` (starts the 4000-px board photo download in parallel).
3. `prepareFirstPageProgressiveReveal()` — tags reveal cards
   (`WEBUI_CONFIG.boot.firstPageRevealSelector`: `.basic-preview-card`,
   `.basic-mid-col > .card`, `.basic-scroll-col > .card`).
4. `await ensureWebUiFontReady()` (GNU Unifont; local file, fast).
5. `initFirstPageUiBeforeShow()` (button press animations, font observer, nav, colors,
   brightness, basic controls, custom selects, face-library auto-refresh) →
   `initializeBasicPreviewMatrix()` → `renderFirstPageUiBeforeShow()`.
6. `showBootUiBehindLoader()` (`data-boot-phase="ui-ready"`) →
   `await revealFirstPageWaterfall()` (cards `.is-revealed` 115 ms apart, 260 ms settle;
   waits for the board image).
7. `waitForBootLoaderMinimum()` (≥`minDisplayMs` 400 ms) → `finishBootVisibility()`
   (`data-boot-phase="ready"`, `rinaLoaderComplete()`) → `scheduleMatrixFitRender(4)` →
   `initDeferredUiAfterShow()` (initializeMatrixViews — 4 configured, 3 materialize
   (§2.1), observeMatrixWraps, initCustom, initParts, initScroll,
   initializeDebugControls, renderSavedFaces, renderMatrices, renderState,
   fitAllMatrices).
8. First firmware sync **after** the loader: `preloadFirmwareRuntimeState()` (GET
   status, timeout 2500 ms) → `applyBrightnessLocal` + `syncAutoIntervalUi` → if the
   firmware is **not** scrolling, `loadStaticFramePreviewFromFirmware("boot_static_frame")`
   (GET `/api/frame/current`, decode base64 → preview); if it **is** scrolling this is
   skipped → `kickPostBootScrollMetaRestore("post_loader_runtime_ready")` (§11.7).
9. `startFirmwareStatusPolling()` + `startPowerStatusPolling()`;
   `runPostBootDeferredReads()` async: `loadFaceLibrary()` (GET `/api/saved_faces`),
   matrix sync (`syncRuntimeStateFromFirmware` or summary while scrolling; fallback to
   `applyKnownFaceIndexLocal`/`applyStartupDefaultFaceLocal`), then background-warm
   `ark12.woff2`. The 2.5 MB `ark12.json` stays lazy — fetched on first scroll use
   (`ensureArkPixelFontReady`; **must not** use `cache:"no-store"`).
10. Any bootstrap exception: log, reveal the UI anyway, start pollers
    (offline-tolerant).

### 7.3 Pages and navigation

`WEBUI_CONFIG.navigation.pages`: `basic` "6.1 基础控制", `parts` "6.2 自定义表情页面",
`debug` "6.5 调试". `switchPage(id)` toggles `.page.active`, sets
`document.body.dataset.page`, lazy-loads the scroll font on basic, re-fits matrices,
refreshes the shared preview from firmware on page entry
(`refreshSharedPreviewFromFirmware`), and back-fills the debug log
(`renderLog` when dirty). Nav: burger `#brand-nav-toggle` opens `#top-page-nav`
(aria-hidden/inert managed by `setNavMenuOpen`).

### 7.4 Global state (module scope, no framework)

- `state{…}` — firmware mirror + UI: `mode, faceIndex, brightness, defaultBrightness,
  color, parentColorId, selectedChildColor, colorSelection, playback, apDomain, apIp,
  autoInterval, refreshPolicy, lastRefreshReason, refreshCount, textScrollActive,
  actualFps, dpsActive, restoreAutoAfterScroll`, battery/charge display fields +
  thresholds + icon classes, source tags (`apIpSource` Config/Firmware), sync
  timestamps.
- Frame buffers (370-bool arrays): `currentFrame` (shared preview), `editFrame`,
  `customHiddenFrame` (396-bool full-grid hidden cells), `partsFrame`, `scrollFrame`,
  `debugPreviewFrame` (+ source/reason/updatedAt metadata).
- `firmware{online, lastRequest, lastStatus, lastError, sentFrames, sentCommands,
  droppedFrames, droppedCommands, frameQueue, buttonQueue, savedFacesSync, endpoints…}`
  — browser-side diagnostics (explicitly *not* firmware counters).
- `scroll{…}` — §11.2/§11.6 fields.
- Face library: `defaultFaces[]`, `userFaces[]`, `faceLibraryDocument`,
  `faceLibraryFileHandle` (File System Access API), `faceEdit{…}` baseline,
  `editingSavedFaceId`, `selectedCall`, `partsSymmetry`.
- Logs: `logs[]` (`LOG_BUFFER_MAX` 500, `LOG_VIEW_MAX` 120 rendered), levels
  error/warn/info/debug (`#log-level-select`, default info).
- `scrollMachine` — §8.2.

### 7.5 API client

- `apiGet(path, {timeoutMs})`: fetch GET, `cache:"no-store"`, AbortController timeout
  (default `getTimeoutMs` 2500 ms); updates `firmware.online/lastStatus/lastError`.
- `apiPost(path, payload, {timeoutMs, silent, expectJson})`: JSON body (or raw
  ArrayBuffer as octet-stream), default timeout 5000 ms.
- `apiPostWithUploadProgress(path, payload, onProgress)`: XHR, timeout 15000 ms;
  concatenates `payload.frames` (Uint8Array 47 B each) into one N×47 buffer,
  base64-encodes it as the octet-stream body; metadata travels **only** as query params
  from the fixed list `append, start, intervalMs, fps, chunkIndex, totalFrames, source,
  timelineId, fontId, generatorVersion`. Payload fields outside that list
  (`sourceText`, `stepLedPerFrame`, `chunkFrames`, `storage`, `persist`,
  `saveToFlash`) are **never sent on the wire** — sourceText reaches the firmware via
  the `start_scroll` JSON body instead.
- `isOfflineHtmlMode()` (file:// or null origin): every API call throws immediately;
  the UI stays usable for local face-file editing/import/export.
- Rate-limited queues (`makeRateLimitedQueue`): `normalFramePump` (POST `/api/frame`,
  ≥20 ms apart, depth 6, drop-oldest with counters; frame packets carry the base64 body
  plus `?reason=&playback=` query params), `buttonCommandPump` (POST `/api/command`,
  ≥120 ms, depth 4, replies merged via `applyFirmwareRuntimeState`), `liveFramePump`
  (5 ms/depth 1/coalesce; **currently disabled** — `isLiveFrameReason()` always returns
  false because the live path didn't reliably refresh the strip; kept for
  re-enablement). `sendAuxCommand(cmd,payload,source)` posts directly (no queue) and
  merges the reply.

### 7.6 Polling / sync (all suspended while `document.hidden`; resumed on
visibilitychange; `pagehide` stops all timers)

| Poller | Cadence | Endpoint | Guards |
|---|---|---|---|
| Status | 500 ms tick; ≥1000 ms between requests (`firmwareNextPollMs`, server-tunable hook) | `/api/status` (`syncRuntimeStateFromFirmware`, or summary variant `syncRuntimeSummaryFromFirmware` while scrolling — skips frame work) | Skipped while scroll upload/start/restore/light-sync in flight (P1-6) |
| Preview-sync | `PREVIEW_SYNC_POLL_MS` 250 ms while scrolling; **`BUTTON_EVENT_SYNC_POLL_MS` 80 ms idle — INTENTIONAL** (hardware-button feedback latency; do not back off) | `/api/preview_sync` | Skips while a heavy request is in flight; `applyPreviewSyncRuntimeHints` dedupes by state version and can sync a saved-face preview |
| Power | 1000 ms timer; ≥`statusRefreshMs` 900 ms between refreshes | `/api/power` | Only on basic/debug pages; skipped during scroll ops |

Staleness: `PREVIEW_SYNC_TRANSPORT_FAIL_LIMIT` 3 consecutive failures or
`PREVIEW_SYNC_STALE_MS` 5 s without success → `SYNC_STALE`; the next OK sample recovers
(`FW_SYNC_RECOVERED`, snap to presented frame, speed multiplier reset).

`applyFirmwareRuntimeState(data, source, {skipFrame})` is the single merge point for
status/command replies: AP info, power payload, mode, autoInterval, playback + split
scroll pause flags, brightness (skipped if the user touched the slider < 2 s ago),
color (`setColor(...,"firmware_sync")`), face index (+ re-derives the preview from the
saved face's `frameBytes` when the reason is a saved-face reason —
`syncSavedFacePreviewByIndex`, falling back to `scheduleStaticFrameReloadFromFirmware`
on cache miss), `FW_SYNC` dispatch into the scrollMachine, GPIO scroll-stop detection
(reason `gpio_*_B[123]_*` → `resetScrollControlsAfterButton` + delayed full sync
`scheduleFirmwareScrollStopFullSync`, delay 140 ms when `deferredFaceRestoreActive` else
20 ms), and scroll restore bookkeeping (`lastFwScrollTimelineId` etc.).

### 7.7 Rendering

- Matrices: `initMatrix(id, frameProvider, editable, editHandler, compact)` builds
  22×18 = 396 `div.led` cells (dataset x/y/grid/idx; non-LED cells get `.invalid`;
  silently returns when the container id is missing). Live views: `matrix-basic`
  (currentFrame), `matrix-custom-edit` (editable, `editCell` handler), `matrix-debug`
  (currentFrame). `renderMatrices()` diffs per-cell against `view.lastState` and toggles
  `.on` only on change; views on hidden pages are marked dirty and skipped.
  `fitMatrix/fitAllMatrices` compute the `--cell` px size from container bounds
  (previewSize: default 18, min 5, max 62 px; ResizeObserver + resize/visualViewport
  listeners; rAF-batched via `scheduleMatrixFitRender`). `ensureRinaboardStage`
  positions the board-photo background (`--alignment-scale = rect.width/4000`).
- `renderState()` — central state→DOM outlet (badges, mode toggle, debug KV lists);
  memoized (`domWriteIfChanged`) so repeated polls do not touch the DOM.
- `updateScrollUi()` — scroll status label/`scroll-frame-index`/`scroll-actual-fps`,
  button disabled states, upload progress bar; uses `setDom*IfChanged` helpers.
- `renderSavedFaces()` / `createFaceRow()` — face library list (§12).
- `renderLog()` — only when the debug page is visible; rAF-merged; renders the last 120
  lines.
- Editor input: `attachDrawing` binds **click-to-toggle only** (`.led.editable` closest
  target; no drag-draw); `editCell(idx, value, "toggle", {gridIndex})` also drives the
  hidden-cell grid; rAF-batched re-render (`scheduleCustomEditRender`).

### 7.8 Error handling / offline

Every API failure: `firmware.online=false`, `lastError` set, log entry rate-limited to
one per 2.5 s (`shouldLogApiError`), header badge shows 离线. Offline HTML mode never
starts pollers. Boot continues with local defaults if the first sync fails. See §15.

---

## 8. UI states and state machine

### 8.1 Output-mode states (what the LED shows)

`playback` vocabulary shared by firmware and UI: `idle`, `paused`, `auto_saved_face`,
`scroll`, `scroll_paused`, `scroll_step` (+ free-form values passed by `/api/frame`
callers). `mode`: `manual` | `auto`. Firmware scroll flags:
`firmwareScrollActive/Paused/UserPaused/SystemPaused`, `restoreAutoAfterScroll`.
`isScrollPlayback()` = playback ∈ {scroll, scroll_paused, scroll_step}.

### 8.2 WebUI `scrollMachine` (authoritative UI-side machine, app.js ~3557)

Phases: `IDLE, GENERATING, UPLOADING, STARTING, ACTIVE, STEPPING, STOPPING, RESTORING,
STALE, DROPPED`. Pause is orthogonal: `pauseReasons ⊆ {user, system}`; effective pause =
non-empty set, mirrored to `scroll.userPaused/systemPaused/paused` and
`state.playback="scroll_paused"` (`syncPauseBacking`). Epoch + per-domain generation
tokens (`upload/restore/step/statusPoll`; `token()`/`isCurrent()`) invalidate stale
async completions. Events are gated by the `ALLOWED_FROM` table; replacement events
(`GENERATE, STOP, RESTORE_BEGIN, FW_SYNC, TEXT_EDITED, IDENTITY_MISMATCH`) are valid
from any phase. `FW_SYNC` is ignored while GENERATING/UPLOADING/STARTING (upload glitch
protection).

| Current | Trigger | New | Side effects |
|---|---|---|---|
| any | `GENERATE` (Send clicked) | GENERATING | epoch++, identityBound=false |
| GENERATING | `UPLOAD_BEGIN` | UPLOADING | chunked POSTs begin |
| UPLOADING | `UPLOAD_COMMIT_DONE` | STARTING | waiting for start confirm |
| STARTING | `START_CONFIRMED` | ACTIVE | pauseReasons cleared |
| STARTING / UPLOADING·GENERATING | `START_FAIL` / `UPLOAD_FAIL` | IDLE | busy flags cleared, progress reset |
| IDLE/ACTIVE/STARTING/STEPPING/RESTORING | `PAUSE_USER` / `PAUSE_SYSTEM` | (same) | add pause reason |
| " | `RESUME_USER` / `RESUME_SYSTEM` | (same) | remove reason |
| ACTIVE/STEPPING | `STEP` | STEPPING | scroll_step command sent |
| STEPPING | `STEP_DONE` | ACTIVE | (still user-paused) |
| any | `STOP` | STOPPING | epoch++ |
| STOPPING | `STOP_DONE` | IDLE | pauses cleared, session + identity cleared |
| any | `RESTORE_BEGIN` | RESTORING | epoch++ (reload path) |
| RESTORING | `RESTORE_DONE(meta)` | ACTIVE if firmware session else IDLE | identityBound = !truncated ∧ exactGeneratorMatch ∧ frameCount match ∧ timeline match |
| any | `FW_SYNC(payload)` | IDLE↔ACTIVE as session appears/disappears | mirrors firmware cursor + pause flags (via PAUSE/RESUME events); clamps `scroll.frameIndex` |
| any | `TEXT_EDITED` | (same) | identityBound=false |
| ACTIVE/STEPPING/RESTORING | `SYNC_STALE` | STALE | preview frozen, warning |
| STALE | `FW_SYNC_RECOVERED` | ACTIVE/IDLE | snap preview, speed reset, syncState=observe |
| any | `IDENTITY_MISMATCH` | DROPPED | preview dropped (timeline/frame-count mismatch) |
| DROPPED | `DROP_DONE` | RESTORING or IDLE | optional auto-restore (`scheduleScrollDropRecovery`) |

Busy flags (`scroll.commandBusy/startBusy/pauseBusy/stopBusy/stepBusy/fpsBusy/
restoring/lightSyncing/uploading`) gate every scroll control; `updateScrollUi()`
disables buttons accordingly (Send disabled while busy; Stop requires a local frame
cache or DROPPED; pause toggle hard-locked 250 ms per flip (`pauseToggleLocked`);
system-paused-without-user-pause blocks the resume path).

### 8.3 Mode changes during operations

- Entering scroll from auto mode: firmware sets `restoreAutoAfterScroll` and forces
  mode=manual while scrolling; Stop with `restoreAuto:true` returns to auto.
- WebUI A/M toggle sends `button:"B3"` (same path as the physical button). Before any
  local output, `guardBeforeOutput`/`terminateOtherActivities(targetMode, reason)` stops
  conflicting activity (one-way hard interrupt, no auto-resume), updates
  `state.refreshPolicy`, and mirrors to the firmware via the
  `terminate_other_activities` command.
- Any `/api/frame` POST with a non-scroll playback stops a running firmware scroll
  without restore.
- Failed commands: the UI logs, keeps its state, and waits for the next poll to re-sync
  (no optimistic rollback beyond the local fallback the caller provided).

### 8.4 Connection states

`firmware.online` drives the runtime badge (`#badge-runtime`: 在线/离线). Preview-sync
staleness drives STALE independently (§7.6). Reload/reconnect recovery: §11.7.

---

## 9. Button logic

### 9.1 Physical buttons (`src/buttons.cpp`; serviced every ~1 ms; debounce
`BUTTON_DEBOUNCE_MS` 25 ms; all pins INPUT_PULLUP active-low)

| Button | GPIO | Fires | Action | Repeat | Combo |
|---|---|---|---|---|---|
| B1 | 17 | on press | stop scroll (no clear-forcing, restoreAuto cleared) + next saved face `applyRelativeSavedFace(+1)` reason `gpio_B1_next_saved_face` | after `FACE_REPEAT_DELAY_MS` 650 ms, every `FACE_REPEAT_MS` 350 ms; suppressed while B3 held | B3 held → `B3B1` |
| B2 | 16 | on press | prev saved face (−1), same scroll-stop | 650/350 ms | B3 held → `B3B2` |
| B3 | 15 | **on release**, only if not combo-consumed | `toggleModeFromButtonAction` — mode auto↔manual (persisted); applies the current saved face (via blank + 90 ms deferred restore if non-face output was active) | none | modifier for B1/B2 |
| B4 | 40 | on press | brightness −`BRIGHTNESS_BUTTON_STEP` 8 (clamped ≥10) | after `BRIGHTNESS_REPEAT_DELAY_MS` 450 ms, every `BRIGHTNESS_REPEAT_MS` 120 ms | — |
| B5 | 41 | on press | brightness +8 (clamped ≤200) | 450/120 ms | — |
| B6 | 42 | on release / long hold | short (<700 ms): single-shot battery overlay (2 s). Long (≥`BATTERY_LONG_PRESS_MS` 700 ms, only while B2 **and** B3 are not held): continuous battery overlay; the release after a long press stops the overlay | none | long-press blocked if B2/B3 held |
| B3+B1 | — | on B1 press while B3 held | auto interval −`AUTO_INTERVAL_BUTTON_STEP_MS` 500 ms (min 500) | none (comboConsumed on both) | consuming B3 means its release does nothing |
| B3+B2 | — | on B2 press while B3 held | auto interval +500 ms (max 10000) | none | " |

Implementation notes: every logical action funnels through
`runButtonAction(code, source)` with sources `gpio`, `serial`, `api_button` (log labels
physical/serial/webui via `buttonSourceLabel`). GPIO-handled actions additionally
trigger LED overlays (`startButtonAnimationForGpioAction`; called from
`finishButtonAction` only when source=="gpio"). B1/B2 actions call
`stopFirmwareScroll(false)` + `scrollSessionSetRestoreAuto(false)` first. B6 is **not**
a logical action (returns false → 400 over the API); its behavior lives in
`handleButtonAnimationGpioPress/Release` + `serviceButtonAnimationButtonInputs`.
`initHardwareButtons()` latches the initial pin state so a held-at-boot button does not
fire an edge.

### 9.2 WebUI buttons (all commands rate-limited via the 120 ms command queue; button
presses get the 90/150 ms visual press animation)

| DOM id | Action | API |
|---|---|---|
| `mode-toggle` | A/M toggle (optimistic local flip + preview) | command `button:"B3"` |
| `face-prev` / `face-next` | prev/next face (optimistic local preview `applyKnownFaceIndexLocal`; resets scroll controls first) | command `button:"B2"` / `"B1"` |
| `brightness-minus/plus` (−8/+8), `brightness-range`, `brightness-input`, `#brightness-presets`, `brightness-reset-default` (→50) | brightness 10–200 | command `set_brightness {raw}` (slider drags logged at debug level; firmware echoes suppressed 2 s) |
| `interval-down/up` (±0.5 s), `auto-interval-range` (0.5–10 s step 0.1), `auto-interval`, `#auto-interval-presets` | auto interval 500–10000 ms | command `set_auto_interval {ms}` |
| `color-input` (`#RRGGBB`), `color-swatch`, `parent-color-select`, `child-color-select` | color pick (custom dropdown UI) | command `set_color {hex}` |
| `scroll-play` (发送) | generate + upload + start (§11.4) | `/api/scroll` chunks + `start_scroll` |
| `scroll-pause` | pause/resume toggle (`togglePauseScroll`) | `pause_scroll` / `resume_scroll` |
| `scroll-stop` (停止/清屏) | stop + clear (+ auto-restore per `returnMode`/`restoreAutoAfterScroll`) | `stop_scroll {clear:true, restoreAuto}` |
| `scroll-step-prev` / `scroll-step-next` | one frame (direction −1 / +1; restores local frames first if needed) | `scroll_step {direction}` |
| `scroll-speed-reset-default` (→10), `scroll-speed-minus/plus` (±5), `scroll-speed-range`, `scroll-speed` input, `#scroll-speed-presets` | fps 1–60 | `set_scroll_interval {fps, intervalMs}` (live retune only when a session exists and identity holds) |
| `custom-send` / `custom-live-toggle` (实时, default ON) | send editor frame / auto-send on change | `/api/frame` reasons `custom_face_send`/`custom_live_send` |
| `custom-clear/fill/invert`, `parts-random`, `parts-reset`, `parts-symmetry-toggle`, `parts-revert` | editor/parts ops | local edit + live send |
| `custom-frame` textarea, `custom-copy`, `custom-import` | packed-frame hex I/O | local |
| `custom-name` + `custom-save` | save (or update, when editing) a face | `/api/saved_faces` POST via `persistFaceDocuments` |
| Face library rows (`.face-library-list`) | apply / edit / rename / drag-reorder / delete | `apply_saved_face {index}`; library POSTs |
| `.faces-json-open-local`, `.faces-json-download-all` (+ hidden import/save-local bindings) | local JSON file round-trip | File System Access API / download |
| Debug: `firmware-ping`, `debug-fw-refresh-power`, `debug-clear-api-error`, `debug-copy-diag`, `debug-refresh-power`, `debug-reset-battery-min/max`, `update-adc` (local simulation only), `debug-ap-pass-toggle`, `debug-network-refresh`, `.debug-sim[data-gpio]` (B1,B2,B3,B4,B5,B6S,B6L,B3B1,B3B2,B6B3), `firmware-pause`, `debug-preview-*` (local patterns), `debug-send-*` (frame POSTs reason `debug_*`; all-on needs confirm + 40 W warning), `debug-frame-*` (hex/JSON/base64 parser lab), `debug-raw-validate/send` (+ `debug-raw-confirm` checkbox), `log-clear/download/copy`, `log-level-select`, `debug-clear-user-faces` (danger; keeps defaults) | diagnostics | status/power GETs, `reset_battery_*`, `battery_overlay {singleShot}`, `button` commands, raw `/api/command` |

`B6S`→`battery_overlay {singleShot:true}`, `B6L`→`{singleShot:false}`, `B6B3` is a
WebUI-local network-info refresh (no firmware command).

---

## 10. Animation system

### 10.1 Firmware LED overlays (`src/button_animations.cpp`)

The overlay buffer is full-RGB and **replaces** the frame while active
(`copyButtonAnimationOverlay` consumed by the renderer). A running scroll is
system-paused while any overlay shows (`pauseScrollForOverlay`) and resumed afterwards.
Overlay-covered latches are never rate-eligible for fps telemetry.

| Overlay | Trigger | Content | Duration / refresh |
|---|---|---|---|
| Mode | B3 (GPIO) | Big "A" (auto) or "M" (manual) 10×13 glyph at (6,2), purple `MODE_COLOR` (180,0,255) | `FLASH_HOLD_MS` 1000 ms |
| Interval | B3B1/B3B2 (GPIO) | `CLOCK_ICON` (22×18) + text `X.XS` (rounded to 0.1 s; exactly `10S` at max), purple; at min/max also an edge flash (B3B1→bottom, B3B2→top, mode color) | 1000 ms; edge flash `EDGE_FLASH_MS` 305 ms (attack 45, decay 260), re-render every 33 ms |
| Brightness | B4/B5 (GPIO) | `SUN_ICON` + `NN%` (`round(raw×100/200)`), blue `BRIGHTNESS_COLOR` (0,120,255); edge flash at min (bottom) / max (top), blue | 1000 ms; same edge params |
| Battery single-shot | B6 short release / `battery_overlay {singleShot:true}` | `BATTERY_ICON` colored by charge + `NN%` text | `BATTERY_SHORT_HOLD_MS` 2000 ms, refresh 100 ms |
| Battery continuous | B6 long ≥700 ms / `battery_overlay {singleShot:false}` | Pages rotate every `BATTERY_PHASE_MS` 2000 ms: percent → pack voltage `X.XV` (voltage layout: +1 px gap after 3rd glyph) → (only while charging) charger voltage in white. While charging the fill animates: 200 ms/column sweep to the target; <10%: 1-column blink at 300 ms | until stopped (B6 release-after-long or a new overlay); refresh `BATTERY_REFRESH_MS` 100 ms (`BATTERY_ANIM_REFRESH_MS` 50 ms while charging) |

Battery color ramp (`batteryColor`): ≤10% red (255,0,0); 10–30% red→orange lerp
(g: 0→165); 30–50% orange→green lerp (r: 255→0, g: 165→255); >50% green. Fill columns
(`batteryFillCols`): 0 below 10%, 8 above 90%, else `((p−10)·8+79)/80` (ceil). Fill
occupies columns x=7..14, rows y=2..4 inside the icon. Edge flash spatial falloff from
center x=10.5 with floor 0.20. Glyph tables (5×7 digits 0–9, `S`, `V`, 1-wide `.`,
3-wide `%`; `BIG_A`/`BIG_M`; `CLOCK_ICON`/`SUN_ICON`/`BATTERY_ICON` 22×18) live in this
file and must be copied exactly for identical visuals. Text drawing: gap 1 px, max 8
glyphs, centered; y0 = 9 with icon / 5 without. State is guarded by the `sAnimMux`
spinlock; the power snapshot is read **outside** it (audit M1).

### 10.2 WebUI boot loader (index.html markup + styles.css keyframes + `WEBUI_CONFIG.boot`)

Avatar swap `rina_icon1_default.png` → `rina_icon2_hover.png`; timings: hold 260 ms,
halo breath 1620 ms (peak ratio 0.5, tolerance 24 ms), halo contract 520 ms, image
release 2100 ms, blur fade 850 ms, extra 180 ms, min total display 400 ms. Keyframes in
styles.css: `rinaBoot-pulseRingBreath`, `rinaBoot-haloContractOut`,
`rinaBoot-avatarShrinkThenRelease` (names `Needs verification` against styles.css if
edited). Then the first-page card waterfall: each `.boot-reveal-item` gains
`.is-revealed` 115 ms apart + 260 ms settle. Scroll locked via
`html[data-scroll-lock="boot"]` until `unlockBootPageScroll()`.

### 10.3 Other WebUI animations

- Button press: pressed class 90 ms down / 150 ms up
  (`interaction.buttonPressDownMs/UpMs`, pointer-tracked WeakMap).
- Scroll preview: JS `setTimeout` chain (§11.6) — frame stepping, not CSS.
- Custom-select dropdown open/close transitions; face-list insert indicator; `.blur-screen`
  backdrop blur; LED cell glow = pure CSS (`.led.on` radial gradient + box-shadow).
- Matrix wraps carry `contain: layout paint` (perf); `.custom-preview-card` overrides
  with `contain: none` — keep them paired.

---

## 11. Scroll text system (end-to-end)

### 11.1 Input

`#scroll-text` textarea (HTML maxlength 1000 = `scroll.maxTextChars`), shipped default
text "RinaChanBoard 370 LED こんにちは 璃奈ちゃんボード" (captured as
`scrollDefaultText`, treated as "not user content" for restore-overwrite purposes).
`sanitizeScrollTextInput(commit)`: emoji presentation normalized to **text style**
(VS15 U+FE0E; VS16 stripped), emoji format controls stripped, visible-char limit
enforced. Editing sets `scroll.textEdited=true` and dispatches `TEXT_EDITED`. The
firmware byte limit (4096 UTF-8 bytes, `firmwareScrollMaxTextBytes`; updatable from a
`scrollLimits.maxTextBytes` status field the firmware does not currently emit) is
checked **before** generation (`scrollTextExceedsByteLimit` → alert).

### 11.2 Frame generation (browser)

1. `ensureArkPixelFontReady()` lazily fetches `ark12.json` (immutable-cached; **never**
   `no-store`) and parses it into `arkPixelFont.glyphs` (Map keyed by codepoint int).
2. `buildTextScrollBitmap(text)` (memoized by `text@@fontModel@@source@@centerY`):
   chars → glyphs via `buildTextGlyph` (per-codepoint cache; whitespace = 6-column
   advance `spaceColumns`, no ink; missing → U+25A1). Bitmap width =
   `max(COLS*2+8, 26 + contentWidth + 26)` (leading/trailing blank = COLS+4 = 26
   columns each). Glyphs blitted at `y = textScrollVerticalOffset() + dstY + yOffset`
   (vertical centering of the 12 px line in 18 rows), `charSpacing 0` added only
   between two non-space glyphs.
3. `prepareTextScrollTimeline(force)` (and the yielding/cancellable
   `prepareTextScrollTimelineForRestoreAsync` for restores): guards — cheap pre-check
   `codepoints − 21 ≤ firmwareScrollMaxFrames` (3072), then exact
   `projectedFrames = width − 22 + 1 ≤ 3072` (early abort M4 with warning). Extracts one
   frame per offset 0..width−22 via `extractFrameFromTextImage` (clipped by
   `row_valid_x_ranges`, mapped through `XY_TO_INDEX`), then
   `rotateScrollTimelineToFirstLitFrame()` rotates so frame 0 is the first with any lit
   LED. Stores `scroll.frames`, `scroll.signature` = JSON of
   `{text, model, source, verticalOffset}`. **1 frame = 1 LED of horizontal advance.**

### 11.3 Identity constants

`TEXT_SCROLL_FONT_MODEL = "ark_pixel_12px_fusion_bitmap_v4"` (sent as `fontId`);
`SCROLL_GENERATOR_VERSION = "webui-scrollgen-6.4.2"`. **Rule:** any change to char
spacing, blank margins, vertical offset, or frame extraction ⇒ bump generatorVersion;
any ark12.json change ⇒ bump fontModel. Both must fit the firmware cap (≤47 chars).
Timeline id: `scroll-<base36 time>-<4 base36 rand>` (`makeScrollTimelineId`).

### 11.4 Upload protocol (client side of §6.5 `/api/scroll`)

- Chunk sizes: first chunk `clamp(⌊12288/47⌋=261, 1, 24) = 24` frames
  (`SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES` 12 KB is a body budget that today resolves to
  the same 24 as `uploadChunkFrames`), subsequent chunks 24; 20 ms sleep between chunks.
- First chunk: `append=0`, query carries
  `timelineId, fontId, generatorVersion, totalFrames, fps, intervalMs, start=0,
  chunkIndex=0, source`. Later chunks: `append=1`, `chunkIndex++`, same timelineId.
  (sourceText intentionally **not** in the query — §7.5.)
- Progress bar checkpoints: 2% prep → 4–34% encode → 36–86% upload → 90% fps → 98%
  start → 100%.
- After the last chunk, if the firmware response didn't report `started`, POST
  `start_scroll {timelineId, fps, intervalMs, sourceText, source}` — sourceText travels
  here (JSON body, raw UTF-8).
- A `409` reply causes one full retry with a fresh timelineId
  (`uploadFirmwareScrollTimeline`). Note: the current firmware never actually returns
  409 on this route — the handling is defensive.
- Upload errors are translated (`describeScrollUploadError`): 413 text/chunk too large,
  507 memory, 503 busy, 409 conflict.
- Frames live **only in firmware RAM/PSRAM** (never flash); a device reboot loses both
  frames and sourceText.

### 11.5 Firmware playback

§4.4 + §4.10: interval 17–1000 ms (default 100), +1 frame per tick modulo frameCount,
drift-reset after gaps > 4 intervals. Pause = user OR system flag (system used by
overlays and terminate paths). Step: ±1 with forced user-pause + immediate frame.
Stop(clear): queued blank → 90 ms hold → deferred startup-default-face restore, auto
mode restored per `restoreAutoAfterScroll`.

### 11.6 WebUI preview & speed lock (PLL)

The preview steps the local `scroll.frames` with a self-rescheduling `setTimeout`
(`previewTickLoop`); each tick advances exactly one frame (`advanceScroll`), display
counter in `scroll.displayIndex`. Delay per tick = `effectivePreviewIntervalMs()` (the
measured device interval `previewIntervalMs` when firmware-backed, else 1000/fps user
setting) divided by a slew-limited speed multiplier.

`/api/preview_sync` samples feed `recordPresentedSyncSample`:

- Identity guards: a different `scrollTimelineId` than `framesTimelineId` →
  `IDENTITY_MISMATCH` (DROPPED); a frameCount mismatch with a bound identity → likewise.
- Phase error = shortest ring distance from the presented index to the local display
  index, low-passed (α 0.25).
- Paused or forced samples: hard snap (`snapPreviewToFirmwareFrame`) and exclude the
  next samples from rate estimation (`ignoreRateUntilSeq = seq+2`).
- Rate estimation: least-squares regression of unwrapped presented-frame vs device time
  over ≤`HW_RATE_WINDOW_MS` 8 s of rate-eligible samples; requires ≥3 samples, ≥2 s
  span, ≥3 frames; accepts 0.2–120 fps; EMA α 0.4 → `applyMeasuredPreviewFpsOnly`
  (blend α 0.18 into `previewIntervalMs`). Never touches the fps slider.
- Speed controller (`updatePreviewSpeedController`): deadband ±0.65 frames → ×1.0
  (state `locked`); gentle band ×0.97–1.03; |error| ≥ 4 frames → catch-up band
  ×0.9–1.1; target = `1 + err/horizonFrames` (horizon ≈ measuredFps × 1 s); applied
  multiplier slew-limited to 4%/s (`PREVIEW_SPEED_SLEW_PER_SEC`) in
  `nextPreviewDelayMs`. **The preview never skips, holds, or jumps frames** — only the
  timer speed changes. Sync states: `observe | gentle | catchup | locked`.
- Legacy estimator `recordFirmwareScrollSample` (driven from logical status cursors)
  still exists for status-poll paths.

Labels: `#scroll-state` (phase text), `#scroll-frame-index` (`display / count`),
`#scroll-actual-fps` (measured preview fps).

### 11.7 Reload / reconnect restore

Once per page load (`kickPostBootScrollMetaRestore`) and on demand
(`ensureLocalScrollFramesRestored`, resume/step with an empty cache):

1. GET `/api/scroll/meta`. If the firmware is not displaying scroll
   (`!active && !paused`) → clear recovered caches (`clearRecoveredScrollCache`) — a
   cached sourceText alone must never resurrect old text after Stop/Clear.
2. Unsent-local-edit guard (C5): if `scroll.textEdited` or the textarea differs from
   both the restored text and the shipped default → do not overwrite; warn
   ("硬件有滚动文字可恢复，但输入框已有未发送内容，未自动覆盖。").
3. Otherwise adopt text + fps + timelineId (`setScrollTextFromFirmware`,
   `applyFirmwareScrollFps`, `applyScrollRuntimeMeta`); warn when the restored text
   exceeds the UI char limit (truncated display, E4/E5) or when
   fontId/generatorVersion don't exactly match (`exactGeneratorMatch`) — preview may
   differ from the LED.
4. `restoreScrollPreviewIfNeeded`: if `localTimelineMatchesMeta` (uploadComplete ∧
   !truncated ∧ exact generator ∧ frameCount>0 ∧ timeline+count match) reuse the local
   frames; else rebuild frames browser-side with progress
   (`prepareTextScrollTimelineForRestoreAsync`, cancellable via restore token). Bind
   `framesTimelineId` only when identity fully matches; then re-fetch the latest meta
   (`fetchLatestScrollFrameMetaAfterPreview`) and snap to the firmware frame index
   (`applyRestoredScrollPreviewFrame` — index-first sync, PLL re-converges speed).
5. `syncScrollStateTextFpsLightweightAfterBoot` is the lightweight variant (text+fps
   only, `force:true` text fill, no frame rebuild) used post-boot before heavy reads.
6. Later identity mismatches (timeline changed under us) → DROPPED →
   `scheduleScrollDropRecovery` attempts one automatic re-restore.

### 11.8 Interactions with other features

Starting any face/frame output stops scroll (§8.3). Overlays system-pause it. Speed
changes during an unedited active session go through `set_scroll_interval` and retune
both firmware and preview. Auto mode entered while scrolling is deferred via
`restoreAutoAfterScroll`. GPIO B1/B2/B3 during scroll stop it firmware-side; the WebUI
detects this via status reasons / stop events and resets its scroll controls
(`resetScrollControlsAfterButton` + full sync after 20/140 ms).

---

## 12. Saved faces / presets

- Library = §6.2 file, loaded at WebUI boot via GET `/api/saved_faces` (deferred until
  after first paint). Split into `defaultFaces` (type default) and `userFaces`
  (`splitFaceLibraryDocument`).
- UI list (`renderSavedFaces`/`createFaceRow`): pointer-based drag-handle reorder with
  insert indicator + edge auto-scroll, inline rename, apply (click), edit-in-editor
  (`beginFaceEdit` with baseline + revert), delete.
- Rules: `type:"default"` faces are `deletable:false, locked:true` — deletion refused;
  the firmware additionally rejects any document with zero defaults. `order` is
  reassigned sequentially (1-based) from the current list order on every save
  (`faceOrderFromIndex` inside `buildUnifiedFaceDocument`).
- Persistence: any mutation → `persistFaceDocuments(reason)` → rebuild the unified
  document (`version:4`, fresh `updatedAt`, `startupDefaultId` preserved via
  `preferredStartupDefaultId`) → optional local-file write (File System Access handle,
  if one was opened) → POST `/api/saved_faces`. Success/failure is reported truthfully
  (`savedFacesSync` status); a firmware-POST failure with a local file still warns.
  Export/import: `downloadFacesJson()` / `importFacesJsonFile()` (re-normalizes via
  `normalizeFaceDocument`, then persists).
- Apply: `apply_saved_face {index, reason, playback}`; the firmware stops scroll (no
  clear), applies, and replies with full state; the UI also optimistically previews
  (`applySavedFace` → `syncSavedFacePreviewByIndex`).
- Startup face: `is_startup_default` flag or `startupDefaultId`
  (`face_08_triangle_eyes_frown` shipped). Fallbacks: first default → index 0.
  Invalid/missing file → firmware boots blank + serial warning; the UI shows an error
  row and keeps working from memory.
- Debug "清空用户表情" (`debug-clear-user-faces`, confirm word `CLEAR`) deletes user
  faces only.

---

## 13. Brightness, battery, and power logic

### 13.1 Brightness

Default `DEFAULT_BRIGHTNESS` 50, range `MIN/MAX_BRIGHTNESS` 10–200, hardware button
step ±8. Firmware clamps with `constrain`. Adafruit backend applies brightness in
`show()`; RMT pre-scales per component in `setPixel`. WebUI power estimate
(`estimateFrameWatts`, exact formula):

```
watts = litCount × 0.06 W × 5 channels × (brightness/255) × ((r+g+b)/765)
```

(`estimatedWattsPerChannel` 0.06, `channelCount` 5, `fullBrightness` 255). Warning
banner + `state.dpsActive` above `powerWarningWatts` 40 W — display-only; the firmware
never throttles.

### 13.2 ADC sampling and battery model (`src/power_monitor.cpp`)

- Non-blocking acquisition (O1): one `analogReadMilliVolts` per loop pass into a
  16-sample set (`POWER_ADC_SAMPLES`); when complete → sort, trim
  `POWER_ADC_TRIM_COUNT` 4 from each end, mean of the middle 8. Battery and charge
  acquisitions alternate (battery has priority); each due every
  `BATTERY/CHARGE_SAMPLE_MS` 1000 ms. Boot/manual force path uses the blocking variant
  (16 × (read + 250 µs)).
- Battery: `vbat = mV/1000 × BATTERY_CAL_SCALE 2.708333 + BATTERY_CAL_OFFSET_V 0.2033`;
  EMA with dt-based α = `1 − exp(−dt/20 s)` (`BATTERY_EMA_TAU_S`); EMA restarts after
  disconnect/low-voltage recovery. Percent from the 10-point LUT
  (8.40→100, 8.10→90, 7.90→80, 7.70→65, 7.50→50, 7.30→35, 7.10→20, 6.80→10, 6.50→5,
  6.20→0; linear interpolation) with ±1% hysteresis (only jumps >1% or first valid
  reading update the percent).
- Disconnect detection: raw ADC drop ≥`BATTERY_DISCONNECT_ADC_DROP_MV` 1000 landing at
  ≤`BATTERY_DISCONNECT_ADC_LOW_MV` 900 (and no charger) ⇒ `batteryDisconnected` (vbat
  forced 0.0, percent 0, batteryValid stays true); remains disconnected until raw
  ≥`BATTERY_RECONNECT_ADC_MV` 1500. Low-voltage unpowered: instant vbat <
  `BATTERY_UNPOWERED_LOW_V` 5.0 without charger ⇒ `batteryLowVoltageUnpowered` (vbat
  0.0/percent 0).
- Charger: `vcharge = mV/1000 × 6.684982 + 0.0712`; EMA α `CHARGE_EMA_ALPHA` 0.2
  (restarts on charger state change); `charging = vcharge > CHARGE_PRESENT_V 4.0`.
- Consistency (C1): all consumer-visible fields (`vbat, batteryPercent, batteryValid,
  batteryDisconnected, batteryLowVoltageUnpowered, vcharge, charging, chargeValid`) are
  committed inside `sPowerStatusMux`; `readPowerStatusSnapshot()` copies under the same
  lock (tear-free across cores).
- Web publish (`servicePowerWebPublish`): charging-state changes bump `stateVersion`
  immediately; slow fields (vbat ±`POWER_WEB_VBAT_EPS_V` 0.01 V, vcharge ±0.05 V,
  percent, validity) publish at most every `POWER_WEB_SLOW_PUBLISH_MS` 10 s.
- Calibration: §6.4. `resetBatteryVoltageMaximum` sets `v_max` to the current powered
  voltage when it exceeds `v_min + 0.10 V` (else nominal 8.0); `resetBatteryVoltageMinimum`
  sets `v_min` to the current voltage when powered, not charging, and below
  `v_max − 0.10 V` (else nominal 6.2); both save immediately.

### 13.3 UI presentation

Header badges: `#badge-runtime` (dot + 在线/离线), `#badge-battery`
(`batteryIconForPercent` color + `X.XX V NN%` / 未上电), `#badge-charging`
(充电中 X.XX V / 未充电 / dim when invalid). `applyPowerData` maps the payload into
`state.*` including thresholds and ADC diagnostics for the debug page; `update-adc`
inputs are a **browser-local simulation only** (never sent to hardware). Poll cadence:
§7.6.

---

## 14. Performance-sensitive areas

| Hotspot | Location | Current behavior / rule |
|---|---|---|
| Idle HTTP load ~14 req/s (80 ms preview-sync + status + power) | app.js pollers | **Intentional** (hardware-button feedback latency). Documented at `BUTTON_EVENT_SYNC_POLL_MS`; do not back off without product sign-off |
| renderState 12–15×/s | app.js | Memoized DOM writes (`domWriteIfChanged`); keep the memo when adding fields |
| LED cell paint (radial gradient + shadow × 396 × views) | styles.css | Dirty-diff rendering + `contain: layout paint` on `.matrix-wrap` (paired `contain:none` override on `.custom-preview-card`) |
| Static file streaming | web_api.cpp `sendFileChunked` | Static 4 KB buffer; one Storage-lock cycle per chunk (C2 invariant: flash reads must hold the Storage lock; each locked window is a single flash read) |
| WS2812 vs Wi-Fi timing | led_driver.cpp / web_api.cpp | IRAM encoder, `intr_priority=3`, DMA 2046 symbols, `WiFi.setSleep(false)` — all four are required together for glitch-free output |
| POST body copies | web_api.cpp | `RinaWebServer::plainBody()` zero-copy reference (O3); never revert to `server.arg("plain")` by value (a scroll chunk body is ~190 KB) |
| JSON doc sizing | web_api.cpp | status 3072 B (O5); command `3·len+512` capped at `MAX_TEXT+4096` (O4); saved_faces + scroll meta PSRAM-sized (B1–B3) |
| ADC in the loop | power_monitor.cpp | One conversion per pass (O1); the blocking path only at boot/force |
| Scroll upload chunking | app.js | 24-frame chunks + 20 ms gaps + status/power poll suppression during upload (P1-6) protect the single-threaded server |
| Font table (2.5 MB) | app.js `ensureArkPixelFontReady` | Lazy fetch, immutable-cached; **never** `cache:"no-store"` |
| Long-text frame generation | app.js `prepareTextScrollTimeline` | Early abort above 3072 projected frames (M4); restore variant yields every 6 frames and is cancellable (P2-7) |
| Log rendering | app.js `renderLog` | Debug-page-only, rAF-merged, 120-line view cap, 500-line buffer |
| Storage-lock hold times | storage.cpp | exists/open/IO consolidated into single lock holds (O6); atomic `.tmp`+rename writes |

Evaluated and **intentionally rejected** (do not implement without re-analysis): O7
(String→enum for mode/playback), O8 (async RMT double-buffering — would break the
synchronous presented-sample contract).

---

## 15. Error handling and recovery

| Failure | Behavior |
|---|---|
| API request fails/times out | UI: offline badge, rate-limited log (1 per 2.5 s), state kept; pollers keep retrying; queues drop-oldest with counters |
| Invalid frame payload | 400 + `framesRejected++` + slow version bump |
| Invalid/oversized command JSON | 400 (`commandsRejected++` for failed actions) |
| Scroll upload interrupted / superseded | Upload token invalidated ("上传已被新的发送取代"); machine → IDLE; progress reset; alert with status-specific hint; 409 retried once with a new timelineId |
| Firmware reboot mid-scroll | Preview goes STALE (3 failures / 5 s); device session lost; next meta restore sees `not displaying` → recovered caches cleared, UI returns to idle |
| Page reload during active scroll | Full automatic restore (§11.7): text + fps + frame index + preview |
| Local unsent text vs firmware text | Restore blocked with warning (unsent-edit guard C5) |
| `saved_faces.json` corrupt | Firmware: parse failure → 0 faces, blank boot, serial log; POST validation prevents writing corrupt documents; UI shows an error row |
| LittleFS unmounted | Red 12-LED pattern; file routes 503/404 |
| Scroll buffer alloc failed | `/api/scroll` 507; `/api/scroll/meta` 507 on staging-alloc failure |
| Out-of-range values | Silently constrained: brightness 10–200, fps 1–60, scroll interval 17–1000 ms, auto interval 500–10000 ms |
| Empty scroll text | Alert "空文本不进入文字滚动播放"; nothing sent |
| Missing glyphs / emoji | U+25A1 box substitute; emoji normalized to text presentation |
| Button/command during busy | WebUI busy flags no-op the click; hardware buttons always act (firmware authoritative) and the UI re-syncs via polls |
| Overlay during scroll | System pause; auto-resume when the overlay ends |
| Short read while streaming a file | Loop breaks; client sees a truncated body and retries |
| bootstrap exception | UI revealed anyway; pollers started; error logged to `#log` |

---

## 16. Compatibility checklist (must remain unchanged)

- **Endpoints & fields**: every route/param/response key in §6.5, including the
  `v`/`version` duality, `frameEncoding:"packed-lsb-first"`, and the `uiFps` +
  `scrollFps` duplication.
- **Formats**: 47-byte LSB-first packed frame; base64 body transport;
  `rina_packed_faces_370_v2` schema + validation rules (document `version: 4`);
  `rina_runtime_settings_v1`; `rina_battery_calibration_v1`;
  `rina_ark_pixel_font_bitmap_v1`; serial console command syntax and `STATUS` line
  format; `RLOG` line format `[<ms> ms] [<LEVEL>] [<CATEGORY>] key=value …`.
- **Identity strings**: `fontId ark_pixel_12px_fusion_bitmap_v4`, `generatorVersion
  webui-scrollgen-6.4.2` (bump rules §11.3), timelineId shape, reason prefixes
  `custom_`/`parts_`/`debug_`/`firmware_text_scroll_*`/`gpio_*`,
  `startup_sequence_complete_saved_face`, playback vocabulary (§8.1).
- **Hardware**: all pins (§5.1); serpentine map; GRB order; brightness 10–200 default
  50; ADC calibration scale/offset constants.
- **Timings**: debounce 25 ms; repeats 650/350 and 450/120 ms; B6 long-press 700 ms;
  overlays 1000/2000 ms; edge flash 305/45/260 ms; frame min interval 33 ms; queue
  depth 3; render gap 2500 µs; reset 300 µs; scroll 17–1000 default 100 ms; auto
  500–10000 default 3000 step 500 ms; ADC 16 samples/trim 4/1000 ms; slow publish 10 s;
  calib save 15 s; boot holds 20/350/120 ms + stop-clear blank 90 ms; HTTP waits
  200 ms; WebUI polls 500/1000, 250/80 (intentional), 900/1000 ms; queues 20 ms/6 and
  120 ms/4; timeouts 2500/5000/15000 ms; chunks 24 + 12 KB first-chunk budget; PLL
  constants (§11.6); boot animation timings (§10.2).
- **Defaults**: firmware color `#f971d4` (WebUI picker default `#ec3fc7` — distinct on
  purpose); mode manual; playback idle; AP `RinaChanBoard-V2`/`rinachan`/`rina.io`/
  192.168.1.14; startup face `face_08_triangle_eyes_frown`; scroll fps 10; auto
  interval 3000 ms; brightness 50.
- **DOM ids**: every id referenced in §7/§9.2 (app.js and styles.css depend on them).
- **No localStorage** — do not introduce browser persistence the firmware can't see.
- **Behavioral invariants**: synchronous LED latch (presented-sample contract);
  Storage→HardwareBus lock pairing; `renderCurrentFrameToLedStrip` single-caller rule;
  preview never skips frames (speed-only sync); firmware never adjusts the user's fps
  setting; overlay-covered latches never feed fps estimation; B3 fires on release;
  default faces undeletable and ≥1 required; scroll frames RAM-only; unsent-local-text
  restore guard; `WiFi.setSleep(false)`.

---

## 17. Reconstruction guide

Build order for a from-scratch reimplementation:

1. **Constants first**: transcribe `src/config.h` (§5, §13, §16) and `WEBUI_CONFIG` +
   the PLL constants block (§7, §11.6) verbatim — nearly every behavior hangs off them.
2. **Firmware core**: `RuntimeStore`/state (§4.7–4.8) → sync locks (§4.7) →
   `led_driver` (Adafruit backend first for correctness, then RMT/DMA) →
   `led_renderer` (packed frames, validation, queue, presented telemetry) → serpentine
   map (§5.2; verify with a checkerboard).
3. **Faces & storage**: LittleFS mount, atomic JSON writes, saved-faces
   validate/load/sort, modes, auto playback, deferred restore (§4.10).
4. **Scroll engine**: scroll buffers → `scroll_session` (upload txn, tick cursor,
   pause/step/stop semantics) → Core-1 task (§4.4).
5. **Buttons & overlays**: §9.1 semantics table → `button_animations` glyph tables +
   timing (§10.1).
6. **Power monitor** (§13.2) → serial log + console (§3.6).
7. **web_api**: every route in §6.5 exactly (CORS/OPTIONS, base64 bodies, gzip static
   serving, cache headers, zero-copy body, chunked locked streaming), AP/DNS bring-up
   with `WIFI_PS_NONE`.
8. **Build scripts**: platformio.ini envs, WebServer.h timeout patch, gzip hook,
   partitions.csv.
9. **WebUI**: WEBUI_CONFIG/EXPRESSION_PARTS data blocks → API client + rate-limited
   queues → matrix rendering + fit → `renderState` → basic-page controls → saved-face
   library → parts composer → scroll system (generator → upload → PLL preview →
   restore) → `scrollMachine` (§8.2 exactly) → debug page → boot loader sequence
   (§7.2, §10.2).
10. **Fonts**: reuse `ark12.json`/`ark12.woff2`/`unifont.woff2` from
    `data/resources/fonts/` (regeneration needs the `tools/` pipeline + upstream Ark
    Pixel BDFs, Mona12 emoji font, and a GNU Unifont PNG sheet — see §3.5).

Required data structures: `RuntimeState`/`RuntimeFace`/`ScrollTimelineMeta`/
`LedPresentationContext`/`LedPresentedSample`/`PowerStatus` (firmware); `state`,
`scroll`, `firmware`, `scrollMachine`, frame bool-arrays, face library arrays (WebUI).
Required tests: §18. Recommended validation order: serial `status` → checkerboard via
serial `frame hex` → API smoke (status/frame/command) → WebUI boot offline + online →
saved-faces CRUD → scroll end-to-end → reload restore → hardware buttons → battery
overlay → performance passes.

---

## 18. Test plan

Manual (device + browser) unless stated. Each row: Steps → Expected (regression it
guards).

| # | Test | Steps | Expected |
|---|---|---|---|
| T1 | Boot | Flash fw+fs, power on | Clean boot (no random lit pixels), startup face `face_08…` in `#f971d4` @ brightness 50, serial `stage=ready faces=11 mode=manual`, AP `RinaChanBoard-V2` visible, `rina.io` resolves |
| T2 | FS-missing fallback | Erase FS, boot | 12 red LEDs; `/api/saved_faces` 404/503; `/` 404 |
| T3 | Status contract | `curl /api/status` | All §6.5 fields incl. stats/renderer/scroll; `v` increments only on changes; brightness spam bumps `v` at most every 10 s |
| T4 | Frame POST | base64 47 B frame, `?reason=debug_x` | LED shows the frame; mode flips to manual; `lit` correct; non-zero tail bits → 400 + framesRejected++ |
| T5 | Command set | Every §6.5b cmd + error cases | Documented replies; unknown cmd 400; `button:"B6"` 400 |
| T6 | Saved faces CRUD | GET, edit, POST back; reorder/rename/delete in UI | Firmware hot-reloads; defaults undeletable; >128 faces rejected; zero-defaults rejected; `order` reassigned 1-based |
| T7 | Auto mode | B3 to auto; wait; B3B1/B3B2 | Rotation every 3.0 s; interval steps ±0.5 s with clock overlay + edge flash at limits; persisted across reboot |
| T8 | Buttons B1–B5 | Press + hold each | On-press firing; repeats 650/350 (faces) and 450/120 (brightness); B3 fires on release; combos consume B3; overlays show |
| T9 | B6 overlay | Short press; long press; long press while charging | 2 s single-shot; continuous 2-phase (3-phase charging) rotation every 2 s with animated fill; running scroll system-pauses and resumes |
| T10 | Scroll E2E | 1000-char CJK/emoji text, Send | Byte-limit precheck; chunked upload (24-frame chunks, progress bar); ≤3072 frames enforced; firmware playback at set fps; preview phase-locks (index labels track; no frame jumps); fps change live; step pauses + steps both directions; pause/resume snaps alignment; Stop clears + blank 90 ms + default face + auto-restore rule |
| T11 | Reload restore | Reload mid-scroll (playing and paused) | Text + fps + position restored automatically; local-unsent-edit guard blocks overwrite; generator-mismatch and truncation warnings appear when applicable |
| T12 | Reboot mid-scroll | Power-cycle the device with the UI open | UI → STALE within ~5 s → idle after sync; no zombie text restored (`not_displaying_scroll` clears caches) |
| T13 | Power | Drain/charge/disconnect the pack | LUT percentages; EMA smoothing; disconnect → 0.0 V + flags; charging badge updates within one version bump; `reset_battery_min/max` persist to battery_calib.json |
| T14 | Perf: LED vs HTTP | Hard-reload the UI ×5 during scroll | No visible LED glitch; `ledRefreshMaxUs` sane; assets served gzip with immutable caching (second load fetches ~only index.html + APIs) |
| T15 | Perf: idle UI | 5 min idle on basic page with DevTools | ~12.5 req/s preview_sync; no DOM churn (memoized); no unbounded memory growth |
| T16 | Offline HTML | Open `index.html` via `file://` | No fetch storms; editor + local JSON import/export work |
| T17 | Serial console | Every §3.6 command | Documented outputs; `frame hex` renders; `btn B6` → `ERR btn invalid` |
| T18 | Automated (recommended; none exist today) | — | Unit tests for: packed frame pack/unpack + tail mask; serpentine map vs table; interval/fps normalization; `scrollMachine` transition table (§8.2); text-bitmap width/frame-count math; battery LUT interpolation; `validateSavedFaces` rules |

### Known gaps / open items (confirmed against code 2026-07-02)

- `index.html` trailing unclosed comment + NUL bytes; referenced test instrumentation
  (`window.__ui`, `data-testid`) does not exist (§2.1).
- `?v=dev` hash-rewrite comment in `WEBUI_CONFIG.textScroll` is stale — no rewrite step
  exists in `gzip_webui_assets.py` (§2.1).
- `serial_log.h` documents `log …`/`led command_history` console commands that
  `serial_console.cpp` does not implement; the log-level setters and LED history ring
  are currently unreachable at runtime (§2.1).
- `MATRIX_VIEW_CONFIGS` registers a nonexistent `matrix-parts` element (silent no-op).
- `liveFramePump` exists but is permanently disabled (`isLiveFrameReason` → false); the
  live path did not reliably refresh the strip.
- Firmware never emits `scrollLimits`, `scrollMaxFrames`, `next_poll_ms`, `unchanged`;
  the WebUI reads them defensively (forward-compat hooks).
- WebUI sends unused `/api/scroll` metadata (`chunkIndex`, `source`) and defines
  payload fields that never reach the wire (`stepLedPerFrame`, `storage`, `persist`,
  `saveToFlash`); the firmware's `sourceText` query-arg path on `/api/scroll` is dead
  from the WebUI's perspective (text goes via `start_scroll`).
- The WebUI's 409-retry on scroll upload is defensive — the current firmware never
  returns 409 on that route.
- `Needs verification`: exact boot-keyframe names in styles.css if that file is edited
  (not re-checked line-by-line in this revision).
