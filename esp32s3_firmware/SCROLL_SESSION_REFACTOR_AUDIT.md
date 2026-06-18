# Scroll Session Refactor Plan Audit

Audited document: `SCROLL_SESSION_REFACTOR_PLAN.md`
Codebase: `esp32s3_firmware/` (firmware `src/`, WebUI `data/app.js`, `data/index.html`)
Date of audit: 2026-06-18

## Executive Summary

**Verdict: PASS WITH REQUIRED FIXES.**

The plan is architecturally sound and, with one exception, the changes it describes are correct, internally consistent, and safe. The firmware side is the strongest part: the ownership-boundary design (everything routes through `scroll_session`) is well-specified and the behavior-equivalence arguments in sec 13.10 hold up against the source.

However, the audit surfaced one fact that dominates everything else and **must be corrected in the plan before it is used as a review contract**:

1. **The plan's status line is false.** It says *"Status: Draft for review -- no code moved yet"* and *"no behavior change in phases 1-3."* In reality the work is **already implemented in the live tree**, and substantially *beyond* Phase 1A:
   - Firmware: `src/scroll_session.{h,cpp}` exist and implement Phases **1A + 1B + 1C + 2** (control plane, upload transaction, render-cursor tick, snapshot/meta readers) plus an extra `scrollSessionStep()` that is **not described anywhere in the Phase 1A code section (sec 13)**. `faces.cpp`, `faces.h`, `scroll.cpp`, `scroll.h`, `buttons.cpp`, `button_animations.cpp`, `web_api.cpp` are all already rewired.
   - WebUI: `data/app.js` already contains the full `scrollMachine` IIFE (Phases **3 + 4**), including the epoch/token machinery and the FW_SYNC reducer.

   So this is no longer an audit of an unimplemented design; it is an audit of an implemented refactor whose plan document was never updated. The plan must either be marked "implemented" with the deltas reconciled, or the team must be told the code already diverged from it.

2. **The plan's headline goal — "preview and LEDs cannot drift by construction" (sec 7) — is NOT achieved in the implemented code.** The local `advanceScroll` timer (`app.js:8931`) still writes `scroll.frameIndex` *unconditionally* while it runs, and `restartScrollPreviewTimer()` (`app.js:8270`) keeps that timer running during firmware-backed active playback (`scroll.active && !scroll.paused`). FW_SYNC (`applyFirmwareCursor`, `app.js:3717`) also writes `scroll.frameIndex`. That is exactly the two-writer condition the plan said it would eliminate; drift is merely bounded by the poll interval and snapped back on each sync, not removed.

Everything else is either correct or a minor consistency nit (dead `PAUSE_SYSTEM`/`RESUME_SYSTEM` events, an unguarded transition table, firmware step-while-running, a stray `app.js.mine` file). Details below.

---

## Stage-by-Stage Audit

The plan's "stages" are its phases (sec 8) plus the detailed Phase 1A spec (sec 13). Each is audited against the actual implemented code.

### Stage Phase 1A: Firmware control-plane extraction
Status: **PASS**

Planned changes (sec 13): move `isScrollPlayback`, the pause statics, `start/stopFirmwareScroll` bodies, `markScrollStoppedByButton`, `set_scroll_interval` body, and restore-auto get/set into `scroll_session.{h,cpp}`; leave face glue in `faces.cpp` via dependency inversion; fix the `String`-under-lock contract violations.

Verified code locations:
- `src/scroll_session.cpp`: `isScrollPlayback` (8), `scrollSessionGetRestoreAuto`/`SetRestoreAuto` (14-24), `firmwareScrollHasRuntimeStateLocked` (26), `resetFirmwareScrollStateLocked` (37), `setFirmwareScrollPauseFlag` (54-99), `scrollSessionSetUserPaused`/`SetSystemPaused` (101-107), `scrollSessionStop` (129), `scrollSessionStart` (151), `scrollSessionSetInterval` (185), `scrollSessionMarkStoppedByButton` (194).
- `src/faces.cpp`: thin wrappers `stopFirmwareScroll` (244-252), `startFirmwareScroll` (254-258); restore-auto callers rewired (56-57, 133); old statics deleted.
- `src/faces.h`: `setFirmwareScrollUserPaused`/`SystemPaused`/`isScrollPlayback` removed (confirmed absent).
- `src/scroll.cpp`/`.h`: `get/setRestoreAutoAfterScroll` removed from header (scroll.h now only declares `startScrollRenderTask`/`notifyScrollRenderTask`).
- `src/buttons.cpp`: `scrollSessionMarkStoppedByButton` (103, 113, 118), `scrollSessionSetRestoreAuto` (109).
- `src/button_animations.cpp`: `scrollSessionSetSystemPaused` (365, 379).
- `src/web_api.cpp`: `scrollSessionSetUserPaused` (361, 370), `scrollSessionSetInterval` (1015), `scrollSessionGetRestoreAuto` (1121), `scrollSessionSetRestoreAuto` (1174).

