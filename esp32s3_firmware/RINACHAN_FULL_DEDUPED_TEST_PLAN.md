# RinaChan Board — Full Deduplicated Serial + WebUI + Firmware Test Plan

**Make the process visible while testing:** keep the serial monitor, HTML/WebUI page, browser automation actions, test runner/report output, and the physical LED display/panel visible whenever possible. **While clicking any WebUI button, the WebUI page must be open, connected, visibly available, and the clicked control plus resulting UI state must be observable.** Whenever testing LED colors or brightness, keep the physical LED display/panel visible and keep the board showing only the default face.

**Hard LED safety rule:** Do not light up all LEDs on the physical display at any time. Do not run `all_on` / full-all-on patterns during this test plan; use sparse/default-face/checker/row/column/single-pixel/default-face patterns only, and clear test patterns immediately. Do not confirm or execute any WebUI button action that would intentionally send an all-on / `lit=370` frame; test such buttons only through a safe cancel/blocked/guard path, and prove no all-on frame was sent.

This is the single combined test plan for the ESP32-S3 RinaChan Board firmware and WebUI. It merges and deduplicates the serial feature plan, WebUI/scroll plan, serial diagnostics notes, and serial-console implementation plan.

Use this file as the main test procedure. Keep the older files only as historical/reference documents.

---

## 0. Scope and pass rule

### 0.1 What this plan covers

This plan verifies:

- firmware build, upload, filesystem upload, and boot;
- serial console liveness, diagnostics, logging, command replies, and self-tests;
- battery and ADC telemetry;
- LED color, brightness, frame, sparse/safe pattern, and M370 behavior;
- default-face-only color/brightness exhaustive testing;
- WebUI control coverage using `window.__ui`;
- every firmware-affecting WebUI button and every selectable WebUI option;
- scroll text upload, play, pause, resume, step, stop, clear, reload, and drift behavior;
- custom face drawing, saving, applying, deleting, and edge cases;
- parts-face generation from actual selected parts, not only the random button;
- physical/serial/WebUI GPIO button behavior and button combinations;
- robustness and edge cases;
- implementation/source verification;
- initial reset, JSON baseline capture, final restore, persistence reset verification, and report.

### 0.2 Required result labels

Use only:

| Label | Meaning |
|---|---|
| `PASS` | Tested and all expected behavior/evidence was observed. |
| `FAIL` | Tested and expected behavior/evidence was missing or wrong. |
| `WARN` | Tested but has a risk, limitation, low-battery/no-battery skip, or non-blocking anomaly. |
| `SKIP` | Not run, with a concrete reason. |

Do not mark any untested item as `PASS`.

### 0.3 Completion rule

The full run is complete only when all of the following are true:

1. firmware build/upload succeeded;
2. filesystem/WebUI upload succeeded or was confirmed already current;
3. serial monitor and WebUI were both used;
4. battery state was checked before LED tests;
5. all required serial, WebUI, GPIO, scroll, face, and edge-case suites were run;
6. every `firmware_effect` WebUI control produced valid API/serial/log evidence;
7. every local/file-only control was classified and checked for no browser errors;
8. every WebUI `<button>` was clicked/tested at least once, except safety-prohibited firmware-send paths which must be tested only by cancel/blocked/guard behavior;
9. the board was reset before tests and the post-reset baseline was saved to `SETTINGS_BASELINE_BEFORE_TEST.json`;
10. baseline state was restored from that JSON after tests;
11. the board was reset again after restore;
12. post-reset settings persistence was verified against `SETTINGS_BASELINE_BEFORE_TEST.json`;
13. `RUN_ALL_TESTS_REPORT.md` was generated.

---

## 1. Required tools and interfaces

### 1.1 Hardware and host

- ESP32-S3 RinaChan Board connected over USB serial.
- Host machine with PlatformIO.
- Browser automation or AI agent capable of DevTools/evaluate actions.
- HTTP client such as `curl`, browser `fetch`, or a test script.
- Optional: pyserial host harness such as `tools/serial_test.py`.

### 1.2 Serial monitor

Open serial at:

```text
115200 8N1
```

Recommended command:

```bash
pio device monitor -b 115200
```

Commands are plain text with newline.

### 1.3 WebUI connection

Board SoftAP:

```text
SSID: RinaChanBoard-V2
Password: rinachan
Base URL: http://192.168.1.14/
Alternate captive domain: http://rina.io/
```

When testing WebUI controls, prefer:

```text
http://192.168.1.14/?ui_badges=1
```

**Try to make the serial monitor and HTML page visible while testing.**

### 1.4 WebUI agent API

Use `window.__ui` instead of pixel-coordinate clicking:

```js
__ui.list()
__ui.list({ visibleOnly: true, page: "page-basic" })
__ui.find("brightness")
__ui.click("brightness-plus")
__ui.click(1042)
__ui.setValue("brightness-input", 127)
__ui.setValue("scroll-text", "你好 こんにちは 🎉")
__ui.get("mode-toggle")
__ui.gpio("B1")
__ui.pages()
__ui.nav()
__ui.badges(true)
```

General WebUI test loop:

1. discover controls with `__ui.list()`;
2. navigate to the page;
3. click/change the control;
4. read `__ui.get(...)`;
5. verify via `/api/status`, `/api/scroll/meta`, serial command output, and serial logs.

---

## 2. Upload, build, and boot

### 2.1 Build

Use the repo's correct upload script or documented PlatformIO commands. Do not invent a new upload method.

Default commands:

```bash
pio run -e esp32s3
```

Optional verbose test build if available:

```bash
pio run -e esp32s3-test
```

### 2.2 Upload firmware

```bash
pio run -e esp32s3 -t upload
```

or, if the repo provides a board-specific upload script, use that script and record the exact command.

### 2.3 Upload filesystem/WebUI

```bash
pio run -e esp32s3 -t uploadfs
```

`uploadfs` may overwrite LittleFS and saved faces. Back up `/resources/saved_faces.json` if needed.

### 2.4 Host-side parse checks

Before on-device testing:

```bash
node --check data/app.js
node --check data/test_harness.js
pio run -e esp32s3
```

Record all results.

### 2.5 Boot sanity

Serial commands:

| Step | Command | Expected |
|---|---|---|
| B0.1 | `help` | Help block appears. |
| B0.2 | `version` | Firmware version, feature gates, heap. |
| B0.3 | `uptime` twice | Milliseconds increase. |
| B0.4 | `status` | Runtime state block. |
| B0.5 | `notacommand` | `ERR` reply and command reject log. |

WebUI/API checks:

| Step | Action | Expected |
|---|---|---|
| B0.6 | Join `RinaChanBoard-V2` | Host IP is on `192.168.1.x`. |
| B0.7 | `GET /api/status` | HTTP 200 and `ok:true`. |
| B0.8 | Open WebUI | `#nav` visible, page loaded, no browser `SyntaxError`/`TypeError`. |

### 2.1 Mandatory pre-test board reset and JSON settings baseline

Before running any functional, LED, WebUI, GPIO, scroll, face, edge-case, or regression test, reset the board first and capture the clean post-reset settings state.

1. Reset the board:

```text
reboot
```

If serial `reboot` is unavailable at this point, press the physical reset/EN button and record:

```text
WARN reason=no_serial_reboot_command_pretest
```

2. Wait until the board is reachable again, then verify boot:

```text
version
status
face status
battery status
```

3. Record all available settings and persistent state into a JSON file named:

```text
SETTINGS_BASELINE_BEFORE_TEST.json
```

The JSON must include, when available:

```json
{
  "capturedAfterInitialReset": true,
  "serial": {
    "version": {},
    "status": {},
    "ledCurrent": {},
    "autoStatus": {},
    "faceStatus": {},
    "scrollStatus": {},
    "batteryStatus": {},
    "logStatus": {}
  },
  "api": {
    "status": {},
    "power": {},
    "scrollMeta": {},
    "savedFaces": {},
    "savedFacesRawJson": ""
  },
  "restoreTargets": {
    "mode": "manual|auto",
    "brightness": 0,
    "color": "#RRGGBB",
    "autoFaceIndex": 0,
    "autoIntervalMs": 0,
    "scrollIntervalMs": 0,
    "logLevel": "INFO",
    "savedFacesShouldMatchRawJson": true
  }
}
```

