# Codebase Architecture and Data Flow Report

> Project: **RinaChanBoard 370 V2** — ESP32-S3 firmware driving a 370-pixel WS2812 LED face matrix, with a captive-portal WebUI for control, editing, and diagnostics.
> Method: every file under `src/` and `data/` was read in full; build config, scripts, resources and the existing `AUDIT_REPORT.md` were read; claims below cite concrete files, functions, and line-level behavior. Build artifacts under `.pio/` and font-tooling under `tools/`, `archive/`, `scripts/` were inspected for runtime relevance only.

---

## 1. Executive Summary

This is a **two-process system joined by a single-threaded HTTP/JSON API over a SoftAP**:

1. **Firmware** (C++/Arduino, `src/*.cpp`) on an ESP32-S3. It owns the LED hardware, buttons, battery ADC, persistent storage (LittleFS), and a `WebServer` on port 80. It is the **source of truth for hardware state**: current frame, brightness, color, mode (manual/auto), auto-playback index, firmware text-scroll playback, and battery.
2. **WebUI** (vanilla JS, `data/app.js` ~10.8k lines + `data/index.html` + `data/styles.css`) served from LittleFS. It is a **rich client that mirrors and re-derives firmware state**, renders local LED previews, edits/saves faces, and generates text-scroll frame sequences which it uploads to firmware RAM.

The architecture style is best described as **"firmware-authoritative state with an optimistic, self-correcting browser mirror."** The browser issues commands and frames through two rate-limited queues, then reconciles by polling `/api/status` and merging the response through one central function, `applyFirmwareRuntimeState()` (`app.js:4586`). Almost every firmware mutation bumps a monotonic `stateVersion` (`state.cpp:150 touchRuntimeState`), and the browser polls with `?since=<version>` for cheap "unchanged" short-circuits (`web_api.cpp:460`).

Concurrency on the firmware is **two-core**: Core 0 runs a cooperative super-loop (HTTP, DNS, buttons, power, frame queue, auto-playback, deferred restores) and Core 1 runs a dedicated **LED render/scroll task** (`scroll.cpp:scrollRenderTask`). Four FreeRTOS mutexes (`sync.cpp`) plus three `portMUX` spinlocks (`sPowerStatusMux` in `power_monitor.cpp`, `sAnimMux` in `button_animations.cpp`, `ledRenderRequestMux` in `led_renderer.cpp:12`) guard the shared `RuntimeStore` singleton (`state.h`).

The most important and most fragile subsystem is **text scrolling** (Phase 6.4): it spans a hand-rolled streaming JSON parser, a chunked timeline-upload protocol with `timelineId`/`chunkIndex` integrity rules, a PSRAM frame cache, an independent Core-1 playback timer, and a browser-side preview that re-generates frames from source text and tries to re-sync by frame index. This is where the highest desynchronization risk lives.

**Notable findings up front:**
- `applyPackedFrame()` (the non-immediate queued variant, `led_renderer.cpp:357`) is **dead code** — declared and defined, never called.
- `DEFAULT_STARTUP_FACE_ID = "face_07_triangle_eyes_frown"` (`app.js`, from `WEBUI_CONFIG.faces.startupFaceId`) is **stale/incorrect**: no such face id exists (face_07 is `face_07_wide_eyebrows_tiny_mouth`; the real startup default is `face_08_triangle_eyes_frown`). It is masked by fallback logic, so it currently causes no visible bug.
- The repo's own `AUDIT_REPORT.md` lists three bugs (C1 array overflow, M1 nested spinlocks, L1 `lastReason` truncation) that the **current source already fixes** — the audit doc is stale relative to the code.
- `updateBatteryCalibration()` (`power_monitor.cpp:170`) is intentionally a **no-op** (auto min/max calibration disabled); only manual reset commands move the calibration window.
- The browser scroll preview runs a **free-running local timer** independent of firmware frame advance, so the on-screen preview and the physical LEDs can drift during active playback (acknowledged design limitation).

---

## 2. Repository Map

### 2.1 Firmware source (`src/`) — runs on ESP32-S3

| Path | Type | Purpose | Key symbols | Used by |
|---|---|---|---|---|
| `src/main.cpp` | firmware entry | `setup()` init order + Core-0 cooperative `loop()` | `setup`, `loop`, `g_syncReady` | boot |
| `src/config.h` | firmware config | All compile-time constants: pins, matrix layout, timings, limits, paths | `LED_PIN`, `LED_COUNT=370`, `ROW_LENGTHS/OFFSETS`, `M370_HEX_CHARS=93`, `MAX_SCROLL_FRAMES=3072`, battery cal | everything |
| `src/config.cpp` | firmware config | Defines the 3 AP `IPAddress` constants | `AP_IP_ADDR`, `AP_GATEWAY_ADDR`, `AP_SUBNET_MASK` | `web_api` |
| `src/state.h` / `state.cpp` | shared state | `RuntimeStore` singleton; `RuntimeState`, `ScrollTimelineMeta`, `RuntimeFace`, `FrameStateSnapshot`; frame & scroll buffers; version cursor | `runtimeState()`, `runtimeScrollFrameBits()`, `touchRuntimeState()`, `serviceRuntimeSlowStatePublish()` | all firmware |
| `src/sync.h` / `sync.cpp` | concurrency | 4 FreeRTOS mutexes + scoped-lock helpers; documented lock order | `withFrameLock`, `withScrollLock`, `withStorageLock`, `withHardwareBusLock`, `initSyncPrimitives` | render, storage, faces |
| `src/led_renderer.h` / `.cpp` | LED output + M370 | Serpentine map, M370 decode/encode, frame queue, render to strip, color/brightness | `applyM370`, `applyPackedFrameImmediate`, `serviceM370FrameQueue`, `renderCurrentFrameToLedStrip`, `setBrightness`, `setColor` | faces, scroll, web_api, buttons |
| `src/scroll.h` / `.cpp` | scroll task | Core-1 `scrollRenderTask`, advances firmware scroll frame index on interval | `startScrollRenderTask`, `notifyScrollRenderTask`, `getRestoreAutoAfterScroll` | main, led_renderer |
| `src/faces.h` / `.cpp` | mode + faces + scroll FSM | Manual/auto mode, auto-playback, saved-face apply, deferred restore, firmware-scroll start/stop/pause | `setMode`, `serviceAutoPlayback`, `applySavedFaceIndex`, `startFirmwareScroll`, `stopFirmwareScroll`, `serviceDeferredFaceRestore` | web_api, buttons, storage |
| `src/storage.h` / `.cpp` | persistence | LittleFS mount, atomic JSON read/write, load/validate/write saved faces, runtime settings | `mountFilesystem`, `loadSavedFaces`, `validateSavedFaces`, `writeSavedFaces`, `saveRuntimeSettings` | main, web_api, power |
| `src/power_monitor.h` / `.cpp` | battery/charge | ADC sampling (trimmed mean), EMA filters, % LUT, disconnect detection, calibration, web-dirty publishing | `servicePowerMonitor`, `readPowerStatusSnapshot`, `resetBatteryVoltageMin/Max` | main, web_api, button_animations |
| `src/buttons.h` / `.cpp` | GPIO input | Debounce, combos (B3+B1/B2), repeat, dispatch to `runButtonAction` | `initHardwareButtons`, `serviceHardwareButtons`, `runButtonAction` | main, web_api |
| `src/button_animations.h` / `.cpp` | LED overlays | Mode/interval/brightness/battery overlays with bitmap glyphs; B6 battery page | `startButtonAnimationForGpioAction`, `showBatteryOverlay`, `copyButtonAnimationOverlay`, `serviceButtonAnimations` | led_renderer, buttons, web_api |
| `src/web_api.h` / `.cpp` | HTTP server | `WebServer` + captive DNS; all route handlers; gzip static serving; AP startup | `startWebServer`, `handleApiStatus/Power/Frame/Scroll/ScrollMeta/Command/SavedFaces`, `serveStaticFile` | main |
| `src/web_json.h` / `.cpp` | streaming JSON | Hand-rolled, allocation-light JSON field extraction + whole-object validation for scroll bodies | `jsonValidateCompleteObject`, `jsonStringField`, `jsonUintField`, `extractJsonStringAt`, `jsonFieldValueOffset` | web_api (scroll) |
| `src/utils.h` / `.cpp` | helpers | Hex nibble, millis math, color parse/format, UTF-8 + meta-id validation | `hexNibble`, `parseColorHex`, `validateScrollSourceText`, `millisElapsed` | many |
| `src/psram_json.h` | helper | ArduinoJson allocator that prefers PSRAM | `PsramJsonDocument`, `SpiRamAllocator` | storage, web_api |

### 2.2 WebUI (`data/`) — runs in the browser

| Path | Type | Purpose | Key symbols | Used by |
|---|---|---|---|---|
| `data/index.html` | WebUI markup | 5 pages (6.1 basic, 6.2 custom, 6.3 parts, 6.4 scroll, 6.5 debug); loading overlay; all control ids | `#page-basic/custom/parts/scroll/debug`, `#matrix-*`, `#scroll-*`, `.debug-sim` | app.js binds by id |
| `data/app.js` | WebUI logic | Entire client: state, API client, sync, rendering, faces, scroll, debug | `state`, `firmware`, `scroll`, `applyFirmwareRuntimeState`, `bootstrapWebUi`, `WEBUI_CONFIG`, `EXPRESSION_PARTS` | self / DOM |
| `data/styles.css` | WebUI styling | Layout, responsive breakpoints, loading animation, embedded UI font face | — | index.html |
| `data/resources/saved_faces.json` | data/persistent | Unified face library (11 default faces); `startupDefaultId=face_08...` | schema `rina_faces_370_v2` | firmware load + WebUI |
| `data/resources/runtime_settings.json` | data/persistent | Persisted `mode` + `autoIntervalMs` | schema `rina_runtime_settings_v1` | `loadRuntimeSettings` |
| `data/resources/battery_calib.json` | data/persistent | Battery voltage window `v_min`/`v_max` | schema `rina_battery_calibration_v1` | `loadBatteryCalibration` |
| `data/resources/fonts/ark12.json` | data asset | ~2.5 MB Ark Pixel 12px bitmap glyph table (lazy-loaded for scroll generation) | — | `loadArkPixelFontTable` |
| `data/resources/fonts/*.woff2` | data asset | Browser display fonts (unifont UI font, ark12 scroll font) | — | CSS / scroll input |
| `data/resources/loading/*.png` | data asset | Loading-screen avatar images | — | index.html |

