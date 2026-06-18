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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", help="serial port, e.g. COM7 or /dev/ttyACM0")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.2)
    time.sleep(0.5)
    ser.reset_input_buffer()

    print("=== RinaChan serial smoke test ===")
    cmd(ser, "version")
    cmd(ser, "log level INFO")
    cmd(ser, "status")

    # Button emulation: B1 should change the face index (when faces exist).
    before = kv(cmd(ser, "face status"), "OK face status")
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
    cmd(ser, "led color #00ff00")
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
