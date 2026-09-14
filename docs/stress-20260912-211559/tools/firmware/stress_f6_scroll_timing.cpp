// F6: Core-1 scroll timeline under CPU stalls. Runs the REAL scrollRenderTask()
// loop (scroll.cpp) + scrollSessionTickCursorLocked + renderCurrentFrameToLedStrip
// with a fake clock; the ulTaskNotifyTake hook injects stalls and ends the run.
// Build: test/host/stress_build.sh test/host/stress_f6_scroll_timing.cpp /tmp/f6 && /tmp/f6
#include "../../src/scroll.cpp"
#include "faces.h"
#include <cinttypes>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

extern uint64_t g_fakeMicros;
extern uint32_t g_fakeRefreshUs;
static unsigned gPass = 0, gFail = 0;
static void rec(const std::string& id, const std::string& load, bool ok, std::string m) {
    for (auto& c : m) if (c == ',') c = ';';
    (ok ? gPass : gFail)++;
    std::cout << "CASE," << id << ",fw-scroll-timing," << load << ",-," << (ok ? "PASS" : "FAIL") << "," << m << ",logs/firmware/f6_scroll_timing.log" << std::endl;
}
struct StopRun {};
struct Plan { uint32_t startMs, endMs; std::vector<std::pair<uint32_t, uint32_t>> stalls; size_t nextStall = 0; std::vector<uint32_t> ticks; uint32_t lastAdv = 0; };
static Plan* gPlan = nullptr;
static void hook(uint32_t ticks) {
    g_fakeMicros += static_cast<uint64_t>(ticks) * 1000ULL;
    Plan& p = *gPlan;
    const uint32_t adv = readLedPresentedSample().scrollAdvanceSeq;
    for (uint32_t k = p.lastAdv; k < adv; ++k) p.ticks.push_back(millis() - p.startMs);
    p.lastAdv = adv;
    if (p.nextStall < p.stalls.size() && millis() - p.startMs >= p.stalls[p.nextStall].first) {
        g_fakeMicros += static_cast<uint64_t>(p.stalls[p.nextStall].second) * 1000ULL; // Core 1 not scheduled
        ++p.nextStall;
    }
    if (millis() >= p.endMs) throw StopRun{};
}
static void loadTimeline(uint16_t frames) {
    ScrollUploadMeta meta; meta.timelineId = "f6"; meta.totalFrames = frames;
    ScrollUploadTxn txn = scrollSessionBeginUpload(meta);
    std::vector<uint8_t> buf(static_cast<size_t>(frames) * FRAME_BYTES, 0);
    for (uint16_t i = 0; i < frames; ++i) buf[static_cast<size_t>(i) * FRAME_BYTES] = static_cast<uint8_t>(i);
    scrollSessionWriteFrames(txn, 0, buf.data(), frames);
    scrollSessionCommitUpload(txn, frames, false, 100, 0);
}
struct Out { double speed; long lost; unsigned maxBurst; double postSpeed; unsigned adv; };
static Out run(uint16_t intervalMs, std::vector<std::pair<uint32_t, uint32_t>> stalls, uint32_t durationMs, uint32_t refreshUs) {
    g_fakeRefreshUs = refreshUs;
    scrollSessionSetLoop(true);
    loadTimeline(3000);
    const uint32_t base = readLedPresentedSample().scrollAdvanceSeq;
    Plan p; p.stalls = stalls; p.lastAdv = base;
    scrollSessionStart(intervalMs, false, 0);
    p.startMs = millis(); p.endMs = p.startMs + durationMs;
    gPlan = &p; g_fakeNotifyTakeHook = hook;
    try { scrollRenderTask(nullptr); } catch (const StopRun&) {}
    g_fakeNotifyTakeHook = nullptr;
    Out o{};
    o.adv = static_cast<unsigned>(p.ticks.size());
    const double expected = static_cast<double>(millis() - p.startMs) / intervalMs;
    o.speed = o.adv / expected;
    o.lost = static_cast<long>(expected + 0.5) - static_cast<long>(o.adv);
    // max advances inside any window of one interval
    size_t j = 0; for (size_t i = 0; i < p.ticks.size(); ++i) { while (p.ticks[i] - p.ticks[j] >= intervalMs) ++j; o.maxBurst = std::max<unsigned>(o.maxBurst, static_cast<unsigned>(i - j + 1)); }
    if (!stalls.empty()) {
        const uint32_t from = stalls.back().first + stalls.back().second + 1000, to = from + 1000;
        unsigned n = 0; for (auto t : p.ticks) if (t >= from && t < to) ++n;
        o.postSpeed = n / (1000.0 / intervalMs);
    }
    stopFirmwareScroll(false, false, false);
    return o;
}
static std::string fmt(double v) { char b[32]; std::snprintf(b, sizeof b, "%.3f", v); return b; }

