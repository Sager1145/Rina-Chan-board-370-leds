#!/usr/bin/env python3
"""group_start's accepted intervalMs range must cover every interval the app
can send (docs/BOARD_GROUP_SPEC.md §1.5). The app's speed control reaches
RinaLinkConstants.scrollFpsMax (60 fps -> 17 ms via ScrollRasterizer.intervalMs);
a stricter firmware floor (it was 20) rejected every group play, speed change
and re-anchor above 51 fps with a 400 on each member.
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
REPO = ROOT.parent
PROTOCOL = (ROOT / "src" / "protocol.cpp").read_text()
CONFIG = (ROOT / "src" / "config.h").read_text()
CONSTANTS = (REPO / "ios" / "Packages" / "RinaCore" / "Sources" / "RinaCore" / "RinaLinkConstants.swift").read_text()


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def app_interval_ms(fps: int) -> int:
    # Mirrors ScrollRasterizer.intervalMs(forFps:): max(1, floor(1000/fps + 0.5)).
    return max(1, int(1000.0 / fps + 0.5))


def test_group_start_accepts_app_fps_range():
    handler = PROTOCOL[PROTOCOL.index('strcmp(cmd, "group_start")'):]
    handler = handler[:handler.index("scrollSessionGroupStart(")]
    check("intervalMs < static_cast<int>(MIN_SCROLL_INTERVAL_MS)" in handler,
          "group_start's intervalMs floor must be MIN_SCROLL_INTERVAL_MS (same as single-board scroll)")
    upper = int(re.search(r"intervalMs > (\d+)", handler).group(1))
    floor = int(re.search(r"MIN_SCROLL_INTERVAL_MS = (\d+)", CONFIG).group(1))
    fps_min = int(re.search(r"scrollFpsMin = (\d+)", CONSTANTS).group(1))
    fps_max = int(re.search(r"scrollFpsMax = (\d+)", CONSTANTS).group(1))
    for fps in range(fps_min, fps_max + 1):
        interval = app_interval_ms(fps)
        check(floor <= interval <= upper,
              f"app fps {fps} -> intervalMs {interval} is outside group_start's {floor}..{upper}")
    print("test_group_start_accepts_app_fps_range: OK")


def main():
    test_group_start_accepts_app_fps_range()
    print("All group_start range checks passed.")


if __name__ == "__main__":
    main()
