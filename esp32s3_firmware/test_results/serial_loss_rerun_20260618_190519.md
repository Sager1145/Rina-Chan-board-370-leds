# SERIAL_TEST_PLAN Rerun - Serial Loss Focus

First failing point: after successful upload with `run_rinachan_unifont.ps1 -UploadFirmware -UploadFS`, COM7 emits only the ESP-ROM boot banner and core-dump warning, then the firmware console never emits `console_ready`; all baseline commands return zero bytes. Wi-Fi/WebUI later comes up, so the firmware is alive, but USB serial diagnostics are lost before section 0.2 baseline.

Raw boot probe: `test_results/boot_probe_20260618_185400.log`

| step | command/control | interface | result | notes |
|---|---|---|---|---|
| 0.1 | `run_rinachan_unifont.ps1 -UploadFirmware -UploadFS` | setup | PASS | Correct upload script completed successfully before this rerun: firmware and LittleFS both flashed; test_harness.js served with HTTP 200. |
| 0.3 | `USB serial 115200 8N1 on COM7` | serial | FAIL | COM7 opens and ROM boot banner is received, but no firmware console output follows. |
| 0.2 baseline | `status / led current / auto status / face status / scroll status / log status` | serial | FAIL | All baseline commands returned 0 bytes after a 45s boot listen. This is the first test-plan failure point; section 0.2 cannot be completed. |
| 1 Console liveness & help | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 2 Logging control | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 3 Button emulation | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 4 LED diagnostics | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 5 ADC / battery | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 6 Mode / face / auto | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 7 Scroll | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 8 Built-in self-test runner | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 9 Regression serial-observable checks | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 9b Serial parity and option sweeps | `all listed serial commands` | serial | BLOCKED | Blocked by first serial failure at baseline: firmware receives/responds with no bytes on COM7 after ROM boot. |
| 9c connect | `netsh wlan connect RinaChanBoard-V2; HTTP 192.168.1.14` | WebUI | PASS | Wi-Fi connection request succeeded; TCP port 80 reachable from 192.168.1.15; /api/status returns JSON; /test_harness.js returns HTTP 200. |
| 9c harness load | `open http://192.168.1.14/?ui_badges=1` | WebUI | PARTIAL | Harness script is present and tags DOM controls: 391 data-testid elements observed. In-app browser evaluate runs in isolated scope and cannot access page window.__ui; javascript: URL page-scope probe is blocked by browser security policy. |
| 9c.1-9c.11 | `drive controls via window.__ui` | WebUI | BLOCKED | Wi-Fi is available, but available browser tooling cannot call page-scope window.__ui. A local Playwright fallback was attempted, but bundled Node package is incomplete: missing playwright-core. |
| 10 restore | `serial restore commands` | serial | BLOCKED | Serial restore cannot be verified over COM7. Web API remains available, but the requested serial restore verification cannot run. |

SUMMARY pass=2 warn=0 fail=2 blocked=12 partial=1
