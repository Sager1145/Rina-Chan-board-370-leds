# App startup and dual-board save acceptance

Date: 2026-10-15. Acceptance is in progress; no commit or push yet.

Current status: all 796 unit tests, the two startup/tab UI tests and the five-board save-picker UI test passed. The 128-face real-BLE test passed and both original libraries were restored. The final coordinator disconnect/retry run still awaits completion. On resuming, the previously authorized test host and its `/tmp` evidence directory had been cleaned; no RinaBoard process survived. The current source is being rebuilt with logs under ignored `build/mac-save-acceptance/` and DerivedData in the persistent workspace artifact directory. Repository-local DerivedData exposed a build-script sandbox output restriction, so intermediate products were moved outside the source tree without disabling sandboxing. The old installed App is not a substitute for current-source acceptance. Recheck actual BLE discovery with the rebuilt host and obtain normal user consent if macOS requests it. Commit/push is authorized only after the coordinator acceptance passes. Other sessions' README, audit and boot-rotation changes must remain untouched. Production source remains unchanged since the passing tests.

## Simulator startup

- Rina IfaceAudit 2 is an iPhone Duo with two integrated displays. Enumeration reports LCD (1398 x 2034) and LCD-1 (2007 x 2853). The default screenshot selected the unused LCD-1 and was black. An explicit screenshot of display 1 shows the complete running App.
- Temporary lifecycle markers confirmed root body, onAppear and startup task execution. A thread sample showed an idle main run loop, not a startup deadlock. Temporary markers were removed.
- The old UI readiness condition expected a TabBar or the retired lightbulb.fill icon. Duo's native vertical rail exposes ordinary buttons and the first tab now has a custom image.
- The App now exposes app.content only after content mounts, plus five stable tab identifiers. The tests retain native TabBar/localized-label compatibility. Startup and all five tabs across supported rotation passed without skipping the readiness assertion or extending its timeout. Final combined verification is recorded below when complete.

## Mac Bluetooth

- Sandbox and the Bluetooth entitlement remain enabled. No permission database was edited.
- Simultaneous old/new processes with the same bundle identity left the new BLE session suspended. Quitting the old App and fully restarting the new App restored real BLE discovery, notifications and telemetry on both physical boards in the unchanged build.
- The XCTest host had a separate authorization identity problem. Its temporary code hash differed from the previously authorized GUI build. TCC rejected that stored designated requirement and delayed the replacement prompt because Xcode launched the host in the background.
- The exact injected test-host build was opened normally in the foreground. It connected to board B with the same code hash that had failed under XCTest. That host was subsequently cleaned from the temporary directory. A replacement build requires a fresh authorization check before live acceptance; the earlier grant is not evidence of authorization for a new hash.

## Save presentation defect found on hardware

- With both boards online, the first Save picker showed 0/0 destinations; canceling and reopening showed 1/2. No save was submitted during reproduction.
- Target selection, naming and results now use item-based sheets carrying immutable presentation data. The submit callback uses the frozen frame, face ID, name, source identity and destination array. Results explicitly record whether to start the prepared operation. Pending single-board names are preserved.
- Independent source review found no remaining presentation defect. Fresh Mac GUI first-open verification passed: both board toggles appeared immediately, current B selected by default (1/2), All selected both (2/2), deselecting A cleared All (1/2), and Continue opened a fresh naming sheet for two boards with the original name. Submission was canceled to preserve the user's editor metadata and pixels. Actual writes use the isolated production coordinator test below.
- Before this GUI check, both live 11-face exports were compared with the original baseline and matched exactly. Evidence: /tmp/rina-app-debug/gui-save-acceptance/A-before.json and B-before.json. No GUI test entry was written.

## Live acceptance method and evidence

The opt-in Mac test calls the production MultiBoardFaceSaveCoordinator over real BLE. Its forwarding transport preserves every real reply; the only injected fault is a real B disconnect before readback, after a genuine committed face_upsert ACK. It checks that A is not resent, B keeps its original ID, a restored journal requires explicit retry, and source-board overwrite creates an independent copy on the other board.

Both exact physical identities receive durable raw backups before any write. Cleanup is independent of test cancellation and restores/compares original JSON records and output state.

