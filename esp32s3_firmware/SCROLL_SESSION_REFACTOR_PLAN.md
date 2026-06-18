# Scroll Session Refactor Plan

> Status: IMPLEMENTED (phases 1A-4) + audit fixes applied. See "Implementation status" below.
> Owner: TBD | Date: 2026-06-18
> Scope: Extract the text-scroll state machine into a dedicated module on both sides -- firmware `scroll_session.{h,cpp}` (split out of `faces.cpp`) and a browser scroll-machine module (inline in `data/app.js`). Behavior-preserving refactor that also makes the later preview-vs-LED anti-drift fix a one-line change.
> Non-goals: No new user-facing features. No protocol/wire changes to `/api/scroll`, `/api/scroll/meta`, `/api/command`, or `/api/status`. No bundler/ES-module adoption.
>
> Note: this document is intentionally ASCII-only (no Unicode arrows, section signs, set symbols, or emoji) so it renders identically in every editor and can serve as the review contract.

---

## 0. Implementation status (reconciled 2026-06-18)

This document was originally written as a forward-looking draft ("no code moved yet").
The work is now implemented in the tree and this section reconciles the plan with the
shipped code. See `SCROLL_SESSION_REFACTOR_AUDIT.md` for the full audit.

Implemented:
- Firmware phases 1A + 1B + 1C + 2 in `src/scroll_session.{h,cpp}`; `faces.cpp`, `faces.h`,
  `scroll.cpp`, `scroll.h`, `buttons.cpp`, `button_animations.cpp`, `web_api.cpp` rewired.
- Browser phases 3 + 4: the `scrollMachine` IIFE in `data/app.js` (epoch + per-domain
  tokens, composable `pauseReasons`, FW_SYNC-authoritative cursor, `cache.identityBound`).
- Phase 5 (delete dead `scroll{}` fields/globals) is NOT done yet and remains future work.

Signature deltas (the shipped signatures are authoritative; the sketches in sec 4.1/13 are
historical):
- `scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode) -> ScrollStartResult`
  (not the `ScrollStartContext` struct sketch).
- `scrollSessionStop(bool restoreAuto, bool clearDisplay) -> ScrollStopResult`.
- `scrollSessionCommitUpload(const ScrollUploadTxn&, uint16_t count, bool hasExplicitTiming, uint16_t intervalMs) -> ScrollUploadResult`.
- `scrollSessionBeginAppend()` exists in addition to `scrollSessionBeginUpload(meta)`.
- New: `scrollSessionStep(int8_t direction, uint8_t* outFrameBits) -> bool` (manual step;
  not in the original sec 13.1 "what moves" table). It latches an effective pause so the
  Core-1 render task holds on the stepped frame.

Audit fixes applied on top of the refactor (see audit doc, "Required Corrections"):
1. Anti-drift: the browser local `advanceScroll` timer is now a display-only tween
   (`scroll.displayIndex`) that never writes the canonical `scroll.frameIndex` while
   `device.hasSession`; FW_SYNC is the sole canonical-cursor writer (sec 7 now true).
2. `scrollSessionStep` latches `firmwareScroll*Paused` so a step holds its frame; the
   WebUI step handler mirrors this (PAUSE_USER + stop local timer).
4. FW_SYNC pause mirroring is routed through `PAUSE_USER/RESUME_USER/PAUSE_SYSTEM/RESUME_SYSTEM`
   dispatch events (single mutation path; the `*_SYSTEM` events are no longer dead).
5. The browser reducer now enforces an `ALLOWED_FROM` source-phase guard table (sec 5.2
   is now enforced, not just documented).
6. `scrollSessionMarkStoppedByButton` is documented as intentionally lockless (Core-0-only
   stop-event fields; locking it would reintroduce a String-under-lock violation).

Note: all `app.js:NNNN` / `faces.cpp:NNNN` line references below point at the PRE-refactor
baseline and are retained for historical context only; they no longer match current files.

---

## 1. Why

The scroll subsystem is the highest-risk area in the codebase (see `ARCHITECTURE_REPORT.md` sec 13). Its state is implicit:

- Browser: `scroll{}` carries ~30 fields (`data/app.js:3565`) plus module globals (`pendingScrollMeta`, `scrollMetaFetchInFlight`, `lastFwScroll*`, `data/app.js:3609`). "What state are we in" is inferred by reading combinations of booleans, and the same combinations are re-derived in `startScroll`, `pauseScroll`, `resumeScroll`, `stopScroll`, `togglePauseScroll`, `restoreScrollTextFromFirmware`, `restoreScrollPreviewIfNeeded`, and `applyFirmwareRuntimeState`.
- Firmware: the scroll FSM is interleaved with mode/auto-playback/face logic in `faces.cpp` (`startFirmwareScroll:352`, `stopFirmwareScroll:331`, `setFirmwareScrollPauseFlag:290`, `recomputeEffectivePauseLocked:281`, `resetFirmwareScrollStateLocked`, deferred-restore machinery), while `/api/scroll` mutates scroll state directly in `web_api.cpp` (`:817`, `:936`), `set_scroll_interval` writes `scrollIntervalMs`/`lastScrollFrameMs` (`web_api.cpp:1120`), buttons write `scrollStopEvent*` (`buttons.cpp:67`), `get/setRestoreAutoAfterScroll` live in `scroll.cpp`, and the Core-1 render task mutates the playback cursor (`scroll.cpp:42`).

Goal: one explicit state machine per side, with a single transition path, so pause/step/restore/upload races are reasoned about in one place.

### 1.1 Goals
1. Single transition function per side; explicit, named states.
2. One ownership boundary for firmware scroll-state writes (control plane + interval + stop-event + restore-auto + upload plane + render-plane cursor).
3. Preserve the composable pause semantics (user AND/OR system paused).
4. Preserve async-race protection via per-domain operation tokens plus cross-domain cancellation.
5. Make FW_SYNC-authoritative preview index a reducer policy (kills drift; see sec 7).
6. Invert the scroll -> face dependency so there is no circular ownership.

### 1.2 Non-goals
- No change to the wire protocol or JSON shapes.
- No new file served by the ESP unless it earns its keep (default: inline, see sec 6).
- No behavior change in phases 1-3 (strangler pattern). The one intentional behavior change (FW_SYNC authority over the preview cursor) lands in phase 4.

---

## 2. Reviewer-driven design corrections (baked in)

### 2.1 Round-1 corrections

| # | Correction | Resolution |
|---|---|---|
| P1 | Pause states are composable, not exclusive | `ACTIVE` state + `pauseReasons: Set<"user"\|"system">`; `isPlaying = ACTIVE && pauseReasons empty` (sec 5.1) |
| P1 | Firmware boundary must include upload/cache mutations | Upload transaction API in `scroll_session` (sec 4.1) |
| P1 | Core-1 render also mutates scroll state | Render-plane `scrollSessionTickCursorLocked()` under the lock the task already holds (sec 4.2) |
| P1 | Single `busy` flag hides concurrent flows | Per-domain generation tokens; `busy` is UI-affordance only (sec 5.3) |
| P2 | No bundler / file:// / single-threaded server | Scroll machine ships inline in `app.js` as an IIFE; no ES modules (sec 6) |
| P2 | Circular ownership with default-face restore | `scrollSessionStop()` returns a result struct; `faces.cpp` performs face restore (sec 4.3) |

### 2.2 Round-2 corrections

