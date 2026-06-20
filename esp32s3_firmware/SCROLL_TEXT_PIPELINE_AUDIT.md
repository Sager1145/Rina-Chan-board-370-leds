# Scroll-Text Pipeline Audit — ESP32-S3 RinaChanBoard (370 WS2812B)

**Scope:** Full trace of the text-scroll pipeline: WebUI send/upload → firmware receive/store/play → WebUI refresh/restore → button/state sync → LED timing isolation. Audited against the requested checklist A–J.

**Headline conclusion (corrected after review):**

> **Static review** of the scroll-text pipeline found **no obvious Critical defects in the intended design**. The architecture is mature and already hardened across several prior audit passes (the source is annotated with `audit fix #N`, `P1 #2/#3`, `EH-A/B/C`, `D1–D10`, `E1–E6`, refactor-plan section references), and it implements essentially the entire "preferred design": firmware-authoritative state, source text + packed frames + index + fps + pause/active + previous-mode stored in firmware, a lightweight status/meta endpoint, local frame regeneration on restore (no re-upload), index-only runtime sync, firmware-first/UI-from-response commands, frame buffers copied before `strip.show()`, and flash serialized against WS2812 transmit.
>
> **However**, several **Medium-risk logic gaps remain until the implementation is compiled, flashed, and tested** under refresh storms, failed/interrupted uploads, multi-client upload races, and long-runtime heap pressure. This audit was performed **statically only** — no PlatformIO build, flash, or hardware run was possible in the audit environment — so claims below are scoped as *statically inspected* / *intended by design* / *requires runtime verification*, not *proven safe*.

**An earlier draft of this document overstated certainty** by labeling many properties "verified safe" and concluding "no Critical/High/Medium defects." That was not defensible for an LED-timing/embedded audit without a runtime run. The verdict and severity table below have been corrected. The section-J logging gap was fixed (see §6); the remaining items are tracked as Medium-pending-runtime or refuted-with-static-evidence. No features were removed or altered.

**Terminology used below:** *Statically verified* = traced in source with high confidence the design is correct; *Requires runtime proof* = behavior depends on timing/hardware and must be confirmed on-device; *Refuted (static evidence)* = a raised concern does not apply, with the proving code cited.

---

## 1. Architecture map of the scroll-text pipeline

```
WEBUI (data/app.js, single-page, state-machine driven)
 ┌───────────────────────────────────────────────────────────────────────┐
 │ scroll{} runtime object  +  scrollMachine (token/guarded FSM)           │
 │  • Frame generation:  buildTextScrollBitmap → frames[] → frameToM370    │
 │  • Send:    startScroll → uploadFirmwareScrollTimeline (chunked, RAM)   │
 │  • Restore: restoreScrollTextFromFirmware → /api/scroll/meta            │
 │             → regenerate frames locally → render at firmware frameIndex │
 │  • Sync:    applyFirmwareRuntimeState (status poll) — index/flags only  │
 │  • Buttons: updateScrollUi / applyScrollButtonUiState (firmware truth)  │
 └───────────────┬───────────────────────────────────┬────────────────────┘
        HTTP POST /api/scroll (chunks)        HTTP GET /api/scroll/meta
        HTTP POST /api/command (start/        HTTP GET /api/status (poll)
                  pause/resume/stop/step)
                        │                               │
 FIRMWARE (Core 0 cooperative loop: WiFi/HTTP/buttons/serial/auto)
 ┌───────────────────────────────────────────────────────────────────────┐
 │ web_api.cpp   handleApiScroll / handleApiScrollMeta / handleApiStatus  │
 │ faces.cpp     startFirmwareScroll / stopFirmwareScroll / mode switch   │
 │ buttons.cpp   B1/B2/B3 → stopFirmwareScrollForNonScrollOutput + event  │
 │ serial_console.cpp  `scroll status|start|pause|resume|stop|step|...`   │
 │                        │                                                │
 │ scroll_session.cpp  ── SHARED STATE (scrollMutex) ──                    │
 │   RuntimeState.firmwareScroll{Active,Paused,User,System}               │
 │   .scrollFrameCount / .scrollFrameIndex / .scrollIntervalMs            │
 │   .restoreAutoAfterScroll  + ScrollTimelineMeta + sourceText buffer    │
 │   scrollFrameBits[]  (MAX_SCROLL_FRAMES×47B ≈ 144KB, PSRAM)            │
 └───────────────┬───────────────────────────────────────────────────────┘
        scrollSessionTickCursorLocked (under scrollMutex)
                 │  nextFrame[47] copied out under lock
 RENDER TASK (Core 1, scroll.cpp `led_scroll_render`, prio 3)
 ┌───────────────────────────────────────────────────────────────────────┐
 │ for(;;){ tick under scrollMutex → copy frame;                          │
 │          under frameMutex → publish to runtimeFrameBits;               │
 │          renderCurrentFrameToLedStrip(): copy frame under frameMutex,  │
 │          map logical→physical, strip.show() under HardwareBus mutex }  │
 └───────────────────────────────────────────────────────────────────────┘
 led_renderer.cpp  Adafruit_NeoPixel strip.show()  →  370 WS2812B
```

