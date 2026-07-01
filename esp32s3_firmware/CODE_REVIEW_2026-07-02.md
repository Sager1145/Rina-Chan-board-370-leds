# Firmware Code Review — Optimization & Function-Path Audit

Date: 2026-07-02 · Scope: all C++ in `src/` (~6,200 lines, 35 files). Web UI (`data/app.js`, 14k lines) not covered in this pass.

## Verdict

The firmware is **well optimized overall**. The hot paths (LED render, scroll tick, frame queue) are clean: precomputed logical→physical index map, single-memcpy chunk writes for scroll uploads, snapshot-under-lock pattern everywhere, IRAM RMT encoder, PSRAM-first allocation, rate-limited logging. No deadlocks found (lock order Scroll→Frame→Storage→HardwareBus is respected; locks are never nested across domains in the render/scroll paths).

The issues found are concentrated in the **HTTP handlers** (JSON document sizing, redundant work, stack pressure) and a few **cross-core consistency gaps**. Nothing on the per-frame render path needs changing.

---

## Bugs (functional, not just perf)

### B1. `/api/scroll/meta` silently drops `sourceText` (web_api.cpp:483–491)
`DynamicJsonDocument d(1024)` but `d["sourceText"] = text` copies up to 4,096 bytes into the doc's pool. Anything beyond ~800 bytes of text fails allocation silently → response has `"sourceText": null` while `hasSourceText: true`. The WebUI restore-from-text path breaks for longer texts.
**Fix:** size the doc `MAX_SCROLL_TEXT_BYTES + 1024` (or use `PsramJsonDocument`).

### B2. `/api/scroll/meta` puts 4 KB on the handler stack (web_api.cpp:485)
`char text[MAX_SCROLL_TEXT_BYTES + 1]` = 4,097 bytes on the loopTask stack (default 8 KB), on top of WebServer machinery. It works today but leaves very little headroom.
**Fix:** heap/PSRAM buffer, or copy straight into the JSON doc under the scroll lock.

### B3. `/api/saved_faces` POST capacity caps face count far below firmware max (web_api.cpp:744)
`DynamicJsonDocument d(16384)` can hold roughly 15–20 faces (each face ≈ 47-element `frameBytes` array ≈ 900 B of ArduinoJson pool), but `MAX_AUTO_FACES` is 128 and the load path (`loadSavedFaces`) correctly uses `PsramJsonDocument(jsonCapacityFor(size))`. Larger uploads get a misleading `400 invalid JSON` (NoMemory).
**Fix:** use `PsramJsonDocument(jsonCapacityFor(b.length()))` like the load path.

### B4. `rinaLogInit()` is never called (serial_log.cpp:34, declared serial_log.h:47)
Harmless today (UART0 mirror is off by default, history starts zeroed), but the init contract is dead code. Either call it from `setup()`/`initSerialConsole()` or delete it.

---

## Cross-core consistency gaps

### C1. `sampleBattery` writes consumer-visible fields outside the spinlock (power_monitor.cpp:339–361)
`batteryDisconnected = false` and `vbat = NAN` are written outside `sPowerStatusMux`, then final values committed under it. A Core 1 reader (`readPowerStatusSnapshot` from the battery overlay) can snapshot `vbat = NAN` with `batteryValid = true` mid-update → overlay briefly renders 0.0 V. Low impact, easy fix: move those transitional writes inside the same critical section as the commit, or write to locals and commit once.

### C2. File streaming bypasses the Storage/HardwareBus lock (web_api.cpp:163, 734)
`sync.h` documents that Storage owns HardwareBus *because LittleFS flash I/O must never overlap the WS2812 transmit*. But `serveFile()` and the saved-faces GET only hold the lock during `open()`/`close()` — `server.streamFile()` does all its flash reads unlocked. Either:
- the invariant matters → wrap the stream in a lock (bad: blocks LED render for the whole 414 KB asset transfer), or chunk it with lock per chunk; or
- the invariant doesn't matter in practice (RMT-DMA + IRAM encoder already immunize timing, per your LED_WIFI_TIMING_RESEARCH notes) → simplify `lockStorage()` to not take the bus lock, which also shortens every settings/calibration write.

Right now the code pays the cost of the coupled lock on writes while not getting the protection on the biggest flash-read path. Pick one model.

### C3. `renderCurrentFrameToLedStrip` is non-reentrant by design but unguarded (led_renderer.cpp:258–307)
`static uint8_t overlayRgb[1110]` and `static lastAppliedBrightness` are safe only because callers are mutually exclusive (Core 1 task when `g_syncReady`, else Core 0 loop; setup runs before the task starts). That invariant is real but implicit — worth a comment/assert so a future call site doesn't break it.

---

## Optimization opportunities (ordered by payoff)

### O1. Blocking ADC sampling stalls the control loop ~8 ms every second (power_monitor.cpp:25–40)
`readTrimmedAdcMilliVolts` = 16 × (`analogReadMilliVolts` + `delayMicroseconds(250)`) ≈ 4 ms, run for two pins. During that window `webServerTick`, buttons, and the frame queue all stall. Options: drop the 250 µs pauses (S3 ADC is stable back-to-back), reduce to 8 samples/trim 2, or spread samples across loop iterations (one sample per tick, finalize every 16).

