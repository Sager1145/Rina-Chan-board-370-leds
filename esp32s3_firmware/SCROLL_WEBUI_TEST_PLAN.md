# Rina-Chan Board -- Automated WebUI / Firmware Test Plan

Target: an autonomous AI agent that joins the board's Wi-Fi, opens the WebUI, exercises
every function, and verifies results against firmware ground truth.

This plan is written to be executed by an agent with:
- An OS-control tool (to join Wi-Fi) -- e.g. computer-use.
- A browser-automation tool (to drive the WebUI DOM) -- e.g. Claude in Chrome.
- An HTTP client (to read `/api/status` etc. as the source of truth) -- e.g. fetch/curl.

Core principle: **drive the UI, assert on the firmware.** Every UI action is verified by
polling `/api/status` (and `/api/scroll/meta`) and comparing explicit JSON fields. The LED
matrix preview is a `<canvas>` and cannot be pixel-asserted reliably, so correctness is
judged by firmware state + DOM state, not by reading pixels.

---

## 1. Device facts (from firmware source)

| Item | Value | Source |
|---|---|---|
| Wi-Fi mode | SoftAP (the board IS the access point) | `web_api.cpp:1392` |
| SSID | `RinaChanBoard-V2` | `config.h:4` |
| Password | `rinachan` | `config.h:5` |
| Board IP / gateway | `192.168.1.14` | `config.cpp:3-4` |
| Subnet | `255.255.255.0` | `config.cpp:5` |
| Captive domain | `rina.io` | `config.h:6` |
| WebUI base URL | `http://192.168.1.14/` (or `http://rina.io/`) | static server |

### 1.1 HTTP API surface (all JSON, CORS-enabled)

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/status` | GET | Full runtime state (poll for assertions). `?summary` for the light payload. |
| `/api/scroll` | POST | Upload scroll frame sequence (chunked). |
| `/api/scroll/meta` | GET | Timeline meta + `sourceText` (reload-restore path). |
| `/api/command` | POST | All commands (body `{ "cmd": "...", ...payload }`). |
| `/api/power` | GET | Battery/power telemetry. |
| `/api/frame` | POST | Direct frame push (M370). |

Command names (`cmd` field): `start_scroll`, `scroll_step`, `pause_scroll`,
`resume_scroll`, `stop_scroll`, `set_scroll_interval`, `pause`, `resume`, `button`,
`set_mode`, `set_brightness`, `set_color`, `set_auto_interval`,
`terminate_other_activities`, `battery_overlay`, `reset_battery_min`, `reset_battery_max`.

### 1.2 Status fields used as assertion ground truth

From `/api/status` (and echoed in every `/api/command` reply):
`firmwareScrollActive`, `firmwareScrollPaused`, `firmwareScrollUserPaused`,
`firmwareScrollSystemPaused`, `restoreAutoAfterScroll`, `scrollFrameCount`,
`scrollFrameIndex`, `scrollIntervalMs`, `scrollTimelineId`, `scrollUploadComplete`,
`scrollHasSourceText`, `mode` (`"manual"`/`"auto"`), `playback`
(`"scroll"`/`"scroll_paused"`/`"scroll_step"`/`"auto_saved_face"`/`"idle"`/...),
`brightness`, and `scrollStopEvent{ seq, ms, button, source, reason }`.

From `/api/scroll/meta`: `ok`, `hasSourceText`, `sourceText`, `sourceTextBytes`,
`scrollTimelineId`, `fontId`, `generatorVersion`, `frameCount`, `frameIndex`, `uiFps`,
`firmwareScrollActive`, `firmwareScrollPaused`.

### 1.3 WebUI DOM handles (verified in `index.html`)

Navigation/pages: `#nav`, pages `#page-basic`, `#page-scroll`, `#page-custom`,
`#page-parts`, `#page-debug`.

Scroll page (`#page-scroll`): input `#scroll-text`; controls `#scroll-play` (start),
`#scroll-pause`, `#scroll-stop`, `#scroll-step-prev`, `#scroll-step-next`; speed
`#scroll-speed`, `#scroll-speed-range`, `#scroll-speed-minus`, `#scroll-speed-plus`,
`#scroll-speed-presets`, `#scroll-speed-reset-default`; readouts `#scroll-state`,
`#scroll-frame-index`, `#scroll-restore-warning`; progress `#scroll-upload-progress`,
`#scroll-upload-bar`, `#scroll-upload-label`; preview canvas `#matrix-scroll`.

