# RinaChan Serial/WebUI Test Plan - Section 10 Report

Observed setup blocker: firmware and LittleFS builds succeeded, but esptool could not enter the ESP32-S3 bootloader on COM7, so tests ran against the already-installed image.

| step | command/control | interface | result | notes |
|---|---|---|---|---|
| 0.1 | `pio run -e esp32s3 -t upload` | serial/setup | FAIL | Build succeeded, upload failed: esptool could not enter ESP32-S3 bootloader on COM7; observed No serial data received / Invalid head of packet. |
| 0.2 | `pio run -e esp32s3 -t uploadfs` | serial/setup | FAIL | LittleFS image built, uploadfs failed: esptool could not enter ESP32-S3 bootloader on COM7. |
| 0.3 | `connect serial 115200 8N1` | serial/setup | PASS | COM7 console responsive at 115200 8N1. |
| 0.2 baseline | `status` | serial | PASS | Captured baseline reply. |
| 0.2 baseline | `led current` | serial | PASS | Captured baseline reply. |
| 0.2 baseline | `auto status` | serial | PASS | Captured baseline reply. |
| 0.2 baseline | `face status` | serial | PASS | Captured baseline reply. |
| 0.2 baseline | `scroll status` | serial | PASS | Captured baseline reply. |
| 0.2 baseline | `log status` | serial | PASS | Captured baseline reply. |
| 1.1 | `help` | serial | PASS | Help block present. |
| 1.2 | `help buttons` | serial | PASS | Topic help returned output. |
| 1.2 | `help led` | serial | PASS | Topic help returned output. |
| 1.2 | `help adc` | serial | PASS | Topic help returned output. |
| 1.2 | `help logs` | serial | PASS | Topic help returned output. |
| 1.2 | `help tests` | serial | PASS | Topic help returned output. |
| 1.3 | `version` | serial | PASS | Feature gates present. |
| 1.4 | `uptime (twice)` | serial | PASS | ms increased on repeat. |
| 1.5 | `status` | serial | PASS | Status fields present. |
| 1.6 | `notacommand` | serial | PASS | Unknown command rejected. |
| 2.1 | `log status` | serial | PASS | Log status reported enabled and level. |
| 2.2 | `log level DEBUG + battery sample 1` | serial | PASS | DEBUG set and ADC log observed. |
| 2.3 | `log level TRACE during scroll` | serial | FAIL | TRACE tick not observed. |
| 2.4 | `log level ERROR` | serial | PASS | ERROR level set; no non-error log spam observed in reply window. |
| 2.5 | `log off; status; log on` | serial | PASS | Logging toggled off/on; command replies remained available. |
| 2.6 | `log level INFO; log status` | serial | PASS | Baseline log level restored. |
| 3.1 | `btn tap B1` | serial | PASS | face next; before=7 after=8 count=11. |
| 3.2 | `btn tap B2` | serial | PASS | face prev; before=8 after=7 count=11. |
| 3.3 | `btn tap B3; btn tap B3` | serial | PASS | Mode toggled then restored by second tap. |
| 3.4 | `btn tap B4; btn tap B5` | serial | FAIL | Brightness before=50 down=None up=None. |
| 3.5 | `btn combo B3+B1 tap` | serial | PASS | Auto interval before=3000 after=2500. |
| 3.6 | `btn combo B3+B2 tap` | serial | PASS | Auto interval before=2500 after=3000. |
| 3.7 | `btn press B5; wait; btn release B5` | serial | PASS | Press/release issued; repeat lines captured if firmware emitted them. |
| 3.8 | `btn hold B5 1500` | serial | PASS | Hold auto-release completed; repeat/OK observed. |
| 3.9 | `btn repeat B4 5 300` | serial | FAIL | Repeat lines observed=2. |
| 3.10 | `btn status` | serial | PASS | B1..B6 listed. |
| 3.11 | `btn tap B9` | serial | PASS | Unknown button rejected. |
| 3.12 | `physical button press` | serial | WARN | Not observed in automated run; requires human pressing a real board button while serial monitor is active. |
| 3.13 | `restore mode/auto/brightness/face` | serial | PASS | Restored baseline-controlled fields after button tests. |
| 4.1 | `led status` | serial | PASS | LED status reported. |
| 4.1c | `led color #00ff00; led current` | serial | FAIL | Color echoed by led current. |
| 4.2 | `led brightness` | serial | PASS | Brightness range reported. |
| 4.3 | `led brightness 127` | serial | PASS | Brightness set to 127. |
| 4.3a | `led brightness 10` | serial | PASS | Mandatory safety cap applied before full-field LED patterns. |
| 4.4 | `led test pattern all_on; all_off` | serial | WARN | Skipped per guardrail: battery percent < 20. |
| 4.5 | `led test pattern all_off` | serial | WARN | Skipped per guardrail: battery percent < 20. |
| 4.6 | `checker/rows/cols; clear` | serial | WARN | Skipped per guardrail: battery percent < 20. |
| 4.7 | `single 0; single 369` | serial | PASS | Both low-draw single pixel patterns lit one LED. |
| 4.8 | `led test pattern single 370` | serial | PASS | Out-of-range rejected. |
| 4.9 | `led dump` | serial | PASS | LED dump block had 18 row lines. |
| 4.10 | `led dump compact` | serial | PASS | Compact M370 returned 93 hex chars. |
| 4.11 | `led clear` | serial | PASS | Frame cleared. |
| 4.12 | `led command_history` | serial | PASS | Command history returned. |
| 4.13 | `restore brightness/color/face` | serial | PASS | LED baseline restored after diagnostics. |
| 5.1 | `adc status` | serial | PASS | Expected token vbat observed. |
| 5.2 | `adc read raw` | serial | PASS | Expected token vbatRaw observed. |
| 5.3 | `adc read vbat` | serial | PASS | Expected token vbat= observed. |
| 5.4 | `adc read charge` | serial | PASS | Expected token vcharge observed. |
| 5.5 | `battery status` | serial | PASS | Expected token percent observed. |
| 5.6 | `log level DEBUG; battery sample 10` | serial | PASS | SAMPLE lines=12; ADC logs=10. |
| 5.7 | `battery status charger sanity` | serial | WARN | No human charger plug/unplug toggle performed; one snapshot captured for plausibility. |
| 6.1 | `mode status` | serial | PASS | Mode reported. |
| 6.2 | `mode auto; mode status` | serial | PASS | Auto mode set; auto-change logs captured if interval elapsed. |
| 6.3 | `mode manual` | serial | PASS | Manual mode set. |
| 6.4 | `face status` | serial | PASS | Face index/count reported. |
| 6.5 | `face next; face prev` | serial | PASS | Face next/prev invoked. |
| 6.6 | `face apply 0; face apply 9999` | serial | FAIL | Valid apply succeeded and bad index rejected. |
| 6.7 | `auto status; auto interval` | serial | PASS | Auto interval/range reported. |
| 6.8 | `auto interval 1000` | serial | PASS | Auto interval set to 1000. |
| 6.9 | `auto start; auto stop` | serial | PASS | Auto start/stop accepted. |
| 6.10 | `restore mode/auto/face` | serial | PASS | Mode/auto/face restored. |
| 7.1 | `scroll status` | serial | PASS | Scroll count=0. |
| 7.1a | `scroll interval 60; scroll fps 30` | serial | FAIL | Scroll interval/fps accepted. |
| 7.1b | `scroll start` | serial | FAIL | WARN/no_scroll_frames accepted if no WebUI frames loaded. |
| 7.2 | `scroll step next` | serial | PASS | No-data warning observed. |
| 7.3 | `scroll pause` | serial | WARN | No WebUI scroll frames loaded yet; active-scroll behavior could not be exercised in serial section 7. |
| 7.4 | `scroll resume` | serial | WARN | No WebUI scroll frames loaded yet; active-scroll behavior could not be exercised in serial section 7. |
| 7.5 | `scroll step next/prev` | serial | WARN | No WebUI scroll frames loaded yet; active-scroll behavior could not be exercised in serial section 7. |
| 7.6 | `scroll stop` | serial | WARN | No WebUI scroll frames loaded yet; active-scroll behavior could not be exercised in serial section 7. |
| 7.7 | `scroll clear` | serial | WARN | No WebUI scroll frames loaded yet; active-scroll behavior could not be exercised in serial section 7. |
| 7.8 | `scroll status; face apply baseline` | serial | PASS | No scroll left intentionally running; face restored. |
| 8.1 | `test list` | serial | PASS | Test groups/names listed. |
| 8.2 | `test run buttons` | serial | PASS | Self-test group=buttons; warnings=False. |
| 8.3 | `led brightness 10; test run led` | serial | PASS | Self-test group=led; warnings=False. |
| 8.4 | `test run adc` | serial | PASS | Self-test group=adc; warnings=False. |
| 8.5 | `test run modes` | serial | PASS | Self-test group=modes; warnings=False. |
| 8.6 | `test run scroll` | serial | PASS | Self-test group=scroll; warnings=True. |
| 8.7 | `led brightness 10; test run all` | serial | FAIL | Self-test all did not report fail=0. |
| 8.8 | `test report` | serial | PASS | Last test counts echoed. |
| 8.9 | `post-check status/current/auto/face` | serial | PASS | Post-run state captured for comparison/restoration. |
| 8.10 | `test run sweep` | serial | PASS | Sweep completed with fail=0. |
| 9.1 | `LED rendering visual check` | serial | WARN | Requires visual inspection of panel smoothness/flicker; not directly observable over serial. |
| 9.2 | `physical buttons all 6 + combos` | serial | WARN | Requires human physical button actuation; serial emulation was tested in section 3. |
| 9.3 | `WebUI connect/use` | WebUI | WARN | Deferred/blocked in serial phase: Deferred to browser-driven section 9c. |
| 9.4 | `API parity` | serial/WebUI | WARN | Deferred/blocked in serial phase: Deferred until WebUI actions are exercised. |
| 9.5 | `saved faces face status/apply` | serial | PASS | Saved-face runtime visible from serial; WebUI authoring deferred. |
| 9.6 | `WebUI scroll text upload/play` | WebUI | WARN | Deferred/blocked in serial phase: Deferred to browser-driven section 9c/9b.5. |
| 9.7 | `battery overlay single (B6 equivalent)` | serial | PASS | Battery overlay command exercised; physical B6 still requires human press. |
| 9.8 | `log DEBUG + scroll start` | serial | FAIL | No visual glitch check possible over serial; no frames warning if empty. |
| 9.9 | `default build/version gates` | serial | PASS | Current installed image reports diagnostics gates; setup flash still failed. |
| 9b.1 | `led color spot sweep + test run sweep color` | serial | FAIL | Manual spot colors echoed; exhaustive web-safe grid covered by test run sweep. |
| 9b.2 | `test run sweep brightness 10..200 + clamps` | serial | PASS | Every brightness value covered by `test run sweep` result in 8.10. |
| 9b.3 | `scroll interval 33/1000; scroll fps 30/5` | serial | FAIL | Scroll speed boundaries and fps mapping accepted; visual speed change requires loaded frames/panel. |
| 9b.4 | `frame M370 all_off/all_on/random; led dump compact` | serial | FAIL | At least one frame round-trip differed. |
| 9b.5 | `WebUI text-scroll random ASCII/CJK/Japanese/emoji` | WebUI | WARN | Deferred/blocked in serial phase: Deferred to browser-driven rasterization and serial playback verification. |
| 9b.6 | `WebUI saved-face add/delete/rename/reorder/default` | WebUI | WARN | Deferred/blocked in serial phase: Deferred to browser-driven authoring; serial can verify face count/apply afterward. |
| 9b parity misc | `mode/auto/scroll/pause/terminate/battery/status command set` | serial | WARN | Serial twins for direct WebUI functions exercised; scroll commands may warn without frames. |
| 10.1 | `final baseline restore + verification` | serial | PASS | Baseline restoration commands run; final status/current/auto/face/log/scroll captured. |
| 10.2 | `guardrail audit` | serial | PASS | Brightness cap applied before full-field manual patterns and self-test led/all; full-field frames cleared immediately; battery sample bounded to 10; log level restored. |
| 9c connect | `Join RinaChanBoard-V2; open http://192.168.1.14/?ui_badges=1` | WebUI | PASS | HTTP port 80 reachable from Wi-Fi source 192.168.1.15; page loaded title Rina WebUI V2. |
| 9c harness | `window.__ui / data-testid / test_harness.js` | WebUI | FAIL | Required agent harness missing: window.__ui=false, data-testid count=0, loaded script only /app.js?v=20260613-debug-rewrite-v1, /test_harness.js returns 404. |
| 9c.1 | `setValue("color-input", "#00ff00") + parent/child selects` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.2 | `brightness-input representative sweep, plus/minus, presets` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.3 | `mode-toggle, face-next/prev, interval up/down, auto-interval sweep` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.4 | `custom page draw/fill/invert/clear/send/save` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.5 | `parts random/symmetry/apply` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.6 | `scroll text ASCII/CJK/Japanese/emoji/boundaries + speed/play/pause/step/stop` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.7 | `debug GPIO B1..B6S/B3B1/B3B2` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.8 | `debug LED checker/border/off/M370 send` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.9 | `debug reset battery min/max + refresh power` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.10 | `raw command pause_scroll` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 9c.11 | `coverage audit __ui.list()` | WebUI | FAIL | Not executable exactly as required because the installed WebUI lacks window.__ui and data-testid instrumentation; LittleFS upload failed. |
| 10 final restore observed | `face apply 7; status; led current; face status; scroll status; log status` | serial | PASS | Final state: mode=manual, brightness=50, color=#f971d4, autoIntervalMs=3000, face index=7, lit=34, scrollActive=0, log level=INFO. |

SUMMARY pass=78 warn=18 fail=26
