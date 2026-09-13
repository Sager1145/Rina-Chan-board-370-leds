#!/usr/bin/env python3
"""Exercise the production presented-frame sequence bookkeeping with host fakes."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src/led_renderer.cpp").read_text()


def function(signature: str) -> str:
    start = SOURCE.index(signature)
    brace = SOURCE.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]


code = r'''
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>

constexpr unsigned PACKED_FRAME_REASON_CHARS = 64;
constexpr unsigned MAX_SCROLL_TIMELINE_ID_CHARS = 47;

enum class LedPresentationSource : uint8_t {
    Unknown = 0, ScrollTick, ScrollStart, ScrollStep, ManualFrame, Clear, Overlay
};

struct LedPresentationContext {
    bool valid = false;
    LedPresentationSource source = LedPresentationSource::Unknown;
    char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {};
    uint16_t frameIndex = 0, frameCount = 0, nominalIntervalMs = 100;
    uint8_t uiFps = 0;
    bool firmwareScrollActive = false, firmwareScrollPaused = false;
    bool userPaused = false, systemPaused = false, rateEligible = false;
    char reason[PACKED_FRAME_REASON_CHARS] = {};
};

struct LedPresentedSample {
    bool valid = false;
    uint32_t presentedSeq = 0, scrollAdvanceSeq = 0;
    LedPresentationSource source = LedPresentationSource::Unknown;
    char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {};
    uint16_t presentedFrameIndex = 0, presentedFrameCount = 0, nominalIntervalMs = 100;
    uint8_t uiFps = 0;
    bool firmwareScrollActive = false, firmwareScrollPaused = false;
    bool userPaused = false, systemPaused = false, rateEligible = false;
    uint64_t renderStartUs = 0, presentedAtUs = 0;
    uint32_t renderDurationUs = 0;
    char reason[PACKED_FRAME_REASON_CHARS] = {};
};

using portMUX_TYPE = int;
static portMUX_TYPE ledPresentationMux = 0;
static LedPresentedSample latestPresentedSample;
static uint32_t presentedSeq = 0;
static uint32_t scrollAdvanceSeq = 0;
#define portENTER_CRITICAL(x) ((void)(x))
#define portEXIT_CRITICAL(x) ((void)(x))
#define RINA_LOG_TRACE 0
#define RLOG_TRACE(...) ((void)0)
bool rinaLogShouldEmit(int) { return false; }
bool rinaLogRateReady(uint32_t&, uint32_t) { return false; }
size_t strlcpy(char* dst, const char* src, size_t size) {
    if (size == 0) return std::strlen(src);
    const size_t n = std::strlen(src);
    const size_t copied = n < size - 1 ? n : size - 1;
    std::memcpy(dst, src, copied);
    dst[copied] = '\0';
    return n;
}
'''
code += "\n" + function("static void publishLedPresentedSample(")
code += r'''
int main() {
    LedPresentationContext ctx;
    publishLedPresentedSample(ctx, 1, 2);
    assert(!latestPresentedSample.valid);

    ctx.valid = true;
    ctx.source = LedPresentationSource::ScrollStart;
    std::strcpy(ctx.timelineId, "timeline-a");
    ctx.frameIndex = 0;
    ctx.frameCount = 3;
    publishLedPresentedSample(ctx, 10000000000ULL, 10000000123ULL);
    assert(latestPresentedSample.presentedSeq == 1);
    assert(latestPresentedSample.scrollAdvanceSeq == 0);
    assert(latestPresentedSample.presentedAtUs == 10000000123ULL);
    assert(latestPresentedSample.renderDurationUs == 123);

    ctx.source = LedPresentationSource::ScrollTick;
    ctx.frameIndex = 1;
    ctx.rateEligible = true;
    publishLedPresentedSample(ctx, 10000100000ULL, 10000100120ULL);
    assert(latestPresentedSample.presentedSeq == 2);
    assert(latestPresentedSample.scrollAdvanceSeq == 1);

    ctx.source = LedPresentationSource::ManualFrame;
    publishLedPresentedSample(ctx, 10000200000ULL, 10000200120ULL);
    assert(latestPresentedSample.presentedSeq == 3);
    assert(latestPresentedSample.scrollAdvanceSeq == 1);

    // Sequence arithmetic is deliberately uint32 modulo arithmetic.
    scrollAdvanceSeq = UINT32_MAX;
    ctx.source = LedPresentationSource::ScrollTick;
    publishLedPresentedSample(ctx, 10000300000ULL, 10000300120ULL);
    assert(latestPresentedSample.scrollAdvanceSeq == 0);
}
'''

with tempfile.TemporaryDirectory(prefix="rina-presentation-test-") as directory:
    source = Path(directory) / "test.cpp"
    binary = Path(directory) / "test"
    source.write_text(code)
    subprocess.run(
        ["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)],
        check=True,
    )
    subprocess.run([str(binary)], check=True)

print("PASS: presented sequence, scroll-only advance sequence, 64-bit monotonic timestamps")