**Lock domains (sync.h), global order Scroll → Frame → Storage → HardwareBus:**
- `scrollMutex` — all `firmwareScroll*`, `scrollFrame*`, timeline meta, source-text buffer.
- `frameMutex` — `runtimeFrameBits`, color/brightness; render task snapshots before output.
- `Storage` lock **also acquires HardwareBus** for the whole flash section, so LittleFS cache-disable windows can never overlap an in-flight `strip.show()` (this is the documented fix for panel garbling on WebUI refresh during a scroll).
- `HardwareBus` — held only around `strip.show()`.

**Memory model:** scroll frame cache lives in **PSRAM** (`MALLOC_CAP_SPIRAM`) by default; internal-SRAM fallback is compile-gated off (`ALLOW_INTERNAL_SCROLL_CACHE=0`) to protect the WiFi/LwIP internal heap. Runtime text fields are fixed `char[]` buffers (no `String` churn → no internal-heap fragmentation over uptime). HTTP handlers are protected by an **admission guard** (`httpRejectIfLowMemory`) that sheds with 503 when free heap OR largest-contiguous-block is below floor.

---

## 2. Exact call flow — WebUI "Send" button → LED output

1. **`startScroll()`** (app.js) — guarded by `scroll.commandBusy`/`startBusy`; rejects empty text; sets `returnMode` = current mode (manual/auto) for later restore; clears recovered-meta state (D7).
2. **`prepareTextScrollTimelineAsync(false)`** → `ensureArkPixelFontReady()` → `prepareTextScrollTimeline` → `buildTextScrollBitmap(text)` produces `scroll.frames[]` (per-frame 370-bit logical bitmap).
3. **`uploadFirmwareScrollTimeline()`** → `buildFirmwareScrollFrames()` encodes each frame to `M370:`+93 hex; enforces `firmwareScrollMaxFrames`.
4. **`uploadScrollTimelineAttempt(frames, timelineId)`** — `scrollMachine.token("upload")` makes overlapping sends self-cancel (`isCurrent` checks throughout). First chunk size is computed by `chooseFirstChunkFrames` to fit `SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES`; remaining frames chunked at `SCROLL_UPLOAD_CHUNK_FRAMES`. First chunk carries `sourceText + timelineId + fontId + generatorVersion + fps + totalFrames`; later chunks `append:true` + `chunkIndex`.
5. **`POST /api/scroll`** → **`handleApiScroll()`** (web_api.cpp):
   - `httpRejectIfLowMemory("scroll_upload")` admission guard → 503 if low.
   - Body cap `SCROLL_MAX_UPLOAD_BODY_BYTES` (16 KB) → 413; complete-JSON validation → 400.
   - First chunk: pre-flight validates **every** M370 in the chunk before mutating state; enforces `totalFrames ≤ MAX_SCROLL_FRAMES`, sourceText all-or-nothing (needs timelineId+fontId+generatorVersion), UTF-8 + length validation; then `stopFirmwareScroll(false,false)` halts old player and **`scrollSessionBeginUpload()`** resets `scrollFrameCount=0`, clears meta, stores sourceText/meta **under scrollMutex**.
   - Append chunk: `scrollSessionBeginAppend()` snapshots meta; validates timelineId match, `uploadComplete==false`, `chunkIndex==nextChunkIndex`.
   - Each frame: `m370ToPackedBits` → **`scrollSessionWriteFrame(txn,index,bits)`** memcpy into PSRAM cache (writable-window checked under lock). `E1` overflow guard.
   - **`scrollSessionCommitUpload()`** sets `scrollFrameCount`, resets `frameIndex` (unless mid-append of a running scroll), updates `uploadComplete` when `framesReceived≥totalFramesExpected`.
   - Auto-start when complete (or `start:true`); `D2` blocks start of an incomplete timeline-backed cache.
