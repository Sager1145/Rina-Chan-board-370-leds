# Firmware repair progress

Production-TU regression harness: esp32s3_firmware/test/host/audit_repairs_test.py compiles actual state/utils/scroll_session/led_renderer/storage/faces/config/button_animations/wifi_manager, plus included protocol/main/scroll; fake only hardware/NVS/radio/FreeRTOS scheduling. ASan/UBSan and -Wall -Wextra -Werror. Fresh executable process + filesystem per case.

RED command: python3 esp32s3_firmware/test/host/audit_repairs_test.py
Observed all 12 intended behavior failures before production edits (exit 1): battery snapshot, already-ended group pause, visible loop preference, invalid AP bytes, AP radio application failure, configured home beyond 64 scan entries, off-mode scan restoration, duplicate/missing face identity, failed renderer-task fallback, registry reconnect teardown, retry presentation context, hint-over-overlay pixel.

Initial harness compilation errors corrected before this red run (moved CPP filename to avoid aggregate runner discovery, corrected actual struct field names, added task/assert headers). No production edits existed during corrected red run.

FW-A11 runner repair is parent-owned.

GREEN command: python3 esp32s3_firmware/test/host/audit_repairs_test.py
All 12 cases PASS, exit 0; ASan/UBSan, strict compiler warnings, actual production translation units.

Dispositions:
- FW-A1 fixed: copy all five battery snapshot fields at overlay start; green fresh/repeated actual overlay pixel regression (healthy 83%, stale long overlay -> healthy short).
- FW-A2 fixed: pause/end latch happens independently of final-frame republishing; green one-frame, start-at-final, late-start final fixtures and stable repeated ticks.
- FW-A3 fixed: group_start updates the externally reported scrollLoop and loop controls update groupLoop; green active loop true/false transitions and nonloop end rewind/resume.
- FW-A4 fixed: common AP setter rejects SSID outside 1..32 bytes and nonempty password outside 8..63 before changes. Hardware AP config/start result determines apActive; failed application returns false and restores runtime credentials without NVS writes. BLE/TCP and HTTP report rejection truthfully. Tests cover empty/short/overlength, limits/open AP, radio failure, runtime/NVS preservation.
- FW-A5 fixed: resolve configured profiles across every scan entry; top-20 insertion retains strongest entries over entire scan for UI. Green Home at index70 and stronger Hotspot at71, Home preferred, 20-row cap and strongest entry retained.
- FW-A6 fixed: restore temporary pre-scan OFF/AP mode after success/failure; applying a new mode cancels old restoration. Green off-success/off-start-failure and AP superseding old off-mode scan.
- FW-A7 fixed: nonempty unique identities at validation seam; green default/custom collision, empty/missing IDs, production BLOB rejection and unchanged stored file bytes.
- FW-A8 fixed: task starter returns readiness separately from mutex allocation. One shared render/scroll iteration runs from either task or main-loop fallback. Green setup allocation failure, frame render and ongoing timeline advancement; scroll capability remains supported by fallback.
- FW-A9 fixed: call carrier disconnect while registry slot still claimed, outside registry critical section; then publish slot free. Green production registry with reconnect callback immediately before carrier mapping check; newer peer stays connected, slot used and inbound usable.
- FW-A10 fixed: version presentation publications (including invalid/manual context). Failed refresh requeues consumed context only while its version still owns pending publication. Green paused seek and nonloop final source fail-once-success telemetry, failed latch not counted, newer owner during refresh preserves both identity and pixels.
- FW-A11 parent-owned runner repair; not modified here.
- FW-A12 fixed: apply hint/mirror after base content or button overlay, except identify. Green actual driver pixel checks for hint>button and identify>hint. Removed the old ordering-string assertion; actual renderer regression replaces it.

Existing focused tests green: playback_ownership_test.py (updated extraction to include shared service; original takeover assertions retained), group_identify_test.py, hint_led_test.py.
Aggregate host run in progress: python3 tools/protocol_selftest.py > /tmp/rina-firmware-selftest.log 2>&1 (session36723).
Firmware PlatformIO build and board flashing parent-owned. No hardware uploads/serial access/commits/subagents from this worker. Radio, FreeRTOS and hardware faults are deterministic adapter injections; live radio/timing not established.

Final host aggregate: python3 tools/protocol_selftest.py completed exit 0, protocol_selftest: PASS. Log: /tmp/rina-firmware-selftest.log. Four C++ suites and all fourteen Python host scripts discovered (including audit_repairs_test.py). Separate complete twelve-case ASan/UBSan run above establishes the new cases; aggregate log has no per-case lines for that script, so use the earlier explicit case outputs as behavioral evidence.

Expanded focused confirmations after the original full green run: python3 esp32s3_firmware/test/host/audit_repairs_test.py ap_validation render_fallback presentation_retry completed exit 0 with all three PASS. AP test now exercises production BLE/TCP command replies; fallback test confirms main-loop rendering stops after successful task start; retry test confirms an untracked manual publication also supersedes old scroll context. No production behavior changed after original green run (only truthful HTTP AP error string and BLE comment).

git -c core.fsmonitor=false diff --check -- esp32s3_firmware/src esp32s3_firmware/test passed. No added whitespace errors.

## FW-A4 independent-review correction

Independent reviewer found that operation failure was still being mistaken for AP inactivity: pinned core AP.cpp get/set-config failure leaves an old AP started; false apActive makes actual web_setup service stop HTTP/DNS. The original ap_failure fake lacked explicit radio-started state and its inactive-status assertion was wrong for this case.

Regression now models explicit WiFi.AP.started() state and compiles actual web_setup.cpp with hardware HTTP/DNS adapters. RED: python3 esp32s3_firmware/test/host/audit_repairs_test.py ap_failure ap_initial_failure returned1; rejected reconfiguration incorrectly cleared active AP status, while initial failure case passed.

Minimal production correction: startSoftAp stores the AP operation result as applied and returns that result. Actual serving state is applied || (wasActive && WiFi.AP.started()). Thus wifiManagerSetAp still rejects/rolls back failed updates without NVS writes; an old started AP retains HTTP/DNS, but stopped or failed initial AP remains inactive. No retries or unrelated configuration changes added.

Targeted green validation pending (six AP/scan/fallback cases); parent rebuilding firmware. Root requests reusing valid earlier aggregate instead of repeating it.

FW-A4 correction GREEN: python3 esp32s3_firmware/test/host/audit_repairs_test.py ap_failure ap_initial_failure ap_validation scan_visibility scan_restore render_fallback completed exit0. All six cases PASS under ASan/UBSan and strict compiler warnings. Real web_setup service preserved HTTP/DNS on rejected updates and stopped them only for a genuinely unavailable AP. Includes IP-config rejection while old AP stays active and driver failure that actually stops AP.

git -c core.fsmonitor=false diff --check -- esp32s3_firmware/src esp32s3_firmware/test also passed after this correction. Previous aggregate remains reused as root directed; incremental firmware rebuild is parent-owned and required for wifi_manager.cpp change.
