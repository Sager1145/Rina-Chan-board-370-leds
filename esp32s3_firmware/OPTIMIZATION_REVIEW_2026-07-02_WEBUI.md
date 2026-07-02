# Optimization Review — 2026-07-02 (Web UI focus + firmware follow-ups)

> **Status update (same day):** W2 (memoized `renderState()` + `updateModeToggleUi()`),
> W3 (`contain: layout paint` on `.matrix-wrap`, paired `contain: none` on the
> `.custom-preview-card` overflow-visible override), and F1 (`sendFileChunked` 1 KB →
> static 4 KB buffer) are **IMPLEMENTED**. W1 (80 ms idle preview-sync poll) was
> **decided: keep as-is** — the rate is a product requirement for hardware-button
> latency and is now documented as intentional at `BUTTON_EVENT_SYNC_POLL_MS` and
> `previewSyncPollDelayMs()` in app.js. W4/W5/W6/F2/F3 remain open as
> measurement-first/optional items.

Scope: full repo pass. The firmware C++ was already audited and fixed the same day
(`CODE_REVIEW_2026-07-02.md`: B1–B4, C1–C3, O1–O6 implemented; O7/O8 intentionally skipped).
This review confirms those fixes are in place and finds **no regression from them**. The
remaining opportunities are concentrated in the **Web UI** (`data/app.js` 14k lines,
`data/styles.css` 3.3k lines), which the previous pass explicitly did not cover, plus three
small firmware follow-ups.

Rule followed throughout: **no behavior changes**. Every fix below is either a pure
DOM-write dedupe, a buffer-size change, or an explicitly flagged "needs measurement /
user decision" item. Nothing here changes APIs, routes, JSON shapes, storage keys, polling
semantics, or visuals unless marked as a decision.

---

## Summary

The codebase is in unusually good shape: the firmware hot paths are clean (precomputed
index map, snapshot-under-lock, IRAM RMT encoder, PSRAM-first allocation, rate-limited
logging), and the web UI already has dirty-diff matrix rendering, rAF batching,
visibility-gated polling, and in-flight guards.

The main remaining performance risks are:

1. **Idle network + DOM churn loop (runtime, network, mobile battery).** With the page
   visible and nothing happening, the UI issues ~14 HTTP requests/second to the
   single-threaded ESP32 WebServer (preview_sync every 80 ms + status ≥1 s + power ~1 s),
   and **every** request start calls `renderState()`, which unconditionally rewrites
   badge classNames/styles/text. This is the dominant steady-state cost on both ends.
2. **Per-cell paint cost of the LED matrix glow (rendering, mobile).** Each lit cell
   carries 2–3 `box-shadow` layers + `radial-gradient` + `color-mix`, up to 396 cells per
   view, several views, toggled at up to 60 fps during scroll preview.
3. **Static-asset streaming granularity (startup/network).** `sendFileChunked()` uses a
   1 KB buffer; each chunk cycles the Storage lock (two mutexes) and one `sendContent`.
   The gzipped app.js pays ~100+ lock cycles and small TCP writes per load.

---

## Highest-impact optimization opportunities (prioritized)

| # | Item | Layer | Class |
|---|------|-------|-------|
| 1 | W2: memoize DOM writes in `renderState()` (skip writes when values unchanged) | app.js | Safe quick fix |
| 2 | W1: adaptive backoff for the 80 ms idle preview-sync poll | app.js | Needs measurement first (latency contract) |
| 3 | F1: enlarge `sendFileChunked` buffer 1 KB → 4 KB (static buffer, not stack) | web_api.cpp | Safe quick fix / verify LED gap |
| 4 | W3: `contain: layout paint` (+ optional style) on `.matrix` / matrix wrap | styles.css | Safe quick fix |
| 5 | W4: two-phase measure/write in `fitAllMatrices()` | app.js | Medium-risk refactor (low urgency) |
| 6 | F2: rate-limit INFO logging on per-frame HTTP paths | led_renderer.cpp | Needs measurement first |
| 7 | W5: reduce `.led.on` glow layers on small cells / mobile | styles.css | User decision (visual change) |
| 8 | F3: idle wake period of render task / main loop (1 ms) | scroll.cpp / main.cpp | Needs measurement first (leave as-is by default) |

---

## Detailed findings

### W1. Idle preview-sync poll runs at 12.5 Hz whenever the page is visible
- **File/function:** `data/app.js` — `previewSyncPollDelayMs()` (~line 10442),
  `BUTTON_EVENT_SYNC_POLL_MS = 80` (line 3084), `shouldPollPreviewSync()` (~10432).
- **Problem:** When *not* scrolling but saved faces exist, the self-scheduling poller hits
  `/api/preview_sync` every 80 ms. Combined with the 500 ms status tick (min 1 s) and the
  1 s power poll, the idle UI generates ~14 req/s against a single-threaded sync WebServer.
