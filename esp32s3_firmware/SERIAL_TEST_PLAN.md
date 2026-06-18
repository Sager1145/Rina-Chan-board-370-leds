# RinaChan Board — Serial Feature Test Plan

A step-by-step plan to verify **every** serial-diagnostics feature **and** confirm
no existing behavior regressed. An AI agent (or a person) executes each step over
USB serial and records PASS / WARN / FAIL.

---

## 0. Setup

1. Build + flash firmware (OS-agnostic): `pio run -e esp32s3 -t upload`
   (or `-e esp32s3-test` for verbose logs).
2. Flash the WebUI/LittleFS image (ships `test_harness.js`): `pio run -e esp32s3 -t uploadfs`.
   ⚠ `uploadfs` overwrites LittleFS — back up `/resources/saved_faces.json` first if it matters.
3. Connect serial at **115200 8N1** (`pio device monitor -b 115200`, or pyserial, or PuTTY).
   Send commands as plain text + newline. Optional driver: `python tools/serial_test.py <PORT>`.
4. For WebUI steps (§9c): join Wi-Fi **`RinaChanBoard-V2`** (password `rinachan`) and open
   **`http://192.168.1.14`** (or `http://rina.io`); add `?ui_badges=1` to see control codes.
   Drive controls with `window.__ui` (see §9c).
5. Run **both** the serial sections (§1–9b) and the WebUI section (§9c); cross-check that each
   WebUI action matches its serial twin.

### Conventions
- Every event **log line** matches: `[<ms> ms] [<LEVEL>] [<CAT>] key=value ...`
- Command **replies**: `OK <cmd> ...`, `ERR <cmd> <reason>`, `WARN <cmd> <reason>`,
  or a block wrapped in `=== <TAG> BEGIN ===` … `=== <TAG> END ===`.
- For each step: record the command, the reply, and PASS/WARN/FAIL with a reason.
- **Always restore prior state** after destructive steps (the built-in `test run`
  does this automatically; manual steps note restoration).

---

## 0.1 Safety guardrails — prevent over-testing

These rules cap electrical, thermal, and wear stress. **Follow them; a step that
violates a guardrail is a FAIL even if the command "worked".**

- **Never light all LEDs at high brightness.** Before any full-field pattern
  (`all_on`, `rows`, `cols`, `checker`), first run **`led brightness 10`**
  (minimum). 370 LEDs at full brightness is a large current/thermal draw,
  especially on battery.
- **Keep full-field patterns brief.** Immediately follow `all_on`/`rows`/`cols`/
  `checker` with `led test pattern all_off` (or `led clear`). Do not leave a
  high-density frame displayed while you read/think — verify `lit=` then clear.
- **One pass per step.** Do not loop or spam a command. The LED apply path is
  frame-rate limited (~30 fps); rapid repeats are pointless and add bus traffic.
- **Bound battery sampling.** Use `battery sample 10` at most; never script tight
  sampling loops. The normal cadence is 1 Hz — forced sampling is for spot checks.
- **Restore brightness after LED tests.** Full-field tests change brightness; the
  baseline (section 0.2) must be restored before moving on.
- **Logging stays calm by default.** Raise to `DEBUG`/`TRACE` only for the
  specific step that needs it, then return to `INFO`. Leave `TRACE` off except
  briefly in 2.3. Never run a demo/performance with `DEBUG`+full-field LEDs.
- **No destructive steps on a low battery.** If `battery status` shows
  `percent` < 20 or `charging=0` at low voltage, skip full-field LED tests
  (sections 4.4–4.7, 8.3) and mark them `WARN reason=low_battery`.
- **Mind heat.** If running many LED tests back-to-back, pause between sections;
  do not hold dense frames lit continuously.

## 0.2 Baseline capture & restore

**Before section 1**, capture the starting state so every later change can be
undone:

```
status            # record: mode, brightness, color, autoFaceIndex
led current       # record: color, brightness
auto status       # record: intervalMs
face status       # record: index, count, id
scroll status     # record: count, active/paused
log status        # record: level (restore to this, default INFO)
```

