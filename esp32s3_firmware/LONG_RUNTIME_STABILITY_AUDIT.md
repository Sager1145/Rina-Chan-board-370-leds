# Rina-Chan 370-LED Firmware — Long-Runtime Stability Audit

**Target:** ESP32-S3 / PlatformIO / Arduino, 370× WS2812B, 8 MB OPI PSRAM, LittleFS (5.9 MB).
**Scope:** every `src/*.cpp/.h` file (~9,200 LOC) read in full.
**Bottom line:** This codebase is unusually well-defended against exactly the failure modes you describe. The render path, scroll cache, lock hierarchy, upload bounds, and serial logging are already engineered for long uptime. There is **no per-frame, per-poll, or per-scroll-cycle heap leak**, and **no unbounded growth** anywhere I could find. The residual long-runtime risks are a short list, dominated by **internal-DRAM fragmentation from per-request JSON `String` churn** and a **blocking raw-socket read on `/api/frame_bin`**. Both are fixable without architectural change.

Severities: **P1** = plausible "crash/freeze after a while," **P2** = real but mitigated, **P3** = hardening / instrumentation.

---

## 1. Architecture map

### Entry points
| Context | Core | Where |
|---|---|---|
| `setup()` | 0 | `main.cpp:38` — HW init, mutexes, scroll buffer alloc, render task spawn, AP+web start |
| `loop()` (cooperative scheduler) | 0 | `main.cpp:105` — buttons → frame queue → web → buttons → slow-publish → serial → anims → power → deferred-face → auto; ends `vTaskDelay(1)` |
| `scrollRenderTask` (FreeRTOS, the **only** `strip.show()` owner in normal operation) | 1 | `scroll.cpp:25`, spawned `scroll.cpp:75`, stack 6144 B, prio 3 |
| HTTP handlers | 0 | `web_api.cpp` — run inside `server.handleClient()` from `webServerTick()` (`web_api.cpp:1895`) |
| DNS captive portal | 0 | `web_api.cpp:1897` |
| Button ISR? | — | **None.** Buttons are polled (`buttons.cpp:269`), not interrupt-driven. `requestLedRender()` has an ISR-safe path but no ISR currently calls it. |
| Serial console | 0 | `serial_console.cpp:1358` — drains only buffered bytes, no blocking read in normal path |
| Power/ADC | 0 | `power_monitor.cpp:457` |

There is **no `xTaskCreate` other than the render task**, no software timers, and no ISRs — so the entire concurrency surface is *two contexts*: the Core-0 cooperative loop (incl. all HTTP/serial/buttons/power) and the Core-1 render task. That dramatically shrinks the race surface and the code uses it well.

### Data flow
- **WebUI → state → frame buffer → LEDs:** `POST /api/frame` (or `/api/frame_bin`) → parse → `applyM370*`/`applyLedDeltasImmediate` → write `runtimeFrameBits()` (static 47 B) under **frameMutex** → `requestLedRender()` sets a flag + notifies Core 1 → render task copies frame under frameMutex, releases, then `strip.show()` under **HardwareBus** lock.
- **Scroll upload → cache → render:** `POST /api/scroll` streams M370 strings into the single pre-allocated **PSRAM scroll buffer** (`scrollFrameBits_`, 3072×47 ≈ 141 KB) under **scrollMutex**; render task advances `scrollFrameIndex` and `memcpy`s the active frame out under scrollMutex, then into `frameBits` under frameMutex.
- **Buttons → state → LEDs:** poll → debounce → `runButtonAction()` → mode/face/brightness changes → frame apply + overlay request.
- **Saved faces:** LittleFS JSON → parsed into fixed `RuntimeFace autoFaces_[128]` array; auto mode cycles the index on a timer.

---

## 2. P1 findings — most likely "after a while" causes

### P1-A. Admission control checks free heap, not the *largest free block* — fragmentation can defeat it
**Files:** `web_api.cpp:190` (`sendJsonDocument`), `web_api.cpp:197` (`sendError`), `web_api.cpp:220` (`httpRejectIfLowMemory`), `config.h:151`.

```cpp
// web_api.cpp:190
static void sendJsonDocument(int status, JsonDocument& doc) {
    String out;                 // <-- internal DRAM String
    serializeJson(doc, out);    // grows by reallocation (0.5→1→2→4 KB ...)
    addCorsHeaders();
    server.send(status, CONTENT_TYPE_JSON_UTF8, out);  // WebServer copies it again
}
```
```cpp
// web_api.cpp:220
static bool httpRejectIfLowMemory(const char* what) {
    const uint32_t freeHeap = ESP.getFreeHeap();          // <-- total free, not contiguous
    if (freeHeap >= HTTP_MIN_FREE_HEAP_BYTES) return false;
    ...
}
```