4. Source commands/API calls for this JSON should include:

```text
version
status
led current
auto status
face status
scroll status
battery status
log status
GET /api/status
GET /api/power
GET /api/scroll/meta
GET /api/saved_faces, /resources/saved_faces.json, or the implemented saved-face endpoint/file path
```

5. The test run must use this JSON as the single restore target at teardown. Do not replace this baseline with a later mutated state.

---

## 3. Output, evidence, and logging contract

### 3.1 Serial evidence format

Diagnostic log lines must be machine-parseable:

```text
[<millis> ms] [<LEVEL>] [<CATEGORY>] key=value key=value ...
```

Command replies must be one of:

```text
OK <cmd> ...
ERR <cmd> <reason>
WARN <cmd> <reason>
```

Multi-line dumps must be wrapped:

```text
=== <TAG> BEGIN ===
...
=== <TAG> END ===
```

### 3.2 Log levels

Default level should be `INFO`.

| Level | Use |
|---|---|
| `ERROR` | failures only |
| `WARN` | recoverable issues and rejected commands |
| `INFO` | normal button/mode/face/LED/scroll/API events |
| `DEBUG` | ADC samples, detailed button state |
| `TRACE` | rate-limited scroll tick information |

Logging test:

| Step | Command | Expected |
|---|---|---|
| L1 | `log status` | Shows enabled state and level. |
| L2 | `log level DEBUG` | Battery samples emit ADC/debug lines. |
| L3 | `log level TRACE` | Active scroll emits rate-limited scroll tick lines. |
| L4 | `log level ERROR` | Only errors after this point. |
| L5 | `log off`, then `log on` | Logs stop, then resume. |
| L6 | `log level <baseline>` | Restored. |

### 3.3 Evidence rule

For every firmware-affecting action, record:

```text
test_id
interface: serial | WebUI | HTTP | physical
action
expected result
observed API/serial/log result
PASS/WARN/FAIL/SKIP
notes
```

A WebUI control can pass only if:

- the control exists;
- the click/change happened through the WebUI;
- firmware/API implementation exists;
- `/api/status`, `/api/scroll/meta`, serial command output, or serial logs confirm the result;
- browser console has no uncaught error caused by the action.

---

## 4. Safety guardrails and battery gate

### 4.1 Mandatory battery check before LED sweeps

Before any LED sweep or exhaustive WebUI LED test, run:

```text
battery status
adc status
```

Also click WebUI:

```text
debug-refresh-power
```

Record:

```text
vbat
batteryPercent
charging
batValid/disconnected if available
battery-present judgment
```

### 4.2 No battery brightness cap

If no battery is connected, battery reading is invalid, or battery presence is ambiguous:

- do not test brightness above `120`;
- allowed brightness preset buttons are only `10`, `25`, `50`, and `80`;
- mark `128`, `160`, and `200` as:

```text
WARN reason=no_battery skip_brightness_above=120
```

### 4.3 Low battery

If `battery status` shows low voltage or `percent < 20` and not charging:

- skip dense LED pattern tests; never run all-LED-on patterns regardless of battery state;
- mark them:

```text
WARN reason=low_battery
```

### 4.4 LED pattern safety — no all-LED-on tests

Do **not** run any pattern that lights all 370 LEDs at once. The `all_on` pattern is prohibited for this test plan, even at low brightness.

Before any sparse/dense-but-not-all pattern test:

```text
led brightness 10
```

Immediately clear after each pattern:

```text
led test pattern all_off
```

or:

```text
led clear
```

Never leave `rows`, `cols`, `checker`, or any other test pattern lit while reading or thinking. Expected lit count for every allowed test pattern must be `< 370`.

### 4.5 Sampling and logging limits

- Do not run tight ADC/battery sampling loops.
- Use `battery sample 10` at most during routine testing.
- Keep `DEBUG`/`TRACE` temporary.
- Restore log level to baseline after each detailed logging section.

---

## 5. Baseline JSON capture and restore

### 5.1 Source of truth baseline

The source of truth baseline is `SETTINGS_BASELINE_BEFORE_TEST.json`, captured after the mandatory initial board reset in §2.1.

Do not use a mid-test state as the restore target. Every restore step must use the values saved in `SETTINGS_BASELINE_BEFORE_TEST.json`.

The baseline JSON must contain at least:

```text
mode
brightness
color
autoFaceIndex
autoIntervalMs
scrollIntervalMs
scroll active/paused/count
face id/count/index
saved faces raw JSON or equivalent persistent saved-face data
battery voltage/percent/charging
log level
```

### 5.2 Restore baseline after major suites and at final teardown

Use values from `SETTINGS_BASELINE_BEFORE_TEST.json`:

```text
scroll stop
log level <json.restoreTargets.logLevel>
led color <json.restoreTargets.color>
led brightness <json.restoreTargets.brightness>
mode <json.restoreTargets.mode>
auto interval <json.restoreTargets.autoIntervalMs>
scroll interval <json.restoreTargets.scrollIntervalMs>
face apply <json.restoreTargets.autoFaceIndex>
```

If saved faces or user-face storage changed, restore saved-face storage from `json.api.savedFacesRawJson` or the equivalent saved-face object captured in the baseline JSON before continuing.

Then verify current state against `SETTINGS_BASELINE_BEFORE_TEST.json` using:

```text
status
led current
auto status
face status
scroll status
battery status
log status
GET /api/status
GET /api/power
GET /api/scroll/meta
GET /api/saved_faces, /resources/saved_faces.json, or the implemented saved-face endpoint/file path
```

A restore is not complete until every persistent setting that can be restored matches the baseline JSON, except for volatile fields such as uptime, heap, timestamps, battery voltage drift, and counters.

---

## 6. WebUI control manifest and classification

### 6.1 Capture full manifest

In browser DevTools/evaluate:

```js
const manifest = __ui.list();
console.table(manifest);
JSON.stringify(manifest, null, 2);
```

Save the result into the final report.

### 6.2 Classification types

Every control from `__ui.list()` must be classified:

| Type | Meaning | Required evidence |
|---|---|---|
| `firmware_effect` | Sends command or changes firmware state | API/serial/log state change |
| `local_only` | DOM/browser-only behavior | DOM change and no JS error |
| `file_io_only` | download/copy/open/import local file behavior | File action or justified skip |
| `destructive_requires_confirm` | Deletes/resets/clears data | Test cancel and safe confirm flow |
| `debug_webui_only` | Debug helper, not a real physical feature | DOM/API behavior and classification note |
| `unsupported_gap` | Exists but cannot be tested or not implemented | Explain implementation gap |

No unclassified controls are allowed.

### 6.2.1 WebUI availability and button-click evidence gate

Before every WebUI button click, the agent must confirm the HTML/WebUI page is open, connected to the board, visibly available, and on the correct page/section. The report must record the pre-click enabled/disabled state, the click or safe cancel/blocked action, the post-click UI state, and the firmware/API/serial evidence when the button is firmware-affecting.

Every static `<button>` in the current WebUI and every generated button or option button must be clicked/tested at least once. The only exception is a button whose confirmed action would violate the hard LED safety rule or destructively erase data; in that case, the agent must test the visible cancel/blocked/confirmation path, prove the dangerous action did not execute, and record `SKIP` or `WARN` for the unsafe confirmed action with a concrete reason.

A run fails if any button is absent from the final report, unclicked without a permitted safety/destructive reason, or marked `PASS` without observable WebUI state and matching firmware/API/serial evidence where applicable.

### 6.3 Control families that must be covered

At minimum, cover controls on:

| Page | Required families |
|---|---|
| Basic | color input/selects, brightness range/input/buttons/presets, face prev/next, mode toggle, auto interval buttons/range/presets, battery badge |
| Custom | grid cells, send, live toggle, clear, fill, invert, M370 text, copy/import, save, name, saved-face library |
| Parts | left eye, right eye, mouth, cheek options, apply, live toggle, random, reset, symmetry, save |
| Scroll | text, speed range/input/minus/plus/presets/reset, play, pause, stop/clear, step prev/next, progress/readouts |
| Debug | GPIO simulator buttons, firmware pause/resume, LED test buttons, M370 preview/send/clear/copy, power refresh/reset, raw command controls, log controls |


### 6.4 Explicit current WebUI control inventory gate

