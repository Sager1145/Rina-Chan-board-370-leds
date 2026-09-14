#!/usr/bin/env python
"""events.py — list BLE/PROTO/port/reboot events from a serial_logger.py log
within a time window, as CSV.

Recognized event lines (host/uptime prefixes stripped before matching):
  [BLE] event=connect|disconnect ... peer=..
  [PROTO] event=client_connect|client_disconnect
  [PROTO] event=command slot=N seq=N name=X
  startup_sequence_complete                (reboot marker)
  PORT_GONE / PORT_BACK / STALL            (serial_logger.py resilience markers)

Output CSV columns: ts,category,event,fields,raw
  - ts: host epoch seconds (float), or empty if the line had no HOST prefix
  - category: BLE | PROTO | PORT | REBOOT
  - event: e.g. connect, disconnect, client_connect, command, PORT_GONE,
    PORT_BACK, STALL, startup_sequence_complete
  - fields: semicolon-separated key=value pairs found on the line (excluding
    "event=...")
  - raw: the original line, stripped of the HOST/uptime prefixes

Usage:
    python events.py board_a.log --from 1700000000 --to 1700000600
"""

import argparse
import csv
import re
import sys

from board_status import _strip_prefixes, KV_RE, STARTUP_RE

BLE_RE = re.compile(r"^\[BLE\]\s*(.*)$")
PROTO_RE = re.compile(r"^\[PROTO\]\s*(.*)$")
PORT_MARKER_RE = re.compile(r"^(PORT_GONE|PORT_BACK|STALL)\b")


def _fields_except_event(text):
    pairs = KV_RE.findall(text)
    return [(k, v) for k, v in pairs if k != "event"]


def iter_events(lines, ts_from=None, ts_to=None):
    for raw in lines:
        raw = raw.rstrip("\n")
        host_ts, _uptime_ms, rest = _strip_prefixes(raw)
        stripped = rest.strip()

        if ts_from is not None and host_ts is not None and host_ts < ts_from:
            continue
        if ts_to is not None and host_ts is not None and host_ts > ts_to:
            continue

        category = None
        event = None
        fields = []

        m = BLE_RE.match(stripped)
        if m:
            body = m.group(1)
            category = "BLE"
            em = re.search(r"event=(\S+)", body)
            event = em.group(1) if em else ""
            fields = _fields_except_event(body)
        else:
            m = PROTO_RE.match(stripped)
            if m:
                body = m.group(1)
                category = "PROTO"
                em = re.search(r"event=(\S+)", body)
                event = em.group(1) if em else ""
                fields = _fields_except_event(body)
            elif PORT_MARKER_RE.match(stripped):
                category = "PORT"
                event = PORT_MARKER_RE.match(stripped).group(1)
            elif STARTUP_RE.search(stripped):
                category = "REBOOT"
                event = "startup_sequence_complete"

        if category is None:
            continue

        yield {
            "ts": "" if host_ts is None else "{:.3f}".format(host_ts),
            "category": category,
            "event": event,
            "fields": ";".join("{}={}".format(k, v) for k, v in fields),
            "raw": stripped,
        }


def main():
    parser = argparse.ArgumentParser(
        description="List BLE/PROTO/port/reboot events from a serial_logger.py log as CSV."
    )
    parser.add_argument("logfile", help="Path to the serial_logger.py log file")
    parser.add_argument(
        "--from", dest="ts_from", type=float, default=None,
        help="Only include events at or after this epoch timestamp",
    )
    parser.add_argument(
        "--to", dest="ts_to", type=float, default=None,
        help="Only include events at or before this epoch timestamp",
    )
    parser.add_argument(
        "--out", default=None,
        help="Write CSV to this path instead of stdout",
    )
    args = parser.parse_args()

    with open(args.logfile, "r", errors="replace") as fh:
        rows = list(iter_events(fh, ts_from=args.ts_from, ts_to=args.ts_to))

    out_fh = open(args.out, "w", newline="") if args.out else sys.stdout
    try:
        writer = csv.DictWriter(out_fh, fieldnames=["ts", "category", "event", "fields", "raw"])
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    finally:
        if args.out:
            out_fh.close()


if __name__ == "__main__":
    main()
