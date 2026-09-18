#!/usr/bin/env python3
"""Hint LED (`set_hint_led`): range check, ownership and render wiring.

Compiles the real setHintLed/clearHintLedOwnedBy bodies from led_renderer.cpp
against stubs, then checks the source wiring the host build cannot reach.
"""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RENDERER = (ROOT / "src/led_renderer.cpp").read_text()
PROTOCOL = (ROOT / "src/protocol.cpp").read_text()


def function(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


code = r'''
#include <cassert>
#include <cstdint>
#include <string>

static const int LED_COUNT = 370;
struct String : std::string {
    String() = default;
    String(const char* s) : std::string(s) {}
    String(int v) : std::string(std::to_string(v)) {}
    String(const std::string& s) : std::string(s) {}
};
static String operator+(const char* a, const String& b) { return String(std::string(a) + b); }
template <typename F> static void withFrameLock(F f) { f(); }
static int renders = 0;
static void showCurrentFrameNoLock() { ++renders; }
static int16_t g_hintLed = -1;
static uint8_t g_hintOwnerSlot = 0xFF;
''' + function(RENDERER, "bool setHintLed(") + "\n" \
    + function(RENDERER, "void clearHintLedOwnedBy(") + r'''
static int hintLed() { return g_hintLed; }
int main() {
    String err;
    assert(!setHintLed(370, 0, err) && !err.empty());
    assert(!setHintLed(-2, 0, err));
    assert(hintLed() == -1 && renders == 0);

    assert(setHintLed(12, 1, err) && hintLed() == 12 && renders == 1);
    assert(setHintLed(12, 1, err) && renders == 1);      // unchanged: no re-render
    clearHintLedOwnedBy(0);                               // not the owner
    assert(hintLed() == 12);
    clearHintLedOwnedBy(1);                               // owner leaves
    assert(hintLed() == -1 && renders == 2);
    clearHintLedOwnedBy(1);
    assert(renders == 2);

    assert(setHintLed(0, 2, err) && setHintLed(369, 2, err) && hintLed() == 369);
    assert(setHintLed(-1, 2, err) && hintLed() == -1);
    return 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "hint.cpp"
    exe = Path(tmp) / "hint"
    src.write_text(code)
    subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                    str(src), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)

render = function(RENDERER, "void renderCurrentFrameToLedStrip(")
assert "hint = g_hintLed;" in render, "render pass must snapshot the hint under the frame lock"
assert "half(colorR), half(colorG), half(colorB)" in render, "hint must be drawn at half colour"
assert "(v + 1) / 2" in render, "a lit channel must not halve to off"
hint_cmd = PROTOCOL[PROTOCOL.index('strcmp(cmd, "set_hint_led")'):]
hint_cmd = hint_cmd[:hint_cmd.index("String err;")]
assert "setHintLed(" in hint_cmd and "sendErrorReply(c, seq, 400" in hint_cmd, "set_hint_led must be dispatched"
assert "touchRuntimeState" not in hint_cmd, "a hover step is not board state and must not bump it"
assert "reply(out" not in hint_cmd, "a hover step is acked, not answered with the status document"
assert "clearHintLedOwnedBy(static_cast<uint8_t>(i))" in PROTOCOL, "disconnect must clear the client's hint"
print("hint_led_test: ok")