### 2.3 Build / tooling / docs

| Path | Type | Purpose |
|---|---|---|
| `platformio.ini` | build | ESP32-S3 env, LittleFS, PSRAM (OPI/qio_opi), core affinity flags, lib deps (ArduinoJson 6.21.5, Adafruit NeoPixel 1.12.3), HTTP timeout flags |
| `partitions.csv` | build | No-OTA layout: 2 MB app + ~5.9 MB LittleFS |
| `scripts/gzip_webui_assets.py` | build hook | Pre-build gzips `index.html/app.js/styles.css/ark12.json` into `.gz` sidecars; post-build removes them |
| `scripts/patch_webserver_timeout.py` | build hook | Patches Arduino `WebServer.h` HTTP timeout macros to be overridable (200 ms) |
| `tools/*.py`, `archive/`, `.font_cache/` | tooling | Font fusion / BDF compile pipeline that produced `ark12.json` — offline, not runtime |
| `tools/test_m370_boundary.js` | test | Node unit test of M370 normalize/pack boundary behavior |
| `AUDIT_REPORT.md` | doc | Prior audit (partly stale — see §14) |
| `plan.md`, `refactor_plan.md`, `PAGE_6_5_DEBUG_REWRITE_PLAN.md` | doc | Large design/planning docs |

### 2.4 Entry points, targets, runtime spine
- **Firmware entry:** `setup()` → `loop()` in `main.cpp`. Build target `esp32s3` (`platformio.ini`).
- **Firmware main loop (Core 0):** `loop()` calls, in order, `serviceM370FrameQueue`, `webServerTick`, `serviceRuntimeSlowStatePublish`, `serviceHardwareButtons`, `serviceButtonAnimations`, `servicePowerMonitor`, `serviceDeferredFaceRestore`, `serviceAutoPlayback`, then `vTaskDelay(1)`.
- **Firmware render loop (Core 1):** `scrollRenderTask` (`scroll.cpp:22`), pinned to `LED_RENDER_TASK_CORE=1`.
- **WebUI entry:** `bootstrapWebUi()` (`app.js:10717`), invoked at script end.
- **Static assets served to browser:** anything in LittleFS, via `serveStaticFile` + `handleNotFound`; gzip-preferred.
- **API endpoints:** `/api/status`, `/api/power`, `/api/frame`, `/api/scroll`, `/api/scroll/meta`, `/api/command`, `/api/saved_faces`, plus `/` and catch-all static.
- **Hardware abstraction boundary:** `led_renderer.cpp` (LED bus via Adafruit_NeoPixel), `power_monitor.cpp` (ADC), `buttons.cpp` (GPIO). All other modules touch hardware only through these.

---

## 3. Major Systems

| System | Responsibility | Firmware files/functions | WebUI files/functions | Shared state/API/protocol |
|---|---|---|---|---|
| Boot/init | Bring-up order, FS mount, load state, start AP+server+tasks | `main.cpp setup()` | `bootstrapWebUi`, `preloadFirmwareRuntimeState` | — |
| LED render | Pack→serpentine→WS2812 output, brightness/color, overlay compositing | `led_renderer.cpp renderCurrentFrameToLedStrip`, `scroll.cpp scrollRenderTask` | local preview `renderMatrices`/`initMatrix` | `frameBits[FRAME_BYTES]`, `frameMutex` |
| M370 frame protocol | Parse/normalize/decode 93-hex frames, rate-limit queue | `led_renderer.cpp normalizeM370`, `applyM370`, `serviceM370FrameQueue` | `frameToM370`/`m370ToFrame` | `M370:`+93 hex |
| Saved faces / storage | Load/validate/persist face library + settings | `storage.cpp`, `faces.cpp applySavedFaceIndex` | `loadFaceLibrary`, `persistFaceDocuments`, `saveFace` | `/api/saved_faces`, `saved_faces.json` |
| Manual/Auto playback | Mode FSM, auto cycle through faces | `faces.cpp setMode`, `serviceAutoPlayback` | `toggleMode`, `applyFirmwareRuntimeState` | `mode`, `autoIntervalMs`, `autoFaceIndex` |
| Scroll text (firmware) | Cache uploaded frames, play on Core-1 timer, pause/step/stop | `faces.cpp startFirmwareScroll/stopFirmwareScroll`, `scroll.cpp scrollRenderTask` | scroll generation + upload + restore (`startScroll`, `uploadFirmwareScrollTimeline`) | `/api/scroll`, `/api/scroll/meta`, `ScrollTimelineMeta` |
| Button input | Debounce/combo/repeat, dispatch actions | `buttons.cpp` | debug page GPIO simulator (`runDebugSimCommand`) | `runButtonAction`, `/api/command cmd:button` |
| Button overlays | Transient LED feedback (mode/interval/brightness/battery) | `button_animations.cpp` | — (firmware-only) | `sAnim`, `sAnimMux` |
| Battery/power | ADC sample, EMA, %, disconnect, calibration | `power_monitor.cpp` | `applyPowerData`, debug power panel | `/api/power`, `/api/status` power object |
| Wi-Fi/server | SoftAP + captive DNS + HTTP routing | `web_api.cpp startAccessPoint/startWebServer/webServerTick` | `apiGet/apiPost`, captive portal | AP `RinaChanBoard-V2` / `rina.io` |
| Web API | Route handlers, JSON build, command dispatch table | `web_api.cpp handleApi*`, `API_COMMAND_ROUTES` | `sendAuxCommand`, `frameSendPump`, `buttonCommandPump` | JSON over HTTP |
| WebUI state mgmt | Mirror firmware, reconcile, busy flags | — | `state`, `firmware`, `scroll`, `applyFirmwareRuntimeState` | `stateVersion`/`since` |
| WebUI preview/render | 370-cell matrix views, fit/scale, DPS estimate | — | `initMatrix`, `fitMatrix`, `renderMatrices`, `estimateFrameWatts` | local frames |
| WebUI transport | Rate-limited frame/command queues, upload progress | — | `makeRateLimitedQueue`, `apiPostWithUploadProgress` | `/api/frame`, `/api/command` |
| Parts composer | Combine eye/mouth/cheek parts into M370 | — | `composePartsFrame`, `EXPRESSION_PARTS` | local M370 |
| Debug console | Diagnostics, GPIO sim, M370 lab, raw command, danger zone | (consumes existing endpoints) | `initializeDebugControls`, `renderDebug*` | all endpoints |

---

## 4. Runtime Lifecycle

### 4.1 Firmware power-on → operation (`main.cpp setup()`)

```
Power on
→ pinMode(LED_PIN, OUTPUT); drive LOW; hold; reset pulse   // quench floating WS2812 data
→ Serial.begin(115200)
→ runtimeState().bootMs = millis()
→ initRuntimeScrollFrameBuffer()      // alloc 3072*47B scroll cache (PSRAM preferred) + 4KB source-text buf
→ g_syncReady = initSyncPrimitives()  // 4 FreeRTOS mutexes; if fail → single-core fallback + FS error pattern
→ initLedIndexMap()                   // precompute logical→physical serpentine map
→ ledStripBegin()                     // strip.begin, clear, show (under HardwareBus lock)
→ setColorStateNoRender(DEFAULT_COLOR)// #f971d4 without racing a render
→ mountFilesystem()                   // LittleFS; on fail → showFilesystemErrorPattern() (12 red LEDs)
   └ loadRuntimeSettings()            // mode + autoIntervalMs (writes defaults if missing/corrupt)
   └ loadSavedFaces(true)             // parse saved_faces.json, sort by order, pick startup face, apply it
→ renderCurrentFrameToLedStrip(); consumeLedRenderRequest()  // show first frame once, clear pending flag
→ startScrollRenderTask()             // Core 1 LED render/scroll task (only if g_syncReady)
→ initHardwareButtons()               // INPUT_PULLUP on 6 pins, sample initial state
→ initPowerMonitor()                  // load battery_calib.json, set ADC res/atten, force one sample
→ startAccessPoint()                  // WIFI_AP, softAPConfig, softAP, DNS captive on rina.io
→ startWebServer()                    // register 7 API routes + static, server.begin()
```

Pins/peripherals initialized: LED data `GPIO2`; buttons `GPIO17,16,15,40,41,42` (B1..B6, INPUT_PULLUP); battery ADC `GPIO10`, charge ADC `GPIO1` (12-bit, 11 dB atten). State loaded from storage: `mode`, `autoIntervalMs` (settings), the full face table + startup face (saved_faces), battery calibration window. Default UI/LED state: brightness `DEFAULT_BRIGHTNESS=50`, color `#f971d4`, playback `idle` (or `auto_saved_face` if mode=auto), startup default face frame on the LEDs.

### 4.2 Firmware steady state (Core 0 `loop()` + Core 1 task)

Core 0 each iteration: drain at most one due M370 frame from the queue (`serviceM370FrameQueue`, gated to ≥`M370_FRAME_MIN_INTERVAL_MS=33ms`), service HTTP/DNS (`webServerTick`), publish slow UI dirty bit (`serviceRuntimeSlowStatePublish`, every 10 s), poll buttons (`serviceHardwareButtons`), tick overlays (`serviceButtonAnimations`), sample power (`servicePowerMonitor`, every 1 s), run any due deferred face restore, advance auto playback if in auto mode, then `vTaskDelay(1)`.

