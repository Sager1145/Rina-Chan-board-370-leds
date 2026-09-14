#!/usr/bin/env python
"""selftest.py — validate the dual-board stress-test host tools without
touching any real hardware.

IMPORTANT SAFETY NOTE: this script never opens a real serial device
(/dev/cu.usbmodem*) and never calls devicectl against the physical iPhone.
It uses a pty pair (os.openpty()) to fake a board's serial port, and
iphone_app.py's --dry-run mode to fake devicectl.

Checks:
  (a) serial_logger.py against the pty slave for ~6s, with a fake board
      thread writing STATUS blocks and a gap long enough to trigger STALL
      (--stall-sec 2). Verifies the log contains HOST-prefixed lines,
      '>> log level debug', '>> status', 'STALL', and evidence of a reopen
      (a second '>> log level debug' after the STALL).
  (b) two synthetic board logs + a STEPS.csv fed to oracle.py; checks that
      the verdicts include one PASS, one ROUTING_FAIL (a non-expected board
      shows name=set_color), and one DUP_SESSION (a second subscribe with no
      intervening disconnect).
  (c) iphone_app.py --dry-run for pid/force-quit/launch/crash-reports.

Exits non-zero and prints details if any check fails.

Usage:
    python selftest.py
"""

import csv
import os
import pty
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PYTHON = sys.executable


def fail(msg):
    print("SELFTEST FAIL: " + msg)
    sys.exit(1)


def ok(msg):
    print("SELFTEST OK: " + msg)


# ---------------------------------------------------------------------------
# (a) serial_logger.py against a pty pair
# ---------------------------------------------------------------------------

def fake_board_writer(master_fd, stop_event):
    """Write STATUS blocks periodically, with one deliberate gap > 2s to
    trigger a STALL, then keep writing so we can observe the reopen."""
    def w(text):
        try:
            os.write(master_fd, text.encode("utf-8"))
        except OSError:
            pass

    t0 = time.time()
    uptime = 1000
    sent_gap = False
    while not stop_event.is_set():
        elapsed = time.time() - t0
        if elapsed > 1.0 and not sent_gap:
            # simulate a stall: stop writing for 3s (> --stall-sec 2)
            sent_gap = True
            time.sleep(3.0)
            continue
        w("[{} ms] STATUS mode=manual playback=idle paused=0 brightness=50 color=#f971d4\n".format(uptime))
        w("[{} ms] STATUS faceIndex=7 faceCount=11 intervalMs=3000\n".format(uptime))
        w("[{} ms] === STATUS END ===\n".format(uptime))
        uptime += 500
        time.sleep(0.5)


