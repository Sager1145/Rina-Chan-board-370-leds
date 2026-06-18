# Serial Test Console, Logging & GPIO Emulation -- Implementation Plan

Goal: make the board fully testable over the USB serial line -- emulate every GPIO button,
read detailed live data (voltage, LED frame buffer, LED commands, scroll/face/mode state),
and emit a structured serial log of every operation (button press, auto face change, scroll
events, brightness, battery, etc.). All additive: **no existing behavior changes**.

This is a plan, not yet code. It is grounded in the current source (symbols and line
numbers below are real). Each phase is an independent, revertable commit.

---

## 0. Constraints (hard requirements)

1. **Zero behavior change** when the feature is compiled out, and no logic change when
   compiled in -- serial button emulation must reuse the exact same code path as real
   GPIO/HTTP so the board behaves identically.
2. **Machine-parseable** output so an AI agent (or `pyserial` script) can drive and assert.
3. **Comment every command in the code** (the parser table doubles as documentation).
4. **Non-blocking**: the serial reader must never stall the Core-0 cooperative loop or the
   Core-1 WS2812 render task.
5. A dedicated **"Automated Testing (Serial)"** section in the repo `README.md`.

---

## 1. Current state (verified findings)

- `Serial.begin(115200)` in `setup()` (`src/main.cpp:29`). **No serial input is read
  anywhere today** (`grep` for `Serial.read/available/serialEvent` = none), so a console is
  purely additive.
- Cooperative Core-0 loop (`src/main.cpp:81-95`) already calls a tidy list of `service*()`
  functions; a `serviceSerialConsole()` call slots in with no restructuring.
- Logging exists but is sparse and ad-hoc: `LOGV(...)` macro gated by `RINACHAN_VERBOSE_LOGS`
  (default `0`) -> `Serial.printf` when on, no-op when off (`src/config.h:155-164`), plus
  scattered `Serial.println` calls.
- Button entry point is already source-tagged: `runButtonAction(const String& button,
  const String& source)` (`src/buttons.cpp:91`). Calling it with `source="serial"` reuses
  the identical action path used by `"gpio"` and `"api_button"`. Combos `B3B1`/`B3B2` are
  valid codes; battery overlay is the `battery_overlay` command.
- Data accessors already exist:
  - LED frame: `runtimeFrameBits()` (`state.h:198`), `countLitLeds()`,
    `readFrameStateSnapshot()` (`led_renderer.h:18-19`), last command in
    `runtimeState().lastReason` / `lastM370` (`state.h:30-31`), color `colorR/G/B`,
    `brightness`.
  - Power/voltage: `readPowerStatusSnapshot()` -> full `PowerStatus` (vbat, vcharge,
    batteryPercent, adcMv, charging, ...) (`power_monitor.h:48`).
  - Scroll: `scrollSessionSnapshot()` (`scroll_session.h:95`).
  - Counters: `framesAccepted/Rejected/Queued`, `commandsAccepted/Rejected` (`state.h:34-40`).
- Matrix geometry for an ASCII LED dump: `LED_COUNT=370`, `FRAME_BYTES=47`,
  `MATRIX_ROWS=18`, `ROW_LENGTHS[]`, `ROW_OFFSETS[]` (`config.h:22,81,84-96`).
- Build envs in `platformio.ini`; logging is already behind a `-D` flag pattern.

---

## 2. Architecture

Two new, self-contained modules plus thin additive hooks:

```
src/serial_log.{h,cpp}       <- structured, categorized, runtime-toggleable logger
src/serial_console.{h,cpp}   <- line-based command reader + dispatch (Core-0, non-blocking)
```

Wiring (the only edits to existing files):
- `main.cpp`: `#include "serial_console.h"`; call `initSerialConsole()` in `setup()` (after
  `Serial.begin`) and `serviceSerialConsole()` once per `loop()`.
- Event-site files get **one log line added** per event (output-only; see sec 6).
- `platformio.ini`: add feature `-D` flags to a test env (sec 10).

Dependency direction: `serial_console -> {everything it reports/drives}` (it is a leaf
consumer; nothing depends back on it). `serial_log` depends on nothing project-specific.

---

## 3. Module A -- `serial_log` (structured logging)

### 3.1 Design