**Why it can crash long-term.** The JSON *document* is correctly in PSRAM (`PsramJsonDocument`), but every response is **serialized into an Arduino `String` in internal DRAM and then copied again by `WebServer::send`**. A WebUI left open polls `/api/status` ~1×/s (and `/api/scroll/meta`, `/api/power`), each producing a ~2–4 KB DRAM String that grows by doubling and is freed. Internal DRAM (the ~300 KB shared with the WiFi/LwIP stack) slowly **fragments**: free bytes stay high but the *largest contiguous block* shrinks. The 40 KB admission floor reads `getFreeHeap()`, so a heap with 50 KB free but an 8 KB largest block **passes the guard**, then a contiguous allocation (a bigger response String, or an LwIP/WiFi buffer) fails and panics — classically "on refresh," because a refresh fires a burst of concurrent requests.

**Frequency:** every dynamic response (per poll, per command, per upload chunk). **Time to symptom:** hours-to-days of an open WebUI, sooner if multiple clients or frequent refreshes.

**Fix (two layers, do both):**
1. Gate on the contiguous block, not just free bytes:
   ```cpp
   static bool httpRejectIfLowMemory(const char* what) {
       const uint32_t freeHeap = ESP.getFreeHeap();
       const uint32_t largest  = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
       if (freeHeap >= HTTP_MIN_FREE_HEAP_BYTES && largest >= HTTP_MIN_LARGEST_BLOCK_BYTES)
           return false;   // add HTTP_MIN_LARGEST_BLOCK_BYTES (e.g. 20480) to config.h
       ...
   }
   ```
2. Stop the double DRAM allocation. Serialize straight to the client instead of to a String:
   ```cpp
   static void sendJsonDocument(int status, JsonDocument& doc) {
       addCorsHeaders();
       server.setContentLength(measureJson(doc));
       server.send(status, CONTENT_TYPE_JSON_UTF8, "");
       // chunked writer over server.client() via ArduinoJson's WriteBufferingStream,
       // or reserve out to measureJson(doc) once: String out; out.reserve(measureJson(doc)+1);
   }
   ```
   At minimum `out.reserve(measureJson(doc) + 1)` removes the doubling-realloc churn (the single biggest fragmentation contributor) for one line of change.

---

### P1-B. `/api/frame_bin` does blocking raw-socket reads with no size guard — Core-0 freeze vector
**File:** `web_api.cpp:898–1003` (`handleApiFrameBin`), reads at `:908`, `:948`, `:966`, `:977`.

```cpp
WiFiClient client = server.client();
uint8_t header[6];
if (client.readBytes(header, 6) != 6) { ... }      // blocks up to client timeout
...
for (uint16_t i = 0; i < count; i++) {             // count up to 255
    uint8_t entry[3];
    if (client.readBytes(entry, 3) != 3) { ... }   // blocks per entry
}
```

**Why it freezes.** `WiFiClient::readBytes` blocks up to the client's stream timeout (default ~1000 ms) waiting for bytes. The whole Core-0 cooperative loop — HTTP, button polling, the M370 frame queue, power, serial — runs single-threaded; while this handler waits, **none of it advances**. A slow, lossy, or malicious client (or just Wi-Fi congestion) that dribbles a delta packet forces up to *255 sequential blocking reads*, each able to stall for the timeout. Result: WebUI unresponsive, buttons laggy/missed, frame queue not serviced. (Core-1 scroll keeps rendering, so the panel may keep scrolling while everything else is frozen — which matches "becomes unresponsive but LEDs still move" reports.) Unlike the JSON endpoints, this path has **no `httpRejectIfLowMemory` and no body-size cap**.

**Fix:**
- `client.setTimeout(50);` at the top of the handler (bounds each read).
- Validate `count`/`type` and total expected bytes *before* the read loop; reject early.
- Optionally only read what's already buffered (`client.available()`) and bail to a retryable 503 otherwise.

---

## 3. P2 findings — real but currently mitigated

### P2-A. Large stack arrays in HTTP handlers + recursive JSON validator on the loopTask stack
**Files:** `web_api.cpp:749–750` (`deltaIndices[370]`+`deltaValues[370]` ≈ **1110 B**), `web_api.cpp:972–973` (`indices[256]`+`values[256]` = **768 B**), recursive `skipJsonValue`/`skipJsonObject`/`skipJsonArray` (`web_json.cpp:227–301`, depth ≤ 32).

