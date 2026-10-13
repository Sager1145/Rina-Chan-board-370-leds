# Firmware audit checkpoint — 2026-10-13 (INCOMPLETE)

This is an interrupted, read-only audit checkpoint. The requested full per-file firmware review has **not** been completed; `firmware-coverage.csv` records the exact state for each of 100 non-generated, non-binary files. No firmware source, test, tool, or configuration file was changed by this reviewer. The existing dirty tree was preserved.

## Confirmed verification results

- `python3 tools/protocol_selftest.py` exited 1. It reached `esp32s3_firmware/test/host/playback_ownership_test.py` after preceding suites passed, then Clang rejected its generated C++ at line 10: `unused variable 'SCROLL_DRIFT_RESET_INTERVALS' [-Werror,-Wunused-const-variable]`. The unused constant is declared in the Python test at line 26. This is a **host test harness compiler failure**, not evidence of a firmware production failure. Existing aggregate log: `/tmp/rina-audit-20261013/firmware/host-tests.log`; exit file: `host-tests.exit` in the same directory.
- The five remaining Python host tests that the aggregate did not reach were run independently and each exited 0: `presentation_telemetry_test.py`, `rmt_recovery_test.py`, `serial_network_scheduling_test.py`, `stress_findings_test.py`, and `web_setup_test.py`. Log: `/tmp/rina-audit-20261013/firmware/remaining-host-tests.log`.
- The attempted PlatformIO firmware build exited 1 **before compilation**: Python raised `PermissionError: [Errno 1] Operation not permitted: '/Users/sager/.platformio/platforms.lock'` while resolving platform dependencies. This cannot establish build success or a production compile defect. Existing log: `/tmp/rina-audit-20261013/firmware/build.log`; exit file: `build.exit` in the same directory.

## Findings and limits at interruption

No new production defect was confirmed in the partial source review. The earlier 2026-10-12 firmware audit's FW-A1 through FW-A12 findings and their documented repairs are prior evidence, not fresh findings in this checkpoint. The current review had begun tracing framing, blob bounds, transport lifetime, Wi-Fi mode changes, group timing, render ownership, and task scheduling. Protocol command handling, most production modules, host test source, tools, resources, and config still require file-by-file review. Hardware behavior, flashing, power-loss storage behavior, and physical BLE/Wi-Fi/RMT timing were not tested.

## Next work after the commit snapshot

Finish every `pending` and `partial` row in the coverage ledger; analyze all protocol handlers and the remaining production modules, host fakes/tests, generators, configuration and resources; run a firmware build with a writable PlatformIO environment; and fix or isolate the host harness warning before claiming aggregate host-suite success. Keep architecture/test gaps distinct from verified correctness defects, and provide exact lines, trigger, evidence, impact, fix and regression check for any new finding.
