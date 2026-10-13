# iOS logic audit — completed

All assigned production files under Services, App, package production, AppleIntegration and WatchLink were fully read. The coverage manifest is authoritative. Supplementary package tests were finished by the separate test reviewer. No source edits.

## LOGIC-1 [P1, currently unintegrated reference code] Failed CloudKit decode advances checkpoint

At `ios/Packages/RinaFaceSync/AppleIntegration/CloudKitFaceSync.swift:198`, decode/validation runs before the ingest catch that sets checkpointBlocked. A recoverable failure reaches applyFailure at :347, which only sets halt. A later stateUpdate can persist its advanced token at :228 despite a batch never being ingested. Restart/resume cannot replay the missed good records in that batch. Fatal scope/history failures are a different path and already halt checkpoints. Block checkpoint advancement for every failed fetched-record batch, including decode; rebuild from the last durable token until replay commits. Test malformed operation plus valid operation in one fetched batch followed by checkpoint serialization/restart. The file is not compiled into the shipping app or SwiftPM package target, so this does not establish current deployed iCloud exposure.

## LOGIC-2 [P2] Producer cancellation prevents partial group-start cleanup

At `ios/RinaBoard/Services/BoardGroupCoordinator.swift:852`, the cancelled play task directly awaits abortStartedBoards. Its stop uses withOutput at :888; cancellation propagates to its child, and wire send checks Task cancellation. Nested try? discards the error, then :896 invalidates the local lease. A board that already accepted group_start remains playing. Ordinary command failure without producer cancellation can send cleanup; preserve that distinction. Run cleanup in a fresh, bounded task while retaining existing epoch/token checks so a newer play is never stopped. Regression should accept the first board, hold the second start, cancel the producer, and verify stop_scroll reaches the accepted member.

## Architecture

BoardConnection has real transport adapters and a deep request-broker seam. Blob cancellation/abort ownership could be concentrated behind a deep internal transfer interface rather than distributed across typed helpers and rate/output lifecycle. CloudKit ingestion plus durable checkpoint publication needs one testable internal seam to exercise replay invariants without a live CloudKit account. See the independent validation and visual architecture report. These suggestions are not fixes made by the audit.
