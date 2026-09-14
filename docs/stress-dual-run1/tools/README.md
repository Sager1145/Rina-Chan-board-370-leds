# Dual-board stress test host tools

Host-side Python helpers for `docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md`. Run
everything with the PlatformIO venv's interpreter, which has `pyserial`
installed:

```sh
~/.platformio-venv/bin/python <tool>.py --help
```

No other third-party dependencies are required. All multi-step shell
recipes below assume `bash` (this Mac's `zsh` handles some of the
redirection/process-substitution differently, and there is no `timeout`
binary here — use `--duration`/background jobs instead).

**Hardware safety**: none of these tools should ever be pointed at a real
`/dev/cu.usbmodem*` port or the physical iPhone's UDID except during an
actual, supervised test run. `serial_logger.py` opens whatever port you
give it — double check it's the intended board before running it, since
opening a port the wrong board's logger already owns will fight over that
port. `iphone_app.py` always supports `--dry-run` for rehearsal.

## 1. `serial_logger.py PORT LOGFILE --duration SEC [--status-interval 10] [--stall-sec 30]`

Resilient per-board serial logger.

- Prefixes every received line with `[HOST <epoch.ms>] `, strips NUL bytes.
- Sends `log level debug` on open and after every reopen; sends `status`
  every `--status-interval` seconds.
- Reads commands to send to the board from `<LOGFILE>.cmd` — append one
  line per command from another process/script while the logger is
  running. Two pseudo-commands are handled specially:
  - `__reset__` — pulses DTR/RTS (DTR=False, RTS=True, sleep 0.1s, RTS=False)
    to hardware-reset an ESP32-S3 USB-Serial/JTAG board.
  - `__reopen__` — closes and reopens the serial port.
- If the port disappears (`OSError`/`SerialException`), logs `PORT_GONE`,
  polls every 0.5s for the device node to return, reopens it, logs
  `PORT_BACK`, and resends `log level debug`.
- If no bytes arrive for `--stall-sec` seconds while the port is still
  present, logs `STALL` and reopens (a real stall occurred on a board on
  2026-09-13; this is the automated recovery for that case).

Example (one logger per board, run in parallel background shells):

```sh
~/.platformio-venv/bin/python serial_logger.py /dev/cu.usbmodemXXXX board_a.log --duration 3600 &
~/.platformio-venv/bin/python serial_logger.py /dev/cu.usbmodemYYYY board_b.log --duration 3600 &
echo 'status' >> board_a.log.cmd     # ask board A for a status block right now
echo '__reset__' >> board_a.log.cmd  # hardware-reset board A
```

## 2. `board_status.py LOGFILE [--since EPOCH]`

Parses the latest (or all, filtered by `--since`) `STATUS ...` blocks
terminated by `=== STATUS END ===` into JSON, merging all `key=value`
pairs across the block's lines. Also extracts the firmware uptime from the
`[<n> ms]` prefix and flags `reboot: true` on a record when uptime
decreased since the previous record or `startup_sequence_complete` was
seen.

```sh
~/.platformio-venv/bin/python board_status.py board_a.log
```

Importable helpers:
- `parse_log_file(logfile, since=None)` -> list of records.
- `latest_record(logfile)` -> most recent record or `None`.
- `request_status(logfile, timeout=5.0)` -> appends `status` to
  `<logfile>.cmd` and waits (up to `timeout` s) for a newer `STATUS END`;
  returns the new record or `None` on timeout.

## 3. `events.py LOGFILE --from EPOCH --to EPOCH [--out FILE]`

Lists `[BLE]`/`[PROTO]` events, reboot markers
(`startup_sequence_complete`), and serial-logger resilience markers
(`PORT_GONE`/`PORT_BACK`/`STALL`) within a time window, as CSV
(`ts,category,event,fields,raw`).

```sh
~/.platformio-venv/bin/python events.py board_a.log --from 1700000000 --to 1700000600
```

## 4. `oracle.py --steps STEPS.csv --board A=LOGFILE --board B=LOGFILE [...] --out ROUTING.csv`

Merges per-board logs against a step CSV and judges INV-1 (zero cross-talk)
and INV-2 (session uniqueness) per `docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md`
section 3.