Basic page: `#mode-toggle` (M/A), `#face-prev`, `#face-next`, `#brightness-input`,
`#brightness-range`, `#brightness-minus`, `#brightness-plus`,
`#brightness-reset-default`, `#auto-interval`, `#badge-battery*`.

Debug page GPIO simulator (drives the same code path as physical buttons):
elements with `data-gpio` = `B1`, `B2`, `B3`, `B4`, `B5`, `B3B1`, `B3B2`, `B6S`
(battery overlay single-shot), `B6L`, `B6B3`.

Hardware button semantics: B1 = next saved face, B2 = prev saved face, B3 = M/A mode
toggle, B4 = brightness down, B5 = brightness up, B3+B1 / B3+B2 = auto-interval down/up,
B6 = battery overlay. B1/B2/B3 must stop an active scroll and record a `scrollStopEvent`.

---

## 2. Test harness contract

### 2.1 Connect to the board (OS action)

1. Use the OS-control tool to open Wi-Fi settings and join SSID `RinaChanBoard-V2`
   with password `rinachan`.
2. Confirm association: the host gets an IP on `192.168.1.x` and `GET http://192.168.1.14/api/status`
   returns HTTP 200 with `{ "ok": true, ... }`.
3. If the host cannot script OS Wi-Fi, require the operator to pre-join the AP; the agent
   then starts at step 2. Do NOT proceed to UI tests until step 2 passes.

> Note: a browser-automation tool alone cannot join Wi-Fi (that is an OS-level action).
> Joining must come from computer-use or a pre-connected host. The captive-portal redirect
> to `rina.io` may appear on join; dismiss it and navigate to `http://192.168.1.14/`.

### 2.2 Open the WebUI

1. Navigate the browser to `http://192.168.1.14/`.
2. Wait for boot: poll until `document.body.dataset.page` is set and `#nav` is visible
   (the first-page reveal waterfall has run). Allow up to 15 s (fonts + runtime read).
3. Sanity: `GET /api/status` `ok===true`; record `mode`, `playback`, `brightness`,
   `scrollFrameCount` as the baseline.

### 2.3 Assertion helpers (pseudocode the agent implements)

```
getStatus()            -> JSON of GET /api/status
cmd(name, payload={})  -> POST /api/command {cmd:name, ...payload}; returns reply JSON
meta()                 -> JSON of GET /api/scroll/meta
click(sel)             -> browser click on CSS selector
type(sel, text)        -> browser set input value + fire 'input'

waitFor(fn, timeoutMs=4000, pollMs=250):
    repeat until fn(getStatus()) truthy or timeout; return last status

assert(cond, msg): record PASS/FAIL with msg and the status snapshot
```

Timing: the scroll status poll on the device runs ~500 ms while on the scroll page, so
allow >=1 s (>=2 poll cycles) before asserting UI-reflected state. Always re-read
`/api/status` directly for ground truth rather than trusting DOM text alone.

### 2.4 Standard reusable payloads

- Upload a known 8-frame timeline (single chunk) for deterministic tests:
  `POST /api/scroll` with `{ "frames": [ ...8 valid M370 strings... ], "timelineId":"T-TEST",
  "fontId":"ark12", "generatorVersion":"test", "sourceText":"TEST", "totalFrames":8,
  "fps":10, "start":false }`. (Reuse a known-good M370 frame string from
  `tools/test_m370_boundary.js`.) Easiest path: enter text in `#scroll-text` and click
  `#scroll-play`, then read back `scrollFrameCount` to learn the real frame count `N`.

---

## 3. Test suites

Each test lists: precondition, action (UI), assertion (firmware/DOM), and pass criteria.
Run suites in order; T1 establishes a session reused by later tests. Reset between
independent tests with `cmd("stop_scroll", {clear:true, restoreAuto:false})`.

### T0 -- Connectivity & boot
- T0.1 `GET /api/status` returns 200 `ok:true`. PASS if reachable.
- T0.2 WebUI loads; `#page-basic` content visible; no uncaught console errors
  (read browser console). PASS if page renders and console has no `SyntaxError`/`TypeError`.