The first authorized live run passed the 128-item mixed-library test on both boards, including concurrent reads, reconnect, exact restoration to 11 original faces, unchanged frame and zero refresh failures. Its coordinator fault case failed a probe assertion: the real disconnect canceled the broker send task before the probe could record its terminal callback. A detached probe then confirmed the expected real state (A confirmed, B pending, one real ACK and one upsert per board), but its initial gate waiter was superseded by the carrier's own disconnect cleanup. CoreBluetooth logged the genuine terminal callback immediately afterward. The test now independently waits after coordinator teardown is quiescent. These corrections change test instrumentation only; the coordinator case must pass its next live run before completion.

The first final combined iOS run completed 796 unit tests (5 skipped, zero failures) and both startup/tab UI checks, then Xcode hung collecting simulator diagnostics. A thread sample identified collectSimulatorDiagnostics waiting on a semaphore. Repeating the same assertions with post-test diagnostic collection disabled completed with TEST SUCCEEDED: 796 unit tests (5 skipped, zero failures) and both UI tests passed. No test or timeout was relaxed. Evidence: app-final-verified.log and xcode-finalize-sample.txt.

A separate five-TCP-board UI regression passed (1 test, zero failures): all five destinations on first presentation, current-board default, All on/off, Continue disabled for zero targets, two individual targets, fresh two-target naming, Cancel and fresh default selection on reopening. Captured hierarchy proves native SwiftUI rows contain a separate trailing UISwitch; earlier test taps hit the row center. The test now taps the observed nested switch and waits for its value. No product switch behavior was changed. Evidence: picker-ui-nested-test.log and picker-first-save-hierarchy.txt. All five owned emulator processes were stopped and their ports were verified closed afterward.

Evidence: /tmp/rina-app-debug contains simulator-sample.txt, simulator-system.log, simulator-display1.png, sim-root-test.log, sim-tabs-test.log, app-final-verification.log, hardware-build.log, real-ble-acceptance1.log, real-ble-acceptance2.log and xctest-ble-focused-evidence.log. GUI Bluetooth evidence is /tmp/rina-transfer-review/mac-ble-focused-evidence.log.

Grok's bounded configuration trace reached its turn limit. A subsequent consultation using locally verified facts advised explicit display selection and separating authorization, radio readiness and live link acceptance. Conclusions here rely on local evidence.

Temporary-artifact retention note: the `/tmp` paths above describe the earlier runs and no longer exist after cleanup. Earlier results are historical observations, not newly rerun checks. New build and acceptance logs are retained under ignored `build/mac-save-acceptance/`.

## Resumed build verification

The replacement Mac test host built successfully with Xcode 27.1 RC. Fresh builds exposed an existing Wi-Fi bridge phase defect: its two declared directory outputs were granted only literal-path access, while compilation and codesigning create children and temporary files. Moving DerivedData and adding trailing slashes did not resolve it; the trailing-slash experiment was reverted.

The bridge now compiles and signs under the already permitted `TEMP_DIR`, then copies its three final signed files into explicitly declared output paths and parent directories. `ENABLE_USER_SCRIPT_SANDBOXING` and App entitlements remain unchanged. An independent review found no actionable issue, `bash -n` passed, the Mac build-for-testing succeeded, and `codesign --verify --strict` passed for the published bridge bundle. This follows the build system's [literal output-path contract](https://github.com/swiftlang/swift-build/blob/f06f9127dad0bbe171d2f1885630f5cc330e80ce/Sources/SWBTaskConstruction/TaskProducerSandboxing.swift#L122-L133).

A hardware-opt-out invocation prepared the exact injected test host (one deliberately skipped test, no hardware acceptance claim). Its code hash is `857c33b1aa385df6c374a65f3b937effbb3239c5`. New logs are in `build/mac-save-acceptance/`; the persistent host is under the task's workspace artifact directory, `rina-mac-acceptance-dd/Build/Products/Debug-maccatalyst/RinaBoard.app`. Bluetooth authorization and final live coordinator acceptance remain pending.

The user confirmed the two boards are currently unavailable. Live acceptance is paused for hardware availability; no new board writes, commit or push were performed during this resumed run. Preserve the prepared host and run the remaining coordinator test when both physical boards return.
