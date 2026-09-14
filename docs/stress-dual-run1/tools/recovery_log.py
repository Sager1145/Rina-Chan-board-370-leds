#!/usr/bin/env python
"""recovery_log.py — append one row per force-quit/reboot recovery event to
RECOVERY.csv (docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md section 6, item 4a).

Columns (per the plan):
    ts                  - epoch seconds when the disturbance was injected
    method              - Q1|Q2|Q3 (force-quit) or B1|B2|B3 (board reboot)
    board_states_json   - JSON: per-board state and playback source at
                           injection time, e.g.
                           {"A": {"state": "active", "source": "scroll"},
                            "B": {"state": "online", "source": "idle"}}
    reconnect_ms_json    - JSON: per-board reconnect duration in ms, e.g.
                           {"A": 4200, "B": 1800}
    r1_ms               - milliseconds for the R1 "connect all discovered" pass
    r3_ms                - milliseconds for the R3 "switch active to an
                           online board" pass (empty if not applicable)
    inv8_result          - PASS|FAIL|UNKNOWN for INV-8
    crash_report          - yes|no

Creates the file with a header row if it does not already exist.

Usage:
    python recovery_log.py RECOVERY.csv \\
        --method Q1 \\
        --board-states '{"A": {"state": "active", "source": "scroll"}, "B": {"state": "online", "source": "idle"}}' \\
        --reconnect-ms '{"A": 4200, "B": 1800}' \\
        --r1-ms 5100 --r3-ms 1200 \\
        --inv8-result PASS --crash-report no
"""

import argparse
import csv
import json
import os
import time

FIELDNAMES = [
    "ts", "method", "board_states_json", "reconnect_ms_json",
    "r1_ms", "r3_ms", "inv8_result", "crash_report",
]

VALID_METHODS = {"Q1", "Q2", "Q3", "B1", "B2", "B3"}
VALID_INV8 = {"PASS", "FAIL", "UNKNOWN"}
VALID_CRASH = {"yes", "no"}


def append_row(csv_path, ts, method, board_states, reconnect_ms, r1_ms, r3_ms,
                inv8_result, crash_report):
    is_new = not os.path.exists(csv_path)
    with open(csv_path, "a", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDNAMES)
        if is_new:
            writer.writeheader()
        writer.writerow({
            "ts": "{:.3f}".format(ts),
            "method": method,
            "board_states_json": json.dumps(board_states, sort_keys=True),
            "reconnect_ms_json": json.dumps(reconnect_ms, sort_keys=True),
            "r1_ms": "" if r1_ms is None else r1_ms,
            "r3_ms": "" if r3_ms is None else r3_ms,
            "inv8_result": inv8_result,
            "crash_report": crash_report,
        })


def _json_arg(value):
    return json.loads(value)


def main():
    parser = argparse.ArgumentParser(
        description="Append one recovery event row to RECOVERY.csv."
    )
    parser.add_argument("csv_path", help="Path to RECOVERY.csv (created if missing)")
    parser.add_argument("--ts", type=float, default=None,
                         help="Injection epoch timestamp (default: now)")
    parser.add_argument("--method", required=True, choices=sorted(VALID_METHODS),
                         help="Disturbance method: Q1-Q3 (force-quit) or B1-B3 (board reboot)")
    parser.add_argument("--board-states", required=True, type=_json_arg,
                         help="JSON object: per-board {state, source} at injection time")
    parser.add_argument("--reconnect-ms", required=True, type=_json_arg,
                         help="JSON object: per-board reconnect duration in ms")
    parser.add_argument("--r1-ms", type=float, default=None,
                         help="Duration of the R1 connect-all pass, in ms")
    parser.add_argument("--r3-ms", type=float, default=None,
                         help="Duration of the R3 active-switch pass, in ms (if applicable)")
    parser.add_argument("--inv8-result", required=True, choices=sorted(VALID_INV8))
    parser.add_argument("--crash-report", required=True, choices=sorted(VALID_CRASH))
    args = parser.parse_args()

    ts = args.ts if args.ts is not None else time.time()

    append_row(
        args.csv_path, ts, args.method, args.board_states, args.reconnect_ms,
        args.r1_ms, args.r3_ms, args.inv8_result, args.crash_report,
    )


if __name__ == "__main__":
    main()
