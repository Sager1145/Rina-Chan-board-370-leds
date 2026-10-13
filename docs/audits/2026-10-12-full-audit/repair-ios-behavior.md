# iOS behavior repair work

Read full assigned audit findings, independent validation and docs/superpowers/plans/2026-10-12-audit-repairs.md. Preserve pre-existing watch styling.

Regression-first cases added in ios/RinaBoardTests/AuditBehaviorRepairTests.swift: terminal query/settings preserve live lease, display takes over; old delayed diagnostic status after B session switch cannot publish and B refresh must run; silent lip-sync mapping edit reaches wire once; cancelling group producer after A accepted start must send A stop_scroll.

Initial simulator command xcrun simctl list devices booted failed under sandbox (CoreSimulatorService access unavailable). Parent owns full suite; requesting targeted build/test setup before fixes.

## Verified red/green

`xcodebuild -project ios/RinaBoard.xcodeproj -scheme RinaBoard -destination id=3FCA0EF3-7639-4B8D-BF03-D44873BE480A -derivedDataPath /tmp/rina-behavior-derived test -only-testing:RinaBoardTests/AuditBehaviorRepairTests`

- Red: all 4 cases failed, 19 expected assertions (/tmp/rina-behavior-red.log).
- Green after logic changes: all 4 cases passed, no failures (/tmp/rina-behavior-green.log).
- LOGIC-2: abort runs in a fresh MainActor task, awaited by producer; each stop request timeout 2 seconds. Existing per-board epoch/token safeguards retained.
- UI-1: deduplicate composed PackedFrame, failure invalidates only matching frame; mapping/costume edits can republish at next existing tick.
- UI-3: diagnostic reads capture snapshot epoch, connection and connectionGeneration; reject every stale result/error. Overview ownership is invalidated on page switch and old defer cannot clear new busy state.
- UI-5: terminal acquires lease only for activity-changing CMDs; settings/query/subscription preserve live source.
- UI-2: both media sliders now expose progress label/value and explicit accessibilityAdjustableAction; clamped 5% increments seek directly. Drag path unchanged. VoiceOver runtime remains unobserved.
- UI-4: shared WatchCrownInput used by Digital Crown Binding setter; phone sync updates origin directly without command path. All pre-existing watch styling preserved. Fifth iOS regression added after first green and pending rebuilt check.

CloudKit standalone regression runner currently diagnosing a scratch SwiftPM build wait. Whole reference source Apple SDK check and decode/checkpoint/restart/replay regression still in progress. No full suite claim; parent owns full verification.

## LOGIC-1 completed

`ios/Packages/RinaFaceSync/AppleIntegration/CloudKitFetchedCheckpoint.swift` is the actual production fetched-batch/checkpoint seam used by `CloudKitFaceSync`'s two delegate branches. Decode, operation validation and repository ingest share one catch that blocks durable checkpoints. Physical history deletion/scope mismatch still reach the driver's fatal classifier. A later successful batch keeps the failed-batch gate closed. `resume()` resets the gate before replay, preserves any new replay failure rather than clearing it after `fetchChanges()`, and rebuilds from durable state as before.

The source remains separate from shipping app/SwiftPM targets. Compile CloudKitFaceSync with the new companion source.

Regression runner:
`bash ios/Packages/RinaFaceSync/AppleIntegration/Tests/AuditBehaviorRunCloudKitTests.sh`

- Compiles actual FaceSyncCore sources into a scratch static module, compiles/runs actual CloudKitFetchedCheckpoint with the standalone regression, then typechecks the complete CloudKitFaceSync delegate under Apple SDK, Swift6, macOS14 deployment.
- Red observed against extracted pre-fix production boundary: malformed+valid batch let advanced-token overwrite durable-token; fatal regression assertion (/tmp/rina-behavior-cloudkit-red.log).
- Green observed (exit0) after fix: malformed batch, decoded-invalid operation, durable token preserved across reopen, partial batch not committed, later success cannot unblock, explicit replay is idempotent and commits token (/tmp/rina-behavior-cloudkit-validation-green.log). Full delegate typecheck succeeded with no diagnostic output.
- No live CKSyncEngine event/account tests; SDK event structs expose no public initializers. The real production boundary is exercised directly, and delegate integration separately typechecked.