| # | Correction | Resolution |
|---|---|---|
| P1 | `UPLOAD_DONE -> ACTIVE` marks playback active before `start_scroll` is confirmed | Split into `UPLOAD_COMMIT_DONE` (frames committed, not playing) -> `STARTING`, then `START_CONFIRMED` -> `ACTIVE` (sec 5.2) |
| P1 | Upload must keep partial frames invisible | Explicit invariant: count/`framesReceived`/`uploadComplete` never expose a chunk until fully written; `scrollSessionWriteFrame` rejects writes into visible indexes unless stopped/invalidated first (sec 4.1) |
| P1 | `firmwareBacked` derived from the UI enum is too coarse | Replace with explicit `device.hasSession` and `cache.identityBound` (sec 5.1) |
| P2 | Transition table too restrictive for replacement flows | `GENERATE`/`RESTORE_BEGIN` allowed from any non-busy state with explicit cleanup effects (sec 5.2) |
| P2 | One generic snapshot risks huge/stack source-text copies | Two APIs: small-scalar `scrollSessionSnapshot()` for `/api/status`; `scrollSessionCopyMeta(textBuf, cap)` for `/api/scroll/meta` (sec 4.1) |
| P2 | Phase 1 bundles three risky moves | Split into 1A start/stop/pause/step, 1B upload/cache txn, 1C render cursor tick (sec 8) |

### 2.3 Round-3 corrections

| # | Correction | Resolution |
|---|---|---|
| P1 | Ownership rule needs more APIs: `set_scroll_interval`, `scrollStopEvent*`, `restoreAutoAfterScroll` also write scroll fields | Add `scrollSessionSetInterval`, `scrollSessionMarkStoppedByButton`, `scrollSessionGet/SetRestoreAuto` to the public surface (sec 4.1) |
| P1 | `scrollSessionStart(uint16_t)` under-specified: start captures auto-mode restore intent and flips mode/playback | Context-in / result-out: `scrollSessionStart(ScrollStartContext)` -> `ScrollStartResult`; `faces.cpp` owns mode/playback String writes (sec 4.1, 4.5) |
| P1 | First-chunk upload must preserve preflight: validate-then-clear, or a malformed first chunk erases a working timeline | Frame validation stays in the transport layer and completes before `scrollSessionBeginUpload` clears anything (sec 4.1, 4.4) |
| P1 | "Transaction" lifetime unclear | `ScrollUploadTxn` is a stack-local per-request context derived from a locked meta snapshot; never persisted across HTTP requests (sec 4.4) |
| P1 | STOP/GENERATE/RESTORE must cancel other async domains, not just their own token | Cross-domain cancellation via a monotonic `epoch`; replacement events bump it and stale replies from any domain are dropped (sec 5.3) |
| P1 | `cache.identityBound` must include timeline binding, not just generator + frame count | Formula includes `framesTimelineId === fw.scrollTimelineId` (the `localTimelineMatchesMeta` check at `app.js:8897`) (sec 5.1) |
| P2 | "Reference only" is a user-facing behavior; conflicts with "no behavior change" if introduced early | The warning already exists today; only its rewiring through `cache.identityBound` lands in phase 4. Clarified in sec 5.1 / sec 8 |
| P2 | Plan file had mojibake / broken arrows | Rewritten ASCII-only (this revision) |

---

## 3. Target architecture

```
Firmware (Core 0 control + Core 1 render)
  web_api.cpp  --(transport: parse + validate)-->  scroll_session.cpp
  buttons.cpp  -------------------------------->   (owns ALL RuntimeState scroll-field writes)
  faces.cpp    --(start/stop/pause/step)------->         |
       ^  (start/stop result: mode + restore intent) ----+
  scroll.cpp (Core 1) --(tick cursor, lock held)-->  scrollSessionTickCursorLocked()

Browser (data/app.js)
  UI handlers ----> scrollMachine.dispatch(event, payload, token)
  pollers/restore-> dispatch(FW_SYNC | UPLOAD_COMMIT_DONE | RESTORE_DONE, ..., token)
  scrollMachine ---> renderMatrices / updateScrollUi (read-only consumers)
```

Dependency edges are one-directional: `faces.cpp -> scroll_session` (never back); `web_api.cpp -> scroll_session`; `buttons.cpp -> scroll_session`; `scroll.cpp -> scroll_session` (render-plane only).

---

## 4. Firmware: `scroll_session.{h,cpp}`

`RuntimeState` scroll fields stay in `state.h` (shared with the render task), but only `scroll_session.cpp` may write them. All control-plane functions take `withScrollLock` internally; the render-plane function is the documented exception (called with the lock already held).

### 4.1 Public surface

```cpp
// --- control plane (Core 0: HTTP handlers, buttons, faces) ---
ScrollStartResult   scrollSessionStart(const ScrollStartContext& ctx);  // intent in, result out; no face/mode/String writes here
ScrollStopResult    scrollSessionStop(bool restoreAuto, bool clearDisplay);
bool                scrollSessionSetUserPaused(bool paused);
bool                scrollSessionSetSystemPaused(bool paused);          // battery overlay
bool                scrollSessionStep(int8_t direction);
void                scrollSessionSetInterval(uint16_t intervalMs);      // set_scroll_interval: writes scrollIntervalMs + lastScrollFrameMs (was web_api.cpp:1120)
void                scrollSessionMarkStoppedByButton(const char* button, const char* source); // owns scrollStopEvent* (was buttons.cpp:67)
bool                scrollSessionGetRestoreAuto();                      // was get/setRestoreAutoAfterScroll in scroll.cpp
void                scrollSessionSetRestoreAuto(bool value);

// --- read plane: two distinct contracts (do NOT merge) ---
ScrollSessionSnapshot scrollSessionSnapshot();                         // small scalars only; for /api/status (tear-free)
bool                scrollSessionCopyMeta(ScrollMetaOut&, char* textBuf, size_t cap); // timeline meta + optional source-text copy; for /api/scroll/meta

// --- upload plane (Core 0: /api/scroll) ---
ScrollUploadTxn     scrollSessionBeginUpload(const ScrollUploadMeta& meta); // first chunk; clears+sets meta under lock AFTER caller preflight
bool                scrollSessionWriteFrame(ScrollUploadTxn&, uint16_t index, const uint8_t* packedBits);
bool                scrollSessionAppendChunk(ScrollUploadTxn&, uint16_t chunkIndex /*, ... */);
ScrollUploadResult  scrollSessionCommitUpload(ScrollUploadTxn&);       // publishes count/framesReceived/uploadComplete under lock
void                scrollSessionInvalidateCache();                    // EH-A: drop frames, keep sourceText
void                scrollSessionClearTimeline();                      // full clear incl. sourceText

// --- render plane (Core 1: scrollRenderTask, lock already held) ---
bool                scrollSessionTickCursorLocked(uint32_t now, uint8_t* outFrameBits);
```

Types:

```cpp
struct ScrollStartContext { uint16_t intervalMs; bool callerIsAutoMode; };
struct ScrollStartResult  { bool started; bool engagedRestoreAuto; };  // caller (faces.cpp) sets mode/playback Strings from this
struct ScrollStopResult   { bool stopped; bool cleared; bool shouldRestoreDefault; bool restoreAuto; };
struct ScrollUploadResult { uint16_t frameCount; bool uploadComplete; char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1]; };
```

