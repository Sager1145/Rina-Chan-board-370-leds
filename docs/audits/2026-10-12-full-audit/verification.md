# Execution evidence and reproduction commands

The source audit covers every file in coverage.csv. The following runtime checks were executed against the current checkout using Xcode 27.0. Logs are retained in the task's scratch directory; this report preserves the commands and result summaries. Production/test code was not changed.

| Command / lane | Observed result | Original log |
|---|---|---|
| `RINA_VERIFY_DIR=/tmp/rina-full-audit-verification bash tools/verify_ios.sh core` | Exit 0; 373 reported tests, 11 skipped, zero failures | `/tmp/rina-full-audit-verification/core.log` |
| `swift test --package-path ios/Packages/RinaFaceSync --scratch-path /tmp/rina-audit-facesync-build` | Exit 0; 69 tests passed | `/tmp/rina-audit-facesync.log` |
| `RINA_SIM_ID=3FCA0EF3-7639-4B8D-BF03-D44873BE480A RINA_VERIFY_DIR=/tmp/rina-full-audit-verification bash tools/verify_ios.sh app concurrency` | Exit 1; app test exit 65; 621 tests, four failure records in two video cases. Strict gate 50 > 44. Build-for-testing succeeded. | `/tmp/rina-audit-app-run.log`, `/tmp/rina-full-audit-verification/app.log`, `concurrency.log` |
| xcodebuild test-without-building, only two failing Video cases | Exit 65; both failures reproduced. Fig -12900 / player -12843 errors accompany them. | `/tmp/rina-audit-video-rerun.log` |
| `RINA_PERF_GATE=1 swift test -c release --package-path ios/Packages/RinaCore --scratch-path /tmp/rina-audit-core-release --filter PerformanceTests` | Exit 0; 18 tests passed, no skips/failures | `/tmp/rina-audit-core-performance.log` |
| xcodebuild test-without-building, only RinaBoardUITests/RinaBoardUITests, dedicated audit simulator | 3 cases, one failure at RinaBoardUITests.swift:39; Debug workspace and serial monitor cases passed | `/tmp/rina-audit-ui-smoke.log` |
| `pio run -d esp32s3_firmware -e esp32s3-rmt-dma` | Exit 0, SUCCESS, 547.90 seconds | `/tmp/rina-audit-firmware-build.log` |
| `python3 tools/protocol_selftest.py` | Exit 1; battery-calibration undefined symbols prevent suite execution | `/tmp/rina-audit-protocol-selftest.log` |
| Every host *_test.cpp individually with C++17/Wall/Wextra/Werror; battery linked with src/battery_calibration.cpp | All five programs passed | `/tmp/rina-audit-cpp-host.log` |
| Every host *_test.py individually | All twelve scripts exit 0, including ASan/UBSan protocol checks and F4/F5F7 summaries | `/tmp/rina-audit-firmware-host.log` |
| C++17 compilation/run of ios/Packages/RinaFaceSync/Firmware/guard_test.cpp | 19 preflight assertions passed | Tool result retained in chat |
| `python3 tools/i18n/test_i18n_tools.py` | Nine tests passed | `/tmp/rina-audit-i18n.log` |
| `python3 tools/verify_preset_live_alignment.py` | Failed decoding local audio_tkmk.m4a with afconvert; no source/transcode alignment result obtained | `/tmp/rina-audit-alignment.log` |
| i18n sync_catalog --check against fresh app intermediates; apply_translations --check | sync_catalog: 659 keys, zero missing, nine active keys marked stale (check fails). apply_translations: zero fields would change; five orphan dictionary entries reported (check passes). No blanket translation defect is inferred. | `/tmp/rina-audit-i18n-sync.log`, `/tmp/rina-audit-i18n-apply.log` |

## Focused defect probes

- `python3 /tmp/rina-audit-probes.py` extracted and compiled production overlay and group-start bodies. A valid 83% battery produces `valid=0 percent=0 voltage=nan` in a fresh single-shot overlay; one-frame and late-start no-loop group cursors remain unpaused. Source and probe outputs were independently checked.
- The actual shell `judge_tests` implementation in verify_ios.sh, given a synthetic XCTest summary of one test and one skip, prints `app: ok, 1 executed, 1 skipped, 0 failed`. The probe evaluates only the existing judge function, not a copied alternative implementation.
- AST-isolated emulator functions (no sockets started) report brightness 12 under a second identity after setting brightness 12 under the first. This proves the shared-state behavior without network/hardware access.
- `measure_lag` on two identical 100,000-sample NumPy arrays with rate 10,000 raises `ValueError: first array argument cannot be empty`, exercising the existing short-track fallback.
- The archived stress runner's actual `run` shell function, invoked with a temporary executable returning 7, logs `failure exit=7` and itself returns 0. This is a gate integration concern, not a current production failure.
- Oracle.evaluate with expected board A, stable bracketing status and no events yields PASS. Its negative routing invariant does not establish positive command delivery.
- Python `compile` syntax checks succeeded for every *.py file in tools/, docs/, firmware tools and host tests. No imports or top-level hardware loops were executed by this syntax check.

## Environment and limits

Initial sandbox compiler-cache/CoreSimulator access failed; supported host escalation allowed the checks to run. No automatic approval rejection remained. Grok reports unauthenticated; it contributed no results. Agent capacity errors interrupted several workers; their saved ledgers/reports allowed continuation and complete coverage.

The dedicated UI simulator is `RinaAcceptance-Audit-20261012` (F84C90F6-27AF-41CB-BCA3-ED3E43147FA1), iPhone 17 Pro/iOS 27.0. Hardware-free UI smoke only was executed there. The app unit lane used the existing simulator named ShareComposerMatrix-1010. Full iPad/old-iOS/watch/hardware/radio/flash matrices were not run. Alternate LED backends were source-reviewed but not separately built. Missing local audio/decoder success prevents a transcode-alignment claim.

No implementation fix, new regression test, commit, push, issue publication, physical reset, hardware firmware upload or account mutation was performed. Standalone audit files and scratch probes are the only authored outputs.
