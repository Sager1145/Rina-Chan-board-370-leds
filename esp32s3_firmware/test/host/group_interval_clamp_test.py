#!/usr/bin/env python3
"""group_start may store 17..2000 ms. Leaving group timing (pause_scroll)
clamps the stored scrollIntervalMs to the legacy tick range, and the next
local tick uses that stored value.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = (ROOT / "src" / "protocol.cpp").read_text()
CONFIG = (ROOT / "src" / "config.h").read_text()
SESSION = (ROOT / "src" / "scroll_session.cpp").read_text()


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def test_group_start_still_accepts_2000():
    handler = PROTOCOL[PROTOCOL.index('strcmp(cmd, "group_start")'):]
    handler = handler[:handler.index("scrollSessionGroupStart(")]
    upper = int(re.search(r"intervalMs > (\d+)", handler).group(1))
    check(upper == 2000, f"group_start accept ceiling must stay 2000, got {upper}")
    print("test_group_start_still_accepts_2000: OK")


def test_exit_clamps_stored_interval_and_tick():
    floor = int(re.search(r"MIN_SCROLL_INTERVAL_MS = (\d+)", CONFIG).group(1))
    cap = int(re.search(r"MAX_SCROLL_INTERVAL_MS = (\d+)", CONFIG).group(1))
    check(floor == 17 and cap == 1000, f"unexpected scroll interval range {floor}..{cap}")
    pieces = [
        function(SESSION, "void scrollSessionExitGroupTimedLocked("),
        function(SESSION, "static bool setFirmwareScrollPauseFlag("),
        function(SESSION, "bool scrollSessionSetUserPaused("),
        function(SESSION, "bool scrollSessionGroupStart("),
        function(SESSION, "bool scrollSessionTickCursorLocked("),
    ]
    code = r'''
#include "group_math.h"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
constexpr unsigned FRAME_BYTES = 47;
constexpr uint16_t MIN_SCROLL_INTERVAL_MS = %d;
constexpr uint16_t MAX_SCROLL_INTERVAL_MS = %d;
using String = std::string;
struct LedPresentationContext {};
enum class LedPresentationSource { ScrollStart };
struct Runtime {
    bool firmwareScrollActive = false;
    bool firmwareScrollPaused = false;
    bool firmwareScrollUserPaused = false;
    bool firmwareScrollSystemPaused = false;
    bool paused = false;
    bool scrollLoop = true;
    bool groupTimed = false;
    bool groupLoop = true;
    String playback = "idle";
    uint16_t scrollFrameIndex = 0;
    uint16_t scrollFrameCount = 2;
    uint16_t scrollIntervalMs = 100;
    uint16_t groupStartFrame = 0;
    uint16_t groupIntervalMs = 0;
    uint32_t lastScrollFrameMs = 0;
    uint64_t groupAtUs = 0;
} rs;
Runtime& runtimeState() { return rs; }
bool runtimeScrollFrameBufferReady() { return true; }
uint8_t scrollBits[2][FRAME_BYTES] = {};
uint8_t* runtimeScrollFrameBits(uint16_t i) { return scrollBits[i]; }
uint32_t nowMs = 10000;
uint32_t millis() { return nowMs; }
uint64_t espNowUs = 5000000;
uint64_t esp_timer_get_time() { return espNowUs; }
bool sScrollEndPausePending = false;
template <class T, class A, class B>
T constrain(T v, A a, B b) {
    if (v < static_cast<T>(a)) return static_cast<T>(a);
    if (v > static_cast<T>(b)) return static_cast<T>(b);
    return v;
}
template <class F>
auto withScrollLock(F f) -> decltype(f()) { return f(); }
void scrollSessionFillPresentationContextLocked(LedPresentationContext&, LedPresentationSource, const char*, bool) {}
void applyPackedFrameImmediate(const uint8_t*, const String&, const LedPresentationContext*) {}
void setRuntimeOutputMode(const char*) {}
void touchRuntimeState() {}
void clearQueuedPackedFrames() {}
void cancelDeferredFaceRestore() {}
#define RLOG_INFO(...) ((void)0)
''' % (floor, cap)
    code += "\n" + "\n".join(pieces) + r'''
int main() {
    scrollBits[0][0] = 1;
    scrollBits[1][0] = 2;
    assert(scrollSessionGroupStart(espNowUs, 0, 1500, true));
    assert(rs.groupTimed);
    assert(rs.groupIntervalMs == 1500);
    assert(rs.scrollIntervalMs == 1500);
    assert(rs.scrollFrameIndex == 0);
    // pause_scroll exits group timing and must store the legacy cap.
    assert(scrollSessionSetUserPaused(true));
    assert(!rs.groupTimed);
    assert(rs.groupIntervalMs == 1500);
    assert(rs.scrollIntervalMs == 1000);
    assert(rs.firmwareScrollPaused);
    // Resume so the local tick runs; it re-anchors lastScrollFrameMs.
    assert(scrollSessionSetUserPaused(false));
    assert(!rs.firmwareScrollPaused);
    assert(rs.scrollIntervalMs == 1000);
    uint8_t out[FRAME_BYTES] = {};
    assert(!scrollSessionTickCursorLocked(rs.lastScrollFrameMs + 999, out));
    assert(rs.scrollFrameIndex == 0);
    assert(scrollSessionTickCursorLocked(rs.lastScrollFrameMs + 1000, out));
    assert(rs.scrollFrameIndex == 1);
    assert(out[0] == 2);
    std::cout << "PASS: group_start 1500, pause_scroll stores 1000, tick uses 1000\n";
}
'''
    with tempfile.TemporaryDirectory(prefix="rina-group-interval-") as directory:
        src = Path(directory) / "test.cpp"
        exe = Path(directory) / "test"
        src.write_text(code)
        subprocess.run(
            ["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
             "-I", str(ROOT / "src"), str(src), "-o", str(exe)],
            check=True,
        )
        subprocess.run([str(exe)], check=True)
    print("test_exit_clamps_stored_interval_and_tick: OK")


def main():
    test_group_start_still_accepts_2000()
    test_exit_clamps_stored_interval_and_tick()
    print("All group interval clamp checks passed.")


if __name__ == "__main__":
    main()
