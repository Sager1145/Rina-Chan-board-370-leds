#!/usr/bin/env python
"""serial_logger.py — resilient host-side serial logger for RinaBoard stress tests.

Opens PORT, timestamps every received line with a host epoch-ms prefix, and
writes it to LOGFILE. Reads pseudo/real commands to send to the board from
``<LOGFILE>.cmd`` (one command appended per line by another process/script).

Behavior (see docs/STRESS_TEST_DUAL_BOARD_PLAN_ZH.md section 1, 4.9, 6):
  - On open (and after every reopen) sends ``log level debug``.
  - Sends ``status`` every --status-interval seconds.
  - Strips NUL bytes from incoming data.
  - Every received line is logged as ``[HOST <epoch.ms>] <line>``.
  - Every command sent to the board is logged as ``[HOST <epoch.ms>] >> <cmd>``.
  - Pseudo-commands read from the .cmd file:
      __reset__  - pulses DTR/RTS to hardware-reset an ESP32-S3 USB-Serial/JTOG
                   board (DTR=False, RTS=True, sleep 0.1s, RTS=False).
      __reopen__ - closes and reopens the serial port.
    Both are logged as ``>> __reset__`` / ``>> __reopen__`` (not written to
    the wire).
  - Resilience:
      * If the port disappears (OSError/SerialException) logs PORT_GONE,
        polls every 0.5s for the device node to come back, reopens it, logs
        PORT_BACK, and resends ``log level debug``.
      * If no bytes arrive for --stall-sec seconds while the port is still
        present, logs STALL and reopens the port (recreating the same
        PORT_GONE/BACK-less reopen + resend of ``log level debug``).

Usage:
    python serial_logger.py /dev/cu.usbmodemXXXX board_a.log --duration 300
"""

import argparse
import os
import sys
import time

try:
    import serial
    from serial import SerialException
except ImportError:  # pragma: no cover - pyserial is a hard dependency
    print("pyserial is required (pip install pyserial)", file=sys.stderr)
    raise


def now_ms():
    return time.time() * 1000.0


def host_prefix(ts_ms=None):
    if ts_ms is None:
        ts_ms = now_ms()
    return "[HOST {:.3f}] ".format(ts_ms / 1000.0)


class LineLogger:
    """Appends timestamped lines to LOGFILE, flushing after every write."""

    def __init__(self, path):
        self._fh = open(path, "a", buffering=1)

    def log(self, text):
        line = host_prefix() + text
        self._fh.write(line + "\n")
        self._fh.flush()
        return line

    def close(self):
        self._fh.close()


class CommandTail:
    """Reads newly appended lines from ``<logfile>.cmd``.

    The file is created if missing. We remember our byte offset across
    calls so we only ever return commands appended since the last poll.
    """

    def __init__(self, path):
        self.path = path
        if not os.path.exists(path):
            open(path, "a").close()
        self._offset = os.path.getsize(path)

    def poll(self):
        commands = []
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return commands
        if size < self._offset:
            # file was truncated/recreated; start over
            self._offset = 0
        if size == self._offset:
            return commands
        with open(self.path, "r") as fh:
            fh.seek(self._offset)
            chunk = fh.read()
            self._offset = fh.tell()
        for raw in chunk.splitlines():
            cmd = raw.strip()
            if cmd:
                commands.append(cmd)
        return commands


def pulse_reset(ser):
    """Pulse DTR/RTS to hardware-reset an ESP32-S3 USB-Serial/JTAG board."""
    ser.dtr = False
    ser.rts = True
    time.sleep(0.1)
    ser.rts = False


def open_port(port_name, baud):
    ser = serial.Serial(port_name, baudrate=baud, timeout=0.2)
    return ser


def run(port_name, logfile, duration, status_interval, stall_sec, baud):
    logger = LineLogger(logfile)
    cmd_tail = CommandTail(logfile + ".cmd")

    ser = None
    buf = b""
    last_status_sent = 0.0
    last_byte_time = time.time()
    deadline = time.time() + duration if duration is not None else None

    def send_raw(text):
        logger.log(">> " + text)
        if ser is not None and ser.is_open:
            ser.write((text + "\n").encode("utf-8", errors="ignore"))

    def reopen(reason):
        nonlocal ser, buf, last_byte_time
        if ser is not None:
            try:
                ser.close()
            except Exception:
                pass
        buf = b""
        while True:
            try:
                ser = open_port(port_name, baud)
                break
            except (OSError, SerialException):
                if deadline is not None and time.time() > deadline:
                    return False
                time.sleep(0.5)
        last_byte_time = time.time()
        if reason:
            logger.log(reason)
        send_raw("log level debug")
        return True

    try:
        ser = open_port(port_name, baud)
    except (OSError, SerialException):
        logger.log("PORT_GONE")
        if not reopen("PORT_BACK"):
            logger.close()
            return
    else:
        send_raw("log level debug")

    last_status_sent = time.time()

    try:
        while deadline is None or time.time() < deadline:
            now = time.time()

            for cmd in cmd_tail.poll():
                if cmd == "__reset__":
                    logger.log(">> __reset__")
                    if ser is not None and ser.is_open:
                        try:
                            pulse_reset(ser)
                        except (OSError, SerialException):
                            pass
                elif cmd == "__reopen__":
                    logger.log(">> __reopen__")
                    reopen(None)
                else:
                    send_raw(cmd)

            if now - last_status_sent >= status_interval:
                send_raw("status")
                last_status_sent = now

            try:
                if ser is None or not ser.is_open:
                    raise SerialException("port not open")
                data = ser.read(4096)
            except (OSError, SerialException):
                logger.log("PORT_GONE")
                if not reopen("PORT_BACK"):
                    break
                continue

            if data:
                last_byte_time = time.time()
                data = data.replace(b"\x00", b"")
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    text = line.decode("utf-8", errors="replace").rstrip("\r")
                    logger.log(text)
            else:
                if time.time() - last_byte_time >= stall_sec:
                    logger.log("STALL")
                    if not reopen(None):
                        break
    finally:
        if ser is not None:
            try:
                ser.close()
            except Exception:
                pass
        logger.close()


def main():
    parser = argparse.ArgumentParser(
        description="Resilient host-side serial logger for RinaBoard stress tests."
    )
    parser.add_argument("port", help="Serial port device, e.g. /dev/cu.usbmodemXXXX")
    parser.add_argument("logfile", help="Path to append timestamped log lines to")
    parser.add_argument(
        "--duration", type=float, default=None,
        help="Seconds to run before exiting (default: run forever)",
    )
    parser.add_argument(
        "--status-interval", type=float, default=10.0,
        help="Seconds between automatic 'status' commands (default: 10)",
    )
    parser.add_argument(
        "--stall-sec", type=float, default=30.0,
        help="Seconds with no received bytes before declaring a STALL and reopening (default: 30)",
    )
    parser.add_argument(
        "--baud", type=int, default=115200,
        help="Baud rate (default: 115200; irrelevant for USB-CDC/JTAG serial)",
    )
    args = parser.parse_args()

    run(args.port, args.logfile, args.duration, args.status_interval, args.stall_sec, args.baud)


if __name__ == "__main__":
    main()
