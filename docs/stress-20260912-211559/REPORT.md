# RinaBoard stress test report — 2026-09-12

## Tested version and scope

- Source: HEAD `1e81ff0` plus 28 uncommitted changes, snapshotted at 21:15 (`hashes/`). Firmware `src/` and the protocol doc were byte-identical between snapshot and repo when the firmware harnesses ran.
- Host layers: RinaCore Swift package, firmware parser/senders/queue/events/BLOB/scroll/storage compiled from the real `.cpp` files with faked hardware, iOS app services (see iOS section).
- Real hardware: iPhone 13 mini (iOS 27) running the **already-installed** RinaBoard 2.0.0 (1), connected to the ESP32-S3 board over BLE. The UI was driven through Device Hub with computer control; force-quit/relaunch via `devicectl`; board telemetry over USB serial. The app build on the phone was not rebuilt from the snapshot, so hardware results describe that build.
- Not in scope: `esp32s3_firmware_old`, `legacy`, root previews. `tools/protocol_selftest.py` targets `pico_firmware/rina_protocol.py`, which does not exist (NOT_RUN).
- Case totals from `CASES.csv` (one row per case; repeated runs are not added together): **260 cases — 208 PASS, 48 FAIL, 3 BLOCKED, 1 NOT_RUN**.
  - Baseline: 9 PASS, 1 NOT_RUN. Firmware host: 139 PASS, 30 FAIL (8 defects). iOS host: 43 PASS, 16 FAIL, 2 BLOCKED. Real hardware: 17 PASS, 2 FAIL, 1 BLOCKED (includes the rapid-tap round).

## Headline findings

