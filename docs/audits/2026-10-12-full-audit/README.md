# Full iOS, firmware and testing-software audit

Date: 2026-10-12 (America/Toronto). Checkout: `e6ac30b3b727fbbafd4fd16dfc8cb47b98dff297`, including the current uncommitted work. This is an audit, not a repair: production and test source were not changed.

## Scope and method

The review covers every first-party code file under `ios/`, current `esp32s3_firmware/`, `tools/`, and the testing software under `docs/`. The coverage manifest records one row per file with reviewer, inspection method, line count and SHA-256. It includes the iOS app, watch companion/shared link, both packages, AppleIntegration reference code, firmware guard, unit/UI tests, firmware host tests, generators, emulator, archived stress harnesses and fake platforms. It is a complete source review, not a claim that every runtime/hardware combination was exercised.

There are **415 source/script files and 98,103 lines**: 267 iOS code files, 72 firmware code files, 66 host/archive tool files and 10 interpreted `.rinalive` timelines. All 113 Swift test/support files and the C++ FaceSync guard test are included. Resource tables were structurally checked in full: 2,374 timeline keyframes, 92 expression parts, 11 default faces, 370 matrix mappings and 33,476 font glyphs. Binary artwork/audio/font files and generated/vendored `.build`/`.pio` outputs are excluded. `legacy/webui_v1` is explicitly archived and no longer firmware; its old browser/HTTP implementation is outside the current app/firmware scope.

Applied skills: Matt Pocock `codebase-design` and `improve-codebase-architecture`, supported by `ios-dev`, `guide-swift-concurrency`, `guide-swiftui-ui-patterns`, `guide-swiftui-performance-audit`, `guide-swift-testing`, and `verification-before-completion`. The architecture lens uses actual module interfaces and test seams; architecture suggestions are separate from correctness findings. The diff-specific `code-review` workflow was not forced onto this whole-codebase audit. No tracker setup, issue publication, commits or pushes were performed.

Six bounded workers contributed production review, test review and independent finding validation. GPT-6.1 Sol capacity interruptions were handled with preserved progress and GPT-6 Sol fallback workers. Grok model discovery succeeded but reported no authentication, so no Grok review is claimed. Audit details and validation are linked below.

## Findings to address first