Write these baseline values down. **After section 8 (and again at the very end),
restore them:**

```
log level <baseline level>          # usually INFO
led color <baseline color>          # e.g. #f971d4
led brightness <baseline brightness>
mode <baseline mode>                # manual|auto
auto interval <baseline intervalMs>
scroll interval <baseline scroll intervalMs>
face apply <baseline autoFaceIndex> # leaves a real face showing
scroll stop                         # only if a test left a scroll running
```

Then re-run `status` and confirm it matches the captured baseline (PASS) before
declaring the run complete. The built-in `test run all` already snapshots and
restores mode/brightness/auto-interval/face internally, but **manual** sections
3–7 do not — you must restore per the per-section "restore" rows below.

---

## 1. Console liveness & help

| # | Command | Expect / Assert |
|---|---|---|
| 1.1 | `help` | block `=== HELP BEGIN ===` … `END`, lists every command group |
| 1.2 | `help buttons` / `help led` / `help adc` / `help logs` / `help tests` | each prints a topic block |
| 1.3 | `version` | `OK version ... diagnostics=1 console=1 tests=1 ... heap=<n>` |
| 1.4 | `uptime` | `OK uptime ms=<n> hms=H:MM:SS`, ms increases on repeat |
| 1.5 | `status` | block with mode/brightness/scroll/counters fields |
| 1.6 | `notacommand` | `ERR unknown_command=notacommand` + a `[CMD] event=reject` log |

## 2. Logging control

| # | Command | Expect / Assert |
|---|---|---|
| 2.1 | `log status` | `enabled=1 level=INFO` (default) |
| 2.2 | `log level DEBUG` | `OK log level=DEBUG`; subsequent battery samples now emit `[ADC]` lines |
| 2.3 | `log level TRACE` | `OK log level=TRACE`; during an active scroll, `[SCROLL] event=tick` appears ≤1/sec |
| 2.4 | `log level ERROR` | only ERROR lines emit afterward |
| 2.5 | `log off` then `log on` | no log lines while off; lines resume after on |
| 2.6 | **restore** | finish with `log level <baseline>` (default `INFO`) and confirm `log status` |

## 3. Button emulation (reuses the real GPIO path)

Pre-req: at least 1 saved face. Check `face status` first.

| # | Command | Expect / Assert |
|---|---|---|
| 3.1 | `btn tap B1` | `[BUTTON] source=serial id=B1 event=action handled=1`; face index +1 (`face status`) |
| 3.2 | `btn tap B2` | face index −1 |
| 3.3 | `btn tap B3` | `[MODE] event=change ...`; `mode status` flipped Manual↔Auto. Tap again to restore |
| 3.4 | `btn tap B4` / `btn tap B5` | `[LED] event=brightness ...`; brightness down/up, clamped 10–200 |
| 3.5 | `btn combo B3+B1 tap` | `[BUTTON] ... id=B3B1 event=combo`; auto interval decreased (`auto status`) |
| 3.6 | `btn combo B3+B2 tap` | auto interval increased |
| 3.7 | `btn press B5` … wait ~1s … `btn release B5` | press/release logs `source=serial`; held press yields `event=repeat` lines |
| 3.8 | `btn hold B5 1500` | auto-releases after 1.5s; produces repeat events |
| 3.9 | `btn repeat B4 5 300` | exactly 5 `event=repeat` lines ~300ms apart |
| 3.10 | `btn status` | lists B1..B6 with `physical=` and `serial=` flags |
| 3.11 | `btn tap B9` | `ERR btn unknown_id=B9` |
| 3.12 | **Physical check** | press a real button → log shows `source=physical`; emulation did NOT disable it |
| **3.13** | **restore** | `mode <baseline>`, `auto interval <baseline>`, `led brightness <baseline>`, `face apply <baseline index>` (steps 3.1–3.6 changed all of these). Confirm `status` matches baseline |

