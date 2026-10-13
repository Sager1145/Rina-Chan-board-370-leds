# Archived iOS stress-source repairs

Scope: only Swift source under docs/stress-20260912-211559/tools/ios. No production/current-test changes, app-target registration, historical-log/result changes, or archived stress execution.

## Changes

- StressSupport: required typed read-only reflection reports XCTFail and stops on any missing/mistyped field instead of fabricating zero/empty/-1 metrics.
- Request metrics now read broker.pending, broker.nextSeq, broker.quarantinedSeqs dictionary keys and PendingRequest.accumulated buffers. Current source still owns eventContinuations directly on BoardConnection; no event hub exists in this checkout, so the subscriber path follows that actual layout. Output operation dictionary is read with required typing.
- Decoder buffer metric now measures storage.count - readOffset (actual unconsumed data), replacing the stale buffer-field lookup that previously yielded an inert metric.
- StressSequenceTests constants use required typed reads of the actual pump/connection fields.
- Shared Stress.encode handles the current throwing encoder; encoding failure records XCTFail and stops instead of silently dropping malformed test fixtures. All five formerly nonthrowing fixture call sites now route through it.
- Shared Stress.record(status: FAIL) now records XCTFail at the caller's file/line before preserving the STRESSCASE JSON/stdout/temp-file output. PASS/BLOCKED retain their existing meanings.
- StressOwnershipTests exhaustiveness failed against current group/groupControl output sources. Both are now included in the actual nine-source matrix, with 72 switches and 9 same-source restarts. No default branch hides future API drift.
- StressCrashReproTests keeps historical selectors stable but now asserts graceful oversized-payload rejection and no outbound frame, rather than expecting an encoder precondition trap. Missing byte-heavy fixture now fails via XCTUnwrap rather than skipping. Historical evidence remains untouched.

Changed files: StressSupport.swift, StressSequenceTests.swift, StressMemoryEventTests.swift, StressBoundaryTests.swift, StressOwnershipTests.swift.

## Verification

Initial baseline with the correct XCTest Swift overlay failed at the unhandled throwing RinaLinkEncoder call (/tmp/rina-archived-ios-baseline-overlay.log). Subsequent typecheck exposed the missing ownership cases; fixed rather than adding a default. One intermediate compiler run detected input mutation from overlapping earlier invocations. All prior invocations were drained and a fresh final run used a separate log.

Final command (all nine archived Swift files):

```sh
xcrun swiftc -typecheck -swift-version 5 \
  -target arm64-apple-ios17.0-simulator \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk \
  -module-cache-path /tmp/rina-archived-ios-module-cache \
  -I /tmp/rina-video-repair-dd/Build/Products/Debug-iphonesimulator \
  -I /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/usr/lib \
  -F /tmp/rina-video-repair-dd/Build/Products/Debug-iphonesimulator/PackageFrameworks \
  -F /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks \
  docs/stress-20260912-211559/tools/ios/*.swift
```

Final exit 0; /tmp/rina-archived-ios-final-typecheck.log is empty (no errors/warnings). git diff --check for archived Swift sources passed. This confirms compile compatibility only; no claim that every historical stress policy/threshold passes against today's app. The large archived stress suites were not run, as assigned.
