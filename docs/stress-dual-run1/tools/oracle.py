#!/usr/bin/env python
"""oracle.py — merge per-board serial logs against a step CSV and judge
command routing / session uniqueness (INV-1, INV-2) for the dual-board
stress plan (docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md sections 3.2 and 4.3).

STEPS.csv columns:
    ts_start, ts_end, step, seed, entry, action, active_board,
    expected_boards, flash_write

  - ts_start / ts_end: epoch seconds bracketing the step.
  - expected_boards: ';'-separated board labels expected to react, or
    'none'.

For each step window, for every board given via --board LABEL=LOGFILE this
tool reports: command names seen (PROTO event=command), the accepted delta,
faceIndex/mode/brightness/color/intervalMs before/after (from the nearest
STATUS record before ts_start and after ts_end), and connect/disconnect/
subscribe counts. It then assigns one verdict per (step, board):

  ROUTING_FAIL  - a board NOT in expected_boards shows commands (other than
                  'status'/'log level', which are host housekeeping, and
                  ignoring periodic/automatic events) or a state/accepted
                  change.
  DUP_SESSION   - the board receives a 'subscribe' while it already has an
                  active (connected, subscribed) client with no intervening
                  disconnect.
  UNKNOWN       - no STATUS bracket (before AND after record) available for
                  that board for this step.
  PASS          - none of the above.

Usage:
    python oracle.py --steps STEPS.csv --board A=board_a.log --board B=board_b.log --out ROUTING.csv
"""

import argparse
import csv
import sys
from collections import defaultdict

from board_status import parse_log_file
from events import iter_events

STATE_FIELDS = ["faceIndex", "mode", "brightness", "color", "intervalMs"]

# Command names that are host housekeeping, not routed UI actions, and are
# ignored when deciding ROUTING_FAIL.
IGNORED_COMMAND_NAMES = {"status", "log", "log_level", "loglevel"}


def parse_board_arg(value):
    if "=" not in value:
        raise argparse.ArgumentTypeError("expected LABEL=LOGFILE, got: {}".format(value))
    label, path = value.split("=", 1)
    return label, path


def load_steps(path):
    with open(path, "r", newline="") as fh:
        reader = csv.DictReader(fh)
        steps = []
        for row in reader:
            row["ts_start"] = float(row["ts_start"])
            row["ts_end"] = float(row["ts_end"])
            expected = row.get("expected_boards", "none") or "none"
            if expected.strip().lower() == "none":
                row["expected_boards_set"] = set()
            else:
                row["expected_boards_set"] = {b.strip() for b in expected.split(";") if b.strip()}
            steps.append(row)
        return steps


def load_board_data(logfile):
    """Return (status_records, all_events) for one board's log."""
    status_records = parse_log_file(logfile)
    with open(logfile, "r", errors="replace") as fh:
        all_events = list(iter_events(fh))
    return status_records, all_events


def nearest_status_before(status_records, ts):
    candidate = None
    for rec in status_records:
        if rec["host_ts"] is None:
            continue
        if rec["host_ts"] <= ts:
            if candidate is None or rec["host_ts"] > candidate["host_ts"]:
                candidate = rec
    return candidate


def nearest_status_after(status_records, ts):
    candidate = None
    for rec in status_records:
        if rec["host_ts"] is None:
            continue
        if rec["host_ts"] >= ts:
            if candidate is None or rec["host_ts"] < candidate["host_ts"]:
                candidate = rec
    return candidate


def command_names_in_window(events, ts_start, ts_end):
    names = []
    for ev in events:
        if ev["category"] != "PROTO" or ev["event"] != "command":
            continue
        ts = ev["ts"]
        if ts == "":
            continue
        ts = float(ts)
        if ts_start <= ts <= ts_end:
            name = None
            for kv in ev["fields"].split(";"):
                if kv.startswith("name="):
                    name = kv.split("=", 1)[1]
                    break
            if name is not None:
                names.append(name)
    return names


def routable_commands(names):
    return [n for n in names if n.strip().lower() not in IGNORED_COMMAND_NAMES]


def connect_disconnect_subscribe_counts(events, ts_start, ts_end):
    connects = disconnects = subscribes = 0
    for ev in events:
        ts = ev["ts"]
        if ts == "":
            continue
        ts = float(ts)
        if not (ts_start <= ts <= ts_end):
            continue
        if ev["category"] == "BLE" and ev["event"] == "connect":
            connects += 1
        elif ev["category"] == "BLE" and ev["event"] == "disconnect":
            disconnects += 1
        elif ev["category"] == "PROTO" and ev["event"] == "command":
            for kv in ev["fields"].split(";"):
                if kv == "name=subscribe":
                    subscribes += 1
    return connects, disconnects, subscribes