| Priority / ID | Finding | Trigger and consequence | Evidence |
|---|---|---|---|
| P1 / LOGIC-1, **reference integration only** | CloudKit can save a checkpoint past operations it failed to decode | A recoverable record decode/validation failure occurs before ingestion; a later state update saves the advanced token. Restart/resume can permanently skip that batch. This AppleIntegration source is currently outside both the shipping app and package test target. | [CloudKitFaceSync.swift](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/ios/Packages/RinaFaceSync/AppleIntegration/CloudKitFaceSync.swift:198), [validation](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/validation.md) |
| P2 / LOGIC-2 | Cancelled group startup cannot stop members that already started | Cancelling the producer task makes its cleanup requests inherit cancellation. Errors are swallowed and local leases released while an accepted board continues scrolling. Ordinary failure on an uncancelled producer is a different path. | [BoardGroupCoordinator.swift](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/ios/RinaBoard/Services/BoardGroupCoordinator.swift:888) |
| P2 / UI-4 | Passive watch echoes send unwanted rounded settings | Phone brightness 67 received by an open crown page is snapped to 65 and sent back without watch input. | [WatchCrownValueView.swift](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/ios/RinaBoardWatch/WatchCrownValueView.swift:96) |
| P2 / UI-1 | Live lip-sync edits leave board pixels stale | Mapping/costume changes update preview, but an unchanged vowel suppresses the newly composed frame. | [LipSyncModel.swift](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/ios/RinaBoard/Features/LipSync/LipSyncModel.swift:467) |
| P2 / UI-3 | Debug can display the previous board's diagnostics | An unstructured refresh for A finishes after switching to B; the shared refresh gate skipped B and the old completion publishes A's fields. | [DebugViewModel.swift](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/ios/RinaBoard/Features/Debug/DebugViewModel.swift:611) |
| P2 / UI-5 | A read-only terminal query stops live output | Default `get_info` takes the debug output lease and invokes the previous producer's stop handler. | [DebugViewModel.swift](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/ios/RinaBoard/Features/Debug/DebugViewModel.swift:911) |
| P2 / FW-A1 | Short battery checks show zero or stale charge | The fresh power snapshot is not copied into the single-shot animation. Host probe with valid 83% battery displayed invalid/0%. | [button_animations.cpp](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/esp32s3_firmware/src/button_animations.cpp:517) |
| P2 / FW-A2/A3 | Group playback end and loop state disagree | Starting already at the non-loop end never latches pause; group loop preference is separate from the status/control preference. Host probes reproduced the end-state defect. | [scroll_session.cpp](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/esp32s3_firmware/src/scroll_session.cpp:670) |
| P2 / FW-A4 | Invalid AP credentials are persisted and reported active | A one-byte password over RinaLink is accepted; softAP failure is ignored. HTTP validates this independently. | [wifi_manager.cpp](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/esp32s3_firmware/src/wifi_manager.cpp:494) |
| P2 / FW-A5/A6 | Wi-Fi selection/off behavior is incorrect at scan edges | A configured visible SSID below the retained top-20 results is treated as absent. Scanning from mode off leaves the STA radio enabled until another mode application/reset. | [wifi_manager.cpp](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/esp32s3_firmware/src/wifi_manager.cpp:313) |
| P2 / FW-A7 | Bulk imports allow ambiguous face identities | Duplicate or empty IDs pass validation; first-match and last-match handlers can operate on different records. | [storage.cpp](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/esp32s3_firmware/src/storage.cpp:261) |
| P2 / FW-A8 | Render-task allocation failure has no effective fallback | Mutex initialization succeeds but task creation fails; synchronous fallback is gated on mutex readiness. Requests are acknowledged without a renderer. | [scroll.cpp](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/esp32s3_firmware/src/scroll.cpp:89) |
| P2 / FW-A9/A10, **conditional static traces** | BLE slot reuse can target a new peer; render retry loses presentation identity | Narrow callback interleaving or recovered RMT refresh failure can respectively disconnect a new peer or leave preview telemetry stale. These were independently traced, not hardware reproduced. | [firmware details](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/firmware.md), [validation](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/validation.md) |
| P2 / FW-A11 / TOOL-1 | Unified firmware test runner does not link the battery implementation | The documented runner fails before remaining suites. Individual programs pass with the required dependency linked. | [protocol_selftest.py](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/tools/protocol_selftest.py:25) |
| P2 / TOOL-2 | All-skipped tests pass the iOS execution gate | The real judge function reports `ok` for one reported test, one skip and zero failures. | [verify_ios.sh](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/tools/verify_ios.sh:69) |
| P2 / TOOL-3 | Two emulated boards share one mutable state | Setting brightness on the first changes the second identity; the documented multi-board simulator cannot establish isolated routing. | [rinalink_board_emulator.py](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/tools/rinalink_board_emulator.py:21) |
| P2 / TOOL-4 | Short-track audio alignment fallback fails for identical signals | Negative slice origin produces an empty NumPy correlation input. Reproduced with identical short arrays. | [verify_preset_live_alignment.py](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/tools/verify_preset_live_alignment.py:95) |

The firmware report also includes FW-A12 (P3): button overlays suppress hints despite the documented hint precedence. The media sliders have a proven missing commit path for updates without edit-end callbacks; their specific VoiceOver failure is **an accessibility verification candidate**, not runtime-confirmed. The detailed test reports separate assertion defects, selector drift and coverage gaps from product bugs. FW-A11 and TOOL-1 are one issue, not two.

## Verification actually executed