`STEPS.csv` columns: `ts_start,ts_end,step,seed,entry,action,active_board,expected_boards,flash_write`
(`expected_boards` is `;`-separated board labels, or `none`).

Per (step, board) it reports commands seen, accepted delta,
faceIndex/mode/brightness/color/intervalMs before/after, and
connect/disconnect/subscribe counts, then assigns:

- `ROUTING_FAIL` — a board not in `expected_boards` shows routed commands
  (ignoring host housekeeping `status`/`log level`) or a state/accepted
  change.
- `DUP_SESSION` — a board receives `subscribe` while already having an
  active client with no intervening `disconnect`.
- `UNKNOWN` — no STATUS bracket (before **and** after) available for that
  board/step.
- `PASS` — otherwise.

Prints a summary of verdict counts and writes the detail rows to
`ROUTING.csv`.

```sh
~/.platformio-venv/bin/python oracle.py --steps STEPS.csv --board A=board_a.log --board B=board_b.log --out ROUTING.csv
```

## 5. `iphone_app.py`

`xcrun devicectl` helpers, always run with
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. Every
subcommand supports `--dry-run` (prints the command instead of running
it) — always rehearse with `--dry-run` before pointing this at the real
device.

```sh
~/.platformio-venv/bin/python iphone_app.py --dry-run pid <udid>
~/.platformio-venv/bin/python iphone_app.py --dry-run force-quit <udid>            # devicectl ... terminate --pid <pid> --kill (SIGKILL; never --terminate-existing)
~/.platformio-venv/bin/python iphone_app.py --dry-run launch <udid> [--bundle com.rinachan.board] [args...]
~/.platformio-venv/bin/python iphone_app.py --dry-run crash-reports <udid> --since 1700000000
```

## 6. `recovery_log.py CSV --method ... --board-states JSON --reconnect-ms JSON --r1-ms N --r3-ms N --inv8-result ... --crash-report yes|no`

Appends one row to `RECOVERY.csv` per plan section 6 item 4a: injection
timestamp, method (`Q1`-`Q3` force-quit or `B1`-`B3` reboot), per-board
state/playback source at injection time, per-board reconnect duration,
R1/R3 pass durations, INV-8 result, and crash-report presence. Creates the
file with a header row on first use.

```sh
~/.platformio-venv/bin/python recovery_log.py RECOVERY.csv \
  --method Q1 \
  --board-states '{"A": {"state": "active", "source": "scroll"}, "B": {"state": "online", "source": "idle"}}' \
  --reconnect-ms '{"A": 4200, "B": 1800}' \
  --r1-ms 5100 --r3-ms 1200 \
  --inv8-result PASS --crash-report no
```

## Self-test

`selftest.py` validates all of the above without touching real hardware:

- (a) opens a `pty` pair (`os.openpty()`) standing in for a serial port,
  runs `serial_logger.py` against the slave end for ~6s with
  `--stall-sec 2` while a fake-board thread writes STATUS blocks and
  deliberately stalls for 3s, then checks the resulting log for HOST
  prefixes, `>> log level debug`, `>> status`, `STALL`, and a second
  `log level debug` proving the reopen happened.
- (b) builds two synthetic board logs plus a `STEPS.csv` and runs
  `oracle.py` against them, asserting the verdicts include one `PASS`, one
  `ROUTING_FAIL` (a non-expected board shows `name=set_color`), and one
  `DUP_SESSION` (a second `subscribe` with no intervening `disconnect`).
- (c) runs `iphone_app.py --dry-run` for `pid`, `force-quit`, `launch`, and
  `crash-reports`.

```sh
~/.platformio-venv/bin/python selftest.py
```

### Known limitation

`PORT_GONE`/`PORT_BACK` (the device node disappearing entirely, e.g. a
board rebooting into a fresh USB enumeration) cannot be simulated with a
`pty` pair — a pty's two ends don't disappear the way a USB-CDC/JTAG node
does when the underlying MCU resets. The self-test only exercises the
`STALL` recovery path (no bytes for `--stall-sec`), which uses the same
reopen-and-resend-`log level debug` code path as `PORT_GONE`/`PORT_BACK`.
The `PORT_GONE`/`PORT_BACK` branch itself is only exercised against real
hardware.
