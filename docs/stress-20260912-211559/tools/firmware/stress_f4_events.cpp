// F4: event fan-out convergence after a single zero-byte event send failure.
// Real protocol.cpp serviceProtocolEvents(); fake carrier drops chosen events.
// Build: test/host/stress_build.sh test/host/stress_f4_events.cpp /tmp/f4 && /tmp/f4
#include "../../src/protocol.cpp"
#include "stress_common.h"

extern bool g_fakeWifiChanged, g_fakeWifiScanReady;
extern PowerStatus g_fakePower;
static CaseLog L;
static FakeTransport T(rinalink::Carrier::Tcp);
static FakeTransport TB(rinalink::Carrier::Ble, 160);
static std::map<uint8_t, int> dropNext;            // event type -> remaining drops
static std::map<uint8_t, bool> dropAll;             // event type -> drop every one
static uint32_t dropAllUntilMs = 0;                  // drop every event until time (CCCD not yet written)

static bool hook(uint8_t, const uint8_t* d, size_t, bool isEvent) {
    if (!isEvent) return false;
    if (millis() < dropAllUntilMs) return true;
    if (dropAll[d[1]]) return true;
    auto it = dropNext.find(d[1]);
    if (it != dropNext.end() && it->second > 0) { --it->second; return true; }
    return false;
}

struct Seen { long statusV = -1; long previewSeq = -1; unsigned status = 0, preview = 0, power = 0, wifi = 0, scan = 0; bool powerCharging = false; };
static void drain(TestClient& c, Seen& s) {
    for (auto& f : c.take()) {
        if (f.seq != 0) continue;
        std::string body(f.payload.begin(), f.payload.end());
        auto d = parse(body);
        switch (f.type) {
        case 0x91: ++s.status; s.statusV = d["v"] | -1L; break;
        case 0x90: ++s.preview; s.previewSeq = d["presentedSeq"] | -1L; break;
        case 0x92: ++s.power; s.powerCharging = d["power"]["charging"] | false; break;
        case 0x93: ++s.wifi; break;
        case 0x95: ++s.scan; break;
        default: break;
        }
    }
}
static void runMs(uint32_t ms, std::vector<std::pair<TestClient*, Seen*>> cs) {
    for (uint32_t t = 0; t < ms; t += 2) { serviceProtocol(); for (auto& p : cs) drain(*p.first, *p.second); advanceMs(2); }
}
static void newTimelineAndPresent(uint16_t frames) {
    ScrollUploadMeta meta; meta.timelineId = "f4"; meta.totalFrames = frames;
    ScrollUploadTxn txn = scrollSessionBeginUpload(meta);
    Bytes buf(frames * FRAME_BYTES, 0);
    for (uint16_t i = 0; i < frames; ++i) buf[i * FRAME_BYTES] = static_cast<uint8_t>(i + 1);
    scrollSessionWriteFrames(txn, 0, buf.data(), frames);
    scrollSessionCommitUpload(txn, frames, true, 100, 10);
    startFirmwareScroll(100, 10);
    scrollSessionSetUserPaused(true); // hold: no further presentations
    renderCurrentFrameToLedStrip();   // Core-1 latch publishes the presented sample
}