| Sev | ID | Layer | Finding | Evidence |
| --- | --- | --- | --- | --- |
| Critical | IOS-D6 | iOS app host | App traps on user-typed text: "Rina" + 1364 zero-width joiners (4096 B, 55 frames) passes the text checks but builds a 4305 B BLOB_BEGIN, hitting the codec precondition. Real `TextViewModel.send` path. | `BoardConnection.swift:941` vs `RinaLinkCodec.swift:30`; `StressCrashReproTests/testCrashRepro_TextSendBitmapBeginOverflow` |
| High | IOS-D7 | iOS app host | Face reorder with 128 long (`local_<uuid>`, 42-char) ids builds 5790 B and traps; ≤90 such ids fit. Whether such ids reach the board is unverified. | `BoardConnection.swift:976,994`; `testCrashRepro_FaceReorderOverflow` |
| High | IOS-D1 | iOS app host | Sequence exhaustion: at 256 outstanding requests 1 hangs forever and 1 reply is misrouted; at 512, 257 hang and 255 misrouted; cancel/disconnect don't release them ("leaked its continuation"). | `BoardConnection.swift:530,588`; `StressSequenceTests/testP0_1_SequenceExhaustion` |
| High | IOS-D2 | iOS app host | Stale replies complete new requests after the 2 s quarantine (6/6) and immediately across a reconnect (0.11 s). | `BoardConnection.swift:513-520,538-544`; `testP0_2_*` |
| Medium | IOS-D3 | iOS app host | GET_FACES MORE paging has no cap: 20.8 MiB in 0.25 s; empty MORE pages loop forever at offset 0. | `BoardConnection.swift:756-792`; `testP0_3b_GetFacesPagingWithoutEnd` |
| Medium | IOS-D4 | iOS app host | `unsubscribe` never finishes the event stream (iterating consumer hangs); a paused subscriber buffers without bound (57.6 MiB for 50k logs). | `BoardConnection.swift:351-353`; `testP0_4_SlowEventSubscriber` |
| High | HW-DRAFT-ADOPT | iOS app, hardware | A synced Faces drawing is replaced by the board's current frame (e.g. text scroll), saved as the draft, and undo history is reset — the drawing is lost. Reproduced twice on the phone and in host test IOS-D8 (both adopt paths). | `ControlViewModel.swift` ~495 `adoptBoardFrameIfUntouched`, didSet save at 20/115; `logs/device/draft_repro.txt` |
| High | HW-RAPID-LIVEPREVIEW-DRAFT-LOSS | iOS app, hardware | Same root cause as HW-DRAFT-ADOPT, but reached by ordinary use: with 即時預覽 on (the default) every edit is sent immediately, so the draft always counts as synced; the next board change (an auto-mode face tick or an M toggle) replaces the drawing and disables Undo. Observed after a cleared draft became the board's 46-lit auto face. | `ControlViewModel.swift:63` (`livePreview = true`), ~495; `metrics/device/rapid_taps.csv` |
| High | FW-D1 | firmware host | A partial flash write is committed: reply OK, 200 B left in `saved_faces.json`, board boots with 0 faces. | `storage.cpp:59,106`; `F7-FS-PARTIAL-WRITE-*` |
| High | FW-D4 | firmware host (model) | Face JSON buffer sized too small for the ESP32 16-byte slots: NoMemory from 32 faces (load/blob) and 59 (edit), far below the 128 limit. Modelled, not run on hardware. | `utils.cpp:22`; `F7-CAPACITY-128-FACES-DEVICE` |
| Medium | FW-D5 | firmware host | Frames declaring > 4096 B are skipped without ERR and their payload is rescanned — an embedded SET_FRAME executed. | `inbound_frame.h:28`; `F1-OVERSIZE-PHANTOM-DISPATCH` |
| Medium | FW-D2 | firmware host | Preview/status/Wi-Fi event cursors advance even when the send fails, so a dropped final state is never re-pushed while idle (storm: 65/200 status, 92/200 preview stuck). Explicit queries recover. | `protocol.cpp:2053,2069,2081,2104`; `F4-*` |
| Medium | FW-D3 | firmware host | Raw scroll upload wipes the timeline at BEGIN; abort/disconnect leaves active=1, frameCount=0. Bitmap upload is atomic. | `protocol.cpp:1370` → `scroll_session.cpp:383` |
| Medium | HW-PRESET-RESUME | iOS app, hardware | Performance (演出) tab stops sending frames after a BLE reconnect while audio keeps playing; the resume API exists but the view never calls it. | `PresetLiveModel.swift:363`, compare `VideoPlayerView.swift:212` |
| Low | FW-D6 | firmware host | Truncated frame followed by a valid PING: PING is swallowed, no reply until reconnect (client-bug path). | `inbound_frame.h`; `F1-TRUNC-THEN-VALID` |
| Low | FW-D7 | firmware host | `start_scroll` with 0 frames replies `started:true` while inactive. | `protocol.cpp:1627,1725` |
| Low | FW-D8 | firmware host / doc | Text > 4046 B cannot be sent via `start_scroll` though the doc says 4096; face upserts can grow the file past the 256 KiB re-upload limit. | doc line 153; `protocol.cpp:814` |
| Low | HW-STATUS-VERSION / IOS-D5 | iOS + firmware, hardware + host | Settings "protocol version 944" is `runtimeStateVersion()` (a state counter); a lite EV_STATUS push nils `device`, `uptimeMs` and `wifi` (host-reproduced). | `protocol.cpp:362`; `BoardConnection.swift:414` |
| Low | HW-RSSI | iOS app, hardware | BLE signal strength stays "0 dBm" while connected; RSSI is only read during scan. | `BLETransport.swift:611` |

Characteristic, not a correctness bug: firmware scroll catches up at most one frame per render (`scroll_session.cpp:567`) — 0.903× / 0.744× speed with 16 / 20 ms renders, 0.712× under repeated 80 ms stalls (host F6). On the real board (11 ms refresh) playback was exact.

## Capacity and timing results

