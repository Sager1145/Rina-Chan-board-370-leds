// F1: inbound framing robustness through the REAL protocol.cpp dispatch path
// (transportPushInbound -> serviceProtocol -> processClientInbound -> dispatch).
// Build: test/host/stress_build.sh test/host/stress_f1_parser.cpp /tmp/f1 asan
// Run:   /tmp/f1 [fuzzIterations=1000000] [seed=0xC0FFEE]
#include "../../src/protocol.cpp"
#include "stress_common.h"
#include <chrono>
#include <deque>

static CaseLog L;
static FakeTransport T(rinalink::Carrier::Tcp);
static TestClient C;

static void fresh() {
    if (C.id.slot < MAX_CLIENTS) { rinalink::transportUnregisterClient(C.id); serviceProtocol(); }
    C = TestClient{};
    if (!C.connect(T)) { std::cerr << "connect failed\n"; std::exit(2); }
}
static unsigned groups(const std::vector<RxFrame>& fs) { unsigned n = 0; for (auto& f : fs) if (!(f.flags & FLAG_MORE)) ++n; return n; }
static Bytes setFramePayload(uint8_t marker, size_t frameBytes = 47, uint8_t reasonLen = 0) {
    Bytes p{0, reasonLen};
    for (uint8_t i = 0; i < reasonLen; ++i) p.push_back('r');
    Bytes f(frameBytes, 0);
    if (!f.empty()) f[0] = marker;
    p.insert(p.end(), f.begin(), f.end());
    return p;
}
// TCP-style delivery honoring transportInboundFree back-pressure.
static void deliver(const Bytes& b, unsigned maxPasses = 100) {
    size_t off = 0;
    for (unsigned pass = 0; off < b.size() && pass < maxPasses; ++pass) {
        size_t freeB = rinalink::transportInboundFree(C.id);
        size_t n = std::min(freeB, b.size() - off);
        if (n) { rinalink::transportPushInbound(C.id, b.data() + off, n); off += n; }
        serviceProtocol();
    }
}
static int errCode(const std::string& body) { auto d = parse(body); return d["code"] | 0; }