Upload performance contract preserved: frames are written into the PSRAM buffer outside the lock (`scrollSessionWriteFrame` writes the buffer directly); only counts + meta are committed under the lock in `scrollSessionBeginUpload`/`scrollSessionCommitUpload`. This is exactly today's shape (`web_api.cpp:817`, `:936`), just behind a named boundary instead of inlined `clearScrollTimelineMetaLocked()` etc.

Ownership completeness: with the round-3 additions, every current direct writer of a scroll field routes through `scroll_session`: `/api/scroll` (upload plane), `set_scroll_interval` (`scrollSessionSetInterval`), button stop events (`scrollSessionMarkStoppedByButton`), restore-auto (`scrollSessionGet/SetRestoreAuto`), and the Core-1 cursor (`scrollSessionTickCursorLocked`). The "only scroll_session writes scroll fields" invariant is then actually true.

### 4.2 Render-plane cursor (the Core-1 exception)

`scrollRenderTask` (`scroll.cpp`) keeps its existing `withScrollLock` block but calls one function instead of inlining the advance:

```cpp
withScrollLock([&]{
    dueFrame = scrollSessionTickCursorLocked(millis(), nextFrame);  // advances scrollFrameIndex, returns "new frame?"
});
```

Invariant statement that is true on day one:
> All scroll-state mutation goes through `scroll_session` functions. Control-plane functions acquire `scrollLock`; the render-plane `...Locked` function is invoked by the render task with `scrollLock` already held. No other code writes `RuntimeState` scroll fields.

### 4.3 Dependency inversion for default-face restore

Today `stopFirmwareScroll(clearDisplay=true)` schedules the default-face restore and calls `setMode` (`faces.cpp`). To avoid `scroll_session` depending back on face selection, the session reports intent and `faces.cpp` acts:

```cpp
// in faces.cpp
ScrollStopResult r = scrollSessionStop(restoreAuto, clearDisplay);
if (r.cleared && r.shouldRestoreDefault)
    scheduleStartupDefaultFaceRestoreAfterBlank(r.restoreAuto);
else if (r.restoreAuto)
    setMode("auto", false);
```

`scroll_session.cpp` includes nothing from `faces.h`. The deferred-restore machinery and `setMode` stay in `faces.cpp`.

### 4.4 Upload transaction: preflight and lifetime

Two rules that preserve today's behavior:

1. Validate-then-clear. The transport layer (`web_api.cpp`) keeps its first-chunk preflight: every frame of the first chunk is decoded/validated before any state is touched, exactly as today (`web_api.cpp:782` preflight, then `stopFirmwareScroll(false)` and clear at `:815`). `scrollSessionBeginUpload` is only called after that preflight succeeds, so a malformed first chunk can never erase a working timeline. `scrollSessionBeginUpload` is the commit point of "we are now replacing the cache," not the validation point.
2. Transaction lifetime is request-local. `ScrollUploadTxn` is a stack/local context for one HTTP request, constructed from a locked snapshot of meta (`nextChunkIndex`, `framesReceived`, `baseIndex`, `timelineId`). It is not persistent state held across requests -- chunked uploads are separate HTTP requests, and the durable per-timeline state lives in `ScrollTimelineMeta` under the lock. The txn just carries the validated, in-request working values between `Begin/Write/Append/Commit`.

Partial-frames-invisible invariant (mandatory):
- `scrollFrameCount`, `framesReceived`, and `uploadComplete` MUST NOT advance to expose any frame in a chunk/transaction until every frame of that chunk is fully written. Publication happens only in `scrollSessionCommitUpload`, atomically under the lock.
- `scrollSessionWriteFrame` MUST reject (return false) a write into a frame index currently visible to playback (within `[0, scrollFrameCount)`) unless playback has first been stopped or the cache invalidated. Appends beyond the visible range are allowed; the first-chunk path clears state (post-preflight) before writing.

### 4.5 scrollSessionStart context/result (no face dependency, no String-under-lock)

`startFirmwareScroll` today captures auto-mode restore intent and flips `mode`/`playback` Strings inside `withScrollLock` (`faces.cpp:352-378`). The refactor moves the decision out:

- Caller passes `ScrollStartContext{ intervalMs, callerIsAutoMode }`.
- `scrollSessionStart` sets only scroll scalars under the lock and returns `ScrollStartResult{ started, engagedRestoreAuto }`.
- `faces.cpp` (the caller) performs any `mode`/`playback` String assignment after the lock is released, from the result -- which also resolves the sec 4.6 String-under-lock issue by construction.

### 4.6 Side cleanup (free win)
While moving these functions, fix the documented lock-contract violation: the `String` assignments to `mode`/`playback` inside `withScrollLock` (`faces.cpp:362`, `:371`) and the `String` copy at `:304`. Snapshot scalars under the lock; do String work after release. With sec 4.5 this falls out naturally for the start path.

---

## 5. Browser: scroll machine (inline in `app.js`)

### 5.1 States and pause model

```
state in { IDLE, GENERATING, UPLOADING, STARTING, ACTIVE, STEPPING, RESTORING, STOPPING }
ACTIVE.pauseReasons : Set<"user" | "system">
isPlaying = (state === ACTIVE) && pauseReasons.size === 0
```

The coarse `firmwareBacked = state in {...}` derivation is rejected -- it conflates two independent facts and is wrong during `RESTORING` (firmware can already have a live session while the browser has not regenerated/bound frames). Two explicit derived subfields are tracked from FW_SYNC, independent of the UI `state`:

```
device.hasSession   : bool   // firmware reports a real scroll session (active OR paused OR cached+startable)
cache.identityBound : bool   // local scroll.frames are pixel-exact to the firmware timeline
                             //   = !restoredTextTruncated
                             //     && exactGeneratorMatch(meta)               // fontId + generatorVersion
                             //     && scroll.frames.length === fw.frameCount
                             //     && scroll.framesTimelineId === fw.scrollTimelineId   // timeline binding (app.js:8897)
```

- `device.hasSession` may be true while `state === RESTORING` or even `IDLE` (e.g. second browser / timeline-mismatch at `app.js:4845`); it drives "is there something on the device to control/restore."
- `cache.identityBound` drives "may we treat the local preview as pixel-exact." It must include the timeline-id binding, not just generator match + frame count, matching today's `localTimelineMatchesMeta` (`app.js:8897`). "Active local preview" and "firmware-backed exact identity" are separate concepts.
- "Reference only" preview labeling already exists in current code (`setScrollRestoreWarning`). This plan does not introduce that behavior; it only rewires the gate to `cache.identityBound`, which lands in phase 4 (the one intentional behavior change).

Pause model mirrors firmware `firmwareScrollUserPaused`/`firmwareScrollSystemPaused` and `recomputeEffectivePauseLocked` (`faces.cpp:281`): `PAUSE_USER`/`PAUSE_SYSTEM` add a reason, `RESUME_USER`/`RESUME_SYSTEM` delete one, and playback only resumes when the set empties. Exclusive `PAUSED_USER`/`PAUSED_SYSTEM` states are rejected -- they break "user paused, then battery overlay system-paused, then overlay ends."

### 5.2 Events and transition table

"Non-busy state" = any state where no `gen.*` operation is in flight for the relevant domain (`IDLE`, `ACTIVE`, plus `RESTORING`/`STOPPING` only where noted). Replacement flows (`GENERATE`, `RESTORE_BEGIN`) are allowed from any non-busy state and run an explicit cleanup-first effect, mirroring today's `startScroll()` terminate/reset and the timeline-mismatch restore trigger (`app.js:4845`).