Findings:
- Correct. The `setFirmwareScrollPauseFlag` rewrite in `scroll_session.cpp:54-99` matches sec 13.3 verbatim, including the no-heap-`String` `playbackChanges` compare (80) and the out-of-lock `playback` write (96). The behavior-equivalence argument in sec 13.10 (#1) is valid: `recompute` set playback purely as a function of `eff`, so the pre-write compare is identical.
- The `String`-under-lock fixes (sec 4.6) are present: `playback` written outside the lock in both pause (`scroll_session.cpp:96`) and start (`:178`); `mode="manual"` outside the lock in the faces wrapper (`faces.cpp:257`).
- `resetFirmwareScrollStateLocked` moved verbatim including its tail `playback` write under the lock (`scroll_session.cpp:49-51`) — consistent with sec 13.10 (#4).
- No leftover duplicate definitions of any moved symbol (grep across `src/` confirms the old names exist only as `scrollSession*` variants).

Required fixes: none for 1A itself. Update sec 13's "no browser change / behavior-identical" framing since the browser was also changed (see Phase 3/4).

### Stage Phase 1B: Upload / cache transaction plane
Status: **PASS**

Planned changes (sec 4.1, 4.4, 8): route `/api/scroll` writes behind `scrollSessionBeginUpload/BeginAppend/WriteFrame/CommitUpload/InvalidateCache/ClearTimeline`; preserve transport-layer first-chunk preflight (validate-then-clear); enforce partial-frames-invisible + visible-index write rejection; add `scrollSessionCopyMeta` for `/api/scroll/meta`.

Verified code locations:
- `src/web_api.cpp` `handleApiScroll`: preflight loop (745-776) decodes/validates *every* first-chunk frame before any mutation; `stopFirmwareScroll(false)` + `scrollSessionBeginUpload` only after preflight (784-793); append path `scrollSessionBeginAppend` + 409 checks (796-810); per-frame `scrollSessionWriteFrame` (854) with `scrollSessionInvalidateCache` on bad frame / overflow (836, 850); `scrollSessionCommitUpload` (867).
- `src/scroll_session.cpp`: `scrollSessionBeginUpload` (203), `scrollSessionBeginAppend` (243), `scrollSessionWriteFrame` (261) with visible-index rejection (266-267), `scrollSessionCommitUpload` (277) publishing counts under lock, `scrollSessionCopyMeta` (321).
- `src/web_api.cpp` `handleApiScrollMeta` (904) → `scrollSessionCopyMeta` (920), PSRAM text copy, 507 on alloc/overflow.

Findings:
- Correct and faithful to sec 4.4. Validate-then-clear is intact: a malformed first chunk fails at `:765` before `stopFirmwareScroll`/`BeginUpload`, so it cannot erase a working timeline.
- Partial-frames-invisible invariant holds: `scrollFrameCount` is only advanced in `scrollSessionCommitUpload` under the lock (`scroll_session.cpp:282`); `scrollSessionWriteFrame` rejects writes into `[0, scrollFrameCount)` unless first-chunk-clearing (`:266`).
- EH-A (bad/oversized frames invalidate cache but keep sourceText): `scrollSessionInvalidateCache` zeroes `scrollFrameCount` + `invalidateScrollUploadLocked()` but does **not** clear sourceText (`scroll_session.cpp:306-311`). Correct.

Required fixes: none. (Note `scrollSessionCommitUpload`'s implemented signature `(txn, count, hasExplicitTiming, intervalMs)` differs from the sec 4.1 sketch `scrollSessionCommitUpload(ScrollUploadTxn&)`; the implementation is the better one. Reconcile sec 4.1.)

### Stage Phase 1C: Render-cursor tick (Core 1)
Status: **PASS**

Planned changes (sec 4.2): move the Core-1 advance into `scrollSessionTickCursorLocked(now, outFrameBits)`, called inside the render task's existing `withScrollLock`.

Verified code locations:
- `src/scroll.cpp` `scrollRenderTask` (11-47): single `withScrollLock` block calling `scrollSessionTickCursorLocked(millis(), nextFrame)` (21); frame published under `withFrameLock` (27-38).
- `src/scroll_session.cpp` `scrollSessionTickCursorLocked` (367-392): returns false unless active && !paused && frames present; drift-compensated `lastScrollFrameMs` advance (384-388).

Findings:
- Correct. The tick is one `...Locked` call inside the existing critical section; no new lock introduced, matching the sec 10 risk mitigation. The function only writes scroll fields and reads `scrollIntervalMs` under the held lock.

Required fixes: none.

### Stage Phase 2: Route reads through the snapshot
Status: **PASS**

Planned changes (sec 8, open item 3): `/api/status`, `/api/command` reply (`buildCommandReply`), and `/api/scroll/meta` share one read path.

Verified code locations:
- `readScrollStateSnapshot()` → `scrollSessionSnapshot()` (`web_api.cpp:168-170`).
- `/api/status` `handleApiStatus` uses snapshot (`:418`) → `addScrollStateFields` (`:472`).
- `buildCommandReply(reply, cmd, scrollState)` (`:1242`) → `addScrollStateFields` (`:1255`); called from the command handler with a snapshot (`:1303-1306`).
- Upload reply also reads the snapshot (`:878`).

Findings: correct; all three read paths converge on `scrollSessionSnapshot()` + `addScrollStateFields`, exactly as open item 3 promised. JSON field names are produced in one place, eliminating the contract-drift risk.

Required fixes: none.

### Stage Phase 3: Browser machine as compatibility wrapper
Status: **PASS (already in place, beyond a pure wrapper)**

Planned changes (sec 5, 6, 8): introduce inline `scrollMachine` IIFE with `scroll{}` still backing; `dispatch` delegating; no behavior change.

Verified code locations:
- `data/app.js:3643-3817` — `scrollMachine` IIFE with `state`, `pauseReasons:Set`, `epoch`, `gen{upload,restore,step,statusPoll}`, `device.hasSession`, `cache.identityBound/frameIndex`; `token`, `isCurrent`, `bumpEpoch`, `dispatch`, `snapshot`.
- Dispatch call sites wired across upload/start (`:8514,8584,8597,8601`), generate (`:8637`), pause/resume (`:8747,8781`), stop (`:8811,8828`), step (`:8899,8918`), restore (`:9256` + many `RESTORE_DONE`), FW_SYNC (`:4890`), text edit (`:8308`).

Findings:
- The machine is real, not a thin pass-through; it already carries Phase-4 logic. `scroll{}` is still the backing store (`syncPauseBacking` writes `scroll.userPaused/systemPaused/paused`, `setPhase` writes `scroll.active/restoring/uploading`), so the compatibility-wrapper intent is honored.
- **Risk:** `dispatch` does **not** validate the `From` state. The plan's sec 5.2 transition table specifies `From`→`To` constraints (e.g. `STEP` only from `ACTIVE`, `START_CONFIRMED` only from `STARTING`). The reducer applies effects regardless of current state (`app.js:3730-3803`). In practice the UI gates these via `commandBusy`/disabled buttons, but the state-machine invariant the plan advertises is not enforced in code.

Required fixes: see Cross-Stage and Required Corrections.

### Stage Phase 4: FW_SYNC authority + identityBound rewiring (the one intended behavior change)
Status: **NEEDS FIX**

Planned changes (sec 5.1, 7): FW_SYNC becomes the *sole* writer of the canonical cursor whenever `device.hasSession`; local `advanceScroll` timer demoted to display-only tween that never writes `cache.frameIndex` and is discarded on each sync; `cache.identityBound` (incl. timeline-id binding) gates "reference only".

Verified code locations:
- `applyFirmwareCursor` (`app.js:3693-3728`): snaps `scroll.frameIndex`/`machine.cache.frameIndex` to firmware index when `device.hasSession` (3717-3721); skips during GENERATING/UPLOADING/STARTING ("FIX 4", 3695).
- `deriveIdentityBound` (`:3683-3691`): includes `!restoredTextTruncated && exactGeneratorMatch(meta) && frames.length===frameCount && framesTimelineId===meta.scrollTimelineId` — matches sec 5.1 formula incl. timeline binding.
- `advanceScroll` (`:8927-8944`): writes `scroll.frameIndex` unconditionally (8931).
- `restartScrollPreviewTimer` (`:8270-8276`): starts the `advanceScroll` interval whenever `scroll.active && !scroll.paused`.

Findings:
- `identityBound` is correctly derived and includes the timeline-id binding (matches the `localTimelineMatchesMeta` gate the plan cited).
- **The core anti-drift policy is incomplete.** FW_SYNC writes the cursor, but so does the still-running local timer during firmware-backed ACTIVE playback. Both `applyFirmwareCursor` (3718) and `advanceScroll` (8931) write `scroll.frameIndex`. The plan's promise ("preview and LEDs cannot drift by construction", sec 7) is therefore not met; drift is only bounded by the FW_SYNC poll cadence (`statusNextPollMs`: 250 ms while scrolling+summary, else 1000 ms — `web_api.cpp:162-166`) and corrected with a visible snap. The plan explicitly listed the two-writer condition (`app.js:4714` and `:8729` historically) as the thing to remove; it persists.

Required fixes: demote the timer (see Required Corrections #1).

### Stage Phase 5: Delete dead `scroll{}` fields + module globals
Status: **NOT DONE (expected) — but note coexistence**

Planned changes: remove migrated fields, `pendingScrollMeta`, `scrollMetaFetchInFlight`, `lastFwScroll*`, `*Busy` flags, `pauseToggleLocked`.

Findings: `pendingScrollMeta`, `lastFwScroll*` (e.g. `lastFwScrollFrameCount` at `app.js:8845`), and the per-control `*Busy` flags (`scroll.commandBusy/pauseBusy/stepBusy/stopBusy/fpsBusy`) are still present and live. This is consistent with Phase 5 being future work. No defect, but the audit goal "no conflicting definitions of scroll session state" is only partially met while both the machine and the legacy `scroll{}` booleans are authoritative in parallel.

Required fixes: none yet; track for Phase 5.

---

## Cross-Stage Consistency Check

- **Names / JSON fields are consistent firmware↔WebUI.** Status/meta producers emit `firmwareScrollActive`, `firmwareScrollPaused`, `firmwareScrollUserPaused`, `firmwareScrollSystemPaused`, `restoreAutoAfterScroll`, `scrollFrameCount`, `scrollFrameIndex`, `scrollIntervalMs`, `scrollTimelineId`, `scrollUploadComplete`, `scrollHasSourceText` (`web_api.cpp:172-184`). The WebUI consumes exactly these keys in `applyFirmwareCursor` (`app.js:3698-3705`) and `applyFirmwareRuntimeState` (`:9170-9186`). No mismatches found.
- **Missing dependencies:** none. Every WebUI dispatch target exists in the reducer; every firmware session function called by `web_api/faces/buttons/scroll/button_animations` is declared in `scroll_session.h`.
- **Dead transitions (defined, never dispatched):** `PAUSE_SYSTEM` and `RESUME_SYSTEM` reducer cases (`app.js:3760-3767`) have no `dispatch(...)` callers. System pause is instead applied directly inside `applyFirmwareCursor` (`:3707-3713`), which mutates `pauseReasons` without going through the reducer event. Functionally correct (battery overlay is firmware-driven and mirrored by FW_SYNC), but it contradicts sec 5.2's event model and leaves two ways to mutate system-pause.
- **Transition table not enforced (sec 5.2 vs `dispatch`):** the implemented reducer ignores the `From` column. This is a documentation/contract mismatch, not a live bug given UI gating.
- **Signature drift plan↔code:** `scrollSessionStart(ScrollStartContext)` / `scrollSessionStop(...) ` / `scrollSessionStep(int8_t)` / `scrollSessionCommitUpload(ScrollUploadTxn&)` as sketched in sec 4.1 differ from the (better) implemented signatures. The plan should be reconciled to the code so it can serve as a contract.
- **Extra surface not in the plan:** `scrollSessionStep(int8_t, uint8_t*)` (`scroll_session.{h,cpp}`) and the `scroll_step` command (`web_api.cpp:1084,1218`) are implemented but absent from sec 13's "what moves" list. The Step row in sec 5.2 exists on the browser side but the firmware function was never specified.
- **Stale line references:** every `app.js:NNNN` and `faces.cpp:NNNN` reference in the plan points at the *pre-refactor* baseline and no longer matches the current files (e.g. plan cites `scroll{}` at `app.js:3565`; the machine is now at `:3643`). Acceptable as historical context only.

---

## API Contract Verification

| Endpoint | Method | Request | Response | Firmware owner fn | WebUI caller | Status | Issues |
|---|---|---|---|---|---|---|---|
| `/api/scroll` | POST | JSON: `frames[]` (M370 strings), optional `timelineId`, `fontId`, `generatorVersion`, `sourceText`, `totalFrames`, `chunkIndex`, `append`, `start`, `fps`, `intervalMs` | `ok`, `frames`, `chunkFrames`, `chunkIndex`, `totalFrames`, `append`, `started`, `timelineId`, `uploadComplete`, `scrollIntervalMs`, `scrollMaxFrames`, `mode`, `playback`, `restoreAutoAfterScroll` | `handleApiScroll` (`web_api.cpp:~700-901`) → `scrollSessionBeginUpload/BeginAppend/WriteFrame/CommitUpload/InvalidateCache` | upload pipeline (`app.js:8513-8601`) | PASS | Preflight + invariants verified |
| `/api/scroll/meta` | GET | — | `ok`, `scrollTimelineId`, `hasSourceText`, `sourceText`, `sourceTextBytes`, `fontId`, `generatorVersion`, frame count/index, pause flags | `handleApiScrollMeta` (`:904`) → `scrollSessionCopyMeta` (`:920`) | restore pipeline (`app.js:9256+`) | PASS | 507 on PSRAM alloc/overflow handled |
| `/api/status` | GET | optional `summary` | full state incl. `addScrollStateFields` + `scrollStopEvent{seq,ms,button,source,reason}` | `handleApiStatus` (`:413`) → `scrollSessionSnapshot` | poller → `dispatch("FW_SYNC")` (`app.js:4890`) | PASS | Poll cadence 250/1000 ms (`:162`) |
| `/api/command` `start_scroll` | POST | `{intervalMs?, timelineId?}` | command reply via `buildCommandReply` | `commandStartScroll` (`:1019`) → `startFirmwareScroll` | start flow (`app.js:8601`) | PASS | Timeline-mismatch→409, incomplete→409, no frames→400 |
| `/api/command` `scroll_step` | POST | `{direction}` | reply | `commandScrollStep` (`:1084`) → `scrollSessionStep` | step handler (`app.js:8906`) | NEEDS FIX | Does not require/keep paused; render tick can overwrite when running (see Firmware Safety) |
| `/api/command` `pause_scroll` | POST | — | reply | `commandPauseScroll` → `scrollSessionSetUserPaused(true)` | `pauseScroll` (`app.js:8744`) | PASS | Composable user-pause |
| `/api/command` `resume_scroll` | POST | — | reply | `commandResumeScroll` → `resumeFirmwareScrollIfCached` | `resumeScroll` (`app.js:8778`) | PASS | `requirePaused` only for `resume` (not `resume_scroll`) — intentional |
| `/api/command` `stop_scroll` | POST | `{clear?, restoreAuto?}` | reply incl. `deferredFaceRestoreActive` | `commandStopScroll` (`:1118`) → `stopFirmwareScroll` | `stopScroll` (`app.js:8814`) | PASS | Restore handled in `faces.cpp` |
| `/api/command` `set_scroll_interval` | POST | `{fps?\|intervalMs?}` | reply | `commandSetScrollInterval` (`:1015`) → `scrollSessionSetInterval` | `setScrollFps` (`app.js:8282+`) | PASS | — |
| `/api/command` `terminate_other_activities` | POST | `{targetMode}` | reply | `commandTerminateOtherActivities` (`:1166`) → `scrollSessionSetRestoreAuto` | mode switches | PASS | Sets `restoreAuto` + `mode="manual"` for scroll target in auto |

Failure cases checked: malformed first chunk → 400 pre-mutation (timeline preserved); oversized → 413, cache invalidated, sourceText kept; chunk out of order / timeline mismatch / upload complete → 409; PSRAM alloc fail on meta → 507. All present.

---

## State Machine Verification

Reconstructed scroll session state (firmware authoritative; browser mirrors):

| State | Firmware representation | Browser `machine.state` |
|---|---|---|
| no session | `!active && !paused && frameCount==0` | `IDLE`, `device.hasSession=false` |
| uploaded, stopped/startable | `frameCount>0`, `uploadComplete`, `!active` | `IDLE`, `device.hasSession=true` (via frameCount+uploadComplete) |
| starting | n/a (commit→start is two ops) | `STARTING` |
| running | `firmwareScrollActive && !firmwareScrollPaused` | `ACTIVE`, `pauseReasons={}` |
| paused | `firmwareScrollPaused`, reasons in `firmwareScrollUserPaused`/`SystemPaused` | `ACTIVE`, `pauseReasons⊇{user|system}` |
| stepping | index nudged, `playback="scroll_step"` | `STEPPING` |
| stopped→restored mode | `resetFirmwareScrollStateLocked` + face restore in `faces.cpp` | `IDLE` after `STOP_DONE` |
| cleared | `scrollSessionStop(clearDisplay=true)` blanks + schedules default face | `IDLE`, cache cleared |
| manual/auto takeover | `stopFirmwareScroll(false,false)` from `toggleModeFromButtonAction` / `setMode` | FW_SYNC drives `device.hasSession=false` |

Transition checks:

| Trigger | Firmware action | WebUI action | Expected | Issue |
|---|---|---|---|---|
| Upload commit | `scrollSessionCommitUpload` publishes counts | `UPLOAD_COMMIT_DONE`→STARTING | not playing yet | OK — STARTING gap honored |
| start_scroll ok | `startFirmwareScroll` | `START_CONFIRMED`→ACTIVE, clear pauseReasons | playing | OK |
| pause(user) | `SetUserPaused(true)` | `PAUSE_USER`, stop local timer | stays paused | OK |
| +battery overlay | `SetSystemPaused(true)` | FW_SYNC adds "system" | stays paused after overlay ends only if user reason remains | OK — composable preserved (`scroll_session.cpp:77`) |
| step (paused) | `scrollSessionStep` holds frame (tick returns false) | `STEP`→`STEP_DONE` | frame holds | OK |
| step (running) | index changes but tick keeps advancing | `STEP`→`STEP_DONE` | **frame does not hold** | NEEDS FIX — firmware does not pause/latch on step |
| stop/clear | `scrollSessionStop` + face restore | `STOP` (bump epoch) → await → `STOP_DONE` | LEDs and UI clear together | OK — UI does not clear until confirm; on no-confirm it restarts preview (`app.js:8824`) |
| B1/B2/B3 hardware | `stopFirmwareScroll` + `scrollSessionMarkStoppedByButton` | next FW_SYNC clears `device.hasSession`, shows face | scroll stops, face shows | OK |
| reload while scrolling | state persists in RAM | `RESTORE_BEGIN`→meta fetch→`RESTORE_DONE`, FW_SYNC authoritative | preview rebuilt + synced | OK (subject to drift caveat) |
| mode→manual/auto | `setMode` clears restore-auto | FW_SYNC | scroll stops cleanly | OK |

---

## Firmware Safety Review

- **Shared variables / locking:** every `RuntimeState` scroll-field write goes through `scroll_session` functions that take `withScrollLock` internally; the render-plane `scrollSessionTickCursorLocked` is the single documented exception, called by `scrollRenderTask` with the lock already held (`scroll.cpp:20-23`). The invariant in sec 4.2 is true in the code.
- **Core0/Core1:** Core-1 only mutates `scrollFrameIndex`/`lastScrollFrameMs` and reads `scrollIntervalMs`/`scrollFrameCount` under the held lock; frame bytes are published under a separate `withFrameLock` (`scroll.cpp:27`). No unlocked cross-core access found.
- **String-under-lock:** fixed. `playback`/`mode` String writes occur outside the lock (`scroll_session.cpp:96,178`; `faces.cpp:257`). `state.h:13-19` documents these as Core-0 cooperative fields not read by Core 1, so the out-of-lock writes are safe (sec 13.10 #2/#3).
- **Memory lifetime:** `ScrollUploadTxn` is a stack-local per-request struct; durable per-timeline meta lives under the lock in `ScrollTimelineMeta`. `scrollSessionCopyMeta` copies sourceText into a caller-provided PSRAM buffer; no dangling pointers. `ScrollUploadMeta` holds `const char*` into request-scoped `String`s that outlive the synchronous `scrollSessionBeginUpload` call — OK because copy happens immediately under the lock.
- **Frame buffers:** `scrollSessionWriteFrame` guards `index < MAX_SCROLL_FRAMES`, `runtimeScrollFrameBufferReady()`, and the visible-index rule before `memcpy`. `scrollSessionTickCursorLocked` guards `scrollFrameCount==0` and buffer-ready. Safe.
- **Buttons:** `scrollSessionMarkStoppedByButton` (`scroll_session.cpp:194-201`) writes `scrollStopEvent*` and `lastReason` **without** taking `withScrollLock`, unlike every other control-plane function. These fields are Core-0-only event fields, so it is consistent with current behavior (it was already lockless at `buttons.cpp:67`), but it contradicts the sec 4.1 statement that "each [control-plane fn] acquires `withScrollLock` internally." Document the exception or add the lock for uniformity. Low risk.
- **Step:** `scrollSessionStep` (`scroll_session.cpp:109-127`) advances the index and sets `playback="scroll_step"` but never sets `firmwareScrollPaused`. If invoked while running, `scrollSessionTickCursorLocked` continues auto-advancing, so the stepped frame is transient. Either require paused at the command layer or latch pause inside step.

## WebUI Safety Review

- **State variables:** machine state + `scroll{}` backing coexist; `syncPauseBacking`/`setPhase` keep them aligned. Acceptable until Phase 5.
- **Command busy flags:** `scroll.commandBusy` plus per-control `*Busy` serialize scroll commands against each other (pause/resume/step/stop/fps) and guard re-entrancy on rapid clicks (`app.js:8739,8773,8804,8893`). They do **not** block unrelated UI (brightness, battery, mode) — they are scoped to scroll controls, satisfying the "no global busy" goal. Token/epoch machinery (`scrollMachine.token/isCurrent`) provides the correctness layer the plan wanted.
- **Reload recovery:** `RESTORE_BEGIN`/`RESTORE_DONE` rebuild preview from `/api/scroll/meta` sourceText; `device.hasSession` can be true during `RESTORING` (FW_SYNC sets it independent of UI state), so FW_SYNC stays authoritative during restore — matches sec 7.
- **Stop/clear:** does not wipe local preview until the firmware confirms; on unconfirmed stop it logs and restarts the preview timer (`app.js:8823-8826`). Good — satisfies "Stop/Clear should not leave WebUI empty while hardware still scrolls."
- **Pause/resume/step:** synchronized via dispatch + `applyFirmwareRuntimeState`/`applyFirmwareScrollFrameIndex`; step is token-guarded (`isCurrent(stepToken)`, `:8914`).
- **Disabled/enabled states:** driven by `updateScrollUi()` (called in every handler's `finally`).
- **Drift:** see Phase 4 — local timer still writes the cursor while firmware-backed.
- **Housekeeping:** `data/app.js.mine` (a stray merge-conflict copy, *older* content despite newer mtime, lacking `scrollMachine`) sits next to the served `app.js`. `index.html` loads only `app.js?v=20260613-...`. The `.mine` file is dead weight and a footgun if anyone copies it over `app.js`; delete it.

---

## Regression Risks

1. **Preview/LED drift during firmware-backed playback** (Phase 4 gap) — visible frame snap every poll; the very symptom the refactor was meant to fix. Highest-value regression to close.
2. **Step while running** — stepped frame is immediately overwritten by the render tick; "Step Prev/Next while running" test will look broken unless step latches pause.
3. **Manual face display / Auto playback / saved faces / M/A toggle / default face** — preserved: `setMode`, `toggleModeFromButtonAction`, `serviceAutoPlayback`, deferred-restore all intact in `faces.cpp`; scroll stop routes face restore back through `faces.cpp` (sec 4.3 inversion verified at `faces.cpp:244-258`).
4. **Brightness buttons / battery animation during scroll** — brightness path (`buttons.cpp:122-131`) and battery overlay (`button_animations.cpp:365,379` via `scrollSessionSetSystemPaused`) are independent of the scroll lock writers; not blocked by scroll busy flags. Low risk.
5. **M370 upload/apply** — `clearQueuedM370Frames`/`applyPackedFrameImmediate` still used in start/step/stop; `tools/test_m370_boundary.js` parity claim (sec 9) should be re-run to confirm encoding unchanged.
6. **WebUI loading sequence / preview scaling** — unaffected by the machine; render path unchanged.
7. **Stray `app.js.mine`** — risk only if mis-deployed; it lacks the machine and would regress everything.

---

## Required Corrections Before Implementation

> Note: most of these are corrections to *already-written code*, not to an unstarted plan.

1. **Demote the local preview timer (the actual sec-7 fix).**
   - File/fn: `data/app.js` `advanceScroll` (`:8927`) and `restartScrollPreviewTimer` (`:8270`).
   - Problem: both `advanceScroll` (8931) and `applyFirmwareCursor` (3718) write `scroll.frameIndex`; the timer runs during firmware-backed ACTIVE playback, so preview drifts and is snapped on each FW_SYNC.
   - Fix: when `scrollMachine.snapshot().device.hasSession` is true, either (a) do not start the `advanceScroll` interval in `restartScrollPreviewTimer`, or (b) make `advanceScroll` a display-only tween that renders an interpolated frame without writing `scroll.frameIndex`/`scroll.offset`/`machine.cache.frameIndex`. Keep the local timer writing the index only for purely-local (non-firmware-backed) preview.
   - Why: it is the plan's single intended behavior change and headline win; as shipped it is not achieved.

2. **Make `scroll_step` latch a held frame.**
   - File/fn: `web_api.cpp` `commandScrollStep` (`:1084`) and/or `scroll_session.cpp` `scrollSessionStep` (`:109`).
   - Problem: stepping while `firmwareScrollActive && !firmwareScrollPaused` lets the render tick overwrite the stepped frame.
   - Fix: require `firmwareScrollPaused` before stepping (reject otherwise), or set `firmwareScrollUserPaused=true` (effective pause) inside `scrollSessionStep` so the cursor holds. Mirror the gate on the WebUI (only enable step when paused).
   - Why: "Step Prev/Next must stay synchronized with firmware state" — a running step does not.

3. **Reconcile the plan document with the implemented code.**
   - File: `SCROLL_SESSION_REFACTOR_PLAN.md` header + sec 4.1, 8, 13.
   - Problem: "no code moved yet" / "behavior-identical phases 1-3" is false; signatures (`scrollSessionStart`, `scrollSessionStop`, `scrollSessionCommitUpload`, `scrollSessionStep`) and the omitted firmware step function diverge from code; all line numbers are stale.
   - Fix: mark phases 1A-4 as implemented, update signatures to match `scroll_session.h`, add the `scrollSessionStep` row to sec 13.1, and refresh references.
   - Why: the document is meant to be the review contract; a stale contract is worse than none.

4. **Resolve the dead `PAUSE_SYSTEM`/`RESUME_SYSTEM` events.**
   - File/fn: `app.js` reducer (`:3760-3767`) vs `applyFirmwareCursor` (`:3707-3713`).
   - Problem: system pause is mutated directly in FW_SYNC, never via the documented events; the two reducer cases are unreachable.
   - Fix: either route the FW_SYNC system-pause update through `dispatch("PAUSE_SYSTEM"/"RESUME_SYSTEM")`, or delete the dead cases and note in the plan that system-pause is FW_SYNC-driven only.
   - Why: removes a second, undocumented mutation path for the same state (sec 1.3 "single transition path").

5. **Enforce or relax the transition table.**
   - File/fn: `app.js` `dispatch` (`:3730`).
   - Problem: `From`-state constraints in sec 5.2 are not checked; effects apply from any state.
   - Fix: add a `From`-state guard table (drop/ignore events not valid from the current state) so the machine matches its contract; or downgrade sec 5.2 to "effects, not guards" and rely on UI gating explicitly.
   - Why: prevents illegal transitions (e.g. `START_CONFIRMED` arriving in `IDLE`) from silently corrupting `scroll.active`.

6. **Document or unify the lockless `scrollSessionMarkStoppedByButton`.**
   - File/fn: `scroll_session.cpp:194-201`.
   - Problem: it writes runtime fields without `withScrollLock`, contradicting sec 4.1's blanket claim.
   - Fix: either wrap the writes in `withScrollLock` or add an explicit comment + amend sec 4.1 that stop-event fields are Core-0-only and intentionally lockless.
   - Why: keeps the "all control-plane fns take the lock" invariant honest.

7. **Delete `data/app.js.mine`.**
   - Problem: stale merge artifact without `scrollMachine`; deployment footgun.
   - Fix: remove it (and confirm the gzip asset pipeline only targets `app.js`).

---

## Final Implementation Checklist

Run after the corrections above. Firmware: build with `pio run` and `pio run -t buildfs` (the audit did not compile on-device; the sandbox has no ESP toolchain — this must be confirmed locally).

- [ ] `pio run` and `pio run -t buildfs` clean; no duplicate-symbol/link errors.
- [ ] Upload scroll text (single chunk + chunked append): `/api/scroll` returns `uploadComplete` only after all frames; partial chunk never visible.
- [ ] Pause → Resume: `firmwareScrollUserPaused` toggles; local timer stops on pause, restarts on resume (unless system-paused).
- [ ] Step Prev/Next while **paused**: frame holds, index moves by ±1, wraps at 0 and `frameCount-1`.
- [ ] Step Prev/Next while **running**: frame holds (after fix #2) or is explicitly disabled.
- [ ] Reload WebUI while **scrolling**: preview rebuilt from `/api/scroll/meta` sourceText; cursor matches LEDs; **no visible drift/snap** (validates fix #1).
- [ ] Reload WebUI while **paused**: preview restored at the paused index; pause reasons reflected.
- [ ] Stop/Clear: LEDs blank + UI clears together; on dropped command UI keeps preview and resyncs (no empty-UI-while-scrolling).
- [ ] Switch to Manual during scroll (B3/M-A and `/api/command`): scroll stops, current saved face shows.
- [ ] Switch to Auto during scroll: scroll stops, `restoreAutoAfterScroll` engaged, auto playback resumes.
- [ ] Press B1/B2 during scroll: scroll stops, next/prev saved face shows, `scrollStopEvent` recorded in `/api/status`.
- [ ] Press B3 during scroll: mode toggles, scroll stops, `scrollStopEvent` recorded.
- [ ] Network failure during pause/resume/step/stop: command logged as unconfirmed; state recovered on next FW_SYNC; no UI lockup.
- [ ] Rapid repeated clicks on pause/step/stop: serialized by `*Busy`; stale replies dropped by epoch/token (`isCurrent`).
- [ ] Saved-face apply during/after scroll: applies cleanly; no scroll residue.
- [ ] Brightness buttons during scroll: adjust without pausing/interrupting scroll.
- [ ] Battery animation (overlay) during scroll: system-pause composes with user-pause; overlay end does not resume a user-paused scroll.
- [ ] `tools/test_m370_boundary.js` passes (encoding unchanged).
- [ ] Reboot: RAM cache lost; `/api/scroll/meta` reports no frames.