Core 1 `scrollRenderTask` loops: consume any pending render request; if firmware scroll is active+unpaused and the interval elapsed, advance `scrollFrameIndex` and copy the next cached scroll frame into `frameBits` (under scroll+frame locks); render to strip if anything changed; block on task-notify with 1 ms timeout. **All physical `strip.show()` happens here** (plus the boot/error paths), serialized by `HardwareBus` lock.

### 4.3 Browser open → operation (`bootstrapWebUi` `app.js:10717`)

```
Browser loads index.html (data-boot-phase="preload", loading overlay shown)
→ bootstrapWebUi()
   → rinaStartLoaderAnimation()
   → prepareFirstPageProgressiveReveal()
   → ensureWebUiFontReady()                  // embedded UI font (unifont) ready before reveal
   → initFirstPageUiBeforeShow(); initializeBasicPreviewMatrix(); renderFirstPageUiBeforeShow()
   → revealFirstPageWaterfall()              // staged 6.1 reveal
   → preloadFirmwareRuntimeState()           // GET /api/status (FULL, skipFrame:false) → first LED frame fills basic preview
        └ applyFirmwareRuntimeState(data, "page_boot_runtime")
   → waitForBootLoaderMinimum(); finishBootVisibility()   // data-boot-phase="ready"
   → initDeferredUiAfterShow()
   → kickPostBootScrollMetaRestore()         // enable + GET /api/scroll/meta restore
   → startFirmwareStatusPolling()            // adaptive 0.5–10 s, since=version
   → startPowerStatusPolling()               // 1 s on basic/debug pages
   → runPostBootDeferredReads()              // loadFaceLibrary() → syncRuntimeStateFromFirmware → render
```

First fetch is the **full** `/api/status` (so the boot loader can paint the first real LED frame). Local state is initialized from `WEBUI_CONFIG`, then overwritten field-by-field by `applyFirmwareRuntimeState`. Face library (`saved_faces.json`) is loaded **after** the UI is revealed to avoid contending with the single-threaded ESP server. The heavy 2.5 MB `ark12.json` scroll font is lazy — loaded the first time the scroll page is opened (`switchPage`) or warmed in the background after critical reads.

---

## 5. Hardware-to-Firmware-to-WebUI Flow

### 5.1 Hardware interaction table

| Hardware source | Pin/peripheral | Read/write fn | Data transformation | State updated | WebUI/API exposure | User-visible effect |
|---|---|---|---|---|---|---|
| Buttons B1–B6 | GPIO 17/16/15/40/41/42, INPUT_PULLUP | `serviceHardwareButtons` (`buttons.cpp:220`) | debounce 25 ms; edge→press/release; combos; repeat | dispatch via `runButtonAction` | `scrollStopEvent`, `lastReason`, mode/brightness/index in `/api/status` | face change, brightness, mode toggle, overlay |
| Battery voltage | ADC `GPIO10` | `readTrimmedAdcMilliVolts`+`sampleBattery` (`power_monitor.cpp:292`) | 16 samples, drop 4 hi/4 lo, mean; `mV/1000*2.708333+0.2033`; EMA τ=20 s; LUT→% | `powerStatus.vbat/batteryPercent` (under `sPowerStatusMux`) | `/api/power`, `/api/status` power obj | battery badge + debug panel |
| Charger presence | ADC `GPIO1` | `sampleCharge` (`power_monitor.cpp:398`) | `mV/1000*6.684982+0.0712`; EMA α=0.2; `>4.0V`→charging | `powerStatus.vcharge/charging` | same | charging badge |
| Battery disconnect | derived from ADC drop | `detectBatteryDisconnect` (`power_monitor.cpp:285`) | huge raw drop ≥1000 mV & ≤900 mV, reconnect <1500 mV | `batteryDisconnected/LowVoltageUnpowered` | power obj flags | "未上电" state |
| LED output | WS2812 on GPIO2 via RMT/NeoPixel | `renderCurrentFrameToLedStrip` (`led_renderer.cpp:211`) | logical→physical serpentine; bit→color or overlay RGB; min-gap pacing | reads `frameBits`+color+brightness | `lit`/`lastM370` in status | the physical face |
| LED render request | `portMUX` flag + task notify | `requestLedRender`/`consumeLedRenderRequest` | ISR-safe flag set; notify Core-1 task | `ledRenderRequested` | — | render scheduling |

### 5.2 End-to-end trace: button press → LEDs (+ optional WebUI)

```
GPIO falling edge on B1
→ serviceHardwareButtons() debounce (25ms) detects press   // buttons.cpp:220
→ handleHardwareButtonPress(): B3-combo check; B1 is face-repeat → fireHardwareButtonAction("B1")
→ runButtonAction("B1","gpio")                             // buttons.cpp:100
   → (B1/B2) stopFirmwareScroll(false); setRestoreAutoAfterScroll(false)
   → applyRelativeSavedFace(+1, "gpio_B1_next_saved_face")  // faces.cpp:148
       → applySavedFaceIndex(): autoFaceIndex++; applyM370(face.m370,...)
           → enqueuePackedM370Frame → publishPackedFrameNow (if rate-ready)
               → withFrameLock { memcpy frameBits; lastM370; ++framesAccepted; touchRuntimeState(); showCurrentFrameNoLock() }
   → if scroll was active: markScrollStoppedByButton() bumps scrollStopEventSeq
   → finishButtonAction(): startButtonAnimationForGpioAction("B1")  // no overlay for B1, but sets press feedback
→ Core-1 scrollRenderTask wakes on notify → renderCurrentFrameToLedStrip() → strip.show()  // LEDs update
→ (later) WebUI poll GET /api/status?since=v → version changed → applyFirmwareRuntimeState
   → autoFaceIndex/lastReason/scrollStopEvent merged → renderSavedFaces / preview update
```

### 5.3 End-to-end trace: battery voltage → WebUI indicator

```
Core-0 loop: servicePowerMonitor() every ~1s              // power_monitor.cpp:435
→ sampleBattery(): readTrimmedAdcMilliVolts(GPIO10)
   → instantVbat = vadc*2.708333 + 0.2033
   → disconnect/low-voltage edge detection
   → EMA: nextVbat = vbat*(1-α)+instant*α, α from dt/τ(20s)
   → batteryPercent via BATTERY_PERCENT_LUT interpolation (±1% hysteresis)
   → commit vbat/percent/valid under sPowerStatusMux
→ servicePowerWebPublish(): set webFastDirty/webSlowDirty + touchRuntimeState() on meaningful change
→ WebUI GET /api/power (1s) or /api/status power obj
   → addPowerStatus() builds JSON (icon class/color, state text, thresholds)
   → applyPowerData() in browser → state.battery* → renderState() → #badge-battery + debug panel
```

---

## 6. WebUI-to-Firmware-to-Hardware Flow

The browser never writes hardware directly. Three transport paths exist:
1. **`frameSendPump`** → `POST /api/frame` (rate `WEBUI_M370_SEND_INTERVAL_MS=45ms`, depth 3) for raw M370 frames (custom/parts/debug/manual draw).
2. **`buttonCommandPump`** → `POST /api/command {cmd:"button"}` (rate 120 ms, depth 4) for simulated buttons.
3. **`sendAuxCommand`** → `POST /api/command` directly (no queue) for everything else (mode, color, brightness, scroll control, battery resets, overlays).

Command responses are fed back through `applyFirmwareRuntimeState()` so the browser reconciles to firmware truth — but **`/api/frame` replies are not**. `buttonCommandPump` sets `onResult: applyFirmwareRuntimeState` (`app.js:4999`), whereas `frameSendPump` has **no `onResult`** (`app.js:5009`); raw frame sends therefore rely on optimistic local state plus the next `/api/status` poll to reconcile, and the frame reply's `color`/`brightness`/`mode`/`lit`/`m370` fields are effectively ignored.

### 6.1 Feature flow: change brightness

```
User drags #brightness-range or clicks +8/−8
→ setBrightness(v,"brightness_change")            // app.js:5235
   → applyBrightnessLocal(v) (instant local preview + DPS)
   → lastUserBrightnessMs = now  (suppresses stale firmware echo for 2s)
   → sendAuxCommand("set_brightness",{raw:v})
→ POST /api/command {cmd:"set_brightness",payload:{raw}}
→ handleApiCommand → commandSetBrightness → setBrightness(raw)   // led_renderer.cpp:421
   → constrain 10..200; withFrameLock { brightness=raw; touchRuntimeStateSlow(); showCurrentFrameNoLock() }
→ Core-1 render applies strip.setBrightness on next show
→ reply JSON (buildCommandReply) → applyFirmwareRuntimeState("webui")
   → brightness echo skipped if within 2s of lastUserBrightnessMs (anti-jitter)
```

Note: brightness uses `touchRuntimeStateSlow()` (only publishes a new version after the 10 s slow window or another fast change), so the slider value is authoritative locally and reconciled lazily.

### 6.2 Feature flow: custom/parts frame send

```
User draws on #matrix-custom-edit / picks parts
→ composePartsFrame()/editFrame edits → setCurrentFrame(frame,"custom_face_send","idle")  // app.js:5180
   → guardBeforeOutput() → terminateOtherActivities("custom") (stops scroll/auto, sends terminate_other_activities)
   → queueFirmwareFrame(frame,reason,playback) → frameSendPump.enqueue
→ POST /api/frame {m370,reason,mode}
→ handleApiFrame: normalizeM370; if reason custom_/parts_ → setMode("manual",false);
   playback=mode; applyM370 → frame queue → render
→ reply (color/brightness/mode/lit/lastM370) returned but NOT merged (frameSendPump has no onResult);
   browser reconciles via the next /api/status poll
```

### 6.3 Feature flow: mode toggle (manual↔auto)

