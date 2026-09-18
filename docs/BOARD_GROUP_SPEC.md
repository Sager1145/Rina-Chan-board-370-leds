# Board groups v1 — identify, stitched text, synchronized start

Status: implementation spec for branch `feat/board-group` (2026-09-17).
Scope is deliberately small: identify numbers, a 2–5 board group with an
order and gaps, one stitched (or mirrored) text scroll, and a synchronized
start with periodic re-anchoring while the app is in the foreground.
Out of scope for v1: timed pause/speed/seek, board-to-board clock sync,
ESP-NOW, long-text streaming bitmaps, face/lip-sync/video mirroring,
reconnect catch-up beyond "re-anchor on next pass".

All new protocol surface is additive. Old firmware answers
`ERR 400 unknown command`; the app must check `get_info.caps` before using
any of it and must never silently fall back while claiming "synchronized".

---

## 1. Firmware additions (RinaLink v1.2)

### 1.1 `get_info` additions

- `bootId`: string, 8 lowercase hex chars, from `esp_random()` once at boot.
  Changes on every boot / deep-sleep wake.
- `caps`: array of strings. v1 value:
  `["identify","clock_sample","scroll_viewport","group_start"]`.

### 1.2 `CMD identify{number, ttlMs}`

- `number`: integer 1…9. `ttlMs`: 0…30000; `0` cancels. Missing `ttlMs` → 5000.
- Out-of-range → `ERR 400`.
- Effect: a render overlay that **replaces** the whole presented frame with a
  black background and one large digit: a 5×7 digit font scaled ×2 (10×14),
  top-left at logical (x=6, y=2) in the 22×18 grid, mapped through the existing
  logical→LED index map (cells outside the board's valid range are skipped).
  Drawn in the board colour at the current brightness.
- It changes no frame/scroll/face/mode state, writes nothing to flash, does
  not bump `stateVersion`, does not pause anything. Scroll time keeps
  advancing underneath (group playback must not fall behind).
- Expires on its own at `esp_timer_get_time() + ttlMs*1000`, independent of
  any client connection. A new `identify` replaces the previous one (re-arm).
- Priority: identify > set_hint_led hint > button-animation overlay > content.
  While identify is shown the hint and button overlay are not drawn.
- Presented samples produced while it is shown have `rateEligible=false`
  (same mechanism as the existing overlays) and must not advance
  `scrollAdvanceSeq` differently from normal (the scroll cursor still ticks).
- Must be drawn by the existing single render path (`led_renderer.cpp`);
  no new task may call the LED driver. Respect lock order
  Scroll → Frame → Storage → HardwareBus.
- Reply: `{"ok":true,"shown":<bool>,"number":n,"ttlMs":t}`.

### 1.3 `CMD clock_sample{}`

- Reply `{"ok":true,"rxUs":<u64>,"txUs":<u64>,"bootId":"…"}` where both are
  `esp_timer_get_time()`; `rxUs` taken as early as possible when the command
  is dispatched, `txUs` just before the reply is serialized.
- Must not be rate-limited or coalesced by firmware; cheap, no state change.

### 1.4 `BLOB kind:"scroll_bitmap"` viewport extension

New optional BEGIN meta fields:

- `virtualWidth` V: integer 22…200. The width of the whole stitched screen
  (all boards + gaps).
- `viewportX` X: integer 0…V−22. This board's left edge inside the virtual screen.

Rules when **either** field is present (both must be present and valid, else 400):

- `frameCount = max(1, W − V) + 1` (413 if > 3072). W is still 22…3093, and
  W ≥ V is required (400 otherwise).
- Frame `f` (0-based) shows, at board cell (x, y), bitmap pixel
  `(f + X + x, y)`; pixels with column ≥ W are off.
- **No rotation.** END reply reports `"rotation":0`, plus echoes
  `"viewportX":X,"virtualWidth":V`.
- Otherwise identical to today's scroll_bitmap (staging, commit at END,
  `start` flag, timelineId, etc.).

Without the fields, behaviour is exactly unchanged (single-board path keeps rotation).

The client pads: the group bitmap is `[V dark columns][text][V dark columns]`,
so frame 0 and the last frame are fully dark on every board, and every board
has the same frameCount.

### 1.5 `CMD group_start{atUs, bootId, intervalMs, startFrame?, loop?}`

- `atUs`: u64, **this board's** `esp_timer_get_time()` value at which frame
  `startFrame` (default 0) must be latched. `bootId` must equal the board's
  current bootId, else `ERR 409` (`"error":"boot_mismatch"`).