int main() {
    initRuntimeScrollFrameBuffer();
    rec("F6-CONST", "-", MIN_SCROLL_INTERVAL_MS == 17 && SCROLL_DRIFT_RESET_INTERVALS == 4 && MAX_SCROLL_FRAMES == 3072,
        "MIN_SCROLL_INTERVAL_MS=17 SCROLL_DRIFT_RESET_INTERVALS=4");
    for (uint32_t refresh : {11100U, 16000U, 20000U}) {
        Out o = run(17, {}, 10000, refresh);
        bool ok = o.speed > 0.99 && o.speed < 1.01;
        rec("F6-STEADY-17MS-RENDER" + std::to_string(refresh / 1000) + "MS", "10s", ok,
            "advances=" + std::to_string(o.adv) + " speedRatio=" + fmt(o.speed) + " lostFrames=" + std::to_string(o.lost) + " maxBurstPerInterval=" + std::to_string(o.maxBurst));
    }
    for (uint16_t interval : {17, 100}) {
        for (uint32_t stall : {0U, 50U, 100U, 500U}) {
            std::vector<std::pair<uint32_t, uint32_t>> st; if (stall) st.push_back({2000, stall});
            Out o = run(interval, st, 5000, 11100);
            const uint32_t threshold = interval * SCROLL_DRIFT_RESET_INTERVALS;
            // Design expectation: stall under the drift threshold (minus one render) is fully caught up;
            // beyond it, at most ceil(stall/interval) frames are skipped and playback resumes at 1.0x.
            bool under = stall + 13 <= threshold;
            long bound = under ? 1 : static_cast<long>((stall + interval - 1) / interval) + 1;
            bool ok = std::labs(o.lost) <= bound && (stall == 0 || (o.postSpeed > 0.95 && o.postSpeed < 1.05));
            rec("F6-STALL-" + std::to_string(stall) + "MS-INTERVAL" + std::to_string(interval), std::to_string(stall) + "ms@" + std::to_string(interval), ok,
                "advances=" + std::to_string(o.adv) + " speedRatio=" + fmt(o.speed) + " timelineOffsetFrames=" + std::to_string(o.lost) +
                    " (" + std::to_string(o.lost * interval) + " ms) maxBurstPerInterval=" + std::to_string(o.maxBurst) + " postStallSpeed=" + fmt(o.postSpeed) +
                    " driftThresholdMs=" + std::to_string(threshold));
        }
    }
    { std::vector<std::pair<uint32_t, uint32_t>> st; for (uint32_t t = 500; t < 9500; t += 250) st.push_back({t, 50});
      Out o = run(17, st, 10000, 11100);
      rec("F6-REPEATED-50MS-EVERY-250MS-INTERVAL17", "36 stalls", o.speed > 0.95,
          "advances=" + std::to_string(o.adv) + " speedRatio=" + fmt(o.speed) + " lostFrames=" + std::to_string(o.lost) + " maxBurstPerInterval=" + std::to_string(o.maxBurst)); }
    { std::vector<std::pair<uint32_t, uint32_t>> st; for (uint32_t t = 500; t < 9500; t += 250) st.push_back({t, 80});
      Out o = run(17, st, 10000, 11100);
      rec("F6-REPEATED-80MS-EVERY-250MS-INTERVAL17", "36 stalls", o.speed > 0.95,
          "advances=" + std::to_string(o.adv) + " speedRatio=" + fmt(o.speed) + " lostFrames=" + std::to_string(o.lost) + " maxBurstPerInterval=" + std::to_string(o.maxBurst)); }
    std::cout << "SUMMARY F6 pass=" << gPass << " fail=" << gFail << std::endl;
    return 0;
}