```
User clicks #mode-toggle → toggleMode("ui_mode_toggle")        // app.js:6844
→ toggleModeLocal (optimistic) + sendAuxCommand("set_mode",{mode})
→ commandSetMode → cancelDeferredFaceRestore(); setMode(mode,true)  // faces.cpp:29
   → auto: mode=auto, playback=auto_saved_face, paused=false, lastAutoSwitchMs=now
   → manual: playback→idle if was auto; clear restoreAutoAfterScroll
   → persist runtime_settings.json if mode changed
→ Core-0 serviceAutoPlayback() then cycles faces on autoIntervalMs when mode=auto
→ reply → applyFirmwareRuntimeState
```

---

## 7. API Endpoint Map

| Endpoint | Method | Called by WebUI fn | Firmware handler | Parameters | State changed | Hardware effect | Response (key fields) |
|---|---|---|---|---|---|---|---|
| `/` | GET | browser nav | `serveRoot`→`serveStaticFile` | — | — | — | index.html (gzip) |
| `/api/status` | GET (HTTP_ANY) | `preloadFirmwareRuntimeState`, `syncRuntime*FromFirmware` | `handleApiStatus` (`web_api.cpp:446`) | `since`, `runtimeOnly`, `summary`/`noFrame`, `fullPower`, `runtimeOnly` | none (read) | none | `v/version`, `next_poll_ms`, `renderer.*`, `power.*`, `matrix`, `endpoints`, `storage`, `stats`, `scrollStopEvent`, `unchanged` |
| `/api/power` | GET | `refreshPowerStatusFromFirmware` | `handleApiPower` (`:584`) | — | none | none | `power.*` (full) |
| `/api/frame` | POST | `frameSendPump` via `queueFirmwareFrame` | `handleApiFrame` (`:596`) | `m370`, `mode`/`playback`, `reason`, `faceId` | frame, playback, mode, autoFaceIndex | LED frame | `accepted`, `queueCount`, `color`, `brightness`, `mode`, `lit`, `m370` |
| `/api/scroll` | POST | `uploadScrollTimelineAttempt` (chunks) | `handleApiScroll` (`:670`) | `frames[]`, `append`, `start`, `chunkIndex`, `totalFrames`, `timelineId`, `sourceText`, `fontId`, `generatorVersion`, `fps`/`intervalMs`, `storage` | scroll cache, scroll meta, playback | LED scroll (on start) | `frames`, `chunkFrames`, `chunkIndex`, `uploadComplete`, `timelineId`, `started` |
| `/api/scroll/meta` | GET | `restoreScrollTextFromFirmware`, `fetchLatestScrollFrameMetaAfterPreview` | `handleApiScrollMeta` (`:988`) | — | none | none | `scrollTimelineId`, `sourceText`, `fontId`, `generatorVersion`, `uiFps`, `frameCount`, `frameIndex`, `uploadComplete`, scroll active/paused flags |
| `/api/command` | POST | `sendAuxCommand`, `buttonCommandPump` | `handleApiCommand` (`:1388`) | `cmd`, `payload{...}` | per-command | per-command | `cmd`, full renderer echo, scroll state, optional `power` |
| `/api/saved_faces` | GET/POST | `loadUnifiedFacesDocument`, `persistFaceDocuments` | `handleApiSavedFaces` (`:1489`) | GET: none; POST: `document`, `path`, `reason` | saved face table (reloaded) | LEDs on reload of current face | GET: raw JSON; POST: `bytes`, `writes`, `path` |
| (catch-all) | GET | static fetches | `handleNotFound`→`serveStaticFile` | URI | none | none | static asset or 503 FS-error page |

### 7.1 `/api/command` command table (`API_COMMAND_ROUTES`, `web_api.cpp:1336`)

`set_color`, `set_brightness`, `set_mode`, `set_auto_interval`, `set_scroll_interval`, `start_scroll`, `scroll_step`, `pause_scroll`, `resume_scroll`, `stop_scroll`, `pause`, `resume`, `button`, `terminate_other_activities`, `reset_battery_min`, `reset_battery_max`, `battery_overlay`.

Each handler returns `bool`; failures set `sCommandErrorStatus` (400 default, 409 for scroll timeline conflicts) and are reported via `sendError`. `commandWantsPower()` augments the reply with a fresh power snapshot for the battery commands.

---

## 8. State Ownership and Synchronization

### 8.1 Sync field table

| State field | Firmware variable/source | API endpoint | WebUI variable | UI element | Poll/event trigger | Risk |
|---|---|---|---|---|---|---|
| Color | `runtimeState().colorHex/R/G/B` (frameMutex) | status/command | `state.color` | swatch/input | command echo + poll | low |
| Brightness | `runtimeState().brightness` | status/command | `state.brightness` | range+input | command echo (2 s echo-suppress) | medium (stale echo during drag) |
| Mode | `runtimeState().mode` | status/command/settings | `state.mode` | mode toggle | command + poll | low |
| Auto interval | `runtimeState().autoIntervalMs` | status/command/settings | `state.autoInterval` | interval slider | command + poll | low |
| Auto face index | `runtimeState().autoFaceIndex` | status/frame | `state.faceIndex` | face list highlight | poll/frame reply | medium (clamped to local library length) |
| Current frame | `frameBits` / `lastM370` (frameMutex) | status (`lastM370`) | `currentFrame` | matrices | full poll only (skipped while scrolling) | medium |
| Playback | `runtimeState().playback` | status/command | `state.playback` | scroll/mode UI | poll/command | medium |
| Scroll active/paused | `firmwareScrollActive/Paused/User/System` (scrollMutex) | status/command/meta | `scroll.active/paused/user/systemPaused` | scroll buttons | poll/command | **high** |
| Scroll frame index | `runtimeState().scrollFrameIndex` (scrollMutex) | status/meta | `scroll.frameIndex` | "当前帧" | poll/meta; local timer overrides | **high (drift)** |
| Scroll source text | `scrollSourceText` + meta (scrollMutex) | `/api/scroll/meta` | `scroll.restoredSourceText`, input box | textarea | restore flow | high (truncation/edit guard) |
| Scroll stop event | `scrollStopEvent*` seq | status | `lastScrollStopEventSeq` | (drives preview reset) | poll | medium |
| Battery | `powerStatus.*` (sPowerStatusMux) | power/status | `state.battery*` | badges/debug | 1 s power poll | low |
| Saved faces | `autoFaces_[]` (Core-0) + LittleFS file | `/api/saved_faces` | `defaultFaces/userFaces/faceLibraryDocument` | face list | explicit load/save | medium (two copies) |
| Settings (mode/interval) | `runtime_settings.json` | (loaded at boot) | — | — | boot | low |
| stateVersion | `runtimeState().stateVersion` | status `v` | `firmwareStatusVersion` | — | every poll | low |

### 8.2 Source-of-truth analysis
- **Firmware is authoritative** for: current frame, color, brightness, mode, auto interval, auto face index, all scroll playback state, battery, and the persisted face library/settings/calibration files.
- **Browser-derived/cached**: `state.*` and `scroll.*` mirror firmware; `currentFrame/scrollFrame/partsFrame/editFrame/debugPreviewFrame` are **locally reconstructed** from M370 or generated bitmaps.
- **Duplicated**: the face library lives both in firmware RAM (`autoFaces_`) and in the browser (`faceLibraryDocument`/`defaultFaces`/`userFaces`); scroll frames live in firmware PSRAM cache and (separately, re-generated) in `scroll.frames`.
- **Survives page reload**: everything firmware-side (frame, mode, scroll cache + source text via `/api/scroll/meta`, battery). The browser re-derives by polling + scroll-meta restore.
- **Survives power reboot**: only what is in LittleFS — `saved_faces.json`, `runtime_settings.json` (mode + interval), `battery_calib.json`. Scroll cache is **RAM-only** (explicitly rejects persist/flash, `web_api.cpp:705`) and is lost on reboot.
- **Can desynchronize**: scroll frame index (independent timers), scroll preview vs. LEDs (font/generator mismatch → `framesTimelineId` left unbound), brightness during active drag (echo-suppressed), face index when the browser's library differs from firmware's file.

---

## 9. Feature-by-Feature Implementation

### Feature: Manual mode
- **Behavior:** static face shown; B1/B2 or WebUI next/prev change face; no auto cycling.
- **Firmware:** `setMode("manual")` (`faces.cpp:29`), `applySavedFaceIndex`/`applyRelativeSavedFace`.
- **WebUI:** `toggleMode`, `nextFace/prevFace` → `sendButtonCommand("B1"/"B2")`; local `nextFaceLocal/prevFaceLocal` for optimistic preview.
- **Persistence:** `mode` saved to `runtime_settings.json`.
- **Risks:** browser face index clamps to its own library length (`applyFirmwareRuntimeState:4743`); if libraries differ, highlight can mismatch.

### Feature: Auto playback mode
- **Behavior:** cycles faces every `autoIntervalMs`.
- **Firmware:** `serviceAutoPlayback` (`faces.cpp:380`) — increments `autoFaceIndex` and `applyM370("firmware_auto_saved_face")` on interval; `paused` and `autoFaceCount==0` short-circuit.
- **WebUI:** mode toggle + interval slider; relies on polling to follow index.
- **Persistence:** `autoIntervalMs` + `mode` in settings.
- **Risks:** the browser does not run its own auto timer; the displayed face lags one poll behind hardware.

### Feature: Saved faces / library
- **Behavior:** unified `saved_faces.json` of default + user faces; reorder/rename/delete; startup default.
- **Firmware:** `loadSavedFaces` (sort by `order`, choose startup/previous face, cap at `MAX_AUTO_FACES=128`), `validateSavedFaces` (category, ≤128, ≥1 default, valid M370), `writeSavedFaces` (atomic temp+rename).
- **WebUI:** `loadFaceLibrary`, `buildUnifiedFaceDocument`, `persistFaceDocuments` (→ optional local File System Access write + `POST /api/saved_faces`), `createFaceRow`/`reorderFace`/`deleteFace`.
- **Persistence:** LittleFS file; reload after POST re-applies current face.
- **Risks:** two divergent copies; ordering re-assigned client-side (`reassignOrderFromLibrary`); local-file vs firmware write can disagree on failure.