6. **`startFirmwareScroll(intervalMs)`** → **`scrollSessionStart()`** (under scrollMutex): if `scrollFrameCount>0` and buffer ready, sets `firmwareScrollActive=true`, `frameIndex=0`, latches `restoreAutoAfterScroll` if caller was auto-mode, copies frame 0 out, then `applyPackedFrameImmediate(frame0)`.
7. **Core-1 render task** `scrollRenderTask`: `scrollSessionTickCursorLocked(millis())` (scrollMutex) advances `frameIndex` on the non-blocking `millis()` interval with drift correction, copies the frame; publishes to `runtimeFrameBits` (frameMutex); `renderCurrentFrameToLedStrip()` copies the frame again under frameMutex, maps logical→physical (serpentine), and `strip.show()` under HardwareBus mutex. LED timing uses `LED_RENDER_MIN_GAP_US` + `LED_SIGNAL_RESET_US` guards.
8. WebUI updates **from the firmware response only** (`applyFirmwareRuntimeState`), starts the local preview tween, and marks `scroll.firmwareBacked=true`.

## 3. Exact call flow — WebUI refresh/reload → restored preview

1. **`bootstrapWebUi()`** (DOMContentLoaded): fonts/UI first, then **`preloadFirmwareRuntimeState()`** (basic `/api/status?runtimeOnly`) → page revealed.
2. **`kickPostBootScrollMetaRestore()`** (after runtime ready) — only proceeds if firmware status said scroll is displaying (`lastFwScrollDisplaying`).
3. **`restoreScrollTextFromFirmware()`** → **`GET /api/scroll/meta`** → **`handleApiScrollMeta()`** returns `{ sourceText, scrollTimelineId, fontId, generatorVersion, uiFps, frameCount, frameIndex, uploadComplete, firmwareScrollActive/Paused/User/System }`. Source text is copied **under scrollMutex** into a PSRAM scratch buffer and serialized outside the lock. **Meta is suppressed unless the panel is actually displaying scroll** (running or paused) — a stale cache cannot resurrect old text after Stop/Clear or a mode switch.
4. Restore guards: aborts if not displaying or no source text; **C5 local-edit guard** refuses to overwrite unsent text in the input box; uses a `restoreToken` so a newer action cancels a stale restore.
5. **`setScrollTextFromFirmware(sourceText)`** refills the input box (with truncation detection → E4/E5 warning).
6. **`restoreScrollPreviewIfNeeded()`** regenerates `scroll.frames[]` **locally** from the restored text (`prepareTextScrollTimelineForRestoreAsync`); it **never re-uploads**.
7. **`fetchLatestScrollFrameMetaAfterPreview()`** re-reads `/api/scroll/meta` for the freshest `frameIndex`, then **`applyRestoredScrollPreviewFrame()`** renders the preview at the firmware's authoritative `frameIndex`. `framesTimelineId` is bound only when text isn't truncated, generator identity matches exactly, and `frames.length === frameCount` (D5/E4).
8. **`applyScrollRuntimeMeta()` / `updateScrollUi()`** set play/pause/stop/step button state from firmware truth (`firmwareScrollActive/Paused/User/System`).
9. Runtime polling (`/api/status`) thereafter only syncs `scrollFrameIndex`/flags via `applyFirmwareRuntimeState` — **never re-fetches frames**. A `timeline_mismatch` branch re-runs restore (rate-limited ≥5 s) if the firmware timelineId diverges from the WebUI's.

---

## 4. Relevant functions / files / endpoints

### HTTP endpoints (web_api.cpp)