- Categories (bitmask, so each can be toggled independently):
  `SYS, BTN, FACE, MODE, SCROLL, LED, PWR, NET, CMD, TEST`.
- One macro used everywhere:
  ```cpp
  // Emits: "[<ms>] <CAT> <event> k=v k=v ..."  (one line, parseable)
  RLOG(CAT, fmt, ...);
  ```
  Expands to a guarded call: `if (serialLogEnabled(CAT)) serialLogf("CAT", fmt, ...);`
- **Compile gate**: wrap the whole logger in `#if ENABLE_SERIAL_LOG`. When `0`, `RLOG`
  becomes `do {} while (0)` -- byte-for-byte the same as today's disabled `LOGV`, so a
  production build is unchanged. Keep `LOGV` working (alias it to `RLOG(SYS, ...)`).
- **Runtime control** (via console, sec 5): enable/disable categories and a global level
  (`0=off, 1=event, 2=verbose`). Default for the test env: all categories on at level 1.
- **Format contract** (so the agent can parse):
  `^\[(\d+)\] ([A-Z]+) (\S+)( (?:\w+=\S+ ?)*)$`
  - field 1 = `millis()`, field 2 = category, field 3 = event name, rest = `key=value`
    pairs. Values with spaces are quoted.

### 3.2 Thread safety (Core-0 vs Core-1)

- The Core-1 render/scroll task (`scroll.cpp`) is the only non-Core-0 writer. Logging the
  per-tick cursor advance there would (a) interleave bytes with Core-0 prints and (b) flood
  the line. Policy:
  - Core-1 logs only **rate-limited** SCROLL ticks (e.g. >=1/sec) or nothing by default;
    full per-frame logging is a level-2 opt-in.
  - Use a tiny `portMUX`/`Serial` is already mutex-internally safe on ESP32 Arduino, but to
    avoid interleaved lines, route Core-1 log requests through a lock-free single-producer
    ring buffer drained by `serviceSerialConsole()` on Core-0. (Simpler v1: Core-1 logs at
    most one line/sec directly; upgrade to the ring buffer if interleaving is observed.)

### 3.3 LED command ring buffer (for `get ledcmd`)

Add a small in-RAM ring (e.g. 16 entries) of recent LED applies:
`{ ms, reason[24], litLeds, source }`. The LED apply functions push one entry (output-only).
`get ledcmd` / `get ledcmd N` prints the last N. This gives the "LED commands" history the
request asks for without touching render logic.

---

## 4. Module B -- `serial_console` (command interface)

### 4.1 Reader (non-blocking)

```cpp
void serviceSerialConsole() {
    while (Serial.available()) {              // drain only what's buffered; never blocks
        char c = (char)Serial.read();
        if (c == '\n' || c == '\r') { if (lineLen) dispatchSerialCommand(lineBuf); lineLen = 0; }
        else if (lineLen < SERIAL_CMD_MAX) lineBuf[lineLen++] = c;
        else lineLen = 0;                     // overflow -> drop the oversized line
    }
}
```
- Fixed `char lineBuf[SERIAL_CMD_MAX]` (e.g. 192) -- no heap, no `String` growth in the hot
  path.
- One command per line; tokenized by spaces. Echo is optional (`echo on/off`).
- Every reply is single-line and prefixed: `OK <cmd> ...` / `ERR <cmd> <reason>` / for dumps
  a tagged block delimited by `=== <tag> BEGIN ===` ... `=== <tag> END ===`.

### 4.2 Dispatch table (self-documenting)

The parser is a table of `{ name, handler, "one-line help" }`. The help string IS the inline
comment required by the task, and `help` prints the table. Example skeleton:

```cpp
// Each row: command keyword, handler, and the human/agent-facing description.
// `help` prints this table; the descriptions are the authoritative command docs.
static const SerialCmd CMDS[] = {
  { "help",   cmdHelp,   "list all commands" },
  { "btn",    cmdBtn,    "btn <B1|B2|B3|B4|B5|B3B1|B3B2|B6S|B6L> : emulate a GPIO button (source=serial)" },
  { "get",    cmdGet,    "get <status|power|leds|ledcmd|scroll|faces|stats> : dump live data" },
  { "scroll", cmdScroll, "scroll <start|stop|pause|resume|step -1|+1> : drive text scroll" },
  { "set",    cmdSet,    "set <mode m|a | bright 0-255 | color #RRGGBB> : control (parity w/ buttons)" },
  { "frame",  cmdFrame,  "frame <M370> : push one frame immediately (test pattern)" },
  { "log",    cmdLog,    "log <cat on|off | all on|off | level 0-2> : control serial logging" },
  { "selftest", cmdSelfTest, "run the built-in non-destructive self-test sequence" },
  { "stats",  cmdStats,  "reset|show firmware counters" },
  { "reboot", cmdReboot, "ESP.restart() (test teardown)" },
};
```