| Event | From | To | Effect / notes |
|---|---|---|---|
| `GENERATE` | any non-busy (IDLE, ACTIVE) | GENERATING | cleanup first: bump epoch (cancel other domains), `terminateOtherActivities`, clear restore state, reset cache; then build frames |
| `UPLOAD_BEGIN` | GENERATING | UPLOADING | captures `gen.upload` |
| `UPLOAD_PROGRESS` | UPLOADING | UPLOADING | UI only; token-checked |
| `UPLOAD_COMMIT_DONE` | UPLOADING | STARTING | all chunks committed on device; not yet playing; token-checked |
| `START_CONFIRMED` | STARTING | ACTIVE | `/api/command start_scroll` returned ok; playback active; token-checked |
| `START_FAIL` | STARTING | IDLE | token-checked; cache may remain for retry |
| `UPLOAD_FAIL` | UPLOADING | IDLE | token-checked |
| `PAUSE_USER` | ACTIVE | ACTIVE | `pauseReasons.add("user")` |
| `RESUME_USER` | ACTIVE | ACTIVE | `pauseReasons.delete("user")` |
| `PAUSE_SYSTEM` | ACTIVE | ACTIVE | `pauseReasons.add("system")` |
| `RESUME_SYSTEM` | ACTIVE | ACTIVE | `pauseReasons.delete("system")` |
| `STEP` | ACTIVE | STEPPING | captures `gen.step` |
| `STEP_DONE` | STEPPING | ACTIVE | token-checked |
| `STOP` | any | STOPPING | bump epoch (cancel other domains); captures intent |
| `STOP_DONE` | STOPPING | IDLE | clears cache + restore state |
| `RESTORE_BEGIN` | any non-busy (IDLE, ACTIVE) | RESTORING | cleanup first if replacing; bump epoch; captures `gen.restore`; allowed when `device.hasSession` even if browser holds other state |
| `RESTORE_DONE` | RESTORING | ACTIVE / IDLE | token-checked; sets `cache.identityBound` only on full match (sec 5.1) |
| `FW_SYNC` | any | (same) | updates `device.hasSession`; authoritative cursor when `device.hasSession` (sec 7) |
| `TEXT_EDITED` | any | (same) | sets `restore.textEdited`; blocks auto-overwrite (C5) |

`UPLOAD_COMMIT_DONE` and `START_CONFIRMED` are deliberately separate: today the browser uploads all chunks, then issues `/api/command start_scroll`, then applies runtime state (`app.js:8405`). Going straight from upload to `ACTIVE` would mark playback active before the device confirms start. `STARTING` is the gap.

### 5.3 Operation tokens + cross-domain cancellation

`busy` becomes UI-affordance only (what controls to disable). State commits are gated two ways:

```js
machine.epoch = 0;                                   // monotonic; bumped by STOP / GENERATE / RESTORE_BEGIN
machine.gen   = { upload: 0, restore: 0, step: 0, statusPoll: 0 };

// async op capture:
const t = { epoch: machine.epoch, dom: ++machine.gen.upload };
... await apiPost("/api/scroll", ...) ...
dispatch("UPLOAD_COMMIT_DONE", data, t);
// reducer drops the event if t.epoch !== machine.epoch  (a newer STOP/GENERATE/RESTORE happened)
//                       or t.dom   !== machine.gen.upload (a newer op in the same domain happened)
```

- Per-domain token (`gen.*`) drops a stale reply from the same domain (e.g. an old upload chunk).
- Epoch drops a stale reply from a different domain: a late upload/start/meta completion can no longer call `applyFirmwareRuntimeState` and clobber a newer `STOP`/`GENERATE`/`RESTORE`. This is the cross-domain cancellation the flag soup lacked.
- `gen.upload` is today's `uploadGeneration` (`app.js:8338`), renamed; `gen.restore` guards the `/api/scroll/meta` + preview-regen pipeline (today races via `pendingScrollMeta` + `scrollMetaFetchInFlight`); `gen.step`/`gen.statusPoll` cover step and polls.

### 5.4 Field migration map (`scroll{}` -> machine)

| Group | Absorbs |
|---|---|
| `machine.state` + `pauseReasons` | `active`, `paused`, `userPaused`, `systemPaused` |
| `machine.device.hasSession` + `machine.cache.identityBound` | `firmwareBacked` (split; no longer one derived bool) |
| `machine.cache` | `frames`, `signature`, `dirty`, `timelineId`, `framesTimelineId`, `frameIndex`, `offset` |
| `machine.upload` | `uploading`, `uploadProgress/Label/Token`, `uploadGeneration`, all `*Busy` -> `busy` |
| `machine.restore` | `pendingScrollMeta`, `restoredSourceText`, `restoredFromFirmwareMeta`, `restoreWarning`, `restoredTextTruncated`, `textEdited`, `scrollMetaFetchInFlight`, `lastFwScroll*` |
| `machine.metrics` | `frameCounter`, `fpsStarted`, `measuredFps` |
| `machine.returnMode` | unchanged |

---

## 6. No-bundler integration

The WebUI is a single vanilla `<script src="app.js">` served gzip'd by a single-threaded ESP, and must still run from `file://` offline.

- Default: the scroll machine is an IIFE section inside `app.js` -- `const scrollMachine = (function(){ ... return { dispatch, snapshot, get state }; })();`. No `import`/`export`, no `type="module"`, no extra HTTP round-trip, no CSP change.
- If ever split into its own file, it would be a plain global-exposing `<script>` ordered before `app.js`, and `scripts/gzip_webui_assets.py` `GZIP_TARGETS` would need it added. Avoid unless it earns its keep.
- The name "scrollMachine.js" is aspirational; in practice it is the scroll-machine module within `app.js`.

---

## 7. FW_SYNC authority (the anti-drift policy)

Decision: FW_SYNC is the sole writer of the canonical playback cursor whenever `device.hasSession` is true. Baked into the reducer because it is the main architectural win and is the anti-drift fix. The gate is `device.hasSession` (a real firmware session), not the coarse UI `state` -- so it also holds during `RESTORING`.

- While `device.hasSession`: every FW_SYNC (poll or `/api/scroll/meta`) snaps `cache.frameIndex` to the firmware `scrollFrameIndex`.
- The local `advanceScroll` timer is demoted to a display-only tween that never writes `cache.frameIndex` and is discarded on each sync.
- Tween rendering is only pixel-trustworthy when `cache.identityBound`; otherwise the preview is labeled "reference only" and the canonical index still comes from firmware.
- While paused/stepping, FW_SYNC is likewise authoritative.

Today both firmware sync and the local timer write `scroll.frameIndex` (`app.js:4714` and `app.js:8729`), which is why drift is structurally possible. Result after this change: preview and LEDs cannot drift by construction, and the "make firmware the single clock" task is done -- it lives entirely in the FW_SYNC handler.

---

## 8. Phased migration (strangler; behavior-identical until phase 4)

Phase 0 -- Design sign-off. This document approved.

Phase 1 -- Firmware extraction, behavior-identical (three independent rollback boundaries).

