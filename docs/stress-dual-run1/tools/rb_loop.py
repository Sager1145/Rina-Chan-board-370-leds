#!/usr/bin/env python3
"""DB-RB host-driven board reboot loop (plan section 4.9, method B2).

Each cycle picks a board (seeded), asks its running serial_logger to pulse a
hardware reset (`__reset__` appended to `<log>.cmd`), then watches all board
logs for `--settle` seconds.

Per cycle it records, for the reset board: whether a reboot was observed
(uptime drop or `startup_sequence_complete`), whether the phone was connected
to it before the reset, and when it reconnected; for every other board:
disconnects/subscribes in the window (must stay 0 for an undisturbed board).

Verdict per cycle:
  NO_REBOOT             reset board showed no reboot marker
  OTHER_BOARD_DISTURBED a board that was not reset disconnected
  DUP_SESSION           a board got more subscribes than connects
  NO_RECONNECT          the phone was connected before but did not reconnect
  APP_DEAD              RinaBoard has no pid at the end
  PASS                  otherwise
"""
import argparse
import csv
import json
import os
import random
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
HOST_RE = re.compile(r"^\[HOST (\d+\.\d+)\] (.*)$")
UPTIME_RE = re.compile(r"\[(\d+) ms\]")


def app_pid(udid):
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer")
    out = subprocess.run(["xcrun", "devicectl", "device", "info", "processes", "--device", udid],
                         capture_output=True, text=True, env=env)
    for line in out.stdout.splitlines():
        if "RinaBoard.app/RinaBoard" in line:
            match = re.match(r"\s*(\d+)\s", line)
            if match:
                return int(match.group(1))
    return None


def read_lines(logfile, start=None, end=None):
    with open(logfile, "rb") as handle:
        for raw in handle:
            match = HOST_RE.match(raw.decode("utf-8", "replace").rstrip("\n"))
            if not match:
                continue
            ts = float(match.group(1))
            if (start is None or ts >= start) and (end is None or ts <= end):
                yield ts, match.group(2)


def phone_connected(logfile, before):
    """Last BLE connect/disconnect before `before` decides the link state."""
    state = False
    for ts, line in read_lines(logfile, end=before):
        if "[BLE] event=connect" in line:
            state = True
        elif "[BLE] event=disconnect" in line:
            state = False
    return state


def window(logfile, start, end):
    result = {"disconnect": 0, "connect": 0, "subscribe": 0, "reboot_ts": None,
              "first_connect_after_reboot": None, "port_gone": 0}
    last_uptime = None
    for ts, line in read_lines(logfile, start, end):
        # Host commands and STATUS blocks (lastReason=startup_sequence_complete_*)
        # are not boot output.
        if line.startswith(">>") or line.startswith("STATUS") or line.startswith("==="):
            continue
        uptime = UPTIME_RE.search(line)
        if uptime:
            value = int(uptime.group(1))
            if last_uptime is not None and value + 1000 < last_uptime and result["reboot_ts"] is None:
                result["reboot_ts"] = ts
            last_uptime = value
        if "startup_sequence_complete" in line and result["reboot_ts"] is None:
            result["reboot_ts"] = ts
        if "PORT_GONE" in line:
            result["port_gone"] += 1
        if "[BLE] event=disconnect" in line:
            result["disconnect"] += 1
        elif "[BLE] event=connect" in line:
            result["connect"] += 1
            if result["reboot_ts"] and result["first_connect_after_reboot"] is None:
                result["first_connect_after_reboot"] = ts
        elif "name=subscribe" in line:
            result["subscribe"] += 1
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--board", action="append", required=True, metavar="LABEL=LOGFILE")
    parser.add_argument("--cycles", type=int, default=6)
    parser.add_argument("--settle", type=float, default=60.0)
    parser.add_argument("--only", help="reset only this board label")
    parser.add_argument("--seed", type=int, default=20260913)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    boards = dict(item.split("=", 1) for item in args.board)
    rng = random.Random(args.seed)
    new_file = not os.path.exists(args.out)
    with open(args.out, "a", newline="") as handle:
        writer = csv.writer(handle)
        if new_file:
            writer.writerow(["cycle", "seed", "method", "reset_board", "t_reset",
                             "connected_before_json", "per_board_json", "reboot_ms",
                             "reconnect_ms", "pid_after", "verdict"])
        for cycle in range(1, args.cycles + 1):
            target = args.only or rng.choice(sorted(boards))
            t_reset = time.time()
            before = {label: phone_connected(path, t_reset) for label, path in boards.items()}
            with open(boards[target] + ".cmd", "a") as cmd:
                cmd.write("__reset__\n")
            time.sleep(args.settle)
            t_end = time.time()
            per_board = {label: window(path, t_reset - 0.5, t_end)
                         for label, path in boards.items()}
            reset = per_board[target]
            pid_after = app_pid(args.udid)
            reboot_ms = round((reset["reboot_ts"] - t_reset) * 1000) if reset["reboot_ts"] else None
            reconnect = reset["first_connect_after_reboot"]
            reconnect_ms = round((reconnect - t_reset) * 1000) if reconnect else None
            others_disturbed = [label for label, c in per_board.items()
                                if label != target and c["disconnect"] > 0]
            if reset["reboot_ts"] is None:
                verdict = "NO_REBOOT"
            elif others_disturbed:
                verdict = "OTHER_BOARD_DISTURBED"
            elif any(c["subscribe"] > c["connect"] for c in per_board.values()):
                verdict = "DUP_SESSION"
            elif before[target] and reconnect is None:
                verdict = "NO_RECONNECT"
            elif not pid_after:
                verdict = "APP_DEAD"
            else:
                verdict = "PASS"
            writer.writerow([cycle, args.seed, "B2", target, f"{t_reset:.3f}", json.dumps(before),
                             json.dumps(per_board), reboot_ms, reconnect_ms, pid_after, verdict])
            handle.flush()
            print(f"cycle {cycle}: reset {target} connected_before={before[target]} "
                  f"reboot_ms={reboot_ms} reconnect_ms={reconnect_ms} "
                  f"others_disturbed={others_disturbed} -> {verdict}", flush=True)


if __name__ == "__main__":
    main()
