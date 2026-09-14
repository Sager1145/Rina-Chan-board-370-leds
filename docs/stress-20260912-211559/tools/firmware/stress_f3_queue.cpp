// F3: packed-frame pending queue vs offered SET_FRAME rates, real protocol +
// led_renderer.cpp with a fake clock. Loop order mirrors main.cpp loop().
// Build: test/host/stress_build.sh test/host/stress_f3_queue.cpp /tmp/f3 && /tmp/f3
#include "../../src/protocol.cpp"
#include "stress_common.h"

static CaseLog L;
static FakeTransport T(rinalink::Carrier::Tcp);

static Bytes setFrame(uint16_t marker) {
    Bytes p{2, 0};
    Bytes f(47, 0);
    f[0] = static_cast<uint8_t>(marker & 0xFF); f[1] = static_cast<uint8_t>(marker >> 8); f[2] = 1;
    p.insert(p.end(), f.begin(), f.end());
    return p;
}
static uint16_t shownMarker() { return static_cast<uint16_t>(runtimeFrameBits()[0] | (runtimeFrameBits()[1] << 8)); }

struct Result { unsigned offered = 0, okReplies = 0, presented = 0, maxQueue = 0, orderViolations = 0, staleViolations = 0; uint32_t minGap = UINT32_MAX, maxLatency = 0; uint32_t dropped = 0, queued = 0, dequeued = 0; bool finalShown = false; };

static Result run(unsigned hz, uint64_t seed, uint32_t durationMs, uint32_t loopMs, bool burst = false) {
    TestClient c; c.connect(T);
    auto& rs = runtimeState();
    rs.framesDropped = rs.framesQueued = rs.framesDequeued = 0;
    XorShift rng(seed);
    Result R;
    std::map<uint16_t, uint32_t> arrivedAt;
    static uint16_t markerBase = 1; // markers stay unique across runs
    uint16_t marker = markerBase, lastOffered = 0, last = shownMarker();
    const uint16_t firstMarker = marker;
    uint32_t lastPresent = 0;
    uint32_t start = millis(), nextArrival = start + 50;
    const double periodMs = 1000.0 / hz;
    double acc = nextArrival;
    auto observe = [&] {
        R.maxQueue = std::max<unsigned>(R.maxQueue, queuedPackedFrameCount());
        uint16_t m = shownMarker();
        if (m == last) return;
        uint32_t now = millis();
        ++R.presented;
        if (m != lastOffered) ++R.staleViolations;  // a presentation must be the newest offered frame
        if (m < last && last >= firstMarker) ++R.orderViolations;
        if (lastPresent) R.minGap = std::min(R.minGap, now - lastPresent);
        R.maxLatency = std::max(R.maxLatency, now - arrivedAt[m]);
        lastPresent = now; last = m;
    };
    while (millis() - start < durationMs + 300) {
        servicePackedFrameQueue(); observe();
        unsigned pushedThisLoop = 0;
        while (millis() - start < durationMs && millis() >= nextArrival && pushedThisLoop < 8) {
            unsigned n = burst ? 100 : 1;
            for (unsigned i = 0; i < n && pushedThisLoop < 8; ++i, ++pushedThisLoop) {
                c.push(frameOf(0x10, static_cast<uint8_t>(1 + (marker % 250)), setFrame(marker)));
                arrivedAt[marker] = millis(); lastOffered = marker; ++marker; ++R.offered;
            }
            acc += periodMs;
            nextArrival = static_cast<uint32_t>(acc) + (rng.below(3)) - 1; // +-1 ms jitter
        }
        serviceProtocol(); observe();
        for (auto& f : c.take()) if (f.type == 0x90 && f.seq != 0) ++R.okReplies;
        advanceMs(loopMs);
    }
    R.dropped = rs.framesDropped; R.queued = rs.framesQueued; R.dequeued = rs.framesDequeued;
    R.finalShown = shownMarker() == lastOffered;
    markerBase = marker;
    rinalink::transportUnregisterClient(c.id); serviceProtocol();
    return R;
}