def find_duplicate_subscribe_timestamps(events):
    """Return a set of timestamps (floats) of 'subscribe' commands issued
    while a client was already active+subscribed with no intervening
    disconnect (DUP_SESSION signal)."""
    timeline = []
    for ev in events:
        ts = ev["ts"]
        if ts == "":
            continue
        ts = float(ts)
        if ev["category"] == "BLE" and ev["event"] == "disconnect":
            timeline.append((ts, "disconnect"))
        elif ev["category"] == "PROTO" and ev["event"] == "command":
            for kv in ev["fields"].split(";"):
                if kv == "name=subscribe":
                    timeline.append((ts, "subscribe"))
    timeline.sort(key=lambda item: item[0])

    duplicates = set()
    active_subscribed = False
    for ts, kind in timeline:
        if kind == "disconnect":
            active_subscribed = False
        elif kind == "subscribe":
            if active_subscribed:
                duplicates.add(ts)
            else:
                active_subscribed = True
    return duplicates


def state_changes(before, after):
    """Return dict field -> (before_val, after_val) for fields that differ,
    given two STATUS record dicts (or None)."""
    changes = {}
    for field in STATE_FIELDS:
        bval = before["fields"].get(field) if before else None
        aval = after["fields"].get(field) if after else None
        if bval != aval:
            changes[field] = (bval, aval)
    return changes


def accepted_delta(before, after):
    if before is None or after is None:
        return None
    try:
        bval = int(before["fields"].get("accepted", 0))
        aval = int(after["fields"].get("accepted", 0))
    except (TypeError, ValueError):
        return None
    return aval - bval


def evaluate(steps, boards):
    """boards: dict label -> (status_records, events, dup_subscribe_ts_set)."""
    rows = []
    summary = defaultdict(int)

    for step in steps:
        ts_start = step["ts_start"]
        ts_end = step["ts_end"]
        expected = step["expected_boards_set"]

        for label, (status_records, events, dup_ts) in boards.items():
            before = nearest_status_before(status_records, ts_start)
            after = nearest_status_after(status_records, ts_end)

            names = command_names_in_window(events, ts_start, ts_end)
            routable = routable_commands(names)
            changes = state_changes(before, after)
            delta = accepted_delta(before, after)
            connects, disconnects, subscribes = connect_disconnect_subscribe_counts(
                events, ts_start, ts_end
            )

            window_dup = any(ts_start <= ts <= ts_end for ts in dup_ts)

            is_expected = label in expected
            has_activity = bool(routable) or bool(changes) or (delta not in (None, 0))

            if window_dup:
                verdict = "DUP_SESSION"
            elif (not is_expected) and has_activity:
                verdict = "ROUTING_FAIL"
            elif before is None or after is None:
                verdict = "UNKNOWN"
            else:
                verdict = "PASS"

            summary[verdict] += 1

            rows.append({
                "step": step.get("step"),
                "entry": step.get("entry"),
                "action": step.get("action"),
                "active_board": step.get("active_board"),
                "expected_boards": step.get("expected_boards"),
                "board": label,
                "commands": ";".join(names),
                "accepted_delta": "" if delta is None else delta,
                "faceIndex_before": before["fields"].get("faceIndex") if before else "",
                "faceIndex_after": after["fields"].get("faceIndex") if after else "",
                "mode_before": before["fields"].get("mode") if before else "",
                "mode_after": after["fields"].get("mode") if after else "",
                "brightness_before": before["fields"].get("brightness") if before else "",
                "brightness_after": after["fields"].get("brightness") if after else "",
                "color_before": before["fields"].get("color") if before else "",
                "color_after": after["fields"].get("color") if after else "",
                "intervalMs_before": before["fields"].get("intervalMs") if before else "",
                "intervalMs_after": after["fields"].get("intervalMs") if after else "",
                "connects": connects,
                "disconnects": disconnects,
                "subscribes": subscribes,
                "verdict": verdict,
            })

    return rows, summary


FIELDNAMES = [
    "step", "entry", "action", "active_board", "expected_boards", "board",
    "commands", "accepted_delta",
    "faceIndex_before", "faceIndex_after",
    "mode_before", "mode_after",
    "brightness_before", "brightness_after",
    "color_before", "color_after",
    "intervalMs_before", "intervalMs_after",
    "connects", "disconnects", "subscribes",
    "verdict",
]


def main():
    parser = argparse.ArgumentParser(
        description="Judge command routing (INV-1) and session uniqueness (INV-2) "
                    "across per-board serial logs and a step CSV."
    )
    parser.add_argument("--steps", required=True, help="Path to STEPS.csv")
    parser.add_argument(
        "--board", action="append", required=True, type=parse_board_arg,
        metavar="LABEL=LOGFILE",
        help="A board label and its serial_logger.py log path; repeat per board",
    )
    parser.add_argument("--out", required=True, help="Path to write ROUTING.csv")
    args = parser.parse_args()

    steps = load_steps(args.steps)

    boards = {}
    for label, path in args.board:
        status_records, events = load_board_data(path)
        dup_ts = find_duplicate_subscribe_timestamps(events)
        boards[label] = (status_records, events, dup_ts)

    rows, summary = evaluate(steps, boards)

    with open(args.out, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDNAMES)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)

    total = sum(summary.values())
    print("oracle: {} rows written to {}".format(total, args.out))
    for verdict in ("PASS", "ROUTING_FAIL", "DUP_SESSION", "UNKNOWN"):
        print("  {}: {}".format(verdict, summary.get(verdict, 0)))


if __name__ == "__main__":
    main()