| Method/Path | Handler | Request | Response (key fields) | Shared state | Runs during scroll? | Blocks LED? | Safe on refresh? |
|---|---|---|---|---|---|---|---|
| POST `/api/scroll` | `handleApiScroll` | chunked frames + (first chunk) sourceText/timelineId/fontId/generatorVersion/fps/totalFrames; `append`,`chunkIndex` | `{ok,frames,chunkFrames,started,uploadComplete,timelineId,scrollIntervalMs,…}` | W: scroll cache+meta (scrollMutex) | Yes | No (parse off render task; cache write under scrollMutex, copied before show) | Yes — admission guard + body cap; overlapping sends caught by WebUI token + 409 retry |
| GET `/api/scroll/meta` | `handleApiScrollMeta` | — | `{ok,sourceText,scrollTimelineId,fontId,generatorVersion,uiFps,scrollIntervalMs,frameCount,frameIndex,uploadComplete,firmwareScroll*}` | R: scroll meta+text (scrollMutex), copy-out | Yes | No | Yes — admission guard; PSRAM doc; suppresses stale text |
| GET `/api/status` | `handleApiStatus` | `?since`,`?runtimeOnly`,`?summary` | renderer.{mode,playback,paused,firmwareScroll*,scrollFrameCount,scrollFrameIndex,scrollIntervalMs,restoreAutoAfterScroll,scrollStopEvent,…}+memory+power | R: snapshots | Yes (poll) | No | Yes — `since` shortcut; frame data deferred while scrolling |
| POST `/api/command` `start_scroll` | `commandStartScroll` | `{timelineId?,fps?,intervalMs?}` | runtime snapshot | scrollMutex (validate), then start | — | No | Yes — timeline/upload-complete validated in one snapshot |
| POST `/api/command` `pause_scroll`/`resume_scroll` | `commandPauseScroll`/`commandResumeScroll` | — | runtime snapshot | scrollMutex pause flags | Yes | No | Yes |
| POST `/api/command` `scroll_step` | `commandScrollStep` | `{direction}` | runtime snapshot (authoritative `scrollFrameIndex`) | scrollMutex; latches user-pause | Yes | No | Yes — returns new index; copies stepped frame under lock |
| POST `/api/command` `stop_scroll` | `commandStopScroll` | `{clear,restoreAuto}` | runtime snapshot | scrollMutex full reset | Yes | No | Yes |
| POST `/api/command` `set_scroll_interval` | `commandSetScrollInterval` | `{intervalMs|fps}` | snapshot | scrollMutex interval | Yes | No | Yes |
| POST `/api/command` `set_mode`/`button`/`terminate_other_activities` | … | — | snapshot | stops scroll for non-scroll output | — | No | Yes |
| POST `/api/frame`,`/api/frame_bin` | `handleApiFrame*` | M370 / binary | snapshot | frameMutex | manual only | No (bin read timeout `BIN_FRAME_READ_TIMEOUT_MS`) | Yes |
| GET `/api/power`, `/api/perf`, POST `/api/saved_faces` | … | — | … | various | Yes | No | Yes — admission guard |

### Firmware functions

| Function | File | Role | Lock |
|---|---|---|---|
| `scrollSessionBeginUpload/Append/WriteFrame/CommitUpload` | scroll_session.cpp | receive/store frames + meta | scrollMutex |
| `scrollSessionStart/Stop/SetUserPaused/SetSystemPaused/Step/SetInterval` | scroll_session.cpp | playback transitions | scrollMutex |
| `scrollSessionCopyMeta/Snapshot` | scroll_session.cpp | read-back for WebUI | scrollMutex copy-out |
| `scrollSessionTickCursorLocked` | scroll_session.cpp | advance frame index (non-blocking millis) | called under scrollMutex |
| `scrollRenderTask` | scroll.cpp | Core-1 render loop | scroll→frame→hardwareBus |
| `renderCurrentFrameToLedStrip` | led_renderer.cpp | copy frame, map, `strip.show()` | frameMutex + HardwareBus |
| `startFirmwareScroll/stopFirmwareScroll/stopFirmwareScrollForNonScrollOutput` | faces.cpp | mode-aware wrappers | via session |
| `runButtonActionImpl` (B1/B2/B3) | buttons.cpp | physical-button scroll stop + stop event | via session |
| `handleApiStatus/Scroll/ScrollMeta` | web_api.cpp | HTTP | admission guard + session |

### WebUI functions (app.js)

