# RinaChanBoard ESP32-S3 Firmware

> ESP32-S3 firmware and offline WebUI for a custom 370-LED WS2812 RinaChanBoard matrix.

RinaChanBoard drives a 370-LED WS2812/NeoPixel display from an ESP32-S3. The board starts its own Wi-Fi access point, serves a complete WebUI from LittleFS, stores face data locally, and exposes REST endpoints for frames, saved faces, color, brightness, auto playback, text scrolling, power status, and diagnostics.

The project is built for fully local use. No router, cloud service, or external server is required after flashing. Connect to the board's access point, open the WebUI, and control the LED matrix from a phone, tablet, computer, or any HTTP client.

## Table of Contents

- [Features](#features)
- [Hardware](#hardware)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Functional Reference](#functional-reference)
- [WebUI Pages](#webui-pages)
- [HTTP API](#http-api)
- [Storage Files](#storage-files)
- [Configuration](#configuration)
- [Project Structure](#project-structure)
- [Build And Asset Pipeline](#build-and-asset-pipeline)
- [Testing](#testing)
- [Contributing](#contributing)
- [Acknowledgments](#acknowledgments)
- [License](#license)

## Features

- ESP32-S3 Wi-Fi access point mode
- Local DNS for `http://rina.io/`
- Offline WebUI served from LittleFS
- Static asset gzip negotiation for faster WebUI loads
- 370-LED WS2812/NeoPixel rendering on `GPIO2`
- Logical M370 frame format mapped to physical serpentine wiring
- Manual and automatic saved-face playback
- Editable default faces, custom faces, and parts-composed faces
- Firmware-side text scrolling from cached frame sequences
- Dedicated FreeRTOS LED scroll/render task pinned to Core 1
- PSRAM-backed scroll frame storage where available
- JSON-heavy workflows designed around ESP32-S3 memory limits
- Hardware button control for faces, mode, brightness, and auto interval
- Battery and charge-voltage monitoring with calibration persistence
- Runtime status, diagnostics, memory, filesystem, and power reporting
- Build-time GNU Unifont WebUI subsetting
- Ark Pixel bitmap font support for LED text-scroll rasterization

## Hardware

Default hardware assumptions:

- ESP32-S3-DevKitC-1 or compatible ESP32-S3 board
- QSPI PSRAM by default
- 370 WS2812/NeoPixel LEDs
- LED data pin: `GPIO2`
- Battery ADC pin: `GPIO10`
- Charge ADC pin: `GPIO1`

Hardware button pins:

| Button | GPIO | Action |
| --- | ---: | --- |
| `B1` | 17 | Next saved face; interrupts firmware scroll |
| `B2` | 16 | Previous saved face; interrupts firmware scroll |
| `B3` | 15 | Toggle manual/auto mode; interrupts firmware scroll |
| `B4` | 40 | Brightness down |
| `B5` | 41 | Brightness up |
| `B6` | 42 | Reserved; initialized but no mapped action currently |
| `B3 + B1` | 15 + 17 | Decrease auto interval |
| `B3 + B2` | 15 + 16 | Increase auto interval |

The LED chain uses serpentine physical wiring. Logical row 0 is forward, logical row 1 is reversed, and so on. M370 bits remain in logical row-major order from `0` to `369`; firmware maps those bits to physical LED indices before writing to the strip.

## Prerequisites

- [PlatformIO Core](https://platformio.org/install) or the PlatformIO VS Code extension
- Python 3.9+
- PowerShell 5+ on Windows
- Python packages for the asset pipeline:

```bash
pip install pillow fonttools brotli
```

PlatformIO libraries are declared in `platformio.ini`:

- `bblanchon/ArduinoJson`
- `adafruit/Adafruit NeoPixel`

## Installation

1. Clone the repository:

```bash
git clone https://github.com/yourusername/Rina-Chan-board-370-leds.git
cd Rina-Chan-board-370-leds/esp32s3_firmware
```

2. Install Python asset-build dependencies:

```bash
pip install pillow fonttools brotli
```

3. Build firmware, prepare WebUI/font assets, upload firmware, and upload LittleFS:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1 -UploadFirmware -UploadFS
```

The PowerShell script prepares offline WebUI assets, regenerates the embedded GNU Unifont subset, verifies Ark Pixel resources, runs PlatformIO, uploads firmware, and uploads the LittleFS image when upload flags are provided.

## Usage

### Build Only

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1
```

### Manual PlatformIO Commands

```bash
pio run
pio run -t upload
pio run -t uploadfs
```

### Connect To The Board

After flashing, connect your device to the board's access point:

| Field | Value |
| --- | --- |
| SSID | `RinaChanBoard-V2` |
| Password | `rinachan` |
| Local DNS URL | `http://rina.io/` |
| IP URL | `http://192.168.1.14/` |

The `rina.io` hostname is resolved by the board's local DNS server and only works while connected to the board's access point.

### Refresh Browser Assets

After uploading a new LittleFS image, force the browser to reload cached assets:

```text
http://rina.io/?v=latest
```

### Default Runtime Behavior

- Startup brightness: `50/255`
- Brightness clamp: raw `10..200`
- WebUI percentage: `raw / 255`, so maximum brightness appears as about `78%`
- Default color: `#f971d4`
- Default mode: `manual`
- Startup face: loaded from `data/resources/saved_faces.json`

If LittleFS is not uploaded or fails to mount, the access point still starts and the root route returns a diagnostic page instead of silently failing. The LEDs also show a short red filesystem-error pattern.

## Functional Reference

### Access Point And Web Server

The firmware starts in AP-only mode:

- AP SSID: `RinaChanBoard-V2`
- AP password: `rinachan`
- IP address: `192.168.1.14`
- Local hostname: `rina.io`
- HTTP port: `80`
- DNS port: `53`

The web server provides:

- Static WebUI files from LittleFS
- Gzip-compressed static assets when the browser sends `Accept-Encoding: gzip`
- CORS headers for API responses
- JSON error replies for missing files, invalid input, and unsupported methods
- A diagnostic page when LittleFS is unavailable

### LED Matrix Rendering

The display format is M370:

- Prefix: `M370:`
- Payload: `93` hexadecimal characters
- Logical bits: `370`
- Storage bytes: `(370 + 7) / 8`
- Bit order: logical row-major
- Physical output: mapped to serpentine WS2812 wiring before `strip.show()`

Renderer behavior:

- Global color and brightness are applied to all lit bits
- Frame writes are rate-limited with a minimum interval
- A small queued-frame buffer smooths rapid WebUI M370 sends
- `strip.show()` is protected by a hardware-bus mutex
- Extra reset/gap timing is inserted for BSS138 level-shifter reliability
- The render task copies frame/color/brightness state under lock, then releases the lock before the physical LED update

### Color And Brightness

Color accepts standard hex input such as:

```text
#f971d4
```

Brightness is stored as raw NeoPixel brightness:

- Minimum: `10`
- Default: `50`
- Maximum: `200`
- Button step: `8`

### Saved Faces

Saved faces live in `data/resources/saved_faces.json`.

Supported face types:

- `default` - shipped faces; locked from deletion but editable/reorderable in the UI
- `custom` - user-created M370 drawings from the custom editor
- `parts` - faces produced by the expression-part composer

Saved face records include IDs, names, type, M370 data, order, and metadata such as `locked`, `editable`, `deletable`, and `is_startup_default`.

Auto/manual behavior:

- Manual mode holds the selected face/frame
- Auto mode cycles through saved faces at `autoIntervalMs`
- Interval range: `500..10000 ms`
- Default interval: `3000 ms`
- Button combo step: `500 ms`

### Text Scroll

The WebUI renders text into a horizontal M370 frame sequence and uploads it to firmware RAM.

Firmware scroll behavior:

- Scroll frames are cached in RAM/PSRAM
- Maximum cached frames: `3072`
- Timing may be supplied as `intervalMs` or `fps`
- Minimum interval: `33 ms`
- Maximum interval: `1000 ms`
- Default interval: `100 ms`
- Scroll rendering runs from a FreeRTOS task pinned to Core 1
- Playback uses elapsed-time compensation, so it catches up after short scheduling delays
- Long uploads can be chunked with `append`, `chunkIndex`, `totalFrames`, and `start`
- Scroll uploads are RAM-only; flash persistence for scroll sequences is rejected by the firmware

Scroll control supports:

- Start cached scroll playback
- Pause scroll
- Resume scroll
- Stop scroll
- Stop and clear display
- Single-frame step
- Restore auto mode after scroll when appropriate

### Hardware Buttons

Buttons are debounced and serviced in the main loop.

Runtime button behavior:

- `B1` and `B2` repeat after a hold delay for face navigation
- `B4` and `B5` repeat faster for brightness changes
- `B3` fires on release so it can be used as a combo modifier
- `B3 + B1` and `B3 + B2` are combo actions
- `B1`, `B2`, and `B3` notify the WebUI when they interrupt firmware scroll

The API can simulate button actions with `/api/command` and `cmd: "button"`.

### Power Monitoring

The firmware samples battery and charge inputs:

- Battery ADC pin: `GPIO10`
- Charge ADC pin: `GPIO1`
- Trimmed ADC samples: `16`
- Trim count: `4`
- Sample interval: `1000 ms`
- Battery disconnect/reconnect detection
- Charge-present detection
- Battery percentage lookup table for a 2S LiPo-style discharge curve
- Calibration min/max persistence in LittleFS
- Reset commands for learned battery minimum and maximum voltage

Power status is reported through `/api/status` and `/api/power`.

### Runtime State And Synchronization

Runtime state tracks:

- Color and RGB channels
- Brightness
- Manual/auto mode
- Playback state
- Current M370 frame
- Auto face list and index
- Scroll activity, pause state, interval, frame count, and frame index
- Deferred face restore after clear-frame operations
- Power status publication state
- Runtime version counters and statistics

Synchronization primitives protect:

- Frame data
- Scroll state
- Hardware bus access

### Diagnostics And Statistics

The status API reports:

- AP SSID, IP, domain, and client count
- Renderer state
- Current auto face metadata
- Scroll state
- Optional current M370 frame
- Matrix geometry
- API endpoint paths
- LittleFS mount and capacity state
- ESP heap and PSRAM state
- Scroll buffer size and PSRAM usage
- Frame, command, settings, and saved-face counters
- Power and battery calibration status

## WebUI Pages

The offline WebUI is implemented in `data/index.html` and `data/styles.css`.

### 6.1 Basic

Basic controls:

- Color picker and color preset dropdowns
- Brightness slider, number input, plus/minus buttons, and default reset
- Saved-face navigation
- Manual/auto mode toggle
- Auto interval controls
- Read-only 370-LED preview
- Battery, charge, and firmware status badges

### 6.2 Custom Face

Custom editor:

- Editable LED matrix paint board
- Clear, fill, and invert tools
- M370 textarea import/export
- Copy current M370
- Save into unified `saved_faces.json`
- Rename, reorder, apply, and delete saved entries where allowed

### 6.3 Expression Parts

Parts composer:

- Choose face parts from grouped expression libraries
- Generate combined M370 output
- Randomize part selection
- Reset to defaults
- Import/export M370
- Save parts-generated faces into the unified face library

### 6.4 Text Scroll

Text-scroll tools:

- Text input for LED scrolling
- Ark Pixel 12 px preview path
- Firmware-frame generation
- FPS/interval control
- Upload cached frame sequence to firmware
- Start, pause/resume, stop/clear, and single-step controls
- Browser preview synchronized with firmware state

### 6.5 Debug

Debug tools:

- Read firmware status
- Send pause/resume commands
- Simulate GPIO button actions
- Apply all-off, all-on, checker, border, and current-face test patterns
- Parse and apply manual M370
- Copy status JSON
- Refresh power state
- Reset battery minimum and maximum calibration
- View ADC/network/system state
- Send auxiliary commands
- Clear or download communication logs

## HTTP API

All endpoints are served from `http://192.168.1.14/` and `http://rina.io/`.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| `GET` | `/` | Serve the WebUI root page |
| `GET` | `/index.html` | Serve the WebUI page |
| `GET` | `/api/status` | Read runtime, matrix, storage, memory, power, and statistics state |
| `GET` | `/api/power` | Read battery and charge state |
| `POST` | `/api/frame` | Apply one M370 frame |
| `POST` | `/api/scroll` | Upload cached scroll frames and optionally start playback |
| `POST` | `/api/command` | Run a control command |
| `GET` | `/api/saved_faces` | Read the saved-face library |
| `POST` | `/api/saved_faces` | Validate and replace the saved-face library |
| `OPTIONS` | API endpoints | CORS preflight support |

### `GET /api/status`

Query options:

- `runtimeOnly=1` - return lightweight runtime state
- `summary=1` - skip heavy frame/storage serialization
- `noFrame=1` - skip `lastM370`
- `since=<version>` - return `unchanged: true` if runtime version has not changed
- `fullPower=1` - include slower-changing power details

Important response sections:

- `ap`
- `power`
- `renderer`
- `renderer.scrollStopEvent`
- `memory`
- `matrix`
- `endpoints`
- `storage`
- `stats`

### `POST /api/frame`

Applies a single frame. Color and brightness are not changed here; use `/api/command`.

Example:

```json
{
  "m370": "M370:<93 hex>",
  "reason": "api_frame",
  "playback": "idle",
  "faceId": "face_08_triangle_eyes_frown"
}
```

Behavior:

- Stops firmware scroll unless the frame is scroll-related
- Applies the M370 frame
- Updates playback metadata
- Updates saved-face index when `faceId` matches a loaded face
- Returns accepted/queued state, queue depth, current color, brightness, lit LED count, and current M370

### `POST /api/scroll`

Uploads a sequence of M370 frames to the firmware scroll cache.

Example:

```json
{
  "frames": [
    "M370:<93 hex>",
    "M370:<93 hex>"
  ],
  "fps": 20,
  "append": false,
  "start": true,
  "chunkIndex": 0,
  "totalFrames": 2,
  "source": "webui_text_scroll"
}
```

Supported fields:

- `frames` - array of M370 strings
- `intervalMs` - frame interval in milliseconds
- `fps` - alternative timing input
- `append` - append to existing RAM scroll cache
- `start` - start playback after upload
- `chunkIndex` - upload chunk index
- `totalFrames` - total intended frames
- `source` - metadata string

Rejected fields/behavior:

- `persist: true`
- `saveToFlash: true`
- `storage` other than `ram`

### `POST /api/command`

General command shape:

```json
{
  "cmd": "set_brightness",
  "payload": {
    "raw": 80
  }
}
```

Supported commands:

| Command | Payload |
| --- | --- |
| `set_color` | `{ "hex": "#f971d4" }` |
| `set_brightness` | `{ "raw": 50 }` or `{ "brightness": 50 }` |
| `set_mode` | `{ "mode": "manual" }` or `{ "mode": "auto" }` |
| `set_auto_interval` | `{ "ms": 3000 }` |
| `set_scroll_interval` | `{ "intervalMs": 100 }` or `{ "fps": 10 }` |
| `start_scroll` | Optional `{ "intervalMs": 100 }` or `{ "fps": 10 }`; requires cached frames |
| `scroll_step` | No payload required |
| `pause_scroll` | No payload required |
| `resume_scroll` | No payload required |
| `stop_scroll` | `{ "clear": true, "restoreAuto": true }` |
| `pause` | Pauses scroll if active; otherwise marks runtime playback paused |
| `resume` | Resumes paused scroll if available; otherwise clears runtime pause |
| `button` | `{ "button": "B1" }` |
| `terminate_other_activities` | `{ "targetMode": "face" }`, `{ "targetMode": "scroll" }`, or another mode |
| `reset_battery_min` | No payload required |
| `reset_battery_max` | No payload required |

### `GET /api/saved_faces`

Streams the current `data/resources/saved_faces.json` file from LittleFS.

### `POST /api/saved_faces`

Validates and replaces the saved-face JSON.

Accepted body forms:

```json
{
  "document": {
    "format": "rina_faces_370_v2",
    "version": 2,
    "faces": []
  },
  "reason": "webui_save"
}
```

or the saved-face document directly.

The firmware validates:

- `format`
- matrix metadata
- face array shape
- M370 strings
- default/custom/parts type constraints
- startup/default face metadata

## Storage Files

LittleFS files:

| Path | Purpose |
| --- | --- |
| `/index.html` | WebUI HTML and JavaScript |
| `/styles.css` | WebUI stylesheet |
| `/resources/saved_faces.json` | Unified saved-face library |
| `/resources/runtime_settings.json` | Manual/auto mode and auto interval persistence |
| `/resources/battery_calib.json` | Learned battery min/max calibration |
| `/resources/loading/rina_icon1_default.png` | Loading screen default icon |
| `/resources/loading/rina_icon2_hover.png` | Loading screen hover/finish icon |
| `/resources/fonts/ark12.woff2` | Browser font for text-scroll textarea |
| `/resources/fonts/ark12.json` | Bitmap glyph table for LED text-scroll rasterization |

Generated/managed assets:

- GNU Unifont subset is embedded directly into `data/index.html`
- Ark Pixel files are stored in `data/resources/fonts/`
- Gzipped copies are generated by the build script for LittleFS upload

## Configuration

Most firmware constants live in `src/config.h`. Build and board settings live in `platformio.ini`.

Default PSRAM configuration:

```ini
board_build.psram_type = qspi
board_build.arduino.memory_type = qio_qspi
```

For ESP32-S3 modules with OPI PSRAM:

```ini
board_build.psram_type = opi
board_build.arduino.memory_type = qio_opi
```

Important constants:

| Constant | Default |
| --- | --- |
| `AP_SSID` | `RinaChanBoard-V2` |
| `AP_PASSWORD` | `rinachan` |
| `AP_DOMAIN` | `rina.io` |
| `LED_PIN` | `2` |
| `LED_COUNT` | `370` |
| `DEFAULT_BRIGHTNESS` | `50` |
| `MIN_BRIGHTNESS` | `10` |
| `MAX_BRIGHTNESS` | `200` |
| `DEFAULT_COLOR` | `#f971d4` |
| `DEFAULT_AUTO_INTERVAL_MS` | `3000` |
| `MAX_AUTO_FACES` | `128` |
| `MAX_SCROLL_FRAMES` | `3072` |
| `DEFAULT_SCROLL_INTERVAL_MS` | `100` |
| `LED_RENDER_TASK_CORE` | `1` |

## Project Structure

```text
esp32s3_firmware/
|-- data/              # LittleFS WebUI and runtime resources
|-- licenses/          # Third-party license notices
|-- scripts/           # PlatformIO pre/post build helpers
|-- src/               # Firmware source modules
|-- tools/             # Font and asset generation tools
|-- platformio.ini     # PlatformIO environment
|-- partitions.csv     # ESP32 flash partitions
`-- run_rinachan_unifont.ps1
```

Important firmware modules:

- `src/main.cpp` - setup and service loop
- `src/config.*` - pins, constants, matrix geometry, timing, defaults
- `src/web_api.*` - access point, static file serving, REST API
- `src/led_renderer.*` - M370 parsing, LED mapping, color, brightness, NeoPixel output
- `src/scroll.*` - Core 1 firmware scroll/render task
- `src/faces.*` - saved-face playback, auto/manual mode, scroll restore behavior
- `src/buttons.*` - hardware button debounce, repeat, combos, and actions
- `src/power_monitor.*` - battery/charge ADC sampling and calibration
- `src/storage.*` - LittleFS, runtime settings, saved-face persistence
- `src/state.*` - runtime state, face arrays, frame buffers, scroll buffers
- `src/sync.*` - FreeRTOS mutex helpers
- `src/utils.*` - hex/color/JSON sizing utilities
- `src/web_json.*` - lightweight JSON field extraction for large scroll uploads
- `src/psram_json.h` - PSRAM allocator for ArduinoJson documents

## Build And Asset Pipeline

### `run_rinachan_unifont.ps1`

Root build helper that:

- Checks Python dependencies
- Rebuilds the WebUI GNU Unifont subset from characters used by the current WebUI/resources
- Downloads or reuses source font assets in `.font_cache`
- Builds or verifies Ark Pixel resources
- Runs PlatformIO build/upload commands
- Can upload firmware and/or LittleFS

### `scripts/patch_webserver_timeout.py`

Pre-build PlatformIO script that patches Arduino WebServer timeout values to reduce blocking behavior on the ESP32 web server.

### `scripts/gzip_webui_assets.py`

Build script that prepares compressed WebUI assets for faster delivery from LittleFS.

### `tools/build_unifont_webui_subset_from_png.py`

Builds a GNU Unifont WOFF2 subset for the exact characters used by the WebUI and runtime resources, then embeds it into `data/index.html`.

### `tools/build_ark12_merged.py`

Builds the merged Ark Pixel 12 px resources used by text scrolling.

### `tools/compile_ark_bdf.py`

Compiles Ark Pixel BDF data into the browser/font and bitmap-table resources consumed by the project.

## Testing

There is no separate automated test suite in this firmware folder yet. Current verification is build-based:

```bash
pio run
```

Recommended manual checks after flashing:

- WebUI loads at `http://rina.io/`
- `/api/status` returns JSON
- `/api/power` returns battery/charge JSON
- A saved face renders after boot
- Color and brightness controls update LEDs
- M370 import/export round-trips correctly
- Custom and parts faces save into `saved_faces.json`
- Auto mode cycles through saved faces
- Text-scroll uploads, starts, pauses, resumes, steps, and stops
- Hardware buttons perform the mapped actions
- LittleFS diagnostic appears if filesystem upload is missing

## Contributing

Pull requests are welcome. For larger changes, open an issue or discussion first so implementation details can be agreed on before code is written.

When changing WebUI text, `data/index.html`, `data/styles.css`, or runtime JSON resources, rerun:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_rinachan_unifont.ps1
```

This keeps the embedded GNU Unifont subset in sync with the characters used by the WebUI.

## Acknowledgments

This project builds on:

- ESP32 Arduino core
- PlatformIO
- ArduinoJson
- Adafruit NeoPixel
- GNU Unifont
- Ark Pixel Font

## License

No top-level project license file is currently included in this firmware folder. Until a project license is added, treat the project source as not licensed for redistribution by default.

Third-party font and library components retain their own licenses. The GNU Unifont subset notice is available at `licenses/GNU_UNIFONT_WEBUI_SUBSET_NOTICE.txt`.