- Phase 1A -- control plane. Move start/stop/pause/step + interval + stop-event + restore-auto into `scroll_session.cpp` behind the sec 4.1 control API; `scrollSessionStart` uses context/result (sec 4.5) and `scrollSessionStop` returns the result struct (sec 4.3); `faces.cpp` consumes both. Fix the sec 4.6 String-under-lock issue here. The `/api/scroll` upload writes, the `scrollSessionSnapshot` reader (Phase 2), and the Core-1 advance (Phase 1C) stay where they are for now. Exact code: section 13.
  - Checkpoint: `pio run` clean; on-device parity for pause(user)+overlay(system), step at boundaries, stop+restore-auto, set_scroll_interval, button stop-event.
- Phase 1B -- upload/cache plane. Move the `/api/scroll` direct writes (`web_api.cpp:817`, `:936`) behind the upload transaction API (sec 4.1/4.4), preserving transport-layer preflight (validate-then-clear), enforcing the partial-frames-invisible invariant and visible-index write rejection. Add `scrollSessionCopyMeta` and route `/api/scroll/meta` through it.
  - Checkpoint: `pio run -t buildfs` clean; start/append/409-retry parity; malformed first chunk does NOT erase an existing timeline; oversized upload -> 413 with sourceText preserved (EH-A).
- Phase 1C -- render cursor. Move the Core-1 advance (`scroll.cpp:42`) into `scrollSessionTickCursorLocked()`, called inside the render task's existing `withScrollLock`.
  - Checkpoint: timing parity (no WS2812 glitch under load); scroll playback smooth; reboot drops RAM cache.

Phase 2 -- Route reads through the snapshot.
- `/api/status` reads `scrollSessionSnapshot()` (small scalars). Per open item 3, also route `/api/command` replies (`buildCommandReply`, `web_api.cpp:1367`) through the snapshot so all three read paths converge. (`/api/scroll/meta` already moved to `scrollSessionCopyMeta` in 1B.)
  - Checkpoint: status/command JSON byte-identical to pre-refactor for representative states.

Phase 3 -- Browser machine as a compatibility wrapper.
- Introduce the inline `scrollMachine` with `scroll{}` still the backing store; `dispatch` delegates to existing functions. No behavior change.
  - Checkpoint: manual run of all 6.4 flows + reload-restore matrix shows no diff.

Phase 4 -- Move logic into the reducer, one event at a time.
- Order: PLAY (GENERATE/UPLOAD/START) -> PAUSE/RESUME (reason set) -> STOP -> STEP -> FW_SYNC/restore (hairiest, last). Introduce `gen.*` tokens + epoch with the async events. Land the sec 7 FW_SYNC authority and the `cache.identityBound` rewiring here (the one intentional behavior change).
  - Checkpoint after each event: targeted tests green (sec 9).

Phase 5 -- Delete dead `scroll{}` fields + module globals.
- Remove migrated fields, `pendingScrollMeta`, `scrollMetaFetchInFlight`, `lastFwScroll*`, the `*Busy` flags, `pauseToggleLocked`.
  - Checkpoint: grep shows no residual references; full regression pass.

---

## 9. Testing

Firmware (integration against the HTTP API where possible):
- Scroll start / chunked append / 409 conflict -> fresh-timeline retry.
- pause(user) then battery_overlay (system) then overlay end -> stays paused (composable-pause regression).
- Step at index 0 and at `frameCount-1` (wrap both directions).
- stop_scroll with `restoreAuto` true/false and `clear` true/false -> correct face restore via `faces.cpp`.
- set_scroll_interval -> `scrollIntervalMs`/`lastScrollFrameMs` updated via session API only.
- Malformed first chunk -> existing timeline/cache preserved (preflight validate-then-clear).
- Reboot -> RAM cache lost, `/api/scroll/meta` reports no frames.
- Oversized upload (> MAX_SCROLL_FRAMES) -> 413, cache invalidated, sourceText preserved (EH-A).

Browser (unit + scripted; host-mocked, no DOM):
- One assertion per transition-table row: `dispatch(state, event) -> state` incl. `pauseReasons` set ops.
- STARTING gap: `UPLOAD_COMMIT_DONE` does not set `isPlaying`; only `START_CONFIRMED` does; `START_FAIL` returns to IDLE.
- Token-staleness (same domain): a late `UPLOAD_COMMIT_DONE`/`RESTORE_DONE`/`STEP_DONE`/`START_CONFIRMED` with an old `gen.*` is dropped.
- Cross-domain cancellation (epoch): a late reply from any domain after a STOP/GENERATE/RESTORE is dropped (does not call `applyFirmwareRuntimeState`).
- Derived fields: `device.hasSession` true during RESTORING; `cache.identityBound` true only on `!truncated && generatorMatch && frameCount match && framesTimelineId === fw timeline`.
- Replacement flow: GENERATE/RESTORE_BEGIN from ACTIVE runs cleanup (terminate + reset + epoch bump) first.
- FW_SYNC authority: local tween never advances canonical `cache.frameIndex` while `device.hasSession`.

Keep existing: `tools/test_m370_boundary.js` still passes (encoding unchanged).

---

## 10. Risks and rollback

| Risk | Mitigation |
|---|---|
| Largest/most-coupled area; regressions | Strangler phasing; behavior-identical phases 1-3; checkpoints |
| Upload hot path slowed by API indirection | Frames still written to PSRAM outside the lock; only counts/meta under lock |
| Core-1 timing perturbed | Render-plane tick is one ...Locked call inside the existing critical section; no new locks |
| Malformed first chunk erases timeline | Transport-layer preflight stays; BeginUpload commits only after validation (sec 4.4) |
| Stale cross-domain completion | Epoch + per-domain tokens added with each async event (sec 5.3) |
| file:// / offline breakage | Inline IIFE, no module system, no new request |

Rollback: each phase is an independent commit; phases 1-3 are behavior-identical, so reverting any single phase restores prior behavior without data migration.

---

## 11. What this does NOT fix
- Clarity/maintainability + correctness-of-races refactor. The drift fix is included only because sec 7 bakes FW_SYNC authority into the reducer; without phase 4 that policy is not active.
- Does not change the scroll wire protocol, the M370 encoding, or the PSRAM cache size/limits.
- Does not address the 2.5 MB `ark12.json` font-parse jank (separate P2 in `ARCHITECTURE_REPORT.md`).

---

## 12. Open items (with recommended resolutions)
1. Review cadence. Recommended: one PR per phase for 1A/1B/1C/2/3/5, and per-event within phase 4 (the only behavior-changing phase). Pending sign-off.
2. Firmware test harness. Recommended: host-mocked HTTP for protocol parity + browser reducer unit tests; a short on-device smoke checklist for 1C timing, PSRAM behavior, and reboot/RAM-cache. Pending sign-off.
3. `/api/command` consistency. Resolved: yes -- route `buildCommandReply` (`web_api.cpp:1367`) through `scrollSessionSnapshot()` in phase 2, so `/api/status`, `/api/command`, and `/api/scroll/meta` share one read path.

---

## 13. Phase 1A implementation (exact code)

This section gives exact, copy-pasteable code for Phase 1A only (the firmware
control-plane move into a new `scroll_session` module). It is behavior-identical: no
wire/JSON/protocol change, no browser change. Phases 1B (upload/cache), 1C (render
cursor), and 2 (snapshot) follow in later PRs and are previewed in 13.12. Everything
below was cross-checked against the current source (verification table in 13.10).

### 13.1 What moves in 1A

