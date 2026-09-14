#!/usr/bin/env python3
"""Compile and run the current ESP32-S3 RinaLink host regression suite.

Requires Python 3 and a C++17 compiler (CXX, or c++). No board is needed.
Temporary executables are removed on exit; test failures return a nonzero status.
"""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIRMWARE = ROOT / "esp32s3_firmware"


def main():
    tests = FIRMWARE / "test" / "host"
    compiler = shlex.split(os.environ.get("CXX", "c++"))
    with tempfile.TemporaryDirectory(prefix="rina-protocol-selftest-") as scratch:
        for source in sorted(tests.glob("*_test.cpp")):
            executable = Path(scratch) / source.stem
            print(f"Running {source.name}", flush=True)
            subprocess.run(compiler + ["-std=c++17", "-Wall", "-Wextra", "-Werror",
                           f"-I{FIRMWARE / 'src'}", str(source), "-o", str(executable)],
                           cwd=ROOT, check=True)
            subprocess.run([str(executable)], cwd=ROOT, check=True)
        for source in sorted(tests.glob("*_test.py")):
            print(f"Running {source.name}", flush=True)
            subprocess.run([sys.executable, str(source)], cwd=ROOT, check=True)
    print("protocol_selftest: PASS")


if __name__ == "__main__":
    main()
