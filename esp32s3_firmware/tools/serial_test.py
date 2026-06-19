#!/usr/bin/env python3
"""
serial_test.py -- host-side harness for the RinaChan board serial test console.

No Wi-Fi required: drives the firmware over USB serial, parses the line-oriented
replies, and asserts. Mirrors the on-device `test run all` but from the host so
it can live in CI on a bench rig.

Usage:
    python serial_test.py [PORT] [--baud 115200]

Examples:
    python serial_test.py COM7
    python serial_test.py /dev/ttyACM0
    python serial_test.py /dev/ttyUSB0 --baud 115200

Requires: pip install pyserial
"""
import argparse
import sys
import time

try:
    import serial  # pyserial
except ImportError:
    sys.exit("pyserial is required: pip install pyserial")


def read_block(ser, settle=0.35):
    """Read whatever the board sends back within `settle` seconds, as lines."""
    deadline = time.time() + settle
    lines = []
    buf = b""
    while time.time() < deadline:
        chunk = ser.read(256)
        if chunk:
            buf += chunk
            deadline = time.time() + settle  # extend while data flows
        else:
            time.sleep(0.02)
    for raw in buf.split(b"\n"):
        s = raw.decode("utf-8", "replace").strip("\r ")
        if s:
            lines.append(s)
    return lines


def cmd(ser, line, settle=0.35):
    ser.reset_input_buffer()
    ser.write((line + "\n").encode())
    out = read_block(ser, settle)
    print(f"> {line}")
    for l in out:
        print(f"    {l}")
    return out


def kv(lines, prefix):
    """Parse 'key=value' tokens from the first line starting with `prefix`."""
    for l in lines:
        if l.startswith(prefix):
            d = {}
            for tok in l.split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    d[k] = v
            return d
    return {}


def parse_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def apply_default_face(ser, default_face_index):
    """Keep the default/baseline saved face visible for color-only tests."""
    cmd(ser, "scroll stop")
    cmd(ser, "mode manual")
    cmd(ser, f"face apply {default_face_index}")


COLOR_SWEEP = [
    # Parent colors from data/app.js parent_color_groups.
    "#f971d4", "#e4007f", "#00a1e8", "#f8b656", "#a5469b", "#fb8a9b",
    # Child colors from data/app.js child_color_groups: 9 + 16 + 16 + 14 + 12.
    "#f38500", "#7aeeff", "#cebfbf", "#1769ff", "#fff832", "#ff503e",
    "#c455f6", "#6ae673", "#ff4f91",
    "#ff9547", "#ff9eac", "#27c1b7", "#db0839", "#66c0ff", "#c1cad4",
    "#ffd010", "#c252c6", "#ff6fbe", "#ffa434", "#ff5a79", "#825deb",
    "#53ab7f", "#00ccff", "#bbbbbb", "#cb3935",
    "#ed7d95", "#e7d600", "#01b7ed", "#485ec6", "#ff5800", "#a664a0",
    "#d81c2f", "#84c36e", "#9ca5b9", "#37b484", "#a9a898", "#f8c8c4",
    "#ab76f7", "#ff0042", "#d9db83", "#424a9d",
    "#ff7f27", "#a0fff9", "#ff6e90", "#74f466", "#0000a0", "#fff442",
    "#ff3535", "#b2ffdd", "#ff51c4", "#e49dfd", "#4cd2e2", "#e8243c",
    "#bcbcde", "#ffe840",
    "#f8b500", "#5383c3", "#68be8d", "#ba2636", "#e7609e", "#c8c2c6",
    "#a2d7dd", "#fad764", "#9d8de2", "#da645f", "#163bca", "#f3b171",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", help="serial port, e.g. COM7 or /dev/ttyACM0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument(
        "--default-face-index",
        type=int,
        default=None,
        help="Saved-face index to keep displayed during color tests; defaults to the startup/baseline face.",
    )
    ap.add_argument(
        "--color-sweep",
        action="store_true",
        help="Exercise all WebUI palette colors while repeatedly restoring the default face.",
    )
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.2)
    time.sleep(0.5)
    ser.reset_input_buffer()

    print("=== RinaChan serial smoke test ===")
    cmd(ser, "version")
    cmd(ser, "log level INFO")
    cmd(ser, "status")
    baseline_face = kv(cmd(ser, "face status"), "OK face status")
    default_face_index = (
        args.default_face_index
        if args.default_face_index is not None
        else parse_int(baseline_face.get("index"), 0)
    )
    print(f"  default_face_index={default_face_index}")

    # Button emulation: B1 should change the face index (when faces exist).
    before = baseline_face
    cmd(ser, "btn tap B1")
    after = kv(cmd(ser, "face status"), "OK face status")
    if before.get("index") is not None and after.get("index") is not None:
        if before["count"] != "0":
            assert before["index"] != after["index"] or before["count"] == "1", \
                "B1 did not change face index"
            print("  [ok] B1 changed face index")

    # Combo auto-interval.
    cmd(ser, "btn combo B3+B1 tap")

    # Voltage.
    cmd(ser, "adc read vbat")
    cmd(ser, "battery status")

    # Full WebUI-parity commands.
    # Color changes are deliberately tested with the baseline/default saved face
    # showing, so the panel proves the color changed on a real face instead of
    # a blank/debug frame left behind by an earlier test.
    apply_default_face(ser, default_face_index)
    cmd(ser, "led color #00ff00")
    cmd(ser, "led current")
    if args.color_sweep:
        for color in COLOR_SWEEP:
            apply_default_face(ser, default_face_index)
            cmd(ser, f"led color {color}")
            current = kv(cmd(ser, "led current"), "OK led current")
            lit = parse_int(current.get("lit"), 0)
            actual = (current.get("color") or "").lower()
            assert actual == color.lower(), f"color mismatch: expected {color}, got {actual}"
            assert lit > 0, f"default face is not visible during color {color}"
            time.sleep(0.5)
    cmd(ser, "scroll interval 60")
    cmd(ser, "scroll fps 30")
    cmd(ser, "terminate all")
    cmd(ser, "pause")
    cmd(ser, "resume")
    cmd(ser, "battery overlay single")

    # Arbitrary frame push + fidelity round-trip: push a frame, read it back,
    # re-push the read-back string, and confirm the dump is identical.
    cmd(ser, "led test pattern single 0")
    out1 = cmd(ser, "led dump compact")
    m370 = next((t for t in " ".join(out1).split() if t.startswith("M370:")), None)
    if m370:
        cmd(ser, f"frame {m370}")
        out2 = cmd(ser, "led dump compact")
        m370b = next((t for t in " ".join(out2).split() if t.startswith("M370:")), None)
        print(f"  [ok] frame round-trip identical" if m370 == m370b
              else f"  [FAIL] round-trip mismatch")

    # LED dump round-trips: compact M370 is pasteable.
    dump = kv(cmd(ser, "led dump compact"), "OK led dump compact")
    print(f"  compact lit={dump.get('lit')}")

    cmd(ser, "scroll status")

    # On-device self-test runner (functional) + exhaustive option sweep.
    res = cmd(ser, "test run all", settle=1.5)
    summary = kv(res, "[TEST] SUMMARY")
    sweep = cmd(ser, "test run sweep", settle=4.0)
    sweep_sum = kv(sweep, "[TEST] SUMMARY")
    print(f"\n=== functional {summary} | sweep {sweep_sum} ===")
    fails = int(summary.get("fail", "0") or "0") + int(sweep_sum.get("fail", "0") or "0")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
