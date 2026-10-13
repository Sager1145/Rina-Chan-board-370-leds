# Independent tools repair review

Read-only review of root-owned tools on 2026-10-12. No repository files edited. Actual gate functions, alignment interface, test suite and staged wrapper fault probes were executed. Firmware integration was not reviewed here.

## Concrete findings

### [P2] Swift Testing skips still satisfy the nonzero-body gate

`tools/verify_ios.sh:57-60,71-72` converts every passing Swift Testing summary to `N 0 0`, even if all N tests were skipped. This bypasses the new `executed - skipped > 0` check specifically on the facesync lane (and any fallback using the Swift summary). The new test suite checks XCTest skip subtraction but its Swift fixture has no skips, so all ten tool tests pass despite this hole.

Reproduced with a real temporary Swift package using bundled Testing Library Version 2084, not an invented summary. A single `@Test(.disabled("review probe"))` prints `Test disabledBody() skipped` and `Test run with 1 test in 0 suites passed`, process exit0. A disabled suite with two test functions prints both `Test first() skipped` / `Test second() skipped` and `Test run with 2 tests in 1 suite passed`, exit0. The existing facesync gate accepts the former as `1 executed, 0 skipped`.

Precise repair: parse Swift Testing's skipped **Test** records alongside its final summary and subtract those from total tests, while retaining the process-exit/failure checks. Disabled suite records are not additional skipped tests; count only Test records. Add actual all-disabled function/suite output fixtures to `tools/test_audit_tools.py`, including at least one executed body among skipped tests. Avoid treating the passed summary as evidence that every registered body ran.

Evidence logs: `/tmp/rina-tools-swift-skip.log`, `/tmp/rina-tools-swift-suite-skip.log`. Initial scratch package compile hit the host cache sandbox; rerun successfully with its module caches under /tmp and SwiftPM's inner sandbox disabled, without expanding host permissions.

### [P3] Mixed-framework logs reject real Swift Testing bodies outside facesync

`test_counts` prefers the last XCTest summary for core/app/UI, even when it is `Executed 0 tests` or all skipped and a positive Swift Testing summary follows. Feeding the actual gate `Executed 0 tests, with 0 failures` followed by `Test run with 69 tests in 13 suites passed` returns exit1 on core and prints `0 executed`. The same result occurs for an all-skipped XCTest summary plus positive Swift Testing bodies. This is a false failure; current Core/app tests use XCTest, so the existing repository runs were not shown affected.

Precise repair: combine the final top-level totals from both frameworks when both are present, rather than privileging one framework by lane name. Sum executed/skipped/failures, enforce nonzero unskipped body count and process exit0. Add mixed-framework fixtures alongside the skip cases above. Treat this as a remaining limitation introduced by partial Swift Testing support, with low immediate impact.

### [P2, remaining baseline defect] Alignment succeeds with no fixtures checked

`tools/verify_preset_live_alignment.py:130-133,139-142,165-171` skips unavailable audio/original fixtures without incrementing failure or recording how many transcodes were actually correlated. It then returns0 and prints `All transcodes are sample-aligned` even if none were examined. The short-window fix itself is correct and the identical/37-sample-shift tests pass, but they do not cover the main command's gate.

Reproduced via the production `main()` with an isolated one-entry catalog and no audio fixture: prints SKIP, prints All transcodes are sample-aligned, returns0. No decoder fake is required for that case.

Precise repair: count checked transcodes and missing required fixtures; reject missing expected audio or required original Ogg inputs, distinguish intentionally copied MP3 tracks, and require an applicable body to run before claiming transcode verification. Print checked/skipped counts. Add a temporary-catalog/no-fixture regression through main. This is pre-existing behavior, not caused by the new short-audio change; include it only as the requested remaining gate defect.

## Repairs accepted / actual verification

- `python3 -m unittest tools/test_audit_tools.py -v`: 10 tests passed. Alignment short identical/shifted cases, emulator board-state isolation/serialized frame writes, soak parser no-recount/split status and XCTest skip/failure gates are meaningful production-interface tests.
- `tools/protocol_selftest.py`: the battery implementation dependency is correct. The earlier full aggregate command completed exit0 and `protocol_selftest: PASS`; no introduced runner defect identified.
- Archived `run_xc.sh`: controlled fake xcodebuild exit17 is returned17, current directory and DEVELOPER_DIR are inherited, and the wrapper preserves WRAPPER_EXIT. A one-second timeout returns142. No introduced launcher defect identified.
- Archived `stress_run_all.sh`: staged copies with deterministic external build/run adapters returned0 for seven PASS harnesses,1 for a child exit9 despite PASS CSV,1 for a FAIL CSV row despite child exit0, and1 for a build failure. The seven changed C++ final return statements match their actual failure counters. No introduced propagation defect identified.
- Soak parser's absolute offsets prevent recounting a completed tail and wait for a complete trailing line; split STATUS fixture passes. The retained 600-byte window accommodates current production STATUS lines; no new concrete parser fault identified.
- Emulator keeps per-board dictionaries and one send mutex per socket, protecting heartbeat/response frame writes. The shared scroll-flag behavior remains explicitly documented, and deliberately absent timeline/face emulation was not treated as a new defect.

Wrapper probe source/output: `/tmp/rina-tools-review-probes.py`, `/tmp/rina-tools-wrapper-probes.log`. These change only temporary external adapters, preserving the production wrapper logic. No hardware, real Xcode tests, external downloads, source edits or commits in this review.