### Feature: Face/frame upload (custom + parts)
- **Firmware:** `handleApiFrame` normalizes and applies; `custom_`/`parts_` reasons force manual mode.
- **WebUI:** `setCurrentFrame`→`queueFirmwareFrame`→`frameSendPump`; live-send toggles re-send on each edit.
- **Risks:** frame queue depth 3 both sides; rapid edits drop frames (counted in `droppedFrames`).

### Feature: LED matrix preview
- **WebUI:** `initMatrix` builds 370 cells using the same serpentine/row geometry as firmware (`MATRIX_VIEW_CONFIGS`, `XY_TO_INDEX`, `ROW_RANGES`); `fitMatrix`/`renderMatrices` size and paint. Five independent views (basic, custom-edit, parts, scroll, debug) each with their own frame buffer.
- **Risks:** preview is browser-rendered; correctness depends on row geometry matching `config.h` (it does — same `ROW_LENGTHS/OFFSETS`).

### Feature: Brightness control
- See §6.1. Firmware `setBrightness` clamps 10–200; overlay shows percent relative to `MAX_BRIGHTNESS=200`. Anti-jitter via `lastUserBrightnessMs`.

### Feature: Color control
- **Firmware:** `setColor` (parse hex, store RGB, `touchRuntimeStateSlow`, request render).
- **WebUI:** `setColor`, parent/child color dropdowns (`renderParentColorButtons`/`renderChildColors`), hex input. Color applies as the "on" pixel color in `renderCurrentFrameToLedStrip`.

### Feature: Scroll text generation (browser)
- **WebUI:** `buildTextScrollBitmap` (Ark Pixel 12px glyphs via `buildTextGlyph`/`getArkGlyph`), `extractFrameFromTextImage` slices a 1-LED-per-frame window across the rendered bitmap into M370 frames; `prepareTextScrollTimeline*` builds `scroll.frames`.
- **Encoding identity:** `SCROLL_GENERATOR_VERSION="webui-scrollgen-6.4.2"` + `fontId` gate whether a restored preview can bind to firmware frames exactly.

### Feature: Scroll upload to firmware
- **WebUI:** `uploadFirmwareScrollTimeline`→`uploadScrollTimelineAttempt` chunks frames (first chunk sized to ≤12 KB body, rest 24 frames), each chunk carries `timelineId`+`chunkIndex`; first chunk carries `sourceText`+`fontId`+`generatorVersion`+`totalFrames`. 409 → one full retry with a fresh `timelineId` (`C10`).
- **Firmware:** `handleApiScroll` validates strictly (pre-flight validates all first-chunk frames before clearing state), enforces timeline integrity (`D1/D2/E1/E2/E3`), writes packed frames into `scrollFrameBits(targetIndex)`, sets `uploadComplete` when `framesReceived≥totalFramesExpected`.

### Feature: Scroll play/pause/resume/stop/step
- **Firmware:** `startFirmwareScroll`, `setFirmwareScrollUserPaused`/`SystemPaused` (effective pause = user OR system, `recomputeEffectivePauseLocked`), `stopFirmwareScroll` (optional clear + deferred default-face restore), `commandScrollStep` (manual index step, immediate frame).
- **WebUI:** `startScroll`, `togglePauseScroll`/`pauseScroll`/`resumeScroll`, `stopScroll`, `setScrollStepHandler`; busy flags (`commandBusy/startBusy/pauseBusy/stopBusy/stepBusy`) and `pauseToggleLocked` serialize user actions.
- **System pause:** battery overlay pauses firmware scroll as "system paused" so it auto-resumes when the overlay ends (`button_animations.cpp pauseScrollForOverlay`/`resumeScrollAfterOverlayIfNeeded`).

### Feature: Scroll preview sync after reload
- **WebUI:** `kickPostBootScrollMetaRestore`→`restoreScrollTextFromFirmware` (GET `/api/scroll/meta`) refills the textarea (never overwriting unsent edits — `C5`), then `restoreScrollPreviewIfNeeded` regenerates frames and re-syncs `frameIndex`. Frame identity (`framesTimelineId`) is bound only when text not truncated + generator matches exactly + frame count equals firmware's (`D5/E4`).
- **Risks:** the core desync surface — see §13.

### Feature: Button controls / GPIO simulator
- **Firmware:** `runButtonAction` maps B1 next, B2 prev, B3 mode toggle, B4/B5 brightness ∓8, B3+B1/B3+B2 interval ∓0.5 s, B6 battery overlay (short/long), B6+B3 (network info path exists in UI labels). Repeat for face/brightness buttons.
- **WebUI:** debug page `.debug-sim` buttons → `runDebugSimCommand` → `/api/command {cmd:"button"}` or specific commands (`battery_overlay`, `pause_scroll`).

### Feature: Battery display / charging detection
- See §5.3. `addPowerStatus` precomputes icon classes/colors and Chinese state text (`电池`/`未上电`/`充电`). Browser `applyPowerData` consumes them directly.

### Feature: Default-face behavior
- **Firmware:** startup default selected by `is_startup_default` or `startupDefaultId` in `loadSavedFaces`; after a scroll stop with restore, `applyStartupDefaultFaceAfterScrollStop` re-applies it.
- **WebUI:** `startupDefaultFaceIndex`/`preferredStartupDefaultId` (note stale `DEFAULT_STARTUP_FACE_ID`, §14).

### Feature: Loading animation / init
- HTML loading overlay + staged reveal (`revealFirstPageWaterfall`); first LED frame painted into basic preview before the loader closes (`preloadFirmwareRuntimeState` full status).

### Feature: Import/export / persistence
- **WebUI:** `downloadFacesJson`, `importFacesJsonText/File`, File System Access `openLocalFaceLibraryFile`/`saveFaceLibraryToLocalFile`. All converge on `buildUnifiedFaceDocument` + `persistFaceDocuments`.

### Feature: Hidden/debug endpoints
- No hidden firmware endpoints beyond the 7 registered. The debug page exposes a **raw `/api/command`** textarea (`#debug-raw-json`) gated by a confirm checkbox, and a "danger zone" clear-user-faces. The `battery_overlay`, `terminate_other_activities`, `reset_battery_min/max` commands are firmware-real and UI-reachable.

---

## 10. Function-Level Call Graphs

### 10.1 Firmware boot
```
setup()
 → initRuntimeScrollFrameBuffer() → RuntimeStore::initScrollFrameBuffer()
 → initSyncPrimitives()
 → initLedIndexMap() → logicalToPhysicalLedIndex()
 → ledStripBegin() → strip.show() [HardwareBus]
 → mountFilesystem()
 → loadRuntimeSettings() → setMode()/setAutoInterval()
 → loadSavedFaces(true) → normalizeM370 / std::sort / applyM370()
 → renderCurrentFrameToLedStrip()
 → startScrollRenderTask() → xTaskCreatePinnedToCore(scrollRenderTask, core1)
 → initHardwareButtons()
 → initPowerMonitor() → loadBatteryCalibration / servicePowerMonitor(true)
 → startAccessPoint() → WiFi.softAP / dnsServer.start
 → startWebServer() → server.on(...) ×8 / server.begin
```

### 10.2 Firmware Core-0 loop
```
loop()
 → serviceM370FrameQueue() → publishPackedFrameNow() → showCurrentFrameNoLock() → requestLedRender()
 → webServerTick() → dnsServer.processNextRequest() / server.handleClient() → handleApi*()
 → serviceRuntimeSlowStatePublish() → touchRuntimeState()
 → serviceHardwareButtons() → handleHardwareButtonPress/Release → runButtonAction() → applyRelativeSavedFace/setMode/setBrightness/adjustAutoInterval
                            → serviceButtonAnimationButtonInputs()
 → serviceButtonAnimations() → readPowerStatusSnapshot() / requestLedRender() / stopOverlay()
 → servicePowerMonitor() → sampleBattery()/sampleCharge()/servicePowerWebPublish()
 → serviceDeferredFaceRestore() → applyStartupDefaultFaceAfterScrollStop / applyCurrentSavedFaceForMode
 → serviceAutoPlayback() → applyM370()
```

### 10.3 Firmware Core-1 render task
```
scrollRenderTask()
 → consumeLedRenderRequest()
 → withScrollLock { advance scrollFrameIndex; memcpy nextFrame }
 → withFrameLock { memcpy frameBits; ++framesAccepted }
 → renderCurrentFrameToLedStrip()
      → withFrameLock { snapshot frame/color/brightness }
      → copyButtonAnimationOverlay()  (overlay path)
      → withHardwareBusLock { strip.show() }
 → ulTaskNotifyTake(1ms)
```

### 10.4 Firmware HTTP command dispatch
```
handleApiCommand()
 → parseJsonBody()
 → findApiCommandRoute(cmd) → route->handler(doc,payload,error)
      commandSetColor → setColor()
      commandSetBrightness → setBrightness()
      commandSetMode → cancelDeferredFaceRestore() + setMode()
      commandStartScroll → withScrollLock checks → startFirmwareScroll()
      commandScrollStep → withScrollLock step → applyPackedFrameImmediate()
      commandPause/Resume[Scroll] → setFirmwareScrollUserPaused()/runtimeState.paused
      commandStopScroll → stopFirmwareScroll()
      commandButton → runButtonAction(...,"api_button")
      commandTerminateOtherActivities → stopFirmwareScroll()/setMode()
      commandResetBatteryMin/Max → resetBatteryVoltage*()
      commandBatteryOverlay → showBatteryOverlay()
 → buildCommandReply() [+ addPowerStatus if commandWantsPower]
 → sendJsonDocument()
```

### 10.5 WebUI initialization
```
bootstrapWebUi()
 → ensureWebUiFontReady()
 → initFirstPageUiBeforeShow() / initializeBasicPreviewMatrix() / renderFirstPageUiBeforeShow()
 → revealFirstPageWaterfall()
 → preloadFirmwareRuntimeState() → bootFastJsonGet(/api/status) → applyFirmwareRuntimeState()
 → finishBootVisibility() / initDeferredUiAfterShow()
 → kickPostBootScrollMetaRestore() → restoreScrollTextFromFirmware()
 → startFirmwareStatusPolling() / startPowerStatusPolling()
 → runPostBootDeferredReads() → loadFaceLibrary() → syncRuntimeStateFromFirmware()
```

