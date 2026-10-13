# Testing software repairs — completed worker scope

## Dispositions

- **Inert permutation loop:** Core test now honestly exercises all five slot crops for each frame and two gap patterns. New existing-file BoardGroupCoordinator regression invokes real play() for all 120 physical identity permutations x two gap configurations, and checks every transport receives a fresh BLOB_BEGIN with its expected viewportX and virtualWidth. Passed.
- **Missing font fixture skip:** GroupScrollBitmap loader records failure and throws for absent tracked ark12.json; never skips a packaging regression. Nine core bitmap tests pass with the actual fixture.
- **DSP misleading gate:** measure test explicitly renamed diagnostic; documented release analyze p50 ratio <=0.65 retained. Release opt-in run passes both; measured analyze engine/reference p50 ~0.518 and diagnostic measure ~0.504.
- **BLE private duplicate:** actual production BLEConnectAttemptSlot extracted and wired into BLETransport connect/defer/disconnect. Existing tests exercise it directly. BLEDisconnectGate exposes internal registeredWaiterCount, and tests wait for actual continuations instead of 10 ms parking sleeps. No public API or radio behavior changes.
- **Overlap fake:** GET_FRAME bytes captured at request arrival. Existing regression holds two replies, asserts distinct old/new payloads, completes newer refresh, releases older last, awaits both completions, then asserts newer draft. Existing ControlViewModel snapshot guard passes; no ControlViewModel production edit needed.
- **Defaults pollution:** standard router preference saved/restored. XCTest helper creates UUID domains, never falls back to standard, and registers domain removal. Used by BoardSyncCoordinator, BoardGroupCoordinator, GroupControlFanOut, GroupAutoCycler/Connector, WatchLink and TextPreviewInvalidation fixtures.
- **Sink lifetime:** only a weak immutable connection reference remains across removal. Assert actual deallocation before survivor dispatch; removed sink receives no new brightness. Passed.
- **Watch sensitivity lock:** separate idle clamps and running lock. Real LipSyncModel starts through injected fake capture/granted permission; watch edit rejected while running, accepted after stop. Passed.
- **FaceSync settings redeploy:** unchanged vector + increased settingsVersion changes startupDefaultId to another present face; actual DurableBoardModel commit and persisted document/vector/version/revision assertions pass.
- **UI stale role:** navigation smoke asserts the real selected local picker. Preset captions use current HStack Text children for existence, local/board switching and context-menu long press. All four UI tests pass.
- **Visual oracle:** screenshot test honestly named capture-for-review. Actual frozen RinaStarfield view is rasterized using ImageRenderer; asserts five packaged assets, nonempty visible alpha and sparse transparent canvas. Passed. This checks the view's actual draw/assets, not a golden whole-page screenshot.
- **Rotation sleeps:** concrete window orientation and sidebar layout waits replace fixed 1.5 s settling. Existing frozen-star test flag used by Settings fixture to avoid perpetual backdrop animation idleness. All three iPad mini rotation tests pass, checking layout changes, filter and terminal state.
- **Group races:** actual held clock-sample/stop-scroll/set-color requests establish audited lease/stop/burst phases. Stale stop replies released immediately after newer play enters real isStarting/lease-claimed phase, before awaiting play completion; avoids request-timeout dependency. Same-group and cross-group final cases pass in 0.323/0.513 seconds.

## Verification evidence

All completed verification commands returned exit 0:

- `/tmp/rina-testsoftware-core.log`: native SwiftPM, 9 bitmap tests pass; optional performance tests intentionally skip without opt-in.
- `/tmp/rina-testsoftware-facesync.log`: 1 settings-only durable redeploy test passes.
- `/tmp/rina-testsoftware-performance.log`: native SwiftPM release RINA_PERF_GATE=1, 2 pass, no skips.
- `/tmp/rina-testsoftware-app.log`: 74 targeted app tests pass, including all120 x2 mapping, captured reorder, BLE seams, actual lifetime, running lock, BoardSync and router preference restoration.
- `/tmp/rina-testsoftware-visual.log`: 2 pass, actual starfield raster and text preview invalidation. Text observes25ticks, parentDelta0, previewDelta24.
- `/tmp/rina-testsoftware-ui.log`: 35 group harness tests +4 face-library UI tests pass.
- `/tmp/rina-testsoftware-races.log`: 4 deterministic race/lifetime checks pass.
- `/tmp/rina-testsoftware-stop-phase.log`: final2 stop release-order cases pass without5second request timeout.
- `/tmp/rina-testsoftware-rotation-rerun.log`: 3 iPad mini rotation UI tests pass.
- `/tmp/rina-testsoftware-final-build.log`: final test build succeeded; later stop-phase run rebuilt final source and passed.

Initial default SwiftBuild package attempts failed generated-bundle signing due resource-fork/Finder metadata in workspace .build output. Native SwiftPM with temporary scratch paths resolved that environment issue. First iPad run stalled at boot-overlay accessibility polling before any layout assertion and was canceled; frozen-backdrop rerun passes. Test/diagnostic processes for the canceled run were stopped.

Dedicated simulators: phone EE68463D-B834-42E0-99C2-EEF7534BB93F; iPad mini018DCF00-5172-45C3-AC78-8A80B7EDD9D9. Derived data /tmp/rina-testsoftware-dd. No hardware accessed, no commits/subagents, no user-modified BoardConnectionOutputTests or RinaRequestBrokerTests edits.

## Remaining assurance boundary

DualBoardStressUITests random walk logs intended targets and drives UI actions; it has no physical board output oracle. Existing real transport/coordinator/host fan-out tests provide software routing evidence. Device output correlation remains the parent's hardware lane. This worker does not claim an automated physical-output assertion or a golden whole-page visual comparison.

Final whitespace check: git diff --check across the owned core/app/UI changes returned0 with no diagnostics. Both dedicated simulators were already Shutdown when cleanup was requested; no simulator remained booted by this worker.