---

## 5. Command reference (full)

| Command | Reuses | Output (parseable) | Notes |
|---|---|---|---|
| `help` | -- | command list | also the in-code docs |
| `btn <CODE>` | `runButtonAction(CODE, "serial")` | `OK btn <CODE> handled=<bool>` | CODE in B1,B2,B3,B4,B5,B3B1,B3B2; identical path to GPIO |
| `btn B6S` / `btn B6L` | `battery_overlay` cmd | `OK btn B6S` | short/long B6 = battery overlay (single-shot/long) |
| `get status` | status builder (sec 7.1) | `STATUS k=v ...` block | mode, playback, brightness, scroll*, counters |
| `get power` | `readPowerStatusSnapshot()` | `POWER vbat=.. vcharge=.. pct=.. adcMv=.. charging=..` | voltages + battery % |
| `get leds` | `runtimeFrameBits()`+geometry | ASCII matrix + `hex=<47 bytes>` + `lit=<n>` | full LED frame |
| `get ledcmd [N]` | LED ring buffer (sec 3.3) | `LEDCMD ms=.. reason=.. lit=.. src=..` xN | recent LED applies |
| `get scroll` | `scrollSessionSnapshot()` | `SCROLL active=.. paused=.. user=.. system=.. idx=.. count=.. interval=.. timeline=..` | full scroll FSM |
| `get faces` | saved-face store | `FACE i=.. id=.. name=..` list + `count=..` | library summary |
| `get stats` | `runtimeState()` counters | `STATS framesAccepted=.. ... commandsAccepted=..` | health counters |
| `scroll start` | `startFirmwareScroll()` | `OK scroll start started=<bool>` | uses cached frames |
| `scroll stop` | `stopFirmwareScroll(restoreAuto,true)` | `OK scroll stop` | clear+restore |
| `scroll pause|resume` | `scrollSessionSetUserPaused()` | `OK scroll pause paused=<bool>` | composable user pause |
| `scroll step -1|+1` | `scrollSessionStep()` | `OK scroll step idx=..` | latches pause (per recent fix) |
| `set mode m|a` | `setMode()` | `OK set mode <m/a>` | parity with B3 |
| `set bright N` | `setBrightness()` | `OK set bright <N>` | parity with B4/B5 |
| `set color #RRGGBB` | `setColor()` | `OK set color #..` | -- |
| `frame <M370>` | `applyM370(.,"serial_frame",.)` | `OK frame lit=..` / `ERR frame <why>` | test pattern push |
| `log <cat> on|off` | `serial_log` | `OK log <cat>=<state>` | cat in SYS,BTN,FACE,...,all |
| `log level <0-2>` | `serial_log` | `OK log level=<n>` | global verbosity |
| `selftest` | sec 12 | `TEST <name> PASS|FAIL ...` + `TEST DONE pass=.. fail=..` | non-destructive |
| `stats reset` | -- | `OK stats reset` | zero counters |
| `reboot` | `ESP.restart()` | `OK reboot` | -- |

All `get` dumps also echo a trailing `END` marker so a reader knows the block is complete.

---

## 6. Event log hook points (additive, one line each)

Each is a single `RLOG(...)` added at an existing event site -- no control-flow change.

