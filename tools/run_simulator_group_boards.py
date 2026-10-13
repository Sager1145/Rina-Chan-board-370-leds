#!/usr/bin/env python3
"""Run five local protocol boards for the opt-in iOS simulator group fixtures."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    emulator = Path(__file__).with_name("rinalink_board_emulator.py")
    children = []
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        for index in range(1, 6):
            env = dict(os.environ, RINA_EMU_HOST="127.0.0.1", RINA_EMU_PORT=str(15369 + index),
                       RINA_EMU_BOARD_ID=f"EMU-127.0.0.{index}", RINA_EMU_BOARD_NAME=f"Test board {index}",
                       RINA_EMU_SCROLL_FLAG="/tmp/rina-simulator-group-scroll.flag")
            children.append(subprocess.Popen([sys.executable, str(emulator),
                f"/tmp/rina-simulator-board-{index}.log"], env=env))
        print("Five test boards: 127.0.0.1 ports 15370–15374. Ctrl-C stops all five.", flush=True)
        # Stop the whole fixture set if a listener fails, rather than leaving
        # a partly connected test group running without an explanation.
        while True:
            for child in children:
                if child.poll() is not None:
                    raise SystemExit(f"Test board exited with code {child.returncode}")
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
        for child in children:
            child.wait()


if __name__ == "__main__":
    main()