- `intervalMs`: 20…2000. `loop`: default true.
- Requires a loaded scroll timeline, else `ERR 409` (`"no_timeline"`).
- Enters **group-timed playback**: the cursor is computed from absolute time,
  never by per-tick accumulation:
  `elapsed = now − atUs`; if `elapsed < 0` show `startFrame`, held (no
  advance); else `n = startFrame + floor(elapsed / (intervalMs*1000))`;
  frame = `n mod frameCount` when loop, else `min(n, frameCount−1)` and then
  the existing "hold on last frame, paused" behaviour.
  A late tick jumps straight to the correct frame (no catch-up replay, no
  drift rebase).
- **Re-anchoring**: `group_start` while already in group-timed playback on the
  same timeline just replaces (atUs, startFrame, intervalMs, loop) atomically,
  with no restart flash. This is how the app corrects drift.
- Leaves group-timed mode (back to the legacy local timing) on: any
  `start_scroll`, `pause_scroll`, `stop_scroll`, `scroll_seek`, `scroll_step`,
  `set_scroll_interval`, a new scroll upload, a button, or any other output
  taking over — i.e. anything that already ends/changes a scroll today.
  Exception: the brightness buttons (`B4`/`B5`) do not affect scroll timing
  and never exit group-timed mode, matching the physical gpio buttons (which
  never exit group-timed mode for any button).
  (v1 has no timed pause.)
- Status/scroll meta add `"groupTimed":<bool>`. `GET_PREVIEW_SYNC` adds
  `"groupTimed":<bool>`.
- Reply: `{"ok":true,"nowUs":<u64>,"frameCount":n}`.

### 1.6 Tests

Host tests under `esp32s3_firmware/test/host/` in the existing style: a
pure-function test of the group cursor math (negative elapsed, exact
boundaries, loop/no-loop, u64 near wrap is irrelevant — use large values),
viewport frame expansion (frame f at X shows columns f+X…, no rotation,
frameCount identical for all X), identify digit bitmap placement stays
within valid LED cells, plus source-pattern checks that identify is drawn
only inside `led_renderer.cpp` and marks `rateEligible=false`.
Pull the cursor math and viewport expansion into small pure functions (a
header with no Arduino dependencies) so they are testable with `c++ -std=c++17`.

---

## 2. RinaCore (Swift package) additions

- `DeviceInfo`: optional `bootId: String?`, `caps: [String]?`, helper
  `supports(_ cap: BoardCapability) -> Bool` with enum cases
  `identify, clockSample, scrollViewport, groupStart` (raw values as in §1.1).
- `RinaCommand`: cases for `identify(number:ttlMs:)`, `clockSample`,
  `groupStart(atUs:bootId:intervalMs:startFrame:loop:)`; reply structs
  `IdentifyReply`, `ClockSampleReply`, `GroupStartReply`.
- scroll_bitmap BEGIN meta: optional `virtualWidth`, `viewportX`; END reply
  optional echoes.
- `StitchedScreenLayout` (new file):
  `init(slotCount: 1...5, gapsAfter: [Int])` (gapsAfter.count == slotCount−1,
  each 0…8), `virtualWidth`, `viewportX(slot:)`, validation errors.
  Board width is `MatrixGeometry.cols` (22). Do not change MatrixGeometry.
- Group bitmap builder in `ScrollRasterizer` (or a sibling type): from the
  existing text rasterization (same font, same generator), produce the text
  bitmap **without** single-board padding/rotation, then pad
  `[V dark][text][V dark]`. Enforce W ≤ 3093 and frameCount ≤ 3072 with a
  typed error (never truncate silently).
- Pure window sampler: `frame(bitmap:, viewportX:, frameIndex:) -> Frame`
  matching §1.4 exactly, with signed/out-of-range columns → dark. Also a
  reference `virtualCanvasFrame(bitmap:, layout:, frameIndex:)` (V×18) used by
  tests and by the app's group preview.
- `ClockOffsetEstimator`: accumulates samples (m1, b2, b3, m4) where m1/m4 are
  phone monotonic µs; per sample `rtt = (m4−m1) − (b3−b2)`,
  `offset = ((b2−m1)+(b3−m4))/2` (board = phone + offset); estimate =
  offset of the minimum-rtt sample among the last N (default 8);
  exposes `bestRttUs`, `offsetUs`, `boardTime(forPhone:)`, `phoneTime(forBoard:)`.
  Discard all samples when bootId changes.