- **Why it matters:** Steady CPU + Wi-Fi power draw on the phone; constant handler load on
  the ESP32 (JSON build + heap churn per request); contention window for any real request.
  Affects runtime, network, and mobile battery.
- **What depends on it:** This is intentional — it gives hardware button presses (B1–B6)
  fast reflection in the UI (~80 ms). Any backoff increases that latency, so this is a
  **behavior trade-off, not a free win**.
- **Severity:** Medium (sustained, but bounded and by design).
- **Safe fix (proposal, do not apply without sign-off):** keep 80 ms for N seconds after
  any user interaction or observed state-version change, then decay to 250–500 ms; any
  version change snaps back to 80 ms. Firmware already sends `v` in the payload, so change
  detection is free. Zero change while the user is actively using the board.
- **Test plan:** manual — press each hardware button with the UI idle >30 s; verify the UI
  reflects the change within one decayed interval and then re-tightens. Verify scroll
  preview sync cadence unchanged (250 ms path is separate). Automated — unit-test the
  delay function state machine if extracted.

### W2. `renderState()` rewrites DOM unconditionally, and is called on every API request start
- **File/function:** `data/app.js` — `renderState()` (~7538), `apiGet()` (~4516: sets
  `firmware.lastRequest` then calls `renderState()`), `setFirmwareStatus()` (~4492). ~44
  call sites total; with W1's cadence this runs 12–15×/s at idle.
- **Problem:** Each call assigns `className`, `style.backgroundColor`, `textContent`,
  `title` on the header badges even when values are identical, plus `updateModeToggleUi()`
  and (gated) `renderDebugReadouts()`. Repeated identical attribute writes still cost JS
  time and can trigger style-recalc work.
- **Why it matters:** Constant background main-thread work on the phone; multiplies with
  W1. Affects runtime/rendering on mobile.
- **What depends on it:** Nothing depends on redundant writes — the codebase's own rule
  ("all rendering functions should be idempotent") makes memoization safe.
- **Severity:** Medium.
- **Safe fix:** module-level cache of last-written values (one small object); write to the
  DOM only when the composed string/class actually changed. No call-site changes, no
  behavior change. Optionally: in `apiGet`, skip the `renderState()` call when only
  `firmware.lastRequest` changed and the debug page is not active (the only consumer of
  that field is the debug panel) — slightly larger change, do second.
- **Test plan:** what could break — a badge failing to update when state *does* change
  (cache key too coarse). Verify: cycle online/offline (stop AP), battery/charging states,
  mode toggle; badges must update exactly as before. Automated: none existing; a DOM
  snapshot test would be new infrastructure — manual checklist is sufficient here.

### W3. LED matrix cells are expensive to paint; invalidation can escape the grid
- **File/section:** `data/styles.css` — `.led`, `.led.on`, `.led-preview-wrap .led.on`
  (radial-gradient + `color-mix` + 2–3 box-shadows, blur radius scales with `--cell`);
  `data/app.js` `renderMatrices()` toggles `.on` per changed cell.
- **Problem:** During firmware/preview scroll at up to 60 fps, dozens of cells change class
  per tick; each lit cell paints gradient + multiple shadows. Without containment the
  browser may invalidate beyond the cell.
- **Why it matters:** This is the single largest repaint area in the app; low-power phones
  are the primary client. Affects rendering/interaction smoothness.
- **What depends on it:** The visual look of the board — glow is a design feature.
- **Severity:** Medium (needs measurement to confirm; dirty-diff already minimizes DOM
  writes, so cost is paint, not layout).
- **Safe fix (visually neutral):** add `contain: layout paint;` to the matrix container
  and/or `contain: layout paint style;` to `.matrix-wrap`. This clips invalidation to the
  grid and is not a visual change (shadows stay inside the wrap's padding; verify the
  edge-gap padding ≥ max shadow radius — `--matrix-edge-gap` exists precisely there).
- **User-decision fix (visual change, NOT applied):** on `@media (max-width: …)` or
  `.compact`, drop the outer glow to a single shadow layer. Only with sign-off.
- **Test plan:** DevTools → Performance + Paint flashing before/after on a mid-tier phone
  while scrolling text; verify glow is not clipped at matrix edges at min/max cell sizes
  (resize the card through its full range); verify editor drawing still repaints cells.

### W4. `fitAllMatrices()` interleaves layout reads and writes across views
- **File/function:** `data/app.js` — `fitMatrix()` (~7320: several `getComputedStyle` +
  `getBoundingClientRect` reads, then `style.setProperty` writes), `fitAllMatrices()`
  (~7396) loops views sequentially → up to N forced reflows per settle frame.
