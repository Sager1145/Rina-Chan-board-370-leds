# RinaBoard UI stress test — run 2026-09-13 (in progress)

Plan: `docs/STRESS_TEST_UI_PLAN_ZH.md`. Cases: `CASES.csv`. Notes: `logs/notes.txt`. Serial logs: `logs/serial/`.

## Tested version

- HEAD `1e81ff0` plus uncommitted work in the tree, plus this run's fix (`hashes/fix.diff` has the first version; the final version also touches `BoardConnection.swift`).
- App: Debug build from the working tree, installed on iPhone 13 mini (iOS 27, UDID 00008110-000E38321AA2801E) with `devicectl`. Driven through Device Hub with full-screen computer control.
- Boards (BLE):
  - A = `RinaBoard-80B54EF48E09` on `/dev/cu.usbmodem5AE70745091`
  - B = `RinaBoard-80B54EF74801` on `/dev/cu.usbmodem5AE70735521`
  - Both started in manual mode, brightness 50, colour `#f971d4`, face 7 of 11.

## Fix under test: unsaved drawing is discarded on board switch (MB-05)

Implementation:
- `ControlViewModel` records which board a draft belongs to (`draftBoardID`, persisted with the draft).
- On a different board it resets the editor, clears undo and the save target, and deletes the draft file (`boardDidChange`).
- It checks the owner again right before any send (`draftBelongs`).
- Board key is the MAC-derived id from the handshake (`wifi.boardId` or `get_info.defaultName`), falling back to the BLE peripheral UUID or Wi-Fi host (`BoardConnection.boardKey`).
- `RootTabView` calls it on every connection or board change.

Verification:
- Simulator unit tests: 86/86 passed in 9 classes, including 5 new `ControlDraftBoardSwitchTests`.
- Two independent Opus reviews: the first found blocking identity issues (name/IP based), which were fixed; the second accepted with no blocking issues.
- Hardware MB-05: all steps PASS.

| Step | Result | Evidence |
| --- | --- | --- |
| Switch A→B with A's drawing (live preview on) | editor shows B's frame, undo disabled; B received nothing on switch | B `lit=34 lastReason=startup` |
| ② live-preview tap on B | B got a frame built from B's face | B `lit=35 custom_live_send`; A unchanged `lit=2` |
| ③ undo | back to 34, then disabled | — |
| ④ switch with unsent drawing (live preview off), both directions via 控制对象 | drawing gone, editor adopts target board display | A stayed `lit=2 accepted=4` |
| ① Send on B after switch | B got B's frame, not the 5-LED drawing | B `lit=34 custom_face_send` |
| ⑤ force-quit and relaunch | drawing not restored | editor shows B frame |
| Control Center 面板 hot-swap (E2) | B's draft discarded, A adopted | A handshake at …515 |

Residual (non-blocking, from review):
- If both identity reads fail during a handshake, the same board can look different and its draft is discarded.
- After relaunch, a restored adopted frame shows 未傳送. This restore behaviour predates the fix.

## Findings

| Sev | ID | Finding | Evidence |
| --- | --- | --- | --- |
| High | MB-10-DUP-SESSION | Control Center 面板 switch to a board that is already connected in another session creates a second app session on the same BLE link. A gets a second `subscribe`/`get_info` on slot 0, the previous board B is disconnected, and 控制对象 shows "2 块在线" with both rows = A. A single › still stepped once (7→8). | serial A @1789278814; screenshot description in CASES `MB-10-list` |
| Medium | MB-E2-STALE-SESSION | After a Control Center hot-swap B→A, the session keeps B's identity (`boardID`, plus A's peripheral as alias). Tapping B in 已保存的璃奈板 does nothing: no progress, no error, no BLE connect (2 taps). Predicted, not exercised: a scan-row connect to B hot-swaps the same session, and 忘记 B removes the session now connected to A. | `BoardControlCenterView.swift:167-175`, `BoardSessionStore.swift:24-42`, `ConnectionView.swift:199-200`; serial shows no events |
| Info | HW-SERIAL-STALL-A | Board A's USB serial output stopped ~25 s after the app reconnected, while BLE kept working. Reopening the port restored it with no reboot. Likely host/USB CDC side; logger restarted into `board_5AE70745091_r2.log`. | `logs/notes.txt` |
| Info | LAUNCH-ANOMALY | `devicectl process launch --terminate-existing` killed the app but launched nothing. No RinaBoard crash report exists. Use terminate, then a plain launch. | `logs/notes.txt` |

## Not run yet

Everything outside MB-01/05/10 in the plan:
- M-class per-page coverage
- X-class 42-direction source switching
- C-class combinations
- S-class high-volume loops
- L-class lifecycle
- MB-03/04/06–09/11–15 and MB-S*
- D-class (needs per-item approval)

## Side effects so far

- Board A shows a 2-LED test drawing and its face index moved 7→8. Board B shows face 7 (34 lit). No flash-writing operations were used (no mode toggles, library edits or renames).
- Both boards are saved in the app; the phone is connected to A (twice, per MB-10).
- Serial loggers are still running (`log level debug`, reset on reboot).