### 10.6 WebUI sync + transport
```
applyFirmwareRuntimeState(data,source)        ← onResult of buttonCommandPump, sendAuxCommand, polls
 → applyPowerData() / setColor() / syncAutoIntervalUi()
 → scroll.* reconciliation / state.* / renderMatrices / renderSavedFaces / renderState
 → scrollStopEventFromStatus() → resetScrollControlsAfterButton() / scheduleFirmwareScrollStopFullSync()
 → (timeline mismatch) restoreScrollTextFromFirmware() → restoreScrollPreviewIfNeeded()

setCurrentFrame() → guardBeforeOutput() → terminateOtherActivities() → queueFirmwareFrame() → frameSendPump.enqueue() → apiPost(/api/frame)
sendAuxCommand() → apiPost(/api/command) → applyFirmwareRuntimeState()
sendButtonCommand() → buttonCommandPump.enqueue() → apiPost(/api/command)
```

### 10.7 Reverse usage of hot functions
- `applyFirmwareRuntimeState` is called by: `preloadFirmwareRuntimeState`, `syncRuntimeStateFromFirmware`, `syncRuntimeSummaryFromFirmware`, `sendAuxCommand`, `buttonCommandPump.onResult`, `startScroll`, `pauseScroll`, `resumeScroll`, `stopScroll`, `uploadScrollTimelineAttempt`.
- `touchRuntimeState` (firmware version bump) is called by ~all mutators: `publishPackedFrameNow`, `setMode`, `setAutoInterval`, `saveRuntimeSettings`, `writeSavedFaces`, `loadSavedFaces`, button handlers, scroll FSM, power publish.
- `renderCurrentFrameToLedStrip` is called by: Core-1 task (normal), `setup()` (boot), `loop()` single-core fallback.

### 10.8 Apparently unused / dead
- `applyPackedFrame()` (non-immediate, `led_renderer.cpp:357`) — defined + declared, **no callers** (verified by grep). The immediate variant is used everywhere instead.

---

## 11. Protocols and Data Encoding

### 11.1 M370 frame format
- **Form:** `M370:` + exactly 93 uppercase hex chars (`M370_HEX_CHARS=93`). 93×4 = 372 bits, of which the first 370 are LED states (`M370_BITS=370`); top 2 bits ignored.
- **Generated:** browser `frameToM370` (and firmware `blankM370`); **parsed:** `normalizeM370`→`decodeNormalizedM370ToPackedBits` (`led_renderer.cpp:280/323`). Bit order: logical row-major; nibble `nib` covers bits `nib*4..nib*4+3`, MSB-first within nibble.
- **Validation:** non-hex char → reject; wrong length → reject. `applyM370` increments `framesRejected` on failure.
- **Packed storage:** `FRAME_BYTES = (370+7)/8 = 47` bytes, bit i at `byte i>>3`, mask `1<<(i&7)`.
- **Example (from saved_faces.json):** `M370:00000000000000000000100200A014044088000000000000000005002829FE5004080010800090000600000000000` (face_08, startup default).

### 11.2 Scroll upload protocol (`/api/scroll`)
- **Body fields:** `frames:[m370,...]`, `append:bool`, `start:bool`, `chunkIndex:uint`, `totalFrames:uint`, `timelineId/fontId/generatorVersion:string`, `sourceText:string`, `fps`/`intervalMs`, `storage:"ram"`, `source`.
- **Integrity rules (firmware-enforced):**
  - First chunk (`append:false`): pre-flight validate **all** frames before clearing state; `totalFrames≤MAX_SCROLL_FRAMES`; if `timelineId` present then `totalFrames>0` required (`E2`); `sourceText` requires `timelineId`+`fontId`+`generatorVersion` (`D1`) and valid UTF-8 (`validateScrollSourceText`); meta ids must match `[A-Za-z0-9._:-]` (`validateMetaIdString`).
  - Append chunks: must match cached `timelineId`, `chunkIndex==nextChunkIndex`, reject if `uploadComplete` (`D3`).
  - Over-count → 409 + cache invalidation but `sourceText` preserved (`EH-A`).
- **Failure behavior:** 400 (malformed/invalid frame), 409 (timeline/chunk conflict), 413 (too many frames), 507 (buffer alloc). On conflict the browser retries once with a new `timelineId`.
- **Streaming parse:** `handleApiScroll` doesn't fully deserialize frames into ArduinoJson; it scans the `frames` array region directly (`jsonFieldValueOffset` + `extractJsonStringAt`) to avoid large allocations.

### 11.3 Scroll meta (`/api/scroll/meta`)
- Read-side counterpart: returns `scrollTimelineId`, `sourceText`, `fontId`, `generatorVersion`, `uiFps`, `frameCount`, `frameIndex`, `uploadComplete`, scroll active/paused. Copies meta + source text **under `scrollMutex`** into a heap buffer, serializes outside the lock; alloc failure → 507.

### 11.4 Status JSON (`/api/status`)
- `renderer` (color, brightness, mode, playback, paused, autoInterval, autoFaceCount/Index, scroll fields, `lastM370` [omitted while scrolling/summary], `lit`, `lastReason`, `scrollStopEvent`), `power`, `ap`, `matrix`, `endpoints`, `storage`, `stats`, `memory`. Supports `since`/`runtimeOnly`/`summary`/`noFrame`/`fullPower` query knobs and `unchanged:true` short-circuit.

### 11.5 Persistence formats (LittleFS)
- `saved_faces.json`: `{format:"rina_faces_370_v2", category:"unified_saved_faces", startupDefaultId, faces:[{id,name,type,m370,order,...}]}`. Atomic write via temp+rename (`writeStringToFileLocked`).
- `runtime_settings.json`: `{format:"rina_runtime_settings_v1", mode, autoIntervalMs}`.
- `battery_calib.json`: `{format:"rina_battery_calibration_v1", v_min, v_max, ...}`.
- **Browser-side**: no localStorage/IndexedDB; the only persistence is via firmware POST or File System Access local file. (The widget guidance against browser storage matches actual code — none is used.)

### 11.6 Color / brightness encoding
- Color: `#RRGGBB` (or `RRGGBB`), parsed by `parseColorHex`, stored as 3 bytes + hex string. Brightness: raw 10–200 (Adafruit scale), button step 8, overlay shows % of 200.

---

## 12. WebUI Structure

### 12.1 Page / section map (`index.html`)
Five `<section class="page">`: `#page-basic` (color/brightness/auto-interval/mode + read-only preview), `#page-custom` (draw board + M370 + face manager), `#page-parts` (eye/mouth/cheek composer + manager), `#page-scroll` (text input, fps, play controls, preview), `#page-debug` (11 cards: device summary, firmware health, power/ADC, network, GPIO simulator, M370 protocol lab, debug preview, resources, comms log, raw command, danger zone). Loading overlay + hamburger page nav are outside `.app`.

### 12.2 UI element → handler map (representative)

| UI element | DOM id/class | Handler | Calls API? | Updates state? | Firmware effect |
|---|---|---|---|---|---|
| Color input | `#color-input` | `initColorInput`/`setColor` | `set_color` | `state.color` | LED color |
| Brightness slider | `#brightness-range` | `initBrightness`/`setBrightness` | `set_brightness` | `state.brightness` | LED brightness |
| Mode toggle | `#mode-toggle` | `toggleMode` | `set_mode` | `state.mode` | auto/manual |
| Next/Prev face | `#face-next/#face-prev` | `nextFace/prevFace` | button | `state.faceIndex` | face change |
| Interval ± | `#interval-up/down` | `adjustInterval` | `set_auto_interval` | `state.autoInterval` | cycle speed |
| Custom send | `#custom-send` | `sendCustomFrame`→`setCurrentFrame` | `/api/frame` | frame | LED frame |
| Parts apply | `#parts-apply` | `sendPartsFrame` | `/api/frame` | frame | LED frame |
| Scroll play | `#scroll-play` | `startScroll` | `/api/scroll`+`start_scroll` | scroll.* | LED scroll |
| Scroll pause/stop/step | `#scroll-pause/stop/step-*` | `togglePauseScroll/stopScroll/setScrollStepHandler` | command | scroll.* | scroll control |
| GPIO sim | `.debug-sim[data-gpio]` | `runDebugSimCommand` | command/button | per-action | per-button |
| Save faces | `.faces-json-*` | `persistFaceDocuments` etc. | `/api/saved_faces` | library | reload faces |
| Raw command | `#debug-raw-send` | raw `/api/command` | command | per | per |

### 12.3 WebUI variable map (key globals, `app.js:3454+`)

| Variable | Purpose | Updated by | Read by | Mirrors firmware? | Risk |
|---|---|---|---|---|---|
| `state` | UI mirror of device runtime + battery + network | `applyFirmwareRuntimeState`, local setters | render fns | yes | medium |
| `firmware` | Connection/queue diagnostics (browser-side counters) | api wrappers, pumps | `renderDebugFirmwareHealth` | partly (online/status real) | low |
| `scroll` | Scroll playback/upload/restore state machine | scroll fns, sync | scroll UI | partly | high |
| `currentFrame`/`scrollFrame`/`partsFrame`/`editFrame`/`debugPreviewFrame` | local LED buffers | edits/sync | `renderMatrices` | reconstructed | medium |
| `defaultFaces`/`userFaces`/`faceLibraryDocument` | face library copy | load/import/persist | list UI | duplicate | medium |
| `firmwareStatusVersion`/`firmwareNextPollMs` | poll cursor + adaptive cadence | `rememberFirmwareStatusPoll` | pollers | yes | low |
| `pendingScrollMeta` | in-flight restore meta | restore flow | preview restore | n/a | high |
| busy flags (`scroll.*Busy`, `pauseToggleLocked`, `uploadGeneration`) | re-entrancy guards | scroll actions | scroll actions | n/a | medium |

