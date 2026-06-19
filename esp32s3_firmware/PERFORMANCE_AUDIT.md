# RinaChanBoard V2 — Frame / Realtime / Button Latency Audit

Scope: why GPIO button presses, realtime/live editing, and frequent frame sends feel
bogged down, and why a sent frame can wait a long time before it lights up.

Status: **Concluded.** The audit points to Core-0 stalls as the practical bottleneck,
with per-frame serial logging as the first fix to make before larger transport or
render-driver changes.

All file/line references are to the source as read with the editor tools (the sandbox
shell returns truncated copies of these files, so line numbers there differ — trust the
editor/IDE view).

Hardware/timing facts used throughout:
- 370 WS2812 @ 800 kHz ⇒ one `strip.show()` ≈ 370 × 24 × 1.25 µs ≈ **11.1 ms** of bus
  time, + `LED_SIGNAL_RESET_US` 300 µs before/after ⇒ ~11.7 ms wall-clock per refresh.
  Physical ceiling ≈ **80–85 FPS**, no matter what the queue does.
- Core affinity (platformio.ini): WebServer + buttons + queues + power on **Core 0**;
  LED render/scroll task on **Core 1**.
- `loop()` runs cooperatively on Core 0 and ends with `vTaskDelay(1)`.

---

## 1. Ranked list of likely bottlenecks

| # | Severity | Cause | File / function |
|---|----------|-------|-----------------|
| 1 | **Critical** | Per-frame/per-event `RLOG_INFO` logging on Core 0, written to **both** USB-CDC and UART0, on the same core that runs the HTTP handler, frame queue, and buttons. Blocks the hot path. | `serial_log.cpp` `rinaSerialWrite()`; `led_renderer.cpp` `applyM370`/`applyM370Immediate`/`applyLedDeltasImmediate`; `buttons.cpp` press/release/repeat/action logs |
| 2 | **High** | `ENABLE_SERIAL_UART0_MIRROR=1` in `platformio.ini` (overrides the safe default of `0`) — doubles every log write and adds a 115200-baud UART that blocks when its 256-byte TX ring fills. | `platformio.ini:49`; `serial_log.cpp:80-86` |
| 3 | **High** | USB-CDC `Serial.write()` can block for its TX timeout when no host monitor is draining the port — directly inside the frame apply path on Core 0. | `serial_log.cpp:82` |
| 4 | **Medium** | Non-live frame queue latency: WebUI posts every ~16 ms, firmware displays queued M370 frames no faster than `M370_FRAME_MIN_INTERVAL_MS=33`, drained **one per `loop()`**, depth 3. Burst tail can wait ~100 ms+. | `config.h:104-105`; `led_renderer.cpp` `enqueuePackedM370Frame`/`serviceM370FrameQueue`; `main.cpp:93` |
| 5 | **Medium** | Power monitor blocks Core 0 ~**8 ms once per second**: 16 ADC samples × 250 µs × 2 channels. Periodic hitch during frame streaming. | `power_monitor.cpp:25-39, 293-455` |
| 6 | **Medium** | Per-request JSON cost on `/api/frame`: `String` copy of POST body + `PsramJsonDocument(4096)` alloc + serialized `String` reply, all inside the synchronous single-client `WebServer`. | `web_api.cpp:146-151, 289-299, 658-664` |
| 7 | **Low/By-design** | GPIO button overlays hold for `FLASH_HOLD_MS=1000` and override the frame; they also pause scroll and force ~30 Hz re-renders for that second. Expected feedback, but it *looks* like "frames not showing." | `button_animations.cpp:19, 456-493, 536-593` |
| 8 | **Low** | B3 mode toggle does a **synchronous LittleFS settings write** on Core 0 (once per press). | `faces.cpp:70, 154`; `storage.cpp:111-127` |
| 9 | **Low** | Shared WebUI `frameSendPump` interval (16 ms) also throttles live deltas, adding up to 16 ms before an "immediate" delta even leaves the browser. | `data/app.js` `WEBUI_CONFIG.firmwareQueues.m370SendIntervalMs`, `frameSendPump` |
| 10 | **Info** | `LED_RENDER_MIN_GAP_US=2500` is effectively harmless (a single show already exceeds it) — not a real source of latency. | `led_renderer.cpp` `renderCurrentFrameToLedStrip` |

---

## 2. True frame-display latency vs. expected behavior

