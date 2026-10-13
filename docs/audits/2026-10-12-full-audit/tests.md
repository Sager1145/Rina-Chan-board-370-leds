# Test software audit — completed assigned scope

Reviewed: all 6 UI tests, all 3 FaceSync Swift tests plus guard_test.cpp, all 43 RinaCore tests, and app tests 0-30 alphabetically. See /tmp/rina-audit-tests-reviewed.txt for exact file list. App tests 31-60 assigned to another worker.

## Candidate testing defects (verify against production and suite configuration)
- UI `SnapshotAcceptanceUITests.swift:42-57`: `testRinaBackgroundStarReferenceFrame` only captures an attachment; no visual comparison or star-specific assertion. If the background star disappears, the test remains green. This is a coverage gap, not a proven product bug.
- UI `DualBoardStressUITests.swift:149-177, 441-478`: random routing walk logs expected board but does not read board output or assert response after actions. Could pass while a command is routed to the wrong board. Needs a device output oracle; mark as coverage gap.
- UI `SettingsAdaptiveLayoutUITests.swift:39-44`: fixed 1.5 s sleeps to settle rotation make the layout test timing-dependent under load; wait on a concrete layout/page state. Potential flakiness, no reproduced failure.
- FaceSync `BoardFixTests.swift:143-157`: settings-only redeploy scenario keeps identical document content; cannot demonstrate that a changed startup setting with unchanged vector is accepted. Coverage gap; add changed `startupDefaultId` and assert committed projection.

## Adjudication
Parent checked decisive source and execution evidence. Findings about permutations, stale-reply ordering, private test models, lifetimes and sensitivity locks are test assurance gaps; they do not establish corresponding product bugs. Diagnostic performance measurements are not an asserted gate for the measure path. UI selector drift is reproduced. Timing/isolation concerns without a failing reproduction remain lower confidence.

## Core batch 7-13
- PROVEN TEST DEFECT: `GroupScrollBitmapTests.swift:191-225` says it tests all 120 board orderings, but every computed `matchesBySlot` value is independent of `ordering`; the loop over permutations only compares a set to itself and repeats the same precomputed booleans. Any bug in mapping ordered board identities to slots remains invisible. Fix by construct layout/frame assignments from each ordering and assert per-board frame/viewport matches expected slot; or rename scope to slot math and add a separate mapping test.

## Core batch 14-20
- PROVEN TEST DEFECT: `LipSyncDSPEnginePerformanceTests.swift:80-93` `testMeasureVoicedWindowRatio` prints ratios but has no assertion even in release with `RINA_PERF_GATE=1`; any performance regression passes. Add a ratio bound comparable to the analyze gate, or name it a diagnostic benchmark outside the gate.
- Existing `LipSyncTests.swift` thoroughly covers analyzer classification/mapping but does not exercise the app model's live edit-to-board synchronization path described by the feature reviewer. Need inspect app tests for that path before reporting a gap.

## App batch 0-11
- PROVEN TEST DEFECT: `BLETransportGateRecoveryTests.swift:166-213` tests superseded attempt single-flight logic using a private `SingleFlightSlot` defined only in the test, not the production `BLETransport.connect()` state. Production could regress and the test would still pass. Extract the actual bookkeeping to a testable seam, or run a gated BLETransport lifecycle test.
- POTENTIAL FLAKINESS/WEAK ORACLE: `BLEDisconnectGateTests.swift:10-22, 49-60` and `BLETransportGateRecoveryTests.swift:110-160` use 10ms sleeps to assume a spawned waiter has parked. If it has not, the tests may pass via the already completed state and fail to prove waiter wake behavior. Expose a registration signal or use a deterministic gate in the test.

## Completed inventory update
Reviewed all 6 UI Swift tests, all 43 RinaCore Swift tests, all 3 FaceSync Swift tests and `guard_test.cpp`, and alphabetical app test files 0–30 (31/61), through `DebugSerialMonitorTests.swift`. Other worker owns app files 31–60. Ledger: `/tmp/rina-audit-tests-reviewed.txt` (84 entries). No test/source edits.

## Additional proven test defects
- `ios/RinaBoardUITests/RinaBoardUITests.swift:31-39`: the Control-to-library smoke test claims each face row is a `Button` and queries `app.buttons` whose label contains `预设`. Current `ios/RinaBoard/Features/Faces/FaceLibraryView.swift:285-321` renders row as `HStack` with `预设` as a `Text` child and only separate edit/send buttons. Parent UI smoke run fails exactly at line 39 after navigation succeeds. Replace the stale button-role query with a stable row accessibility identifier (or `staticTexts` if content existence is the intended oracle); avoid relying on built-in preset content if the test only checks navigation.
- `ios/RinaBoardTests/ControlEventRefreshTests.swift:329-348,426-433`: named overlap test changes `transport.displayFrame` to the newer frame while first GET_FRAME is in flight, but fake reads `displayFrame` after every response delay. The older request therefore also replies with the newer frame, so the test stays green even if an older response can overwrite a newer one. Capture reply payload at request time and control release order with two gates; assert final draft after old response arrives last.
- `ios/Packages/RinaCore/Tests/RinaCoreTests/GroupScrollBitmapTests.swift:12-16`: tracked font fixture missing yields `XCTSkip`, hiding a packaging/path regression as a skipped test. Fail on missing fixture, as other fixture loaders in this package do.

## App test pollution and gaps
- `ios/RinaBoardTests/BoardResumeModeTests.swift:136-149`: router test removes `PerformanceTabMode.storageKey` from `UserDefaults.standard` at start and teardown, discarding a pre-existing user/app preference and potentially influencing parallel tests. Save and restore old value, or inject an isolated defaults suite into AppRouter.
- `ios/RinaBoardTests/BoardSyncCoordinatorTests.swift:233-250`: every `makeDeps` creates a named persistent UserDefaults domain without removing it; also falls back to `.standard` if creation fails. Keep suite names for teardown and require a non-nil isolated suite, avoiding persistent residue or accidental shared-state writes.
- `ios/RinaBoardTests/DebugSerialMonitorTests.swift:39-78`: send tests check reply/log formatting, but never assert output lease ownership or that a query preserves current playback. Feature review found `DebugViewModel.sendMonitorCommand` claims `.debug` for `get_info`, and `RootTabView` stop handlers pause/stop the previous producer. Add a production integration test starting text/media, issuing read-only monitor query, and asserting previous producer remains active; currently this product regression is not caught here.
- `ios/RinaBoardTests/BoardGroupTests.swift` has broad real coordinator+transport coverage for routing, reconnect, output ownership and clocks. Some race tests (e.g. 1735, 1929) still rely on 20/50 ms sleeps to land at intended interleavings, so a loaded runner can hit a different phase. Use fake phase gates where timing is integral. This is potential flakiness, not a reproduced failure.