- T0.3 Baseline capture: store `mode`, `playback`, `brightness`.

### T1 -- Upload scroll text
- Pre: on `#page-scroll` (click nav to scroll page).
- Action: `type("#scroll-text", "HELLO RINA")`; `click("#scroll-play")`.
- Assert (poll `/api/status`):
  - `scrollFrameCount > 0`, `scrollUploadComplete === true`, `scrollHasSourceText === true`.
  - `firmwareScrollActive === true`, `firmwareScrollPaused === false`, `playback === "scroll"`.
  - `meta().sourceText === "HELLO RINA"`, `meta().scrollTimelineId` non-empty.
  - `#scroll-state` text shows a running/playing state; `#scroll-upload-progress` completes.
- Pass: all true. Record `N = scrollFrameCount` and `TID = scrollTimelineId`.
- Negative: re-`click("#scroll-play")` does not error; partial frames never visible
  (`scrollFrameCount` only ever equals 0 or `N`, never an intermediate during upload).

### T2 -- Pause / Resume
- Pre: T1 running.
- T2.1 Pause: `click("#scroll-pause")`. Assert `firmwareScrollUserPaused === true`,
  `firmwareScrollPaused === true`, `playback === "scroll_paused"`. `scrollFrameIndex`
  stops advancing across 2 polls (read twice ~1 s apart; value unchanged).
- T2.2 Resume: `click("#scroll-pause")` (or `#scroll-play`). Assert
  `firmwareScrollUserPaused === false`, `firmwareScrollPaused === false`,
  `playback === "scroll"`, and `scrollFrameIndex` advances again across 2 polls.
- Pass: both transitions verified.

### T3 -- Step Left / Right  (verifies audit fix #2: step latches a held frame)
- T3.1 Step while paused: from T2.1 paused state, read `scrollFrameIndex = i`.
  `click("#scroll-step-next")` (right arrow). Assert new `scrollFrameIndex === (i+N-1) % N`,
  because the right arrow means **the text moves right visually**, not "increase the
  frame number". Increasing `scrollFrameIndex` moves the source window right, which makes
  the text appear to move left. Assert `playback === "scroll_step"` and frame index is
  **stable** across 2 polls (held). `click("#scroll-step-prev")` (left arrow) -> index
  back to `i`.
- T3.2 Boundary wrap: right arrow at index 0 -> `N-1`; left arrow at index `N-1` -> `0`.
- T3.3 Step while running: resume (T2.2), then `click("#scroll-step-next")`. Assert the
  step now **latches pause**: `firmwareScrollUserPaused === true`,
  `firmwareScrollPaused === true`, and the stepped `scrollFrameIndex` is stable across
  2 polls (does NOT keep auto-advancing). This is the corrected behavior; a regression
  would show the index still incrementing on its own.
- Pass: stepping moves exactly one frame and the frame holds in all cases.

### T4 -- Reload WebUI while scrolling / paused  (restore + anti-drift, fix #1)
- T4.1 Reload while running: with T1 running, reload the browser tab
  (`navigate http://192.168.1.14/`, go to scroll page). Assert:
  - `#scroll-text` is repopulated from `meta().sourceText`.
  - `scrollFrameCount === N`, `scrollTimelineId === TID`.
  - No `#scroll-restore-warning` for an exact-match restore (same font/generator).
  - Preview resumes; firmware remains `firmwareScrollActive === true`.
- T4.2 Anti-drift: while running and on the scroll page, sample `scrollFrameIndex` from
  `/api/status` 5 times at ~600 ms intervals; it must be **monotonic mod N** (only
  forward, wrapping), never jumping backward. The local preview must not race ahead and
  snap back. (Ground-truth firmware index is the reference; the preview is a display-only
  tween re-anchored each sync.)
- T4.3 Reload while paused: pause (T2.1), reload, go to scroll page. Assert restored
  state shows `firmwareScrollPaused === true` and the preview holds at `meta().frameIndex`.
- Pass: text/preview restored; index never moves backward; paused restore holds frame.

### T5 -- Stop / Clear  (UI must not blank while hardware still scrolls)
- Pre: T1 running.
- Action: `click("#scroll-stop")`.
- Assert: after the command confirms, `firmwareScrollActive === false`,
  `firmwareScrollPaused === false`, `scrollFrameCount === 0`, `playback` becomes
  `"idle"` or `"auto_saved_face"` (depending on restoreAuto), display blanked then face
  restored. The WebUI preview must NOT be cleared *before* the firmware confirms (observe
  that `#matrix-scroll` keeps the last frame until the stop reply arrives).
