# iOS logic audit — incomplete checkpoint

The user interrupted the full audit for a commit and push. This is a read-only review checkpoint, not a complete audit. No production or test files were changed by this reviewer. The adjacent `ios-logic-coverage.csv` records each assigned path and whether it was reviewed before the interruption. No build or test result is claimed; the parent agent owns those verification lanes.

## Current finding: CloudKit engine lifecycle can overlap [P2; reference integration only]

`ios/Packages/RinaFaceSync/AppleIntegration/CloudKitFaceSync.swift:94-112` checks `engine == nil` before awaiting account verification, metadata fetch, and engine creation. An actor is reentrant at those awaits. Two callers of `start()` can therefore both pass the nil check, create separate `CKSyncEngine` instances, and replace `engine` with the second one. The first engine can still send delegate events because `handleEvent`/`process` (`:172-205`) do not verify that `syncEngine` is the current engine. `resume()` (`:146-165`) also replaces the engine and calls `fetchedCheckpoint.beginReplay()` (`CloudKitFetchedCheckpoint.swift:50-54`), reopening checkpoint persistence without distinguishing events from the canceled engine. A late old-engine `.stateUpdate` could then persist an advanced token after a failed fetched batch, skipping its replay on restart. This needs a lifecycle gate or generation identity, and a test that holds one `start()` across its first await while another starts, then delivers an old-engine state update after `resume()`.

Scope: `AppleIntegration` is outside the SwiftPM package target and shipping app target according to its source comments and test runner. This finding concerns the reference CloudKit integration, not proven deployed behavior. The existing `AuditBehaviorCloudKitCheckpointTests.swift` exercises the checkpoint actor in isolation, but does not create or replace a sync engine.

## Review status and remaining work

The checkpoint review covered the CloudKit driver/checkpoint, its isolated test runner, and selected FaceSync core and board storage/connection files. Full review of the large group coordinator, remaining transports/services, RinaCore sources/tests, FaceSync tests, and app files remains open. The previously reported group-start cancellation defect from the 2026-10-12 audit appears repaired at `BoardGroupCoordinator.swift:885-891` by detached cleanup ownership; it is not repeated as a current finding. Do not treat this checkpoint as a final all-file audit.