## Expanded app/watch verification completed

Command:
`xcodebuild -project ios/RinaBoard.xcodeproj -scheme RinaBoard -destination id=3FCA0EF3-7639-4B8D-BF03-D44873BE480A -derivedDataPath /tmp/rina-behavior-derived test -only-testing:RinaBoardTests/AuditBehaviorRepairTests -only-testing:RinaBoardTests/DebugSerialMonitorTests -only-testing:RinaBoardTests/DebugSessionTests -only-testing:RinaBoardTests/LipSyncProcessorStopWhileRunningTests -only-testing:RinaBoardTests/BoardGroupCoordinatorTests`

Exit0, 76 tests, no failures; log /tmp/rina-behavior-expanded-green.log. Actual suites: AuditBehaviorRepairTests 5; BoardGroupCoordinatorTests 65; DebugSerialMonitorTests 5; LipSyncProcessorStopWhileRunningTests 1. The nonexistent DebugSessionTests selector contributes no cases (not a coverage claim). Build included companion watchOS target and shared WatchCrownInput.

Existing adjacent test-source conformance/unused-claim warnings and AppIntents metadata warnings are in the app build log. No full-suite or strict-concurrency warning-gate claim.

Final same-vowel guard avoids newly introducing 30Hz observable writes while still composing for live costume changes. Focused final rebuild/test (5 new cases + lip-sync lifecycle) running at /tmp/rina-behavior-final-green.log.

## Owned file changes

- ios/RinaBoard/Services/BoardGroupCoordinator.swift
- ios/RinaBoard/Features/LipSync/LipSyncModel.swift
- ios/RinaBoard/Features/Debug/DebugViewModel.swift
- ios/RinaBoard/Features/Debug/DebugCommandCatalog.swift
- ios/RinaBoard/Features/PresetLive/PresetLiveView.swift
- ios/RinaBoard/Features/Video/VideoPlayerView.swift
- ios/RinaBoardWatch/WatchCrownValueView.swift (existing styling preserved)
- ios/RinaWatchLink/WatchCrownInput.swift (new; parent explicitly approved shared file)
- ios/RinaBoardTests/AuditBehaviorRepairTests.swift (new; existing tests untouched)
- ios/Packages/RinaFaceSync/AppleIntegration/CloudKitFaceSync.swift
- ios/Packages/RinaFaceSync/AppleIntegration/CloudKitFetchedCheckpoint.swift (new)
- ios/Packages/RinaFaceSync/AppleIntegration/Tests/AuditBehaviorCloudKitCheckpointTests.swift (new)
- ios/Packages/RinaFaceSync/AppleIntegration/Tests/AuditBehaviorRunCloudKitTests.sh (new)

No VideoPlayerModel or other-worker production/test source edits. No commits, uploads, nested workers or account operations.

## Final state

Final focused rebuild/test completed exit0: 6 tests, no failures (/tmp/rina-behavior-final-green.log; xcresult /tmp/rina-behavior-derived/Logs/Test/Test-RinaBoard-2026.10.12_03-57-24--0400.xcresult). This is the latest source state for all owned app/watch changes.

Final command:
`xcodebuild -project ios/RinaBoard.xcodeproj -scheme RinaBoard -destination id=3FCA0EF3-7639-4B8D-BF03-D44873BE480A -derivedDataPath /tmp/rina-behavior-derived test -only-testing:RinaBoardTests/AuditBehaviorRepairTests -only-testing:RinaBoardTests/LipSyncProcessorStopWhileRunningTests`

All assigned concrete findings LOGIC-1/2 and UI-1..5 have focused production fixes. Architecture opportunity suggestions were not expanded into unrelated redesigns. Remaining validation limits: VoiceOver real-user adjustment and watch crown hardware runtime were not exercised; CloudKit driver event/account lifecycle was SDK-typechecked, while its actual production batch/checkpoint seam was runtime-tested without CloudKit account operations. Parent still owns full suites/concurrency gate/video diagnosis/hardware.