## 4. LED diagnostics (all use existing apply paths)

> **Guardrail (section 0.1):** step **4.3a is mandatory before 4.4–4.7.** Never run
> a full-field pattern above minimum brightness, and clear it immediately after
> reading `lit=`. Skip 4.4–4.7 with `WARN reason=low_battery` if battery < 20%.

| # | Command | Expect / Assert |
|---|---|---|
| 4.1 | `led status` | mode, brightness, face index, scroll state, pending/queued frame |
| 4.1c | `led color #00ff00` then `led current` | color set + echoed; full sweep in 9b.1 |
| 4.2 | `led brightness` | reports value + `min=10 max=200` |
| 4.3 | `led brightness 127` | `OK led brightness set=127 effective=127`; `[LED] event=brightness value=127` |
| **4.3a** | **`led brightness 10`** | **mandatory safety cap before any full-field pattern** |
| 4.4 | `led test pattern all_on` → then **`led test pattern all_off`** | `lit=370`, then `lit=0`; clear immediately, do not linger |
| 4.5 | `led test pattern all_off` | `lit=0` (confirms cleared) |
| 4.6 | `led test pattern checker` → **clear**; `rows` → **clear**; `cols` → **clear** | each `lit` 0<x<370, then `led clear` after each |
| 4.7 | `led test pattern single 0` then `single 369` | `lit=1` each (low draw; no cap needed) |
| 4.8 | `led test pattern single 370` | `ERR ... out_of_range` |
| 4.9 | `led dump` | `=== LEDS BEGIN ===`, 18 `ROWnn` lines, `hex=<93 chars>` |
| 4.10 | `led dump compact` | `M370:<93 hex>` — paste into a test/WebUI to confirm identical frame |
| 4.11 | `led clear` | frame blank; `[LED] event=clear` |
| 4.12 | `led command_history` | ring buffer lists the recent applies above |
| **4.13** | **restore** | **`led brightness <baseline>`** then **`face apply <baseline index>`** (or `mode <baseline>`) so a real face shows at the original brightness |

## 5. ADC / battery (read-only; must not disturb sampling)

| # | Command | Expect / Assert |
|---|---|---|
| 5.1 | `adc status` | block with vbat/vcharge/percent/charging/raw/calib fields |
| 5.2 | `adc read raw` | `vbatRaw=<mV> vchargeRaw=<mV>` |
| 5.3 | `adc read vbat` | `vbat=<v> raw=<mV> percent=<0..100>` |
| 5.4 | `adc read charge` | `vcharge=<v> charging=<0|1>` |
| 5.5 | `battery status` | percent in 0–100, calibMin/Max present |
| 5.6 | `battery sample 10` (with `log level DEBUG`) | 10 `SAMPLE` lines + `[ADC] event=battery` logs; values plausible |
| 5.7 | sanity | readings consistent with a charger plugged/unplugged toggle |

## 6. Mode / face / auto (reuse WebUI/button internals)

| # | Command | Expect / Assert |
|---|---|---|
| 6.1 | `mode status` | current mode + playback |
| 6.2 | `mode auto` → `mode status` | mode=auto; faces begin auto-cycling (`[FACE] event=auto_change` ~每 interval) |
| 6.3 | `mode manual` | mode=manual; auto-cycle stops |
| 6.4 | `face status` | index/count/id |
| 6.5 | `face next` / `face prev` | index ±1; `[FACE] event=apply` |
| 6.6 | `face apply 0` | applies index 0; bad index → `ERR face apply failed` |
| 6.7 | `auto status` / `auto interval` | report interval + min/max |
| 6.8 | `auto interval 1000` | `[AUTO] event=interval_change interval_ms=1000` |
| 6.9 | `auto start` / `auto stop` | equivalent to mode auto/manual |
| 6.10 | **restore** | `mode <baseline>`, `auto interval <baseline>`, `face apply <baseline index>`; confirm via `mode status` + `auto status` |

