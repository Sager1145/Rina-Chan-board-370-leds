#!/usr/bin/env python3
"""DB-FQ host-driven force-quit / relaunch loop (plan section 4.8, Q1).

Each cycle: force-quit RinaBoard on the iPhone (SIGKILL via devicectl), wait,
relaunch it, then watch every board's serial log for `--settle` seconds and
record per-board BLE disconnect/connect/subscribe events in that window.

Verdict per cycle:
  DUP_SESSION  a board got more subscribes than connects in the window
  NO_RECONNECT no board reconnected within the settle window
  APP_DEAD     the app has no pid at the end of the window
  PASS         otherwise

The app auto-connects only one board at launch (E4); connecting the rest needs
UI (R1), so a single reconnected board is the expected PASS here.
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


DEVELOPER_DIR = "/Applications/Xcode-beta.app/Contents/Developer"
BUNDLE = "com.rinachan.board"


def devicectl(*args):
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    out = subprocess.run(["xcrun", "devicectl", *args], capture_output=True, text=True, env=env)
    return out.returncode, (out.stdout + out.stderr).strip()


def app(*args):
    """Only used for crash-reports; pid/quit/launch go through devicectl directly
    because iphone_app.py's JSON pid lookup returned nothing on 2026-09-13."""
    out = subprocess.run([PY, os.path.join(HERE, "iphone_app.py"), *args],
                         capture_output=True, text=True)
    return out.returncode, (out.stdout + out.stderr).strip()


def app_pid(udid):
    _, text = devicectl("device", "info", "processes", "--device", udid)
    for line in text.splitlines():
        if "RinaBoard.app/RinaBoard" in line:
            match = re.match(r"\s*(\d+)\s", line)
            if match:
                return int(match.group(1))
    return None


def force_quit(udid, pid):
    return devicectl("device", "process", "terminate", "--device", udid, "--pid", str(pid), "--kill")


def launch(udid):
    return devicectl("device", "process", "launch", "--device", udid, BUNDLE)


def window_events(logfile, start, end):
    counts = {"disconnect": 0, "connect": 0, "subscribe": 0, "reboot": 0,
              "first_connect": None, "port_issue": 0}
    with open(logfile, "rb") as handle:
        for raw in handle:
            match = HOST_RE.match(raw.decode("utf-8", "replace").rstrip("\n"))
            if not match:
                continue
            ts, line = float(match.group(1)), match.group(2)
            if ts < start or ts > end:
                continue
            if "[BLE] event=disconnect" in line:
                counts["disconnect"] += 1
            elif "[BLE] event=connect" in line:
                counts["connect"] += 1
                if counts["first_connect"] is None:
                    counts["first_connect"] = ts
            elif "name=subscribe" in line:
                counts["subscribe"] += 1
            elif ("startup_sequence_complete" in line and ">>" not in line
                  and not line.startswith("STATUS")):
                counts["reboot"] += 1
            elif "PORT_GONE" in line or "STALL" in line:
                counts["port_issue"] += 1
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--board", action="append", required=True, metavar="LABEL=LOGFILE")
    parser.add_argument("--cycles", type=int, default=10)
    parser.add_argument("--settle", type=float, default=30.0)
    parser.add_argument("--min-gap", type=float, default=1.0)
    parser.add_argument("--max-gap", type=float, default=4.0)
    parser.add_argument("--seed", type=int, default=20260913)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    boards = dict(item.split("=", 1) for item in args.board)
    rng = random.Random(args.seed)
    new_file = not os.path.exists(args.out)
    started = time.time()
    with open(args.out, "a", newline="") as handle:
        writer = csv.writer(handle)
        if new_file:
            writer.writerow(["cycle", "seed", "t_quit", "t_launch", "pid_before", "pid_after",
                             "gap_s", "per_board_json", "reconnected_boards", "reconnect_ms",
                             "verdict"])
        for cycle in range(1, args.cycles + 1):
            pid_before = app_pid(args.udid)
            t_quit = time.time()
            if pid_before:
                force_quit(args.udid, pid_before)
            gap = rng.uniform(args.min_gap, args.max_gap)
            time.sleep(gap)
            t_launch = time.time()
            launch(args.udid)
            time.sleep(args.settle)
            t_end = time.time()
            per_board = {label: window_events(path, t_quit - 0.5, t_end)
                         for label, path in boards.items()}
            pid_after = app_pid(args.udid)
            reconnected = [label for label, c in per_board.items() if c["connect"] > 0]
            reconnect_ms = {label: round((c["first_connect"] - t_launch) * 1000)
                            for label, c in per_board.items() if c["first_connect"]}
            if any(c["subscribe"] > c["connect"] for c in per_board.values()):
                verdict = "DUP_SESSION"
            elif not pid_after:
                verdict = "APP_DEAD"
            elif not reconnected:
                verdict = "NO_RECONNECT"
            else:
                verdict = "PASS"
            writer.writerow([cycle, args.seed, f"{t_quit:.3f}", f"{t_launch:.3f}", pid_before,
                             pid_after, f"{gap:.2f}", json.dumps(per_board),
                             ";".join(reconnected), json.dumps(reconnect_ms), verdict])
            handle.flush()
            print(f"cycle {cycle}: {verdict} reconnected={reconnected} ms={reconnect_ms}",
                  flush=True)
    code, text = app("crash-reports", args.udid, "--since", str(int(started)))
    print("crash-reports:", text if text else "(none)")


if __name__ == "__main__":
    main()