| Area | Result |
| --- | --- |
| BLE reconnect after app kill (hardware, 100 cycles) | launch → connect p50 0.62 s, p99 1.05 s; launch → notifications subscribed p50 0.93 s, max 1.04 s; independent of 0–3 s dwell |
| In-app disconnect/reconnect (hardware, 15 cycles) | 15/15 reconnected |
| Live-preview frame floods (hardware) | 40/40 invert frames applied in order; drag flood converged to the final frame (142 lit on UI and board) |
| Firmware scroll soak (hardware, 15 min, battery 58 → 50 %) | 8860 frames at exactly 10.00 fps, 0 drift; heap 90436 B (min 89620, recovered); `refreshFail` 0; `refreshMaxUs` 11099; no resets |
| Scroll during BLE disconnect / app kill (hardware) | playback continued uninterrupted; app resynced to board position within ~2 s |
| Packed frame queue (host F3) | 10–100 Hz offered: latest-only, ≤1 pending, gaps ≥34 ms, ~29.4 Hz presented, final frame always shown |
| Parser fuzz (host F1) | 1e6 iterations each on parser and dispatch path, 0 invariant violations, ASan/UBSan clean |
| BLE/TCP senders (host F2) | ATT 20/182/244/509 and TCP: 3000 frames each, 0 interleaving; worst blocking 375 ms at ATT 20 (250 ms deadline counts stall time only) |

## Rapid taps and mode switching (real hardware)

Driven through Device Hub on the iPhone 13 mini; the board serial log is the reference for what arrived and in which order. Final board state was checked against the UI after the app's 2 s optimistic override expired. Rows in `metrics/device/rapid_taps.csv`.

| Case | Load | Result |
| --- | --- | --- |
| HW-RAPID-M9 | 9 rapid M (auto/manual) taps | PASS — 9/9 `B3` commands, seq contiguous, 9 mode changes, board auto = UI A |
| HW-RAPID-MIXED-12 | › › M ‹ › M › ‹ M ‹ › M | PASS — 12/12 commands in exact tap order; face index path and 4 mode changes correct; board auto = UI A |
| HW-RAPID-CROSSMODE-C1 | cross-tab: random/M/Text Play/invert/›/clear | PASS for mode/ownership only — the Faces taps were invalid (harness used stale coordinates) |
| HW-RAPID-CROSSMODE-C2 | same, corrected | PASS — random ×3, clear, `B3`/`B1` arrived in order; invert superseded by clear (latest-wins); both Play taps pre-empted by the next control tap with no scroll left running; board auto = UI A |
| HW-RAPID-TABS-30 | 30 taps across all 5 tabs | PASS — app PID unchanged, 0 control commands, heap back to 90436 B |
| HW-RAPID-COLORS-8 | 8 colour picks ending on red | PASS — 8/8 `set_color` in pick order; board `#db0839` = UI red |
| HW-RAPID-LIVEPREVIEW-DRAFT-LOSS | clear draft with live preview on, then M | **FAIL** — editor adopted the board's auto face (46 lit, 已同步) and Undo was disabled; see headline table |

Observations:
- No command was dropped or reordered at human tap speed (commands landed 90–210 ms apart; the command pump interval is 120 ms with depth 4). Drop-oldest behaviour was therefore not exercised on hardware — see iOS host P1-a for that.
- The M button sends the firmware toggle `B3`, not an explicit set-mode. It stayed consistent here because nothing was dropped; a dropped or duplicated toggle under congestion would invert the user's intent until the next status reconcile (static, not reproduced).
- Every mode toggle is logged `MODE change … persist=1` (13 flash-persisted mode writes across the M and mixed bursts). Rapid toggling therefore wears flash; consider debouncing the persist.
- Every face-step/mode button also sends a `SCROLL stop` (logged `stopped=0` when nothing was playing) — harmless.
- Heap dipped to 89088 B during the cross-mode burst and returned to 90436 B.

## iOS host stress (P0/P1/P2)

61 cases: 43 PASS, 16 FAIL, 2 BLOCKED (`metrics/ios/cases.csv`, tests in `tools/ios/`, logs in `logs/ios/`). Run on dedicated iOS 26.5 simulators (since deleted) under per-run kill timeouts.

Constants vs the prompt: frame/command/blob/output queue depths and intervals match; request timeout measured 5.04 s; quarantine edge between 1.84 and 2.25 s. The prompt's 64 MiB was only the test's injection limit; the code itself has no cap on MORE aggregation, and each chunk copies the whole buffer (16 MiB took 873 ms on the main actor, 8 → 97 ms per MiB). Not in the prompt: the BLE write queue drops the oldest write beyond 255 queued.