- Negative (dropped command): simulate by stopping with the network briefly blocked
  (see T8); UI keeps the local preview and logs "unconfirmed", does not blank.
- Pass: LEDs and UI clear together on success; no empty-UI-while-scrolling.

### T6 -- Switch to Manual / Auto during scroll
- Pre: T1 running.
- T6.1 To Manual: go to `#page-basic`, `click("#mode-toggle")` to Manual (or
  `cmd("set_mode",{mode:"manual"})`). Assert scroll stops
  (`firmwareScrollActive === false`), `mode === "manual"`, current saved face shows
  (`playback === "idle"`/face), and the matrix shows a face not a scroll.
- T6.2 To Auto: start scroll again (T1), toggle to Auto. Assert `mode === "auto"`,
  scroll stopped, `restoreAutoAfterScroll` handled, auto playback resumes
  (`playback === "auto_saved_face"`, `scrollFrameCount` 0).
- Pass: clean mode takeover, scroll cleared, correct face/auto behavior.

### T7 -- Hardware buttons B1 / B2 / B3 (via Debug GPIO simulator)
- Pre: T1 running. Open `#page-debug`.
- T7.1 B1 during scroll: click `[data-gpio="B1"]`. Assert scroll stops
  (`firmwareScrollActive === false`), a **new** `scrollStopEvent.seq` (greater than before)
  with `scrollStopEvent.button === "B1"`, and the next saved face is shown.
- T7.2 B2 during scroll: restart scroll, click `[data-gpio="B2"]`. Assert stop +
  `scrollStopEvent.button === "B2"` + previous saved face.
- T7.3 B3 during scroll: restart scroll, click `[data-gpio="B3"]`. Assert mode toggled,
  scroll stopped, `scrollStopEvent.button === "B3"`.
- T7.4 (optional, physical) Repeat T7.1-3 with real GPIO presses if a tester is present;
  expect identical `scrollStopEvent`s with `source` = `"gpio"`.
- Pass: each button stops scroll, records the stop event, and applies the correct action.

### T8 -- Network failure during a command
- Pre: T1 running.
- Action: issue a command (e.g. pause) with connectivity briefly interrupted (disable the
  host Wi-Fi for ~3 s right after the click, or point the browser at a dead port for one
  request). 
- Assert: the WebUI logs the command as unconfirmed, does NOT lock the UI, keeps the
  current preview, and recovers correct state on the next successful `/api/status` poll
  after reconnect (state matches firmware).
- Pass: graceful degradation, no stuck busy state, eventual convergence.

### T9 -- Rapid repeated clicks (idempotency / token guard)
- Pre: T1 running.
- Action: click `#scroll-pause` 5 times within 1 s; then `#scroll-step-next` 5 times fast;
  then `#scroll-stop` twice fast.
- Assert: no error toasts; final firmware state is consistent (e.g. ends paused once, not
  oscillating); `scrollFrameIndex` advanced by at most the number of accepted steps; only
  one effective stop. Stale replies are dropped (no backward index jumps).
- Pass: commands serialize cleanly; state is deterministic and consistent.

### T10 -- Saved face apply during / after scroll
- T10.1 During scroll: while running, on `#page-basic` click `#face-next`. Assert scroll
  stops and the selected saved face is applied (`playback` not a scroll value,
  `scrollFrameCount === 0`).
- T10.2 After stop: from cleared state, `#face-next`/`#face-prev` cycle saved faces;
  `mode` stays manual; no scroll residue.
- Pass: face apply is clean before/after scroll.

### T11 -- Brightness during scroll (must not interrupt scroll)
- Pre: T1 running.
- Action: on `#page-basic` adjust `#brightness-range` / click `#brightness-plus` /
  `#brightness-minus`.
- Assert: `brightness` changes in `/api/status`; scroll keeps running
  (`firmwareScrollActive` stays true, `scrollFrameIndex` keeps advancing). Brightness does
  not pause or stop scroll.
- Pass: brightness independent of scroll.

