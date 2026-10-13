# Testing and build-tool audit — 2026-10-12

Read-only review of all 18 code files under tools/ and all 48 code files under docs/, including archived firmware harnesses, Swift stress tests, fake platforms, serial loggers, routing oracles, and result collectors. Full file coverage is in rina-audit-parent-reviewed.txt. Archived code is identified separately from current verification tooling. No physical device commands were executed.

## Current tooling defects

### TOOL-1 [P2] Aggregate firmware tests stop at an unlinked implementation

`tools/protocol_selftest.py:25` compiles every C++ test alone. `battery_calibration_test.cpp` requires `src/battery_calibration.cpp`; the documented command fails with undefined symbols before any remaining suite runs. Reproduced with `python3 tools/protocol_selftest.py`. All five C++ test programs pass when the calibration implementation is linked explicitly, and all twelve Python host scripts pass independently. Add the real translation-unit dependency to this test's build recipe. This duplicates FW-A11 and must count once in the consolidated report.

### TOOL-2 [P2] All-skipped iOS tests satisfy the nonzero-test gate

`tools/verify_ios.sh:69` checks the reported executed count but does not subtract skipped tests. XCTest's executed count includes skips. Feeding its actual `judge_tests` function the summary `Executed 1 test, with 1 test skipped and 0 failures` and status zero prints `app: ok, 1 executed, 1 skipped, 0 failed`. No test body ran. Require executed minus skipped to be positive; keep skip counts visible. The current Core run was not all skipped: 373 reported, 11 skipped.

### TOOL-3 [P2] Two emulated boards share mutable state

`tools/rinalink_board_emulator.py:21` creates one global state dictionary. Different local host identities only change the reported name/IP (`:31-39`); `handle_cmd` mutates the same dictionary. The tool explicitly advertises a two-member group simulation (`:8-10`). A scratch AST probe sets brightness to 12 for identity 127.0.0.1, switches identity to 192.0.2.1 and reads brightness 12 there too. This prevents the emulator from testing independent target state or zero cross-talk. Store state per logical board identity. Its intentionally absent face/timeline emulation remains a declared limitation, not another defect.

### TOOL-4 [P2] Short-audio alignment fallback slices from a negative origin

`tools/verify_preset_live_alignment.py:87-95` sets start to zero for shorter tracks, then slices the haystack starting at negative max_lag. NumPy interprets that relative to the end; the resulting range is empty for a normal short signal. A probe with two identical 100,000-sample arrays at rate 10,000 raises `ValueError: first array argument cannot be empty` instead of returning lag zero. Select an anchor beginning at least max_lag samples into the signal and compute the fallback window from that origin. Test identical and shifted short signals through the public measure_lag function. The real-asset verification run also failed at afconvert; its decoder/asset cause remains unresolved and is not proof of this fallback defect.

## Archived harness concerns

### TOOL-5 [P2, integration risk] Stress harness failure does not determine process success

`docs/stress-20260912-211559/tools/firmware/stress_run_all.sh:32-36` saves a child's exit status only in text. Background `run` jobs finish with a successful echo/tee; `wait` at :46 does not propagate the recorded child failures. Its final commands also return success regardless of FAIL case rows. In addition, stress_f1/f2/f3/f4/f5_f7/f6/json_capacity programs print fail counts and return zero, so successful exit does not imply passing assertions. The CSV is useful evidence, but this archived runner is unsuitable as a pass/fail gate without checking every child status, case count and FAIL row. Several archived harness paths assume a staged snapshot, so they are not direct commands for the present checkout. Current host scripts explicitly parse F4/F5F7 summaries, which avoids some of this risk.

### TOOL-6 [P3] Archived UI launcher loses xcodebuild's exit status

`docs/stress-20260912-211559/tools/ios/run_xc.sh:8-10` records RC then ends with echo, returning zero even on a failed test/timeout. Its hardcoded scratch checkout and Xcode-beta path no longer exist on this host. Preserve the log line, then exit with RC; resolve checkout/toolchain from invocation context if this historical launcher is revived. Do not count archived scripts as currently running regression coverage.

## Coverage gaps and test semantics

- The routing oracle checks zero cross-talk and duplicate subscriptions. It does not check positive delivery: `oracle.evaluate` returns PASS when the expected board has before/after status but no commands and no state change. A scratch no-op case confirmed this. This is a limitation of its INV-1/INV-2 purpose; it must not be presented as proof that each requested action succeeded. Add action-specific delivery checks in a separate oracle if that assurance is required.
- The battery soak parser retains an already-consumed tail and can count repeated matches multiple times; archived telemetry statistics are diagnostic rather than an independent safety guarantee. Real radio/battery/USB-loss branches require hardware.
- Archived Swift stress tests reflect old private property names and contain encoder calls predating the throwing interface. They are not part of the app test target. Several report FAIL in STRESSCASE output without making an equivalent XCTest assertion; treat the recorded status as evidence, not a green XCTest result.
- `verify_ios.sh` deliberately runs Core, app unit tests and concurrency only. FaceSync package/guard and UI tests need separate invocations; its three green lanes would not establish complete repository testing coverage. FaceSync AppleIntegration is outside the SwiftPM target and app project.
- No CI configuration is present. The real production-interface tests and differential codec/frame tests are valuable; do not replace them with source-string assertions. Prefer a small explicit verification manifest that enumerates packages, C++ dependencies, UI/hardware lanes, minimum executed counts and skip reasons.

## Validation

Python syntax compilation succeeded for every Python file under tools, docs, firmware tools and firmware host tests. i18n's nine subprocess tests passed. Parent ran every current host program and both Swift packages; separate execution logs carry counts and failures. No hardware, external downloads, commits or source edits were performed. Binary images/fonts, generated build outputs, and legacy web application production code are outside this testing-software scope.
