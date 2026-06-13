# Rina-Chan Board — Audit-Level Refactor & Bug-Fix Plan

> Scope: full project — ESP32-S3 firmware (`src/*.cpp/.h`), Web UI (`data/app.js`, `data/index.html`, `data/styles.css`), and the WebUI↔firmware sync/protocol boundary.
> Status: **plan + concrete diffs**. Every bug item carries a reproduction path, a validation test, and a `Code change:` block with the actual current snippet and the proposed replacement. Every refactor item states what must remain unchanged and shows representative before/after code. (The "do not output replacement code" rule from the original brief is intentionally superseded here at the maintainer's request.)
> This document is independent of `plan.md` (which is a reconstruction spec, not a refactor plan).
>
> **Implementation status legend:** 🟢 = already applied to the codebase · ⬜ = proposed, not yet applied.

---

## 1. Scope of analysis

### 1.1 Firmware (C++, PlatformIO / Arduino / FreeRTOS)

| File | Why relevant |
|---|---|
| `src/main.cpp` | Entry points `setup()`/`loop()`. Defines the boot ordering and the Core-0 cooperative service order. Any reordering risk lives here. |
| `src/state.h` / `src/state.cpp` | `RuntimeStore` singleton, `RuntimeState`, scroll buffers, `stateVersion` publish cursor. Central mutable state; lock-ownership contract documented in headers. |
| `src/config.h` / `src/config.cpp` | All hardware pins, matrix geometry, timing constants, defaults, battery LUT. Source of magic numbers and `static_assert` invariants. |
| `src/sync.h` / `src/sync.cpp` | FreeRTOS mutex wrappers (`Frame`, `Scroll`, `HardwareBus`) and lock ordering contract (`Scroll → Frame → HardwareBus`). Governs every cross-core access. |
| `src/led_renderer.cpp/.h` | M370 codec, frame bit helpers, frame queue, color/brightness, ISR-safe render-request flag, physical render to `Adafruit_NeoPixel`. The timing-critical core. |
| `src/scroll.cpp/.h` | Core-1 FreeRTOS scroll/render task; drift compensation; the only place that drives continuous frame output. |
| `src/faces.cpp/.h` | Mode (auto/manual), saved-face apply, deferred face restore state machine, firmware scroll lifecycle (`start/stop/pause`). High state-coupling. |
| `src/buttons.cpp/.h` | GPIO debounce, combos (B3+B1/B2), repeat, semantic button dispatch shared by GPIO and API. |
| `src/button_animations.cpp/.h` | Overlay state machine (mode/interval/brightness/battery), `portMUX`-guarded `sAnim`, scroll system-pause coupling. |
| `src/power_monitor.cpp/.h` | ADC sampling, EMA, battery LUT, disconnect detection, calibration persistence, fast/slow web publish dirty flags. |
| `src/storage.cpp/.h` | LittleFS mount, atomic JSON write, settings + saved-faces load/save, validation. All file I/O holds `HardwareBus`. |
| `src/web_api.cpp/.h` | SoftAP/DNS, all HTTP routes, JSON serialization, the 277-line `/api/scroll` upload handler and the command dispatch table. Largest single file (1491 lines). |
| `src/web_json.cpp/.h` | Hand-rolled JSON field extraction over the raw request body (used to avoid full ArduinoJson parse for scroll uploads). |
| `src/psram_json.h` | PSRAM-first ArduinoJson allocator. |
| `src/utils.cpp/.h` | hex/color/millis helpers, UTF-8 + meta-id validators. |

### 1.2 Web UI (vanilla JS/CSS/HTML, no build step)

| File / region | Why relevant |
|---|---|
| `data/index.html` | DOM IDs/classes consumed by `app.js` and `styles.css`. The contract surface for any DOM refactor. |
| `data/app.js` lines 27–3190 | `WEBUI_CONFIG` + `EXPRESSION_PARTS` (≈3000 lines of static data: parts/colors/matrix geometry). Pure data; rarely the bug source but dominates file size. |
| `app.js` 3191–3630 | Derived constants, matrix index maps, the global `state` / `scroll` / `firmware` objects. Central UI state. |
| `app.js` 4255–4441 | `apiUrl` / `apiGet` / `apiPost` / `apiPostWithUploadProgress` — the only firmware transport entry points. |
| `app.js` 4450–4923 | Power apply + `applyFirmwareRuntimeState` (260-line merge of `/api/status` into UI state). The sync hub. |
| `app.js` 4933–5160 | Button-command and frame-send queues (rate-limited, drop-on-overflow). |
| `app.js` 5222–5361 | `terminateOtherActivities` / `guardBeforeOutput` / `setCurrentFrame` / `setColor` / `setBrightness` — mode mutual-exclusion + local echo. |
| `app.js` 5378–5956 | Boot sequence, status polling, power polling, timer lifecycle. |
| `app.js` 8331–9765 | Scroll subsystem: text→bitmap→frames, chunked timeline upload, start/pause/resume/stop/step, source-text restore from firmware. The most complex async region. |
| `app.js` 9937–10150 | `updateScrollUi` and DOM-diff helpers. |
| `app.js` 10150–10520 | UI init, first-page reveal, `bootstrapWebUi`. |
| `data/styles.css` | 3246 lines; layout/animation. Reviewed structurally; not the source of logic bugs but a refactor/maintainability surface. |

### 1.3 Sync / protocol boundary

`/api/status` (+`since`/`runtimeOnly`/`noFrame`/`summary`/`fullPower` query flags), `/api/power`, `/api/frame`, `/api/scroll`, `/api/scroll/meta`, `/api/command` (16-command dispatch table), `/api/saved_faces`. JSON field names, the `stateVersion`/`since` long-poll cursor, the `scrollStopEvent` sequence, and the timeline-upload state machine (`append`, `chunkIndex`, `totalFrames`, `uploadComplete`, `timelineId`).

---

## 2. Current behavior map

### 2.1 Startup / init flow (firmware)

`setup()` runs on Core 0 in this exact order (semantics depend on it):

1. Drive `LED_PIN` LOW, hold `LED_BOOT_DATA_LOW_HOLD_MS`, then `delayMicroseconds(LED_SIGNAL_RESET_US)` — prevents WS2812 latching floating data before the bus is driven.
2. `Serial.begin(115200)`, `delay(200)`, record `runtimeState().bootMs = millis()` (used later for `uptimeMs`).
3. `initRuntimeScrollFrameBuffer()` — allocates the ≈140 KB scroll frame buffer and the source-text buffer (PSRAM first, internal SRAM fallback). Allocation failure is non-fatal: text uploads later return 507.
4. `initSyncPrimitives()` — creates the three mutexes. Failure prints a warning but boot continues (locks then become no-ops — see Bug 7).
5. `initLedIndexMap()` — precomputes logical→physical serpentine map.
6. `ledStripBegin()` — `strip.begin()`, brightness default, clear, `show()` once under `HardwareBus`. Then `delay(LED_BOOT_CLEAR_HOLD_MS)`.
7. `setColorStateNoRender(DEFAULT_COLOR)` — updates color fields only, no render queued.
8. Mount LittleFS. On failure → `showFilesystemErrorPattern()` (12 red LEDs). On success → `loadRuntimeSettings()` then `loadSavedFaces(true)` (applies startup face via `applyM370`).
9. `renderCurrentFrameToLedStrip()` once synchronously (Core 0), then `consumeLedRenderRequest()` to drain the request the load just queued, then `delay(LED_BOOT_STARTUP_SETTLE_MS)`.
10. `startScrollRenderTask()` — pins the render/scroll task to Core 1.
11. `initHardwareButtons()` — reads initial pin levels (debounce baseline).
12. `initPowerMonitor()` — loads calibration, configures ADC, samples once (`force`).
13. `startAccessPoint()` then `startWebServer()` — AP/DNS/HTTP last, so a connecting client sees a fully-initialized state.

### 2.2 Main loop (firmware, Core 0)

`loop()` calls, in order, every ~1 ms (`vTaskDelay(1)`):
`serviceM370FrameQueue()` → `webServerTick()` → `serviceRuntimeSlowStatePublish()` → `serviceHardwareButtons()` → `serviceButtonAnimations()` → `servicePowerMonitor()` → `serviceDeferredFaceRestore()` → `serviceAutoPlayback()`.

Order is intentional: dequeue/publish frame first, then HTTP, then publish the slow UI cursor, then react to buttons/API for this tick, then run deferred restore and auto-advance.

### 2.3 Render task (firmware, Core 1)

`scrollRenderTask` loops:
1. `consumeLedRenderRequest()` → `mainTaskRenderPending`.
2. Under `Scroll` lock: if scroll active+not paused+frames>0+buffer ready, and the per-frame interval elapsed, advance `scrollFrameIndex` (mod count), apply drift compensation (`lastScrollFrameMs += interval` unless drift > 4 intervals, then resync to `now`), `memcpy` the new frame to a local stack buffer, set `hasScrollFrame`.
3. If `hasScrollFrame`: under `Frame` lock, re-check a render request; if no pending main render and scroll still active, copy the local scroll frame into `runtimeFrameBits()` and `++framesAccepted`; otherwise drop it.
4. If `shouldRender`, `renderCurrentFrameToLedStrip()`.
5. `ulTaskNotifyTake(pdTRUE, 1ms)` — wakes on `notifyScrollRenderTask()` or times out.

`renderCurrentFrameToLedStrip()`: snapshot frame bits + color + brightness under `Frame` lock into locals; enforce `LED_RENDER_MIN_GAP_US` since last `show`; apply brightness if changed; if a button-animation overlay is active, fill `overlayRgb` per-pixel, else map frame bits → color; `delayMicroseconds(reset)`, `strip.show()` under `HardwareBus`, record `lastLedShowUs`, `delayMicroseconds(reset)`.

### 2.4 User interaction flow (hardware buttons)

`serviceHardwareButtons()` (Core 0) debounces each pin (`BUTTON_DEBOUNCE_MS`), edges → `handleHardwareButtonPress/Release`. Press handles combos (B3+B1 / B3+B2 fire `B3B1`/`B3B2` and mark B3 consumed), and immediate fire for repeatable buttons (B1/B2 face, B4/B5 brightness). Release fires B3 (mode toggle) only if not combo-consumed, and drives B6 overlay (short = battery page, long = continuous battery). `serviceHardwareButtonRepeats()` re-fires held face/brightness buttons after delay. `runButtonAction()` is the shared semantic dispatcher for both `gpio` and `api_button` sources.

### 2.5 Data generation / transmission / preview (Web UI)

- Color/brightness/mode/interval: local echo via `state` + DOM, then `sendAuxCommand` to `/api/command`.
- Custom & parts pages: compose a `currentFrame`/`partsFrame`, `queueFirmwareFrame` → `frameToM370` → rate-limited POST `/api/frame`.
- Scroll page: text → `buildTextScrollBitmap` (Ark pixel font) → frames; chunked upload to `/api/scroll` (`append:false` first chunk carries `timelineId`+`sourceText`+`fontId`+`generatorVersion`+`totalFrames`; subsequent chunks `append:true`+`chunkIndex`); then `start_scroll` command. A local `setInterval` advances the WebUI preview independently of firmware.

### 2.6 State synchronization flow

- WebUI long-polls `/api/status?since=<version>` (interval driven by `next_poll_ms`, faster when scrolling+on scroll page). `applyFirmwareRuntimeState` merges `renderer`/`power`/`ap`/`stats` into `state`/`scroll`/`firmware` and conditionally re-renders.
- Firmware bumps `stateVersion` via `touchRuntimeState()` on every meaningful change; `slowUiDirty` + `serviceRuntimeSlowStatePublish()` coalesce high-frequency power changes to one publish per `POWER_WEB_SLOW_PUBLISH_MS`.
- GPIO scroll interruptions publish a `scrollStopEvent{seq,ms,button,source,reason}`; the WebUI detects `seq` increase + `gpio` + B1/B2/B3 to mirror the stop and schedule a full resync.

### 2.7 Error / retry flow

- Firmware: validation failures return 400/405/409/413/507 with `{ok:false,error}`. Bad scroll frame data calls `invalidateScrollUploadLocked()` (keeps source text). Atomic JSON writes use temp+rename and remove temp on failure.
- WebUI: `apiGet/apiPost` add `AbortController` timeouts; `apiPostWithUploadProgress` uses `XMLHttpRequest`. Scroll upload retries once with a fresh `timelineId` on any 409. API errors are log-throttled (`shouldLogApiError`, 2.5 s). Button commands have a local `fallback`.

### 2.8 Stop / reset / cleanup

- `stopFirmwareScroll(restoreAuto, clearDisplay)`: cancel deferred restore, reset scroll state under lock (keep or clear timeline meta per `clearDisplay`), clear queued frames, optionally blank + schedule default-face restore, else optionally restore auto mode.
- `serviceDeferredFaceRestore()` fires after `LED_STOP_CLEAR_BLANK_HOLD_MS` so the blank frame physically latches before the saved face replaces it (no `delay()` in handlers).
- WebUI `stopScroll` clears its preview timer, sends `stop_scroll`, and resets scroll controls.
- `stopPollingTimers()` on `pagehide`.

### 2.9 Persistence

`runtime_settings.json` (mode, autoIntervalMs), `saved_faces.json` (unified default+user faces), `battery_calib.json` (manual min/max only — auto calibration is intentionally disabled). All via `writeJsonFileAtomic`. Scroll uploads are RAM-only by contract (any `persist`/`saveToFlash`/non-`ram` storage → 400).

---

## 3. State model audit

### 3.1 Firmware `RuntimeState` (defined `state.h`)

| Field(s) | Represents | Readers | Writers | Lock owner | Risk |
|---|---|---|---|---|---|
| `colorHex/R/G/B`, `brightness` | Active display color/brightness | render task (C1), web handlers (C0) | `setColor`/`setColorStateNoRender`/`setBrightness`, boot | `Frame` | Read unlocked in `handleApiStatus` (C0 vs C1 writes) — torn read (Bug 1). |
| `lastM370` (String) | Last applied frame text | `handleApiStatus` (C0) | `publishPackedFrameNow` under `Frame` (C0 + C1) | `Frame` | Heap `String` written under lock from two cores, read unlocked → torn read of a `String` (Bug 1, higher severity for String). |
| `lastReason` (String) | Last operation reason | status/handlers (C0) | many (C0); `publishPackedFrameNow` (C0+C1) | `Frame` partial | Mostly C0; `publishPackedFrameNow` path touches it on C1 too. |
| `mode`, `playback`, `paused` | Mode/playback state machine | C0 everywhere, render task reads `firmwareScroll*` not these | faces/web/buttons (C0) | Core-0 cooperative | `playback` overlaps `firmwareScroll*` booleans (redundant encoding). |
| `framesAccepted/Rejected/Queued/Dequeued/Dropped`, `commandsAccepted/Rejected`, `savedFacesWrites`, `settingsWrites` | Debug counters | `handleApiStatus` (C0) | enqueue/publish (C0); `framesAccepted` also C1 | mixed | `framesAccepted` incremented on C1 under `Frame`, read unlocked on C0 (Bug 1). |
| `stateVersion`, `slowUiDirty`, `lastSlowUiPublishMs` | UI publish cursor | WebUI via status; `serviceRuntimeSlowStatePublish` | `touchRuntimeState`/`...Slow` (C0); but `touchRuntimeState` is also reachable from C1? No — C1 only `++framesAccepted`. | Core-0 | Must stay monotonic non-zero (wrap handled). OK. |
| `autoIntervalMs`, `lastAutoSwitchMs`, `autoFaceIndex` | Auto playback | `serviceAutoPlayback`, faces, status (C0) | faces/web/buttons (C0) | Core-0 | `autoFaceIndex` also written in `loadSavedFaces`. Bounded by mod count. |
| `firmwareScrollActive/Paused/UserPaused/SystemPaused`, `restoreAutoAfterScroll`, `scrollFrameCount/Index/IntervalMs`, `lastScrollFrameMs` | Firmware scroll playback | render task (C1) + web/faces/buttons (C0) | same | `Scroll` | Correctly guarded in most paths. `restoreAutoAfterScroll` is written in a few places without `Scroll` (e.g. `buttons.cpp` `runButtonAction` line 134, `web_api` `commandTerminateOtherActivities`) — minor inconsistency (Refactor 7). |
| `scrollStopEvent{Seq,Ms,Button,Source,Reason}` | Lightweight GPIO-stop event for WebUI | `addScrollStopEvent` (C0) | `markScrollStoppedByButton` (C0) | Core-0 | String fields; single-core OK. |
| `deferredFaceRestore*` | Deferred restore timer | `serviceDeferredFaceRestore` (C0) | faces (C0) | Core-0 | OK. |

`ScrollTimelineMeta` and the source-text buffer: guarded by `Scroll`; invariant EH-C documented (`timelineId[0]!=0` ⇒ timeline-backed, `totalFramesExpected>0`, `uploadComplete` authoritative). `RuntimeFace[]` autoFaces + `autoFaceCount`: written by `loadSavedFaces` (C0), read by faces/status (C0). `frameBits_[FRAME_BYTES]`: guarded by `Frame`. `scrollFrameBits_` (heap): guarded by `Scroll`.

#### Firmware state findings
- **Redundant state**: `playback` string vs `firmwareScrollActive/Paused` booleans encode overlapping truth; `firmwareScrollPaused` is derived from `User||System` (`applyFirmwareScrollPauseIntentLocked`). `paused` duplicates `firmwareScrollPaused` during scroll. → consolidate (Refactor 6); do **not** change wire values.
- **Derived-not-stored candidates**: `firmwareScrollPaused` (= user||system) is computed and stored; acceptable for snapshot atomicity but documented as derived.
- **Missing state**: none required; the lock-ownership contract is the main gap and it is documented, not enforced.
- **Should be centralized**: cross-core reads in `handleApiStatus` should go through a single locked snapshot (Refactor 1) like `readScrollStateSnapshot()` already does for scroll.

### 3.2 Web UI `state` / `scroll` / `firmware` (app.js 3467–3613)

| Object | Key fields | Notes |
|---|---|---|
| `state` | mode, faceIndex, brightness, defaultBrightness, color, playback, autoInterval, textScrollActive, battery*/charge* | Mirror of firmware renderer+power. `defaultBrightness` frozen after first manual change (Bug 4). |
| `scroll` | timer, active/paused/userPaused/systemPaused, firmwareBacked, uploading/commandBusy/startBusy/pauseBusy/stopBusy/restoring/stepBusy, frames[], timelineId, framesTimelineId, uploadGeneration, returnMode, restored* | Large flat bag; many overlapping booleans. `firmwareBacked` + `active` + `paused` + `state.textScrollActive` + `state.playback` partially duplicate firmware truth. |
| `firmware` | online, last*, counters, queue depths | Diagnostics + transport status. |

#### Web UI state findings
- **Redundant**: `scroll.active/paused/userPaused/systemPaused` + `state.textScrollActive` + `state.playback` overlap; a single derived predicate set would remove drift risk (Refactor 9).
- **Derived-not-stored**: `state.textScrollActive` is fully derivable from `playback`+firmware scroll flags; it is recomputed in several places already.
- **Stale risk**: `brightnessChangedByUser` is a one-way latch (Bug 4); `lastFwScrollTimelineId`/`lastFwScrollHasSourceText` module globals shadow `scroll.*`.
- **Should remain local**: DOM-diff caches, upload progress token — correctly local.

---

## 4. Side-effect audit

| # | Side effect | Where | Trigger | Safe? | Ordering / multiplicity / cleanup |
|---|---|---|---|---|---|
| S1 | `strip.show()` (WS2812 bus) | `led_renderer.cpp renderCurrentFrameToLedStrip`, `ledStripBegin` | render task tick / boot | Yes under `HardwareBus` + min-gap | Single-caller invariant at runtime (C1 only after boot). Must not run concurrently with file I/O which shares the same lock (Bug 3). |
| S2 | `runtimeFrameBits()` mutation | `setFrameBit`, `publishPackedFrameNow`, scroll task, `showFilesystemErrorPattern` | frame apply | Mostly under `Frame` | `setFrameBit` in `showFilesystemErrorPattern` runs under `Frame` (OK). `countLitLeds` reads it unlocked (Bug 1). |
| S3 | Render-request flag + task notify | `requestLedRender`/`consumeLedRenderRequest`/`notifyScrollRenderTask` | color/brightness/frame/overlay change | Yes (`portMUX` + ISR variant) | Can coalesce; double-consume in scroll task drops a scroll frame (Bug 2). |
| S4 | LittleFS read/write | `storage.cpp`, `power_monitor.cpp`, `web_api.cpp` static serving | settings/faces/calib save+load, static files | Functionally yes | Serialize/deserialize executed **inside** `HardwareBus` lock → blocks `strip.show()` (Bug 3, perf). |
| S5 | Timers/intervals (firmware) | none (cooperative `millis()` scheduling) | — | Yes | No OS timers; all polled. |
| S6 | `portMUX` critical sections | `button_animations.cpp` `sAnimMux`, `led_renderer.cpp` `ledRenderRequestMux` | overlay state, render flag | Yes | Short, no nested locks. OK. |
| S7 | WiFi/DNS/HTTP | `web_api.cpp` start/tick | boot + loop | Yes | `server.handleClient()` is blocking per request; long handlers stall loop (`/api/scroll`, large saved-faces). |
| S8 | Serial logging | throughout | events/errors | Yes | High-volume `Serial.printf` in hot paths (auto/scroll apply) — minor perf (Refactor 12). |
| S9 | Global mutation `powerStatus` | `power_monitor.cpp` | sampling | Mostly C0 | `powerStatus` read by overlay code on… C0 (`copyButtonAnimationOverlay` runs on C1 via render task and reads `powerStatus.*`!) → cross-core unlocked read (Bug 8). |
| S10 | DOM updates | `app.js` render*/update* | state change | Yes | `applyFirmwareRuntimeState` re-renders matrices + color dropdowns even when unchanged (Bug 5). |
| S11 | `fetch`/`XHR` | `apiGet/apiPost/apiPostWithUploadProgress` | user actions + polling | Yes | Multiple in-flight guarded by `*InFlight` flags. Color echo can loop visually (Bug 5). |
| S12 | `setInterval`/`setTimeout` (UI) | polling, scroll preview, button anim, full-sync | various | Mostly | Cleared on `pagehide`; scroll preview timer cleared on stop/pause. `firmwareScrollStopFullSyncTimer` cleared before reschedule (OK). |
| S13 | `localStorage` | — | — | n/a | Not used (consistent with environment constraints). |
| S14 | Clipboard / file download / File System Access | copy/save/open faces | user | Yes | `openLocalFaceLibraryFile` handle persists; benign. |

---

## 5. Bug list

> Severity reflects user-visible/operational impact on this single-user AP device. Concurrency items are real but mostly low-probability due to the cooperative Core-0 design.

### Bug 1: Unlocked cross-core reads of frame/state in `handleApiStatus`
**Severity:** Medium
**Type:** state / async (data race)
**Location:** `src/web_api.cpp` `handleApiStatus` (`countLitLeds()` call ~line 519; `renderer.color/brightness/lastM370` reads 500–525; `stats.*` 576–584); `src/led_renderer.cpp` `countLitLeds` (198) reads `runtimeFrameBits()` with no lock; `renderCurrentFrameToLedStrip` (226) writes nothing to frameBits but scroll task (`scroll.cpp` 60) and `publishPackedFrameNow` write under `Frame`.
**Current behavior:** Core-0 HTTP handler reads `runtimeFrameBits()`, `colorHex` (heap `String`), `lastM370` (heap `String`), and `framesAccepted` while the Core-1 render task may be writing them under `Frame`. For `String` fields this is a read of a possibly-reallocating object.
**Expected behavior:** Status reads of frame-lock-owned data should be taken from an atomic snapshot under `Frame` (mirroring the existing `readScrollStateSnapshot()` pattern for scroll).
**Root cause:** No snapshot helper for frame/color/stat fields; the lock contract in `state.h` is documented but not applied at the status path.
**Reproduction path:** Start firmware scroll (continuous Core-1 writes). Poll `/api/status` (non-summary) at high frequency from two browser tabs. Under load, `lit`/`lastM370` can momentarily reflect a torn value; in the worst case the `String` read races a reallocation. Hard to crash deterministically but observable as flicker in reported `lit` and rare malformed `lastM370`.
**Risk if not fixed:** Rare corrupted status JSON; theoretical heap read during `String` realloc → crash under sustained dual-tab polling while scrolling.
**Fix strategy:** Add `FrameStateSnapshot readFrameStateSnapshot()` that copies `colorHex` (to a fixed `char[8]`), `brightness`, `lastM370` (to `char[5+93+1]`), `lastReason`, and the lit count (computed under lock from a local copy of frameBits) inside one `withFrameLock`. Serialize from the snapshot outside the lock. Keep all JSON field names identical.
**Code change:** ⬜
```cpp
// --- CURRENT (src/led_renderer.cpp) — Core-0 reads frameBits with no Frame lock:
uint16_t countLitLeds() {
    const uint8_t* bits = runtimeFrameBits();   // Core-1 render task may be writing this
    uint16_t lit = 0;
    for (uint16_t byteIndex = 0; byteIndex < FRAME_BYTES; ++byteIndex) { /* popcount */ }
    return lit;
}
// --- CURRENT (src/web_api.cpp handleApiStatus) — direct reads of Frame-owned fields:
renderer["color"]    = runtimeState().colorHex;     // heap String, written under Frame on C0+C1
renderer["brightness"] = runtimeState().brightness;
renderer["lastM370"] = runtimeState().lastM370;     // heap String — realloc-during-read risk
renderer["lit"]      = countLitLeds();
```
```cpp
// --- PROPOSED (src/state.h): one atomic snapshot type
struct FrameStateSnapshot {
    char     colorHex[8] = {0};
    uint8_t  brightness  = 0;
    char     lastM370[5 + M370_HEX_CHARS + 1] = {0};
    char     lastReason[M370_FRAME_REASON_CHARS] = {0};
    uint16_t litLeds        = 0;
    uint32_t framesAccepted = 0;
};

// --- PROPOSED (src/led_renderer.cpp): copy everything under ONE Frame lock
FrameStateSnapshot readFrameStateSnapshot() {
    FrameStateSnapshot s;
    withFrameLock([&]() {
        copyText(s.colorHex,  sizeof(s.colorHex),  runtimeState().colorHex.c_str());
        s.brightness = runtimeState().brightness;
        copyText(s.lastM370,  sizeof(s.lastM370),  runtimeState().lastM370.c_str());
        copyText(s.lastReason,sizeof(s.lastReason),runtimeState().lastReason.c_str());
        s.litLeds        = countLitLedsLocked();   // counts from the held buffer (no extra lock)
        s.framesAccepted = runtimeState().framesAccepted;
    });
    return s;
}

// --- PROPOSED (src/web_api.cpp handleApiStatus): serialize from the snapshot, no lock held
const FrameStateSnapshot fs = readFrameStateSnapshot();
renderer["color"]      = fs.colorHex;     // identical JSON field names + value types
renderer["brightness"] = fs.brightness;
renderer["lastM370"]   = fs.lastM370;
renderer["lit"]        = fs.litLeds;
```

**Tests required:** (a) Unit: snapshot returns consistent color+lit for a known frame. (b) Stress: 2-tab `/api/status` polling during scroll for 5 min with heap-integrity logging (`heap_caps_check_integrity`) — no corruption. (c) Field-name diff of status JSON before/after = identical.

### Bug 2: Scroll frame silently dropped when a render request is pending
**Severity:** Low
**Type:** async / rendering
**Location:** `src/scroll.cpp` `scrollRenderTask` lines 52–66.
**Current behavior:** After advancing `scrollFrameIndex` and copying the next scroll frame to a local buffer, the task re-checks the render-request flag under `Frame`. If a main render request arrived (e.g. color/brightness/overlay change), it does **not** copy the scroll frame into `runtimeFrameBits()` but still renders — showing the previous frame's bits with the new color. The advanced `scrollFrameIndex` is lost, so that timeline frame is skipped.
**Expected behavior:** A concurrent color/brightness change should re-render the *current* scroll frame, not skip it; index should not advance past an undisplayed frame, or the new frame should still be applied.
**Root cause:** The "main render takes priority" branch discards the freshly-decoded scroll frame instead of applying it; index was already incremented before the priority check.
**Reproduction path:** Start scroll at low fps (e.g. 5 fps). Rapidly drag the brightness slider (each emits a render request). Observe the scroll text momentarily skips a column/frame on each brightness tick.
**Risk if not fixed:** Minor visual stutter during simultaneous scroll + color/brightness edits. No data loss beyond the visual.
**Fix strategy:** Apply the scroll frame to `runtimeFrameBits()` whenever `firmwareScrollActive` regardless of `mainTaskRenderPending` (the main request and the scroll frame are not mutually exclusive — both want a render of the latest bits). Concretely: drop the `&& !mainTaskRenderPending` guard on the memcpy; keep `shouldRender = true`. Verify ordering vs `publishPackedFrameNow` (which also writes frameBits under `Frame`) — last writer wins, acceptable since a queued M370 frame during active scroll is already an exceptional path.
**Code change:** ⬜
```cpp
// --- CURRENT (src/scroll.cpp scrollRenderTask, inside withFrameLock):
if (runtimeState().firmwareScrollActive && !mainTaskRenderPending) {
    memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
    ++runtimeState().framesAccepted;
} else {
    if (!mainTaskRenderPending) shouldRender = false;   // scroll frame discarded; index already advanced
}
```
```cpp
// --- PROPOSED: a pending main render and the new scroll frame are NOT mutually
// exclusive — both want the latest bits shown, so apply the scroll frame regardless.
if (runtimeState().firmwareScrollActive) {
    memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
    ++runtimeState().framesAccepted;
    shouldRender = true;
} else if (!mainTaskRenderPending) {
    shouldRender = false;
}
```

**Tests required:** Manual hardware: 5 fps scroll + brightness sweep → no skipped columns (capture with phone slow-mo). Bench: instrument `framesAccepted` delta vs `scrollFrameIndex` advances over 100 frames with periodic render requests — equal counts.

### Bug 3: File serialization/deserialization holds the LED `HardwareBus` lock
**Severity:** Medium
**Type:** performance / timing
**Location:** `src/storage.cpp` `writeJsonFileAtomic` (56–62: `serializeJson` + `flush` + `close` + `rename` inside `withHardwareBusLock`), `loadSavedFaces` (270–273: `deserializeJson` inside lock), `web_api.cpp streamFileChunked` (153–158 reads inside lock per chunk).
**Current behavior:** `HardwareBus` is the same mutex that gates `strip.show()`. Writing/loading a large `saved_faces.json` (or streaming a large static asset) holds it for the full serialize/parse, blocking the Core-1 render task's `show()` for tens of ms.
**Expected behavior:** LED refresh cadence should not stall during flash I/O; only the genuinely shared hardware window needs the lock.
**Root cause:** Coarse-grained lock scope: the lock protects "LittleFS + LED bus" together (a deliberate simplification), but serialize/parse do not touch the LED bus and need not be inside it.
**Reproduction path:** While a firmware scroll plays, POST a large `saved_faces.json` to `/api/saved_faces`. Observe a visible scroll hitch (frame gap) for the duration of the write. Same on boot `loadSavedFaces`.
**Risk if not fixed:** Visible stutter on saves and large static transfers; worsens as the face library grows.
**Fix strategy:** Keep LittleFS file *open/close/rename* under the lock if flash and LED truly contend on the same SPI/timing budget (verify hardware: WS2812 is on RMT/GPIO, LittleFS on internal flash — they likely do **not** share a bus, in which case the `HardwareBus` lock over file I/O is unnecessary and can be removed entirely for storage). If they are independent, introduce a separate `Storage` mutex (or no lock) for file content I/O and reserve `HardwareBus` strictly for `strip.show()`. **Mark as a deliberate, justified change** — it alters timing behavior, so it is a bug fix, not a silent refactor. Do not change atomic-write semantics (temp+rename).
**Code change:** ⬜ (requires adding `SyncDomain::Storage` to `sync.h`/`sync.cpp`)
```cpp
// --- CURRENT (src/storage.cpp writeJsonFileAtomic): serialize runs under the LED-bus lock
bool renamed = false;
withHardwareBusLock([&]() {
    written = serializeJson(document, file);   // multi-KB serialize blocks strip.show()
    file.flush();
    file.close();
    renamed = written > 0 && LittleFS.rename(tempPath, path);
    if (!renamed) LittleFS.remove(tempPath);
});
```
```cpp
// --- PROPOSED: reserve HardwareBus strictly for strip.show(); guard flash content I/O
// with a dedicated Storage lock (only after confirming WS2812/RMT and flash do not
// share hardware — see Risk table). Atomic temp+rename semantics unchanged.
bool renamed = false;
withStorageLock([&]() {
    written = serializeJson(document, file);   // heavy work OFF the LED-bus lock
    file.flush();
    file.close();
    renamed = written > 0 && LittleFS.rename(tempPath, path);
    if (!renamed) LittleFS.remove(tempPath);
});
```
```cpp
// --- PROPOSED (src/sync.h): extend the domain enum + helper
enum class SyncDomain : uint8_t { Frame, Scroll, HardwareBus, Storage };
template <typename Fn> auto withStorageLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Storage); return fn();
}
// Global order extended to: Scroll -> Frame -> HardwareBus -> Storage (no reverse nesting).
```

**Tests required:** (a) Measure scroll frame gap (logic-analyzer or `micros()` delta around `show()`) during a 64 KB saved-faces write — before vs after. (b) Power-loss-during-write test still leaves either old or new file intact (atomicity preserved). (c) Confirm no concurrent `strip.show()` + LittleFS corruption over 1000 write cycles.

### Bug 4: `brightnessChangedByUser` latch never resets → frozen `defaultBrightness`
**Severity:** Low
**Type:** logic / state
**Location:** `data/app.js` `setBrightness` (5351 sets latch true), `applyFirmwareRuntimeState` (4785 `if (!brightnessChangedByUser) state.defaultBrightness = ...`), `resetBrightnessDefault` (7144 uses `state.defaultBrightness`).
**Current behavior:** Once the user changes brightness, `brightnessChangedByUser` stays `true` for the whole session. `state.defaultBrightness` therefore stops tracking firmware brightness, so "重置默认亮度" reverts to whatever default was synced before the first manual change — even if firmware default later changed (e.g. after a startup-face reload that sets `brightness=DEFAULT_BRIGHTNESS`).
**Expected behavior:** "Reset default brightness" should restore the firmware's current notion of default (50), or the latch semantics should be explicitly documented and bounded.
**Root cause:** A latch used to prevent polling from overwriting the user's brightness also permanently disables default-tracking; no reset on firmware-confirmed brightness or on reset action.
**Reproduction path:** Load page (default 50). Move slider to 120. Click "重置默认亮度" → goes to 50 (ok this time). Now imagine firmware reloads saved faces (brightness→50) and a new default scheme; UI still treats the pre-edit value as default. More concretely: the field is dead state that can desync.
**Risk if not fixed:** Confusing reset behavior; low impact.
**Fix strategy:** Either (a) reset `brightnessChangedByUser=false` after a successful firmware echo of the user's brightness in `applyFirmwareRuntimeState`, or (b) drive `defaultBrightness` from a dedicated firmware-provided default field and stop gating it on the latch. Choose (b): firmware status already implies the default (50); expose/derive it and remove the latch's coupling to `defaultBrightness`.
**Code change:** ⬜
```js
// --- CURRENT (data/app.js): latch set true on first user change, never cleared
function setBrightness(v, source = "brightness_change") {
  brightnessChangedByUser = true;            // sticky for the whole session
  applyBrightnessLocal(v);
  log(`亮度更新 raw=${state.brightness} (${source})`);
  sendAuxCommand("set_brightness", { raw: state.brightness }, source);
}
// applyFirmwareRuntimeState():
if (!brightnessChangedByUser) state.defaultBrightness = nextBrightness;  // frozen after first edit
```
```js
// --- PROPOSED (data/app.js applyFirmwareRuntimeState): clear the latch once the
// firmware echoes the user's brightness, so defaultBrightness resumes tracking.
const nextBrightness = clampBrightness(brightnessValue);
if (state.brightness === nextBrightness) brightnessChangedByUser = false;  // echo confirmed
if (!brightnessChangedByUser) state.defaultBrightness = nextBrightness;
```

**Tests required:** UI test: change brightness, trigger a poll cycle, click reset → returns to firmware default. Verify polling does not stomp an in-progress slider drag.

### Bug 5: Status polling re-renders matrices and resets color dropdowns even when color is unchanged
**Severity:** Medium
**Type:** UI / performance
**Location:** `data/app.js` `setColor` (5313–5338): it mutates DOM, calls `syncColorDropdownsToHex`, `renderMatrices`, `renderState` **before** the `if (unchangedFirmwareSync) return;` early-out; `applyFirmwareRuntimeState` (4795–4798) calls `setColor(firmwareColor,"firmware_sync")` on every poll that includes a color.
**Current behavior:** Each `/api/status` poll that carries `renderer.color` runs full matrix re-render + `syncColorDropdownsToHex` even when the color equals the current one. If the user has the parent/child color dropdown open or is mid-selection, the poll resets the dropdown selection to match the hex.
**Expected behavior:** When the firmware color equals `state.color`, the sync should be a no-op (no DOM writes, no dropdown reset, no matrix re-render).
**Root cause:** The unchanged-case early return is placed after the rendering side effects rather than before them.
**Reproduction path:** On the basic page, open the child-color dropdown and hover/select; within ~1 s a status poll arrives and `syncColorDropdownsToHex` snaps the dropdown back. Also: continuous matrix re-renders every second waste CPU/battery on the client.
**Risk if not fixed:** Janky color picker; unnecessary per-second re-render churn.
**Fix strategy:** In `setColor`, when `source === "firmware_sync" && state.color === c`, return immediately before any DOM/render side effects. Keep the non-sync path (user-initiated) fully rendering. Verify `--led-color` CSS var and swatch still update on genuine changes.
**Code change:** ⬜
```js
// --- CURRENT (data/app.js setColor): unchanged-case early-return sits AFTER the
// DOM writes + dropdown sync + matrix re-render, so a no-op poll still churns.
function setColor(hex, source = "color_change") {
  const c = normalizeHexColor(hex);
  if (!c) { alert("颜色必须是 #RRGGBB 或 RRGGBB"); return; }
  const unchangedFirmwareSync = source === "firmware_sync" && state.color === c;
  state.color = c;
  document.documentElement.style.setProperty("--led-color", c);
  if ($("color-input"))  $("color-input").value = c;
  if ($("color-swatch")) $("color-swatch").style.background = c;
  syncColorDropdownsToHex(c);     // <-- resets an open/in-progress dropdown
  updateDps();
  renderMatrices();               // <-- per-second re-render churn
  renderState();
  if (unchangedFirmwareSync) return;
  log(`颜色更新 ${c} (${source})`);
  if (source !== "firmware_sync") sendAuxCommand("set_color", { hex: c }, source);
}
```
```js
// --- PROPOSED: move the no-op short-circuit ABOVE all side effects.
function setColor(hex, source = "color_change") {
  const c = normalizeHexColor(hex);
  if (!c) { alert("颜色必须是 #RRGGBB 或 RRGGBB"); return; }
  // A firmware poll re-asserting the colour we already show must be a true no-op:
  // no DOM writes, no dropdown reset, no matrix re-render.
  if (source === "firmware_sync" && state.color === c) return;
  state.color = c;
  document.documentElement.style.setProperty("--led-color", c);
  if ($("color-input"))  $("color-input").value = c;
  if ($("color-swatch")) $("color-swatch").style.background = c;
  syncColorDropdownsToHex(c);
  updateDps();
  renderMatrices();
  renderState();
  log(`颜色更新 ${c} (${source})`);
  if (source !== "firmware_sync") sendAuxCommand("set_color", { hex: c }, source);
}
```

**Tests required:** UI: open color dropdown, let 3 polls pass with identical firmware color → dropdown selection unchanged, no matrix re-render (assert via render counter). Genuine firmware color change still updates swatch + matrices.

### Bug 6: `loadRuntimeSettings` writes defaults during a transient mount/parse failure
**Severity:** Low
**Type:** persistence / edge case
**Location:** `src/storage.cpp` `loadRuntimeSettings` (106–110): if `SETTINGS_PATH` doesn't exist it calls `saveRuntimeSettings()` (writes defaults) and returns false; parse failure (127–130) returns false without writing.
**Current behavior:** Missing file → defaults written (intended). But a parse failure (corrupt file) silently keeps current in-RAM defaults and does **not** repair the file, so the corrupt file persists and every boot re-parses+fails.
**Expected behavior:** A corrupt settings file should be repaired (rewritten with current/default values) so the corruption doesn't persist indefinitely.
**Root cause:** Asymmetric handling of "missing" vs "corrupt".
**Reproduction path:** Manually corrupt `runtime_settings.json` (truncate). Reboot → log shows parse failure every boot; file never repaired.
**Risk if not fixed:** Permanent log noise; settings never persist again until a setting changes (which does rewrite). Low impact because any mode/interval change rewrites.
**Fix strategy:** On parse failure, call `saveRuntimeSettings()` to rewrite a valid file after applying defaults. Keep success/missing paths unchanged.
**Code change:** ⬜
```cpp
// --- CURRENT (src/storage.cpp loadRuntimeSettings): corrupt file is left in place
if (err) {
    Serial.printf("runtime_settings.json parse failed: %s\n", err.c_str());
    return false;
}
```
```cpp
// --- PROPOSED: repair the corrupt file so the failure does not persist every boot.
if (err) {
    Serial.printf("runtime_settings.json parse failed; rewriting defaults: %s\n", err.c_str());
    saveRuntimeSettings();   // current in-RAM mode/interval are already defaults here
    return false;
}
```

**Tests required:** Corrupt the file → boot → assert file is rewritten to valid JSON and parses on next boot.

### Bug 7: Mutex creation failure degrades silently to unsynchronized operation
**Severity:** Medium
**Type:** async / error handling
**Location:** `src/main.cpp` (42–44 logs but continues); `src/sync.cpp` `lockFrame`/`lockScroll`/`lockHardwareBus` (each `if (mutex) take(...)`). If creation failed, the handle is null and every lock/unlock becomes a no-op.
**Current behavior:** If any `xSemaphoreCreateMutex()` returns null (heap exhaustion), boot continues and all critical sections silently run without protection across both cores — a latent corruption source with no runtime signal beyond one boot log line.
**Expected behavior:** Either fail safe (do not start the Core-1 render task, run single-core) or make the failure loud and persistent (e.g. dedicated error LED pattern), rather than running cross-core without locks.
**Root cause:** Defensive `if (mutex)` guards make missing mutexes invisible at the call sites.
**Reproduction path:** Hard to trigger naturally; force by making `initSyncPrimitives` return false (stub) → system runs but locks are no-ops; under scroll + status polling, frame corruption appears.
**Risk if not fixed:** Silent data races if RAM is ever exhausted at boot.
**Fix strategy:** If `initSyncPrimitives()` fails, do not call `startScrollRenderTask()` (keep all rendering on Core 0 where the cooperative loop serializes access), and surface a distinct diagnostic (reuse `showFilesystemErrorPattern`-style indicator or a dedicated pattern). Document that locks must exist before the Core-1 task starts.
**Code change:** ⬜
```cpp
// --- CURRENT (src/main.cpp setup): logs but continues; Core-1 task starts anyway
if (!initSyncPrimitives()) {
    Serial.println("Failed to create one or more FreeRTOS mutexes");
}
// ... later, unconditionally:
startScrollRenderTask();
```
```cpp
// --- PROPOSED: fail safe — keep everything on Core 0 (cooperative loop serializes
// access) and surface a loud, persistent diagnostic when locks are unavailable.
const bool syncReady = initSyncPrimitives();
if (!syncReady) {
    Serial.println("FATAL: FreeRTOS mutexes unavailable; render task disabled, running single-core");
    showFilesystemErrorPattern();   // reuse or add a dedicated diagnostic LED pattern
}
// ... later:
if (syncReady) startScrollRenderTask();   // never start Core-1 access without locks
// loop(): when !syncReady, drive renderCurrentFrameToLedStrip() inline after frame service.
```

**Tests required:** Fault-injection unit: force `initSyncPrimitives` false → assert scroll task not created and a diagnostic raised; no Core-1 access to shared state.

### Bug 8: `powerStatus` read on Core 1 (overlay) without synchronization
**Severity:** Low
**Type:** async (data race)
**Location:** `src/button_animations.cpp` `drawBatteryPage` (300–322), `serviceButtonAnimations` (530–538), `startBatteryOverlay` (431) read `powerStatus.batteryValid/percent/charging/vbat/vcharge`. `copyButtonAnimationOverlay` runs on the **Core-1** render task; `powerStatus` is written by `servicePowerMonitor` on **Core 0**.
**Current behavior:** Battery overlay (drawn on C1) reads multi-field `powerStatus` while C0 sampling may be mid-update. Fields are scalar (`float`/`uint8`/`bool`), so tears are partial-struct inconsistencies (e.g. `percent` from new sample, `vbat` from old).
**Expected behavior:** Overlay should read a consistent power snapshot.
**Root cause:** `powerStatus` is a shared global with no lock; the overlay was likely assumed Core-0 but `copyButtonAnimationOverlay` is invoked from `renderCurrentFrameToLedStrip` (C1).
**Reproduction path:** Hold B6 (battery overlay) while charging state toggles; rare frame may show mismatched percent vs voltage. Visual only.
**Risk if not fixed:** Cosmetic inconsistency in the battery overlay; no crash (POD scalars).
**Fix strategy:** Add a small `PowerSnapshot` copied under a short `portMUX` (or reuse a dedicated critical section) in `servicePowerMonitor` write and overlay read; or compute the overlay's power-derived values on Core 0 and pass them into `sAnim` (which is already `portMUX`-guarded). Prefer the latter: stage battery percent/vbat/charging into `sAnim` fields under `sAnimMux` when starting/refreshing the battery overlay.
**Code change:** ⬜
```cpp
// --- CURRENT (src/button_animations.cpp drawBatteryPage, runs on Core 1):
const bool    batteryValid = powerStatus.batteryValid;   // powerStatus written on Core 0
const uint8_t pct          = batteryValid ? powerStatus.batteryPercent : 0;
const bool    charging     = powerStatus.chargeValid && powerStatus.charging;
const float   v            = isfinite(powerStatus.vbat) ? powerStatus.vbat : 0.0f;
```
```cpp
// --- PROPOSED: stage power fields into the sAnimMux-guarded sAnim on Core 0 when the
// battery overlay starts/refreshes; Core 1 reads only the copied snapshot.
// AnimationState (add):
bool    batValid = false, batCharging = false;
uint8_t batPercent = 0;
float   batVbat = NAN, batVcharge = NAN;

// startBatteryOverlay()/serviceButtonAnimations() on Core 0, under portENTER_CRITICAL(&sAnimMux):
next.batValid    = powerStatus.batteryValid;
next.batPercent  = powerStatus.batteryPercent;
next.batCharging = powerStatus.chargeValid && powerStatus.charging;
next.batVbat     = powerStatus.vbat;
next.batVcharge  = powerStatus.vcharge;

// drawBatteryPage() on Core 1 reads state.batValid/batPercent/... (the copied snapshot),
// never powerStatus directly → consistent percent/voltage pairing.
```

**Tests required:** Stress: toggle charger input while B6 overlay active for 2 min; assert no struct-tear via logged snapshot consistency check.

### Bug 9: WebUI mirrors firmware scroll pause as user-pause when split flags are absent
**Severity:** Low
**Type:** state / sync
**Location:** `data/app.js` `applyFirmwareRuntimeState` 4740–4748. When `hasSplitPauseFlags` is false (older/summary payloads), `scroll.userPaused` is set from `playbackValue==="scroll_paused" || firmwareScrollPaused`, conflating a **system** pause (B6 overlay) with a **user** pause.
**Current behavior:** During a B6 battery overlay (firmware system-pause), a status payload lacking split flags would mark the WebUI `userPaused`, changing the pause button's semantics and potentially letting the user "resume" a system-paused scroll out of band.
**Expected behavior:** System pause must not be presented as user pause. Firmware status always includes the split flags in the current code (`addScrollStateFields` always emits them), so this path is currently dormant — but it is a latent contradiction if any summary path omits them.
**Root cause:** Backward-compat fallback that cannot distinguish user vs system pause.
**Reproduction path:** Force a status response without `firmwareScrollUserPaused/SystemPaused` (e.g. a future trimmed summary) while B6 overlay active → pause toggle mislabeled.
**Risk if not fixed:** Latent; only triggers if the wire contract drops the split flags. Document + guard.
**Fix strategy:** When split flags are absent, treat `firmwareScrollPaused` as **systemPaused=unknown** and prefer leaving `userPaused` unchanged rather than inferring it; or assert that all status/summary payloads always include split flags (and add a firmware test that guarantees it). Keep current behavior when flags present.
**Code change:** ⬜
```js
// --- CURRENT (data/app.js applyFirmwareRuntimeState): without split flags, a SYSTEM
// pause (B6 overlay) is mis-attributed to the USER.
scroll.userPaused = hasSplitPauseFlags
  ? firmwareScrollUserPaused
  : playbackValue === "scroll_paused" || firmwareScrollPaused;   // conflates system pause
scroll.systemPaused = hasSplitPauseFlags ? firmwareScrollSystemPaused : false;
```
```js
// --- PROPOSED: when split flags are absent, do not invent a user pause; leave the
// previous userPaused untouched and treat the effective pause as system-origin.
if (hasSplitPauseFlags) {
  scroll.userPaused   = firmwareScrollUserPaused;
  scroll.systemPaused = firmwareScrollSystemPaused;
} else {
  // Cannot distinguish user vs system → keep last known userPaused, attribute the
  // effective pause to "system" so the pause button is never wrongly made resumable.
  scroll.systemPaused = (playbackValue === "scroll_paused" || firmwareScrollPaused) && !scroll.userPaused;
}
// PLUS firmware contract test: addScrollStateFields() always emits both split flags
// in every /api/status variant (already true today — lock it with a test).
```

**Tests required:** Contract test: every `/api/status` variant (`runtimeOnly`, `noFrame`, `summary`, full) includes both split pause flags. UI test with flags omitted → user-pause not asserted.

### Bug 10: First-chunk size search re-encodes the whole payload per candidate (upload latency)
**Severity:** Low
**Type:** performance
**Location:** `data/app.js` `chooseFirstChunkFrames` (8768–8784): loops `count` down from `SCROLL_UPLOAD_CHUNK_FRAMES`, each iteration `JSON.stringify` + `TextEncoder().encode` of the full first-chunk payload to measure bytes.
**Current behavior:** For long text the first-chunk fit search can stringify+encode a multi-KB payload many times (O(n) re-encodes), adding client-side latency before the first byte uploads.
**Expected behavior:** Estimate chunk size from per-frame byte cost + fixed meta overhead, then verify once.
**Root cause:** Brute-force shrink loop with full re-serialization each step.
**Reproduction path:** Enter the maximum scroll text; click 发送; observe a measurable pause (hundreds of ms on a phone) before the progress bar moves past "准备".
**Risk if not fixed:** Sluggish send for long text; not a correctness issue.
**Fix strategy:** Compute `metaBytes` once (payload with `frames:[]`), compute average frame string bytes, derive an initial `count` from `(LIMIT - metaBytes)/avgFrameBytes`, then do at most one or two verify/adjust steps. Keep the D4 "too long for one chunk" error path.
**Code change:** ⬜
```js
// --- CURRENT (data/app.js): re-stringifies + re-encodes the full payload per candidate
function chooseFirstChunkFrames(firstChunkPayloadBuilder) {
  let count = SCROLL_UPLOAD_CHUNK_FRAMES;
  while (count > 1) {
    const bytes = new TextEncoder().encode(JSON.stringify(firstChunkPayloadBuilder(count))).length;
    if (bytes <= SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES) return count;
    count--;                                  // O(n) full re-encodes for long text
  }
  const oneFrameBytes = new TextEncoder().encode(JSON.stringify(firstChunkPayloadBuilder(1))).length;
  if (oneFrameBytes > SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES) throw new Error("滚动文字过长，元数据无法放入首个上传分块");
  return 1;
}
```
```js
// --- PROPOSED: estimate from per-frame cost + fixed meta, then verify at most a few times.
function chooseFirstChunkFrames(firstChunkPayloadBuilder) {
  const enc = new TextEncoder();
  const metaBytes = enc.encode(JSON.stringify(firstChunkPayloadBuilder(0))).length;  // frames:[]
  const oneFrame  = enc.encode(JSON.stringify(firstChunkPayloadBuilder(1))).length;
  const perFrame  = Math.max(1, oneFrame - metaBytes);
  let count = Math.min(
    SCROLL_UPLOAD_CHUNK_FRAMES,
    Math.max(0, Math.floor((SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES - metaBytes) / perFrame)),
  );
  while (count > 1 &&
         enc.encode(JSON.stringify(firstChunkPayloadBuilder(count))).length > SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES) {
    count--;                                  // JSON overhead is near-constant → 0–2 iterations
  }
  if (count < 1) throw new Error("滚动文字过长，元数据无法放入首个上传分块");  // D4 preserved
  return count;
}
```

**Tests required:** Bench: encode count for representative texts before/after = same chosen size; measure wall-clock of `chooseFirstChunkFrames` (≥10× faster for max text).

### Bug 11: `serviceM370FrameQueue` copies a 56-byte queue item by value every serviced frame
**Severity:** Low
**Type:** performance
**Location:** `src/led_renderer.cpp serviceM370FrameQueue` (395–401) `memcpy(&item, &m370FrameQueue[head], sizeof(item))` then publishes from the copy.
**Current behavior:** Each dequeue copies the full `QueuedM370Frame` (47-byte bits + 98-byte m370 text + 64-byte reason ≈ 210 bytes) to a stack temp before publishing, then publish memcpy's bits again into frameBits. Two copies per frame.
**Expected behavior:** Publish directly from the queue slot, then advance head.
**Root cause:** Defensive copy to allow advancing head before publishing; not required since publish reads bits synchronously.
**Reproduction path:** N/A (perf only); visible only under sustained max frame rate.
**Risk if not fixed:** Negligible; listed for completeness and because it interacts with Refactor 2.
**Fix strategy:** Publish from `m370FrameQueue[head]` directly (publish copies bits under lock), then advance head/count. Confirm no re-entrancy (publish does not enqueue).
**Code change:** ⬜
```cpp
// --- CURRENT (src/led_renderer.cpp serviceM370FrameQueue): copies the ~210-byte item
QueuedM370Frame item;
memcpy(&item, &m370FrameQueue[m370FrameQueueHead], sizeof(item));
m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
--m370FrameQueueCount;
++runtimeState().framesDequeued;
publishPackedFrameNow(item.bits, item.hasM370 ? item.m370 : nullptr, item.reason);
```
```cpp
// --- PROPOSED: publish directly from the slot (publish copies bits under Frame lock and
// does not enqueue, so reading the slot then advancing head is safe).
const QueuedM370Frame& item = m370FrameQueue[m370FrameQueueHead];
publishPackedFrameNow(item.bits, item.hasM370 ? item.m370 : nullptr, item.reason);
m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
--m370FrameQueueCount;
++runtimeState().framesDequeued;
```

**Tests required:** Frame-rate bench unchanged; `framesDequeued` count identical.

### Bug 12: `decodeNormalizedM370ToPackedBits` discards the top 2 bits of the last nibble silently (by design) — verify boundary
**Severity:** Low (verify-only / uncertain)
**Type:** edge case
**Location:** `src/led_renderer.cpp` (338–352). 93 hex nibbles × 4 = 372 bits, but `if (bit < M370_BITS)` (370) guards writes, so bits 370–371 are dropped.
**Current behavior:** Correct per spec (370 LEDs, 2 padding bits). Marked **uncertain** only to confirm the WebUI encoder agrees.
**Expected behavior:** WebUI `frameToM370` pads 370 bits + "00" then groups by 4 → 93 hex; decode drops the final 2 padding bits. Consistent.
**Root cause:** n/a — this is correct; included to assert the invariant is intentional and tested.
**Reproduction path:** Encode a frame with LED 369 set in WebUI, send, read back `lastM370`, decode → LED 369 set, bits 370/371 ignored.
**Risk if not fixed:** None if the invariant holds; risk is a future change to `LED_COUNT` breaking the `static_assert` relationship.
**Fix strategy:** No change. Add a round-trip test pinning `frameToM370`↔`m370ToPackedBits` for boundary LEDs (0, 369) and the existing `static_assert M370_HEX_CHARS == (M370_BITS+3)/4`.
**Code change:** ⬜ (test-only; no production change)
```js
// --- PROPOSED test (Node/JS harness reusing the WebUI + a mirror of the firmware decode):
for (const led of [0, 17, 369]) {
  const f = blankFrame(); f[led] = true;
  const m = frameToM370(f);                 // WebUI encoder: 370 bits + "00" → 93 hex
  const back = m370ToFrame(m);              // decoder drops padding bits 370/371
  assert(back[led] === true);
  assert(onCount(back) === 1);
}
// Firmware side: assert the existing invariant holds and pin it:
//   static_assert(M370_HEX_CHARS == (M370_BITS + 3U) / 4U, ...);  // already in config.h
```

**Tests required:** Round-trip unit test for LEDs {0, 17, 369}.

### Bug 13: Face ID bounds/overflow on parsing
**Severity:** Low
**Type:** logic / edge case
**Location:** `src/storage.cpp` `defaultFaceIdNumberIsInvalid` (149–159).
**Current behavior:** Extremely long default face IDs (e.g. `face_42949672960`) can overflow the 32-bit integer parser `value = value * 10 + ...` and wrap to `0`, causing `value < 1` to be true and rejecting the faces, or wrapping to a valid positive number and being incorrectly accepted.
**Expected behavior:** Prevent overflow during ID parsing or bound the length strictly.
**Root cause:** Naive parsing loop without length or overflow guards.
**Reproduction path:** Save a face with ID `face_42949672960` and reboot.
**Risk if not fixed:** Malicious or malformed faces could break JSON load logic silently.
**Fix strategy:** Add a character-length limit (e.g., maximum 9 digits) inside the `while` loop before multiplying by 10.
**Code change:** ⬜
```cpp
// --- CURRENT (src/storage.cpp defaultFaceIdNumberIsInvalid):
uint32_t value = 0;
while (*p >= '0' && *p <= '9') {
    value = value * 10 + static_cast<uint32_t>(*p - '0');   // can overflow 2^32 → wraps
    ++p;
}
return value < 1;
```
```cpp
// --- PROPOSED: cap digit count (9 digits fits in uint32_t without wrap) and treat
// over-long numeric IDs as invalid rather than letting them wrap.
uint32_t value = 0;
uint8_t  digits = 0;
while (*p >= '0' && *p <= '9') {
    if (++digits > 9) return true;          // implausibly long → invalid, no overflow
    value = value * 10 + static_cast<uint32_t>(*p - '0');
    ++p;
}
return value < 1;
```
**Tests required:** Unit: `defaultFaceIdNumberIsInvalid("face_42949672960")` returns true.

### Bug 14: `powerStatus` EMA filtering edge case (dtS constrained but unsigned wrap)
**Severity:** Low
**Type:** edge case
**Location:** `src/power_monitor.cpp` `sampleBattery` (348).
**Current behavior:** The EMA filtering constraint uses `static_cast<float>(now - powerStatus.lastBatteryMs) * 0.001f`. While `now - last` handles 32-bit wrap, if the device hangs or misses a sample for > 49 days, the delta might wrap around to a very small positive number instead of hitting the 10.0f clamp.
**Expected behavior:** If the last sample was an extremely long time ago, the filter should snap to the instant value or correctly clamp.
**Root cause:** The `constrain` operates on the `float` output *after* the `uint32_t` subtraction, which already wraps modulo $2^{32}$.
**Reproduction path:** Keep board on for 49.7 days without sampling battery.
**Risk if not fixed:** Negligible. One wrong EMA sample every 50 days.
**Fix strategy:** Just before `constrain`, if `now < lastBatteryMs` and `now - lastBatteryMs > 0x7FFFFFFF` (a massive negative jump representing wrap or huge delay), just snap `vbat = instantVbat` and bypass EMA.
**Code change:** ⬜
```cpp
// --- CURRENT (src/power_monitor.cpp sampleBattery):
const float dtS = constrain(
    static_cast<float>(now - powerStatus.lastBatteryMs) * 0.001f, 0.001f, 10.0f);
const float emaAlpha = 1.0f - expf(-dtS / BATTERY_EMA_TAU_S);
powerStatus.vbat = (powerStatus.vbat * (1.0f - emaAlpha)) + (instantVbat * emaAlpha);
```
```cpp
// --- PROPOSED: detect an implausible elapsed time (wrap / long stall) and snap.
const uint32_t elapsedMs = now - powerStatus.lastBatteryMs;
if (elapsedMs > 0x7FFFFFFFu) {                 // ~24.8 days+ / wrap → distrust the delta
    powerStatus.vbat = instantVbat;            // snap, skip EMA this sample
} else {
    const float dtS = constrain(static_cast<float>(elapsedMs) * 0.001f, 0.001f, 10.0f);
    const float emaAlpha = 1.0f - expf(-dtS / BATTERY_EMA_TAU_S);
    powerStatus.vbat = (powerStatus.vbat * (1.0f - emaAlpha)) + (instantVbat * emaAlpha);
}
```
**Tests required:** Unit: fake `now` wrap and assert `vbat` snaps to `instantVbat`.

---

### Bug 15: 6.4 scroll buttons flash disabled→enabled on every click  🟢 APPLIED
**Severity:** Medium
**Type:** UI
**Location:** `data/app.js` `updateScrollUi` (`anyCommandBusy` definition + the `pause`/`stop`/`step`/`speed` `disabled` expressions). Handlers `setScrollFps` (8557), `setScrollStepHandler` (9154), `pauseScroll`/`resumeScroll`/`stopScroll`.
**Current behavior (before fix):** Each scroll command handler set a transient busy flag (`scroll.commandBusy` plus `pauseBusy`/`stepBusy`/`fpsBusy`/`stopBusy`), called `updateScrollUi()`, awaited one HTTP round-trip, cleared the flag, and called `updateScrollUi()` again. Because `anyCommandBusy = hardBusy || scroll.commandBusy` was folded into **every** button's `disabled`, a quick command disabled the whole button row and then re-enabled it — a visible flash on every click.
**Expected behavior:** A button's enabled/disabled state should change only when its *real* availability changes; a normal click must not flash the row. Only genuinely long operations (upload/restore) should visibly disable controls.
**Root cause:** Short-lived single-round-trip re-entrancy flags were reflected into the DOM `disabled` attribute, even though each handler already blocks re-entry at its own entry (`if (scroll.commandBusy || scroll.*Busy) return;`).
**Reproduction path:** On 6.4, click 暂停/继续/停止/逐帧/帧率 — every click briefly greys out all buttons.
**Risk if not fixed:** Janky control row; perceived unresponsiveness.
**Fix strategy (applied):** Drop the transient flags from the visual `disabled` computation; keep them only as handler re-entrancy guards. `anyCommandBusy` now equals `hardBusy` (upload/restore) only.
**Code change:** 🟢 applied to `data/app.js`
```js
// --- BEFORE:
const anyCommandBusy = hardBusy || scroll.commandBusy;
applyScrollButtonUiState("pause", pauseBtn, {
  disabled: anyCommandBusy || scroll.pauseBusy || nonResumableSystemPause || !scrollLiveOrPaused,
  text: effectivePaused ? "继续" : "暂停", pressed: scrollPlayingNow,
});
applyScrollButtonUiState("stop", stopBtn, { disabled: anyCommandBusy || scroll.stopBusy || !hasFrameCache });
const stepDisabled = anyCommandBusy || scroll.stepBusy || scrollPlayingNow || !hasFramesForStep;
const speedDisabled = anyCommandBusy || scroll.fpsBusy;
```
```js
// --- AFTER: only long upload/restore disable controls; re-entrancy stays in the handlers.
const anyCommandBusy = hardBusy;
applyScrollButtonUiState("pause", pauseBtn, {
  disabled: anyCommandBusy || nonResumableSystemPause || !scrollLiveOrPaused,
  text: effectivePaused ? "继续" : "暂停", pressed: scrollPlayingNow,
});
applyScrollButtonUiState("stop", stopBtn, { disabled: anyCommandBusy || !hasFrameCache });
const stepDisabled = anyCommandBusy || scrollPlayingNow || !hasFramesForStep;
const speedDisabled = anyCommandBusy;
```
**Tests required:** Manual: click each scroll button rapidly → no whole-row flash; pause/继续 label flips only on real state change; send/upload still disables the row while uploading. The `*Busy` flags still gate their handlers (no double-submit).

---

## 6. Refactor opportunities

### Refactor 1: Extract a locked status snapshot for frame/color/stat fields
**Category:** extraction / state cleanup
**Location:** `src/web_api.cpp` `handleApiStatus`, `handleApiFrame`, `handleApiCommand`; `src/led_renderer.cpp`.
**Current problem:** Status handlers read `Frame`-owned fields (`colorHex`, `brightness`, `lastM370`, `lastReason`, `framesAccepted`, lit count) without taking `Frame`. Mirrors the missing-snapshot half of Bug 1.
**Why this is safe (as pure refactor of the read pattern):** Introducing a snapshot that copies fields under `withFrameLock` does not change any emitted JSON values in the single-threaded common case; it only makes reads atomic. (The behavior-changing part — fixing the race — is Bug 1; this refactor provides the seam.)
**What should change:** Add `struct FrameStateSnapshot` + `readFrameStateSnapshot()` next to `readScrollStateSnapshot()`. Status code reads from the snapshot.
**What must not change:** JSON field names, value formatting (`colorHex` string form, `lit` semantics), order is irrelevant to clients.
**Dependencies:** Bug 1 fix builds on this seam.
**Implementation steps:** (1) Define snapshot struct. (2) Implement reader copying under `withFrameLock` (compute lit from a local frameBits copy). (3) Replace direct reads in `handleApiStatus`/`handleApiFrame`/`handleApiCommand`. (4) Diff JSON output.
**Regression risk:** Low.
**Code change:** ⬜ (mirrors the existing `readScrollStateSnapshot()` pattern)
```cpp
// --- EXISTING pattern to copy (src/web_api.cpp readScrollStateSnapshot):
static ScrollStateSnapshot readScrollStateSnapshot() {
    ScrollStateSnapshot snapshot;
    withScrollLock([&]() { /* copy scroll fields + memcpy timelineId under lock */ });
    return snapshot;
}
// --- PROPOSED sibling for Frame-owned fields (see Bug 1 for the struct + reader):
const FrameStateSnapshot fs = readFrameStateSnapshot();
renderer["color"] = fs.colorHex; renderer["lit"] = fs.litLeds; /* etc. — same field names */
```

**Validation method:** Byte-diff of `/api/status` JSON for a fixed state before/after.

### Refactor 2: Split the 277-line `/api/scroll` handler into named phases
**Category:** extraction / modularization
**Location:** `src/web_api.cpp handleApiScroll` (660–937).
**Current problem:** One function performs: method/body guards, timing parse, flag parse, meta-id validation, first-chunk vs append branching, frame stream parse, completion bookkeeping, autostart decision, and reply build. Very hard to modify safely.
**Why this is safe:** Pure extraction of contiguous blocks into `static` helpers with the same locals passed by reference; no logic reordered.
**What should change:** Extract `parseScrollUploadHeader(body, …)`, `beginFirstChunkLocked(…)`, `validateAppendChunkLocked(…)`, `parseAndStoreFrames(body, pos, …)`, `finalizeScrollChunkLocked(…)`, `buildScrollReply(…)`.
**What must not change:** Lock acquisition points and ordering (`Scroll` snapshot/commit boundaries), all HTTP status codes (400/409/413/507) and their messages, the EH-A/EH-B/EH-C/D1–D8 invariants encoded in comments, and the exact field set of the reply.
**Dependencies:** None; do before Bug-fix work in this handler.
**Implementation steps:** Extract one block at a time, compile + run the scroll upload integration test after each extraction.
**Regression risk:** Medium (lock boundaries are subtle) → enforce "one block per commit + test".
**Code change:** ⬜ (illustrative target shape — extract contiguous blocks, no logic moved)
```cpp
// --- CURRENT: one 277-line function (src/web_api.cpp handleApiScroll, 660–937).
// --- PROPOSED orchestrator over phase helpers (locks/order/status codes unchanged):
static void handleApiScroll() {
    if (!scrollMethodAndBufferOk()) return;          // method/body/buffer-ready guards (sends its own errors)
    ScrollUploadHeader h;
    if (!parseScrollUploadHeader(body, h)) return;   // timing, flags, meta-id validation → 400/413/507
    if (!h.appendFrames) { if (!beginFirstChunkLocked(h)) return; }   // clear meta + store first-chunk meta under Scroll
    else                 { if (!validateAppendChunkLocked(h)) return; } // EH-B/D3 chunk-order checks → 409
    ScrollParseResult r;
    if (!parseAndStoreFrames(body, h, r)) return;    // stream frames into buffer; E1/EH-A invalidation
    finalizeScrollChunkLocked(h, r);                 // frame count, uploadComplete, autostart decision
    buildScrollReply(h, r);                          // identical reply field set
}
```

**Validation method:** Full scroll upload/restore integration test (single chunk, multi chunk, 409 retry, oversize, bad frame) green after each step.

### Refactor 3: Unify the two near-identical send queues (frame + button command)
**Category:** deduplication
**Location:** `data/app.js` 4959–5141 (`scheduleButtonCommandPump`/`pumpButtonCommandQueue`/`sendButtonCommand` vs `scheduleFrameSendPump`/`pumpFrameSendQueue`/`queueFirmwareFrame`).
**Current problem:** Two copies of the same rate-limited, drop-on-overflow, in-flight-guarded pump differing only in endpoint/interval/queue-max/counter names.
**Why this is safe:** Behavior is identical modulo parameters; a parameterized `makeRateLimitedQueue({endpoint, intervalMs, maxDepth, onResult, …})` reproduces both.
**What should change:** Introduce one factory; instantiate for frames and buttons.
**What must not change:** `WEBUI_M370_SEND_INTERVAL_MS`/`WEBUI_BUTTON_COMMAND_INTERVAL_MS`, queue maxes, drop semantics (shift oldest, bump `dropped*`), `firmware.frameQueue/buttonQueue` reporting, fallback invocation, `applyFirmwareRuntimeState` on success.
**Dependencies:** None.
**Implementation steps:** (1) Write factory matching current button pump exactly. (2) Swap button queue to it; test. (3) Swap frame queue; test. (4) Remove dead duplicates.
**Regression risk:** Medium → keep both during transition behind the factory.
**Code change:** ⬜
```js
// --- CURRENT: two near-identical pumps (data/app.js 4959–5141), differing only in
// endpoint / interval / queue-max / counter names (buttonCommand* vs frameSend*).
```
```js
// --- PROPOSED: one factory; instantiate twice with the existing constants.
function makeRateLimitedQueue({ endpoint, intervalMs, maxDepth, onResult /* optional */ }) {
  let queue = [], inFlight = false, timer = 0, lastAt = 0;
  function schedule(delay = 0) { /* clearTimeout + setTimeout(pump, max(0,delay)) */ }
  function pump() {
    if (inFlight) return;
    if (!queue.length) { /* report depth 0 */ return; }
    const wait = Math.max(0, intervalMs - (performance.now() - lastAt));
    if (wait > 0) return schedule(wait);
    const q = queue.shift(); inFlight = true; lastAt = performance.now();
    apiPost(endpoint, q.request)
      .then((d) => { if (onResult) onResult(d, q.source); q.resolve?.(d); })
      .catch((e) => { q.fallback?.(); q.resolve?.(null); })
      .finally(() => { inFlight = false; schedule(0); });
  }
  return { enqueue(request, { source, fallback } = {}) {
    if (queue.length >= maxDepth) { queue.shift()?.resolve?.(null); /* ++dropped */ }
    /* push {request, source, fallback, promise/resolve}; schedule(0); return promise */
  }};
}
const frameQueue  = makeRateLimitedQueue({ endpoint: API_ENDPOINTS.frame,   intervalMs: WEBUI_M370_SEND_INTERVAL_MS,      maxDepth: WEBUI_M370_QUEUE_MAX });
const buttonQueue = makeRateLimitedQueue({ endpoint: API_ENDPOINTS.command, intervalMs: WEBUI_BUTTON_COMMAND_INTERVAL_MS, maxDepth: WEBUI_BUTTON_COMMAND_QUEUE_MAX, onResult: applyFirmwareRuntimeState });
```

**Validation method:** Burst test (queue overflow) shows identical drop counts and ordering before/after.

### Refactor 4: Centralize firmware lock contract enforcement via scoped accessors
**Category:** structure / state cleanup
**Location:** `src/state.*`, all writers of `RuntimeState`.
**Current problem:** The lock-owner contract is documented in `state.h` comments but enforced by convention. Several writes to `restoreAutoAfterScroll` and scroll fields happen outside `Scroll` in `buttons.cpp`/`web_api.cpp`.
**Why this is safe:** Wrapping existing access in `withScrollLock`/`withFrameLock` where the contract already requires it does not change behavior on the cooperative Core-0 path; it closes latent gaps.
**What should change:** Audit each `runtimeState().<lock-owned field>` write; ensure it is inside the correct lock or explicitly Core-0-only with a comment.
**What must not change:** No new nested-lock orderings (preserve `Scroll → Frame → HardwareBus`).
**Dependencies:** Interacts with Bug 1/Refactor 1.
**Implementation steps:** Grep each field; classify; wrap or annotate.
**Regression risk:** Medium (over-locking could deadlock if ordering violated) → review every wrap against the global order.
**Code change:** ⬜
```cpp
// --- CURRENT: lock-owned fields written ad hoc, some outside their lock, e.g.
runtimeState().restoreAutoAfterScroll = false;            // buttons.cpp (no Scroll lock)
runtimeState().scrollFrameCount = 0;                      // various
```
```cpp
// --- PROPOSED: route lock-owned writes through scoped setters that assert/take the lock.
// (Example; see Refactor 6/7 for the concrete pause + restoreAuto setters.)
static inline void withScrollState(const std::function<void()>& fn) { withScrollLock(fn); }
// All callers: withScrollState([]{ runtimeState().restoreAutoAfterScroll = false; });
// Preserve global order Scroll -> Frame -> HardwareBus(-> Storage); never nest in reverse.
```

**Validation method:** Static review checklist + scroll/status stress test.

### Refactor 5: Decompose `applyFirmwareRuntimeState` (260 lines) into field-group appliers
**Category:** extraction
**Location:** `data/app.js` 4664–4923.
**Current problem:** One function merges AP, power, mode, interval, playback/scroll flags, brightness, color, face index, frame, scroll-stop detection, and timeline-mismatch re-fetch. Hard to reason about; central to most UI bugs (4, 5, 9).
**Why this is safe:** Pure extraction into `applyApFields`, `applyPowerFields`, `applyModeInterval`, `applyScrollFlags`, `applyBrightnessColor`, `applyFaceAndFrame`, `detectScrollStop`, `maybeRestoreTimeline`, each returning a `changed` boolean OR'd together.
**What should change:** Function bodies move; the orchestrator calls them in the same order and aggregates `stateChanged`.
**What must not change:** Order of application (later fields depend on earlier, e.g. `firmwareIsScrolling` computed after playback flags), the single trailing `if (stateChanged) renderState()`, and all source-string semantics.
**Dependencies:** Do before Bug 4/5/9 fixes so each fix lands in a focused helper.
**Implementation steps:** Extract bottom-up, preserving shared locals; test polling after each extraction.
**Regression risk:** Medium → snapshot UI state transitions for a recorded status sequence before/after.
**Code change:** ⬜
```js
// --- CURRENT: one 260-line function (data/app.js 4664–4923).
// --- PROPOSED thin orchestrator; field-group appliers keep the SAME order (later
// groups depend on earlier — e.g. firmwareIsScrolling is computed after scroll flags).
function applyFirmwareRuntimeState(data, source = "firmware_status", options = {}) {
  if (!data || typeof data !== "object") return;
  const ctx = { data, renderer: data.renderer || data, source, options, changed: false };
  applyApFields(ctx);
  applyPowerFields(ctx);
  applyModeInterval(ctx);
  applyScrollFlags(ctx);        // sets ctx.firmwareIsScrolling, scroll.* booleans
  applyBrightnessColor(ctx);    // Bug 4 + Bug 5 land here
  applyFaceAndFrame(ctx);
  detectScrollStop(ctx);        // newButtonStopEvent / fallbackButtonStop heuristics
  maybeRestoreTimeline(ctx);    // /api/scroll/meta re-fetch on timeline mismatch
  if (ctx.changed) renderState();
}
```

**Validation method:** Replay a captured `/api/status` sequence through the function and diff resulting `state`/`scroll` objects.

### Refactor 6: Model firmware scroll pause as one source-of-truth + derived effective flag
**Category:** state cleanup
**Location:** `src/faces.cpp` `applyFirmwareScrollPauseIntentLocked`, `state.h` scroll fields.
**Current problem:** `firmwareScrollPaused` (effective) is stored alongside `User`/`System` and `paused`, with derivation logic spread across functions.
**Why this is safe:** `firmwareScrollPaused` and `paused` are already computed from `User||System`; making the derivation a single helper does not change outputs.
**What should change:** A single `recomputeEffectivePauseLocked()` that sets `firmwareScrollPaused` and `playback` from the two intents; callers only set intents.
**What must not change:** Wire fields (`firmwareScrollUserPaused/SystemPaused/Paused`) must still be emitted; `playback` strings (`scroll`/`scroll_paused`) unchanged.
**Dependencies:** None.
**Regression risk:** Low.
**Code change:** ⬜
```cpp
// --- CURRENT (src/faces.cpp applyFirmwareScrollPauseIntentLocked): derivation inline,
// mixed with the early-out for the no-frames case.
runtimeState().firmwareScrollActive = true;
runtimeState().firmwareScrollPaused = effectivePaused;   // = user || system
runtimeState().paused = effectivePaused;
if (effectivePaused) runtimeState().playback = "scroll_paused";
else { runtimeState().lastScrollFrameMs = millis(); runtimeState().playback = "scroll"; }
```
```cpp
// --- PROPOSED: single source-of-truth derivation; callers set only the two intents.
static void recomputeEffectivePauseLocked() {
    const bool eff = runtimeState().firmwareScrollUserPaused ||
                     runtimeState().firmwareScrollSystemPaused;
    runtimeState().firmwareScrollPaused = eff;
    runtimeState().paused               = eff;
    runtimeState().playback             = eff ? "scroll_paused" : "scroll";
    if (!eff) runtimeState().lastScrollFrameMs = millis();
}
// setFirmwareScrollPauseFlag(): set user/system intent, then recomputeEffectivePauseLocked().
// Wire fields (firmwareScrollUserPaused/SystemPaused/Paused) + playback strings unchanged.
```

**Validation method:** Pause matrix test: user-pause, system-pause (B6), both, neither → identical emitted flags before/after.

### Refactor 7: Consolidate `restoreAutoAfterScroll` writes under `Scroll` lock + one setter
**Category:** state cleanup / deduplication
**Location:** `buttons.cpp` (134, 183), `faces.cpp` (62–65, 384), `web_api.cpp` (1248).
**Current problem:** Written from several call sites, some outside `Scroll`.
**Why this is safe:** A single `setRestoreAutoAfterScroll(bool)` that takes the lock centralizes the (already Core-0) writes.
**What must not change:** The semantic that B1/B2/mode-toggle clear it and `terminate_other_activities targetMode=scroll` sets it.
**Regression risk:** Low.
**Code change:** ⬜
```cpp
// --- CURRENT: scattered (buttons.cpp 134/183, faces.cpp 62–65/384, web_api.cpp 1248),
// some outside the Scroll lock:
runtimeState().restoreAutoAfterScroll = false;
runtimeState().restoreAutoAfterScroll = true;
```
```cpp
// --- PROPOSED: one setter under Scroll lock; all call sites use it.
void setRestoreAutoAfterScroll(bool v) {
    withScrollLock([&]() { runtimeState().restoreAutoAfterScroll = v; });
}
// Semantics preserved: B1/B2/mode-toggle clear it; terminate_other_activities(scroll) sets it.
```

**Validation method:** Mode/scroll transition tests assert the flag matches today.

### Refactor 8: Extract repeated `withHardwareBusLock` file primitives
**Category:** deduplication
**Location:** `src/web_api.cpp` (`littleFsExistsLocked`/`littleFsOpenLocked`/`fileSizeLocked`/`closeFileLocked`) vs `storage.cpp`/`power_monitor.cpp` which inline the same pattern.
**Current problem:** The locked-LittleFS helpers exist only in `web_api.cpp`; `storage.cpp` and `power_monitor.cpp` re-inline `withHardwareBusLock([&]{ LittleFS… })`.
**Why this is safe:** Moving the helpers to a shared `storage`-level header and reusing them is mechanical.
**What must not change:** Lock domain (`HardwareBus`) — unless Bug 3 reassigns file I/O to a `Storage` lock, in which case do Bug 3 first and route these helpers to the new lock.
**Dependencies:** Coordinate with Bug 3.
**Regression risk:** Low–Medium (ordering vs Bug 3).
**Code change:** ⬜
```cpp
// --- CURRENT: helpers live only in web_api.cpp; storage.cpp & power_monitor.cpp re-inline:
withHardwareBusLock([&]() { exists = LittleFS.exists(SETTINGS_PATH); });   // storage.cpp
withHardwareBusLock([&]() { calibExists = LittleFS.exists(BATTERY_CALIB_PATH); }); // power_monitor.cpp
```
```cpp
// --- PROPOSED: promote to storage.h and reuse everywhere (route to the new Storage
// lock if Bug 3 lands; otherwise keep HardwareBus — do Bug 3 first).
bool   littleFsExistsLocked(const String& path);
File   littleFsOpenLocked(const String& path, const char* mode);
size_t fileSizeLocked(File& f);
void   closeFileLocked(File& f);
// storage.cpp / power_monitor.cpp: exists = littleFsExistsLocked(SETTINGS_PATH);  // one domain
```

**Validation method:** File ops unit tests; ensure single lock domain per call.

### Refactor 9: Replace overlapping WebUI scroll booleans with derived predicates
**Category:** state cleanup
**Location:** `data/app.js` `scroll` object + `isScrollPlaybackValue`, `state.textScrollActive`.
**Current problem:** `scroll.active/paused/userPaused/systemPaused/firmwareBacked` + `state.textScrollActive` + `state.playback` overlap; updated in multiple places (drift risk behind Bug 9).
**Why this is safe:** Introduce pure predicates (`isScrolling()`, `isUserPaused()`, `isSystemPaused()`) derived from the firmware-truth fields; keep storing only the firmware-provided flags.
**What should change:** Replace scattered boolean writes with derivations where possible; keep only fields that the firmware authoritatively provides.
**What must not change:** `updateScrollUi` outputs (button enabled/labels), upload/restore gating booleans (`uploading/startBusy/restoring` are local control flags, keep them).
**Dependencies:** After Refactor 5.
**Regression risk:** Medium → cover with `updateScrollUi` snapshot tests.
**Code change:** ⬜
```js
// --- CURRENT: overlapping stored booleans recomputed in many places
scroll.active; scroll.paused; scroll.userPaused; scroll.systemPaused; scroll.firmwareBacked;
state.textScrollActive; state.playback;   // partially duplicate firmware truth
```
```js
// --- PROPOSED: store only firmware-provided truth; derive the rest via pure predicates.
function isScrolling()   { return scroll.firmwareBacked || isScrollPlaybackValue(state.playback); }
function isUserPaused()  { return scroll.userPaused; }
function isSystemPaused(){ return scroll.systemPaused && !scroll.userPaused; }
function isEffectivePaused() { return isUserPaused() || isSystemPaused() || state.playback === "scroll_paused"; }
// updateScrollUi() reads the predicates; control flags (uploading/startBusy/restoring) stay as fields.
```

**Validation method:** For a matrix of firmware scroll states, assert identical button DOM state before/after.

### Refactor 10: Name and table-drive the command dispatch reply assembly
**Category:** structure
**Location:** `web_api.cpp handleApiCommand` reply block (1335–1360) + per-command handlers.
**Current problem:** The shared reply is hand-assembled; battery commands special-case power. Adding a command requires editing multiple spots.
**Why this is safe:** Extract `buildCommandReply(cmd, scrollState)` and a `commandWantsPower(cmd)` predicate; no field changes.
**What must not change:** Reply field set and the `sCommandErrorStatus` 400/409 mapping.
**Regression risk:** Low.
**Code change:** ⬜
```cpp
// --- CURRENT (src/web_api.cpp handleApiCommand): reply hand-assembled inline + battery special-case
reply["color"] = runtimeState().colorHex; /* ...~20 fields... */
if (cmd == "reset_battery_min" || cmd == "reset_battery_max") {
    servicePowerMonitor(true);
    addPowerStatus(reply.createNestedObject("power"), true, true);
}
```
```cpp
// --- PROPOSED: extract builder + predicate; identical field set + 400/409 mapping kept.
static void buildCommandReply(JsonObject reply, const String& cmd, const ScrollStateSnapshot& s) {
    /* exactly today's fields */
}
static bool commandWantsPower(const String& cmd) {
    return cmd == "reset_battery_min" || cmd == "reset_battery_max";
}
// handleApiCommand(): buildCommandReply(...); if (commandWantsPower(cmd)) { servicePowerMonitor(true); addPowerStatus(...); }
```

**Validation method:** Reply JSON diff per command.

### Refactor 11: Comment/identifier cleanup (auto-generated Chinese boilerplate)
**Category:** comments
**Location:** Throughout `src/*` and `data/*` — repeated template comments like `// 中文块：执行对应逻辑 X 相关逻辑，连接 WebUI 状态、DOM 和固件 API。` and `// 说明 … 中当前代码块的职责和维护约束。`
**Current problem:** Many comments are auto-generated placeholders adding noise without information; some functions have a generic banner that doesn't describe behavior.
**Why this is safe:** Comments only; zero behavior impact.
**What should change:** Replace placeholder banners with one-line behavioral descriptions or delete; keep the genuinely informative invariant comments (EH-A/B/C, D1–D8, lock contracts, drift logic).
**What must not change:** The invariant/contract comments and the `SYNCTEST_MARKER`/cache-version markers in HTML.
**Regression risk:** Low (avoid touching `?v=` cache-busting strings and any string-matched markers).
**Code change:** ⬜
```cpp
// --- CURRENT: auto-generated placeholder banners add noise, e.g.
// 中文块：执行对应逻辑 logicalToPhysicalIndex 相关逻辑，连接 WebUI 状态、DOM 和固件 API。
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
```
```cpp
// --- PROPOSED: replace with a one-line behavioral description, or delete.
// logical→physical serpentine index for one LED (odd rows reversed).
// KEEP the informative invariant comments verbatim: EH-A/B/C, D1–D8, E1–E6, lock order,
// scroll drift logic, and the HTML "?v=..." cache markers / SYNCTEST_MARKER.
```

**Validation method:** Build + grep that protected markers still present.

### Refactor 12: Gate hot-path `Serial.printf` behind a log-level switch
**Category:** performance
**Location:** `faces.cpp serviceAutoPlayback`/`applySavedFaceIndex`, `scroll.cpp`, `power_monitor.cpp`.
**Current problem:** Per-frame/per-apply `Serial.printf` runs even in normal operation; blocking UART writes add jitter on Core 0.
**Why this is safe:** Wrapping in a compile-time/runtime verbosity guard preserves messages when enabled.
**What must not change:** Error/warning messages on failure paths remain by default; default-on messages users may rely on for diagnostics should stay unless clearly redundant.
**Regression risk:** Low.
**Code change:** ⬜
```cpp
// --- CURRENT: unconditional hot-path logging (src/faces.cpp serviceAutoPlayback / applySavedFaceIndex):
Serial.printf("Applied saved face %u/%u via %s: %s\n", ...);   // every auto switch
```
```cpp
// --- PROPOSED: gate verbose logs; keep error/warning paths on by default.
#ifndef RINA_LOG_VERBOSE
#define RINA_LOG_VERBOSE 0
#endif
#define LOGV(...) do { if (RINA_LOG_VERBOSE) Serial.printf(__VA_ARGS__); } while (0)
// hot path: LOGV("Applied saved face %u/%u via %s: %s\n", ...);
// failure path stays: Serial.printf("auto face apply failed: %s\n", error.c_str());
```

**Validation method:** Measure Core-0 loop jitter with logging off vs on.

### Refactor 13: Extract LittleFS logic from `loadSavedFaces`
**Category:** modularization
**Location:** `src/storage.cpp` `loadSavedFaces` (238–364).
**Current problem:** `loadSavedFaces` does file I/O, parses JSON under the hardware bus lock, extracts fields, normalizes M370, populates the runtime array directly, and triggers apply/startup logic.
**Why this is safe:** Splitting into `parseAndValidateFaces` and `applyFacesToState` makes the function testable in isolation.
**What must not change:** The startup face default precedence logic and sorting.
**Code change:** ⬜
```cpp
// --- CURRENT: one function (src/storage.cpp loadSavedFaces 238–364) does I/O + parse +
// field extraction + M370 normalize + array fill + sort + startup apply.
// --- PROPOSED split (same behavior, testable pieces):
static bool parseAndValidateFaces(JsonArrayConst faces, const String& startupId,
                                  RuntimeFace* out, uint16_t& count);  // pure-ish: fills array, no apply
static void applyFacesToState(uint16_t selectedIndex, bool applyStartupFace); // side effects
bool loadSavedFaces(bool applyStartupFace) {
    /* open+read+deserialize under lock (Refactor 8 helpers) */
    parseAndValidateFaces(faces, startupId, runtimeAutoFaces(), runtimeAutoFaceCount());
    /* existing std::sort + selectedIndex precedence stays identical */
    applyFacesToState(selectedIndex, applyStartupFace);
}
```
**Regression risk:** Medium.
**Validation method:** Unit tests for `parseAndValidateFaces` with various JSON structures.

### Refactor 14: Extract `sampleBattery` disconnect logic into helper
**Category:** structure / extraction
**Location:** `src/power_monitor.cpp` `sampleBattery` (281–372).
**Current problem:** A single 90-line function implements EMA filtering, large-drop disconnect detection, recovery, calibration updates, and JSON field dirtying.
**Why this is safe:** Extracting pure logic (e.g., `detectBatteryDisconnect(adcMv, prevMv)`) keeps side-effects in the caller.
**What must not change:** The hysteresis values (`BATTERY_DISCONNECT_ADC_DROP_MV`, `BATTERY_RECONNECT_ADC_MV`).
**Code change:** ⬜
```cpp
// --- CURRENT (src/power_monitor.cpp sampleBattery): disconnect detection inlined
const bool hugeRawDrop = hadPreviousAdc && prevAdcMv > adcMv &&
    static_cast<uint16_t>(prevAdcMv - adcMv) >= BATTERY_DISCONNECT_ADC_DROP_MV &&
    adcMv <= BATTERY_DISCONNECT_ADC_LOW_MV;
const bool stillDisconnected = powerStatus.batteryDisconnected && adcMv < BATTERY_RECONNECT_ADC_MV;
```
```cpp
// --- PROPOSED: pure helper, same thresholds; sampleBattery keeps the side effects.
struct BatteryEdge { bool hugeRawDrop; bool stillDisconnected; };
static BatteryEdge detectBatteryDisconnect(uint16_t adcMv, uint16_t prevAdcMv,
                                           bool hadPrev, bool wasDisconnected) {
    const bool drop = hadPrev && prevAdcMv > adcMv &&
        static_cast<uint16_t>(prevAdcMv - adcMv) >= BATTERY_DISCONNECT_ADC_DROP_MV &&
        adcMv <= BATTERY_DISCONNECT_ADC_LOW_MV;
    return { drop, wasDisconnected && adcMv < BATTERY_RECONNECT_ADC_MV };
}
```
**Regression risk:** Low.
**Validation method:** Hardware disconnect test (pulling battery during operation).

---

## 7. Proposed target architecture

The change is **organizational**, not a rewrite. Module boundaries are already good; the goal is clearer seams between **state**, **transport**, **rendering**, **protocol**, and **persistence**, plus enforced locking.

### 7.1 Firmware modules (proposed)
- `state` (unchanged role): owns `RuntimeStore`; add `readFrameStateSnapshot()`/`readScrollStateSnapshot()` as the **only** sanctioned cross-core read path. Add `setRestoreAutoAfterScroll()` and `recomputeEffectivePauseLocked()` setters so writers go through one place.
- `sync` (unchanged): keep the three mutexes and global order. Consider a fourth `Storage` mutex **only if** Bug 3 confirms flash and LED do not share hardware (then `HardwareBus` ⇒ strictly LED bus).
- `led_renderer`: keep render/codec/queue. Frame queue stays Core-0-owned (documented). Publish directly from queue slot (Bug 11).
- `scroll`: render task; fix frame-apply (Bug 2).
- `faces`: mode + deferred-restore + scroll lifecycle; pause derivation centralized (Refactor 6).
- `storage`: owns the locked-LittleFS primitives (Refactor 8); repair-on-corrupt (Bug 6).
- `power_monitor`: stage overlay-relevant fields into `sAnim` under `sAnimMux` (Bug 8).
- `web_api`: split `handleApiScroll` into phase helpers (Refactor 2); table-driven command reply (Refactor 10); read state via snapshots (Refactor 1).
- `web_json`, `psram_json`, `utils`, `config`: unchanged.

### 7.2 Web UI structure (proposed, still single-file unless asked)
- **Transport layer**: `apiGet/apiPost/apiPostWithUploadProgress` (unchanged) + one `makeRateLimitedQueue` factory powering both send queues (Refactor 3).
- **Sync layer**: `applyFirmwareRuntimeState` becomes a thin orchestrator over pure-ish field appliers (Refactor 5); `setColor` short-circuits firmware-sync no-ops (Bug 5).
- **Scroll subsystem**: keep upload/restore state machine; isolate chunk-size estimation (Bug 10).
- **State layer**: keep `state`/`firmware`; reduce `scroll` booleans to firmware-truth + derived predicates (Refactor 9).
- **Render layer**: `renderMatrices`/`renderState`/`updateScrollUi` unchanged outputs.

### 7.3 Pure functions vs side-effect owners
- **Pure (no I/O/DOM):** M370 codec (`m370ToFrame`/`frameToM370`/firmware codec), color/hex/utf-8 validators, battery LUT, `chooseFirstChunkFrames` (after Bug 10), field appliers that only mutate the passed snapshot.
- **Side-effect owners:** the queues (network), `renderCurrentFrameToLedStrip` (LED bus), `writeJsonFileAtomic` (flash), `service*` loop functions, DOM `render*`.

### 7.4 Centralize vs keep local
- **Centralize:** cross-core firmware reads (snapshots), firmware pause derivation, `restoreAutoAfterScroll`, WebUI scroll truth.
- **Keep local:** UI control flags (`uploading/startBusy/restoring/pauseToggleLocked`), DOM-diff caches, upload progress token, firmware frame queue (Core-0 only).
- **Derive, don't store:** `state.textScrollActive` (from playback + flags); WebUI effective pause.

No code is written in this section — names are proposals only.

---

## 8. Step-by-step implementation plan

Ordering principle: low-risk pure refactors and comment cleanup first; then state-snapshot seams; then bug fixes that depend on those seams; timing/perf last. Bug 3 (timing) and Bug 7 (lock safety) are scheduled where they unblock or de-risk later work.

### Phase 1: Baseline behavior documentation
**Goal:** Freeze current observable behavior as a test baseline.
**Allowed changes:** Test/harness files, captured fixtures (status JSON samples, scroll upload transcripts). No `src/`/`data/` logic edits.
**Forbidden changes:** Any firmware/UI logic.
**Files affected:** new `test/` fixtures, a Node script to replay status JSON through a copy of `applyFirmwareRuntimeState` (or DOM-less harness).
**Exact steps:** (1) Capture `/api/status` (all query variants), `/api/scroll` request/response transcripts, `/api/command` replies for each command. (2) Record LED `show()` cadence during idle/scroll/save via `micros()` logging. (3) Snapshot `updateScrollUi` DOM state for the pause matrix.
**Expected behavior after phase:** Unchanged.
**Tests after phase:** Baseline fixtures committed and reproducible.
**Rollback:** Delete test artifacts.

### Phase 2: Comment / identifier cleanup (Refactor 11)
**Goal:** Remove auto-generated placeholder comments; keep invariant comments.
**Allowed:** Comments only; whitespace.
**Forbidden:** Any token that is string-matched (`?v=` cache versions, `SYNCTEST_MARKER`, command names, JSON keys, DOM ids).
**Files affected:** `src/*`, `data/app.js`, `data/index.html` (comments only).
**Exact steps:** Replace/delete placeholder banners; preserve EH-/D-/lock/drift comments.
**Expected behavior:** Identical build output (only comments differ).
**Tests:** Firmware builds; UI loads; protected-marker grep passes.
**Rollback:** `git revert`.

### Phase 3: Extract pure helpers (Refactors 2, 3, 5, 10) — no behavior change
**Goal:** Break up the three giant functions and the duplicated queues.
**Allowed:** Function extraction with identical logic/ordering/lock points.
**Forbidden:** Reordering lock acquisitions; changing JSON fields, status codes, intervals.
**Files affected:** `web_api.cpp`, `app.js`.
**Exact steps:** One extraction per commit, each followed by the Phase-1 regression suite. Do `handleApiScroll` (R2) and command reply (R10) on firmware; queue factory (R3) and `applyFirmwareRuntimeState` decomposition (R5) on UI.
**Expected behavior:** Byte-identical API responses; identical queue drop behavior; identical UI transitions on replay.
**Tests:** Phase-1 fixtures green after every commit.
**Rollback:** Revert the offending extraction commit.

### Phase 4: State snapshot + lock-contract seams (Refactors 1, 4, 6, 7, 8)
**Goal:** Route cross-core reads/writes through sanctioned snapshots/setters.
**Allowed:** Adding snapshot readers/setters; wrapping existing accesses in the already-required lock.
**Forbidden:** New nested-lock orders; changing the global lock order.
**Files affected:** `state.*`, `web_api.cpp`, `faces.cpp`, `buttons.cpp`, `storage.cpp`, `power_monitor.cpp`.
**Exact steps:** (1) Add `readFrameStateSnapshot()` and switch status/frame/command reads to it. (2) Centralize `restoreAutoAfterScroll` + pause derivation. (3) Move locked-LittleFS helpers to `storage`.
**Expected behavior:** Identical JSON; no functional change in single-threaded use; reads now atomic.
**Tests:** API JSON diff = identical; dual-tab polling-during-scroll heap-integrity check passes.
**Rollback:** Revert; snapshots are additive.

### Phase 5: Separate side effects (part of Refactor 9 prep + Bug 5 seam)
**Goal:** Make `setColor` firmware-sync a true no-op when unchanged; isolate WebUI scroll-truth derivation.
**Allowed:** Reordering the early-return in `setColor`; adding derived predicates.
**Forbidden:** Changing user-initiated color behavior; changing emitted commands.
**Files affected:** `app.js`.
**Exact steps:** Move `unchangedFirmwareSync` early-return above DOM/render side effects (Bug 5); add `isScrolling()/isUserPaused()/isSystemPaused()` predicates without removing fields yet.
**Expected behavior:** No dropdown reset / matrix re-render on unchanged color polls; everything else identical.
**Tests:** Bug 5 UI tests; render-counter assertions.
**Rollback:** Revert.

### Phase 6: Fix confirmed bugs (2, 4, 5, 6, 9, 11, 12 round-trip)
**Goal:** Land the focused, low-risk correctness fixes.
**Allowed:** The specific edits in each bug's Fix strategy.
**Forbidden:** Touching timing (Phase 8) or lock topology (Phase 7).
**Files affected:** `scroll.cpp` (B2), `app.js` (B4, B5, B9), `storage.cpp` (B6), `led_renderer.cpp` (B11), tests (B12).
**Exact steps:** One bug per commit + its validation test.
**Expected behavior:** Each bug's "Expected behavior" met; no other change.
**Tests:** Per-bug validation tests (Section 10).
**Rollback:** Per-commit revert.

### Phase 7: Lock-safety hardening (Bug 7) and overlay power snapshot (Bug 8)
**Goal:** Fail safe if mutex creation fails; remove overlay cross-core power read.
**Allowed:** Skip Core-1 task on mutex failure + diagnostic; stage power fields into `sAnim`.
**Forbidden:** Changing the lock order.
**Files affected:** `main.cpp`, `sync.cpp`, `button_animations.cpp`, `power_monitor.cpp`.
**Exact steps:** (1) `if (!initSyncPrimitives()) { /* diagnostic; do not startScrollRenderTask */ }` and route rendering on Core 0. (2) Populate battery overlay fields under `sAnimMux`.
**Expected behavior:** Normal boot unchanged; fault-injection runs single-core safely.
**Tests:** Fault-injection (Bug 7), overlay consistency stress (Bug 8).
**Rollback:** Revert; both are additive guards.

### Phase 8: Performance-sensitive paths (Bug 3, Bug 10, Refactor 12)
**Goal:** Stop file I/O from stalling LED refresh; speed up first-chunk sizing; gate hot logs.
**Allowed:** Reassign storage I/O off `HardwareBus` (after hardware confirmation); estimate chunk size; log gating.
**Forbidden:** Changing atomic-write semantics; changing wire protocol.
**Files affected:** `storage.cpp`, `web_api.cpp` (streaming), `app.js` (B10), hot-path logs.
**Exact steps:** (1) Confirm WS2812 (RMT/GPIO) vs LittleFS (flash) independence; if independent, remove `HardwareBus` from file content I/O or add a `Storage` mutex. (2) Replace shrink-loop with estimate+verify. (3) Gate logs.
**Expected behavior:** No scroll hitch during saves; faster long-text send; identical outputs.
**Tests:** Bug 3 timing test, Bug 10 bench, atomicity test.
**Rollback:** Revert; keep `HardwareBus`-over-IO if any corruption observed.

### Phase 9: Reduce overlapping WebUI scroll state (Refactor 9 completion)
**Goal:** Remove now-derivable booleans.
**Allowed:** Delete fields fully replaced by predicates.
**Forbidden:** Changing `updateScrollUi` outputs.
**Files affected:** `app.js`.
**Exact steps:** Replace remaining reads with predicates; delete dead fields; keep control flags.
**Expected behavior:** Identical UI.
**Tests:** `updateScrollUi` snapshot matrix green.
**Rollback:** Revert.

### Phase 10: Final cleanup and full regression
**Goal:** Remove dead code, re-run everything.
**Allowed:** Dead-code removal, final doc updates.
**Forbidden:** New behavior.
**Files affected:** any with leftovers.
**Tests:** Full Section 11 regression plan + manual hardware pass.
**Rollback:** Revert.

---

## 9. Behavior preservation checklist

Must remain unchanged through Phases 1–10 (except where a bug fix explicitly and justifiably changes it — only Bug 3 changes timing, only Bug 5/4 change UI-render cadence):

- **Public HTTP routes & methods:** `/`, `/index.html`, `/api/status` (GET/OPTIONS), `/api/power` (GET/OPTIONS), `/api/frame` (POST/OPTIONS), `/api/scroll`, `/api/scroll/meta` (GET/OPTIONS), `/api/command` (POST/OPTIONS), `/api/saved_faces` (GET/POST/OPTIONS), static fallback.
- **JSON request fields:** scroll upload (`frames`, `append`, `start`, `chunkIndex`, `totalFrames`, `timelineId`, `sourceText`, `fontId`, `generatorVersion`, `fps`, `intervalMs`, `source`, `storage`, `persist`, `saveToFlash`, `stepLedPerFrame`); command (`cmd`, `payload`, per-command keys); frame (`m370`, `mode`, `playback`, `reason`, `faceId`).
- **JSON response fields:** every key in `handleApiStatus`/`handleApiFrame`/`handleApiCommand`/`handleApiScroll`/`handleApiScrollMeta`/`handleApiPower` replies (e.g. `ok`, `v`, `version`, `next_poll_ms`, `renderer.*`, `power.*`, `stats.*`, `scrollStopEvent.*`, `uploadComplete`, `timelineId`, `lit`, `lastM370`). Field **names and value types**.
- **Status codes & messages:** 200/204/400/404/405/409/413/500/503/507 and their exact error strings (E1/E2/E3/D1–D8 paths).
- **`stateVersion`/`since` long-poll contract:** monotonic non-zero, `unchanged` short response shape.
- **DOM IDs/classes:** all in `index.html` consumed by `app.js`/`styles.css` (`matrix-*`, `scroll-*`, `brightness-*`, `color-*`, `mode-toggle`, `data-gpio` values, `face-library-list`, etc.).
- **Event names / button semantics:** B1 next, B2 prev, B3 mode, B4/B5 brightness ∓8, B3+B1/B2 interval ∓500 ms, B6 short=battery / long=continuous; combo-consume rule; repeat timings.
- **Timing behavior:** `M370_FRAME_MIN_INTERVAL_MS=33`, queue depth 3, scroll drift reset = 4 intervals, `LED_RENDER_MIN_GAP_US=2500`, `LED_SIGNAL_RESET_US=300`, boot hold/settle constants, debounce/repeat constants, `POWER_WEB_SLOW_PUBLISH_MS=10000`. (Bug 3 changes only the *contention window*, not these constants.)
- **Default values:** color `#f971d4`, brightness 50 (min10/max200), mode `manual`, playback `idle`, auto interval 3000 (min500/max10000), scroll interval 100 ms (fps default), `MAX_SCROLL_FRAMES=3072`, `MAX_AUTO_FACES=128`, `MAX_SCROLL_TEXT_BYTES=4096`.
- **Storage keys / file formats:** `saved_faces.json` (`category:"unified_saved_faces"`, `faces[]` with `order≥1`, ≥1 `type:"default"`), `runtime_settings.json` (`format:"rina_runtime_settings_v1"`, `mode`, `autoIntervalMs`), `battery_calib.json` (`rina_battery_calibration_v1`, `v_max`/`v_min`). Atomic temp+rename.
- **Protocol/hardware formats:** `M370:` + 93 hex (370 bits + 2 padding); serpentine odd-rows-reversed mapping; row lengths/offsets; WS2812 GRB.
- **User-visible text:** Chinese UI labels, error/log strings users may match on, the LittleFS-error HTML page.
- **Startup behavior:** boot LED quiet window, startup face application, AP SSID/password/IP/domain, DNS captive portal.
- **Stop/reset behavior:** blank-then-deferred-restore timing, `restoreAutoAfterScroll` semantics, scroll RAM-only contract.
- **Rendering output:** identical lit pixels/colors for identical frames; overlay glyph bitmaps unchanged.
- **Edge cases:** empty body 400, oversize 413, timeline mismatch/incomplete 409, buffer unavailable 507.

---

## 10. Bug-fix validation checklist

| Test | Mode | Setup | Steps | Expected result | Protects |
|---|---|---|---|---|---|
| BV-1 status race | Manual+instrumented | Firmware scrolling; `heap_caps_check_integrity` enabled | Two browser tabs poll `/api/status` (non-summary) for 5 min | No heap corruption; `lit`/`lastM370` never malformed | Bug 1 |
| BV-2 scroll frame skip | Manual hardware | 5 fps scroll running | Sweep brightness slider for 20 s; record with slow-mo | No skipped scroll columns; `framesAccepted` advances == index advances | Bug 2 |
| BV-3 save no-stall | Instrumented | Scroll running; 64 KB `saved_faces.json` | POST it; log `micros()` gap around `show()` | Max inter-`show` gap unchanged (no multi-ms spike); file written atomically | Bug 3 |
| BV-4 reset brightness | UI | Page loaded (default 50) | Set 120 via slider; pass ≥2 poll cycles; click 重置默认亮度 | Returns to firmware default; in-progress drag not stomped by polls | Bug 4 |
| BV-5 color no-op poll | UI | Basic page, color dropdown open | Let 3 polls pass with identical firmware color | Dropdown selection unchanged; matrix render counter does not increment | Bug 5 |
| BV-6 settings repair | Manual | Corrupt `runtime_settings.json` | Reboot | File rewritten to valid JSON; next boot parses cleanly | Bug 6 |
| BV-7 mutex fail-safe | Fault injection | Stub `initSyncPrimitives`→false | Boot | Core-1 task not started; diagnostic shown; no cross-core access | Bug 7 |
| BV-8 overlay power | Stress | B6 battery overlay held | Toggle charger input repeatedly 2 min | No percent/voltage struct-tear (logged snapshot consistent) | Bug 8 |
| BV-9 pause flags | Contract+UI | — | Inspect every `/api/status` variant; then simulate omitted split flags | All variants include split flags; with flags omitted, user-pause not inferred | Bug 9 |
| BV-10 chunk sizing | Bench | Max-length scroll text | Time `chooseFirstChunkFrames`; compare chosen count | Same chosen count; ≥10× faster | Bug 10 |
| BV-11 dequeue copy | Bench | Max frame rate | Run 1000 frames | `framesDequeued` identical; throughput ≥ before | Bug 11 |
| BV-12 m370 round-trip | Unit | — | Encode/decode frames with LEDs {0,17,369} set | Exact round-trip; padding bits ignored | Bug 12 |

---

## 11. Regression test plan

For each test, what it proves is stated.

### Unit tests
- **M370 codec round-trip** (`m370ToPackedBits`↔`frameToM370`, boundary LEDs): proves frame encoding unchanged after Refactor 1/2 and Bug 11.
- **UTF-8 / meta-id validators** (`validateScrollSourceText`, `validateMetaIdString`): proves scroll upload acceptance/rejection unchanged.
- **Battery LUT + percent interpolation**: proves power math untouched.
- **JSON field extractors** (`web_json.cpp`): proves raw-body parsing unchanged (critical for scroll uploads).
- **`chooseFirstChunkFrames`**: proves Bug 10 estimate matches brute-force result.

### Integration tests (firmware ↔ HTTP)
- **`/api/status` field/shape snapshot** for all query variants: proves Refactors 1/5/10 and Bugs 1/5 preserve the wire contract.
- **`/api/scroll` upload state machine**: single-chunk, multi-chunk, `append` ordering, 409 retry, oversize 413, bad-frame invalidate, timeline-backed incomplete block: proves Refactor 2 preserves all EH-/D- invariants.
- **`/api/command` dispatch**: each of 16 commands returns the same reply shape and status mapping: proves Refactor 10.
- **`/api/saved_faces` validate+write+reload**: proves validation and atomic write unchanged after Bug 3/Refactor 8.

### UI tests (DOM-level, replay-based)
- **`applyFirmwareRuntimeState` replay**: feed a recorded status sequence, diff resulting `state`/`scroll`: proves Refactor 5 + Bugs 4/5/9.
- **`updateScrollUi` pause matrix**: button enabled/labels for {idle, scrolling, user-paused, system-paused, both}: proves Refactor 6/9.
- **Color picker stability**: proves Bug 5.

### API/protocol tests
- **Long-poll `since` cursor**: unchanged → `unchanged` response; changed → full doc: proves `stateVersion` semantics intact.
- **`scrollStopEvent` detection**: GPIO B1/B2/B3 stop raises seq and WebUI mirrors: proves sync boundary intact.

### Timing / async tests
- **LED `show()` cadence** idle/scroll/save: proves Bug 3 fix removes save-stall without violating `LED_RENDER_MIN_GAP_US`.
- **Frame/button queue rate limit + overflow drop**: proves Refactor 3 preserves limiter.
- **Scroll drift compensation**: long-run index vs wall-clock: proves Bug 2 fix didn't disturb timing.

### State-consistency tests
- **Dual-tab polling during scroll + heap integrity**: proves Bug 1/Refactor 1.
- **Pause source-of-truth**: user vs system pause never conflated: proves Bug 9 / Refactor 6.

### Persistence tests
- **Power-loss-during-write**: old or new file intact: proves atomicity after Bug 3.
- **Corrupt settings repair**: proves Bug 6.
- **Saved-faces reload after write** selects correct index: proves `loadSavedFaces` untouched.

### Performance tests
- **Long-text send latency** (Bug 10), **dequeue throughput** (Bug 11), **Core-0 loop jitter with logs off** (Refactor 12).

### Manual hardware tests
- All 6 buttons + combos; B6 short/long battery overlay during scroll; mode toggle during scroll; brightness sweep during scroll; large saved-faces save during scroll; boot quiet window (no stray pixels).

### Failure-mode tests
- Mutex creation failure (Bug 7); scroll buffer unavailable → 507; LittleFS unmounted → error page + 503s; offline `file://` mode no-ops.

---

## 12. Risk analysis

| Risk | Why risky | What could break | Minimize | Test | Delay? |
|---|---|---|---|---|---|
| Splitting `handleApiScroll` (R2) | Subtle lock snapshot/commit boundaries + many error invariants | Wrong 409/413/507 handling; partial upload corruption | One block per commit; keep lock points identical | BV/scroll integration suite | No (Phase 3, but gated by tests) |
| Reassigning storage I/O off `HardwareBus` (Bug 3) | Changes a real timing/contention assumption | LED corruption or flash/LED contention if they *do* share a resource | Confirm WS2812 (RMT/GPIO) vs flash independence on hardware first; fall back to a `Storage` mutex | BV-3 + 1000-cycle write+show | **Yes — Phase 8**, after correctness fixes |
| Lock-contract wrapping (R4/R7) | Over-locking can deadlock if order violated | Boot hang / watchdog reset | Review every wrap against `Scroll→Frame→HardwareBus`; never nest in reverse | Scroll+status stress | Phase 4 |
| `applyFirmwareRuntimeState` decomposition (R5) | Field order dependencies | Wrong derived scroll/face state | Bottom-up extraction + replay diff | UI replay | Phase 3 |
| Reducing WebUI scroll booleans (R9) | Many call sites read them | Mislabeled pause/stop buttons | Keep predicates equivalent; snapshot matrix | `updateScrollUi` matrix | **Yes — Phase 9**, last |
| Mutex fail-safe (Bug 7) | Alters boot topology on failure | Could disable rendering if misdetected | Only trigger on genuine null handle; keep normal path identical | BV-7 fault injection | Phase 7 |
| Comment cleanup (R11) | Risk of touching string-matched markers | Broken cache-busting / sync markers | Protect `?v=`, `SYNCTEST_MARKER`, keys, ids via grep gate | marker grep | Phase 2 |

Riskiest overall: **Bug 3** (timing/hardware assumption) and **R2** (protocol-critical lock boundaries). Both are gated behind the Phase-1 baseline and dedicated tests, and Bug 3 is deferred until after all correctness fixes.

---

## 13. Things not to change

- **Wire protocol & field names** for all routes (Section 9) — unless a bug item explicitly lists a change (none do except response *cadence* in Bug 5).
- **`stateVersion`/`since` long-poll semantics** and the `unchanged` short response.
- **M370 format** (`M370:`+93 hex, 370+2 padding) and the serpentine mapping / row tables / `static_assert`s in `config.h`.
- **Lock order** `Scroll → Frame → HardwareBus`; no new nested locks.
- **Timing constants** in `config.h` (frame interval, queue depth, render gap, reset window, boot holds, debounce/repeat, slow-publish). Bug 3 changes only the *file-I/O contention window*, not these values.
- **Scroll upload invariants** EH-A/EH-B/EH-C and D1–D8 / E1–E6 encoded in `web_api.cpp`/`state.cpp` comments — preserve exactly; only re-home them during extraction.
- **Atomic write semantics** (temp + rename + remove-temp-on-fail).
- **Battery auto-calibration stays disabled** (manual reset only) — do not re-enable.
- **Excluded hardware** (I2C PMIC / PD / temperature) — do not add.
- **Boot LED quiet-window sequence** in `setup()` — order is timing-sensitive; do not reorder.
- **DOM IDs/classes/`data-gpio` values** and `?v=` cache markers in `index.html`.
- **Working-but-ugly code where behavior is unclear:** the drift-compensation math in `scrollRenderTask`, the EMA/disconnect heuristics in `power_monitor.cpp`, and the `applyFirmwareRuntimeState` scroll-stop heuristics (`fallbackButtonStop` regex) — refactor *structure* only, keep logic byte-for-byte until covered by tests.
- **The Core-0 service order** in `loop()` (semantic per its comment).

---

# Addendum: Additional Audit Pass From `prompt.txt`

> Added without removing existing content.
> This addendum records a second pass over the runtime firmware/WebUI paths, plus validation results from `node --check data/app.js` and `pio run`.

## A1. Scope of Additional Analysis

Reviewed these runtime paths:

- `src/main.cpp`: setup order, Core-0 loop scheduling, service order.
- `src/state.h` / `src/state.cpp`: `RuntimeState`, `RuntimeStore`, scroll frame/source buffers, version publishing.
- `src/sync.cpp`: mutex creation and null-handle behavior.
- `src/led_renderer.cpp`: M370 codec, frame queue, render requests, NeoPixel output, lit-count helper.
- `src/scroll.cpp`: Core-1 scroll/render task, scroll frame advancement, render request consumption.
- `src/faces.cpp`: mode handling, saved-face apply, auto playback, scroll lifecycle, deferred face restore.
- `src/web_api.cpp`: status, power, frame, scroll upload, scroll meta, command, saved-face, static file routes.
- `src/storage.cpp`: settings and saved-face persistence.
- `src/buttons.cpp`: GPIO button dispatch and scroll interruption behavior.
- `src/button_animations.cpp`: overlay state and scroll system-pause coupling.
- `src/power_monitor.cpp`: ADC sampling, global power status, calibration persistence.
- `src/web_json.cpp`: partial raw JSON field extraction used by scroll uploads.
- `data/index.html`: DOM controls, especially debug `data-gpio` buttons and manual command input.
- `data/app.js`: global UI state, API transport, queues, firmware status merge, scroll upload/restore, debug controls.
- `data/styles.css`: UI state classes for progress, matrix, disabled controls, warnings, and loader.

Validation performed:

- `node --check data/app.js`: passed with bundled Node.
- `pio run`: passed with bundled PlatformIO. Reported RAM 17.3% and flash 42.2%.

## A2. Additional Current Behavior Notes

- Firmware startup allocates scroll buffers before mounting LittleFS, then starts the render task after an initial frame render.
- Core 0 owns HTTP, button, power, auto-playback, deferred-restore, and M370 queue service.
- Core 1 owns continuous scroll frame advancement and physical LED rendering.
- `/api/status?since=<version>` returns a short `unchanged:true` response when `stateVersion` matches, even during scroll.
- Core 1 scroll frame advancement updates `scrollFrameIndex` and `framesAccepted`, but does not update `stateVersion`.
- `/api/frame` validates the JSON body, then may stop scroll/change playback before validating the M370 payload.
- `/api/scroll` first-chunk uploads clear/stop existing scroll state before all incoming frames are parsed and validated.
- WebUI has three transport styles: direct aux command, queued button command, and queued frame command.
- WebUI scroll restore uses `/api/scroll/meta` and local regeneration, tracked by `pendingScrollMeta`, `lastFwScrollTimelineId`, `lastFwScrollHasSourceText`, and `lastFwScrollFrameCount`.
- Debug buttons with `data-gpio` exist in HTML, but no `app.js` handler binds them.
- The debug manual JSON input wraps user JSON inside an unsupported `manual_json` command instead of posting the raw command object.

## A3. Additional State Model Findings

- `RuntimeState::colorHex` duplicates `colorR/colorG/colorB`; these can diverge if code bypasses color helpers.
- Firmware `mode`, `playback`, `paused`, `restoreAutoAfterScroll`, and WebUI `state.mode`, `state.playback`, `state.textScrollActive`, `scroll.active`, `scroll.paused`, `scroll.firmwareBacked` represent overlapping playback truth.
- `RuntimeState::stateVersion` is a general publish cursor, but not all status-visible state changes touch it.
- `RuntimeState::scrollFrameIndex` is a live runtime cursor that should either have its own version or bypass the `since` short-circuit while active.
- `PowerStatus powerStatus` is globally read/written without a lock; Core 1 overlay rendering reads it while Core 0 updates it.
- WebUI `scroll` object mixes frame cache, firmware mirror, upload progress, command locks, restore metadata, dirty tracking, and UI flags.
- WebUI restore cursors should be grouped as a dedicated scroll-restore model rather than spread across globals.

## A4. Additional Bug List

### Addendum Bug A1: Active scroll polling can return unchanged while frame index changed

**Severity:** High  
**Type:** state / async / UI sync  
**Location:** `src/scroll.cpp` scroll frame advancement; `src/web_api.cpp` status `since` shortcut  
**Current behavior:** Core 1 advances `scrollFrameIndex` and `framesAccepted` without touching `stateVersion`; `/api/status?since=v` can return `unchanged:true`.  
**Expected behavior:** While firmware scroll is active, status summary polling should return updated scroll frame progress or explicitly exclude it by design.  
**Root cause:** `stateVersion` is not updated by Core-1 scroll ticks.  
**Reproduction path:** Start firmware scroll; repeatedly poll `/api/status?runtimeOnly=1&noFrame=1&since=<current version>`; observe unchanged responses while LEDs advance.  
**Risk if not fixed:** WebUI scroll preview/pause/step state can drift from firmware.  
**Fix strategy:** Low-risk option: bypass the `since == version` unchanged shortcut while `scrolling == true`. More explicit option: add a scroll status cursor updated on frame-index change and include it in the status freshness comparison.  
**Tests required:** API polling test during active scroll; manual WebUI scroll page open while firmware scroll runs.

### Addendum Bug A2: Power status data race between Core 0 and Core 1 overlay

**Severity:** High  
**Type:** race / firmware  
**Location:** `src/power_monitor.cpp`, `src/button_animations.cpp`  
**Current behavior:** `powerStatus` floats/booleans are written by Core 0 and read by Core 1 overlay rendering without a lock or coherent snapshot.  
**Expected behavior:** Overlay and API should read a coherent power snapshot.  
**Root cause:** No synchronization domain or snapshot helper for power state.  
**Reproduction path:** Hold B6 long overlay while forcing frequent power samples; inspect inconsistent battery/charge values or rare instability.  
**Risk if not fixed:** Torn float reads, inconsistent battery display, rare cross-core instability.  
**Fix strategy:** Add a small `PowerStatusSnapshot` helper guarded by a mutex/critical section. Writers update under the same guard or publish a copied snapshot; readers use copies only.  
**Tests required:** B6 overlay stress test while `servicePowerMonitor(true)` runs frequently.

### Addendum Bug A3: Invalid `/api/frame` can stop scroll before M370 validation

**Severity:** High  
**Type:** protocol / state  
**Location:** `src/web_api.cpp::handleApiFrame`  
**Current behavior:** Handler can stop firmware scroll and change playback before `applyM370()` validates the submitted frame.  
**Expected behavior:** Invalid frame requests should reject without changing active scroll/playback state.  
**Root cause:** Side effects occur before full payload validation.  
**Reproduction path:** Start scroll, POST `/api/frame` with invalid `m370` and non-scroll mode; response is 400 but scroll may already be stopped.  
**Risk if not fixed:** Malformed client packets can interrupt playback.  
**Fix strategy:** Normalize/decode M370 into a local packed buffer before stopping scroll or mutating playback. Commit state only after validation succeeds.  
**Tests required:** Invalid frame during active scroll leaves scroll active.

### Addendum Bug A4: Failed first scroll upload can destroy existing scroll cache

**Severity:** High  
**Type:** protocol / edge case  
**Location:** `src/web_api.cpp::handleApiScroll` first-chunk path  
**Current behavior:** `append:false` upload stops firmware scroll and clears metadata before all incoming frames are parsed and validated.  
**Expected behavior:** A bad replacement upload should not destroy a currently running/cached scroll sequence.  
**Root cause:** The handler commits destructive state changes before the incoming upload is proven valid.  
**Reproduction path:** Start scroll A, POST first chunk for scroll B with an invalid M370 frame; firmware stops A and invalidates cache, then returns 400.  
**Risk if not fixed:** One bad upload can wipe active scroll playback.  
**Fix strategy:** Use a two-phase upload path. Validate metadata and all frames in the chunk before clearing existing state. If memory does not allow full staging, at least validate every frame string before writing/committing shared cache metadata.  
**Tests required:** Invalid first chunk while existing scroll runs; existing scroll remains active.

### Addendum Bug A5: Partial JSON scanner accepts ambiguous or invalid JSON forms

**Severity:** Medium  
**Type:** protocol / edge case  
**Location:** `src/web_json.cpp`, `src/web_api.cpp::handleApiScroll`  
**Current behavior:** Scroll upload parsing scans raw fields manually, accepts unknown string escapes, does not fully validate trailing JSON, and integer parsing can overflow silently.  
**Expected behavior:** Malformed JSON should return 400 before state mutation.  
**Root cause:** Custom partial JSON extraction rather than strict token parsing.  
**Reproduction path:** POST scroll JSON with invalid escapes, trailing garbage, or huge numeric fields.  
**Risk if not fixed:** Protocol ambiguity and possible state corruption on edge-case inputs.  
**Fix strategy:** Keep memory-conscious parsing but reject unknown escapes, validate trailing content, add integer overflow checks, and limit accepted fields to intended top-level keys.  
**Tests required:** Protocol tests for invalid escapes, trailing garbage, huge numbers, and deceptive nested keys.

### Addendum Bug A6: Startup auto mode does not mark startup face as auto playback

**Severity:** Medium  
**Type:** state / persistence  
**Location:** `src/storage.cpp::loadSavedFaces`, `src/faces.cpp::setMode`  
**Current behavior:** If settings load `mode:auto`, startup face application still sets playback to idle before the first auto interval.  
**Expected behavior:** Persisted auto mode should boot with startup face shown as `auto_saved_face`.  
**Root cause:** `loadSavedFaces(true)` ignores current mode when choosing startup playback label.  
**Reproduction path:** Save auto mode, reboot, read `/api/status`; mode is auto but playback may be idle.  
**Risk if not fixed:** WebUI mode/playback mismatch after boot.  
**Fix strategy:** In startup apply path, set playback from `isAutoMode()` and initialize `lastAutoSwitchMs`.  
**Tests required:** Persistence boot test with auto mode and saved faces.

### Addendum Bug A7: B3 GPIO during active scroll is handled but does nothing

**Severity:** Medium  
**Type:** UI / firmware / state  
**Location:** `src/buttons.cpp::runButtonAction`  
**Current behavior:** B3 press during active unpaused firmware scroll returns handled immediately, without stopping scroll, toggling mode, or publishing a scroll-stop event.  
**Expected behavior:** Either B3 should be documented/represented as ignored during scroll, or it should interrupt scroll consistently with the WebUI stop-event logic.  
**Root cause:** Early return conflicts with later `isScrollInterruptButton()` handling.  
**Reproduction path:** Start scroll, press GPIO B3, observe scroll continues and no stop event is published.  
**Risk if not fixed:** User and WebUI expectations diverge.  
**Fix strategy:** Decide intended UX. If B3 should interrupt, call `stopFirmwareScroll(...)` and mark stop event. If ignored, remove B3 from interrupt assumptions in firmware/WebUI.  
**Tests required:** Manual B3 active-scroll test and status event sequence check.

### Addendum Bug A8: Status lit count reads current frame without frame lock

**Severity:** Medium  
**Type:** race / API  
**Location:** `src/led_renderer.cpp::countLitLeds`, `src/web_api.cpp::handleApiStatus`  
**Current behavior:** `countLitLeds()` reads `runtimeFrameBits()` without `frameMutex`.  
**Expected behavior:** API status should count a coherent frame snapshot.  
**Root cause:** Helper has no locking/snapshot contract.  
**Reproduction path:** Poll full status while Core 1 updates frame bits during scroll.  
**Risk if not fixed:** Incorrect lit counts or torn reads.  
**Fix strategy:** Add a locked/snapshot-based lit-count helper and keep expensive frame details skipped during active scroll as today.  
**Tests required:** Concurrent scroll/status stress test.

### Addendum Bug A9: Mutex creation failure leaves firmware running without full locking

**Severity:** Medium  
**Type:** firmware / race / error handling  
**Location:** `src/main.cpp::setup`, `src/sync.cpp::initSyncPrimitives`  
**Current behavior:** Setup logs mutex creation failure but continues; null mutex handles make lock calls no-ops for that domain.  
**Expected behavior:** Firmware should fail safe or disable dependent services if synchronization primitives are unavailable.  
**Root cause:** `initSyncPrimitives()` result is not enforced.  
**Reproduction path:** Fault-injection build where `xSemaphoreCreateMutex()` fails.  
**Risk if not fixed:** Rare boot heap failure creates unsynchronized runtime.  
**Fix strategy:** Render fatal pattern and avoid starting WebServer/scroll task, or reboot after a delay, when required mutexes fail.  
**Tests required:** Fault-injection build/test.

### Addendum Bug A10: Debug GPIO buttons have no WebUI handler

**Severity:** Low  
**Type:** UI  
**Location:** `data/index.html` debug `data-gpio` buttons, `data/app.js` debug initialization  
**Current behavior:** Debug GPIO buttons exist in HTML but are never bound in JS.  
**Expected behavior:** Supported debug GPIO buttons should send button commands or be disabled/removed if unsupported.  
**Root cause:** Missing event binding.  
**Reproduction path:** Open debug page and click B1/B2/B3/B4/B5; no command is sent.  
**Risk if not fixed:** Debug tools are misleading.  
**Fix strategy:** Add a debug binding map. B1/B2/B3/B4/B5/B3B1/B3B2 should call `sendButtonCommand`; unsupported B6 variants should be implemented or disabled with clear UI behavior.  
**Tests required:** Browser click test verifies command queue/API call.

### Addendum Bug A11: Manual JSON debug input sends unsupported `manual_json`

**Severity:** Low  
**Type:** UI / protocol  
**Location:** `data/app.js` debug `serial-send` handler  
**Current behavior:** Placeholder suggests entering `{"cmd":"pause"}`, but handler sends `cmd:"manual_json"` with parsed JSON as payload. Firmware does not support `manual_json`.  
**Expected behavior:** Raw debug JSON should be posted directly to `/api/command`, or the UI should expose structured command fields.  
**Root cause:** Debug helper wraps user input incorrectly.  
**Reproduction path:** Enter `{"cmd":"pause_scroll"}` and send; firmware returns unknown command.  
**Risk if not fixed:** Debug command path is broken.  
**Fix strategy:** Parse raw JSON and POST it directly if it has a `cmd`; otherwise show validation error.  
**Tests required:** Debug command sends `pause_scroll` successfully.

### Addendum Bug A12: Counter-only changes may not publish status changes

**Severity:** Low  
**Type:** state / API  
**Location:** frame/command rejection and queue counters  
**Current behavior:** Some counter-only changes do not call `touchRuntimeState()`.  
**Expected behavior:** Status consumers using `since` should eventually observe changed stats, or counters should be documented as excluded from versioning.  
**Root cause:** Diagnostic counters are inconsistently included in status versioning.  
**Reproduction path:** Poll status with `since`, send invalid command/frame, poll again.  
**Risk if not fixed:** Debug stats can appear stale.  
**Fix strategy:** Either call `touchRuntimeStateSlow()` for counter-only changes or explicitly exclude counters from `since` freshness semantics.  
**Tests required:** API stats visibility test.

## A5. Additional Refactor Opportunities

- Split `web_api.cpp` by route domain into status, frame, scroll, command, static, and saved-face handlers while preserving routes and JSON fields.
- Create a firmware scroll controller module to own start/stop/pause/resume/step, metadata invalidation, first-frame apply, and restore policy.
- Define typed playback/mode constants in firmware and WebUI while preserving serialized string values.
- Add status snapshot helpers for renderer, scroll, power, and storage before serialization.
- Separate the M370 codec from LED rendering into a pure module.
- Split WebUI `app.js` conceptually into API, state, matrix, faces, scroll, power, debug, and boot units, with bundled output preserved if needed for LittleFS.
- Separate WebUI scroll generation, upload, restore, and control rendering.
- Centralize WebUI transport queues so frames, buttons, and aux commands share consistent rate-limit/error semantics.

## A6. Additional Implementation Order

1. Add baseline tests/protocol notes.
2. Fix active-scroll status freshness.
3. Add coherent power snapshots.
4. Reorder validation before side effects in `/api/frame`.
5. Protect existing scroll cache from failed replacement uploads.
6. Repair debug UI controls.
7. Extract M370/status helpers.
8. Centralize firmware scroll lifecycle.
9. Split WebUI scroll logic only after the scroll regression suite exists.

## A7. Additional Preservation Checklist

- Preserve all public routes and JSON field names.
- Preserve M370 format, bit order, and normalization behavior.
- Preserve scroll upload RAM-only behavior and timeline validation rules.
- Preserve LED timing constants and render task core.
- Preserve GPIO/ADC pins and AP credentials.
- Preserve LittleFS paths and saved-face schema.
- Preserve DOM IDs/classes and existing page structure.
- Preserve default color, brightness, mode, auto interval, and scroll FPS defaults.
- Preserve button repeat/debounce timing.
- Preserve stop-clear/deferred-restore timing.
- Preserve user-visible text unless doing a dedicated copy/encoding cleanup pass.

## A8. Additional Validation Checklist

- Active-scroll `since` polling returns updated scroll status.
- Invalid `/api/frame` during scroll returns 400 and leaves scroll active.
- Invalid replacement `/api/scroll` first chunk leaves existing scroll active.
- B6 overlay remains stable under forced power sampling.
- Full status `lit` count is coherent during frame updates.
- Persisted auto mode boots with `auto_saved_face`.
- B3 active-scroll behavior matches documented expected behavior.
- Debug `data-gpio` buttons send commands.
- Manual JSON debug input sends raw `cmd` payload successfully.
- PlatformIO build and `node --check` pass after each phase.

## A9. Concrete Implementation Snippets

> These are proposed code-change snippets for a later implementation pass.
> They are intentionally included in the plan only; no firmware/WebUI source files are changed by this document update.

### Snippet A1: Bypass `since` short response while firmware scroll is active

Target: `src/web_api.cpp`, inside `handleApiStatus()`.

Current risk: `/api/status?since=<version>` can return `unchanged:true` while `scrollFrameIndex` advances on Core 1.

Planned change:

```cpp
if (hasSince) {
    const uint32_t since = static_cast<uint32_t>(strtoul(server.arg("since").c_str(), nullptr, 10));
    const bool allowUnchangedShortcut = !scrolling;
    if (allowUnchangedShortcut && since == version) {
        DynamicJsonDocument unchanged(192);
        unchanged["ok"]           = true;
        unchanged["v"]            = version;
        unchanged["version"]      = version;
        unchanged["unchanged"]    = true;
        unchanged["next_poll_ms"] = statusNextPollMs(scrolling, summaryOnly);
        sendJsonDocument(200, unchanged);
        return;
    }
}
```

Validation:

- Start firmware scroll.
- Poll `/api/status?runtimeOnly=1&noFrame=1&since=<last version>`.
- Confirm response includes updated `renderer.scrollFrameIndex` instead of `unchanged:true`.

### Snippet A2: Validate `/api/frame` M370 before stopping scroll

Target: `src/web_api.cpp`, inside `handleApiFrame()`.

Current risk: invalid frame requests can stop scroll before M370 validation.

Planned change:

```cpp
String normalized;
uint8_t packed[FRAME_BYTES];
if (!normalizeM370(m370, normalized, error)) {
    ++runtimeState().framesRejected;
    sendError(400, error);
    return;
}
if (!m370ToPackedBits(normalized, packed, error)) {
    ++runtimeState().framesRejected;
    sendError(400, error);
    return;
}

if (!isScrollPlayback(String(mode))) {
    stopFirmwareScroll(false);
}
if (reason.startsWith("custom_") || reason.startsWith("parts_")) {
    setMode("manual", false);
}
runtimeState().playback = mode;

applyPackedFrame(packed, reason);
```

Implementation note:

- If exact `lastM370` preservation is required, add an `applyPackedM370Frame()` helper that accepts both packed bits and normalized M370 text, rather than dropping normalized `lastM370`.

Validation:

- Start scroll.
- POST invalid M370 to `/api/frame`.
- Confirm HTTP 400 and scroll remains active.
- POST valid M370 and confirm previous behavior is preserved.

### Snippet A3: Add locked power snapshot helper

Target: `src/power_monitor.h` / `src/power_monitor.cpp`.

Current risk: Core 1 overlay reads `powerStatus` while Core 0 updates it.

Planned API:

```cpp
struct PowerStatusSnapshot {
    float    vbat;
    float    vcharge;
    uint8_t  batteryPercent;
    bool     charging;
    bool     batteryValid;
    bool     chargeValid;
    bool     batteryDisconnected;
    bool     batteryLowVoltageUnpowered;
};

PowerStatusSnapshot powerStatusSnapshot();
```

Planned implementation shape:

```cpp
static portMUX_TYPE sPowerStatusMux = portMUX_INITIALIZER_UNLOCKED;

PowerStatusSnapshot powerStatusSnapshot() {
    PowerStatusSnapshot snapshot;
    portENTER_CRITICAL(&sPowerStatusMux);
    snapshot.vbat                         = powerStatus.vbat;
    snapshot.vcharge                      = powerStatus.vcharge;
    snapshot.batteryPercent               = powerStatus.batteryPercent;
    snapshot.charging                     = powerStatus.charging;
    snapshot.batteryValid                 = powerStatus.batteryValid;
    snapshot.chargeValid                  = powerStatus.chargeValid;
    snapshot.batteryDisconnected          = powerStatus.batteryDisconnected;
    snapshot.batteryLowVoltageUnpowered   = powerStatus.batteryLowVoltageUnpowered;
    portEXIT_CRITICAL(&sPowerStatusMux);
    return snapshot;
}
```

Writer-side planned pattern:

```cpp
portENTER_CRITICAL(&sPowerStatusMux);
powerStatus.vbat = nextVbat;
powerStatus.batteryPercent = nextPercent;
powerStatus.batteryValid = true;
powerStatus.lastBatteryMs = now;
portEXIT_CRITICAL(&sPowerStatusMux);
```

Validation:

- Render B6 battery overlay while forcing frequent power sampling.
- Confirm no inconsistent charge/battery combination appears.

### Snippet A4: Use power snapshot in button overlay rendering

Target: `src/button_animations.cpp`, inside battery overlay drawing.

Current risk: overlay reads global `powerStatus` directly.

Planned change:

```cpp
void drawBatteryPage(uint8_t* out, const AnimationState& state, uint32_t now) {
    clearOverlay(out);

    const PowerStatusSnapshot power = powerStatusSnapshot();
    const bool batteryValid = power.batteryValid;
    const bool chargeValid = power.chargeValid;
    const uint8_t pct = batteryValid ? power.batteryPercent : 0;
    const bool charging = chargeValid && power.charging;
    const Rgb iconColor = batteryValid ? batteryColor(pct) : RED_COLOR;
    const bool animate = !state.batterySingleShot && charging;
    const uint32_t phaseMs = now - state.batteryDisplayStartedMs;

    drawBatteryIcon(out, iconColor, pct, animate, phaseMs);
    // Existing text formatting logic continues using `power.vbat` and `power.vcharge`.
}
```

Validation:

- B6 short press shows battery percent.
- B6 long press cycles percent/battery voltage/charge voltage without scroll desync.

### Snippet A5: Locked lit-count helper

Target: `src/led_renderer.cpp` / `src/led_renderer.h`.

Current risk: `countLitLeds()` reads `runtimeFrameBits()` without `frameMutex`.

Planned helper:

```cpp
uint16_t countLitLedsLocked() {
    uint8_t snapshot[FRAME_BYTES];
    withFrameLock([&]() {
        memcpy(snapshot, runtimeFrameBits(), FRAME_BYTES);
    });

    uint16_t lit = 0;
    for (uint16_t byteIndex = 0; byteIndex < FRAME_BYTES; ++byteIndex) {
        uint8_t value = snapshot[byteIndex];
        const uint16_t firstBit = static_cast<uint16_t>(byteIndex) << 3;
        if (firstBit + 8U > LED_COUNT) {
            const uint8_t validBits = static_cast<uint8_t>(LED_COUNT - firstBit);
            value &= static_cast<uint8_t>((1U << validBits) - 1U);
        }
        lit += static_cast<uint16_t>(__builtin_popcount(value));
    }
    return lit;
}
```

Planned status use:

```cpp
if (!scrolling && !summaryOnly) {
    renderer["lastM370"] = runtimeState().lastM370;
    renderer["lit"]      = countLitLedsLocked();
}
```

Validation:

- Poll full status during frame updates.
- Confirm `lit` remains plausible and no race-sensitive behavior appears.

### Snippet A6: Make mutex init failure fail safe

Target: `src/main.cpp`, immediately after `initSyncPrimitives()`.

Current risk: firmware can continue with missing locks.

Planned change:

```cpp
if (!initSyncPrimitives()) {
    Serial.println("Fatal: failed to create one or more FreeRTOS mutexes");
    pinMode(LED_PIN, OUTPUT);
    for (;;) {
        digitalWrite(LED_PIN, LOW);
        delay(250);
        digitalWrite(LED_PIN, HIGH);
        delay(250);
    }
}
```

Implementation note:

- A nicer later version can render a specific NeoPixel fatal pattern if the hardware bus mutex exists. The initial fail-safe should avoid depending on locks that may not exist.

Validation:

- Fault-injection build forces `initSyncPrimitives()` false.
- Firmware does not start WebServer or render task.

### Snippet A7: Bind debug `data-gpio` buttons in WebUI

Target: `data/app.js`, inside `initializeDebugControls()`.

Current risk: debug GPIO buttons exist but do nothing.

Planned change:

```js
document.querySelectorAll("[data-gpio]").forEach((button) => {
  button.addEventListener("click", () => {
    const code = String(button.dataset.gpio || "").toUpperCase();
    if (["B1", "B2", "B3", "B4", "B5", "B3B1", "B3B2"].includes(code)) {
      sendButtonCommand(code, `debug_gpio_${code}`);
      return;
    }
    log(`Unsupported debug GPIO simulation: ${code}`);
  });
});
```

Validation:

- Click B1/B2/B3/B4/B5/B3B1/B3B2 on debug page.
- Confirm `/api/command` receives `cmd:"button"` with the expected payload.

### Snippet A8: Send raw manual debug JSON directly

Target: `data/app.js`, `serial-send` debug handler.

Current risk: handler wraps user JSON inside unsupported `manual_json`.

Planned change:

```js
[
  "serial-send",
  () => {
    const raw = $("serial-input")?.value || "{}";
    try {
      const packet = JSON.parse(raw);
      if (!packet || typeof packet !== "object" || typeof packet.cmd !== "string") {
        throw new Error("Command JSON must be an object with a string cmd field");
      }
      apiPost(API_ENDPOINTS.command, packet)
        .then((data) => applyFirmwareRuntimeState(data, "debug_manual_json"))
        .catch((err) => {
          setFirmwareStatus({
            lastStatus: "manual command failed",
            lastError: err.message,
          });
          log(`manual command failed: ${err.message}`);
        });
    } catch (err) {
      alert(`JSON format error: ${err.message}`);
    }
  },
]
```

Validation:

- Enter `{"cmd":"pause_scroll"}`.
- Confirm firmware command is accepted or returns a meaningful command-specific error.

### Snippet A9: Preserve existing scroll until replacement upload validates

Target: `src/web_api.cpp`, `handleApiScroll()`.

Current risk: first replacement chunk clears active scroll before validation finishes.

Planned shape:

```cpp
struct ParsedScrollFrame {
    uint16_t index;
    uint8_t bits[FRAME_BYTES];
};

ParsedScrollFrame parsedFrames[MAX_SAFE_CHUNK_FRAMES];
uint16_t parsedCount = 0;

// Parse and validate all incoming frames into parsedFrames first.
// Do not call stopFirmwareScroll(false) or clearScrollTimelineMetaLocked() yet.
while (pos < body.length()) {
    // Existing frame-string extraction stays here.
    if (!m370ToPackedBits(m370, parsedFrames[parsedCount].bits, error)) {
        sendError(400, String("invalid scroll frame ") + targetIndex + ": " + error);
        return;
    }
    parsedFrames[parsedCount].index = static_cast<uint16_t>(targetIndex);
    ++parsedCount;
}

// Only after validation succeeds, commit destructive state changes.
if (!appendFrames) {
    stopFirmwareScroll(false);
    withScrollLock([&]() {
        runtimeState().scrollFrameCount = 0;
        runtimeState().scrollFrameIndex = 0;
        clearScrollTimelineMetaLocked();
        // Reapply validated metadata here.
    });
}

withScrollLock([&]() {
    for (uint16_t i = 0; i < parsedCount; ++i) {
        memcpy(runtimeScrollFrameBits(parsedFrames[i].index), parsedFrames[i].bits, FRAME_BYTES);
    }
    runtimeState().scrollFrameCount = baseIndex + parsedCount;
});
```

Implementation note:

- If stack size is a concern, allocate the staging array from PSRAM/internal heap and cap it by chunk size. The key requirement is validation before destructive commit.

Validation:

- Start scroll A.
- Send invalid first chunk for scroll B.
- Confirm scroll A remains active and cached.

### Snippet A10: Startup face playback should respect persisted auto mode

Target: `src/storage.cpp`, startup face apply block in `loadSavedFaces(true)`.

Current risk: persisted auto mode boots with `playback` set to idle.

Planned change:

```cpp
if (applyStartupFace) {
    String error;
    const bool autoMode = isAutoMode();
    runtimeState().brightness = DEFAULT_BRIGHTNESS;
    runtimeState().playback   = autoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    runtimeState().paused     = false;
    if (autoMode) runtimeState().lastAutoSwitchMs = millis();

    if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, STARTUP_FACE_REASON, error)) {
        Serial.printf("startup M370 failed: %s\n", error.c_str());
        return false;
    }
}
```

Validation:

- Persist `mode:auto`.
- Reboot.
- Confirm `/api/status` reports `mode:auto` and `playback:auto_saved_face`.

### Snippet A11: Strict unknown escape rejection in JSON string extraction

Target: `src/web_json.cpp::extractJsonStringAt`.

Current risk: unknown JSON escapes are accepted as literal characters.

Planned change:

```cpp
switch (c) {
    case '"': value += '"'; break;
    case '\\': value += '\\'; break;
    case '/': value += '/'; break;
    case 'b': value += '\b'; break;
    case 'f': value += '\f'; break;
    case 'n': value += '\n'; break;
    case 'r': value += '\r'; break;
    case 't': value += '\t'; break;
    case 'u':
        // Existing unicode handling remains here.
        break;
    default:
        return false;
}
```

Validation:

- POST scroll JSON containing `"sourceText":"bad\\xescape"`.
- Confirm 400 response and no scroll state mutation.

## A10. Consolidated Workstreams

> This section organizes related findings, snippets, validation steps, and refactor targets together.
> It does not replace the detailed bug/refactor/phase sections above; it is an implementation-oriented map for a later coding pass.

### Workstream 1: Firmware status freshness and state publishing

Related findings:

- Addendum Bug A1: active scroll polling can return `unchanged:true` while `scrollFrameIndex` changed.
- Addendum Bug A12: counter-only changes may not publish status changes.
- Existing plan items that discuss `stateVersion`, `since`, status snapshots, slow UI publishing, and status response cadence.

Relevant files:

- `src/state.h`
- `src/state.cpp`
- `src/scroll.cpp`
- `src/web_api.cpp`
- `data/app.js`

Concrete snippets:

- Snippet A1: bypass `since` short response while firmware scroll is active.

Implementation order:

1. Add a status polling regression test for active scroll.
2. Apply Snippet A1 or introduce a dedicated scroll-status cursor.
3. Decide whether diagnostic counters are included in `stateVersion` or documented as best-effort.
4. Add snapshot helpers before broader status refactoring.

Validation:

- Start firmware scroll and poll `/api/status?runtimeOnly=1&noFrame=1&since=<last version>`.
- Confirm `renderer.scrollFrameIndex` updates.
- Send invalid frame/command and confirm stats are visible according to the chosen counter policy.

Preserve:

- Existing JSON field names.
- `unchanged:true` response shape when no scroll/progress-sensitive state changed.
- `next_poll_ms` behavior.

### Workstream 2: Cross-core safety for frame and power reads

Related findings:

- Addendum Bug A2: power status data race between Core 0 and Core 1 overlay.
- Addendum Bug A8: status lit count reads current frame without frame lock.
- Existing bug/refactor items around overlay power reads, status snapshots, and lock fail-safe behavior.

Relevant files:

- `src/power_monitor.h`
- `src/power_monitor.cpp`
- `src/button_animations.cpp`
- `src/led_renderer.h`
- `src/led_renderer.cpp`
- `src/web_api.cpp`
- `src/sync.cpp`

Concrete snippets:

- Snippet A3: add locked power snapshot helper.
- Snippet A4: use power snapshot in button overlay rendering.
- Snippet A5: locked lit-count helper.
- Snippet A6: make mutex init failure fail safe.

Implementation order:

1. Add `PowerStatusSnapshot` and snapshot reader.
2. Replace overlay direct `powerStatus` reads with the snapshot.
3. Replace API direct lit-count path with a locked/snapshot helper.
4. Harden mutex creation failure after the above behavior is tested.

Validation:

- Hold B6 battery overlay while power sampling runs.
- Poll full status while frames update.
- Fault-injection build for `initSyncPrimitives()` failure.

Preserve:

- ADC thresholds and calibration math.
- LED timing and render task cadence.
- Existing power JSON field names.

### Workstream 3: Scroll upload, metadata, and cache commit safety

Related findings:

- Addendum Bug A4: failed first scroll upload can destroy existing scroll cache.
- Addendum Bug A5: partial JSON scanner accepts ambiguous or invalid JSON forms.
- Existing scroll upload invariants EH-A/EH-B/EH-C and D/E/H notes.
- Refactor opportunity: centralize firmware scroll controller.

Relevant files:

- `src/web_api.cpp`
- `src/web_json.cpp`
- `src/state.cpp`
- `src/state.h`
- `src/faces.cpp`
- `src/scroll.cpp`
- `data/app.js`

Concrete snippets:

- Snippet A9: preserve existing scroll until replacement upload validates.
- Snippet A11: strict unknown escape rejection in JSON string extraction.

Implementation order:

1. Add protocol tests for invalid frame strings, invalid escapes, huge numbers, out-of-order chunks, and trailing garbage.
2. Make JSON string extraction reject unknown escapes.
3. Reorder `/api/scroll` first-chunk handling into validate-then-commit.
4. Only after behavior is protected, move lifecycle logic into a scroll controller module.

Validation:

- Start scroll A, send invalid first chunk for scroll B, confirm scroll A remains active.
- Send valid chunked upload and confirm timeline metadata, frame count, and start behavior remain unchanged.
- Confirm `/api/scroll/meta` still returns source text and frame metadata after valid upload.

Preserve:

- RAM-only scroll behavior.
- Timeline ID format and validation.
- `sourceText` all-or-nothing metadata requirements.
- Existing start-scroll 409 behavior.

### Workstream 4: Frame command validation and M370 codec boundaries

Related findings:

- Addendum Bug A3: invalid `/api/frame` can stop scroll before M370 validation.
- Existing refactor opportunity to separate M370 codec from LED renderer.
- Existing behavior preservation requirement for M370 format and bit order.

Relevant files:

- `src/led_renderer.h`
- `src/led_renderer.cpp`
- `src/web_api.cpp`
- future `src/m370_codec.h`
- future `src/m370_codec.cpp`

Concrete snippets:

- Snippet A2: validate `/api/frame` M370 before stopping scroll.

Implementation order:

1. Add M370 unit tests for valid, invalid, lowercase, whitespace, and prefix/no-prefix forms.
2. Extract pure M370 codec helpers.
3. Reorder `/api/frame` to validate before side effects.
4. Add a helper that can apply packed bits while preserving normalized `lastM370`.

Validation:

- Invalid `/api/frame` during scroll leaves scroll active.
- Valid `/api/frame` still updates LEDs, `lastM370`, `lastReason`, counters, and status.
- Known M370 patterns roundtrip unchanged.

Preserve:

- `M370:` + 93 hex normalized format.
- Logical row-major bit order.
- Existing error messages unless tests are updated explicitly.

### Workstream 5: Startup mode, saved faces, and persistence consistency

Related findings:

- Addendum Bug A6: startup auto mode does not mark startup face as auto playback.
- Existing saved-face validation, settings repair, default brightness/default face startup findings.
- Persistence behavior around `runtime_settings.json`, `saved_faces.json`, and battery calibration.

Relevant files:

- `src/storage.cpp`
- `src/faces.cpp`
- `src/state.h`
- `data/app.js`
- `data/resources/saved_faces.json`
- `data/resources/runtime_settings.json`

Concrete snippets:

- Snippet A10: startup face playback should respect persisted auto mode.

Implementation order:

1. Add boot/persistence test notes for manual mode and auto mode.
2. Apply startup playback fix.
3. Confirm `lastAutoSwitchMs` is initialized when booting into auto mode.
4. Keep saved-face sort/default selection behavior unchanged.

Validation:

- Persist `mode:auto`, reboot, confirm status reports `mode:auto` and `playback:auto_saved_face`.
- Persist `mode:manual`, reboot, confirm existing manual startup behavior.
- Reload saved faces and confirm selected/default face remains stable.

Preserve:

- Saved-face schema.
- Startup default selection priority.
- Atomic settings/saved-face writes.

### Workstream 6: GPIO, debug controls, and manual command tooling

Related findings:

- Addendum Bug A7: B3 GPIO during active scroll is handled but does nothing.
- Addendum Bug A10: debug GPIO buttons have no WebUI handler.
- Addendum Bug A11: manual JSON debug input sends unsupported `manual_json`.
- Existing button behavior preservation requirements.

Relevant files:

- `src/buttons.cpp`
- `src/faces.cpp`
- `data/index.html`
- `data/app.js`

Concrete snippets:

- Snippet A7: bind debug `data-gpio` buttons in WebUI.
- Snippet A8: send raw manual debug JSON directly.

Implementation order:

1. Decide intended B3 behavior during active scroll.
2. Update firmware/WebUI assumptions consistently for B3.
3. Bind supported debug GPIO buttons.
4. Replace `manual_json` wrapping with direct raw command POST.
5. Disable or implement unsupported B6 debug variants.

Validation:

- Press real GPIO B1/B2/B3 during scroll and confirm documented behavior.
- Click debug B1/B2/B3/B4/B5/B3B1/B3B2 and confirm command payloads.
- Enter `{"cmd":"pause_scroll"}` in debug input and confirm firmware receives that command directly.

Preserve:

- GPIO debounce/repeat timings.
- Existing B1/B2/B3/B4/B5 production behavior unless explicitly fixing B3 active-scroll semantics.
- DOM `data-gpio` values.

### Workstream 7: WebUI transport and scroll-state structure

Related findings:

- WebUI has direct aux commands, queued button commands, and queued frame commands with different behavior.
- WebUI `scroll` state mixes model, firmware mirror, cache, progress, locks, and restore metadata.
- Addendum refactor opportunities A6 and A7.

Relevant files:

- `data/app.js`
- `data/index.html`
- `scripts/gzip_webui_assets.py`

Concrete snippets:

- Snippet A7 and A8 apply to debug transport.
- Scroll upload snippets A9/A11 inform frontend protocol tests but are firmware-side changes.

Implementation order:

1. Add browser smoke tests for transport and scroll controls.
2. Extract an API client/transport queue helper.
3. Split scroll logic into generator, uploader, restorer, and view/controller sections.
4. Preserve generated/bundled output behavior for LittleFS.

Validation:

- Node syntax check.
- Browser smoke test.
- Frame queue saturation test.
- Button command queue saturation test.
- Scroll upload/restore test.

Preserve:

- Endpoint paths.
- DOM IDs/classes.
- Upload chunk sizing and progress semantics unless separately changed.

### Workstream 8: Module extraction and long-term architecture

Related findings:

- `web_api.cpp` is too broad.
- `led_renderer.cpp` mixes codec, queueing, state mutation, and physical output.
- `faces.cpp` owns both face playback and scroll lifecycle.
- `app.js` is a monolithic frontend runtime.

Relevant files:

- `src/web_api.cpp`
- `src/led_renderer.cpp`
- `src/faces.cpp`
- `src/scroll.cpp`
- `data/app.js`

Concrete snippets:

- Snippets A1-A11 show target behavior for the most important seams before extraction.

Implementation order:

1. Extract pure M370 codec.
2. Extract status snapshots.
3. Split Web API route domains.
4. Create firmware scroll controller.
5. Split WebUI scroll modules.
6. Clean comments/encoding after behavior tests are stable.

Validation:

- `pio run`.
- `node --check data/app.js`.
- API contract tests.
- Manual hardware smoke test.

Preserve:

- Public APIs and protocol formats.
- Hardware timing.
- User-visible behavior unless a bug fix explicitly changes it.

---

## 14. Final recommendation

**Already shipped:** Bug 15 (6.4 scroll-button flash) is applied — `updateScrollUi` no longer folds transient command-busy flags into the button `disabled` state, so normal clicks no longer flash the row. All other items remain ⬜ (proposed).

**Is the refactor safe?** Yes, in the proposed order. The codebase is already well-modularized with explicit lock and protocol contracts; the work is mostly extraction, snapshotting, and a small set of focused fixes — not a rewrite. The two genuinely risky items (Bug 3 timing reassignment, Refactor 2 scroll-handler split) are isolated and gated behind a behavior baseline and dedicated tests.

**Bugs to fix first (highest value / lowest risk):**
1. **Bug 5** (color picker reset + per-second re-render) — clear user impact, trivial fix.
2. **Bug 2** (scroll frame skip) — visible, isolated to one branch.
3. **Bug 6** (settings repair) and **Bug 4** (brightness default) — small, contained.
4. **Bug 1 + Refactor 1** (status snapshot) — closes the most real concurrency gap; depends on the snapshot seam.

**Bugs to do carefully / later:**
- **Bug 3** (file I/O vs LED lock) — defer to Phase 8; requires hardware confirmation; highest timing risk.
- **Bug 7/8** (lock fail-safe, overlay power) — Phase 7; low probability but correct to harden.
- **Bug 9** — latent; primarily a contract test + guard.

**Refactors first:** comment cleanup (R11, Phase 2), then the three extractions (R2/R3/R5/R10, Phase 3), then snapshot/lock seams (R1/R4/R6/R7/R8, Phase 4). These create the seams every later fix lands in.

**Changes to delay:** WebUI scroll-boolean reduction (R9, Phase 9) and the timing-sensitive Bug 3 (Phase 8) — both after correctness is locked and tested.

**Safest implementation order:** Phase 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10, one logical change per commit, each followed by the relevant regression subset, with the Phase-1 baseline as the gate. This keeps every low-risk pure refactor ahead of behavior-affecting fixes, and isolates the only two intentional behavior changes (Bug 3 timing, Bug 5 render cadence) behind explicit tests.