int main() {
    L.layer = "fw-frame-queue"; L.evidence = "logs/firmware/f3_queue.log";
    protocolBegin();
    initRuntimeScrollFrameBuffer();
    L.check("F3-CONST", PACKED_FRAME_QUEUE_DEPTH == 3 && PACKED_FRAME_MIN_INTERVAL_MS == 33,
            "PACKED_FRAME_QUEUE_DEPTH=3 (array) PACKED_FRAME_MIN_INTERVAL_MS=33");
    for (unsigned hz : {10U, 25U, 50U, 75U, 100U}) {
        for (uint32_t loopMs : {2U, 5U}) {
            const uint64_t seed = 0xF300 + hz;
            Result R = run(hz, seed, 10000, loopMs);
            bool conserve = R.offered == R.presented + R.dropped;
            bool ok = R.maxQueue <= 1 && R.orderViolations == 0 && R.staleViolations == 0 && R.minGap >= 33 && R.finalShown &&
                      conserve && R.okReplies == R.offered;            L.check("F3-RATE-" + std::to_string(hz) + "HZ-LOOP" + std::to_string(loopMs) + "MS", ok,
                    "offered=" + std::to_string(R.offered) + " okReplies=" + std::to_string(R.okReplies) + " presented=" + std::to_string(R.presented) +
                        " dropped=" + std::to_string(R.dropped) + " queuedCtr=" + std::to_string(R.queued) + " dequeuedCtr=" + std::to_string(R.dequeued) +
                        " maxPending=" + std::to_string(R.maxQueue) + " minGapMs=" + std::to_string(R.minGap == UINT32_MAX ? 0 : R.minGap) +
                        " maxLatencyMs=" + std::to_string(R.maxLatency) + " presentedHz=" + std::to_string(R.presented / 10.0) +
                        " finalMarkerShown=" + std::to_string(R.finalShown) + " stale=" + std::to_string(R.staleViolations) + " conserved=" + std::to_string(conserve),
                    std::to_string(hz) + "Hz/10s", "0x" + hex64(seed));
        }
    }
    { Result R = run(10, 0xF3B, 1000, 2, true);
      // Within one pass the first frame may publish immediately while 7 more replace the pending
      // slot, so "stale vs newest pushed" is not meaningful here; final frame + conservation are.
      L.check("F3-BURST-8-PER-PASS", R.maxQueue <= 1 && R.finalShown && R.offered == R.presented + R.dropped && R.orderViolations == 0 && R.minGap >= 33,
              "offered=" + std::to_string(R.offered) + " presented=" + std::to_string(R.presented) + " dropped=" + std::to_string(R.dropped) +
                  " finalShown=" + std::to_string(R.finalShown) +
                  " maxPending=" + std::to_string(R.maxQueue) + " order=" + std::to_string(R.orderViolations) + " minGapMs=" + std::to_string(R.minGap),
              "8 frames/pass x10Hz", "0xf3b"); }
    // Expectation confirmed: array depth 3 is advertised, effective pending depth is 1.
    { TestClient c; c.connect(T);
      advanceMs(40);
      c.request(0x10, 6, setFrame(9000));
      auto rep = c.request(0x10, 7, setFrame(9001)); // second within 33 ms -> pending
      auto d = parse(rep.second);
      int depth = d["queueDepth"] | -1, count = d["queueCount"] | -1;
      L.check("F3-STATUS-QUEUEDEPTH-SEMANTICS", depth == 3 && count == 1,
              "SET_FRAME reply queueDepth=" + std::to_string(depth) + " queueCount=" + std::to_string(count) +
                  " (advertised depth 3; effective pending depth 1 latest-only)");
      rinalink::transportUnregisterClient(c.id); serviceProtocol(); }
    std::cout << "SUMMARY F3 pass=" << L.pass << " fail=" << L.fail << std::endl;
    return 0;
}