- `GroupSchedule` pure helper: given per-board estimators and a desired phone
  start time, returns each board's `atUs`; and given a running group anchor
  (phoneAnchorUs, startFrame, intervalMs) returns re-anchor commands.
- Tests (Swift Testing or XCTest, match package style):
  all 120 orderings of 5 boards × a couple of gap configs: each board's
  window frame == the matching crop of the virtual canvas frame (masked to
  the physical LED set), for every frameIndex of a short text; 2/3/4-board
  layouts; CJK + ASCII + spaces; frameCount identical per slot; limits error;
  estimator picks min-rtt sample, handles asymmetric delay, resets on bootId;
  JSON encode/decode of all new commands and replies, including `caps`
  missing (old firmware).

## 3. iOS app additions

- **Identity**: groups store members by `physicalBoardID` = the handshake
  `BoardConnection.boardIdentity`. Never by BLE UUID, host, or name. A board
  appears at most once in a group.
- `BoardGroup` model: `id: UUID`, `name`, `members: [Member]` ordered left→right
  (`physicalBoardID`, `displayName` snapshot), `gapsAfter: [Int]`,
  `mode: .stitched | .mirror`, `layoutRevision: Int`.
  `BoardGroupStore`: persisted as JSON in UserDefaults, observable. Max 5
  members, min 2 to play.
- `BoardGroupCoordinator` (@MainActor, observable):
  - resolves each member to a connected `BoardSession` via `boardIdentity`;
    exposes per-member state: offline / connected / unsupported(caps missing) /
    ready / uploading / playing / error(message).
  - `identifyAll(draftOrder:)`: sends `identify{number: slot+1, ttlMs: 5000}`
    to every connected member; while the layout editor is open, re-sends every
    4 s so numbers follow drags; stops (ttl 0) when the editor closes.
  - `play(text:, fps:, loop:)`: captures (group id, layoutRevision, each
    member's session + connection generation) at start; builds one group
    bitmap (mirror mode: V = 22, every viewportX = 0); uploads
    `scroll_bitmap` with viewport fields and `start:false` to every member
    concurrently through each board's existing BLOB/output-lease path;
    runs 8 clock samples per member (sequential per board, boards in
    parallel); picks phone start `T0 = now + max(400 ms, 3 × worst bestRtt)`;
    sends `group_start` with each board's own `atUs` and `bootId`. After any
    await, if the captured values no longer match (generation changed, group
    edited, cancelled) abort and report — never write to the new group.
  - While playing and the app is active: every 30 s take 4 fresh samples per
    board and re-send `group_start` with the same phone anchor mapped through
    the updated estimate (re-anchoring). On a member reconnect with the same
    timeline, re-anchor it; if bootId changed, mark it "needs re-upload"
    and re-run upload+anchor for that board only against the same phone anchor.
  - `stop()`: `stop_scroll` to all members; cancels timers.
  - An offline member keeps its slot; the virtual width never shrinks
    automatically.
  - Play requires every member online and supported (≥2 members); an
    offline member blocks play (`offlineMembers`) rather than playing a gap.
  - Control target: the 控制对象 menu (Control Center) switches between a
    single board and a group (`ControlTarget`, persisted). With a group
    targeted, the Text tab's send/stop go to the group and pause/step/seek
    are hidden (v1 has no timed pause).
  - Members without all four caps are shown as unsupported and block play
    (clear message), never silently skipped.
- **Do not break single-board flows.** Selecting/focusing a member board in
  the existing UI must not cancel a running group upload: make
  `BoardSessionStore.select(_:)` skip `output.invalidate()` for a session that
  the coordinator currently marks as group-owned, and have the coordinator
  hold/release output leases through `BoardPlaybackCoordinator`. Any single-board
  action on a member ends group ownership for that board (the firmware already
  leaves group-timed mode on those commands).
- **UI** (SwiftUI, Simplified Chinese literals only — do NOT edit
  `Localizable.xcstrings`; a separate session owns localization):
  a "多板组" entry reachable from the Control Center / connection area.
  Screens: group list → group editor (pick 2–5 connected boards, reorder via
  drag / 左移 右移 buttons, per-gap stepper 0…8, 识别编号 button, mode picker
  拼接/镜像) → play panel (text field, speed, loop, 播放/停止, per-member status
  row, a stitched preview drawn from `virtualCanvasFrame` driven by one shared
  clock). Keep it simple and native; match existing app components.
- Tests (RinaBoardTests): group store persistence/migration, coordinator with
  fake connections: capture/abort on generation change, atUs computation,
  unsupported member blocks play, offline slot preserved, select() does not
  invalidate a group-owned session.