- **Why it matters:** Only runs on resize/orientation/visualViewport events and settle
  frames (already rAF-batched, 1–2 settle frames), so the cost is bounded; noticeable
  mainly during interactive resizes/rotation on mobile.
- **Severity:** Low.
- **Safe fix:** split `fitMatrix` into `measureMatrix(view) -> plan` and
  `applyMatrixPlan(view, plan)`; `fitAllMatrices` measures all, then writes all. Pure
  reordering; outputs identical.
- **Risk level:** Medium-risk refactor (function split touches a subtle sizing path).
- **Test plan:** resize window through breakpoints, rotate phone, open/close nav; cell
  sizes and `--matrix-edge-gap` values must be byte-identical (log them before/after in a
  quick manual harness).

### W5. Backdrop-filter blur on sticky chrome
- **File/section:** `data/styles.css` — 14 `backdrop-filter: … blur(var(--top-glass-blur))`
  instances on top bars/overlays; boot overlay uses `filter: blur(2.4px) + drop-shadow`.
- **Why it matters:** Continuous compositing cost while the page scrolls on low-end GPUs.
  Boot-time effects are one-shot and fine.
- **Severity:** Low–medium on old phones; purely aesthetic feature.
- **Recommendation:** measurement first (GPU frame times while scrolling the page on a
  low-end device). If confirmed, the non-breaking option is honoring
  `prefers-reduced-transparency`/a settings toggle — **visual change, user decision**. Not
  applied.

### W6. Re-init hazard: `initMatrix()` stacks click listeners if ever re-run
- **File/function:** `data/app.js` — `attachDrawing()` adds a `click` listener each call;
  `initializeMatrixViews()` resets `matrixViews = []` but doesn't remove old listeners.
  Today it runs exactly once (line ~13900), and the `matrix-basic` re-init path (~13825)
  is guarded, so there is **no live leak** — this is a latent hazard, not a current bug.
- **Safe fix:** guard with `el.dataset.drawingBound` before adding the listener. One line,
  no behavior change.
- **Test plan:** editor click toggles exactly one cell state change per click (unchanged);
  no automated coverage needed.

### F1. `sendFileChunked()` streams static assets in 1 KB chunks
- **File/function:** `src/web_api.cpp` — `sendFileChunked()` (~line 171): per chunk, one
  Storage-lock cycle (two mutex take/give), one flash read, one `sendContent`.
- **Problem:** The gzipped `app.js` (~100+ KB) pays 100+ lock cycles and 100+ small TCP
  writes per cold load; `index.html`/CSS similar. This shapes first-load latency, which the
  cache-policy comment identifies as a historical pain point.
- **What depends on it:** The C2 invariant — flash reads must hold the Storage lock so they
  serialize with the WS2812 latch. **Keep the per-chunk locking; only enlarge the chunk.**
- **Severity:** Low–medium (startup/network only).
- **Safe fix:** raise the buffer to 4 KB. Do **not** put 4 KB on the loopTask stack (B2
  lesson): use a `static uint8_t buf[4096]` — safe because the sync WebServer serves one
  request at a time on one task. Lock hold per chunk grows to ~1 flash read of 4 KB
  (~100–200 µs), still far below a frame budget.
- **Risk level:** Safe quick fix (verify the LED claim below).
- **Test plan:** what could break — LED scroll jitter during asset download if the longer
  hold matters. Verify: run a firmware text scroll while hard-reloading the UI 5×; watch
  `ledRefreshMaxUs` and visible stutter (same test the C2 fix used). Measure cold-load time
  before/after (`curl -H "Accept-Encoding: gzip" -w %{time_total}`). Confirm byte-identical
  responses (hash the body) and unchanged headers.

### F2. Per-frame INFO logging on the HTTP frame path
- **File/function:** `src/led_renderer.cpp` — `applyPackedFrameQueued()` /
  `applyPackedFrameImmediate()` emit `RLOG_INFO` + `rinaLogRecordLedCommand` per accepted
  frame. During rapid editor drawing (frame POSTs), each ~100-char line goes out
  synchronously via `rinaSerialWrite`.
- **Why it matters:** USB-CDC writes are cheap with a host attached and drop fast without
  one, so this is likely fine — but it is the only unbounded per-event I/O left on a hot
  HTTP path. Scroll ticks correctly bypass it (TRACE + 1/s rate limit).
- **Severity:** Low. **Needs measurement first** (time `applyPackedFrameQueued` with/without
  a serial host during a drag-draw session).
- **Safe fix if confirmed:** rate-limit the INFO line (e.g. ≤5/s) via the existing
  `rinaLogRateReady` helper, keeping the history ring untouched (`rinaLogRecordLedCommand`
  stays per-frame — the debug console depends on it).