### O2. Remove `servicePowerMonitor()` from HTTP handlers (web_api.cpp:235, 307)
The main loop already calls it every ~1 ms; the handler calls add up to 8 ms latency to `/api/status` and `/api/power` whenever the 1 s sample window happens to be due, and buy at most 1 ms of freshness.

### O3. Avoid copying the POST body (web_api.cpp:54)
`body()` returns `server.arg("plain")` by value → a full copy of the body String. For scroll uploads this duplicates the largest allocation in the system (a full 3,072-frame timeline is ~189 KB base64; even chunked uploads double their chunk). Peak RAM during `/api/scroll` is currently ≈ body + copy + decoded vector ≈ 2.75× payload.
**Fix:** `static const String& body() { ... return server.arg("plain"); }` (or take `const String&` at call sites). One-line change, biggest single RAM-headroom win in the web layer.

### O4. `/api/command` allocates 8 KB JSON doc for every command (web_api.cpp:623)
Even `set_brightness` pays `MAX_SCROLL_TEXT_BYTES + 4096`. Size by `body().length()` (e.g. `min(len*2+512, 8500)`) to keep `start_scroll`-with-text working while making the common case ~500 B.

### O5. `/api/status` builds a 6 KB doc per poll (web_api.cpp:236)
Measured payload is well under 2 KB of pool; polled frequently by the UI. Right-sizing (~3 KB) halves the heap churn per poll. Same idea for `previewSync` (1,280 B is fine) and `frame` (1,024 B fine). Minor.

### O6. `readStringFromFileLocked` / `writeStringToFileLocked` cycle the storage lock 3× per call (storage.cpp:27–56)
Each cycle takes *two* mutexes (Storage + HardwareBus). Exists/open/read could be one lock hold; also removes the exists→open TOCTOU. Minor (cold paths), but free.

### O7. `mode`/`playback` as `String` with per-loop compares (faces.cpp:16, state.h:28–29)
`isAutoMode()` does a String compare every loop iteration via `serviceAutoPlayback`. Cost is trivial, but an enum + `toString()` for the API would remove repeated heap-backed compares and the scattered `"auto_saved_face"` literals. Cleanup-tier.

### O8. RMT `refresh()` blocks up to a full frame (~11.3 ms) holding the bus lock (led_driver.cpp:343–364)
`rmt_tx_wait_all_done` preserves the synchronous `show()` contract the render task relies on, so this is by design. A double-buffered async pipeline (encode next frame while previous transmits) could raise the max frame rate from ~60 → ~85 fps, but it complicates the presented-sample telemetry (which is keyed to "latch completed"). Not recommended unless you need >60 fps scroll.

---

## Function-path spot checks (verified OK)

- **Frame queue paths** (`enqueuePackedFrame` → immediate publish vs ring; `servicePackedFrameQueue` drain; overflow drops oldest + counts `framesDropped`) — correct, rate limit honored on both paths.
- **Scroll upload concurrency** (`scrollSessionWriteFrames` writes unlocked but only to slots ≥ `scrollFrameCount`, count published in `commitUpload` under lock) — safe-by-construction; the monotonic-index argument in the comment holds.
- **Scroll tick drift handling** (`scrollSessionTickCursorLocked`: `lastScrollFrameMs += interval` with 4-interval catch-up reset) — correct, wrap-safe.
- **Lock ordering** — no nested cross-domain acquisitions anywhere except the intentional Storage→HardwareBus pairing; scroll task takes Scroll then Frame *sequentially*, never nested.
- **`millis()`/`micros()` wraparound** — `millisReached`/`millisElapsed` are subtraction-based and wrap-safe; `packedFrameRateReady`'s `== 0` sentinel has a 1-in-4-billion no-op, acceptable.
- **Button paths** (debounce, B3 combo consume, repeat timing, B6 long-press via animation module) — all paths covered, no stuck-state holes found; `comboConsumed` reset on release.
- **`validatePackedFrame` tail-bit mask** for 370 % 8 = 2 — correct (`0x03` mask on byte 46).
- **Serpentine map** (`logicalToPhysicalLedIndex` + boot-time table) — correct against `ROW_OFFSETS`/`ROW_LENGTHS`; static_asserts already guard the layout.
- **Battery LUT interpolation, EMA with dt-based alpha, disconnect edge detection** — correct; percent hysteresis (±1) intentional.
- **`web_api frame()`** sets `playback` before `applyPackedFrameQueued`, but the frame was already validated above, so the only failure path can't be reached — no state corruption.
- **Boot sequence** — mutex-failure fallback to single-core render is coherent (`g_syncReady` gates task start and loop render).

## Suggested priority

1. B1/B2 (`scroll/meta` doc + stack) — user-visible bug.
2. B3 (saved_faces capacity) — blocks a documented feature limit.
3. O3 (body copy) — one line, large RAM headroom.
4. O1/O2 (ADC stalls) — loop latency.
5. C1, C2 decision, O4–O6 — as convenient.
