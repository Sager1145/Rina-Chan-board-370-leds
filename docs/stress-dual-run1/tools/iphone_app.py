#!/usr/bin/env python
"""iphone_app.py — thin wrapper around `xcrun devicectl` for driving the
RinaBoard app on the physical iPhone during dual-board stress tests.

Sets DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer for every
invocation. All state-changing operations support --dry-run, which prints
the command instead of running it.

Force-quit uses `devicectl device process terminate --pid <pid> --kill`
(SIGKILL). Per the stress plan, this tool never uses --terminate-existing.

Usage:
    python iphone_app.py --dry-run pid <udid>
    python iphone_app.py --dry-run force-quit <udid>
    python iphone_app.py --dry-run launch <udid> [--bundle com.rinachan.board] [-- extra args...]
    python iphone_app.py --dry-run crash-reports <udid> --since 1700000000
"""

import argparse
import json
import re
import subprocess
import sys
import time

DEVELOPER_DIR = "/Applications/Xcode-beta.app/Contents/Developer"
DEFAULT_BUNDLE_ID = "com.rinachan.board"


def _env():
    import os
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = DEVELOPER_DIR
    return env


def _run(cmd, dry_run=False, capture=True):
    """Run cmd (a list) with DEVELOPER_DIR set. In dry-run mode, print the
    command and return an empty successful CompletedProcess-like result."""
    if dry_run:
        print("DRY-RUN: " + " ".join(cmd))
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
    return subprocess.run(
        cmd, env=_env(), capture_output=capture, text=True, check=False
    )


def pid(udid, dry_run=False):
    """Return the running process id of the RinaBoard app on the device, or
    None if not running. Uses `devicectl device info processes` and greps
    for the bundle's executable name."""
    cmd = [
        "xcrun", "devicectl", "device", "info", "processes",
        "--device", udid, "--json-output", "-",
    ]
    result = _run(cmd, dry_run=dry_run)
    if dry_run:
        return None
    if result.returncode != 0:
        return None
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return None

    processes = (
        payload.get("result", {}).get("processes")
        or payload.get("result", {}).get("devices", [{}])[0].get("processes")
        or []
    )
    for proc in processes:
        name = proc.get("executable") or proc.get("name") or ""
        if "RinaBoard" in name:
            return proc.get("processIdentifier") or proc.get("pid")
    return None


def force_quit(udid, target_pid=None, dry_run=False):
    """Force-quit (SIGKILL) the RinaBoard process by pid. Never uses
    --terminate-existing. If target_pid is not given, it is looked up via
    pid()."""
    if target_pid is None:
        target_pid = pid(udid, dry_run=dry_run)
        if target_pid is None and not dry_run:
            print("iphone_app: no running RinaBoard process found", file=sys.stderr)
            return False
    cmd = [
        "xcrun", "devicectl", "device", "process", "terminate",
        "--device", udid,
        "--pid", str(target_pid) if target_pid is not None else "<pid>",
        "--kill",
    ]
    result = _run(cmd, dry_run=dry_run)
    return dry_run or result.returncode == 0


def launch(udid, bundle=DEFAULT_BUNDLE_ID, args=None, dry_run=False):
    """Launch the app. Options must precede the bundle id per devicectl's
    argument order."""
    args = args or []
    # devicectl process launch syntax: options BEFORE the bundle id, then the
    # bundle id, then any app arguments.
    cmd = [
        "xcrun", "devicectl", "device", "process", "launch",
        "--device", udid,
        bundle,
    ] + list(args)
    result = _run(cmd, dry_run=dry_run)
    return dry_run or result.returncode == 0


def crash_reports(udid, since_epoch, dry_run=False):
    """List systemCrashLogs entries whose name starts with RinaBoard, created
    at or after since_epoch. Returns a list of dicts with at least 'name'
    and 'date' when not in dry-run mode."""
    cmd = [
        "xcrun", "devicectl", "device", "info", "crashLogs",
        "--device", udid,
        "--json-output", "-",
    ]
    result = _run(cmd, dry_run=dry_run)
    if dry_run:
        return []
    if result.returncode != 0:
        return []
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return []

    entries = payload.get("result", {}).get("logs") or payload.get("result", {}).get("crashLogs") or []
    matches = []
    for entry in entries:
        name = entry.get("name", "")
        if not name.startswith("RinaBoard"):
            continue
        date_str = entry.get("date") or entry.get("timestamp")
        entry_epoch = _parse_date_to_epoch(date_str)
        if entry_epoch is not None and entry_epoch < since_epoch:
            continue
        matches.append(entry)
    return matches


def _parse_date_to_epoch(date_str):
    if not date_str:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S"):
        try:
            return time.mktime(time.strptime(date_str[:19], fmt[:19].replace("%z", "")))
        except ValueError:
            continue
    return None


def main():
    parser = argparse.ArgumentParser(
        description="devicectl helpers for driving RinaBoard on the physical iPhone."
    )
    parser.add_argument("--dry-run", action="store_true", help="Print commands instead of running them")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_pid = sub.add_parser("pid", help="Print the running RinaBoard process id")
    p_pid.add_argument("udid")

    p_fq = sub.add_parser("force-quit", help="SIGKILL the RinaBoard process by pid")
    p_fq.add_argument("udid")
    p_fq.add_argument("--pid", type=int, default=None, dest="target_pid")

    p_launch = sub.add_parser("launch", help="Launch RinaBoard")
    p_launch.add_argument("udid")
    p_launch.add_argument("--bundle", default=DEFAULT_BUNDLE_ID)
    p_launch.add_argument("args", nargs="*", help="Extra launch arguments (after --)")

    p_crash = sub.add_parser("crash-reports", help="List RinaBoard crash reports since a timestamp")
    p_crash.add_argument("udid")
    p_crash.add_argument("--since", type=float, required=True, help="Epoch seconds")

    args = parser.parse_args()

    if args.cmd == "pid":
        result = pid(args.udid, dry_run=args.dry_run)
        print(result if result is not None else "")
    elif args.cmd == "force-quit":
        ok = force_quit(args.udid, target_pid=args.target_pid, dry_run=args.dry_run)
        sys.exit(0 if ok else 1)
    elif args.cmd == "launch":
        ok = launch(args.udid, bundle=args.bundle, args=args.args, dry_run=args.dry_run)
        sys.exit(0 if ok else 1)
    elif args.cmd == "crash-reports":
        reports = crash_reports(args.udid, args.since, dry_run=args.dry_run)
        print(json.dumps(reports, indent=2))


if __name__ == "__main__":
    main()