- **Test plan:** serial console `led history` still shows every command; log line still
  appears for isolated commands; drag-draw shows rate-limited lines.

### F3. 1 ms idle wake of render task and main loop
- **File/function:** `src/scroll.cpp` (`ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1))`),
  `src/main.cpp` (`vTaskDelay(pdMS_TO_TICKS(1))`).
- **Assessment:** 1 kHz wakeups with cheap early-return service calls. Scroll timing
  granularity, button debounce, and the O1 ADC scheme all assume ~1 ms cadence. Power is
  dominated by Wi-Fi (modem sleep is deliberately off) and LEDs, so tick-reduction buys
  almost nothing. **Recommendation: leave as-is.** Listed only for completeness; any change
  is high-risk relative to its benefit.

### Verified non-issues (checked, no action)
- Firmware O1–O6/B1–B4/C1–C3 from `CODE_REVIEW_2026-07-02.md` are correctly implemented in
  the current tree (spot-verified in web_api.cpp, power_monitor.cpp, storage.cpp, main.cpp,
  led_renderer.cpp).
- Web UI: matrix dirty-diff rendering, log rAF batching + view cap, visibility-gated
  pollers with `pagehide` cleanup, in-flight guards on all pollers, upload-aware poll
  suppression (P1-6), preload/caching strategy with `?v=` stamping + immutable headers,
  PSRAM-first JSON — all sound.
- No unbounded growth found: `logs` ring-capped; `matrixViews` rebuilt only once;
  listeners are one-time global bindings in an SPA that never tears down.

---

## Recommended implementation order

1. **W2 memoized `renderState()`** — pure dedupe, biggest steady-state win, trivially
   reviewable, independently testable.
2. **W6 listener guard** — one line while in the same file.
3. **W3 CSS containment** — one declaration; visual-parity check.
4. **F1 chunk size 1 KB → 4 KB (static buffer)** — isolated firmware change; run the
   scroll-while-download jitter test before merging.
5. **Measure** W1 (request rate / battery), W5 (GPU), F2 (serial timing) on real hardware.
6. **W1 adaptive backoff** — only after step 5 and after agreeing the button-latency
   trade-off; implement behind a constant so 80 ms fixed behavior is one revert away.
7. **W4 measure/write split** — optional, last; only if resize jank is actually observed.

## Code change plan (exact edits, pending approval)

1. `data/app.js` `renderState()`: add `const _rsCache = {}` in module scope; before each
   badge write, compose the target string; `if (_rsCache.k !== v) { el.… = v; _rsCache.k = v; }`
   for: runtime dot class, runtime label, runtime badge title, battery label, battery dot
   class, battery dot color, charging dot class, charging dot color, charging label.
   `updateModeToggleUi()` and `renderDebugReadouts()` calls unchanged.
2. `data/app.js` `attachDrawing()`: first line
   `if (el.dataset.drawingBound) return; el.dataset.drawingBound = "1";`
3. `data/styles.css`: add `contain: layout paint;` to the matrix grid container rule
   (and test `.matrix-wrap` variant); nothing else in the rule changes.
4. `src/web_api.cpp` `sendFileChunked()`: `uint8_t buf[1024]` →
   `static uint8_t buf[4096]` with a comment stating the single-threaded-server invariant;
   loop logic unchanged.
5. W1 (only after sign-off): `previewSyncPollDelayMs()` gains a decay based on
   `performance.now() - lastActivityOrVersionChange`; constants at top of file next to
   `BUTTON_EVENT_SYNC_POLL_MS`.

## Compatibility checklist (must remain unchanged)

- **HTTP API:** all routes (`/api/status`, `/api/power`, `/api/frame[/current]`,
  `/api/scroll[/meta]`, `/api/preview_sync`, `/api/command`, `/api/saved_faces`), all JSON
  keys and shapes, base64 packed-frame encoding (47 bytes, LSB-first), error codes,
  CORS/cache headers, gzip negotiation.
- **Firmware timing contracts:** synchronous `refresh()` semantics (presented-sample
  telemetry), `PACKED_FRAME_MIN_INTERVAL_MS` rate limit, Storage↔HardwareBus lock pairing
  (C2), non-reentrancy invariant of `renderCurrentFrameToLedStrip` (C3), 1 ms service
  cadence (F3 left as-is).
- **Web UI behavior:** poll cadences (80/250/500/1000 ms) unchanged until W1 is separately
  approved; badge text/format, log format and caps, matrix visuals (glow), editor
  click/drag semantics, offline-HTML mode, visibilitychange suspend/resume, `?v=` cache
  stamping.
- **Data formats:** `saved_faces.json` (`unified_saved_faces`), `runtime_settings.json`,
  `battery_calib.json`, packed-frame layout, `WEBUI_CONFIG` keys.