## 7. Scroll (reuse scroll-session logic)

Pre-req for active tests: upload scroll frames via the WebUI first. If none:

| # | Command | Expect / Assert |
|---|---|---|
| 7.1 | `scroll status` | `count=0` when empty, else active/paused/idx/count |
| 7.1a | `scroll interval 60` / `scroll fps 30` | sets interval; full speed sweep in 9b.3 |
| 7.1b | `scroll start` (with frames) | `OK scroll start ...`; or `WARN ... no_scroll_frames` |
| 7.2 | `scroll step next` (no data) | `WARN scroll step reason=no_scroll_frames` |
| 7.3 | (with frames) `scroll pause` | `[SCROLL] event=pause ... effective=1`; status paused |
| 7.4 | `scroll resume` | resumes |
| 7.5 | `scroll step next` / `step prev` | idx changes; `[SCROLL] event=step` |
| 7.6 | `scroll stop` | scroll cleared, restores a face; `[SCROLL] event=stop` |
| 7.7 | `scroll clear` | timeline cleared, `count=0` |
| **7.8** | **restore** | ensure no scroll is left running (`scroll status` → `active=0`); `face apply <baseline index>` so a real face shows. (Re-upload scroll text from the WebUI later if you cleared it.) |

## 8. Built-in self-test runner

| # | Command | Expect / Assert |
|---|---|---|
| 8.1 | `test list` | lists groups + test names |
| 8.2 | `test run buttons` | `[TEST] buttons.* PASS ...` lines |
| 8.3 | `test run led` | `led.clear`, `led.pattern_all_on`, `led.pattern_single` PASS |
| 8.4 | `test run adc` | `adc.read` PASS (or WARN if battery invalid) |
| 8.5 | `test run modes` | `modes.toggle` PASS |
| 8.6 | `test run scroll` | PASS if frames exist, else `WARN reason=no_scroll_frames` |
| 8.7 | `test run all` | ends with `[TEST] SUMMARY pass=N warn=M fail=0` — **fail must be 0** |
| 8.8 | `test report` | echoes last counts |
| 8.9 | post-check | board state restored (mode/brightness/color/face/interval unchanged from before 8.7) |
| 8.10 | `test run sweep` | exhaustive option sweep: `sweep.brightness`, `sweep.color`, `sweep.scroll_interval` all PASS (see §9b.1–9b.3) |

## 9. Regression — existing functionality must still work

| # | Check | Expect / Assert |
|---|---|---|
| 9.1 | LED rendering | faces render smoothly; no flicker/glitch with logging at INFO |
| 9.2 | Physical buttons | all 6 work as before (B1/B2 face, B3 mode, B4/B5 brightness, B6 battery, combos) |
| 9.3 | WebUI | connect AP `RinaChanBoard-V2`, open UI: color/brightness/mode/faces/scroll all work |
| 9.4 | API parity | a WebUI action and the matching serial command produce the same `status` state |
| 9.5 | Saved faces | apply/list unaffected; `/api/status` reasons unchanged (e.g. not `physical_*`) |
| 9.6 | Scroll text | upload + play from WebUI still works |
| 9.7 | Battery display | physical B6 still shows the battery overlay; `[LED] event=battery_display` logs |
| 9.8 | Timing | enable `log level DEBUG`, run a scroll — WS2812 output stays glitch-free |
| 9.9 | Default build | with gates at default, normal boot/behavior identical to pre-change |

## 9b. Full WebUI ↔ serial parity & option-space coverage

**Goal: every WebUI function, and every option of that function, is exercised
from the serial interface.** The table below maps each WebUI capability to its
serial command. Run each, then sweep its full option range.

