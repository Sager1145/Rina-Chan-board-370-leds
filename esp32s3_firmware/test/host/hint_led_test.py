#!/usr/bin/env python3
"""Hint LED (`set_hint_led`): range check, ownership and render wiring.

Compiles the real setHintLed/clearHintLedOwnedBy/clearHintLed/
hintLedForDiagnostics bodies from led_renderer.cpp against stubs, then checks
the source wiring the host build cannot reach (output-mode gating in
serviceProtocol(), the handler's `shown` reply, the TCP dead-peer clear, and
serial console wiring).
"""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RENDERER = (ROOT / "src/led_renderer.cpp").read_text()
PROTOCOL = (ROOT / "src/protocol.cpp").read_text()
TRANSPORT_TCP = (ROOT / "src/transport_tcp.cpp").read_text()
SERIAL_CONSOLE = (ROOT / "src/serial_console.cpp").read_text()
CONFIG = (ROOT / "src/config.h").read_text()


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
    + function(RENDERER, "void clearHintLedOwnedBy(") + "\n" \
    + function(RENDERER, "void clearHintLed(") + "\n" \
    + function(RENDERER, "int16_t hintLedForDiagnostics(") + r'''
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

    // clearHintLed(): unconditional, regardless of owner; no-op (no extra
    // render) when already clear.
    assert(hintLedForDiagnostics() == -1);
    assert(setHintLed(5, 7, err) && hintLedForDiagnostics() == 5);
    int rendersBefore = renders;
    clearHintLed();
    assert(hintLedForDiagnostics() == -1 && renders == rendersBefore + 1);
    int rendersAfterClear = renders;
    clearHintLed();                                        // already clear
    assert(renders == rendersAfterClear);

    assert(setHintLed(100, 3, err));
    clearHintLed();                                        // clears regardless of owner
    assert(hintLedForDiagnostics() == -1);
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

# --- output-mode gate in serviceProtocol() -------------------------------
service_protocol = function(PROTOCOL, "void serviceProtocol(")
assert 'runtimeState().outputMode != "control"' in service_protocol, \
    "serviceProtocol must drop the hint once output leaves the control mode"
assert "clearHintLed();" in service_protocol, \
    "serviceProtocol must call the unconditional clearHintLed(), not the owner-scoped variant"

# --- handler's `shown` reply, gated on control output --------------------
hint_cmd_full = PROTOCOL[PROTOCOL.index('strcmp(cmd, "set_hint_led")'):]
hint_cmd_full = hint_cmd_full[:hint_cmd_full.index('\n    }\n\n    String err;')]
assert 'runtimeState().outputMode == "control"' in hint_cmd_full, \
    "handler must gate led>=0 on the control output"
assert 'out["shown"]' in hint_cmd_full, "reply must carry shown"
assert "++runtimeState().commandsAccepted;" in hint_cmd_full, "must still count as accepted"
decline = hint_cmd_full[hint_cmd_full.index("if (led >= 0 && !isControlOutput)"):]
assert "sendErrorReply" not in decline.split('} else {')[0], \
    "declining because another output owns the frame must not be an error"
assert hint_cmd_full.index("led >= static_cast<int>(LED_COUNT)") < hint_cmd_full.index("isControlOutput"), \
    "an out-of-range led must be a 400 before the output-mode decline, in every mode"

# --- TCP dead-peer hint clear ---------------------------------------------
assert "uint32_t lastInboundMs" in TRANSPORT_TCP, "TCP slot must track last inbound time"
assert "TCP_HINT_SILENCE_MS" in TRANSPORT_TCP, "TCP service loop must reference the silence constant"
assert "clearHintLedOwnedBy(s.id.slot)" in TRANSPORT_TCP, \
    "TCP silence check must clear by protocol client slot (s.id.slot), not the TCP array index"
tcp_service = function(TRANSPORT_TCP, "void tcpTransportService(")
assert "s.lastActivityMs = millis();" in tcp_service and "closeSlot(s);" in tcp_service, \
    "idle-disconnect semantics must be untouched"
assert "TCP_HINT_SILENCE_MS" in CONFIG, "TCP_HINT_SILENCE_MS must be defined in config.h"

# --- serial console wiring -------------------------------------------------
status_fn = function(SERIAL_CONSOLE, "void printStatus(")
assert "hintLedForDiagnostics()" in status_fn, "status must report the hint LED"
assert '"STATUS hint=' in status_fn, "status output must be prefixed hint="
run_line = function(SERIAL_CONSOLE, "void runLine(")
frame_clear = run_line[run_line.index('"clear") == 0'):run_line.index('"OK frame clear"')]
assert "clearHintLed();" in frame_clear, "frame clear must also clear the hint LED"

print("hint_led_test: ok")