This explicit inventory is mandatory in addition to the generic `window.__ui.list()` manifest rule. The agent must verify that every exact current control below appears in the manifest or is otherwise discoverable in the DOM, then classify and test it. A run fails if any exact control is absent from the final report, unclassified, or marked `PASS` without evidence.

For duplicate controls that appear in multiple pages, such as saved-face JSON controls under both Custom and Parts, test each page instance separately because the surrounding state and handlers may differ.

#### Global / navigation

| Control | Required classification / test |
|---|---|
| `brand-nav-toggle` | `local_only`; verify menu/nav state changes and no JS error. |
| generated top-nav Basic button | `local_only`; verify navigation to Basic page and active-page state. |
| generated top-nav Custom button | `local_only`; verify navigation to Custom page and active-page state. |
| generated top-nav Parts button | `local_only`; verify navigation to Parts page and active-page state. |
| generated top-nav Scroll button | `local_only`; verify navigation to Scroll page and active-page state. |
| generated top-nav Debug button | `local_only`; verify navigation to Debug page and active-page state. |

#### Basic page

| Control | Required classification / test |
|---|---|
| `color-input` | `firmware_effect`; set colors and verify `/api/status`, serial `[CMD]`, and LED color state. |
| `parent-color-select` | `firmware_effect`; test every parent color group option. |
| `child-color-select` | `firmware_effect`; test every child color option. |
| `brightness-reset-default` | `firmware_effect`; verify default brightness and serial/API evidence. |
| `brightness-minus` | `firmware_effect`; verify decrement/clamp and serial/API evidence. |
| `brightness-plus` | `firmware_effect`; verify increment/clamp and serial/API evidence. |
| `brightness-range` | `firmware_effect`; set allowed values, clamp edge cases, and verify serial/API evidence. |
| `brightness-input` | `firmware_effect`; set allowed values, invalid values, clamp edge cases, and verify serial/API evidence. |
| every generated `brightness-presets` button | `firmware_effect`; click each preset allowed by the battery gate. |
| `face-prev` | `firmware_effect`; verify previous saved face and serial/API evidence. |
| `face-next` | `firmware_effect`; verify next saved face and serial/API evidence. |
| `mode-toggle` | `firmware_effect`; verify Manual/Auto toggle and serial/API evidence. |
| `interval-down` | `firmware_effect`; verify auto interval decrement/clamp and serial/API evidence. |
| `interval-up` | `firmware_effect`; verify auto interval increment/clamp and serial/API evidence. |
| `auto-interval-range` | `firmware_effect`; verify every preset/range edge and serial/API evidence. |
| `auto-interval` | `firmware_effect`; verify input values, invalid values, and serial/API evidence. |
| every generated `auto-interval-presets` button | `firmware_effect`; click every preset and verify firmware interval. |

#### Custom page

| Control | Required classification / test |
|---|---|
| every custom grid cell | `local_only` while drawing; becomes `firmware_effect` when sent/saved. Draw real patterns manually through the grid. |
| `custom-send` | `firmware_effect`; send drawn grid to firmware and verify LED/M370 evidence. |
| `custom-live-toggle` | `firmware_effect` when live-send is enabled; verify live grid edits send/apply. |
| `custom-clear` | `local_only` or `firmware_effect` depending on live toggle; verify grid clears and, if live, firmware clears. |
| `custom-fill` | `local_only` only during this plan; click with live-send disabled, verify the grid fills locally, and do **not** send/apply the all-on frame to firmware. If live-send would make this a firmware all-on action, disable live first or mark the firmware path `SKIP reason=all_leds_prohibited`. |
| `custom-invert` | `local_only` or `firmware_effect` depending on live toggle; verify grid inversion and, if live, firmware applies. |
| `custom-m370` | `local_only` for text editing; `firmware_effect` when imported/sent. Test valid/invalid M370. |
| `custom-copy` | `local_only`; verify clipboard/copy behavior or justified browser-permission skip. |
| `custom-import` | `local_only`/`firmware_effect`; verify valid import changes grid, invalid import rejected, and send/apply path works. |
| `custom-save` | `firmware_effect`; verify saved-face storage write log/API evidence and persistence. |
| `custom-name` | `local_only` input; verify name is used by save, including empty/duplicate/long/Unicode cases. |
| `.faces-json-load` on Custom page | `firmware_effect`; load from firmware storage and verify serial/API evidence. |
| `.faces-json-open-local` on Custom page | `file_io_only`; verify local-file open path or justified skip. |
| `.faces-json-save-local` on Custom page | `file_io_only`; verify save/export behavior or justified skip. |
| `.faces-json-download-all` on Custom page | `file_io_only`; verify download starts or justified skip. |
| `.faces-json-import-btn` on Custom page | `file_io_only` leading to `firmware_effect` if persisted; verify import flow. |
| `.faces-json-import-file` on Custom page | `file_io_only` leading to `firmware_effect` if persisted; verify valid/invalid JSON import. |

#### Parts page

| Control | Required classification / test |
|---|---|
| `parts-apply` | `firmware_effect`; apply selected parts and verify LED/M370 evidence. |
| `parts-live-toggle` | `firmware_effect` when live-send is enabled; verify selected parts update firmware. |
| `parts-random` | `local_only` or `firmware_effect` depending on live toggle; test separately, but do not use it as a substitute for explicit option selection. |
| `parts-reset` | `local_only` or `firmware_effect` depending on live toggle; verify selection reset. |
| `parts-symmetry-toggle` | `local_only`; verify left/right symmetry behavior and no JS error. |
| `parts-m370-text` | `local_only` for text state; verify generated M370 updates and invalid edits are handled. |
| `parts-copy-m370` | `local_only`; verify copy behavior or justified browser-permission skip. |
| `parts-import-m370` | `local_only`/`firmware_effect`; verify valid/invalid M370 import and apply path. |
| `parts-save-bottom` | `firmware_effect`; verify saved-face storage write log/API evidence and persistence. |
| `parts-name` | `local_only` input; verify name is used by save, including Unicode/long/duplicate cases. |
| every left-eye option | `local_only` selection; `firmware_effect` after apply/save. Test every option at least once. |
| every right-eye option | `local_only` selection; `firmware_effect` after apply/save. Test every option at least once. |
| every mouth option | `local_only` selection; `firmware_effect` after apply/save. Test every option at least once. |
| every cheek option | `local_only` selection; `firmware_effect` after apply/save. Test every option at least once. |
| `.faces-json-load` on Parts page | `firmware_effect`; load from firmware storage and verify serial/API evidence. |
| `.faces-json-open-local` on Parts page | `file_io_only`; verify local-file open path or justified skip. |
| `.faces-json-save-local` on Parts page | `file_io_only`; verify save/export behavior or justified skip. |
| `.faces-json-download-all` on Parts page | `file_io_only`; verify download starts or justified skip. |
| `.faces-json-import-btn` on Parts page | `file_io_only` leading to `firmware_effect` if persisted; verify import flow. |
| `.faces-json-import-file` on Parts page | `file_io_only` leading to `firmware_effect` if persisted; verify valid/invalid JSON import. |

#### Scroll page

| Control | Required classification / test |
|---|---|
| `scroll-text` | `local_only` input until upload; verify 100-character CJK/Japanese/emoji text and edge cases. |
| `scroll-speed-reset-default` | `firmware_effect`; verify default speed and serial/API evidence. |
| `scroll-speed-minus` | `firmware_effect`; verify decrement/clamp and serial/API evidence. |
| `scroll-speed-plus` | `firmware_effect`; verify increment/clamp and serial/API evidence. |
| `scroll-speed-range` | `firmware_effect`; verify every speed preset and edge values. |
| `scroll-speed` | `firmware_effect`; verify input values, invalid values, and serial/API evidence. |
| every generated `scroll-speed-presets` button | `firmware_effect`; click every preset `1,10,20,30,40,50,60`. |
| `scroll-play` | `firmware_effect`; upload/start/resume as applicable and verify button state. |
| `scroll-pause` | `firmware_effect`; verify pause/resume and button state. |
| `scroll-stop` | `firmware_effect`; verify stop/clear-screen behavior and button state. |
| `scroll-step-prev` | `firmware_effect`; verify step/hold/wrap and button state. |
| `scroll-step-next` | `firmware_effect`; verify step/hold/wrap and button state. |