| WebUI function | Serial command | Option sweep to run |
|---|---|---|
| `set_color` | `led color #RRGGBB` | full color sweep (9b.1) |
| `set_brightness` | `led brightness N` | every level 10–200 (9b.2) |
| `set_mode` | `mode manual` / `mode auto` | both values |
| `set_auto_interval` | `auto interval N` | 500–10000 incl. clamp |
| `set_scroll_interval` | `scroll interval N` / `scroll fps N` | every speed 33–1000 (9b.3) |
| `start_scroll` | `scroll start [ms]` | with frames loaded |
| `scroll_step` | `scroll step next/prev` | both directions, wrap-around |
| `pause_scroll`/`resume_scroll`/`stop_scroll` | `scroll pause/resume/stop` | each |
| `pause` / `resume` (global) | `pause` / `resume` | in auto + in scroll |
| `button` | `btn tap/press/hold/repeat/combo` | all 6 buttons + 2 combos (§3) |
| `terminate_other_activities` | `terminate scroll/face/all` | all 3 targets |
| `reset_battery_min` / `reset_battery_max` | `battery reset min` / `max` | both |
| `battery_overlay` | `battery overlay single/hold` | both modes |
| `POST /api/frame` | `frame <M370>` | several frames + round-trip (9b.4) |
| `GET /api/status` / `/api/power` | `status` / `adc`/`battery` | read parity |
| `POST /api/scroll` (frame upload) | **WebUI/host only** — see 9b.5 |
| `POST /api/saved_faces` (add/delete/rename/reorder) | **WebUI only** — see 9b.6 |

### 9b.1 Color — full range
- `test run sweep` covers the 6×6×6 web-safe grid + boundaries automatically
  (`sweep.color PASS`).
- Spot-check manually: `led color #ff0000`, `#00ff00`, `#0000ff`, `#ffffff`,
  `#000000`, `#f971d4`, plus several random hexes; after each, `led current`
  must echo the same value. (24-bit space = 16.7M colors is **not** literally
  enumerable — the web-safe grid + boundaries + random sampling is the accepted
  full-range proxy.)

### 9b.2 Brightness — every level
- `test run sweep` sets **every** value 10–200 and asserts each
  (`sweep.brightness PASS count=191 ... clamp=ok`), including 0→clamps-to-10 and
  255→clamps-to-200.

### 9b.3 Scroll speed — every value
- `test run sweep` sets **every** interval 33–1000 ms and asserts clamping
  (`sweep.scroll_interval PASS`). Also verify via `scroll fps 30` / `scroll fps 5`
  that fps maps to interval, and that with frames loaded the on-screen speed
  visibly changes between `scroll interval 33` (fast) and `scroll interval 1000`
  (slow).

### 9b.4 Arbitrary frame push + fidelity round-trip
- `frame M370:<93 hex>` with a known pattern, then `led dump compact` → the
  echoed `M370:` must equal what you pushed (bit-for-bit). Repeat for an all-on,
  all-off, and a random frame. This proves the firmware stores/plays **exactly**
  the frames it is given (the basis for trusting WebUI-generated text frames).

### 9b.5 Text scrolling — random CJK / Japanese / emoji (WebUI-driven)
Text is **rasterized to frames in the browser** (fonts incl. CJK/emoji); the
firmware only plays frames, so character coverage is tested through the WebUI
while serial verifies playback:
1. In the WebUI text-scroll tool, enter strings sampling each set, e.g.:
   - ASCII: random `A–Z a–z 0–9 !@#…`
   - Simplified/Traditional Chinese: 你好世界 测试 龍鳳 random from a common-3500 list
   - Japanese: ひらがな カタカナ 日本語 漢字 random kana + kanji
   - Emoji: 😀🎉🔥❤️🐱 random from the emoji picker
2. Generate + upload, then **drive playback from serial**: `scroll start`,
   `scroll status` (`count>0`, `active=1`), `scroll interval 60`, `scroll step
   next/prev`, `scroll pause/resume/stop`.
3. Verify fidelity: `scroll status` frame count matches the WebUI; `led dump
   compact` of a paused frame is non-empty and stable. Confirm the glyphs render
   recognizably on the panel for each script. Repeat with ≥5 random strings per
   set.