### T12 -- Battery overlay (system pause composability, fix #4)
- Pre: T1 running, then pause via user (T2.1) so `firmwareScrollUserPaused === true`.
- T12.1 Trigger overlay: on `#page-debug` click `[data-gpio="B6S"]` (battery overlay
  single-shot) or `cmd("battery_overlay",{singleShot:true})`. During overlay assert
  `firmwareScrollSystemPaused === true` and `firmwareScrollPaused === true`.
- T12.2 Overlay ends: after it finishes, assert `firmwareScrollSystemPaused === false`
  but, because the user pause is still set, `firmwareScrollUserPaused === true` and
  `firmwareScrollPaused === true` (scroll stays paused -- composable pause did not
  collapse). Resume (T2.2) then clears both.
- T12.3 Overlay while running (no user pause): from running, trigger overlay; assert
  system-pause during, and full resume to running after (`firmwareScrollPaused` back to
  false). 
- Pass: system and user pause compose; overlay end never resumes a user-paused scroll.

### T13 -- State-machine / transition guards (fix #5)
- T13.1 Start gap: during upload-then-start, observe that playback is not marked active
  until start is confirmed (no window where `playback==="scroll"` while
  `scrollUploadComplete===false`).
- T13.2 Illegal/stale events: after a stop, a late upload/start completion must not revive
  scroll (verify by rapid stop immediately after a start; final state stays stopped).
- Pass: no illegal transition revives or corrupts scroll state.

### T14 -- Regression sweep (must still work)
- T14.1 Manual face display: in manual mode, faces show and persist.
- T14.2 Auto playback: in auto mode with multiple saved faces, faces rotate at
  `autoIntervalMs`.
- T14.3 Default face after stop: stop+clear with restoreAuto -> default/startup face shows.
- T14.4 Auto-interval buttons: `[data-gpio="B3B1"]`/`[data-gpio="B3B2"]` change
  `autoIntervalMs` down/up.
- T14.5 M370 direct: `POST /api/frame` with a valid M370 renders without disturbing an
  idle scroll cache.
- T14.6 Battery telemetry: `GET /api/power` returns voltage; `#badge-battery` updates.
- Pass: all baseline features unaffected by the refactor.

---

## 4. Reporting format

For each test, the agent emits:

```
[T<id>] <name>: PASS | FAIL
  action:   <what was clicked/posted>
  expected: <field=value, ...>
  observed: <field=value, ...>   (from /api/status or /api/scroll/meta)
  note:     <timing, retries, anomalies>
```

End with a summary table (test id, status, key observed fields) and an overall verdict.
Attach the raw `/api/status` JSON captured at each assertion point for traceability.

### 4.1 Pass/fail gate
- All of T0-T7, T10-T12, T14 must PASS for a release-candidate build.
- T8, T9, T13 are robustness gates; a FAIL is a high-priority bug, not a hard blocker.
- Any FAIL in T3.3 (step latch), T4.2 (anti-drift), or T12.2 (pause composability) is a
  regression of an audit fix and must block.

---

## 5. Notes, limits, and prerequisites

- **Wi-Fi join is an OS action.** A browser tool cannot do it; use computer-use or a
  pre-joined host. The board is the AP, so the host loses internet while connected.
- **Single-threaded server.** The ESP serves one request at a time; keep concurrency low
  (no parallel floods) or expect 503/timeouts that are not bugs.
- **Preview is a canvas.** Do not assert pixels; assert firmware state + DOM text
  (`#scroll-state`, `#scroll-frame-index`) instead.
- **Frame-exact drift checks** rely on `/api/status` `scrollFrameIndex` as truth; the
  on-screen preview is a display-only tween and may differ by a frame between polls by
  design (it re-anchors on each sync) -- only a *backward* jump in the firmware index, or
  preview that diverges and never re-anchors, is a failure.
- **Physical-only items** (true GPIO presses, real battery sag) need a human or a rig; the
  Debug GPIO simulator (`data-gpio`) covers the same firmware code paths for automation.
- **Determinism:** always reset between independent tests with
  `cmd("stop_scroll",{clear:true,restoreAuto:false})` and re-verify `scrollFrameCount===0`.
- **Build/parse precheck (host-side, before flashing):** run `node --check data/app.js`
  and `pio run` locally; the WebUI must parse and the firmware must compile before any
  on-device run.
```