int main(int argc, char** argv) {
    const unsigned long iters = argc > 1 ? std::strtoul(argv[1], nullptr, 0) : 1000000UL;
    const uint64_t seed = argc > 2 ? std::strtoull(argv[2], nullptr, 0) : 0xC0FFEEULL;
    L.layer = "fw-parser"; L.evidence = "logs/firmware/f1_parser.log";
    protocolBegin();
    initRuntimeScrollFrameBuffer();
    fresh();

    // --- constants vs expectation --------------------------------------------------
    L.check("F1-CONST", FRAME_MAGIC == 0xA5 && FRAME_HEADER_BYTES == 6 && MAX_PAYLOAD_BYTES == 4096 &&
                            INBOUND_BUFFER_BYTES == 4166 && MAX_FRAMES_PER_CLIENT_PASS == 8 && FRAME_BYTES == 47,
            "magic=0xA5 hdr=6 maxPayload=4096 inbound=" + std::to_string(INBOUND_BUFFER_BYTES) +
                " perPass=" + std::to_string(MAX_FRAMES_PER_CLIENT_PASS));

    // --- F1-SPLIT: split a 4-request stream at every offset ---------------------------
    Bytes stream;
    for (auto& b : {frameOf(0x06, 1, {}), frameOf(0x11, 2, {}), frameOf(0x10, 3, setFramePayload(7)),
                    jsonFrame(0x01, 4, "{\"cmd\":\"set_brightness\",\"raw\":60}")})
        stream.insert(stream.end(), b.begin(), b.end());
    const uint8_t wantType[] = {0x86, 0x91, 0x90, 0x81};
    auto verify4 = [&](const std::vector<RxFrame>& fs) {
        if (fs.size() != 4) return false;
        for (int i = 0; i < 4; ++i) if (fs[i].seq != i + 1 || fs[i].type != wantType[i]) return false;
        return true;
    };
    unsigned splitFail = 0;
    for (size_t k = 0; k <= stream.size(); ++k) {
        fresh();
        C.push(Bytes(stream.begin(), stream.begin() + k)); serviceProtocol();
        C.push(Bytes(stream.begin() + k, stream.end())); serviceProtocol(); serviceProtocol();
        if (!verify4(C.take())) ++splitFail;
    }
    L.check("F1-SPLIT-EVERY-OFFSET", splitFail == 0, "offsets=" + std::to_string(stream.size() + 1) + " failures=" + std::to_string(splitFail));
    fresh();
    for (uint8_t b : stream) { C.push(Bytes{b}); serviceProtocol(); }
    L.check("F1-SPLIT-BYTE-BY-BYTE", verify4(C.take()), "bytes=" + std::to_string(stream.size()));

    // --- F1-GLUE: 20 glued PINGs, per-pass budget ------------------------------------
    fresh();
    Bytes glued;
    for (int i = 1; i <= 20; ++i) { auto f = frameOf(0x06, static_cast<uint8_t>(i), {}); glued.insert(glued.end(), f.begin(), f.end()); }
    C.push(glued);
    std::vector<unsigned> perPass;
    for (int p = 0; p < 4; ++p) { serviceProtocol(); perPass.push_back(groups(C.take())); }
    L.check("F1-GLUE-BUDGET", perPass[0] == 8 && perPass[1] == 8 && perPass[2] == 4 && perPass[3] == 0,
            "perPass=" + std::to_string(perPass[0]) + "/" + std::to_string(perPass[1]) + "/" + std::to_string(perPass[2]) + "/" + std::to_string(perPass[3]));

    // --- F1-BADMAGIC ------------------------------------------------------------------
    fresh();
    { Bytes g(1000); XorShift r(1); for (auto& x : g) { x = static_cast<uint8_t>(r.below(256)); if (x == 0xA5) x = 0; }
      C.push(g); C.push(frameOf(0x06, 9, {})); serviceProtocol();
      auto rep = C.replyFor(9); L.check("F1-BADMAGIC-1000B-THEN-PING", rep.first == 0x86, "replyType=" + std::to_string(rep.first)); }
    fresh();
    C.push(Bytes{0xA5, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x13}); C.push(frameOf(0x06, 10, {})); serviceProtocol();
    { auto rep = C.replyFor(10); L.check("F1-MAGIC-LEN65535-HEADER-THEN-PING", rep.first == 0x86, "replyType=" + std::to_string(rep.first)); }

    // --- F1-LEN: payload length boundaries (unknown type 0x7E -> ERR 400) -------------
    for (size_t len : {0UL, 4095UL, 4096UL}) {
        fresh();
        deliver(frameOf(0x7E, 20, Bytes(len, 0)));
        auto rep = C.replyFor(20);
        C.push(frameOf(0x06, 21, {})); serviceProtocol();
        auto ping = C.replyFor(21);
        L.check("F1-LEN-" + std::to_string(len), rep.first == 0xFF && errCode(rep.second) == 400 && ping.first == 0x86,
                "reply=" + std::to_string(rep.first) + " code=" + std::to_string(errCode(rep.second)) + " nextPing=" + std::to_string(ping.first));
    }
    for (size_t len : {4097UL, 65535UL}) {
        fresh();
        Bytes f = frameOf(0x7E, 22, {});
        f[4] = static_cast<uint8_t>(len & 0xFF); f[5] = static_cast<uint8_t>(len >> 8);
        f.insert(f.end(), len, 0);
        deliver(f, 1000);
        auto rep = C.replyFor(22);
        C.push(frameOf(0x06, 23, {})); serviceProtocol();
        auto ping = C.replyFor(23);
        L.check("F1-LEN-" + std::to_string(len) + "-RESYNC", ping.first == 0x86, "nextPingReply=" + std::to_string(ping.first));
        L.check("F1-LEN-" + std::to_string(len) + "-EXPLICIT-REJECT", rep.first == 0xFF,
                "oversizeReplyType=" + std::to_string(rep.first) + " (0=silently skipped; no ERR; no disconnect)");
    }

    // --- F1-TRUNC: truncated frame followed by a valid one -----------------------------
    fresh();
    { Bytes t = frameOf(0x06, 30, Bytes(100, 0x20)); t.resize(16); // header says 100, only 10 arrive
      C.push(t); C.push(frameOf(0x06, 31, {})); serviceProtocol(); serviceProtocol();
      auto ping31 = C.replyFor(31);
      C.push(Bytes(84, 0x20)); serviceProtocol();
      auto after = C.take();
      bool got30 = false, got31 = false; for (auto& f : after) { got30 |= f.seq == 30; got31 |= f.seq == 31; }
      L.check("F1-TRUNC-THEN-VALID", ping31.first == 0x86,
              "validPingAnswered=" + std::to_string(ping31.first == 0x86) + " swallowedIntoTruncated=1 afterFill:seq30=" +
                  std::to_string(got30) + " seq31=" + std::to_string(got31)); }

    // --- F1-PHANTOM: oversize frame payload containing a frame-shaped byte run --------
    fresh();
    { Bytes inner = frameOf(0x10, 0x5A, setFramePayload(0x5A));
      Bytes outer{0xA5, 0x21, 40, 0x00, 0x68, 0x10}; // BLOB_CHUNK len 4200 (>4096)
      Bytes body(4200, 0x00);
      std::copy(inner.begin(), inner.end(), body.begin() + 100);
      outer.insert(outer.end(), body.begin(), body.end());
      runtimeFrameBits()[0] = 0; advanceMs(100);
      deliver(outer); advanceMs(50); servicePackedFrameQueue();
      auto ph = C.replyFor(0x5A);
      L.check("F1-OVERSIZE-PHANTOM-DISPATCH", ph.first == 0 && runtimeFrameBits()[0] != 0x5A,
              "phantomReplyType=" + std::to_string(ph.first) + " displayMarkerDec=" + std::to_string(runtimeFrameBits()[0]) + "(injected=90)" +
                  " (payload bytes of a rejected frame re-parsed as SET_FRAME)"); }

    // --- F1-UNKNOWN-TYPE ----------------------------------------------------------------
    fresh();
    { auto rep = C.request(0x7F, 40, Bytes{1, 2, 3});
      auto ping = C.request(0x06, 41, {});
      L.check("F1-UNKNOWN-TYPE", rep.first == 0xFF && errCode(rep.second) == 400 && ping.first == 0x86, "code=" + std::to_string(errCode(rep.second))); }

    // --- F1-SETFRAME payload sizes -------------------------------------------------------
    struct SF { std::string id; Bytes p; bool ok; };
    std::vector<SF> sfs;
    for (size_t n : {46UL, 47UL, 48UL}) { Bytes p(n, 0); sfs.push_back({"F1-SETFRAME-PAYLOAD-" + std::to_string(n), p, false}); }
    sfs.push_back({"F1-SETFRAME-PAYLOAD-49-VALID", setFramePayload(1), true});
    sfs.push_back({"F1-SETFRAME-PAYLOAD-50-TRAILING", [] { Bytes p = setFramePayload(2); p.push_back(9); return p; }(), true});
    sfs.push_back({"F1-SETFRAME-FRAME46", setFramePayload(3, 46), false});
    sfs.push_back({"F1-SETFRAME-FRAME48", setFramePayload(4, 48), true});
    sfs.push_back({"F1-SETFRAME-TAILBITS", [] { Bytes p = setFramePayload(5); p[2 + 46] = 0x04; return p; }(), false});
    sfs.push_back({"F1-SETFRAME-REASONLEN-OVERRUN", setFramePayload(6, 47, 0) /*len49*/, false});
    sfs.back().p[1] = 10;
    uint8_t sq = 50;
    for (auto& s : sfs) {
        fresh();
        auto rep = C.request(0x10, sq++, s.p);
        bool ok = rep.first == 0x90;
        L.check(s.id, ok == s.ok, "replyType=" + std::to_string(rep.first) + " expectAccept=" + std::to_string(s.ok) +
                                      (rep.first == 0xFF ? " code=" + std::to_string(errCode(rep.second)) : ""));
    }

    // --- F1-BLE-RESYNC: carrier overflow -> ERR 413 seq0, then recover ----------------
    fresh();
    { Bytes partial = frameOf(0x06, 60, Bytes(50, 1)); partial.resize(30);
      C.push(partial); rinalink::transportMarkResyncNeeded(C.id); serviceProtocol();
      bool got413 = false; for (auto& f : C.take()) if (f.type == 0xFF && f.seq == 0 && errCode(std::string(f.payload.begin(), f.payload.end())) == 413) got413 = true;
      auto ping = C.request(0x06, 61, {});
      L.check("F1-BLE-OVERFLOW-RESYNC", got413 && ping.first == 0x86 && g_clients[C.id.slot].inboundLen == 0,
              "err413=" + std::to_string(got413) + " nextPing=" + std::to_string(ping.first)); }

    // --- F1-FUZZ-POP: direct popInboundFrame differential vs reference model -----------
    {
        XorShift r(seed);
        uint8_t buf[INBOUND_BUFFER_BYTES]; size_t len = 0; std::vector<uint8_t> ref; uint8_t out[FRAME_HEADER_BYTES + MAX_PAYLOAD_BYTES];
        unsigned long mismatches = 0, frames = 0, capViolations = 0;
        auto refPop = [&](Bytes& fr) -> size_t {
            size_t i = 0;
            while (ref.size() - i >= 6) {
                if (ref[i] != 0xA5) { ++i; continue; }
                size_t n = ref[i + 4] | (static_cast<size_t>(ref[i + 5]) << 8);
                if (n > 4096) { ++i; continue; }
                if (ref.size() - i < 6 + n) break;
                fr.assign(ref.begin() + static_cast<long>(i), ref.begin() + static_cast<long>(i + 6 + n));
                ref.erase(ref.begin(), ref.begin() + static_cast<long>(i + 6 + n));
                return fr.size();
            }
            ref.erase(ref.begin(), ref.begin() + static_cast<long>(i));
            return 0;
        };
        const auto t0 = std::chrono::steady_clock::now();
        for (unsigned long it = 0; it < iters; ++it) {
            size_t want = 1 + r.below(r.below(4) == 0 ? 600 : 40);
            size_t room = INBOUND_BUFFER_BYTES - len;
            if (want > room) want = room;
            for (size_t i = 0; i < want; ++i) {
                uint8_t b;
                switch (r.below(8)) { case 0: b = 0xA5; break; case 1: b = static_cast<uint8_t>(r.below(3)); break; case 2: b = 0x10; break; default: b = static_cast<uint8_t>(r.below(256)); }
                buf[len++] = b; ref.push_back(b);
            }
            for (int k = 0; k < 8; ++k) {
                Bytes fr;
                size_t n = rinalink::popInboundFrame(buf, len, out);
                size_t rn = refPop(fr);
                if (n != rn || (n && std::memcmp(out, fr.data(), n) != 0) || len != ref.size() || std::memcmp(buf, ref.data(), len) != 0) { ++mismatches; ref.assign(buf, buf + len); }
                if (len > INBOUND_BUFFER_BYTES || n > FRAME_HEADER_BYTES + MAX_PAYLOAD_BYTES) ++capViolations;
                if (!n) break;
                ++frames;
            }
            // Deadlock guard: a full buffer must always make progress.
            if (len == INBOUND_BUFFER_BYTES) { Bytes fr; size_t n = rinalink::popInboundFrame(buf, len, out); refPop(fr); if (!n && len == INBOUND_BUFFER_BYTES) { ++capViolations; len = 0; ref.clear(); } }
        }
        const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        L.check("F1-FUZZ-POP", mismatches == 0 && capViolations == 0,
                "iters=" + std::to_string(iters) + " frames=" + std::to_string(frames) + " mismatches=" + std::to_string(mismatches) +
                    " capOrStallViolations=" + std::to_string(capViolations) + " secs=" + std::to_string(secs),
                std::to_string(iters), "0x" + hex64(seed));
    }

    // --- F1-FUZZ-DISPATCH: seeded stream through real dispatch -------------------------
    {
        fresh();
        XorShift r(seed ^ 0x5151);
        std::deque<uint8_t> pending;
        unsigned long passes = 0, maxGroups = 0, budgetViolations = 0, capViolations = 0, replyGroups = 0;
        const char* cmds[] = {"{\"cmd\":\"set_brightness\",\"raw\":77}", "{\"cmd\":\"pause\"}", "{\"cmd\":\"resume\"}", "{bad json", "",
                              "{\"cmd\":\"scroll_seek\",\"frameIndex\":3}", "{\"cmd\":\"subscribe\",\"preview\":false}", "{\"cmd\":\"nope\"}"};
        const uint8_t types[] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x10, 0x11, 0x20, 0x21, 0x22, 0x23, 0x24, 0x7E, 0xFF};
        const auto t0 = std::chrono::steady_clock::now();
        for (unsigned long it = 0; it < iters; ++it) {
            if (pending.size() < 32768) {
                Bytes seg;
                uint32_t kind = r.below(100);
                uint8_t sqn = static_cast<uint8_t>(1 + r.below(255));
                if (kind < 40) {
                    switch (r.below(6)) {
                    case 0: seg = frameOf(0x06, sqn, {}); break;
                    case 1: seg = frameOf(0x11, sqn, {}); break;
                    case 2: seg = frameOf(0x10, sqn, setFramePayload(static_cast<uint8_t>(r.below(256)))); break;
                    case 3: seg = jsonFrame(0x01, sqn, cmds[r.below(8)]); break;
                    case 4: seg = frameOf(0x23, sqn, {}); break;
                    default: seg = frameOf(0x7E, sqn, Bytes(r.below(64), 0x33)); break;
                    }
                } else if (kind < 65) {
                    seg.resize(1 + r.below(64)); for (auto& b : seg) b = static_cast<uint8_t>(r.below(256));
                } else if (kind < 75) {
                    size_t n = 4097 + r.below(65535 - 4097);
                    seg = {0xA5, types[r.below(15)], sqn, 0, static_cast<uint8_t>(n & 0xFF), static_cast<uint8_t>(n >> 8)};
                    for (uint32_t i = r.below(100); i; --i) seg.push_back(static_cast<uint8_t>(r.below(256)));
                } else if (kind < 85) {
                    seg = frameOf(0x06, sqn, Bytes(r.below(20), 0)); seg.resize(1 + r.below(5));
                } else {
                    Bytes p(r.below(300)); for (auto& b : p) b = static_cast<uint8_t>(r.below(256));
                    seg = frameOf(types[r.below(15)], sqn, p);
                }
                pending.insert(pending.end(), seg.begin(), seg.end());
            }
            size_t freeB = rinalink::transportInboundFree(C.id);
            size_t n = std::min<size_t>({pending.size(), freeB, 1 + r.below(512)});
            if (n) { Bytes chunk(pending.begin(), pending.begin() + static_cast<long>(n)); pending.erase(pending.begin(), pending.begin() + static_cast<long>(n)); C.push(chunk); }
            if (g_clients[C.id.slot].inboundLen > INBOUND_BUFFER_BYTES) ++capViolations;
            if (r.below(10) < 7) {
                serviceProtocol(); ++passes;
                unsigned g = groups(C.take());
                replyGroups += g;
                // one extra group allowed: the ERR(413) resync notice
                if (g > MAX_FRAMES_PER_CLIENT_PASS) ++budgetViolations;
                maxGroups = std::max<unsigned long>(maxGroups, g);
                if (!g_clients[C.id.slot].used) { ++capViolations; fresh(); }
                ClientSlot& cs = g_clients[C.id.slot]; cs.subPreview = cs.subStatus = cs.subPower = false;
            }
            if ((it & 0x3F) == 0) advanceMs(1);
        }
        const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        L.check("F1-FUZZ-DISPATCH", budgetViolations == 0 && capViolations == 0 && g_lockRecursion == 0 && g_lockOrderViolations == 0,
                "iters=" + std::to_string(iters) + " passes=" + std::to_string(passes) + " replyGroups=" + std::to_string(replyGroups) +
                    " maxGroupsPerPass=" + std::to_string(maxGroups) + " budgetViolations=" + std::to_string(budgetViolations) +
                    " capViolations=" + std::to_string(capViolations) + " lockRecursion=" + std::to_string(g_lockRecursion) +
                    " lockOrder=" + std::to_string(g_lockOrderViolations) + " secs=" + std::to_string(secs),
                std::to_string(iters), "0x" + hex64(seed ^ 0x5151));
    }
    std::cout << "SUMMARY F1 pass=" << L.pass << " fail=" << L.fail << std::endl;
    return 0;
}