HTTP handlers execute on the **Arduino `loopTask`** (default 8 KB stack unless `CONFIG_ARDUINO_LOOP_STACK_SIZE` is overridden — I didn't find an override, so assume 8 KB). A single `/api/frame` request can stack the 1110 B delta scratch arrays **plus** up to ~32 levels of JSON-validation recursion **plus** several `String` temporaries (`requestBody()` copy, `normalizedM370`, etc.). I found **no stack-overflow proof**, but also **no high-water instrumentation**, so the margin is unknown — and stack overflow presents exactly as your symptom set (random crash/reboot under load).

**Fix:** the delta scratch buffers are only ever touched by Core-0 handlers, so make them `static` (removes 1110 B / 768 B from the stack entirely), and add `uxTaskGetStackHighWaterMark` logging for the loopTask (see §7). Consider lowering `JSON_MAX_DEPTH` from 32 to ~12 — no legitimate payload here nests that deep.

### P2-B. LED panel stalls during flash writes (by design, but visible)
**Files:** `sync.cpp:97` (`lockStorage` also takes HardwareBus), `storage.cpp:58` (`writeStringToFileLocked`).

`writeStringToFileLocked` holds Storage+HardwareBus across `file.print(content)` + flush + close + rename of the whole serialized JSON (saved faces up to ~64 KB). Because Storage is deliberately coupled to the HardwareBus mutex to keep a flash-cache-disable from garbling WS2812 timing, `strip.show()` is blocked for the **entire** write — tens to low-hundreds of ms on LittleFS. This is a **freeze, not a crash**, and only on user-triggered saves; the design trade-off is correct. If the visible hitch matters, chunk the write and yield between chunks (releasing/re-taking the lock per chunk, as `streamFileChunked` already does for reads). Note: battery-calibration auto-save is effectively disabled (`updateBatteryCalibration` is a no-op, `power_monitor.cpp:187`), so there is **no periodic background flash write/wear** — good.

### P2-C. Synchronous ADC sampling blocks Core 0 ~8 ms, sometimes inside an HTTP handler
**File:** `power_monitor.cpp:41` (`readTrimmedAdcMilliVolts`: 16×`delayMicroseconds(250)`), called for battery + charge ≈ **8 ms**; invoked from `handleApiStatus` (`web_api.cpp:489`) and `handleApiPower` (`:627`).

Bounded to ~1×/s and skipped during live-frame activity (`isLiveFrameActivityRecent`), so minor — but it does insert ~8 ms Core-0 stalls onto the HTTP path. Prefer servicing power only from the cooperative loop and never calling `servicePowerMonitor()` synchronously from a request handler.

---

## 4. P3 findings — hardening

- **`scrollSessionMarkStoppedByButton` writes heap `String`s without a lock** (`scroll_session.cpp:257–264`). Safe *today* because writer (button/HTTP) and reader (`addScrollStopEvent`, status builder) are both Core 0 — but it's the one shared field-family relying on "both happen to be Core 0" rather than a mutex. Keep that invariant documented, or convert `scrollStopEventButton/Source/Reason` to fixed `char[]` to make it lock-free-safe by construction.
- **Serial test helpers block** (`serial_console.cpp:877` `delay(2)` loop in `pumpHardwareButtons`, `:1305` `delay(80)` before reboot). Only reachable via explicit `test`/`reboot` serial commands, not a production path — leave as-is unless you run HIL tests on a live board.
- **`requestBody()` copies the whole POST body into a DRAM `String`** (`web_api.cpp:359`) before parsing (up to 64 KB for saved faces). Peak DRAM, freed after; already guarded by size caps and admission control. Fine, just be aware it's a transient internal-DRAM spike that interacts with P1-A fragmentation.

---

## 5. Heap / PSRAM buffer inventory

| Buffer | Size | Lifetime | Region | Bounded? | Alloc-fail handled? |
|---|---|---|---|---|---|
| `frameBits_` | 47 B | whole run | static SRAM | n/a | n/a |
| `scrollFrameBits_` | 3072×47 ≈ **141 KB** | whole run (alloc once) | **PSRAM**, SRAM fallback | yes (`MAX_SCROLL_FRAMES`) | yes → 507 (`state.cpp:43`) |
| `scrollSourceText_` | 4097 B | whole run | PSRAM/SRAM | yes (`MAX_SCROLL_TEXT_BYTES`) | yes → 507 (`state.cpp:20`) |
| `autoFaces_[128]` | 128×`RuntimeFace` | whole run | static SRAM | yes (`MAX_AUTO_FACES`) | extra faces dropped (`storage.cpp:302`) |
| render `localFrame` | 47 B | per tick | **stack (Core 1)** | n/a | n/a |
| render `overlayRgb` | 1110 B | whole run | **static** (not stack) | n/a | n/a |
| status JSON doc | 4608–6656 B | per request | **PSRAM** | yes | overflow→507 on meta |
| status response `String` | 2–4 KB | per request | **internal DRAM** | grows by doubling | ⚠️ see P1-A |
| `/api/scroll/meta` text copy | 4097 B | per request | PSRAM (SRAM fallback) | yes | yes, freed every path (`:1337–1372`) |
| static-file stream buffer | 8192 B (1024 during scroll) | per request | DRAM heap, **512 B stack fallback** | yes | yes (`web_api.cpp:158`) |
| frame-bin delta scratch | 768 B | per request | **stack** | yes (255) | n/a — see P2-A |
| LED history ring | 16×`LedCmdRecord` | whole run | static | yes | n/a |

No buffer is allocated per-frame or per-scroll-cycle. The scroll cache is the only large allocation and it is **allocated exactly once** and reused; send/stop/clear/pause/step/refresh only memset/rewrite it in place (`scroll_session.cpp`), so there is **no leak and no fragmentation from scroll churn** — a common failure mode you specifically worried about, and it's already handled correctly.

---

## 6. What is already correct (so you don't chase ghosts)

- **One `show()` owner.** Only the Core-1 render task calls `strip.show()` in normal operation (`scroll.cpp` → `renderCurrentFrameToLedStrip`), plus the single-core fallback in `loop()` when mutexes fail. No reentrancy.
- **Copy-before-show.** `renderCurrentFrameToLedStrip` (`led_renderer.cpp:271`) copies frame + brightness + color under frameMutex, *releases the lock*, then transmits — no partial frame is ever latched, and the lock is never held across `strip.show()`.
- **Zero allocation in the render tick.**
- **Lock hierarchy** Scroll→Frame→Storage→HardwareBus is documented (`sync.h:7`), consistently ordered, never nested; Storage⊇HardwareBus coupling prevents flash-cache-disable from corrupting WS2812 timing.
- **Upload validation is pre-flight** (`web_api.cpp:1151`): frames are fully validated *before* any cache state is mutated; bad data invalidates the playback cache but preserves source text for recovery; frame index is always `% scrollFrameCount` (no overflow); `totalFrames`, body size (16 KB scroll / 64 KB faces), and text length (4096 B) are all hard-capped.
- **JSON failures handled** (400), depth-limited (32), integer-overflow-guarded (`web_json.cpp:350`).
- **Watchdog fed:** `loop()` ends in `vTaskDelay(1)`; render task blocks on `ulTaskNotifyTake(..., pdMS_TO_TICKS(1))`. Neither spins.
- **Serial logging is non-blocking** (`serial_log.cpp:96`): writes only if the whole line fits the TX buffer *now*, short-circuits entirely when no host is connected, fixed 16-entry ring — no per-frame Serial on the hot path.
- **Cross-core power reads** are spinlock-protected for tear-free snapshots (`power_monitor.cpp:488`).
- **Immutable cache headers** stop a refresh from re-streaming ~100 KB of assets out of flash (`web_api.cpp:97`).

---

## 7. Diagnostics to add (you asked for this in item 11)

A drop-in `DEBUG_HEALTH` module is included as **`src/health_diagnostics.h` / `.cpp`** alongside this report. It logs, on a timer and on boot:

- `esp_reset_reason()` once at boot (tells you *why* the last crash happened — `TASK_WDT`, `INT_WDT`, `PANIC`, `BROWNOUT`...).
- `getFreeHeap`, `getMinFreeHeap`, `getMaxAllocHeap`.
- `heap_caps_get_free_size(MALLOC_CAP_8BIT)` and **`heap_caps_get_largest_free_block(MALLOC_CAP_8BIT)`** (the fragmentation metric that P1-A turns on).
- PSRAM free + largest block.
- Render-task and loop-task **stack high-water marks** (`uxTaskGetStackHighWaterMark`).
- Current scroll frame count + the existing `framesDropped` counter.

Wire-up: `#include "health_diagnostics.h"`, call `healthDiagnosticsBegin()` at the end of `setup()`, and `serviceHealthDiagnostics()` once per `loop()`. Set `#define DEBUG_HEALTH 1` to enable; `0` compiles it to nothing.

**Recommended first move:** flash with `DEBUG_HEALTH 1`, leave the WebUI open, and watch `largestBlock8` over a few hours. If it trends down while `freeHeap` stays flat, P1-A is confirmed as your crash cause and the §2 fixes resolve it.

---

## 8. Priority order

1. **P1-A** — add largest-free-block to the admission guard + `reserve()`/stream JSON responses. *Highest impact on "crash after a while / on refresh."*
2. **P1-B** — `setTimeout` + size guard on `/api/frame_bin`. *Removes the Core-0 freeze vector.*
3. **P3 diagnostics** — ship `DEBUG_HEALTH` so the next incident is diagnosable, not guessed.
4. **P2-A** — make delta scratch arrays static + log stack high-water.
5. **P2-C / P2-B** — move ADC off the HTTP path; chunk flash writes if the hitch bothers you.