int main() {
    L.layer = "fw-events"; L.evidence = "logs/firmware/f4_events.log";
    protocolBegin();
    initRuntimeScrollFrameBuffer();
    T.dropHook = hook; TB.dropHook = hook;
    TestClient A, B; A.connect(T, false); B.connect(T, true);
    Seen sa;
    runMs(600, {{&A, &sa}});
    L.check("F4-BASELINE-CONVERGE", sa.statusV == static_cast<long>(runtimeStateVersion()) && sa.preview >= 1,
            "statusV=" + std::to_string(sa.statusV) + " boardV=" + std::to_string(runtimeStateVersion()));

    // E1: one EV_STATUS dropped, state then unchanged.
    dropNext[0x91] = 1;
    B.cmd(1, "{\"cmd\":\"set_brightness\",\"raw\":123}");  // another controller changes state
    runMs(5000, {{&A, &sa}});
    const long boardV = runtimeStateVersion();
    L.check("F4-STATUS-SINGLE-DROP-CONVERGE", sa.statusV == boardV,
            "clientLastV=" + std::to_string(sa.statusV) + " boardV=" + std::to_string(boardV) + " waitedMs=5000 dropped=1 lastStatusVersion advanced on failed send");
    { auto rep = A.request(0x02, 2, bytesOf("{\"lite\":true}")); auto d = parse(rep.second); long v = d["v"] | -1L;
      L.check("F4-STATUS-QUERY-RECOVERS", v == boardV, "GET_STATUS v=" + std::to_string(v)); }

    // E1b: dropped intermediate event followed by a later successful one converges.
    dropNext[0x91] = 1;
    B.cmd(3, "{\"cmd\":\"set_brightness\",\"raw\":90}"); runMs(400, {{&A, &sa}});
    B.cmd(4, "{\"cmd\":\"set_brightness\",\"raw\":91}"); runMs(1000, {{&A, &sa}});
    L.check("F4-STATUS-INTERMEDIATE-DROP-ALLOWED", sa.statusV == static_cast<long>(runtimeStateVersion()),
            "clientLastV=" + std::to_string(sa.statusV) + " boardV=" + std::to_string(runtimeStateVersion()));

    // E2: final EV_PREVIEW_SYNC dropped after a presentation, then idle.
    runMs(500, {{&A, &sa}});
    dropNext[0x90] = 1;
    newTimelineAndPresent(20);
    const long boardSeq = readLedPresentedSample().presentedSeq;
    runMs(5000, {{&A, &sa}});
    L.check("F4-PREVIEW-SINGLE-DROP-CONVERGE", sa.previewSeq == boardSeq,
            "clientLastPresentedSeq=" + std::to_string(sa.previewSeq) + " boardPresentedSeq=" + std::to_string(boardSeq) + " waitedMs=5000");
    { auto rep = A.request(0x05, 5, {}); auto d = parse(rep.second); long s = d["presentedSeq"] | -1L;
      L.check("F4-PREVIEW-QUERY-RECOVERS", s == boardSeq, "GET_PREVIEW_SYNC presentedSeq=" + std::to_string(s)); }

    // E3: BLE central whose CCCD arrives 300 ms after registration; board idle.
    { TestClient C; Seen sc; dropAllUntilMs = millis() + 300; C.connect(TB, false);
      runMs(5000, {{&C, &sc}});
      dropAllUntilMs = 0;
      L.check("F4-BLE-CCCD-LATE-STATUS", sc.status >= 1 && sc.statusV == static_cast<long>(runtimeStateVersion()),
              "EV_STATUS received=" + std::to_string(sc.status) + " EV_PREVIEW_SYNC received=" + std::to_string(sc.preview) +
                  " EV_POWER received=" + std::to_string(sc.power) + " over 5000 ms idle");
      L.check("F4-BLE-CCCD-LATE-PREVIEW", sc.preview >= 1, "EV_PREVIEW_SYNC received=" + std::to_string(sc.preview));
      rinalink::transportUnregisterClient(C.id); serviceProtocol(); }

    // E4: one-shot Wi-Fi events.
    { dropNext[0x93] = 1; g_fakeWifiChanged = true; unsigned before = sa.wifi; runMs(3000, {{&A, &sa}});
      L.check("F4-WIFI-EVENT-SINGLE-DROP", sa.wifi > before, "EV_WIFI received=" + std::to_string(sa.wifi - before) + " (one-shot; not retried)");
      auto rep = A.cmd(6, "{\"cmd\":\"wifi_status\"}");
      L.check("F4-WIFI-STATUS-QUERY-RECOVERS", rep.first == 0x81, "replyType=" + std::to_string(rep.first)); }
    { A.cmd(7, "{\"cmd\":\"wifi_scan\"}"); dropNext[0x95] = 1; g_fakeWifiScanReady = true; unsigned before = sa.scan; runMs(3000, {{&A, &sa}});
      L.check("F4-WIFI-SCAN-EVENT-SINGLE-DROP", sa.scan > before, "EV_WIFI_SCAN received=" + std::to_string(sa.scan - before) + " requester cleared");
      auto rep = A.cmd(8, "{\"cmd\":\"wifi_scan_result\"}");
      L.check("F4-WIFI-SCAN-RESULT-QUERY-RECOVERS", rep.first == 0x81, "replyType=" + std::to_string(rep.first)); }

    // E5: charging flip event dropped -> periodic 1 Hz power converges.
    { runMs(1500, {{&A, &sa}});
      dropNext[0x92] = 1; g_fakePower.chargeValid = true; g_fakePower.charging = true;
      uint32_t t0 = millis(); uint32_t conv = 0;
      for (uint32_t t = 0; t < 3000 && !conv; t += 2) { serviceProtocol(); drain(A, sa); if (sa.powerCharging) conv = millis() - t0; advanceMs(2); }
      L.check("F4-POWER-FLIP-DROP-CONVERGE", conv > 0 && conv <= 1002, "convergedAfterMs=" + std::to_string(conv)); }

    // E6: seeded random drop storm during changes, then idle: count non-converged trials.
    { XorShift r(0xF4F4); unsigned trials = 200, stuckStatus = 0, stuckPreview = 0;
      for (unsigned i = 0; i < trials; ++i) {
          for (int k = 0; k < 5; ++k) {
              dropNext[0x91] = r.below(2); dropNext[0x90] = r.below(2);
              B.cmd(static_cast<uint8_t>(10 + k), "{\"cmd\":\"set_brightness\",\"raw\":" + std::to_string(20 + r.below(150)) + "}");
              if (r.below(2)) renderCurrentFrameToLedStrip(); else { scrollSessionSeek(static_cast<uint16_t>(r.below(20))); renderCurrentFrameToLedStrip(); }
              runMs(10 + r.below(300), {{&A, &sa}});
          }
          dropNext.clear();
          runMs(2000, {{&A, &sa}});
          if (sa.statusV != static_cast<long>(runtimeStateVersion())) ++stuckStatus;
          if (sa.previewSeq != static_cast<long>(readLedPresentedSample().presentedSeq)) ++stuckPreview;
          A.request(0x02, 30, {}); A.request(0x05, 31, {}); // app-style resync between trials
          sa.statusV = runtimeStateVersion(); sa.previewSeq = readLedPresentedSample().presentedSeq;
      }
      L.check("F4-DROP-STORM-NONCONVERGENCE", stuckStatus == 0 && stuckPreview == 0,
              "trials=200 stuckStatus=" + std::to_string(stuckStatus) + " stuckPreview=" + std::to_string(stuckPreview) + " dropP=0.5 per burst change",
              "200 trials", "0xf4f4"); }
    std::cout << "SUMMARY F4 pass=" << L.pass << " fail=" << L.fail << std::endl;
    return 0;
}
