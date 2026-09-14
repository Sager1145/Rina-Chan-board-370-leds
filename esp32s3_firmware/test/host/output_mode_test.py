#!/usr/bin/env python3
"""Exercise stable renderer ownership parsing and takeover wiring."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
STATE = (ROOT / "src/state.cpp").read_text()
PROTOCOL = (ROOT / "src/protocol.cpp").read_text()
FACES = (ROOT / "src/faces.cpp").read_text()
RENDERER = (ROOT / "src/led_renderer.cpp").read_text()
SCROLL = (ROOT / "src/scroll_session.cpp").read_text()


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
#include <cstddef>
#include <cstdint>
#include <cstring>

struct OutputFrameDescriptor {
    char mode[12] = "control";
    char streamID[37] = {0};
    uint32_t positionMs = 0;
};

size_t strlcpy(char* dst, const char* src, size_t size) {
    const size_t length = std::strlen(src);
    if (size) {
        const size_t copied = length < size - 1 ? length : size - 1;
        std::memcpy(dst, src, copied);
        dst[copied] = '\0';
    }
    return length;
}
'''
for signature in (
    "static bool outputReasonBase(",
    "static bool canonicalOutputUuid(",
    "static bool outputPosition(",
    "void parseOutputFrameReason(",
):
    code += "\n" + function(STATE, signature) + "\n"

code += r'''
static void expect(const char* reason, const char* mode, const char* stream, uint32_t position) {
    OutputFrameDescriptor out;
    parseOutputFrameReason(reason, out);
    assert(std::strcmp(out.mode, mode) == 0);
    assert(std::strcmp(out.streamID, stream) == 0);
    assert(out.positionMs == position);
}

int main() {
    constexpr const char* uuid = "123e4567-e89b-12d3-a456-426614174000";
    expect(nullptr, "control", "", 0);
    expect("custom_live_send", "control", "", 0);
    expect("lipsync", "lipSync", "", 0);
    expect("live_preset", "performance", "", 0);
    expect("video", "video", "", 0);
    expect("lipsync:123e4567-e89b-12d3-a456-426614174000:0", "lipSync", uuid, 0);
    expect("live_preset:123E4567-E89B-12D3-A456-426614174000:4294967295",
           "performance", "123E4567-E89B-12D3-A456-426614174000", UINT32_MAX);
    expect("video:123e4567-e89b-12d3-a456-426614174000:987654321", "video", uuid, 987654321);

    // A recognized base remains useful for navigation, but malformed metadata
    // must never identify a stream that the app could accidentally resume.
    expect("video:123e4567-e89b-12d3-a456-42661417400:1", "video", "", 0);
    expect("video:123e4567-e89b-12d3-a456-42661417400z:1", "video", "", 0);
    expect("video:123e4567-e89b12d3-a456-426614174000:1", "video", "", 0);
    expect("video:123e4567-e89b-12d3-a456-426614174000:", "video", "", 0);
    expect("video:123e4567-e89b-12d3-a456-426614174000:-1", "video", "", 0);
    expect("video:123e4567-e89b-12d3-a456-426614174000:4294967296", "video", "", 0);
    expect("video:123e4567-e89b-12d3-a456-426614174000:1:2", "video", "", 0);
    expect("Video:123e4567-e89b-12d3-a456-426614174000:1", "control", "", 0);
    expect("video_extra:123e4567-e89b-12d3-a456-426614174000:1", "control", "", 0);
}
'''

with tempfile.TemporaryDirectory(prefix="rina-output-mode-test-") as directory:
    source = Path(directory) / "test.cpp"
    binary = Path(directory) / "test"
    source.write_text(code)
    subprocess.run(
        ["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)],
        check=True,
    )
    subprocess.run([str(binary)], check=True)

status = function(PROTOCOL, "static void buildStatusJson(")
preview = function(PROTOCOL, "static void buildPreviewSyncJson(")
for builder in (status, preview):
    assert '["outputMode"] = runtimeState().outputMode' in builder
    assert '["outputStreamID"] = runtimeState().outputStreamID' in builder
    assert '["outputPositionMs"] = runtimeState().outputPositionMs' in builder

set_frame = function(PROTOCOL, "static void handleSetFrame(")
assert set_frame.index("validatePackedFrame(") < set_frame.index("takeOverExternalFrame();")
assert set_frame.index("applyPackedFrameQueued(") < set_frame.index("setRuntimeOutputFromFrameReason(")

set_mode = function(FACES, "bool setMode(")
saved_face = function(FACES, "bool applySavedFaceIndex(")
stop_scroll = function(SCROLL, "ScrollStopResult scrollSessionStop(")
start_scroll = function(SCROLL, "ScrollStartResult scrollSessionStart(")
step_scroll = function(SCROLL, "bool scrollSessionStep(")
seek_scroll = function(SCROLL, "bool scrollSessionSeek(")
service_scroll = function(SCROLL, "void serviceScrollSession(")
assert 'setRuntimeOutputMode("control")' in set_mode
assert saved_face.index("applyPackedFrameQueued(") < saved_face.index('setRuntimeOutputMode("control")')
assert 'setRuntimeOutputMode("control")' in stop_scroll
assert start_scroll.index("scrollSessionStart(") < start_scroll.index('setRuntimeOutputMode("text")')
assert 'setRuntimeOutputMode("text")' in step_scroll
assert 'setRuntimeOutputMode("text")' in seek_scroll
assert "setRuntimeOutput" not in service_scroll

# Color and brightness are presentation attributes and keep stream ownership.
assert "setRuntimeOutput" not in function(RENDERER, "bool setColor(")
assert "setRuntimeOutput" not in function(RENDERER, "void setBrightness(")
assert 'setRuntimeOutputMode("control")' in function(RENDERER, "void applyBlankFrame(")

print("PASS: output mode/session parsing, status+preview exposure, takeover, and color/brightness stability")