#### Debug page

| Control | Required classification / test |
|---|---|
| `firmware-ping` | `firmware_effect`; verify ping/API success and serial/API evidence if available. |
| `debug-fw-refresh-power` | `firmware_effect`; verify firmware power refresh and serial/API evidence. |
| `debug-clear-api-error` | `local_only`; verify error panel clears and no JS error. |
| `debug-copy-diag` | `local_only`; verify clipboard/copy behavior or justified browser-permission skip. |
| `debug-refresh-power` | `firmware_effect`; verify `/api/power`/serial battery evidence. |
| `debug-reset-battery-min` | `destructive_requires_confirm`; test cancel first, then safe confirm only if allowed, and verify serial/API evidence. |
| `debug-reset-battery-max` | `destructive_requires_confirm`; test cancel first, then safe confirm only if allowed, and verify serial/API evidence. |
| ADC details `<summary>` | `local_only`; verify open/close and no JS error. |
| `battery-v` | `local_only`; verify simulated value changes only unless wired to firmware. |
| `charge-v` | `local_only`; verify simulated value changes only unless wired to firmware. |
| `update-adc` | `local_only`; verify simulated UI update and no serial requirement unless actual API call is observed. |
| `debug-ap-pass-toggle` | `local_only`; verify password visibility toggles. |
| `debug-network-refresh` | `firmware_effect` or `debug_webui_only`; verify network values refresh and classify according to actual API path. |
| `gpio-B1` | `firmware_effect`; verify same as B1 button path. |
| `gpio-B2` | `firmware_effect`; verify same as B2 button path. |
| `gpio-B3` | `firmware_effect`; verify same as B3 mode path. |
| `gpio-B4` | `firmware_effect`; verify brightness down path. |
| `gpio-B5` | `firmware_effect`; verify brightness up path. |
| `gpio-B6S` | `firmware_effect`; verify B6 single battery overlay. |
| `gpio-B3B1` | `firmware_effect`; verify auto interval down combo. |
| `gpio-B3B2` | `firmware_effect`; verify auto interval up combo. |
| `gpio-B6L` | `firmware_effect`; verify B6 hold/long battery overlay. |
| `gpio-B6B3` | `debug_webui_only` unless firmware source proves a real combo exists; do not count it as a physical combo. |
| `firmware-pause` | `firmware_effect`; verify pause/resume semantics and distinguish from scroll-page pause if behavior differs. |
| `debug-preview-off` | `local_only`; verify preview changes without firmware LED state change. |
| `debug-preview-checker` | `local_only`; verify preview changes without firmware LED state change. |
| `debug-preview-border` | `local_only`; verify preview changes without firmware LED state change. |
| `debug-preview-saved` | `local_only`; verify preview changes without firmware LED state change. |
| `debug-send-off` | `firmware_effect`; verify LED off frame sent. |
| `debug-send-on` | `destructive_requires_confirm` / safety-prohibited; source-inspect first. Test only the visible cancel/blocked/guard path and prove no all-on / `lit=370` frame is sent. Do **not** confirm the firmware send. If no safe cancel/blocked path exists, do not click it and mark `FAIL reason=safety_violation_risk`. |
| `debug-send-checker` | `firmware_effect`; verify checker frame sent. |
| `debug-send-border` | `firmware_effect`; verify border frame sent. |
| `debug-send-saved` | `firmware_effect`; verify saved face sent/restored. |
| `debug-m370` | `local_only` text state; `firmware_effect` when preview/send uses it. |
| `debug-m370-preview` | `local_only`; verify preview updates without firmware state change. |
| `debug-m370-send` | `firmware_effect`; verify valid/invalid M370 send behavior. |
| `debug-m370-clear` | `local_only`; verify M370 text clears and no JS error. |
| `debug-m370-copy` | `local_only`; verify copy behavior or justified browser-permission skip. |
| `debug-preview-copy` | `local_only`; verify copy behavior or justified browser-permission skip. |
| `log-clear` | `local_only`; verify WebUI log clears. |
| `log-download` | `file_io_only`; verify download starts or justified skip. |
| `log-copy` | `local_only`; verify copy behavior or justified browser-permission skip. |
| raw-command `<summary>` | `local_only`; verify open/close and no JS error. |
| `debug-raw-json` | `local_only`; verify valid/invalid JSON editing. |
| `debug-raw-confirm` | `destructive_requires_confirm`; verify confirm checkbox gates raw send. |
| `debug-raw-validate` | `local_only`; verify valid and invalid JSON validation. |
| `debug-raw-send` | `firmware_effect` or `destructive_requires_confirm`; verify safe command send, invalid command reject, and serial/API evidence. |
| `debug-clear-user-faces` | `destructive_requires_confirm`; test cancel first, then backup/clear/restore user faces, default faces preserved. |

---

## 7. Serial console command coverage

### 7.1 Console liveness

| Step | Command | Expected |
|---|---|---|
| S1.1 | `help` | Lists command groups. |
| S1.2 | `help buttons`, `help led`, `help adc`, `help logs`, `help tests` | Topic help appears. |
| S1.3 | `version` | Feature gates and heap shown. |
| S1.4 | `uptime` | Increasing value. |
| S1.5 | `status` | State snapshot. |
| S1.6 | invalid command | `ERR` + `[CMD] event=reject`. |

### 7.2 Read-only diagnostics

| Step | Command | Expected |
|---|---|---|
| S2.1 | `adc status` | Voltage, percent, raw/calibration fields. |
| S2.2 | `adc read raw` | Raw vbat/vcharge. |
| S2.3 | `adc read vbat` | Plausible vbat/percent. |
| S2.4 | `adc read charge` | Plausible charge voltage/charging state. |
| S2.5 | `battery status` | Battery block. |
| S2.6 | `led status` | LED mode/brightness/frame state. |
| S2.7 | `led current` | Current color/brightness/lit count. |
| S2.8 | `led dump compact` | `M370:<93 hex>` or equivalent compact frame. |
| S2.9 | `led dump` | Row dump plus packed hex. |
| S2.10 | `scroll status` | Scroll active/paused/index/count. |
| S2.11 | `face status` | Saved face index/count/id. |
| S2.12 | `auto status` | Auto interval/range/state. |
| S2.13 | `btn status` | Physical/serial state for B1..B6. |

### 7.3 Built-in self-test runner

| Step | Command | Expected |
|---|---|---|
| S3.1 | `test list` | Lists test groups. |
| S3.2 | `test run buttons` | Button tests pass, including the overlay-driven cases `buttons.serial_overlay_b1`, `buttons.combo_b3b1_seq`, `buttons.combo_b3b2_seq`, `buttons.combo_simultaneous_b3b1`, `buttons.noncombo_b4b5` (see 8.7). |
| S3.3 | `test run led` | Run only if source inspection confirms it does not execute `all_on` or any `lit=370` pattern. Otherwise `SKIP reason=all_leds_prohibited`. |
| S3.4 | `test run adc` | PASS or WARN if battery invalid. |
| S3.5 | `test run modes` | PASS. |
| S3.6 | `test run scroll` | PASS if frames exist, else `WARN reason=no_scroll_frames`. |
| S3.7 | `test run sweep` | Brightness/color/scroll interval sweeps pass, respecting battery cap. |
| S3.8 | `test run all` | Run only if source inspection confirms the aggregate suite does not execute `all_on`/`lit=370`. Otherwise run safe groups individually and mark aggregate `SKIP reason=all_leds_prohibited`. |
| S3.9 | `test report` | Echoes last counts. |

---

## 8. Button and GPIO coverage

### 8.1 Serial button commands

Run:

```text
btn tap B1
btn tap B2
btn tap B3
btn tap B4
btn tap B5
btn press B6
btn release B6
btn hold B6 1500
btn combo B3+B1 tap
btn combo B3+B1 hold
btn combo B3+B2 tap
btn combo B3+B2 hold
btn hold B5 1500
btn repeat B4 5 300
btn multi B3+B1 800
btn multi B3+B2 800
btn multi B4+B5 0
btn multi B1+B2 600
btn multi B9 500
btn tap B9
```