| Event | File:function | Log line (example) |
|---|---|---|
| Button action (any source) | `buttons.cpp:runButtonAction` | `BTN action code=B1 src=gpio handled=1` |
| Raw press/release/repeat | `buttons.cpp:handleHardwareButton*` | `BTN press code=B3` / `BTN release code=B3` |
| Scroll-stop event mark | `scroll_session.cpp:scrollSessionMarkStoppedByButton` | `BTN scrollstop btn=B1 src=gpio seq=12` |
| Auto face change | `faces.cpp:serviceAutoPlayback` | `FACE auto idx=3/8 reason=firmware_auto_saved_face` |
| Saved-face apply | `faces.cpp:applySavedFaceIndex` | `FACE apply idx=3 id=happy reason=..` |
| Mode change | `faces.cpp:setMode` / `toggleModeFromButtonAction` | `MODE set mode=manual persist=1` |
| Scroll start/stop | `scroll_session.cpp:scrollSessionStart/Stop` | `SCROLL start count=42 interval=80` / `SCROLL stop cleared=1 restoreAuto=0` |
| Scroll pause/resume | `scroll_session.cpp:setFirmwareScrollPauseFlag` | `SCROLL pause user=1 system=0 eff=1` |
| Scroll step | `scroll_session.cpp:scrollSessionStep` | `SCROLL step idx=5 dir=+1 latchedPause=1` |
| Scroll tick (rate-limited) | `scroll_session.cpp:scrollSessionTickCursorLocked` | `SCROLL tick idx=5 (<=1/s)` |
| LED apply | `led_renderer.cpp:applyM370/applyPackedFrameImmediate/applyBlankFrame` | `LED apply reason=.. lit=120 src=..` |
| Brightness/color | `led_renderer.cpp:setBrightness/setColor` | `LED bright v=140` / `LED color #f971d4` |
| Battery event / overlay | `power_monitor.cpp` / `button_animations.cpp` | `PWR vbat=3.92 pct=74 charging=0` / `PWR overlay start` |
| Command accepted/rejected | `web_api.cpp` command dispatch | `CMD ok cmd=start_scroll` / `CMD rej cmd=.. err=..` |
| Boot milestones | `main.cpp:setup` | `SYS boot fs=ok faces=8 ip=192.168.1.14` |

Because these are behind `RLOG` (compiled out when `ENABLE_SERIAL_LOG=0`), a release build is
identical to today.

---

## 7. Data dump formats

### 7.1 `get status`
Reuse the existing snapshot sources (`scrollSessionSnapshot`, `readFrameStateSnapshot`,
`runtimeState`) and print `key=value` pairs -- NOT the web JSON builder (keep serial cheap
and avoid pulling in the HTTP doc). Same field names as `/api/status` so tooling is
consistent.

### 7.2 `get power` (voltage)
```
=== POWER BEGIN ===
POWER vbat=3.921 vcharge=4.870 pct=74 charging=0 batValid=1 adcMv=1960 calibMin=3.30 calibMax=4.20
=== POWER END ===
```

### 7.3 `get leds` (LED data)
Render the 18-row irregular matrix from `runtimeFrameBits()` using `ROW_LENGTHS/ROW_OFFSETS`:
```
=== LEDS BEGIN ===
LEDS lit=120 bright=140 color=#f971d4
ROW00 ..##....##..
ROW01 .#..#..#..#.
...
hex=00ff2a...(47 bytes)
=== LEDS END ===
```
`#` = lit, `.` = off. The `hex` line is the packed `FRAME_BYTES` buffer for exact assertions.

### 7.4 `get ledcmd` (LED commands)
Dumps the ring buffer (sec 3.3): recent `applyM370/applyPackedFrame/applyBlank` calls with
`ms`, `reason`, `lit`, `src`.

### 7.5 `get scroll`
Direct print of `scrollSessionSnapshot()` fields (active/paused/user/system/idx/count/
interval/timeline/uploadComplete/hasSourceText).

---

## 8. GPIO button emulation

`btn <CODE>` calls `runButtonAction(String(CODE), "serial")` -- the **same** function the
GPIO ISR path and the HTTP `button` command call. This guarantees identical behavior
(face cycling, scroll-stop side effects, `scrollStopEvent` recording, mode toggle, combos).
For combos that depend on simultaneous hold (`B3B1`/`B3B2`), expose them as discrete codes
(already supported) rather than trying to simulate timing. Optional `press <CODE>` /
`release <CODE>` can drive `buttons[]` state directly for hold-based tests if needed later.

`btn B6S`/`B6L` map to the `battery_overlay` command (short=single-shot, long=sustained),
matching the WebUI Debug simulator's `B6S`/`B6L`.

---

## 9. Non-invasiveness & safety

