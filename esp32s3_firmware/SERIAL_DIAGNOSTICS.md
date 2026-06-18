# Serial Diagnostics — README section (ready to paste)

> This file contains the documentation block requested for the **parent**
> `Rina-Chan-board-370-leds/README.md`. The parent folder is outside the
> connected `esp32s3_firmware` workspace, so it could not be edited directly —
> copy the section below (everything under the horizontal rule) into the parent
> `README.md`. The `tools/serial_test.py` host harness it references already
> lives in this repo.

---

## Automated Testing and Serial Diagnostics

The firmware ships with a **non-blocking USB-serial test console**, a structured
**diagnostic logger**, and a built-in **self-test runner**. Together they let you
test the board — emulate every button, drive scroll/face/mode, read live battery
voltage, dump the LED frame, and run assertions — **without the WebUI and without
Wi-Fi**. The feature is additive: with no commands issued and the default log
level, normal LED/WebUI/button/battery/scroll behavior is unchanged.

### Build and connect

* **Baud rate: `115200` (8N1).** This matches `monitor_speed` in `platformio.ini`.
* The feature is **enabled by default** in the standard build. Flash normally:

  ```bash
  pio run -e esp32s3 -t upload
  ```

  Or flash the verbose test build (adds extra `LOGV` chatter):

  ```bash
  pio run -e esp32s3-test -t upload
  ```

* Open a serial monitor at 115200:
  * **PlatformIO:** `pio device monitor -b 115200`
  * **Arduino IDE:** Tools → Serial Monitor, set baud to **115200**, line ending
    **Newline** (or Both NL & CR).
  * **PuTTY / any terminal:** Serial, 115200 8N1.
* Type `help` and press Enter for the full command list.

To compile the feature **out** entirely (stripped production image), set any of
these to `0` in `build_flags`: `ENABLE_SERIAL_DIAGNOSTICS`,
`ENABLE_SERIAL_CONSOLE`, `ENABLE_FIRMWARE_TESTS`. Each hook then becomes a no-op.

### Output format

Every diagnostic **log line** is machine-parseable:

```
[<millis> ms] [<LEVEL>] [<CATEGORY>] key=value key=value ...
```

Command **replies** are line-oriented: `OK <cmd> ...`, `ERR <cmd> <reason>`, or
`WARN <cmd> <reason>`. Multi-line **dumps** are wrapped in
`=== <TAG> BEGIN ===` … `=== <TAG> END ===`.

### Log levels

`ERROR` < `WARN` < `INFO` < `DEBUG` < `TRACE` — default is **`INFO`**.

| Level | Adds |
|-------|------|
| `ERROR` | failures, invalid states, rejected commands |
| `WARN`  | recoverable issues, rejected serial/API commands |
| `INFO`  | button/mode/face/LED/scroll/command events (default) |
| `DEBUG` | per-sample ADC battery/charge reads, button debounce/conflict |
| `TRACE` | rate-limited (≤1/s) scroll-tick frame index |

Categories: `SYS BUTTON MODE FACE AUTO SCROLL LED ADC CMD TEST`.

Control logging at runtime:

```
log level DEBUG      # raise verbosity
log on | log off     # master enable
log status           # show current enabled flag + level
```

### Command list

| Command | Description |
|---|---|
| `help` / `help buttons\|led\|adc\|logs\|tests` | list all commands / topic help |
| `status` | full runtime snapshot (mode, brightness, face, scroll, counters) |
| `version` | firmware id + active feature gates + free heap |
| `uptime` | milliseconds since boot |
| `log level <ERROR\|WARN\|INFO\|DEBUG\|TRACE>` / `log on\|off` / `log status` | logger control |
| `btn press\|release\|tap <B1..B6>` | emulate a GPIO button (logs `source=serial`) |
| `btn hold <B1..B6> <ms>` | hold with auto-release (produces real repeats) |
| `btn repeat <B1..B6> <n> <ms>` | fire the action `n` times spaced `ms` apart |
| `btn combo B3+B1\|B3+B2 tap\|hold <ms>` | auto-interval combos |
| `btn status` | per-button physical + emulated pressed state |
| `led status` | mode, brightness, active face/index, scroll state, pending frame |
| `led color #RRGGBB` | set global LED color (full 24-bit; mirrors `set_color`) |
| `led brightness [N]` | show / set brightness (clamped 10–200) |
| `led current` | current color, brightness, lit count |
| `led dump` | ASCII 18-row matrix + 93-char hex frame |
| `led dump compact` | `M370:<hex>` one-liner for copy/paste into tests |
| `led clear` | blank the frame |
| `led test pattern checker\|rows\|cols\|all_on\|all_off\|single <0..369>` | apply a test pattern |
| `led command_history` | recent LED-apply ring buffer |
| `adc status` / `adc read [raw\|vbat\|charge]` | ADC voltage reads |
| `battery status` / `battery sample <N>` | battery snapshot / forced N samples (≤50) |
| `battery reset min\|max` / `battery overlay [single\|hold]` | reset calib / show battery display (mirrors `reset_battery_*`, `battery_overlay`) |
| `mode status\|manual\|auto` | mode control |
| `face status\|next\|prev\|apply <N>` | saved-face navigation |
| `auto status\|interval [N]\|start\|stop` | auto playback control |
| `scroll status\|start [ms]\|interval ms\|fps n\|pause\|resume\|stop\|clear\|step next\|prev` | text scroll control (mirrors `start_scroll`, `set_scroll_interval`, …) |
| `pause` / `resume` | global pause/resume (mirrors `pause` / `resume`) |
| `frame <M370>` | push one arbitrary frame (mirrors `POST /api/frame`) |
| `terminate [scroll\|face\|all]` | stop competing activities (mirrors `terminate_other_activities`) |
| `test list\|run all\|run <group>\|run sweep\|report` | self-test runner; `run sweep` = every brightness/color/speed |