**Genuine, avoidable latency**
- Serial logging stalls (#1–#3): every applied frame/delta runs `RLOG_INFO` synchronously
  on Core 0 before the HTTP handler returns. While Core 0 is blocked in `Serial.write` /
  `Serial0.write`, it is **not** running `serviceM370FrameQueue()`, `webServerTick()`, or
  `serviceHardwareButtons()`. This is the dominant contributor to "feels bogged down."
- Non-live queue tail (#4): real added delay of up to ~100 ms for the last frame of a burst.
- Power ADC hitch (#5): a real ~8 ms/second stall.
- HTTP/JSON per-request overhead (#6): real but small (single-digit ms) — matters only at
  high send rates because it stacks on the single-threaded server.

**Expected / by-design (not bugs)**
- `M370_FRAME_MIN_INTERVAL_MS=33` rate limiting and depth-3 newest-wins drop: intentional
  protection; the *drops* are desirable (newest-frame-wins), the *33 ms spacing* is the
  floor for queued non-live frames.
- Button overlay 1 s hold (#7): deliberate visual feedback that overrides the frame and
  pauses scroll. Frames sent during the overlay legitimately won't show until it expires.
- WS2812 ~11.7 ms/refresh: hard physical limit; you cannot display faster than ~80 FPS.

---

## 3. Does the frame queue build latency?

Yes, for **non-live** full-M370 frames (`queueFirmwareFrame` → reason `frame_update` →
`applyM370()` → `enqueuePackedM370Frame`):

- WebUI side: `frameSendPump` posts at ~16 ms with `coalesceLatest=true` and depth 3, so the
  browser already collapses to roughly one in-flight POST + newest queued. Good.
- Firmware side: `enqueuePackedM370Frame` publishes immediately only if the queue is empty
  **and** `m370FrameRateReady` (≥33 ms since last show). Otherwise it queues (max 3, oldest
  dropped). `serviceM370FrameQueue()` dequeues **at most one frame per `loop()` iteration**,
  and only when ≥33 ms have passed.
- Worst case: a 3-deep queue drains at 33 ms spacing ⇒ the newest frame can wait
  ~66–100 ms, plus HTTP round-trip, plus any Core-0 stall (logging/ADC) that delays the
  loop from reaching `serviceM370FrameQueue()`.

Net: depth-3 + newest-wins means you never display *stale* intermediate frames, but the
**final** frame of a fast burst is delayed by the 33 ms floor × residual queue depth, and
further by whatever blocks Core 0. This matches "a frame waits a long time before display."

Live frames do **not** go through this queue (see §4).

---

## 4. Does realtime/live mode use the immediate path consistently?

Mostly yes, with one browser-side throttle to relax.

- **Reason strings:** `editCell()` → `sendCustomFrameIfLive("custom_live_send")`;
  parts page → `sendPartsFrameIfLive("parts_live_send")`. Both start with `custom_live_` /
  `parts_live_`, so `handleApiFrame()` sets `liveFrame = true` (`web_api.cpp:708`).
- **Delta path:** live edits send `{changes:[[idx,val]…]}` via `queueFirmwareLedDeltas`,
  which firmware routes to `applyLedDeltasImmediate()` → `publishPackedFrameNow()`
  directly. **This bypasses `M370_FRAME_MIN_INTERVAL_MS`** (no `m370FrameRateReady` gate, no
  queue) and bypasses the heavy reply (the fast-ack added earlier). Good — this is the
  low-latency path.
- **Live full M370 (no delta):** reason `*_live_*` with an `m370` field →
  `applyM370Immediate()` → also immediate, also bypasses the 33 ms gate. Good.
- **Deltas vs. the 33 ms limit:** confirmed bypassed. One subtlety: `publishPackedFrameNow`
  sets `lastM370FrameApplyMs = millis()`, so an immediate live frame pushes back the *next
  queued* frame's rate-ready time by 33 ms — fine for pure-live use, slightly interacts when
  mixing live + queued.
- **Shared `frameSendPump` 16 ms interval (browser):** live deltas use the same pump as
  bulk frames, so a delta can wait up to ~16 ms in the browser before it's even sent. With
  `coalesceLatest=true` this is correct (newest delta is a full diff from the last acked
  baseline, so dropping intermediates is safe and matches newest-wins), but the 16 ms floor
  is unnecessary latency for single edits. Recommend a shorter interval (or 0) for the delta
  pump while keeping coalescing.

---

## 5. Serial logging overhead (the #1 issue)

Path: `RLOG_INFO(...)` → `rinaLogEmit()` formats one line into a stack buffer →
`rinaSerialWrite()` → `Serial.write()` **and** (because `ENABLE_SERIAL_UART0_MIRROR=1`)
`Serial0.write()`. `serial_log.cpp:80-86`.

**Bytes per frame at INFO:** a typical LED line —
`[123456 ms] [INFO] [LED] event=delta reason=custom_live_send changes=1 lit=42 bytes=47 brightness=50` —
is ~95–115 bytes. Each applied frame emits one such line (plus `rinaLogRecordLedCommand`,
which is cheap). Button actions emit several lines per press/release/repeat.

**Why it blocks Core 0:**
- **UART0** at 115200: 1 byte ≈ 86.8 µs ⇒ a 100-byte line ≈ **8.7 ms** of transmit time.
  The Arduino `HardwareSerial` TX ring is ~256 bytes; it absorbs ~2 lines, then `write()`
  **blocks** until the ring drains. At 30–60 applied frames/s the ring is perpetually full,
  so every frame pays a multi-ms blocking write.
- **USB-CDC** (`Serial`, `ARDUINO_USB_CDC_ON_BOOT=1`): if the host serial monitor isn't open
  / isn't reading, `HWCDC::write()` blocks up to its TX timeout before giving up. That stall
  happens **inside `applyLedDeltasImmediate`/`applyM370Immediate` on Core 0**, i.e. inside
  the HTTP handler, delaying the response, the next queue service, and button polling.

This single factor can turn a ~12 ms render-bound live update into tens of ms of
hand-to-mouth stalling, and it scales with send rate.

**Recommendations (cheapest first):**
1. **Stop logging per applied frame at INFO.** Demote the `event=apply`/`event=delta`/
   `event=clear` lines in `led_renderer.cpp` to `RLOG_TRACE` (off by default) or rate-limit
   them with `rinaLogRateReady(&cursor, 1000)` like the scroll-tick log already does
   (`scroll.cpp:46-51`). Keep `rinaLogRecordLedCommand` (it's a cheap in-RAM ring).
2. **Set `ENABLE_SERIAL_UART0_MIRROR=0`** in `platformio.ini` for normal/production builds
   (keep it only on the dedicated test env). Removes the guaranteed-blocking UART path.
3. **Lower the default log level to `WARN`** (`serial_log.cpp:19 sLogLevel`) so INFO chatter
   (button press/release/repeat, mode, face) doesn't hit the wire during interaction.
4. **Make logging non-blocking by construction:** for production, compile diagnostics out
   (`ENABLE_SERIAL_DIAGNOSTICS=0` → every `RLOG_*` becomes `do{}while(0)`), or wrap
   `rinaSerialWrite` to skip USB-CDC when `!Serial` (not connected) and to drop instead of
   block when the TX buffer is full.

---

## 6. HTTP / JSON overhead

- **One POST per delta/frame** over a synchronous, single-client `WebServer`
  (`webServerTick()` = `server.handleClient()`, `web_api.cpp:1603-1608`). While one
  `/api/frame` is being parsed/answered, no other request runs and `loop()` is parked in
  `handleClient()`. So handler duration directly gates queue service and button polling.
- **Allocations / `String` churn per request** (`web_api.cpp`):
  - `requestBody()` returns `server.arg("plain")` → a full `String` **copy** of the body.
  - `parseJsonBody` deserializes into `PsramJsonDocument(4096)` — a 4 KB PSRAM allocation
    per request even though a live delta body is tiny.
  - `sendJsonDocument` serializes into another heap `String` before `server.send`.
- **Suggestions**
  - For `/api/frame`, parse with a small `StaticJsonDocument<512/1024>` (stack, no PSRAM
    alloc) since delta and single-M370 bodies are small; reserve the 4 KB doc only for the
    bulk scroll-upload endpoints.
  - The live fast-ack reply is already minimal (good). Consider an even cheaper
    `server.send(200, "application/json", F("{\"ok\":true}"))` for deltas to skip JSON
    serialization entirely.
  - **Best structural win for high-rate realtime:** add a **WebSocket** (or raw UDP) channel
    for live deltas. One persistent connection removes per-edit TCP/HTTP setup, header
    parsing, and the `String`/JSON allocations, and lets you push a compact binary delta
    (e.g. `[u16 idx | u8 val]` pairs, or a 47-byte packed bitmap). This is the highest-impact
    change if you want sustained high-frequency realtime, but it's the largest in scope.
  - Compact delta format even over HTTP: send `idx,val` as a binary body to a
    `/api/frame_delta` endpoint to avoid JSON parsing.

---

## 7. Render cost

- `strip.show()` for 370 WS2812 ≈ **11.1 ms** bus time; with 300 µs reset guards ≈ 11.7 ms.
  **Max physical ≈ 80–85 FPS.** Any send rate above that is coalesced/dropped regardless.
- `renderCurrentFrameToLedStrip()` (`led_renderer.cpp`) copies the frame under the frame
  mutex (fast `memcpy`), **releases it**, then does the ~11 ms `show()` under the hardware
  bus mutex only. So the long part does **not** hold the frame lock — Core 0 can keep
  publishing new bits while Core 1 is mid-show (newest-wins is preserved). Good design.
- `LED_RENDER_MIN_GAP_US=2500`: measured from the end of the previous show; since a show is
  ~11 ms, the elapsed time is already > 2.5 ms on the next render, so this delay essentially
  never fires. **Not** a latency source. (You could delete it for clarity, but it's benign.)
- **Adafruit_NeoPixel:** `show()` blocks the calling task for the full ~11 ms and, depending
  on the ESP32 core path, may briefly gate interrupts. Because it runs on the dedicated Core
  1 render task, it does **not** block buttons/HTTP on Core 0. The cost is that Core 1 is
  CPU-busy ~11 ms per refresh, capping render throughput.
  - **DMA alternatives:** the ESP-IDF `led_strip` RMT driver, FastLED's RMT/I2S backend, or
    an I2S/SPI WS2812 driver transmit via DMA so the CPU is freed during the ~11 ms. This
    raises sustainable refresh headroom and reduces jitter, but won't beat the ~11 ms
    physical data time. Worth it only if Core 1 CPU time becomes the limit (e.g. heavy scroll
    + overlay). Medium-to-large change.

---

## 8. Lock contention & task scheduling

Locks in play: frame mutex (`withFrameLock`), scroll mutex (`withScrollLock`), hardware bus
mutex (`withHardwareBusLock`), plus spinlocks (`sAnimMux`, `sPowerStatusMux`,
`sLedHistoryMux`, `ledRenderRequestMux`).

- **Frame mutex:** held only for short `memcpy`/field updates in `publishPackedFrameNow`,
  `renderCurrentFrameToLedStrip` (copy-out), `setBrightness`, and the scroll task's frame
  commit. No long critical sections. Good.
- **Hardware bus mutex:** held for the ~11 ms `show()`. Only the render path takes it, so no
  cross-subsystem contention — but it does serialize any future second caller; keep all
  `strip.show()` calls on the render task.
- **Scroll mutex:** taken by the render task each tick and by overlay pause/resume and
  scroll session ops on Core 0. Sections are short. The overlay path deliberately snapshots
  power **outside** `sAnimMux` (`button_animations.cpp:541-553`) to avoid nesting spinlocks
  while interrupts are disabled — good.
- **Spinlocks (`portENTER_CRITICAL`)** disable interrupts on the current core. They're all
  short (struct copy / counter bump). The one to watch is `readPowerStatusSnapshot()` copying
  a ~120-byte struct under `sPowerStatusMux`; it's called from the overlay and HTTP handlers
  — fine at current call rates.
- **Ordering risk:** no lock is held across `Serial`/flash I/O (verified for the logging ring
  and storage paths), and the render task drops the frame lock before `show()`. No deadlock
  ordering issues found. The real scheduling problem is not contention but **Core 0 being
  blocked by serial/flash/ADC** (see #1, #5, #8/§9), starving `serviceM370FrameQueue` and
  buttons.

---

## 9. GPIO button latency

- **Debounce** `BUTTON_DEBOUNCE_MS=25` (`config.h:127`): a press is recognized only after
  25 ms stable — expected, fine.
- **Polling cadence:** `serviceHardwareButtons()` runs once per `loop()` (≈ every 1 ms +
  whatever blocked the loop). So button responsiveness degrades exactly when Core 0 is
  blocked by logging/ADC/flash — the same root causes as frame latency.
- **B1/B2 saved-face apply:** `applyRelativeSavedFace(..., immediate=true)` →
  `applyM370Immediate` (no flash). Fast — except it emits INFO `FACE`/`LED` log lines (#1),
  and on **repeat** (every `FACE_REPEAT_MS=350`) it re-applies + re-logs.
- **B3 mode toggle:** `toggleModeFromButtonAction` → `setMode(..., persist=true)` →
  **`saveRuntimeSettings()` synchronous LittleFS atomic write** on Core 0
  (`faces.cpp:70,154`; `storage.cpp:111-127`). One flash write per press (tens of ms,
  blocks the loop). Also may `applyBlankFrame` then deferred restore after
  `LED_STOP_CLEAR_BLANK_HOLD_MS=90`.
- **B4/B5 brightness:** `setBrightness` does **no** flash write (just `touchRuntimeStateSlow`
  + render) — good, so brightness repeats (every `BRIGHTNESS_REPEAT_MS=120`) are cheap apart
  from logging.
- **Overlays:** every GPIO action starts a 1 s overlay that overrides the LEDs and pauses
  scroll (by design; see #7).
- **Recommendations:** debounce/defer `saveRuntimeSettings()` (mark dirty, write from a
  low-priority timer after N seconds of no change, like the battery-calib save already does),
  and demote/rate-limit button log lines.

---

## 10. Power monitor impact

- `servicePowerMonitor()` is called every `loop()` (`main.cpp:102`) but only samples when
  ≥`BATTERY_SAMPLE_MS`/`CHARGE_SAMPLE_MS` = **1000 ms** elapsed.
- When it does sample, `readTrimmedAdcMilliVolts()` takes **16 samples with a 250 µs delay
  each** = **4 ms blocking per channel**, two channels ⇒ **~8 ms Core-0 stall once per
  second** (`power_monitor.cpp:25-39, 293-455`). During frame streaming this is a periodic
  visible hitch.
- **Auto min/max calibration is disabled** (`updateBatteryCalibration` is a no-op), so the
  only flash writes are the 15 s-delayed calib save and **manual** reset commands — not on
  the streaming hot path. Good.
- **Recommendations:** reduce `POWER_ADC_SAMPLES` (e.g. 8) and/or the 250 µs inter-sample
  delay; or move ADC sampling to a low-priority task / spread the 16 samples across loop
  iterations; or skip/great-defer sampling while a live/scroll frame stream is active.

---

## 11. Recommended instrumentation

Add lightweight µs timers (guarded by a `RLOG_TRACE` or a compile flag, **never** logged
per-frame at INFO) and expose counters via `/api/status` rather than per-frame serial:

- `handleApiFrame` stages: body read, `deserializeJson`, apply, reply serialize+send
  (wrap each with `esp_timer_get_time()`).
- Apply path: time in `applyM370`/`enqueuePackedM370Frame` vs `publishPackedFrameNow`.
- Render: timestamp at `requestLedRender()` and at the start of `renderCurrentFrameToLedStrip`
  to measure **request→show latency**; time `strip.show()` itself.
- Queue: enqueue timestamp per `QueuedM370Frame`; on dequeue compute **dequeue age**; export
  running max. Add counters for `framesDropped`, `framesQueued`, `framesDequeued` (already
  present in `runtimeState()`), plus a max-queue-age gauge.
- `serviceHardwareButtons` and `servicePowerMonitor` durations (catch the 8 ms ADC stall).
- Serial: bytes written/sec and count of blocked/timed-out CDC writes.
- HTTP: per-request duration histogram (min/avg/max) for `/api/frame`.

Expose as a `GET /api/perf` JSON snapshot (counters + gauges), and reset on read. This keeps
measurement off the serial hot path.

---

## 12. Concrete patches — ordered safest/highest-impact → larger

**Tier A — safe, high impact, do first**
1. **Demote per-frame LED logs** in `led_renderer.cpp` (`applyM370`, `applyM370Immediate`,
   `applyLedDeltasImmediate`, `applyBlankFrame`) from `RLOG_INFO` to `RLOG_TRACE`, or
   rate-limit to ≤1/s with `rinaLogRateReady`. Keep `rinaLogRecordLedCommand`.
2. **`ENABLE_SERIAL_UART0_MIRROR=0`** in the default `[env:esp32s3]` build; keep `=1` only in
   `[env:esp32s3-test]`.
3. **Default log level `WARN`** (`serial_log.cpp:19`) so button/mode/face INFO lines don't hit
   the wire during interaction. (Runtime `log level info` still available for debugging.)
4. **Guard CDC writes:** in `rinaSerialWrite`, skip `Serial.write` when `!Serial`
   (USB not connected) and never block — drop on full buffer.

Expected effect: removes the dominant Core-0 stalls; live edits become render-bound
(~12–30 ms), button response tightens, queued-frame service stops being starved.

**Tier B — small, targeted**
5. **Shorten the live-delta send interval** in `data/app.js`: give deltas their own pump (or
   lower `m370SendIntervalMs` toward ~4–8 ms / 0) while keeping `coalesceLatest=true`
   (newest-wins). Bulk full-frame sends can keep 16 ms.
6. **Debounce settings persistence:** make `saveRuntimeSettings()` from B3 mode toggle (and
   `setAutoInterval`) mark-dirty + write from a deferred timer (mirror the battery-calib
   15 s pattern) so no flash write sits on the button path.
7. **Lighten `/api/frame` JSON:** parse with `StaticJsonDocument<1024>` instead of
   `PsramJsonDocument(4096)`; for deltas reply with a literal `{"ok":true}` to skip
   serialization.
8. **Trim power ADC:** `POWER_ADC_SAMPLES` 16→8 and/or drop the 250 µs delay; or spread
   sampling across loop iterations. Cuts the 8 ms/s hitch to ~2–4 ms or less.

**Tier C — structural (only if you need sustained high-rate realtime)**
9. **WebSocket (or UDP) live channel** with a **binary** delta/bitmap payload, replacing
   per-edit HTTP POSTs. Removes TCP/HTTP/JSON/`String` overhead and decouples realtime from
   the synchronous `WebServer`.
10. **DMA WS2812 driver** (ESP-IDF `led_strip` RMT, FastLED RMT/I2S, or I2S/SPI) to free
    Core 1 during the ~11 ms transmit and reduce jitter. Won't beat the physical ~11 ms/frame
    but raises headroom under scroll+overlay load.
11. **Drain the firmware frame queue more aggressively when rate-ready:** allow
    `serviceM370FrameQueue()` to publish the newest queued frame immediately (skip
    intermediates) instead of one-per-loop, so a burst tail shows within one 33 ms slot
    rather than queue-depth × 33 ms. (Still bounded by the 33 ms WS2812-friendly floor.)

**Behavioral guarantees to preserve while doing the above**
- Newest-frame-wins (drop intermediates) — keep `coalesceLatest` and depth-bounded queue.
- Don't block GPIO buttons — keep flash/serial/ADC off the Core-0 hot path (Tier A/B).
- Keep firmware scroll stable — leave the Core-1 render task, frame-lock-released-before-show
  design, and overlay pause/resume intact.

---

### One-line summary
The realtime delta path is already architecturally correct (immediate apply, no 33 ms gate,
fast ack). What makes it *feel* slow is **Core-0 being blocked** — overwhelmingly by
**per-frame INFO serial logging mirrored to USB-CDC + UART0**, with secondary hits from the
once-per-second ADC sampling, the synchronous settings write on mode toggle, and the
one-frame-per-loop drain of the non-live queue. Fix Tier A first; it addresses the bulk of
the symptom with near-zero risk.

---

## 13. Final conclusion

This is not primarily a WS2812 throughput problem and not a broken realtime path. The
hardware has an unavoidable ~11.7 ms refresh cost, but the firmware already routes live
deltas around the 33 ms queued-frame limiter and applies them immediately. The lag comes
from Core 0 being occupied by blocking side work while it is also responsible for HTTP,
frame queue service, button polling, and power monitoring.

The first production patch should therefore be the low-risk logging cleanup: remove or
demote per-frame LED INFO logs, disable UART0 mirroring in the normal build, and make
serial output drop/skip instead of blocking when no host is draining it. That should make
live edits feel render-bound instead of serial-bound, and should also improve button
latency because the same Core-0 stalls affect both paths.

After that, measure before making structural changes. If the system is still not responsive
enough, apply the Tier B items in this order: separate the live-delta browser pump from the
bulk frame pump, defer settings saves from button actions, trim or spread ADC sampling, and
lighten `/api/frame` JSON handling. WebSocket/UDP live transport and a DMA LED driver are
valid future upgrades, but they should come after the serial, flash, ADC, and browser-pump
costs are removed or measured.

Acceptance target for this audit: with Tier A applied, single live-cell edits should be
limited mostly by the next LED refresh (~12-20 ms typical path, depending on timing), GPIO
button recognition should stay close to debounce cadence unless an intentional overlay is
active, and non-live burst tails should no longer be stretched by serial backpressure.