4. Boundary chars: empty string, single char, very long string (near
   `MAX_SCROLL_TEXT_BYTES`), mixed scripts in one string.

### 9b.6 Saved-face library authoring (WebUI-driven)
Add / delete / rename / reorder / set-default of saved faces is a WebUI
authoring function (writes `/api/saved_faces`). From serial, verify the **result**:
after each WebUI edit, `face status` count/index and `face apply <n>` reflect the
change, and `test run buttons` still passes. (Serial does not author the library.)

> **Note:** 9b.5 (text rasterization) and 9b.6 (face authoring + bulk frame
> upload) are the only WebUI functions not directly issuable from serial — they
> require the browser's font engine / multi-frame upload. Serial fully covers
> their *playback and effect*; every other WebUI function is directly driveable
> and option-swept from serial above.

## 9c. WebUI agent testing (browser-driven, clickable by code)

The WebUI is instrumented for AI agents (Codex, Claude-in-Chrome, Playwright).
`data/test_harness.js` tags **every** interactive control with a stable
`data-testid` (e.g. `brightness-plus`, `gpio-B1`, `scroll-play`) **and** a stable
`data-test-code` number, and exposes `window.__ui`. Drive it instead of guessing
pixel coordinates. **Do both 9b (serial) and 9c (WebUI), and cross-check that a
WebUI action and its serial twin produce the same state.**

### Connect
- Join Wi-Fi **`RinaChanBoard-V2`** (password `rinachan`).
- Open **`http://192.168.1.14`** (or `http://rina.io`). Add `?ui_badges=1` to the
  URL to show each control's code as an on-screen badge.

### Agent API (run via devtools `evaluate` / console)
```js
__ui.list()                  // catalog: [{code, testid, label, tag, type, page, visible, disabled, value, rect}]
__ui.list({visibleOnly:true, page:"page-basic"})
__ui.find("brightness")      // search by testid/label
__ui.click(1042)             // click by code …
__ui.click("brightness-plus")// … or by testid
__ui.setValue("brightness-input", 137)   // set a slider/number/text (fires input+change)
__ui.setValue("scroll-text", "你好 こんにちは 🎉")
__ui.get("mode-toggle")      // read value/text/aria-pressed/disabled
__ui.gpio("B1")              // click a GPIO simulator button
__ui.pages()                 // list page sections + which is active
__ui.nav()                   // nav items to switch pages
__ui.badges(true)            // toggle visible code badges
```
General loop: `__ui.list()` to discover, switch page via a `__ui.nav()` item,
`__ui.click(code)` / `__ui.setValue(...)`, then verify via `__ui.get(...)`, the
serial `status`/`led dump compact`, and/or `GET /api/status`.

### Control catalog (key testids per page)
| Page (section id) | Key controls (testid) |
|---|---|
| `page-basic` (6.1) | `color-input`, `parent-color-select`, `child-color-select`, `brightness-range`, `brightness-input`, `brightness-minus`, `brightness-plus`, `brightness-reset-default`, `face-prev`, `face-next`, `mode-toggle`, `interval-down`, `interval-up`, `auto-interval-range`, `auto-interval`, presets in `brightness-presets`/`auto-interval-presets` |
| `page-custom` (6.2) | `custom-send`, `custom-live-toggle`, `custom-clear`, `custom-fill`, `custom-invert`, `custom-m370`, `custom-copy`, `custom-import`, `custom-save`, `custom-name`, face-library items |
| `page-parts` (6.3) | `parts-apply`, `parts-live-toggle`, `parts-random`, `parts-reset`, `parts-symmetry-toggle`, `parts-save-bottom`, part-group buttons |
| `page-scroll` (6.4) | `scroll-text`, `scroll-speed-range`, `scroll-speed`, `scroll-speed-minus`/`plus`, `scroll-play`, `scroll-pause`, `scroll-stop`, `scroll-step-prev`, `scroll-step-next` |
| `page-debug` (6.5) | `gpio-B1`…`gpio-B6S`, `gpio-B3B1`, `gpio-B3B2`, `gpio-B6L`, `firmware-pause`, `debug-send-off/checker/border/saved/on`, `debug-m370`, `debug-m370-send`, `debug-reset-battery-min/max`, `debug-refresh-power`, `debug-raw-json`+`debug-raw-confirm`+`debug-raw-send` |