| Check | Result |
|---|---|
| Xcode/toolchain | Xcode 27.0, build 27A266a |
| RinaCore debug package | PASS: 373 reported tests, including 11 skips; 362 non-skipped |
| RinaCore opt-in release performance filter | PASS: 18 tests, zero failures, `RINA_PERF_GATE=1` |
| FaceSyncCore package | PASS: 69 Swift Testing tests |
| FaceSync firmware guard | PASS: 19 host preflight assertions |
| iOS app build-for-testing | PASS |
| iOS app unit suite | FAIL: 621 tests, 4 failure records across 2 video cases; exit 65 |
| Targeted video rerun | FAIL: both cases reproduced; media-decoder errors also present; cause unresolved |
| Strict-concurrency lane | Build compiles; gate FAIL: 50 distinct sites > baseline 44. Compiler warnings alone are not treated as demonstrated Swift 5 races. |
| Hardware-free UI smoke | FAIL: 3 tests, 1 failure. Face-library navigation succeeds; stale Button selector for preset caption fails. |
| Default firmware (`esp32s3-rmt-dma`) | PASS: PlatformIO build, 547.90 seconds |
| Unified firmware host command | FAIL: battery-calibration linker dependencies missing |
| All individual current firmware host programs | PASS: 5 C++ programs (calibration linked correctly), 12 Python scripts |
| i18n tool tests | PASS: 9 subprocess tests |
| i18n catalog checks | sync check FAIL: nine active keys marked stale, zero missing; translation application check PASS: zero changes |
| Python source syntax | PASS across host tools, archived testing tools, firmware tools/tests |
| Resource structural validation | PASS for all enumerated timelines, parts, faces, geometry and font records |
| Audio alignment against local media | FAIL at afconvert; asset/decoder cause unresolved; no alignment success claimed |

The video failures are `VideoPlaybackRecoveryTests.testMatchingSavedVideoResumesBoardPositionWithOriginalStreamID` (CancellationError waiting for a sent frame) and `VideoProgressPublishingTests.testCheckpointAtEndOfPlaybackIsExactDuration` (still playing at position zero after ten seconds). The tests depend on real simulator media decoding. A product defect has not been isolated from the decoder failure; do not dismiss these as flaky or call the suite green.

The UI failure is `RinaBoardUITests.testLegacyControlCenterAndFaceLibraryAreReachable:39`. Its comment expects an outer Button row, while the current library row is an HStack with a static preset caption and separate action Buttons. Update the test to assert the actual row/caption semantics, then rerun that test. This audit did not change the selector.

## Architecture and test priorities

Matt Pocock's architecture lens points to three strong opportunities:

1. Keep playback state transitions, loop preference, end state and presentation identity inside a deeper playback module. Tests should cross the same command/snapshot seam as real callers, including cancellation and refresh retry. This addresses a cluster of observed defects rather than adding pass-through wrappers.
2. Centralize Wi-Fi validation, persistence/application outcome and configured-profile visibility. HTTP and RinaLink are real adapters at this seam; neither should carry a separate validation rule or mistake a presentation-capped scan list for connection policy.
3. Give board-scoped diagnostics and watch confirmed-value reconciliation explicit ownership. Results must retain the board/session that produced them; passive echoes must remain passive. Existing fake transports and watch senders already provide real test seams.

The standalone architecture report illustrates before/after ownership. These are suggestions, not repairs performed by the audit. Prioritize failing verification and the deterministic playback/watch/Wi-Fi/battery defects before broad refactoring.

## Details, coverage and practical limits

- [iOS logic](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/ios-logic.md)
- [iOS features, watch and resources](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/ios-ui.md)
- [firmware](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/firmware.md)
- [testing/build tools and archived harnesses](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/tools.md)
- [package/UI tests and first app-test half](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/tests.md)
- [remaining app tests](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/app-tests-b.md)
- [independent finding validation](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/validation.md)
- [file-by-file coverage and source hashes](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/coverage.csv)
- [execution evidence and reproduction commands](/Users/sager/Documents/GitHub/Rina-Chan-board-370-leds/docs/audits/2026-10-12-full-audit/verification.md)

Current source was reviewed in full; literal data tables were validated structurally rather than read as prose. No physical BLE/Wi-Fi/USB interruption, battery/flash power-loss, RTOS scheduling, WatchConnectivity runtime, VoiceOver runtime, Instruments trace, iPad rotation matrix, iOS 17 device or alternate LED backend was exercised. Those are named validation gaps, not reasons to omit source findings. The no-bonding/unauthenticated firmware control surfaces are intentional in code; their ownership/security policy is an architecture decision requiring an explicit threat model, not silently classified as a spec violation.

[Visual architecture report](/tmp/architecture-review-20261012-0308-rina.html)