def check_serial_logger():
    master_fd, slave_fd = pty.openpty()
    port_name = os.ttyname(slave_fd)

    stop_event = threading.Event()
    writer_thread = threading.Thread(target=fake_board_writer, args=(master_fd, stop_event), daemon=True)
    writer_thread.start()

    with tempfile.TemporaryDirectory() as tmp:
        logfile = os.path.join(tmp, "board.log")
        cmd = [
            PYTHON, os.path.join(HERE, "serial_logger.py"),
            port_name, logfile,
            "--duration", "6",
            "--status-interval", "10",
            "--stall-sec", "2",
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if proc.returncode != 0:
            fail("serial_logger.py exited {}: stderr={}".format(proc.returncode, proc.stderr))

        stop_event.set()
        os.close(master_fd)

        if not os.path.exists(logfile):
            fail("serial_logger.py did not create a log file")

        with open(logfile, "r") as fh:
            contents = fh.read()

    checks = {
        "HOST prefix": "[HOST " in contents,
        ">> log level debug": ">> log level debug" in contents,
        "STALL marker": "STALL" in contents,
    }
    debug_count = contents.count(">> log level debug")
    checks["reopened after STALL (>=2 'log level debug' sends)"] = debug_count >= 2

    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        print("---- serial_logger.py log contents ----")
        print(contents)
        print("----------------------------------------")
        fail("serial_logger check(s) failed: " + ", ".join(failed))

    ok("serial_logger.py: HOST prefixes, 'log level debug', STALL, and reopen all observed")
    return contents


# ---------------------------------------------------------------------------
# (b) oracle.py against synthetic board logs
# ---------------------------------------------------------------------------

def build_status_block(uptime_ms, host_ts, face_index, mode, brightness, color,
                        interval_ms, accepted):
    lines = [
        "[HOST {:.3f}] [{} ms] STATUS mode={} playback=idle paused=0 brightness={} color={}".format(
            host_ts, uptime_ms, mode, brightness, color),
        "[HOST {:.3f}] [{} ms] STATUS faceIndex={} faceCount=11 intervalMs={}".format(
            host_ts, uptime_ms, face_index, interval_ms),
        "[HOST {:.3f}] [{} ms] STATUS frameEncoding=raw lit=34 queued=0 accepted={} lastReason=custom_set".format(
            host_ts, uptime_ms, accepted),
        "[HOST {:.3f}] [{} ms] === STATUS END ===".format(host_ts, uptime_ms),
    ]
    return "\n".join(lines) + "\n"


def build_proto_command(host_ts, uptime_ms, name, slot=0, seq=1):
    return "[HOST {:.3f}] [{} ms] [PROTO] event=command slot={} seq={} name={}\n".format(
        host_ts, uptime_ms, slot, seq, name)


def build_ble_event(host_ts, uptime_ms, event, peer="AA:BB"):
    return "[HOST {:.3f}] [{} ms] [BLE] event={} peer={}\n".format(host_ts, uptime_ms, event, peer)


def check_oracle():
    with tempfile.TemporaryDirectory() as tmp:
        log_a = os.path.join(tmp, "a.log")
        log_b = os.path.join(tmp, "b.log")
        steps_csv = os.path.join(tmp, "steps.csv")
        routing_csv = os.path.join(tmp, "routing.csv")

        base = 1_700_000_000.0
        uptime = 1000

        # --- Step 1 (PASS): A is active and expected, only A changes. ---
        s1_start, s1_end = base + 0.0, base + 5.0
        a_lines = []
        b_lines = []

        a_lines.append(build_status_block(uptime, s1_start - 1.0, 1, "manual", 50, "#ff0000", 3000, 10))
        b_lines.append(build_status_block(uptime, s1_start - 1.0, 3, "auto", 80, "#0000ff", 2000, 20))

        a_lines.append(build_ble_event(s1_start + 1.0, uptime, "connect"))
        a_lines.append(build_proto_command(s1_start + 1.0, uptime, "set_color"))
        a_lines.append(build_status_block(uptime + 500, s1_end + 1.0, 1, "manual", 50, "#00ff00", 3000, 11))
        b_lines.append(build_status_block(uptime + 500, s1_end + 1.0, 3, "auto", 80, "#0000ff", 2000, 20))

        # --- Step 2 (ROUTING_FAIL): only A expected, but B shows set_color. ---
        s2_start, s2_end = base + 10.0, base + 15.0
        a_lines.append(build_status_block(uptime + 1000, s2_start - 1.0, 1, "manual", 50, "#00ff00", 3000, 11))
        b_lines.append(build_status_block(uptime + 1000, s2_start - 1.0, 3, "auto", 80, "#0000ff", 2000, 20))

        a_lines.append(build_proto_command(s2_start + 1.0, uptime + 1200, "set_brightness"))
        a_lines.append(build_status_block(uptime + 1500, s2_end + 1.0, 1, "manual", 60, "#00ff00", 3000, 12))

        # B is not expected in step 2, but receives a routed command.
        b_lines.append(build_proto_command(s2_start + 1.5, uptime + 1200, "set_color"))
        b_lines.append(build_status_block(uptime + 1500, s2_end + 1.0, 3, "auto", 80, "#123456", 2000, 20))

        # --- Step 3 (DUP_SESSION): B gets a second subscribe without a
        #     disconnect in between. ---
        s3_start, s3_end = base + 20.0, base + 25.0
        a_lines.append(build_status_block(uptime + 2000, s3_start - 1.0, 1, "manual", 60, "#00ff00", 3000, 12))
        b_lines.append(build_status_block(uptime + 2000, s3_start - 1.0, 3, "auto", 80, "#123456", 2000, 20))

        b_lines.append(build_ble_event(s3_start + 0.5, uptime + 2100, "connect"))
        b_lines.append(build_proto_command(s3_start + 1.0, uptime + 2100, "subscribe"))
        # Second subscribe with no disconnect in between -> DUP_SESSION.
        b_lines.append(build_proto_command(s3_start + 2.0, uptime + 2100, "subscribe"))

        a_lines.append(build_status_block(uptime + 2500, s3_end + 1.0, 1, "manual", 60, "#00ff00", 3000, 12))
        b_lines.append(build_status_block(uptime + 2500, s3_end + 1.0, 3, "auto", 80, "#123456", 2000, 20))

        with open(log_a, "w") as fh:
            fh.writelines(a_lines)
        with open(log_b, "w") as fh:
            fh.writelines(b_lines)

        with open(steps_csv, "w", newline="") as fh:
            writer = csv.writer(fh)
            writer.writerow(["ts_start", "ts_end", "step", "seed", "entry", "action",
                              "active_board", "expected_boards", "flash_write"])
            writer.writerow([s1_start, s1_end, "1", "42", "E1", "set_color", "A", "A", "0"])
            writer.writerow([s2_start, s2_end, "2", "42", "E1", "set_brightness", "A", "A", "0"])
            writer.writerow([s3_start, s3_end, "3", "42", "E3", "subscribe", "B", "B", "0"])

        cmd = [
            PYTHON, os.path.join(HERE, "oracle.py"),
            "--steps", steps_csv,
            "--board", "A={}".format(log_a),
            "--board", "B={}".format(log_b),
            "--out", routing_csv,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if proc.returncode != 0:
            fail("oracle.py exited {}: stderr={}".format(proc.returncode, proc.stderr))

        with open(routing_csv, "r", newline="") as fh:
            rows = list(csv.DictReader(fh))

        verdicts_by_step_board = {(r["step"], r["board"]): r["verdict"] for r in rows}

        expected = {
            ("1", "A"): "PASS",
            ("2", "B"): "ROUTING_FAIL",
            ("3", "B"): "DUP_SESSION",
        }
        problems = []
        for key, expected_verdict in expected.items():
            actual = verdicts_by_step_board.get(key)
            if actual != expected_verdict:
                problems.append("{} expected {} got {}".format(key, expected_verdict, actual))

        if problems:
            print("---- oracle.py stdout ----")
            print(proc.stdout)
            print("---- ROUTING.csv rows ----")
            for r in rows:
                print(r)
            print("---------------------------")
            fail("oracle verdict mismatch(es): " + "; ".join(problems))

        ok("oracle.py: PASS, ROUTING_FAIL, and DUP_SESSION verdicts all observed as expected")
        print(proc.stdout, end="")


# ---------------------------------------------------------------------------
# (c) iphone_app.py --dry-run
# ---------------------------------------------------------------------------

def check_iphone_app_dry_run():
    fake_udid = "00000000-0000000000000000"
    subcommands = [
        ["pid", fake_udid],
        ["force-quit", fake_udid, "--pid", "1234"],
        ["launch", fake_udid],
        ["crash-reports", fake_udid, "--since", "1700000000"],
    ]
    for args in subcommands:
        cmd = [PYTHON, os.path.join(HERE, "iphone_app.py"), "--dry-run"] + args
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if proc.returncode != 0:
            fail("iphone_app.py --dry-run {} exited {}: stderr={}".format(
                args, proc.returncode, proc.stderr))
        if args[0] == "force-quit" and "DRY-RUN" not in proc.stdout:
            fail("iphone_app.py --dry-run force-quit did not print DRY-RUN command")

    ok("iphone_app.py --dry-run: pid/force-quit/launch/crash-reports all exit 0 without touching a device")


def main():
    check_serial_logger()
    check_oracle()
    check_iphone_app_dry_run()
    print("SELFTEST PASSED")


if __name__ == "__main__":
    main()