### WebUI steps (mirror every function + option)
| # | Action (via `__ui`) | Verify |
|---|---|---|
| 9c.1 | `setValue("color-input","#00ff00")` (+ try `parent`/`child-color-select`) | swatch + serial `led current` = `#00ff00` |
| 9c.2 | sweep `setValue("brightness-input",N)` for representative N incl. 10/200; `click("brightness-plus")`/`minus`; click each `brightness-presets` item | `brightness-range` mirrors; serial `led status` matches |
| 9c.3 | `click("mode-toggle")`, `click("face-next")`/`face-prev`, `click("interval-up")`/`down`, sweep `setValue("auto-interval",s)` | serial `mode status` / `auto status` match |
| 9c.4 | custom page: draw via matrix cells, `click("custom-fill")`/`invert`/`clear`, `click("custom-send")`, `click("custom-save")` | serial `led dump compact` reflects frame |
| 9c.5 | parts page: `click("parts-random")`, `parts-symmetry-toggle`, `parts-apply` | preview + serial frame |
| 9c.6 | scroll: `setValue("scroll-text", <random ASCII/中文/日本語/emoji>)`, sweep `setValue("scroll-speed",fps)`, `click("scroll-play")`, `scroll-pause`, `scroll-step-next/prev`, `scroll-stop` | serial `scroll status` count>0; glyphs render; `led dump compact` non-empty |
| 9c.7 | debug GPIO sim: `gpio("B1")`…`gpio("B6S")`, `gpio("B3B1")`, `gpio("B3B2")` | serial logs `source=...` and matching face/mode/brightness change |
| 9c.8 | debug LED tests: `click("debug-send-checker")`, `debug-send-border`, `debug-send-off`; `setValue("debug-m370", <hex>)` + `click("debug-m370-send")` | serial `led dump compact` matches |
| 9c.9 | debug power: `click("debug-reset-battery-min")`, `debug-reset-battery-max`, `debug-refresh-power` | serial `battery status` |
| 9c.10 | raw command: `setValue("debug-raw-json",'{"cmd":"pause_scroll"}')`, check `debug-raw-confirm`, `click("debug-raw-send")` | serial `scroll status` paused |
| 9c.11 | **coverage audit** | `__ui.list()` count ≈ all controls; every catalog control with a function was clicked at least once; none threw |

> **Random character sampling (9c.6):** generate ≥5 strings per set — ASCII, Simplified/Traditional Chinese, Japanese kana+kanji, emoji — plus a mixed-script string, empty, single char, and near-max-length. The browser rasterizes them; the firmware plays them; serial verifies frame count/playback. This is the same text-scroll coverage as §9b.5, driven from the UI.

## 10. Final restore & report

1. **Restore baseline (section 0.2)** and verify: run `status`, `led current`,
   `auto status`, `face status`, `log status` and confirm each matches the values
   captured before section 1. Make sure brightness is back to baseline (not the
   safety-cap `10`), no scroll is running, and a real face is displayed.
2. Confirm **no guardrail was violated** (no full-field pattern left lit, no
   sampling loops, log level back to baseline).
3. Produce a table: step | command/control | interface (serial / WebUI) | result
   (PASS/WARN/FAIL) | notes. Cover **both** the serial steps (§1–9b) and the
   WebUI steps (§9c), and note where a WebUI action and its serial twin were
   confirmed to match. End with `SUMMARY pass=<n> warn=<n> fail=<n>`. Any FAIL
   must include the exact reply/log line (or `__ui` result) observed and the
   expectation it violated; list any `WARN reason=low_battery` skips and any
   `__ui.list()` controls that could not be exercised.