- **Compile gates**: `ENABLE_SERIAL_CONSOLE` and `ENABLE_SERIAL_LOG` (independent). Both
  default `0` in production envs; `1` in a dedicated `env:esp32s3-test`. With both `0`, the
  only residual change is two no-op calls in `loop()`/`setup()` that the compiler elides --
  effectively zero.
- **Reuse, don't fork**: every control command calls the existing function; no duplicated
  state machine, so no divergence risk.
- **Bounded, non-blocking I/O**: fixed-size line buffer, drain-only reader, no `delay()`.
- **Timing**: high-frequency events (scroll tick, render) are rate-limited or level-gated so
  logging cannot swamp the 115200 line or perturb WS2812 timing. Core-1 logging uses the
  ring-buffer drain (sec 3.2) to avoid interleaving and bus jitter.
- **No new locks** on the render hot path; `get leds` reads `runtimeFrameBits()` under the
  existing frame lock (snapshot copy), consistent with current readers.

---

## 10. Build configuration

Add a test env in `platformio.ini` (leave existing envs untouched):
```ini
[env:esp32s3-test]
extends = env:esp32s3
build_flags =
    ${env:esp32s3.build_flags}
    -D ENABLE_SERIAL_CONSOLE=1
    -D ENABLE_SERIAL_LOG=1
    -D RINACHAN_VERBOSE_LOGS=1
```
Production `env:esp32s3` stays at the current flags (feature absent). Flash test builds with
`pio run -e esp32s3-test -t upload`.

---

## 11. Phased rollout (independent commits)

- **P1 -- logger core.** Add `serial_log.{h,cpp}` + `RLOG`/category gating; alias `LOGV`.
  No hooks yet. Build clean both gate states. (Behavior-identical.)
- **P2 -- event hooks.** Insert the sec-6 `RLOG` lines at each event site. Output-only.
- **P3 -- console reader + `get*` dumps.** Add `serial_console.{h,cpp}`, wire into
  `main.cpp`, implement `help` + all read-only `get` commands + `log` control.
- **P4 -- control + emulation.** `btn`, `scroll`, `set`, `frame`, `stats`, `reboot`.
- **P5 -- selftest + README + host harness.** Built-in `selftest`, the README section
  (Appendix A), and the `pyserial` harness (sec 12).

Each phase reverts independently; P1-P2 are pure additions; P3+ are gated by
`ENABLE_SERIAL_CONSOLE`.

---

## 12. Host-side automated harness (no Wi-Fi needed)

A `tools/serial_test.py` (pyserial) opens the port at 115200, sends commands, parses the
`key=value` lines, and asserts -- a serial twin of the WebUI test plan, usable in CI on a
bench rig:

```python
# pseudo
s = serial.Serial(port, 115200, timeout=2)
def cmd(line): s.write((line+"\n").encode()); return read_block(s)
assert "handled=1" in cmd("btn B1")            # B1 cycles a face
st = parse(cmd("get scroll"))
cmd("frame <known M370>"); assert int(parse(cmd("get leds"))["lit"]) == EXPECTED
cmd("scroll pause"); assert parse(cmd("get scroll"))["paused"] == "1"
```

Self-test (`selftest`) runs a non-destructive sequence on-device and prints
`TEST <name> PASS|FAIL` lines, ending with `TEST DONE pass=N fail=M`, so an agent only needs
to send one command and read the result. Suggested coverage mirrors
`SCROLL_WEBUI_TEST_PLAN.md`: button cycle, mode toggle, scroll start/pause/step/stop,
brightness change, battery-overlay system pause, LED frame integrity -- each restoring prior
state at the end.

Tie-in: this serial path is the recommended automation when Wi-Fi join (an OS action) is not
scriptable; the WebUI plan's assertions map 1:1 onto `get status`/`get scroll`/`get power`.

---

## 13. Acceptance criteria

- Production build (`env:esp32s3`) binary behavior unchanged; diff of behavior = none.
- `env:esp32s3-test`: `help` lists all commands; every `btn`/`set`/`scroll` command produces
  the same firmware state as the equivalent GPIO/WebUI action (cross-checked via `get status`
  and `/api/status`).
- Every event in sec 6 produces exactly one parseable log line; no interleaved/garbled lines
  under load; WS2812 shows no glitch with logging on.
- `get leds` ASCII + hex matches a known test frame bit-for-bit.
- `selftest` returns deterministic PASS for all sub-tests on a healthy board.