The button emulator injects into the **same** debounce/repeat/combo/action code
path as the physical GPIO, so emulated and physical buttons behave identically;
only the log `source=` tag differs (`serial` vs `physical`). Emulated presses
never permanently override the GPIO — physical input always still works, and a
simultaneous physical+serial press resolves deterministically to "pressed" and is
logged.

### Examples

**Test buttons**

```
> btn tap B1
[12840 ms] [INFO] [BUTTON] source=serial id=B1 event=action handled=1
[12841 ms] [INFO] [FACE] event=apply idx=5/8 id=wink reason=serial_B1_next_saved_face
OK btn tap B1 handled=1

> btn combo B3+B1 tap        # decrease auto interval
> btn hold B5 1500           # brightness-up held 1.5s -> repeats
> btn status
BTN id=B1 physical=0 serial=0
...
```

**Read voltage**

```
> adc read vbat
OK adc read vbat vbat=7.421 raw=2410 percent=81
> battery status
=== BATTERY BEGIN ===
BATTERY vbat=7.421 vcharge=0.000 percent=81 charging=0 batValid=1 chargeValid=1
BATTERY vbatRaw=2410 vchargeRaw=0 calibMin=6.200 calibMax=8.400 disconnected=0
=== BATTERY END ===
```

**Dump LED state**

```
> led test pattern checker
OK led test pattern checker lit=185
> led dump compact
OK led dump compact lit=185 M370:aaa...   # paste-able frame
> led dump
=== LEDS BEGIN ===
LEDS lit=185 bright=50 color=#f971d4
ROW00 #.#.#.#.#.#.#.#.#.
...
hex=aaaaa...
=== LEDS END ===
```

**Run automated tests**

```
> test run all
[TEST] buttons.tap_b1 PASS before=7 after=8
[TEST] buttons.tap_b2 PASS before=8 after=7
[TEST] buttons.b3_toggle PASS from=manual to=auto
[TEST] buttons.brightness_limit PASS min=10 max=200
[TEST] buttons.auto_interval PASS min=500 max=10000 now=3000
[TEST] led.clear PASS lit=0
[TEST] led.pattern_all_on PASS lit=370
[TEST] led.pattern_single PASS lit=1
[TEST] adc.read PASS vbat=7.42 percent=81
[TEST] modes.toggle PASS auto_ok=1 manual_ok=1
[TEST] scroll.step_no_data WARN reason=no_scroll_frames
[TEST] SUMMARY pass=10 warn=1 fail=0
```

The self-test runner snapshots mode/brightness/auto-interval/face before running
and restores them afterward, so it is non-destructive.

### Host harness

`esp32s3_firmware/tools/serial_test.py` (requires `pip install pyserial`) drives
the same commands from a PC and asserts on the parsed replies:

```bash
python esp32s3_firmware/tools/serial_test.py /dev/ttyACM0   # or COM7 on Windows
```

### Timing warning

Diagnostic logging is line-rate-limited and emitted off the WS2812 render path,
but **detailed logging during timing-critical demos is still discouraged**. Keep
the level at `INFO` (or `log off`) during performances; `DEBUG`/`TRACE` and
`battery sample N` add serial traffic that, while non-blocking, is unnecessary
when you are not actively debugging. The `test run` commands and `led test
pattern` commands change the displayed frame — don't run them mid-demo.