The `btn multi <ID+ID+..> <ms>` command is the general "multiple buttons at
once" path: it asserts the emulated overlay for every listed button in the same
instant and releases them together after `<ms>`, flowing through the identical
debounce / combo / repeat state machine as physical GPIO. Parameters are the
`+`-joined button list and the press time in ms (`0` = momentary tap). It works
for combos that exist in firmware (`B3+B1`, `B3+B2`) and for arbitrary pairs that
do **not** (see section 8.6). A bad id, duplicate id, or empty list returns `ERR`.

Expected:

| Button / command | Expected behavior |
|---|---|
| B1 | next saved face; stops scroll if active |
| B2 | previous saved face; stops scroll if active |
| B3 | toggles Manual/Auto; stops scroll if active |
| B4 | brightness down; clamp respected |
| B5 | brightness up; clamp respected and repeat works |
| B6 press/release/hold | battery overlay behavior |
| B3+B1 (sequenced: B3 held, then B1) | auto interval down |
| B3+B2 (sequenced: B3 held, then B2) | auto interval up |
| `btn multi B3+B1 800` | B3 then B1 latch together; because B1 is serviced before B3, **no** B3B1 combo forms — produces a plain next-face. Differs from the sequenced combo. See 8.6. |
| `btn multi B4+B5 0` | both single actions fire (down then up), net brightness unchanged, auto-interval untouched |
| `btn multi B1+B2 600` | both single actions fire; net saved-face change of zero (forward then back) |
| `btn multi B9 500` | rejected with `ERR btn multi unknown_id=B9` |
| B9 | rejected with `ERR` |

### 8.2 WebUI GPIO simulator

Use actual WebUI buttons via `__ui.gpio(...)` or `[data-gpio=...]`:

```js
__ui.gpio("B1")
__ui.gpio("B2")
__ui.gpio("B3")
__ui.gpio("B4")
__ui.gpio("B5")
__ui.gpio("B6S")
__ui.gpio("B6L")
__ui.gpio("B3B1")
__ui.gpio("B3B2")
```

Expected behavior must match serial equivalents.

### 8.3 `gpio-B6B3` classification

If the WebUI exposes `gpio-B6B3`, do not count it as a real physical GPIO combination unless firmware source proves the combo exists.

Default classification:

```text
debug_webui_only
```

### 8.4 Physical button spot check

If a human or rig is available, physically press:

```text
B1 B2 B3 B4 B5 B6 B3+B1 B3+B2
```

Expected: same behavior as WebUI/serial with `source=physical`/`gpio` in logs.

### 8.5 Complete implemented button action / combo matrix

This is the authoritative list of **every** button input the firmware actually
implements (verified against `src/buttons.cpp` and `src/button_animations.cpp`).
Every row must be covered by serial (`btn ...`), WebUI (`__ui.gpio(...)`), or
physical means. There are exactly **two** real multi-button combos — `B3B1` and
`B3B2`; no other physical combo exists.

| Input | Firing edge | Repeats? | Implemented action | Source of truth |
|---|---|---|---|---|
| B1 | press | yes (650ms delay, 350ms) | next saved face; stops firmware scroll | `runButtonActionImpl` B1 branch |
| B2 | press | yes (650ms delay, 350ms) | previous saved face; stops firmware scroll | `runButtonActionImpl` B2 branch |
| B3 | release (only if not combo-consumed) | no | toggle Manual/Auto | `runButtonActionImpl` B3 + `handleHardwareButtonRelease` |
| B4 | press | yes (450ms delay, 120ms) | brightness down (step 8, clamped) | `adjustBrightnessFromButton` |
| B5 | press | yes (450ms delay, 120ms) | brightness up (step 8, clamped) | `adjustBrightnessFromButton` |
| B6 | press | n/a | battery overlay single-shot | `handleButtonAnimationGpioPress` |
| B6 (long) | hold ≥ 700ms, **only if B2 and B3 not held** | n/a | battery overlay hold; cleared on release | `serviceButtonAnimationButtonInputs` |
| B3 + B1 (B3 held first, then B1) | B1 press while B3 pressed | no | auto interval **down** (step 500ms) | `handleHardwareButtonPress` B3B1 |
| B3 + B2 (B3 held first, then B2) | B2 press while B3 pressed | no | auto interval **up** (step 500ms) | `handleHardwareButtonPress` B3B2 |

Coverage check: the serial and WebUI tables in 8.1/8.2 list `B1, B2, B3, B4, B5,
B6S, B6L, B3B1, B3B2` — i.e. all nine rows above. No implemented combo is
missing from this plan.

### 8.6 Combinations NOT implemented (negative coverage)

These combinations are deliberately **not** combos. The firmware must degrade to
the individual per-button actions (or to nothing special) and must never invent
a phantom combo. Drive each with `btn multi` (true simultaneous press) and, where
noted, also with a typed sequence to show the ordering dependence.

| Combination | How to drive | Expected (must hold) |
|---|---|---|
| B3 + B1 **simultaneous** | `btn multi B3+B1 800` | **No** B3B1 combo. B1 is serviced before B3 (fixed array order B1..B6), so B1's next-face fires while B3 is not yet `pressed`; auto-interval is unchanged. On release the un-consumed B3 toggles mode. Contrast with the sequenced combo in 8.5. |
| B3 + B2 **simultaneous** | `btn multi B3+B2 800` | Same as above: no B3B2 combo, plain prev-face, interval unchanged, mode toggles on release. |
| B4 + B5 | `btn multi B4+B5 0` | Both single actions fire (down then up); net brightness unchanged; auto-interval untouched; brightness stays within clamp. |
| B1 + B2 | `btn multi B1+B2 600` | Both single actions fire; net saved-face index returns to start; no combo. |
| B6 + B3 (`gpio-B6B3`) | `btn multi B6+B3 1000` | **Not** a combo. B6's long-press is explicitly suppressed while B3 is held, so no battery-hold overlay; B3 toggles mode on release. Classify any WebUI `gpio-B6B3` as `debug_webui_only`. |
| B6 + B2 | `btn multi B6+B2 1000` | Long-press suppressed (B2 held); B6 single overlay only; B2 prev-face fires. No combo. |
| Any other pair (e.g. B1+B4, B2+B5, B3+B4) | `btn multi <pair> <ms>` | Each button's own action fires independently in array order; no combo, no crash, all values within clamps. |
| Invalid / malformed list | `btn multi B9 500`, `btn multi B1+B1 500`, `btn multi "" 500` | `ERR` with `unknown_id` / `duplicate_id` / `empty`; no state change. |

Note on logging: emulated presses are tagged `source=serial` (physical presses
`source=physical`); the resulting **state changes are identical**, only the log
label differs, which is intentional for traceability and overlap detection
(`event=conflict` when physical and serial assert the same button at once).

### 8.7 Self-test coverage of the above

`test run buttons` now exercises the overlay path through the real debounce
machine, not just the logical `runButtonAction` shortcut:

| Test name | Asserts |
|---|---|
| `buttons.serial_overlay_b1` | emulated B1 press/release advances saved face by 1 (serial == GPIO) |
| `buttons.combo_b3b1_seq` | sequenced B3-then-B1 lowers auto interval by one step |
| `buttons.combo_b3b2_seq` | sequenced B3-then-B2 raises auto interval by one step |
| `buttons.combo_simultaneous_b3b1` | simultaneous B3+B1 forms **no** combo (interval unchanged, face advances) |
| `buttons.noncombo_b4b5` | simultaneous B4+B5 nets zero brightness change and never touches auto interval |

---

## 9. LED diagnostics and M370 frame coverage

### 9.1 Basic LED controls

| Step | Command/action | Expected |
|---|---|---|
| LED1 | `led color #00ff00` then `led current` | Color echoed/applied. |
| LED2 | `led brightness 127` | Brightness set/applied. |
| LED3 | `led brightness 0` | Clamps to min. |
| LED4 | `led brightness 255` | Clamps to max unless battery cap skips. |
| LED5 | `led clear` | Lit count becomes 0. |
| LED6 | `led command_history` | Recent applies are listed. |

### 9.2 Safe pattern tests — `all_on` prohibited

Before allowed pattern tests:

```text
led brightness 10
```

Do **not** run `led test pattern all_on`. The test plan must never intentionally light all LEDs on the physical display.

Run only the allowed sparse/non-all patterns, and immediately clear after each one:

```text
led test pattern all_off
led test pattern checker
led clear
led test pattern rows
led clear
led test pattern cols
led clear
led test pattern single 0
led clear
led test pattern single 369
led clear
led test pattern single 370
```