---

## 14. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Log volume perturbs WS2812 timing | Rate-limit/level-gate high-freq logs; Core-1 via ring buffer drained on Core-0 |
| Interleaved lines from two cores | Single-producer ring buffer; Core-0 is the only `Serial` writer |
| Serial RX buffer overflow on long input | Fixed line buffer, drop oversized lines, drain-only reader |
| Feature creep into production build | Two independent compile gates, default off; only no-op calls remain |
| `get leds` racing the render task | Read under existing frame lock (snapshot copy), like current readers |
| Divergent behavior from a parallel command path | All commands reuse existing functions; no forked logic |

---

## Appendix A -- README section (ready to paste)

> The parent-repo `README.md` (`Rina-Chan-board-370-leds/README.md`) is OUTSIDE the connected
> `esp32s3_firmware` folder, so it cannot be edited from this session. Paste the block below
> under a new heading, or connect the parent folder and I will insert it.

```markdown
## Automated Testing (Serial Console)

The firmware exposes a USB-serial test console (test builds only). It lets a script or AI
agent emulate every button, drive scroll/face/mode, and read live voltage / LED / scroll
data -- no Wi-Fi required.

### Build & connect
- Flash the test build: `pio run -e esp32s3-test -t upload`
- Open the port at **115200 8N1** (e.g. `pio device monitor -b 115200`, or pyserial).
- Send `help` for the full command list.

### Output format
Every event log line is: `[<ms>] <CAT> <event> key=value ...`
Command replies are `OK <cmd> ...` / `ERR <cmd> <reason>`; data dumps are wrapped in
`=== <TAG> BEGIN ===` ... `=== <TAG> END ===`.

### Commands
| Command | Description |
|---|---|
| `help` | list all commands |
| `btn B1\|B2\|B3\|B4\|B5\|B3B1\|B3B2\|B6S\|B6L` | emulate a GPIO button (same path as hardware) |
| `get status` | full runtime state (mode, playback, brightness, scroll, counters) |
| `get power` | battery/charger voltages and percent |
| `get leds` | current LED frame as ASCII matrix + packed hex + lit count |
| `get ledcmd [N]` | recent LED command history |
| `get scroll` | scroll state machine snapshot |
| `get faces` | saved-face library summary |
| `get stats` | firmware health counters |
| `scroll start\|stop\|pause\|resume\|step -1\|+1` | drive text scroll |
| `set mode m\|a` / `set bright 0-255` / `set color #RRGGBB` | direct controls |
| `frame <M370>` | push one frame immediately |
| `log <cat> on\|off` / `log all on\|off` / `log level 0-2` | control serial logging |
| `selftest` | run the built-in non-destructive test sequence |
| `stats reset` / `reboot` | counters reset / restart |

### Logging categories
`SYS BTN FACE MODE SCROLL LED PWR NET CMD TEST` -- each toggleable via `log <cat> on|off`.
All operations (button presses, automatic face changes, scroll/pause/step, brightness,
battery events, LED applies, accepted/rejected commands) emit a log line.

### Example agent session
```
> btn B1
[12840] BTN action code=B1 src=serial handled=1
[12841] FACE apply idx=4 id=wink reason=serial_B1_next_saved_face
OK btn B1 handled=1
> get power
=== POWER BEGIN ===
POWER vbat=3.921 vcharge=0.000 pct=74 charging=0
=== POWER END ===
> selftest
TEST btn_cycle PASS
TEST scroll_pause_step PASS
TEST battery_overlay_pause PASS
TEST DONE pass=8 fail=0
```
```

---

## Appendix B -- In-code comment style for commands

The dispatch table's help strings are the canonical per-command docs (sec 4.2). In addition,
each handler gets a short block comment stating: purpose, which existing function it reuses,
expected reply, and that it is test-only/non-destructive. Example:

```cpp
// btn <CODE> -- emulate a hardware button over serial.
// Reuses runButtonAction(code, "serial"); identical to a real GPIO press, so all side
// effects (face cycle, scroll-stop + scrollStopEvent, mode toggle) are exercised.
// Reply: "OK btn <CODE> handled=<0|1>". Non-destructive (no flash writes beyond normal).
static void cmdBtn(int argc, char** argv) { ... }
```