| Symbol (current) | Current location | Destination |
|---|---|---|
| `isScrollPlayback` | `faces.cpp:81` / `faces.h:34` | `scroll_session.{h,cpp}` |
| `firmwareScrollHasRuntimeStateLocked` (static) | `faces.cpp:98` | `scroll_session.cpp` (static) |
| `resetFirmwareScrollStateLocked` (static) | `faces.cpp:109` | `scroll_session.cpp` (static) |
| `recomputeEffectivePauseLocked` (static) | `faces.cpp:281` | inlined into pause fn, removed |
| `setFirmwareScrollPauseFlag` (static) | `faces.cpp:290` | `scroll_session.cpp` (static) |
| `setFirmwareScrollUserPaused` -> `scrollSessionSetUserPaused` | `faces.cpp:323` / `faces.h:30` | `scroll_session.{h,cpp}` |
| `setFirmwareScrollSystemPaused` -> `scrollSessionSetSystemPaused` | `faces.cpp:327` / `faces.h:32` | `scroll_session.{h,cpp}` |
| scroll-state body of `stopFirmwareScroll` -> `scrollSessionStop` | `faces.cpp:331` | `scroll_session.{h,cpp}` (faces keeps thin wrapper) |
| scroll-state body of `startFirmwareScroll` -> `scrollSessionStart` | `faces.cpp:352` | `scroll_session.{h,cpp}` (faces keeps thin wrapper) |
| `markScrollStoppedByButton` (static) -> `scrollSessionMarkStoppedByButton` | `buttons.cpp:67` | `scroll_session.{h,cpp}` |
| `set_scroll_interval` body -> `scrollSessionSetInterval` | `web_api.cpp:1120` | `scroll_session.{h,cpp}` |
| `getRestoreAutoAfterScroll` -> `scrollSessionGetRestoreAuto` | `scroll.cpp:10` / `scroll.h:3` | `scroll_session.{h,cpp}` |
| `setRestoreAutoAfterScroll` -> `scrollSessionSetRestoreAuto` | `scroll.cpp:16` / `scroll.h:4` | `scroll_session.{h,cpp}` |

Face-side glue that STAYS in `faces.cpp` (so `scroll_session` never includes
`faces.h`): `cancelDeferredFaceRestore`, `setMode`, `isAutoMode`,
`scheduleStartupDefaultFaceRestoreAfterBlank`. Dependency inversion (sec 4.3) is what
makes this possible. Three documented lock-contract fixes (the flagged
`faces.cpp:304/362/371` String writes under `withScrollLock`) fall out of this move
and are shown inline.

### 13.2 New file: `src/scroll_session.h`

```cpp
#pragma once
#include <Arduino.h>
#include "config.h"

// Result of a scroll start request. faces.cpp owns the mode/face glue and acts on
// engagedRestoreAuto after the call (outside the scroll lock).
struct ScrollStartResult {
    bool started            = false;  // a cached timeline existed and playback began
    bool engagedRestoreAuto = false;  // auto-mode restore intent was (re)engaged this start
};

// Result of a scroll stop request. faces.cpp performs any face restore from this.
struct ScrollStopResult {
    bool stopped             = false; // there was runtime scroll state to clear
    bool cleared             = false; // display was blanked (clearDisplay)
    bool shouldRestoreDefault = false; // caller should schedule the startup-default face
    bool restoreAuto         = false; // restore to auto mode
};

// Pure scroll-playback predicate (moved from faces.cpp).
bool isScrollPlayback(const String& playback);

// --- control plane (Core 0). Each acquires withScrollLock internally. ---
ScrollStartResult scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode);
ScrollStopResult  scrollSessionStop(bool restoreAuto, bool clearDisplay);
bool scrollSessionSetUserPaused(bool paused);
bool scrollSessionSetSystemPaused(bool paused);
void scrollSessionSetInterval(uint16_t intervalMs);
void scrollSessionMarkStoppedByButton(const String& button, const String& source);

// Restore-auto flag (moved from scroll.cpp).
bool scrollSessionGetRestoreAuto();
void scrollSessionSetRestoreAuto(bool value);
```

### 13.3 New file: `src/scroll_session.cpp`