Expected:

- `all_off`: `lit=0`;
- `checker`, `rows`, `cols`: `0 < lit < 370`;
- `single 0` and `single 369`: `lit=1`;
- `single 370`: rejected/out of range;
- any result with `lit=370` is a `FAIL` and must be cleared immediately.

### 9.3 M370 direct frame tests

Test:

```text
frame M370:<known-all-off-93-hex>
frame M370:<known-all-on-93-hex>
frame M370:<known-random-93-hex>
led dump compact
```

Expected:

- accepted valid frames;
- rejected malformed/oversized frames;
- `led dump compact` matches accepted frame bit-for-bit.

---

## 10. Default-face-only color × brightness exhaustive WebUI test

### 10.1 Purpose

Verify every WebUI color choice at every WebUI brightness preset button while holding the default face constant.

### 10.2 Preconditions

1. Apply the default face.
2. Make the physical LED display/panel visible before changing any color or brightness.
3. Confirm no scroll is running.
4. Confirm mode and face state via serial:
   ```text
   face status
   scroll status
   led current
   ```
5. Check battery gate from Section 4.

### 10.3 Brightness presets

If battery is connected and valid:

```text
10, 25, 50, 80, 128, 160, 200
```

If battery is absent/invalid:

```text
10, 25, 50, 80
```

Record skipped high values:

```text
WARN reason=no_battery skip_brightness_above=120
```

### 10.4 Color choices

Test every available WebUI color option discovered from:

```text
parent-color-select
child-color-select
color-input / color buttons / swatches exposed by __ui.list()
```

For each color option:

1. select the parent group if needed;
2. select the exact child color;
3. for every active brightness preset, click the actual WebUI brightness preset button;
4. wait exactly `0.5s` after each LED state change;
5. verify:
   ```text
   led current
   led dump compact
   GET /api/status
   ```
6. pass only if color/brightness match and a serial/API/log acceptance exists.

### 10.5 Failure conditions

Fail the row if:

- WebUI selected a color but firmware color did not match;
- brightness preset did not apply;
- serial/API/log evidence is missing;
- physical LED display/panel was not visible during color/brightness changes;
- test switched away from default face during the matrix;
- the 0.5s interval was not respected;
- browser console produced an uncaught error.

---

## 11. Mode, face, and auto playback

### 11.1 Mode controls

Serial:

```text
mode status
mode auto
mode manual
```

WebUI:

```js
__ui.click("mode-toggle")
```

Expected:

- `mode` flips correctly;
- auto playback starts/stops as expected;
- serial and WebUI state agree.

### 11.2 Face navigation

Serial:

```text
face status
face next
face prev
face apply 0
face apply <bad_index>
```

WebUI:

```js
__ui.click("face-next")
__ui.click("face-prev")
```

Expected:

- good face indexes apply;
- bad index rejected;
- scroll stops before face change if active;
- status and LED frame reflect selected face.

### 11.3 Auto interval

Serial:

```text
auto status
auto interval 500
auto interval 1000
auto interval 2000
auto interval 3000
auto interval 5000
auto interval 7500
auto interval 10000
auto interval 0
auto interval 999999
```

WebUI:

- click interval up/down;
- use auto interval range/input;
- click every auto interval preset.

Expected:

- valid values apply;
- invalid values clamp/reject according to firmware rules;
- WebUI displayed value, `/api/status`, and serial `auto status` agree.

---

## 12. Scroll text exhaustive test

### 12.1 Test string

Generate one exact random 100-character string containing mixed:

- Chinese characters;
- Japanese kana/kanji;
- emoji.

Record the exact string in the report.

Also test edge strings:

| Case | Text |
|---|---|
| empty | `""` |
| one char | one CJK or emoji |
| ASCII | random ASCII |
| Chinese | random Chinese-only sample |
| Japanese | random Japanese-only sample |
| emoji | emoji-only sample |
| mixed | CJK + kana + emoji |
| newline | includes `\n` |
| near max | near WebUI maxlength / firmware limit |

### 12.2 Upload and start

Use the actual WebUI:

```js
__ui.setValue("scroll-text", "<test text>")
__ui.click("scroll-play")
```

Verify:

```text
GET /api/status
GET /api/scroll/meta
scroll status
```

Required fields:

```text
scrollFrameCount > 0
scrollUploadComplete === true
scrollHasSourceText === true
firmwareScrollActive === true
firmwareScrollPaused === false
playback === "scroll"
meta.sourceText matches the test text
```

### 12.3 Speed presets

Test every WebUI scroll speed preset:

```text
1, 10, 20, 30, 40, 50, 60
```

For each speed:

1. click the actual preset button or set the actual WebUI speed control;
2. verify WebUI input/range text;
3. verify `/api/status.scrollIntervalMs` or equivalent;
4. verify serial `scroll status`;
5. verify frame index movement rate visibly changes enough to distinguish slow/fast.

### 12.4 Play/pause/resume/step/stop/clear

For every speed where practical, and at least once for the 100-character string:

| Action | WebUI control | Required assertion |
|---|---|---|
| play/send | `scroll-play` | active, not paused, frame count > 0 |
| pause | `scroll-pause` | user paused, index stable |
| resume | `scroll-pause` or `scroll-play` | unpaused, index advances |
| step previous | `scroll-step-prev` | exactly one step, held frame |
| step next | `scroll-step-next` | exactly one step, held frame |
| stop | `scroll-stop` | active false, frame count cleared if command clears |
| clear screen | clear/stop behavior | LEDs blank or face restored as specified |

Monitor button states before and after every transition:

```text
disabled
aria-disabled
aria-pressed
text
value
visible
busy/progress state
```

### 12.5 Step and wrap behavior

Use `N = scrollFrameCount`.

- Step right/next behavior must match the firmware/UI semantics.
- Boundary wrap must work at index `0` and `N-1`.
- Step while running must latch/pause and hold the stepped frame.

### 12.6 Reload and restore

Test:

1. reload WebUI while scrolling;
2. reload WebUI while paused;
3. verify `scroll-text` restores from `/api/scroll/meta.sourceText`;
4. verify timeline id/frame count match;
5. verify no restore warning for exact match;
6. verify frame index does not jump backward except normal wrap.

### 12.7 Scroll takeover by other actions

While scroll is running, test:

- mode toggle to manual;
- mode toggle to auto;
- face next/prev;
- B1/B2/B3 via WebUI GPIO simulator;
- physical B1/B2/B3 if available.

Expected:

- scroll stops cleanly;
- `scrollStopEvent` records button/source/reason where applicable;
- face/mode action completes;
- no empty UI while hardware still scrolls.

### 12.8 Network and rapid-click robustness

Test:

- pause command while network briefly fails;
- rapid `scroll-pause` clicks;
- rapid step clicks;
- repeated stop clicks;
- stop immediately after start/upload.

Expected:

- UI does not lock;
- stale replies do not revive old state;
- no backward scroll-index jumps;
- final firmware state is deterministic;
- browser logs unconfirmed command where appropriate.

---

## 13. Custom face tests

### 13.1 Hand-drawn grid faces

Do not only use serial frame commands. Draw directly in the WebUI grid.

Test patterns:

| Pattern | Requirement |
|---|---|
| diagonal | draw manually in grid cells |
| border | draw manually or through WebUI button, then edit manually |
| checker subset | draw manually |
| asymmetric face | draw manually to ensure no forced symmetry |

For each:

1. draw in the grid;
2. send/apply to LED;
3. verify `led dump compact`;
4. save with name;
5. apply from saved-face library;
6. reload WebUI and verify persistence;
7. delete/remove;
8. reload and verify gone.

### 13.2 Saved-face edge cases

Test:

| Case | Expected |
|---|---|
| normal ASCII name | save/apply/delete works |
| empty name | rejected or defaulted consistently |
| duplicate name | handled predictably |
| long name | truncated/rejected safely |
| Chinese/Japanese/emoji name | saved/displayed/applied safely |
| protected default face delete attempt | rejected or safely blocked |
| invalid saved-face JSON import | rejected with no corruption |
| corrupted import | rejected with no corruption |
| duplicate saved-face IDs | rejected or normalized safely |

