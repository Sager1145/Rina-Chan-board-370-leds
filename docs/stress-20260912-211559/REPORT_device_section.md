# Real hardware (iPhone 13 mini + ESP32-S3 board over BLE) — draft section

Driver: Device Hub on macOS mirroring the iPhone, controlled with Claude computer-use; force-quit/relaunch via `devicectl`; board telemetry via USB serial (`log level debug`, later `trace`, `status` every 10 s).
Installed app: RinaBoard 2.0.0 (1) as already on the phone — **not rebuilt from the snapshot**, so results describe that build, not necessarily the current working tree.
Transport tested: BLE only (MTU 255, interval 24 units). Wi-Fi/TCP not tested on hardware (board not discoverable via mDNS `_rinalink._tcp`; no IP).

| Case | Load | Result | Key numbers |
| --- | --- | --- | --- |
| HW-UI-RECONNECT | 15 in-app disconnect → reconnect via Settings › Connection | PASS 15/15 | board disconnect→resubscribe 2.40–2.49 s incl. fixed 1.2 s wait before tap (first 6 cycles used longer waits) |
| HW-RELAUNCH-100 | 100 × SIGKILL + relaunch, dwell ∈ {0,0.2,0.5,1,2,3} s, seed 20260912, deadline 15 s | PASS 100/100 | launch→connect p50 0.62 s / p99 1.05 s; launch→notify subscribed p50 0.93 s / max 1.04 s; no dwell dependence |
| HW-TAB-SWITCH | 20 tab switches at 0.3 s | PASS | no crash, board unaffected |
| HW-FLOOD-DRAG | 20 rapid drags on Faces grid, live preview on | PASS (converged) | 19 frames applied; final board lit 142 = UI 142; 8 board apply intervals < 33 ms (min 5 ms) — see note |
| HW-FLOOD-INVERT | 40 rapid 反轉 taps, live preview on | PASS | 40/40 applied in order (228/142 alternating), 120–211 ms apart, final 142 = UI |
| HW-SCROLL-PAUSE-TOGGLE | 10 pause/play taps during firmware scroll | PASS | 10 pause events, alternating user=1/0 |
| HW-SCROLL-STEP-BURST | 10 step fwd + 10 step back, no wait | PASS | 20 scroll_step, seq contiguous, wrap 0→324, UI 325/325 = board idx 324 |
| HW-SCROLL-BLE-DISCONNECT | UI disconnect/reconnect during scroll | PASS | scroll continued at 10.0 fps through 6.45 s gap; UI resynced to board position |
| HW-SCROLL-APP-KILL | SIGKILL + relaunch during scroll | PASS | scroll uninterrupted; reconnect 3.96 s after kill; UI within ~2 s of board index |
| HW-SOAK-15MIN | firmware scroll 325 frames @100 ms + bursts above + 10 s status, battery floor 30 % | running | — |

Board health across all of the above: 0 resets / Guru Meditation / watchdog, `refreshFail=0`, `refreshMaxUs` 11099, `heapFree` 90852 → 90436 after scroll start (−416 B, then flat), `largestBlock` 8126452.
Battery (not charging): 70 % (7.77 V) → 54 % (7.56 V) in ~16 min with up to 228 LEDs lit at brightness 50.

Notes
- The 8 sub-33 ms board apply intervals in HW-FLOOD-DRAG are `apply_packed` log timestamps, not measured LED presentation; whether the 33 ms minimum applies to presentation rather than acceptance is covered by the firmware host case F3.
- Harness bug (not a product bug): first 100-cycle attempt failed at cycle 0 because options were placed after the bundle id in `devicectl process launch`; fixed and rerun, attempt not counted.
- `soak_guard.py` reports each anomaly line up to twice (it re-scans a 600-byte tail); de-duplicated in analysis.

Observed product issues on hardware (code-traced, no automated repro yet)
1. Performance (演出) tab does not resume board output after a BLE reconnect while music keeps playing — `resumeBoardOutput` exists (PresetLiveModel.swift:363) but PresetLiveView never calls it (VideoPlayerView.swift:212 does).
2. Settings shows "protocol version 944": the firmware's `version` field is `runtimeStateVersion()` (protocol.cpp:362, state.cpp:142), a state-change counter. The device row is empty because lite `EV_STATUS` pushes omit `device` and `BoardConnection.applyStatus` replaces the whole status (BoardConnection.swift:414).
3. BLE "signal strength 0 dBm" while connected: RSSI is only captured during scan (BLETransport.swift:611); never read after connect.
4. Synced face drawing replaced on disk: the Faces draft was 33 lit / 已同步; the text-scroll tab then started firmware scroll; after SIGKILL + relaunch the draft was a different 7-lit frame / 未傳送, identical again after a second relaunch (so it is the persisted draft, not a live board sample).
   - Ruled out: debounce loss — every `draftFrame` change, undo included, persists after 250 ms (ControlViewModel.swift:115-137) and the last undo was many seconds before the kill.
   - Ruled out: frame pulled at connect — board log after both relaunches shows only `subscribe` + 2× `get_info` in the first 4 s, no apply/get_frame (logs/device/serial_realhw2.log offsets 350392, 401977).
   - **Confirmed on hardware (HW-DRAFT-ADOPT, FAIL):** sent the 7-lit draft (已同步), started text scroll, returned to Faces: the editor showed "面板正在播放：滾動文字" with live board frames (lit 51 → 48) and Undo disabled; after SIGKILL + relaunch the persisted draft was the scroll glyph "R" (20 lit, 未傳送). A synced drawing is replaced by whatever the board shows, that frame is saved as the draft, and undo history is reset — the drawing cannot be recovered.
   - Mechanism: `adoptBoardFrameIfUntouched` (ControlViewModel.swift ~495) assigns `draftFrame` whenever `!hasUnsentChanges` and calls `resetUndoHistory()`; the `draftFrame` didSet schedules the normal 250 ms save (lines 20, 115). After relaunch `restoreDraft` sets `lastSentFrame` empty (line 105), so the restored frame counts as unsent and adoption stops — which is why the second relaunch in repro 1 was identical.
   - Test-induced data loss: this reproduction overwrote the user's original 33-lit drawing; it was not in the face library and cannot be restored.
   - Minimal fix suggestions: follow the board in the preview only (don't write `draftFrame`/persist) unless the user opts in, or keep the user's last draft as an undo checkpoint before adopting. Host repro requested as IOS-DRAFT-ADOPT-1..3.