```cpp
#include "scroll_session.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"

// Pure predicate (was faces.cpp:81).
bool isScrollPlayback(const String& playback) {
    return playback == "scroll" ||
           playback == "scroll_paused" ||
           playback == "scroll_step";
}

bool scrollSessionGetRestoreAuto() {
    bool value = false;
    withScrollLock([&]() { value = runtimeState().restoreAutoAfterScroll; });
    return value;
}

void scrollSessionSetRestoreAuto(bool value) {
    withScrollLock([&]() {
        runtimeState().restoreAutoAfterScroll = value;
    });
}

// Was faces.cpp:98.
static bool firmwareScrollHasRuntimeStateLocked() {
    return runtimeState().firmwareScrollActive ||
           runtimeState().firmwareScrollPaused ||
           runtimeState().restoreAutoAfterScroll ||
           runtimeState().lastScrollFrameMs != 0 ||
           runtimeState().scrollFrameCount != 0 ||
           runtimeState().scrollFrameIndex != 0 ||
           runtimeState().paused ||
           isScrollPlayback(runtimeState().playback);
}

// Was faces.cpp:109. Moved verbatim (its playback write at the tail is the one
// String-under-lock the reviewer did NOT flag; left as-is to stay behavior-identical).
static void resetFirmwareScrollStateLocked(bool clearTimelineMeta = false) {
    runtimeState().firmwareScrollActive       = false;
    runtimeState().firmwareScrollPaused       = false;
    runtimeState().firmwareScrollUserPaused   = false;
    runtimeState().firmwareScrollSystemPaused = false;
    runtimeState().restoreAutoAfterScroll     = false;
    runtimeState().lastScrollFrameMs          = 0;
    runtimeState().scrollFrameCount           = 0;
    runtimeState().scrollFrameIndex           = 0;
    runtimeState().paused                     = false;
    if (clearTimelineMeta) clearScrollTimelineMetaLocked();
    else invalidateScrollUploadLocked();
    if (isScrollPlayback(runtimeState().playback)) {
        runtimeState().playback = DEFAULT_PLAYBACK;
    }
}

// Was faces.cpp:290 + recomputeEffectivePauseLocked (faces.cpp:281), merged.
// Fix: the old `const String oldPlayback = runtimeState().playback;` heap copy is
// removed; playback-change is detected with a non-allocating String != const char*
// compare, and the playback String is written OUTSIDE the lock (sec 4.6).
static bool setFirmwareScrollPauseFlag(bool userFlag, bool paused) {
    bool changed = false;
    bool applyPlaybackOutside = false;
    const char* playbackOutside = "scroll";
    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount == 0 && !runtimeState().firmwareScrollActive &&
            !runtimeState().firmwareScrollPaused) {
            runtimeState().firmwareScrollUserPaused = false;
            runtimeState().firmwareScrollSystemPaused = false;
            runtimeState().firmwareScrollPaused = false;
            return;
        }

        const bool oldUser      = runtimeState().firmwareScrollUserPaused;
        const bool oldSystem    = runtimeState().firmwareScrollSystemPaused;
        const bool oldEffective = runtimeState().firmwareScrollPaused;
        const bool oldPaused    = runtimeState().paused;

        if (userFlag) runtimeState().firmwareScrollUserPaused = paused;
        else          runtimeState().firmwareScrollSystemPaused = paused;
        runtimeState().firmwareScrollActive = true;

        const bool eff = runtimeState().firmwareScrollUserPaused ||
                         runtimeState().firmwareScrollSystemPaused;
        // No String temporary: compare current (still old) playback to the target.
        const bool playbackChanges =
            runtimeState().playback != (eff ? "scroll_paused" : "scroll");

        runtimeState().firmwareScrollPaused = eff;
        runtimeState().paused               = eff;
        if (!eff) runtimeState().lastScrollFrameMs = millis();

        applyPlaybackOutside = true;
        playbackOutside      = eff ? "scroll_paused" : "scroll";

        changed = oldUser != runtimeState().firmwareScrollUserPaused ||
                  oldSystem != runtimeState().firmwareScrollSystemPaused ||
                  oldEffective != eff ||
                  playbackChanges ||
                  oldPaused != runtimeState().paused;
    });
    if (applyPlaybackOutside) runtimeState().playback = playbackOutside;  // outside lock
    if (changed) touchRuntimeState();
    return changed;
}

bool scrollSessionSetUserPaused(bool paused) {
    return setFirmwareScrollPauseFlag(true, paused);
}

bool scrollSessionSetSystemPaused(bool paused) {
    return setFirmwareScrollPauseFlag(false, paused);
}

// Scroll-state portion of the old stopFirmwareScroll (faces.cpp:331). cancelDeferredFaceRestore /
// scheduleStartupDefaultFaceRestoreAfterBlank / setMode stay in the faces.cpp wrapper (sec 4.3).
ScrollStopResult scrollSessionStop(bool restoreAuto, bool clearDisplay) {
    ScrollStopResult r;
    r.restoreAuto = restoreAuto;
    r.cleared     = clearDisplay;

    bool changed = false;
    withScrollLock([&]() {
        changed = firmwareScrollHasRuntimeStateLocked();
        resetFirmwareScrollStateLocked(clearDisplay);
    });
    r.stopped = changed;
    if (changed) touchRuntimeState();
    if (changed || clearDisplay) clearQueuedM370Frames();

    if (clearDisplay) {
        applyBlankFrame("firmware_text_scroll_stop_clear");
        if (restoreAuto) r.shouldRestoreDefault = true;
    }
    return r;
}

// Scroll-state portion of the old startFirmwareScroll (faces.cpp:352). isAutoMode() is
// supplied by the caller as callerIsAutoMode; the mode="manual" write moves to the
// faces.cpp wrapper (outside the lock); playback="scroll" is written outside the lock.
ScrollStartResult scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode) {
    ScrollStartResult result;
    clearQueuedM370Frames();

    uint8_t firstFrame[FRAME_BYTES];
    bool    hasFirstFrame = false;

    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            runtimeState().restoreAutoAfterScroll =
                runtimeState().restoreAutoAfterScroll || callerIsAutoMode;
            result.engagedRestoreAuto = runtimeState().restoreAutoAfterScroll;
            runtimeState().scrollIntervalMs =
                constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            runtimeState().scrollFrameIndex           = 0;
            runtimeState().lastScrollFrameMs          = millis();
            runtimeState().firmwareScrollActive       = true;
            runtimeState().firmwareScrollPaused       = false;
            runtimeState().firmwareScrollUserPaused   = false;
            runtimeState().firmwareScrollSystemPaused = false;
            runtimeState().paused                     = false;
            memcpy(firstFrame, runtimeScrollFrameBits(0), FRAME_BYTES);
            hasFirstFrame = true;
        }
    });

    if (hasFirstFrame) {
        runtimeState().playback = "scroll";  // Core-0 field; String write outside the lock
        result.started = true;
        applyPackedFrameImmediate(firstFrame, "firmware_text_scroll_start");
    }
    return result;
}

void scrollSessionSetInterval(uint16_t intervalMs) {
    withScrollLock([&]() {
        runtimeState().scrollIntervalMs =
            constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        runtimeState().lastScrollFrameMs = millis();
    });
    touchRuntimeState();
}

// Was buttons.cpp:67 (static markScrollStoppedByButton).
void scrollSessionMarkStoppedByButton(const String& button, const String& source) {
    ++runtimeState().scrollStopEventSeq;
    runtimeState().scrollStopEventMs     = millis();
    runtimeState().scrollStopEventButton = button;
    runtimeState().scrollStopEventSource = source;
    runtimeState().scrollStopEventReason = runtimeState().lastReason;
    touchRuntimeState();
}
```

### 13.4 Edit `src/faces.cpp`

Add the include (top, with the other includes):
```cpp
#include "scroll_session.h"
```
Delete `isScrollPlayback` (faces.cpp:81-85); it now lives in `scroll_session.cpp`
(`playbackIsNonFaceActivity` just below keeps calling it -- resolved via the include).
Delete the moved statics `firmwareScrollHasRuntimeStateLocked` (98-107) and
`resetFirmwareScrollStateLocked` (109-126).

Delete `recomputeEffectivePauseLocked` (281-288), `setFirmwareScrollPauseFlag`
(290-321), `setFirmwareScrollUserPaused`/`setFirmwareScrollSystemPaused` (323-329),
`stopFirmwareScroll` (331-350), and `startFirmwareScroll` (352-378). The pause fns are
now `scrollSessionSet*Paused` with no faces wrapper -- their call sites are updated in
13.8 and 13.9. Replace the stop/start pair with these wrappers:

```cpp
void stopFirmwareScroll(bool restoreAuto, bool clearDisplay) {
    cancelDeferredFaceRestore();
    const ScrollStopResult r = scrollSessionStop(restoreAuto, clearDisplay);
    if (r.cleared) {
        if (r.shouldRestoreDefault) scheduleStartupDefaultFaceRestoreAfterBlank(r.restoreAuto);
    } else if (r.restoreAuto) {
        setMode("auto", false);
    }
}

void startFirmwareScroll(uint16_t intervalMs) {
    cancelDeferredFaceRestore();
    const ScrollStartResult r = scrollSessionStart(intervalMs, isAutoMode());
    if (r.engagedRestoreAuto) runtimeState().mode = "manual";  // Core-0 field; no scroll lock needed
}
```

Update the internal restore-auto calls (faces.cpp:57-58 in `setMode`, 170 in
`toggleModeFromButtonAction`):
```cpp
-        if (persistSettings && getRestoreAutoAfterScroll()) {
-            setRestoreAutoAfterScroll(false);
+        if (persistSettings && scrollSessionGetRestoreAuto()) {
+            scrollSessionSetRestoreAuto(false);
...
-    setRestoreAutoAfterScroll(false);
+    scrollSessionSetRestoreAuto(false);
```
`scheduleStartupDefaultFaceRestoreAfterBlank` stays a `static` in faces.cpp and is in
scope for the wrapper. No header change for it.

### 13.5 Edit `src/faces.h`

Remove the three declarations now owned by `scroll_session.h`:
```cpp
-bool setFirmwareScrollUserPaused(bool paused);
-
-bool setFirmwareScrollSystemPaused(bool paused);
-
-bool isScrollPlayback(const String& playback);
```
Keep `stopFirmwareScroll`, `startFirmwareScroll`, and `playbackIsNonFaceActivity`.

### 13.6 Edit `src/scroll.h` and `src/scroll.cpp`

`src/scroll.h` -- remove the restore-auto declarations (lines 3-4):
```cpp
-bool getRestoreAutoAfterScroll();
-void setRestoreAutoAfterScroll(bool value);
-
 void startScrollRenderTask();
```
`src/scroll.cpp` -- delete `getRestoreAutoAfterScroll`/`setRestoreAutoAfterScroll`
(lines 10-20). The render task stays; `scroll.cpp` does not call these, so no other
change and no new include is needed.