### 12.4 Rendering flow
`renderMatrices` repaints all matrix views from their frame buffers; `fitMatrix`/`scheduleMatrixFitRender` recompute cell size on resize (ResizeObserver). `renderState` updates badges/diagnostics. `updateScrollUi` recomputes scroll button enable/labels from `scroll.*`. DPS (`updateDps`/`estimateFrameWatts`) warns >40 W.

### 12.5 Performance / desync risks (WebUI)
- 5 matrix views × 370 DOM cells; `renderMatrices` repaints frequently. `setDom*IfChanged` helpers minimize layout thrash for scroll UI but matrices repaint wholesale.
- `ark12.json` is ~2.5 MB JSON parsed in the browser (lazy) — first scroll-page entry can jank.
- Scroll preview timer (`advanceScroll` via `setInterval`) free-runs and can diverge from firmware index.

---

## 13. Concurrency, Timing, and Race Conditions

### 13.1 Mechanisms
- **FreeRTOS mutexes** (`sync.cpp`): `Frame`, `Scroll`, `Storage`, `HardwareBus`. Documented global order **Scroll → Frame → Storage → HardwareBus**; code intentionally avoids nesting.
- **Spinlocks** (`portMUX`): `sPowerStatusMux` (tear-free power snapshot), `sAnimMux` (overlay state), `ledRenderRequestMux` (ISR-safe render flag).
- **Task notify**: Core-0 wakes Core-1 render task via `notifyScrollRenderTask`.
- **Core affinity**: build flags pin Arduino/event/WebServer/buttons/power to Core 0; render/scroll to Core 1 — explicitly to protect WS2812/RMT timing from network load.

### 13.2 Concurrency table

| System | Timing mechanism | Shared state | Protection | Possible race/desync | Evidence |
|---|---|---|---|---|---|
| LED render | Core-1 task, `LED_RENDER_MIN_GAP_US=2500` pacing | `frameBits`, color, brightness | `frameMutex` snapshot + `HardwareBus` for show | none observed (snapshot under lock) | `led_renderer.cpp:211` |
| M370 queue | Core-0 only, ≥33 ms | `m370FrameQueue` | **no lock** — Core-0 invariant | corruption if ever called off Core 0 | `led_renderer.cpp:27` comment |
| Scroll playback | Core-1 interval | scroll meta + index | `scrollMutex` | browser preview drift (different timer) | `scroll.cpp:31` |
| Power | Core-0 1 s | `powerStatus` | `sPowerStatusMux` for consumer fields | minor (some fields written outside lock) | `power_monitor.cpp:318` |
| Overlay | Core-0 service + Core-1 read | `sAnim` | `sAnimMux` | power read correctly hoisted out of lock | `button_animations.cpp:543` |
| WebUI frame/cmd | browser `setTimeout` queues | `state`/`scroll` | busy flags, `uploadGeneration` | stale upload, pause/resume races | `app.js:4898` |
| Status poll | adaptive `setInterval` | `state`/`scroll` | in-flight guards | overlapping summary vs full | `app.js:5734` |

### 13.3 Specific questions
- **Can WebUI commands modify frame state while the LED task renders?** Yes, but safely: writers hold `frameMutex`; the render task snapshots `frameBits`+color+brightness under the same lock before output (`renderCurrentFrameToLedStrip:220`).
- **Can scroll text and manual/auto playback conflict?** They are mutually exclusive by design: starting scroll forces manual and sets `restoreAutoAfterScroll`; manual/auto face actions call `stopFirmwareScroll` first (`buttons.cpp:117`, `web_api.cpp commandTerminateOtherActivities`). Browser `terminateOtherActivities` mirrors this.
- **Can stop/pause/resume race?** On firmware, all run on Core 0 cooperatively (no overlap). On the browser, `scroll.commandBusy`/`pauseToggleLocked`/`stopBusy` serialize them; an unconfirmed command keeps prior state and waits for the next poll.
- **Can brightness change during a show?** The render task reads brightness under `frameMutex` before `strip.setBrightness`; no partial application.
- **Can the WebUI preview differ from firmware?** Yes — the strongest desync point. During active scroll the browser advances its own preview timer; the firmware advances independently; only periodic `scrollFrameIndex` from polling nudges the browser. After reload, exact frame binding requires generator+fontId+frame-count match, else the preview is "reference only" with a warning.
- **Can a reload lose state firmware still has?** Browser-only state (busy flags, unsent textarea edits) yes; firmware state is recovered by polling + `/api/scroll/meta`. Scroll cache itself is RAM-only and survives reload but not reboot.
- **Can button input and WebUI command conflict?** Both mutate `runtimeState` on Core 0 cooperatively, so no torn state; logically the last writer wins and the browser reconciles on next poll.
- **Critical sections correctly scoped?** Mostly. The previously-reported nested-spinlock (audit M1) is fixed: `serviceButtonAnimations` snapshots power **outside** `sAnimMux` (`button_animations.cpp:543-549`). The HTTP-path scroll handlers do follow the "serialize outside the lock" rule (e.g. `commandStartScroll` extracts `timelineId` to a stack buffer before locking). **However, the "no heap `String` writes inside `frameMutex`/`scrollMutex`" contract is not fully honored in `faces.cpp`:** `setFirmwareScrollPauseFlag` copies/compares Arduino `String` values inside `withScrollLock` (`faces.cpp:304`, `oldPlayback = runtimeState().playback`), and `startFirmwareScroll` assigns `runtimeState().mode`/`playback` String literals inside `withScrollLock` (`faces.cpp:362,371`). These run only on Core 0 and the strings are short (SSO-eligible), so it is not a known live bug, but it does violate the documented lock contract and could allocate under the lock. This should be flagged as a P2 cleanup.

---

## 14. Hidden, Dead, Duplicate, or Unclear Code

| Issue type | File/function | Evidence | Impact | Recommendation |
|---|---|---|---|---|
| Dead function | `applyPackedFrame` (`led_renderer.cpp:357`) | grep: only definition+declaration, no callers; `applyPackedFrameImmediate` used everywhere | none (harmless) | remove or document why retained |
| Stale constant | `DEFAULT_STARTUP_FACE_ID="face_07_triangle_eyes_frown"` (`WEBUI_CONFIG.faces.startupFaceId`) | no face has that id; real startup is `face_08_triangle_eyes_frown`; face_07 id is `face_07_wide_eyebrows_tiny_mouth` | none today (fallbacks mask it) | fix to `face_08...` or remove; rely on file's `startupDefaultId` |
| Stale audit doc | `AUDIT_REPORT.md` C1/M1/L1 | C1 overflow guarded at `storage.cpp:289`+`validateSavedFaces:193`; L1 `lastReason` now `[M370_FRAME_REASON_CHARS=64]` (`state.h:84`); M1 hoisted (`button_animations.cpp:543`) | misleading to readers | re-run/refresh audit; mark fixed items |
| Intentional no-op | `updateBatteryCalibration` (`power_monitor.cpp:170`) | body discards `vbat`/`freezeCalibration`; comment says auto-calibration disabled | dead params; only manual reset moves window | keep but drop unused params or comment clearly (it does comment) |
| Minor display bug | battery overlay phase 2 (`button_animations.cpp:318`) | charge voltage drawn as `"%.1f"` with no unit, unlike phase 1 `"%.1fV"` | cosmetic | add `V`/distinct unit |
| Duplicated state | face library (firmware `autoFaces_` vs browser `faceLibraryDocument`) | both hold full list; orders re-assigned client-side | drift if writes fail mid-way | single canonical save path + post-write reload (already partially done) |
| Duplicated frame logic | M370 encode/decode in both C++ and JS | `led_renderer.cpp` vs `frameToM370/m370ToFrame` + scroll gen | must stay bit-compatible | covered by `tools/test_m370_boundary.js`; add JS↔C++ golden vectors |
| UI-only / simulated | debug ADC inputs (`#battery-v/#charge-v`) | label says "浏览器本地模拟,不读取真实硬件" | could confuse | clearly labeled already |
| Unclear ownership | `scroll.framesTimelineId` binding rules (`D5/E4/C5`) | spread across `restoreScrollPreviewIfNeeded`, `applyFirmwareRuntimeState`, `prepareTextScrollTimelineForRestoreAsync` | high cognitive load | extract a documented state machine |
| Large planning docs | `plan.md` (347 KB), `refactor_plan.md` (163 KB), `PAGE_6_5_DEBUG_REWRITE_PLAN.md` (79 KB) | not runtime | repo bloat | move to `docs/` or archive |

No firmware endpoint is un-called by the WebUI, and no WebUI call targets a missing endpoint — the 7 endpoints + command table are fully matched (`API_ENDPOINTS` in `app.js` mirror `server.on` registrations). `terminate_other_activities` and `battery_overlay` are firmware-real and UI-reachable.

---

## 15. Text Architecture Diagrams

### 15.1 High-level
```
┌────────────────────────── Browser (data/app.js) ──────────────────────────┐
│  state{}  scroll{}  firmware{}   matrices×5   face library copy            │
│  applyFirmwareRuntimeState()  ⇄  frameSendPump / buttonCommandPump / aux   │
└──────────────▲───────────────────────────────────────────────┬───────────┘
               │ HTTP/JSON over SoftAP (rina.io, 192.168.x)     │
        GET /api/status?since=v, /api/power, /api/scroll/meta   │ POST /api/frame,
               │                                                │ /api/command, /api/scroll,
┌──────────────┴────────────────────────────────────────────────▼───────────┐
│                      Firmware WebServer (web_api.cpp, Core 0)               │
│  handleApiStatus/Power/Frame/Scroll/ScrollMeta/Command/SavedFaces          │
└───────┬───────────────────────┬───────────────────────┬───────────────────┘
        │ touchRuntimeState()    │                       │
┌───────▼─────────┐   ┌──────────▼──────────┐   ┌────────▼─────────┐
│ RuntimeStore     │   │ faces/scroll FSM    │   │ storage (LittleFS)│
│ (state.h)        │   │ (faces.cpp)         │   │ saved_faces/json  │
│ frameBits, meta, │   └──────────┬──────────┘   └──────────────────┘
│ scroll cache     │              │ mutex-guarded shared state
└───────┬──────────┘              │
        │ frameMutex/scrollMutex  │
┌───────▼──────────────────────────▼─────────────────────────────────────────┐
│ Core 1 LED render/scroll task (scroll.cpp) → renderCurrentFrameToLedStrip   │
│ Core 0 drivers: buttons.cpp (GPIO) · power_monitor.cpp (ADC) · overlays     │
└───────┬───────────────────┬───────────────────────┬────────────────────────┘
        ▼ WS2812 (GPIO2)     ▼ ADC GPIO10/1           ▼ Buttons GPIO17..42
```