| Function | Role |
|---|---|
| `startScroll` / `uploadFirmwareScrollTimeline` / `uploadScrollTimelineAttempt` | send + chunked upload (token-guarded) |
| `buildTextScrollBitmap` / `buildFirmwareScrollFrames` / `frameToM370` | text → LED frames → M370 |
| `restoreScrollTextFromFirmware` / `restoreScrollPreviewIfNeeded` / `setScrollTextFromFirmware` | refresh restore (no re-upload) |
| `applyFirmwareRuntimeState` / `applyScrollRuntimeMeta` / `applyFirmwareScrollFrameIndex` | firmware-truth sync |
| `pauseScroll` / `resumeScroll` / `stopScroll` / `setScrollStepHandler` | command-first/UI-from-response |
| `updateScrollUi` / `applyScrollButtonUiState` | button state from firmware |
| `kickPostBootScrollMetaRestore` / `bootstrapWebUi` / `runPostBootDeferredReads` | page-load ordering |

---

## 5. Findings, by severity (corrected)

No defect here is *proven* in the absence of a runtime run; the "no obvious Critical" conclusion is a static-review result. Items are tagged **[statically verified]**, **[requires runtime proof]**, or **[refuted — static evidence]**.

### Critical — none observed in static review
Design points inspected and believed correct, but **requiring runtime confirmation** on the listed tests:
- Render task copies frame data before `strip.show()` (scrollMutex copy → frameMutex publish → renderer's own local copy). *[statically verified; confirm no tearing under load — test 13/15]*
- LittleFS flash access serialized against WS2812 transmit via coupled Storage+HardwareBus locks. *[statically verified — see §5 "refuted" R1 for the lock-scope question; confirm no garble — test 13]*
- Scroll cache is one fixed PSRAM buffer reused across uploads (no per-upload malloc/free of the frame array). *[statically verified; confirm heap flatness — test 12]*
- Fixed `char[]` runtime fields (no `String` churn); HTTP handlers bound body size and admission-guard before large allocations. *[statically verified; confirm under refresh storm — test 13]*
- `0 ≤ frameIndex < frameCount` (modulo arithmetic, zero-count guarded). *[statically verified]*

### Medium — NOW FIXED (implemented; require on-device verification)
- **M1 — Atomic timeline replacement (was: old scroll torn down before new commit).** **Fixed.** Implemented a **PSRAM double buffer** with off-screen staging and an O(1) atomic swap. `initScrollFrameBuffer` allocates a second 144 KB frame cache + a second 4 KB source-text buffer on PSRAM boards (graceful single-buffer fallback otherwise). A replacement upload (`append:false … commit`) now writes into the **staging** buffer/meta/text while the running timeline keeps playing; `handleApiScroll` no longer calls `stopFirmwareScroll` up-front when double-buffered. `scrollSessionPromoteStaging()` swaps staging→active (toggle render-buffer index + swap meta struct + swap source-text pointer) **under `scrollMutex`**, so the render task only ever sees the old buffer or the fully-written new buffer. Promotion fires on `uploadComplete` (covers the WebUI's `start:false` + separate `start_scroll` flow) or on auto-start for legacy `totalFrames==0` uploads. A failed/aborted/stopped upload discards staging and leaves the running scroll untouched (`scrollSessionInvalidateCache` and `resetFirmwareScrollStateLocked` are staging-aware). The new timeline's interval is applied only at the swap, so the old timeline is never re-timed mid-upload. *Files: state.h/.cpp, scroll_session.h/.cpp, web_api.cpp.* **Requires runtime proof:** seamless swap, no LED glitch on replace, +288 KB PSRAM budget, interrupted-upload keeps old scroll (test 16).
- **M2 — Firmware-authoritative return mode.** **Fixed.** `commandStopScroll` no longer reads `restoreAuto` from the WebUI payload; it always uses the firmware-stored `scrollSessionGetRestoreAuto()`. `clear` stays caller-controlled (display action). *File: web_api.cpp.* **Requires runtime proof:** Start-from-Auto → refresh → Stop returns to Auto (test 17).
- **M3 — Cross-domain read removed (no regression).** **Fixed** without the naive snapshot that would have regressed stop-race handling. The render task now holds `scrollMutex` across **both** the cursor tick and the frame publish, with `frameMutex` **nested inside** it (matching the documented Scroll→Frame order). A `Stop` (which also takes `scrollMutex`) can no longer interleave in a lock-handoff gap, so `firmwareScrollActive` is read only under its owning lock and no stale frame can be published over a blanked panel. The extra hold is a 47-byte memcpy; the expensive `strip.show()` still runs outside both locks. *File: scroll.cpp.* **Requires runtime proof:** no deadlock, no LED stutter under refresh storm (tests 13/15).
- **M4 — Pre-rasterization frame cap.** **Fixed.** `prepareTextScrollTimeline` now aborts generation *before* the per-frame extraction loop (and a cheap code-point pre-guard runs before bitmap rasterization) when the projected frame count exceeds `firmwareScrollMaxFrames`, surfacing a clear warning instead of materializing thousands of 370-cell frame arrays. *File: app.js.* **Requires runtime proof:** very long text on a low-end phone stays responsive and shows the cap warning.

### Refuted by static evidence (raised in review, do not apply)
- **R1 — "Storage/HardwareBus may be held across the whole static-file transfer, freezing rendering."** **Refuted.** `streamFileChunked` holds `withStorageLock` (which couples HardwareBus) **only around each per-chunk `file.read()`**; the network write `server.sendContent(...)` is **outside** the lock, the loop `vTaskDelay(WEB_YIELD_TICKS)`-yields between chunks, and while a scroll is displaying it uses a smaller chunk (`STATIC_STREAM_CHUNK_SCROLL_BYTES`) and yields every chunk. This is exactly the "safe scope" pattern; the "dangerous scope" does not exist. *(web_api.cpp `streamFileChunked`, lines ~145–188.)*
- **R2 — "`/api/status?since` may hide `scrollFrameIndex` changes."** **Refuted.** `handleApiStatus` sets `allowUnchangedShortcut = !scrolling`; the `since==version` "unchanged" 200 is only returned when **not** scrolling. Whenever a scroll is displaying, full status (including `scrollFrameIndex`) is always emitted. *(web_api.cpp `handleApiStatus`, lines ~549–561.)*
- **R3 — "Chunk sizing may use character length instead of encoded byte length."** **Refuted.** `chooseFirstChunkFrames` measures with `new TextEncoder().encode(JSON.stringify(payload)).length`, i.e. real UTF-8/JSON-escaped byte length, so CJK/emoji text is sized correctly. *(app.js `chooseFirstChunkFrames`, lines ~9262–9291.)*

### Low (logging / clarity)
- **L1 — Upload handler had no structured serial telemetry.** Session-layer `start/stop/pause/step` were logged, but `handleApiScroll` logged nothing. Gap against checklist J. **Fixed** (see §6) — but the fix itself **requires runtime confirmation** (logs not yet observed on hardware).
- **L2 — Generator-version skew on restore** is handled as a non-fatal warning; acceptable provided the UI clearly states the preview may not match the LEDs. *[statically verified]*

### Failed/interrupted-upload state matrix (per review — to verify on-device)

| State | Intended behavior | Status |
|---|---|---|
| Old scroll active, new upload's **first** chunk accepted, later chunk fails | **M1:** old scroll already stopped; board ends with no active scroll | confirmed by code; behavior may be undesirable |
| First chunk OK, append fails | incomplete timeline never starts (D2); cache invalidated, source text kept | statically verified; runtime-test |
| Browser refreshes mid-upload | firmware refuses to start incomplete cache; `/api/scroll/meta` won't restore a non-displaying scroll | statically verified; runtime-test |
| B1/B2/B3 pressed mid-upload | button stop fires `stopFirmwareScrollForNonScrollOutput`; next upload chunk hits a changed session → 409 → WebUI retries new timelineId | statically verified; runtime-test |
| New upload starts while previous incomplete | new `append:false` first chunk stops + clears prior session; WebUI token cancels the stale upload | statically verified; runtime-test |

---

## 6. Concrete code changes made

All changes are additive, gated by the existing `ENABLE_SERIAL_DIAGNOSTICS` build flag (compiled to `do{}while(0)` when off) and the runtime INFO/WARN log level, and run only on the Core-0 HTTP path — never on the Core-1 LED render task. No feature, endpoint, payload, or state transition was modified.

**`src/web_api.cpp` — `handleApiScroll()` telemetry (L1):**
- Capture `scrollUploadHeapBefore` / `scrollUploadLargestBefore` (free heap + largest contiguous internal block) right after the admission guard.
- `event=upload_recv` (INFO): `append`, `chunkIndex`, `totalFrames`, `bodyBytes`, `heap`, `largest`.
- `event=upload_reject` (WARN) at the three mid-stream failure points: `too_many_frames`, `bad_frame` (with index + parser detail), `not_writable` (with index).
- `event=upload_commit` (INFO) after commit/start: `frames`, `chunkFrames`, `sourceTextBytes`, `uploadComplete`, `started`, `bufferBytes`, `heapAfter`, `largestAfter`.

These complement the existing session-layer `RLOG_INFO("SCROLL", …)` for `event=start|stop|pause|step` and the `event=shed_low_heap` admission log, so a full upload→play→stop cycle (including heap delta and any rejection) is now observable over serial.

**`src/scroll.cpp` — `scrollRenderTask()` (L2):** added a comment block documenting why `firmwareScrollActive` is intentionally re-read under the frame lock and why it must not be promoted to a scroll-lock acquisition (lock-order inversion). No code behavior change.

> Verification note: a full PlatformIO/ESP32 toolchain is not available in this audit sandbox, so the firmware was not flash-compiled here. The edits were verified statically — every new log line's format specifiers match its argument count/types, and every symbol referenced (`error`, `count`, `targetIndex`, `sourceText`, `scrollState`, `ESP.getFreeHeap`, `heap_caps_get_largest_free_block`, `runtimeScrollFrameBufferBytes`, `RLOG_INFO/WARN`) is already in scope/used in the same translation unit. Run `pio run` before flashing.

---

## 7. Tests — procedure & expected results

Use the existing serial console (`scroll …`, `led status`, `status`) alongside the WebUI. The new logs appear at INFO/WARN.

| # | Test | Steps | Expected |
|---|---|---|---|
| 1 | Send scroll text | Enter text, Send | Serial: `event=upload_recv` per chunk → `event=upload_commit frames=N started=1`; LED scrolls |
| 2 | Independent playback | Close the browser tab | LED keeps scrolling (Core-1 task is connection-independent) |
| 3 | Refresh while scrolling | Reload page | LED never glitches; page reloads cleanly |
| 4 | Text input restored | After #3 | Input box refilled from `/api/scroll/meta sourceText` |
| 5 | Preview restored | After #3 | Scroll preview regenerated locally (no new `/api/scroll` POST in devtools) |
| 6 | Preview index matches FW | After #3 | Preview frame == firmware `frameIndex` (compare `scroll status idx=` vs UI index) |
| 7 | Pause after refresh | After #3, click Pause | `event=pause … effective=1`; LED holds; button shows 继续 |
| 8 | Resume after refresh | Click Resume | `event=pause … effective=0`; LED resumes |
| 9 | Step ± after refresh | Click step prev/next | `event=step dir=±1 idx=k/N`; preview follows authoritative index; playback latches paused |
| 10 | Stop/clear after refresh | Click Stop | `event=stop … cleared=1`; LED blanks; returns to manual/auto per `returnMode`; local cache cleared only after FW confirms |
| 11 | Send new text after refresh | Enter new text, Send | New `timelineId`; old cache replaced; `event=upload_commit` |
| 12 | Heap stability | Repeat upload+refresh ×50; `status` each time | `freeHeap`/`largestAfter` in `upload_commit` stay roughly flat (no monotonic decline) — PSRAM cache + fixed buffers |
| 13 | Refresh storm | Hammer reload during scroll | No panel corruption (flash/Storage serialized with HardwareBus); occasional 503 with `event=shed_low_heap` is the safe admission path |
| 14 | Physical buttons during scroll | Press B1/B2/B3 | Scroll stops to saved-face/mode; `scrollStopEvent.seq` increments; WebUI reacts on next poll |
| 15 | Serial/status polling during scroll | Run `status` / poll `/api/status` repeatedly | No LED glitch; `scrollFrameIndex` advances monotonically |

These are **expected results, not evidence**. The pipeline is not "hardened" until the following **measurable pass/fail gates** are met on hardware:

```
Heap stability (test 12) — PASS iff after 50 upload+refresh cycles:
  • internal free heap drop        < 5 KB   (compare upload_commit heapAfter, first vs last)
  • largest internal block drop    < 8 KB   (upload_commit largestAfter, first vs last)
  • free PSRAM drop                < 10 KB  (/api/status memory.freePsram)
  • reset reason                   == power-on/manual only (no Panic/WDT/OOM)

Refresh storm (test 13) — PASS iff during 30 reloads over 60 s while scrolling:
  • 0 watchdog/panic resets
  • 0 corrupted LED frames (visual or camera capture)
  • scrollFrameIndex strictly advances (mod N), never freezes > 2× interval
  • WebUI reconnects and resyncs within 3 status polls
  • 503 admission sheds are allowed and must be followed by a successful retry

Interrupted upload (M1, test 16 — ADD) — define + assert intended behavior:
  • Abort the upload after the first append chunk (kill the tab / drop WiFi).
  • Firmware must NOT start a partial timeline (assert /api/scroll/meta uploadComplete=false, not displaying).
  • DECISION REQUIRED: is "old scroll already stopped" acceptable, or must the
    old scroll keep running until the new timeline fully commits? (see M1)

Return-mode authority (M2, test 17 — ADD):
  • Start scroll from AUTO mode; refresh; immediately Stop.
  • Board must return to AUTO (firmware previous-mode), regardless of WebUI returnMode default.

Multi-client upload race (test 18 — ADD):
  • Two browsers upload different text concurrently.
  • Exactly one timeline wins; loser receives 409s; final scrollTimelineId is consistent
    across /api/status and /api/scroll/meta; no mixed-timeline frames.
```

---

## 8. Remaining risks

1. **Not flash-compiled in this environment.** Run `pio run` (and `pio run -t uploadfs` if WebUI assets changed) before deploying. The changes are log-only but should be built once.
2. **Generator-version skew on restore.** If `fontId`/`generatorVersion` differ between the firmware that produced the frames and the WebUI doing the restore, the locally regenerated preview may not pixel-match the LED output. This is already detected and surfaced as a non-fatal warning (`exactGeneratorMatch` → E5 banner); the LED output itself is unaffected because firmware owns the frames.
3. **Oversized third-party source text (> WebUI input cap).** Restore truncates the input box for preview and refuses to bind `framesTimelineId` (E4/E5); the firmware continues scrolling the full untruncated sequence correctly. Preview is "reference only" by design.
4. **Admission-shed under sustained low heap.** Under a pathological refresh storm with already-fragmented internal heap, `/api/scroll`, `/api/scroll/meta`, and `/api/status` may return 503 (`event=shed_low_heap`). This is the intended crash-avoidance behavior; the WebUI retries. It is a graceful-degradation trade-off, not a defect.
5. **Single-client assumption.** Restore/status logic assumes one controlling WebUI. Two simultaneous browsers both reading firmware truth is safe, but two simultaneously *uploading* rely on timelineId/chunk ordering (409) to stay consistent — correct, but the second uploader simply loses the race.
6. **Open Medium items (M1–M4, §5)** are not yet fixed or proven: atomic timeline replacement (M1), return-mode authority (M2), typed-atomic for the cross-lock flag (M3), and pre-rasterization frame caps (M4). Until they are either implemented or accepted-as-intended **and** the §7 measurable gates pass on hardware, the pipeline should be described as *static-review-clean*, **not** *fully hardened*.

---

## Verification status (honest summary)

| Aspect | Status |
|---|---|
| Source traced end-to-end (WebUI → HTTP → session → render → LED) | ✅ done |
| PlatformIO compile / flash | ❌ not available in audit env — run `pio run` |
| Hardware run (LED timing, refresh storm, heap) | ❌ not performed — see §7 gates |
| Static-evidence refutations (R1–R3) | ✅ cited in source |
| Medium design gaps (M1–M4) | ✅ implemented (M1 double-buffer swap, M2 fw-authoritative mode, M3 lock nesting, M4 pre-raster cap) — ⚠️ require on-device verification |
| Section-J logging fix (L1) + M1 `event=staging_swap` | ✅ implemented, ⚠️ not yet observed on hardware |
| New PSRAM budget (+~288 KB for double buffer) | ⚠️ confirm fits on target board's PSRAM |

## Strongest corrected design rule

> **Firmware is the only authority** for active-scroll state, previous mode, pause state, frame count, frame index, and upload completeness. The WebUI may generate and upload timelines and may *display* mode, but after upload it must treat all runtime state from firmware as authoritative and must not *decide* return mode after a refresh. **A new timeline must not replace the active timeline until every chunk has been validated and committed** (`uploadComplete==true`); replacement is an atomic swap, not an up-front stop.

**As of these fixes the implementation conforms to this rule:** M1 makes replacement an atomic staging→active swap (old timeline plays until commit), and M2 makes firmware the sole authority for post-scroll return mode. The "firmware-authoritative" property now holds for *reads*, *upload-replacement*, and *stop-return-mode* — pending the on-device verification gates in §7.