Saved-face firmware storage writes must produce parseable serial/API evidence. Local copy/download/open actions are `file_io_only`, not firmware-write tests.

---

## 14. Parts-face tests

### 14.1 Actual selected parts

Do not only click the random button.

For multiple random combinations, actually select individual options from:

```text
left eye
right eye
mouth
cheek
```

For each combination:

1. select left eye option;
2. select right eye option;
3. select mouth option;
4. select cheek option;
5. apply;
6. verify LED/M370 state;
7. save as a face;
8. apply from saved faces;
9. delete;
10. verify deletion.

### 14.2 Full option coverage

Every generated option must be selected at least once across the run:

```text
all left-eye options
all right-eye options
all mouth options
all cheek options
```

### 14.3 Random button

Test `parts-random` separately after actual-selected-parts coverage.

Expected:

- random changes at least one part;
- apply works;
- serial/API/log evidence confirms frame apply;
- no browser errors.

---

## 15. Debug, raw commands, and file/local controls

### 15.1 Debug LED controls

Test:

```text
debug-send-off
debug-send-on — click/test only safe cancel/blocked/guard path; do not confirm all-on send
debug-send-checker
debug-send-border
debug-send-saved
debug-m370-preview
debug-m370-send
debug-m370-clear
debug-m370-copy
debug-preview-copy
```

Expected:

- firmware-affecting controls produce LED/API/serial evidence;
- preview-only/copy controls are classified as `local_only` or `file_io_only`;
- invalid M370 is rejected safely.

### 15.2 Power debug controls

Test:

```text
debug-refresh-power
debug-reset-battery-min
debug-reset-battery-max
```

Expected:

- power refresh agrees with `battery status`;
- resets are confirmed and logged;
- destructive reset controls test cancel/confirm if confirmation exists.

### 15.3 Raw JSON command controls

Test:

```text
debug-raw-json
debug-raw-confirm
debug-raw-validate
debug-raw-send
```

Cases:

| Case | Expected |
|---|---|
| valid command | accepted and state changes |
| invalid JSON | validation error |
| missing confirm | not sent |
| confirm then send | sent exactly once |
| destructive command | confirmation required |

---

## 16. Battery overlay tests

### 16.1 Serial

```text
battery overlay single
battery overlay hold
```

or equivalent current command syntax.

### 16.2 WebUI GPIO

```js
__ui.gpio("B6S")
__ui.gpio("B6L")
```

### 16.3 Pause composability during scroll

Test:

1. start scroll;
2. pause scroll by user;
3. trigger battery overlay;
4. while overlay active, verify system pause;
5. when overlay ends, verify user pause still holds;
6. resume and verify scroll continues.

Then test overlay while running without user pause:

- system pause during overlay;
- automatic resume after overlay.

Expected: overlay never resumes a user-paused scroll accidentally.

---

## 17. Edge-case suite

Run and record edge cases.

### 17.1 Invalid color and brightness

| Test | Expected |
|---|---|
| invalid hex color | rejected, no state corruption |
| short hex | rejected |
| non-hex characters | rejected |
| brightness below min | clamp/reject according to rule |
| brightness above max | clamp/reject; respect battery cap |
| rapid brightness clicks | final state consistent |

### 17.2 Invalid intervals and speeds

| Test | Expected |
|---|---|
| auto interval too low | clamp/reject |
| auto interval too high | clamp/reject |
| scroll speed `0` | reject/clamp |
| scroll speed negative | reject |
| scroll speed very high | reject/clamp |
| non-number speed | reject |

### 17.3 Scroll text edge cases

Test:

```text
empty text
single character
emoji-only text
CJK-only text
mixed CJK/Japanese/emoji text
newline text
near-max length text
very long / over-limit text
```

Expected:

- WebUI enforces length/validity;
- firmware never receives partial/corrupt timeline;
- empty/invalid cases do not leave stale scroll active.

### 17.4 M370 edge cases

Test:

```text
empty M370
wrong prefix
too short
too long
invalid hex
valid all-off
valid all-on
random valid
```

Expected:

- valid frames apply;
- invalid frames reject;
- previous valid state is not corrupted by invalid input.

### 17.5 Saved-face storage edge cases

Test:

```text
invalid JSON
corrupted JSON
duplicate names
duplicate IDs
empty name
very long name
Unicode name
delete default/protected face
clear user faces cancel
clear user faces confirm if safe
```

### 17.6 Concurrency and transition edge cases

Test:

```text
rapid play/pause/stop
rapid GPIO clicks during scroll
mode switching while scroll upload is in progress
WebUI reload during scroll
WebUI reload during paused scroll
serial command while WebUI command is active
network disconnect/reconnect during command
```

Expected:

- no stuck busy state;
- no scroll revival after stop;
- no stale response overwrites newer state;
- UI converges to firmware truth after reconnect/reload.

---

## 18. Implementation/source verification

Before marking a feature `PASS`, verify source implementation exists.

### 18.1 Files to inspect

Check relevant code paths in:

```text
data/index.html
data/app.js
data/test_harness.js
src/web_api.cpp
src/serial_console.cpp
src/serial_log.cpp
src/buttons.cpp
src/led_renderer.cpp
src/scroll_session.cpp
src/power_monitor.cpp
src/faces.cpp
platformio.ini
```

### 18.2 Required implementation checks

| Feature | Verify |
|---|---|
| serial console | initialized, serviced, non-blocking |
| serial logging | parseable logs, levels, categories |
| WebUI harness | all controls tagged/listed by `__ui.list()` |
| `/api/status` | returns truth fields used by tests |
| `/api/command` | implements every firmware command under test |
| `/api/scroll` and `/api/scroll/meta` | upload, sourceText, frame index, restore metadata |
| `/api/frame` | direct M370 frame apply |
| `/api/power` | voltage/charging telemetry |
| `/api/saved_faces` | writes emit parseable serial/API evidence |
| buttons | serial/WebUI/physical paths reuse same action logic |
| B6 | overlay press/release/hold semantics implemented |
| B3+B1/B3+B2 | real combos implemented |
| `gpio-B6B3` | only real combo if firmware proves it |
| LED apply | all tested paths reach actual LED/frame state |
| compile gates | diagnostics/test features controlled by build flags |

A UI-only visual change is not a firmware `PASS`.

---

## 19. Regression sweep

After exhaustive tests, verify normal behavior still works.

| Step | Check | Expected |
|---|---|---|
| R1 | Manual face display | face persists and renders smoothly |
| R2 | Auto playback | faces rotate at `autoIntervalMs` |
| R3 | Default face after stop/clear | correct face restored |
| R4 | WebUI color/brightness/mode | all basic functions work |
| R5 | Physical buttons | B1–B6 still work |
| R6 | Scroll text | upload/play still works |
| R7 | Battery display | B6 overlay still works |
| R8 | LED rendering with `INFO` logs | no flicker/glitch |
| R9 | `DEBUG` during scroll briefly | no WS2812 glitch; restore `INFO` |
| R10 | Default build behavior | no unintended production behavior changes |

---

## 20. Final restore, persistence reset test, and report

### 20.1 Final restore from JSON baseline

After all functional tests finish, restore from `SETTINGS_BASELINE_BEFORE_TEST.json`:

```text
scroll stop
log level <json.restoreTargets.logLevel>
led color <json.restoreTargets.color>
led brightness <json.restoreTargets.brightness>
mode <json.restoreTargets.mode>
auto interval <json.restoreTargets.autoIntervalMs>
scroll interval <json.restoreTargets.scrollIntervalMs>
face apply <json.restoreTargets.autoFaceIndex>
```

If saved-face storage, custom faces, names, order, or deleted-user-face state changed during testing, restore the saved-face JSON/object from `SETTINGS_BASELINE_BEFORE_TEST.json` before final verification.

Verify the restored live state against the JSON baseline:

```text
status
led current
auto status
face status
scroll status
battery status
log status
GET /api/status
GET /api/power
GET /api/scroll/meta
GET /api/saved_faces, /resources/saved_faces.json, or the implemented saved-face endpoint/file path
```

Record any non-matching persistent setting as `FAIL`. Volatile values such as uptime, heap, timestamps, counters, and small battery-voltage drift are allowed to differ.

### 20.2 Final reset as settings-persistence test

After the restore in §20.1 succeeds, reset the board. This reset is the final settings-persistence test.

```text
reboot
```