Passed:
- P0-1 at 254 and 255 outstanding: each request completed exactly once with the correct reply.
- P1-a congestion (host: 2 s warm-up + 10 s sample; fake ACK 8 ms): at 100 Hz frames + 20 Hz commands, 516 frames dropped (p99 77 ms) and 116 commands dropped (p99 395 ms), 0 timeouts; the uniquely-marked final frame was always last on the wire. The live-edit path reached 76 quarantined seqs at 100 Hz — with slow real BLE ACKs this may approach IOS-D1 (unverified).
- P1-b: not-writable fails in 8 ms; zero-byte write times out in 320 ms; mid-frame disconnect resumed all 20 pending once; 200 concurrent chunked writes through the serialized queue arrived intact.
- P1-c ownership: 5 phases × 49 directions (42 switches + 7 restarts) × 100 loops = 24,500 iterations, 0 writes from the old producer, 0 leaked leases (the "ACK routed just before takeover" ordering was never actually hit). Paused text session did not advance across 20 reconnects.
- P1-d BLOB stages × cancel/disconnect (10 loops each, not 100): leases, pending requests and permits released; next upload completed in ~5 ms; an unanswered abort ends via forced reconnect at 2.0 s.
- P2 malformed raw bytes: no crash, link recovered (no CRC, so a plausible header can swallow following frames).

Failed besides the headline defects:
- P1-b3 short write: BoardConnection doesn't reset after a partial write; the next frame is swallowed and times out at 5 s. BLE and TCP transports prevent this in practice, so it is a contract gap.
- P2 scroll 3073 frames: no client-side cap; only the rasterizer guards.

Draft adoption (IOS-D8, confirms HW-DRAFT-ADOPT): ADOPT-1 FAIL (synced draft overwritten in memory and `face.json`, undo cleared); ADOPT-2 FAIL only when adoption precedes restore by > 250 ms (the debounced save writes the board frame first) — not shown reachable in a real launch because `restoreDraft` runs before auto-reconnect (RootTabView.swift:179-184); ADOPT-3 PASS — Faces polling is cancelled ~0.67 s after leaving the tab, so on hardware the adoption came from reconnect (RootTabView, any tab) or returning to Faces.

Blocked: OBS-a Performance resume (host repro needs licensed audio; static: RootTabView.swift:120 suspends output on connection change and nothing calls `resumeBoardOutput`); OBS-c RSSI (static: only written on discovery, BLETransport.swift:623/630; scanning stops on connect, :325).

Harness notes: one P1-c run was stopped by mistake and rerun (log 12 recorded); the first P1-b5 run exceeded the 255-seq space and had a parser bug, rerun as log 13; P1-d's `carrier_resets` column includes the initial connect.

## Not tested / blocked

- Wi-Fi/TCP on hardware: BLOCKED — board not discoverable via mDNS and no IP configured.
- Physical LED latency: not measured (no synchronized camera capture); ACK and logical render logs are not treated as display time.
- 30–60 min hardware soak: reduced to 15 min on battery by user decision.
- Face library capacity on hardware: not run, to avoid modifying the user's library; D4 is a host model.
- The iPhone build was not rebuilt from the snapshot.

## Side effects of testing

- The user's unsaved 33-lit Faces drawing was lost while reproducing HW-DRAFT-ADOPT; it was not in the library and could not be restored.
- Board: no flash writes, no library changes, brightness unchanged. `log level trace` was used during the soak and set back to `info` afterwards (board replied `OK log level INFO`; the level is not persisted).
- Final board state (after the rapid-tap round): manual mode, idle, face index 1, colour restored to the original `#f971d4` over serial, BLE still connected to the phone. Before testing it was showing Performance-tab frames (`live_preset`); that playback was not restarted. The iPhone app was relaunched several times and is running.
- One stray tap during cleanup landed on the scroll progress slider and seeked playback from frame 7 to 221 before the stop; no effect beyond that.

Details: `REPORT_device_section.md`, `RUNBOOK.md`, `CASES.csv`, `metrics/`, `logs/`.
