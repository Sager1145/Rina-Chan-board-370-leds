#!/usr/bin/env python
"""board_status.py — parse board `status` blocks out of a serial_logger.py log.

A firmware STATUS block looks like (each line additionally carries the host
timestamp prefix added by serial_logger.py and the firmware's own uptime
prefix, e.g. ``[HOST 1700000000.123] [1672635 ms] STATUS mode=manual ...``):

    STATUS mode=manual playback=idle paused=0 brightness=50 color=#f971d4
    STATUS faceIndex=7 faceCount=11 intervalMs=3000
    STATUS frameEncoding=... lit=34 queued=0 accepted=1 lastReason=...
    STATUS boardId=80B54EF48E09 apSsid=... hostname=...
    STATUS heapFree=90836 largestBlock=...
    === STATUS END ===

All ``key=value`` pairs across the consecutive ``STATUS ...`` lines preceding
a ``=== STATUS END ===`` marker are merged into one record. The firmware
uptime (``[<n> ms]``) found on the block's lines is attached as ``uptime_ms``,
and the host epoch timestamp of the terminating ``STATUS END`` line is
attached as ``host_ts``. A record is flagged as a reboot boundary
(``reboot: true``) if its uptime is lower than the previous record's uptime,
or if a ``startup_sequence_complete`` line was observed since the previous
record.

Usage:
    python board_status.py board_a.log
    python board_status.py board_a.log --since 1700000000
"""

import argparse
import json
import os
import re
import sys
import time

HOST_RE = re.compile(r"^\[HOST\s+(?P<ts>[0-9.]+)\]\s?(?P<rest>.*)$")
UPTIME_RE = re.compile(r"^\[(?P<uptime>\d+)\s*ms\]\s?(?P<rest>.*)$")
KV_RE = re.compile(r"(\w+)=(\S*)")
STATUS_END_RE = re.compile(r"===\s*STATUS END\s*===")
STARTUP_RE = re.compile(r"startup_sequence_complete")


def _strip_prefixes(raw_line):
    """Return (host_ts_or_None, uptime_ms_or_None, remainder_text)."""
    host_ts = None
    m = HOST_RE.match(raw_line)
    rest = raw_line
    if m:
        host_ts = float(m.group("ts"))
        rest = m.group("rest")
    uptime_ms = None
    m2 = UPTIME_RE.match(rest)
    if m2:
        uptime_ms = int(m2.group("uptime"))
        rest = m2.group("rest")
    return host_ts, uptime_ms, rest


def parse_records(lines, since=None):
    """Parse an iterable of raw log lines into a list of STATUS records.

    Each record is a dict: {fields: {...}, host_ts, uptime_ms, reboot}.
    ``since`` (epoch seconds) filters out records whose host_ts is earlier.
    """
    records = []
    fields = {}
    block_uptime = None
    saw_status_line = False
    pending_reboot_marker = False
    prev_uptime = None

    for raw in lines:
        raw = raw.rstrip("\n")
        host_ts, uptime_ms, rest = _strip_prefixes(raw)

        if STARTUP_RE.search(rest):
            pending_reboot_marker = True

        if uptime_ms is not None:
            block_uptime = uptime_ms

        stripped = rest.strip()
        if stripped.startswith("STATUS ") or stripped == "STATUS":
            saw_status_line = True
            for key, value in KV_RE.findall(stripped):
                fields[key] = value
            continue

        if STATUS_END_RE.search(stripped):
            if saw_status_line:
                reboot = pending_reboot_marker
                if prev_uptime is not None and block_uptime is not None and block_uptime < prev_uptime:
                    reboot = True
                record = {
                    "fields": fields,
                    "host_ts": host_ts,
                    "uptime_ms": block_uptime,
                    "reboot": reboot,
                }
                if since is None or (host_ts is not None and host_ts >= since):
                    records.append(record)
                if block_uptime is not None:
                    prev_uptime = block_uptime
            fields = {}
            block_uptime = None
            saw_status_line = False
            pending_reboot_marker = False

    return records


def parse_log_file(logfile, since=None):
    with open(logfile, "r", errors="replace") as fh:
        return parse_records(fh, since=since)


def latest_record(logfile):
    records = parse_log_file(logfile)
    return records[-1] if records else None


def request_status(logfile, timeout=5.0, poll_interval=0.1):
    """Append 'status' to <logfile>.cmd and wait for a newer STATUS END.

    Returns the new record dict, or None on timeout.
    """
    cmd_path = logfile + ".cmd"
    before = latest_record(logfile)
    before_ts = before["host_ts"] if before else None

    with open(cmd_path, "a") as fh:
        fh.write("status\n")

    deadline = time.time() + timeout
    while time.time() < deadline:
        after = latest_record(logfile)
        if after is not None:
            after_ts = after["host_ts"]
            if before_ts is None or (after_ts is not None and after_ts > before_ts):
                return after
        time.sleep(poll_interval)
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Parse STATUS blocks from a serial_logger.py log into JSON."
    )
    parser.add_argument("logfile", help="Path to the serial_logger.py log file")
    parser.add_argument(
        "--since", type=float, default=None,
        help="Only include records with host_ts >= SINCE (epoch seconds)",
    )
    args = parser.parse_args()

    if not os.path.exists(args.logfile):
        print(json.dumps({"error": "logfile not found", "path": args.logfile}))
        sys.exit(1)

    records = parse_log_file(args.logfile, since=args.since)
    print(json.dumps(records, indent=2))


if __name__ == "__main__":
    main()