### 13.7 Edit `src/buttons.cpp`

Add `#include "scroll_session.h"`. Remove the static `markScrollStoppedByButton`
(lines 67-74). Update the three call sites (lines 112, 123, 128):
```cpp
-        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
+        if (handled && shouldNotifyScrollStop) scrollSessionMarkStoppedByButton(code, source);
```
Update the restore-auto call (line 118):
```cpp
-        setRestoreAutoAfterScroll(false);
+        scrollSessionSetRestoreAuto(false);
```
`isScrollPlayback` (buttons.cpp:57) now resolves via the include.

### 13.8 Edit `src/web_api.cpp`

Add `#include "scroll_session.h"`. Delegate `commandSetScrollInterval`
(lines 1120-1130):
```cpp
 static bool commandSetScrollInterval(JsonDocument& doc, JsonVariant payload, String& error) {
     (void)error;
     uint16_t iMs = runtimeState().scrollIntervalMs;
     scrollIntervalFromCommand(doc, payload, iMs);
-    withScrollLock([&]() {
-        runtimeState().scrollIntervalMs  = constrain(iMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
-        runtimeState().lastScrollFrameMs = millis();
-    });
-    touchRuntimeState();
+    scrollSessionSetInterval(iMs);
     return true;
 }
```
Pause/resume helpers (lines 393-404):
```cpp
-    changed = setFirmwareScrollUserPaused(true);
+    changed = scrollSessionSetUserPaused(true);
...
-    if (canResume) changed = setFirmwareScrollUserPaused(false);
+    if (canResume) changed = scrollSessionSetUserPaused(false);
```
`commandStopScroll` restore-auto read (line 1246) and
`commandTerminateOtherActivities` write (line 1299):
```cpp
-    bool restoreAuto  = getRestoreAutoAfterScroll();
+    bool restoreAuto  = scrollSessionGetRestoreAuto();
...
-        setRestoreAutoAfterScroll(true);
+        scrollSessionSetRestoreAuto(true);
```
`isScrollPlayback` (web_api.cpp:623) resolves via the include.

### 13.9 Edit `src/button_animations.cpp`

Add `#include "scroll_session.h"`. Update the two system-pause calls (lines 364, 378):
```cpp
-    if (shouldPause && setFirmwareScrollSystemPaused(true)) {
+    if (shouldPause && scrollSessionSetSystemPaused(true)) {
...
-    setFirmwareScrollSystemPaused(false);
+    scrollSessionSetSystemPaused(false);
```

### 13.10 Verification against current source

| Claim | Verified against |
|---|---|
| restore-auto defined `scroll.cpp:10/16`, declared `scroll.h:3/4` | grep confirmed |
| restore-auto callers: `faces.cpp:57,58,170`; `buttons.cpp:118`; `web_api.cpp:1246,1299` | grep confirmed (exactly these 6) |
| `setFirmwareScrollUserPaused` callers: `web_api.cpp:394,403` | read confirmed |
| `setFirmwareScrollSystemPaused` callers: `button_animations.cpp:364,378` | read confirmed |
| `markScrollStoppedByButton` static `buttons.cpp:67`, 3 call sites | read confirmed |
| `commandSetScrollInterval` body `web_api.cpp:1120-1130` | read confirmed |
| `start/stopFirmwareScroll` bodies `faces.cpp:352/331` | read confirmed (verbatim above) |
| `mode`/`playback` are Core-0 cooperative fields (safe outside scroll lock) | `state.h:13-19` lock/owner contract |
| `isScrollPlayback` consumers: `faces.cpp`, `buttons.cpp:57`, `web_api.cpp:623` | grep/read confirmed; all 3 get the include |

Behavior-equivalence arguments (the only non-mechanical changes):
1. Pause-flag playback detection. Old code captured `const String oldPlayback` and
   compared after `recomputeEffectivePauseLocked`. New code computes
   `playbackChanges = currentPlayback != (eff ? "scroll_paused" : "scroll")` before the
   write. Since `recompute` set playback purely as a function of `eff`, the two
   booleans are identical; only the heap String copy is removed.
2. playback written outside the lock. `playback` is Core-0 cooperative state
   (`state.h:16-19`) and is not read by the Core-1 render task. On Core 0 there is no
   yield between lock release and the assignment, so no observer sees an intermediate
   value. Same for `mode="manual"` in the start wrapper.
3. Order of `mode="manual"` vs frame publish in start. `publishPackedFrameNow` takes
   only the frame lock and does not read `mode`, and Core 0 does not yield between, so
   the reorder is unobservable.
4. `resetFirmwareScrollStateLocked` is moved verbatim (including its tail `playback`
   write under the lock, not in the flagged set), preserving stop semantics exactly.

### 13.11 Build + checkpoint

```
pio run                       # compile firmware
pio run -t buildfs            # (optional in 1A) LittleFS image still builds
```
On-device parity checklist:
- Pause (user) then battery overlay (system) then end overlay -> still paused.
- B1/B2 face step at list ends; B3 mode toggle; B3+B1/B3+B2 interval.
- Start scroll, stop with clear+restore-auto -> returns to auto and shows default face.
- `set_scroll_interval` via `/api/command` updates fps with no visual glitch.
- Button-triggered scroll stop still produces a `scrollStopEvent` in `/api/status`.

This is one self-contained, behavior-identical PR. Revert = restore prior behavior
with no data migration.

### 13.12 Next PRs (previews)
- Phase 1B (upload/cache): `ScrollUploadTxn` + `scrollSessionBeginUpload/WriteFrame/
  AppendChunk/CommitUpload/InvalidateCache/ClearTimeline` over the `web_api.cpp:817/936`
  writes; keep the transport-layer first-chunk preflight (`web_api.cpp:782`); add
  `scrollSessionCopyMeta` and route `/api/scroll/meta`.
- Phase 1C (render cursor): move the `scroll.cpp:42` advance into
  `scrollSessionTickCursorLocked(now, outFrameBits)`, called inside the render task's
  existing `withScrollLock`.
- Phase 2 (snapshot): `scrollSessionSnapshot()` backing `/api/status` and
  `buildCommandReply` (`web_api.cpp:1367`).

---

## Appendix A -- Code references (current source)
- Pause OR-semantics: `src/faces.cpp:281` (`recomputeEffectivePauseLocked`), `:290` (`setFirmwareScrollPauseFlag`).
- Scroll start/stop: `src/faces.cpp:352` / `:331`.
- String-under-lock: `src/faces.cpp:304`, `:362`, `:371`.
- Direct `/api/scroll` state writes: `src/web_api.cpp:817`, `:936`; first-chunk preflight `:782`.
- set_scroll_interval writes: `src/web_api.cpp:1120`. Command reply builder: `src/web_api.cpp:1367`.
- Button stop-event writes: `src/buttons.cpp:67`.
- restore-auto get/set: `src/scroll.cpp`. Core-1 cursor advance: `src/scroll.cpp:42`.
- Browser scroll state + globals: `data/app.js:3565`, `:3609`; upload generation `:8338`; start_scroll send `:8405`; frameIndex writers `:4714`, `:8729`; timeline match `:8897`; timeline-mismatch restore `:4845`.
- Endpoint/contract baseline: `ARCHITECTURE_REPORT.md` sec 7, sec 11, sec 13.