### 15.2 WebUI command flow
```
User action → DOM event → JS handler (e.g. setBrightness)
 → optimistic local apply (applyBrightnessLocal)
 → sendAuxCommand / pump.enqueue → apiPost(/api/command|/api/frame)
 → handleApiCommand → route handler → setBrightness()/setColor()/setMode()...
 → withFrameLock mutate runtimeState → touchRuntimeState() → showCurrentFrameNoLock()
 → Core-1 render → strip.show()  (hardware)
 → JSON reply → applyFirmwareRuntimeState() → state.* → renderState/renderMatrices
```

### 15.3 Hardware event flow
```
Button/ADC event
 → Core-0 service (serviceHardwareButtons / servicePowerMonitor)
 → runButtonAction / sampleBattery → mutate runtimeState/powerStatus (+ touchRuntimeState)
 → LED effect (face/brightness/overlay) via requestLedRender → Core-1 show
 → status version bumped
 → WebUI poll /api/status|/api/power → applyFirmwareRuntimeState/applyPowerData → UI refresh
```

### 15.4 Scroll text flow
```
Text input (#scroll-text)
 → buildTextScrollBitmap (Ark Pixel glyphs) → extractFrameFromTextImage → scroll.frames[]
 → uploadFirmwareScrollTimeline → chunked POST /api/scroll (timelineId, chunkIndex, sourceText@chunk0)
 → handleApiScroll: validate → write scrollFrameBits[] → uploadComplete when framesReceived≥total
 → POST /api/command start_scroll → startFirmwareScroll → playback="scroll"
 → Core-1 scrollRenderTask advances scrollFrameIndex on interval → strip.show()
 → reload: GET /api/scroll/meta → restoreScrollTextFromFirmware (refill text, guard unsent edits)
          → restoreScrollPreviewIfNeeded (regenerate frames; bind framesTimelineId iff exact match)
          → re-sync by frameIndex
```

### 15.5 Saved face flow
```
Create/edit/reorder/delete in 6.2/6.3
 → buildUnifiedFaceDocument → persistFaceDocuments
     ├ (optional) File System Access write to local saved_faces.json
     └ POST /api/saved_faces {document}
 → validateSavedFaces (category, ≤128, ≥1 default, valid M370)
 → writeSavedFaces (atomic temp+rename) → ++savedFacesWrites → touchRuntimeState
 → loadSavedFaces(false) reloads table, re-applies current face
 → reply → WebUI renderSavedFaces (list refresh)
```

---

## 16. Risks and Refactor Recommendations

| Priority | Area | Problem | Evidence | Recommended fix |
|---|---|---|---|---|
| P1 | Scroll sync | Browser preview timer free-runs vs firmware index; after reload exact binding is fragile (generator/fontId/count gates) | `advanceScroll` (`app.js:8729`), `restoreScrollPreviewIfNeeded` (`:9198`) | Make firmware push current `scrollFrameIndex` in summary polls authoritative for the preview during active playback; or drive preview purely from polled index when `firmwareBacked` |
| P1 | Scroll FSM complexity | `scroll{}` has ~30 fields + many busy flags; restore/identity logic split across 5 functions | `app.js:3565`, `4837`, `9055`, `9198` | Extract an explicit, documented scroll state machine module with one transition function |
| P1 | State duplication | Face library duplicated in firmware RAM and browser; order reassigned client-side; partial-failure divergence | `buildUnifiedFaceDocument`/`autoFaces_` | Always reload from firmware after a successful POST; treat firmware file as canonical, browser as view |
| P2 | Brightness echo | 2 s echo-suppression window can show stale value if a real change arrives mid-window | `applyFirmwareRuntimeState:4726` | Use a per-control "last local intent" token compared to firmware version instead of a wall-clock window |
| P2 | Rendering cost | 5×370 DOM matrices repainted wholesale; 2.5 MB font parse on first scroll entry | `renderMatrices`, `loadArkPixelFontTable` | Diff-based cell updates; stream/precompute glyph table or ship a compact binary font |
| P2 | Frame queue lock | `m370FrameQueue` is lock-free by Core-0 invariant only | `led_renderer.cpp:27` | Add a static-assert/comment guard or a lightweight lock if any caller might move off Core 0 |
| P2 | Lock contract violation | `String` copies/assignments inside `withScrollLock` despite the "serialize outside the lock" contract | `faces.cpp:304` (`oldPlayback`), `:362/:371` (`mode`/`playback`) | Move String reads/writes outside the scroll lock (snapshot scalars under lock, mutate Strings after), or relax the documented contract |
| P3 | Dead/stale code | `applyPackedFrame` unused; `DEFAULT_STARTUP_FACE_ID` wrong; stale `AUDIT_REPORT.md` | §14 | Remove dead fn, fix constant, refresh audit |
| P3 | Cosmetic | Battery overlay phase-2 voltage missing unit | `button_animations.cpp:318` | Add unit suffix |
| P3 | Docs/bloat | 590 KB of planning markdown at repo root | `plan.md` etc. | Move to `docs/`/archive |
| P3 | Protocol parity | M370 + scroll-frame encoding duplicated in C++ and JS | §14 | Shared golden test vectors covering both decoders |

**Missing abstraction boundaries:** a single "scroll session" object on each side; a "device state mirror" reducer in the browser instead of one 280-line `applyFirmwareRuntimeState`. **Suggested module boundaries:** firmware `scroll_session.cpp` (split scroll FSM out of `faces.cpp`), browser `scrollMachine.js` + `deviceMirror.js`. **Suggested naming:** distinguish `firmwareScroll*` (device) from `scroll.*` (browser) consistently; rename `applyPackedFrame`/`applyPackedFrameImmediate` to make the queued vs immediate distinction obvious (or delete the unused one). **Suggested tests:** loader fixture with >128 faces (regression for the formerly-critical overflow), JS↔C++ M370 golden vectors, scroll upload conflict (409 retry) integration test, battery LUT boundary test. **Suggested logging:** structured scroll-restore trace already exists (`logScrollRestoreDebug`); add a firmware-side counter for scroll cache invalidations and a `scrollFrameIndex` sample in summary status (already present) used to detect drift.

---

## 17. Files to Read First (for a new engineer)

1. `src/config.h` — every constant, pin, and matrix-geometry fact lives here.
2. `src/state.h` — the shared `RuntimeStore` and the lock/ownership contract comments.
3. `src/main.cpp` — exact bring-up order and the Core-0 loop.
4. `src/web_api.cpp` — the entire HTTP contract and command dispatch table.
5. `src/faces.cpp` + `src/scroll.cpp` — the mode/scroll state machine and Core-1 render task.
6. `src/led_renderer.cpp` — M370 encoding, the frame queue, and the actual pixel output.
7. `data/app.js` in this order: `WEBUI_CONFIG` (top), `state/firmware/scroll` objects (`:3454`), `applyFirmwareRuntimeState` (`:4586`), `makeRateLimitedQueue` (`:4898`), `bootstrapWebUi` (`:10717`), then the scroll cluster (`:8271`–`:9304`).
8. `src/power_monitor.cpp` — the most self-contained subsystem, good warm-up.

---

## 18. Open Questions / Things the Code Does Not Make Clear

1. **Scroll preview drift policy.** The code accepts that the browser preview and physical LEDs run on independent timers during active scroll, but there is no explicit spec for how much drift is acceptable or when a re-sync is forced. The summary poll carries `scrollFrameIndex`, but `advanceScroll` overwrites it every local tick — is the local timer meant to be cosmetic only?
2. **`B6+B3` network-info action is WebUI-only.** The debug UI exposes a `B6B3` button (`app.js:10553`) that merely calls `syncRuntimeStateFromFirmware("debug_gpio_B6B3_network_info")` — i.e. it re-fetches `/api/status` to refresh the network panel. There is **no** corresponding firmware GPIO combo or LED overlay (`button_animations.cpp` only has mode/interval/brightness/battery kinds; `buttons.cpp` only wires `B3B1`/`B3B2`). So the on-device hardware combo does nothing network-related; it is unclear whether a physical network-info overlay was ever intended.
3. **`MAX_AUTO_FACES` vs UI.** Firmware caps at 128 faces and now rejects more; the browser does not appear to warn the user before a save that would exceed this. Intended UX on overflow is unspecified.
4. **`updateBatteryCalibration` future intent.** It is a deliberate no-op with unused params — is auto min/max calibration meant to return, or should the scaffolding be removed?
5. **Single-core fallback fidelity.** If `initSyncPrimitives()` fails, the design drops to single-core (`loop()` renders directly) and disables the scroll task. The behavioral differences (scroll unavailable, timing) are not documented for the user/UI.
6. **`faceId` echo in `/api/frame`.** `handleApiFrame` accepts an optional `faceId` to sync `autoFaceIndex`, but the browser's normal custom/parts sends don't pass it; it's unclear which client path (if any) uses this.
7. **Stale `AUDIT_REPORT.md`.** Because the doc lists already-fixed bugs, it is unclear whether there is a newer audit of record or whether the fixes were validated against the same reproduction steps.