If unavailable, press physical reset/EN and record:

```text
WARN reason=no_serial_reboot_command_final_persistence_test
```

After reboot, verify boot and compare persisted settings to `SETTINGS_BASELINE_BEFORE_TEST.json`:

```text
version
status
led current
auto status
face status
scroll status
battery status
log status
GET /api/status
GET /api/power
GET /api/scroll/meta
GET /api/saved_faces, /resources/saved_faces.json, or the implemented saved-face endpoint/file path
```

PASS criteria:

- board reboots and responds;
- restored mode, brightness, color, auto interval, scroll interval, active face/default face state, and saved-face persistent data survive the reboot;
- scroll is not accidentally left active unless it was active in the initial baseline JSON;
- no unexpected user-face deletion, rename, order change, or storage corruption remains;
- no unexpected browser/API/serial error is produced after reboot.

If any persistent setting does not match the initial JSON baseline after this final reset, mark:

```text
FAIL reason=settings_persistence_mismatch
```

This final persistence check is the last test action. End the test after recording its result and saving the report.

### 20.3 Required report file

Generate:

```text
RUN_ALL_TESTS_REPORT.md
```

Required report sections:

```text
test date/time
repo path
git commit/hash if available
firmware build result
firmware upload result
filesystem/WebUI upload result
serial port and baud
firmware version
battery voltage/state before tests
whether brightness >120 was tested or skipped
baseline state
WebUI control manifest summary
control classification table
serial console test results
battery/ADC results
LED/M370 results
default-face color × brightness matrix result
scroll 100-character string
scroll speed/action/button-state table
custom face add/apply/delete results
parts face selected-option results
GPIO/WebUI/serial/physical button results
edge-case results
implementation verification results
regression results
warnings and skipped items
failures with evidence
browser console errors
initial reset verification
`SETTINGS_BASELINE_BEFORE_TEST.json` path and checksum/summary
final restore verification against JSON baseline
final board reset persistence verification
summary pass/warn/fail/skip counts
overall verdict
```

### 20.4 Report row template

Use this for each row:

```text
| ID | Area | Interface | Action | Expected | Observed evidence | Result | Notes |
|---|---|---|---|---|---|---|---|
```

### 20.5 Blocking failures

Block release if any of these fail:

- build or upload;
- serial console unavailable;
- WebUI cannot load;
- `__ui.list()` unavailable;
- `/api/status` unavailable;
- default-face color/brightness matrix has firmware-affecting failures;
- scroll play/pause/resume/step/stop/clear fails;
- step latch, anti-drift, or pause composability regressions;
- saved-face storage corruption;
- M370 valid frame cannot round-trip;
- GPIO B1/B2/B3/B4/B5/B6 or B3+B1/B3+B2 behavior broken;
- initial reset, JSON baseline capture, final restore, or final persistence reset verification fails.

---

## Appendix A — Compact command checklist

```text
help
help buttons
help led
help adc
help logs
help tests
version
uptime
status
log status
log level DEBUG
log level TRACE
log level ERROR
log off
log on
adc status
adc read raw
adc read vbat
adc read charge
battery status
battery sample 10
led status
led current
led color #00ff00
led brightness 10
led brightness 127
led brightness 200
# Do not run: led test pattern all_on
led test pattern all_off
led test pattern checker
led clear
led test pattern rows
led clear
led test pattern cols
led clear
led test pattern single 0
led test pattern single 369
led test pattern single 370
led dump
led dump compact
led command_history
btn tap B1
btn tap B2
btn tap B3
btn tap B4
btn tap B5
btn press B6
btn release B6
btn hold B6 1500
btn combo B3+B1 tap
btn combo B3+B1 hold
btn combo B3+B2 tap
btn combo B3+B2 hold
btn multi B3+B1 800
btn multi B3+B2 800
btn multi B4+B5 0
btn multi B6+B3 1000
btn multi B9 500
btn status
mode status
mode auto
mode manual
face status
face next
face prev
face apply 0
auto status
auto interval 500
auto interval 10000
scroll status
scroll start
scroll pause
scroll resume
scroll step next
scroll step prev
scroll stop
scroll clear
pause
resume
frame M370:<valid-93-hex>
terminate scroll
terminate face
terminate all
test list
test run buttons
# test run led only if source confirms no all-on/lit=370 pattern
test run adc
test run modes
test run scroll
test run sweep
# test run all only if source confirms no all-on/lit=370 pattern
test report
reboot
```

## Appendix B — Compact WebUI checklist

The report must include this exact checklist, with each item marked `PASS`, `FAIL`, `WARN`, or `SKIP` and a classification. This appendix is intentionally redundant with §6.4 so a weak agent cannot skip controls by only following family names. Static audit of `data/index.html` found 84 `<button>` elements, 79 unique button identifiers, and all unique button identifiers are represented below either by exact id/class/data-gpio name or by a generated-button rule; each must be clicked/tested according to §6.2.1.

```text
Global / harness:
__ui.list()
__ui.nav()
__ui.pages()
__ui.badges(true)
brand-nav-toggle
all generated top-nav page buttons: Basic, Custom, Parts, Scroll, Debug

Basic:
color-input
parent-color-select: all 6 parent color groups
child-color-select: all child color choices
brightness-reset-default
brightness-minus
brightness-plus
brightness-range
brightness-input
all brightness preset buttons allowed by battery gate
face-prev
face-next
mode-toggle
interval-down
interval-up
auto-interval-range
auto-interval
all auto interval preset buttons

Custom:
every custom grid cell needed for drawn patterns
custom-send
custom-live-toggle
custom-clear
custom-fill
custom-invert
custom-m370
custom-copy
custom-import
custom-save
custom-name
saved-face apply/rename/delete/reorder controls
.faces-json-load on Custom
.faces-json-open-local on Custom
.faces-json-save-local on Custom
.faces-json-download-all on Custom
.faces-json-import-btn on Custom
.faces-json-import-file on Custom

Parts:
parts-apply
parts-live-toggle
parts-random
parts-reset
parts-symmetry-toggle
parts-m370-text
parts-copy-m370
parts-import-m370
parts-save-bottom
parts-name
all left-eye options
all right-eye options
all mouth options
all cheek options
.faces-json-load on Parts
.faces-json-open-local on Parts
.faces-json-save-local on Parts
.faces-json-download-all on Parts
.faces-json-import-btn on Parts
.faces-json-import-file on Parts

Scroll:
scroll-text
scroll-speed-reset-default
scroll-speed-minus
scroll-speed-plus
scroll-speed-range
scroll-speed
speed presets 1,10,20,30,40,50,60
scroll-play
scroll-pause
scroll-stop
scroll-step-prev
scroll-step-next

Debug firmware/API/power/network:
firmware-ping
debug-fw-refresh-power
debug-clear-api-error
debug-copy-diag
debug-refresh-power
debug-reset-battery-min
debug-reset-battery-max
ADC details summary
battery-v
charge-v
update-adc
debug-ap-pass-toggle
debug-network-refresh

Debug GPIO:
gpio-B1
gpio-B2
gpio-B3
gpio-B4
gpio-B5
gpio-B6S
gpio-B6L
gpio-B3B1
gpio-B3B2
gpio-B6B3 as debug_webui_only unless implemented as real firmware combo

Debug LED/M370/preview:
firmware-pause
debug-preview-off
debug-preview-checker
debug-preview-border
debug-preview-saved
debug-send-off
debug-send-on — click/test only safe cancel/blocked/guard path; do not confirm all-on send
debug-send-checker
debug-send-border
debug-send-saved
debug-m370
debug-m370-preview
debug-m370-send
debug-m370-clear
debug-m370-copy
debug-preview-copy

Debug logs/raw/danger:
log-clear
log-download
log-copy
raw-command summary
debug-raw-json
debug-raw-confirm
debug-raw-validate
debug-raw-send
debug-clear-user-faces
```

---

## Appendix C — Source documents merged

This deduplicated plan was created from:

```text
SERIAL_TEST_PLAN(1).md
SCROLL_WEBUI_TEST_PLAN.md
SERIAL_DIAGNOSTICS.md
SERIAL_TEST_CONSOLE_PLAN(1).md
```

The merged plan keeps each unique requirement once and removes repeated setup, output-format, serial-command, scroll, reporting, and regression sections.
