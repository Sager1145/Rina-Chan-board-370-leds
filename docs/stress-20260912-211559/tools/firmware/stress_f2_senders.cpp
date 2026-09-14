// F2: BLE (and TCP) frame sender fault injection + byte-stream integrity.
// Standalone (headers only): c++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
//   -Iesp32s3_firmware/src esp32s3_firmware/test/host/stress_f2_senders.cpp -o /tmp/f2 && /tmp/f2
#include "ble_frame_sender.h"
#include "tcp_frame_sender.h"
#include <cstdio>
#include <functional>
#include <iostream>
#include <string>
#include <vector>

using namespace rinalink;
using Bytes = std::vector<uint8_t>;
static unsigned gPass = 0, gFail = 0;
static void rec(const std::string& id, const std::string& load, const std::string& seed, bool ok, std::string m) {
    for (auto& c : m) if (c == ',') c = ';';
    (ok ? gPass : gFail)++;
    std::cout << "CASE," << id << ",fw-ble-tcp-sender," << load << "," << seed << "," << (ok ? "PASS" : "FAIL") << "," << m
              << ",logs/firmware/f2_senders.log" << std::endl;
}
struct Rng { uint64_t s; explicit Rng(uint64_t x) : s(x) {} uint64_t n() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; } uint32_t below(uint32_t k) { return static_cast<uint32_t>(n() % k); } };
static Bytes mk(size_t total, uint8_t tag) {
    Bytes b(total);
    b[0] = FRAME_MAGIC; b[1] = tag; b[2] = tag; b[3] = 0;
    b[4] = static_cast<uint8_t>((total - 6) & 0xFF); b[5] = static_cast<uint8_t>((total - 6) >> 8);
    for (size_t i = 6; i < total; ++i) b[i] = static_cast<uint8_t>(i * 31 + tag);
    return b;
}

struct BleLink {
    uint32_t now = 0;
    bool up = true;
    Bytes rx;
    size_t notifies = 0, attempts = 0;
    uint32_t pause2Cost = 2, pause1Cost = 1;
    std::function<bool(size_t attempt, size_t okSlices)> fail;  // true -> notify fails
    std::function<bool()> dropLink;                           // true -> connected() turns false now
    BleFrameSendResult send(const Bytes& f, size_t chunk, bool ev) {
        return sendBleFrame(f.data(), f.size(), chunk, ev,
            [&](const uint8_t* p, size_t n) { ++attempts; if (fail && fail(attempts, notifies)) return false; rx.insert(rx.end(), p, p + n); ++notifies; return true; },
            [&] { if (dropLink && dropLink()) up = false; return up; },
            [&](uint32_t ms) { now += ms == 2 ? pause2Cost : pause1Cost; },
            [&] { return now; });
    }
};

int main() {
    const Bytes reply = mk(67, 1);
    // ---- BLE unit cases ------------------------------------------------------------
    { BleLink l; l.fail = [](size_t, size_t) { return true; };
      auto r = l.send(reply, 20, false);
      rec("F2-BLE-NOT-WRITABLE-REPLY", "1", "-", !r.complete && r.bytesSent == 0 && bleSendFailureRequiresDisconnect(r, false) && l.now >= 250 && l.now <= 252,
          "bytes=" + std::to_string(r.bytesSent) + " blockedMs=" + std::to_string(l.now) + " disconnect=1"); }
    { BleLink l; l.fail = [](size_t, size_t) { return true; };
      auto r = l.send(reply, 20, true);
      rec("F2-BLE-NOT-WRITABLE-EVENT", "1", "-", !r.complete && r.bytesSent == 0 && !bleSendFailureRequiresDisconnect(r, true) && l.now == 0,
          "bytes=0 blockedMs=" + std::to_string(l.now) + " droppedCleanly=1"); }
    // "zero write": the ATT layer has no short/zero-length notify; a zero-byte frame never calls notify.
    { BleLink l; auto r = l.send(Bytes{}, 20, false);
      rec("F2-BLE-ZERO-LENGTH-FRAME", "1", "-", r.complete && r.bytesSent == 0 && l.attempts == 0, "attempts=" + std::to_string(l.attempts)); }
    { BleLink l; auto r = sendBleFrame(reply.data(), reply.size(), 0, false, [](const uint8_t*, size_t) { return true; }, [] { return true; }, [](uint32_t) {}, [] { return 0U; });
      rec("F2-BLE-CHUNK0", "1", "-", !r.complete && r.bytesSent == 0, "chunk=0 rejected"); }
    for (bool ev : {false, true}) {
        BleLink l; l.dropLink = [&] { return l.notifies == 2; };
        auto r = l.send(reply, 20, ev);
        rec(std::string("F2-BLE-PARTIAL-THEN-DISCONNECT-") + (ev ? "EVENT" : "REPLY"), "1", "-",
            !r.complete && r.bytesSent == 40 && l.rx.size() == 40 && bleSendFailureRequiresDisconnect(r, ev),
            "bytesSent=" + std::to_string(r.bytesSent) + " teardown=1");
    }
    // Deadline: cumulative stall via N failed notifies of 1 ms each at slice 0 (reply).
    for (unsigned n : {249U, 250U, 251U}) {
        BleLink l; l.pause2Cost = 1; l.fail = [n](size_t a, size_t) { return a <= n; };
        auto r = l.send(reply, 20, false);
        bool expectOk = n <= 250;
        rec("F2-BLE-DEADLINE-STALL-" + std::to_string(n) + "MS", std::to_string(n), "-", r.complete == expectOk,
            "complete=" + std::to_string(r.complete) + " blockedMs=" + std::to_string(l.now) + " (tolerates exactly 250 ms of 1 ms stalls)");
    }
    // Deadline with coarse pauses (scheduler hiccup): one pause of X ms, then another failure.
    for (unsigned x : {249U, 250U, 251U}) {
        BleLink l; l.pause2Cost = x; l.fail = [](size_t a, size_t) { return a <= 2; };
        auto r = l.send(reply, 20, false);
        rec("F2-BLE-DEADLINE-COARSE-PAUSE-" + std::to_string(x), std::to_string(x), "-", l.now <= 250 + x + 4,
            "complete=" + std::to_string(r.complete) + " blockedMs=" + std::to_string(l.now) + " bound=deadline+onePause");
    }
    // Worst-case loop() blocking for a max 4102 B reply at each ATT payload size.
    for (size_t att : {20UL, 182UL, 244UL, 509UL}) {
        BleLink l; l.fail = [](size_t, size_t) { return false; };
        const Bytes big = mk(4102, 9);
        // each slice fails once first (2 ms) until the 250 ms budget is spent
        size_t lastOk = SIZE_MAX; l.fail = [&](size_t, size_t ok) { if (ok != lastOk) { lastOk = ok; return true; } return false; };
        auto r = l.send(big, att, false);
        size_t slices = (big.size() + att - 1) / att;
        rec("F2-BLE-WORSTCASE-BLOCK-ATT" + std::to_string(att), "4102B", "-", l.now <= 250 + slices * 1 + 2 + 2,
            "slices=" + std::to_string(slices) + " complete=" + std::to_string(r.complete) + " bytes=" + std::to_string(r.bytesSent) +
                " blockedMs=" + std::to_string(l.now));
    }

    // ---- BLE randomized stream integrity per ATT payload ---------------------------
    for (size_t att : {20UL, 182UL, 244UL, 509UL}) {
        const uint64_t seed = 0xB1E0000ULL + att;
        Rng rng(seed);
        unsigned sessions = 0, frames = 0, complete = 0, droppedEvents = 0, teardowns = 0, violations = 0;
        size_t maxBlock = 0;
        while (frames < 3000) {
            BleLink l; ++sessions;
            Bytes expect;
            unsigned congest = 0;
            l.fail = [&](size_t, size_t) { if (congest) { --congest; return true; } if (rng.below(1000) < 8) congest = rng.below(200); return false; };
            l.dropLink = [&] { return rng.below(20000) == 0; };
            bool alive = true;
            while (alive && frames < 3000) {
                size_t total = 6 + (rng.below(4) == 0 ? rng.below(4097) : rng.below(300));
                bool ev = rng.below(2) == 0;
                Bytes f = mk(total, static_cast<uint8_t>(frames));
                ++frames;
                uint32_t t0 = l.now;
                auto r = l.send(f, att, ev);
                maxBlock = std::max<size_t>(maxBlock, l.now - t0);
                if (r.complete) { expect.insert(expect.end(), f.begin(), f.end()); ++complete; }
                else if (bleSendFailureRequiresDisconnect(r, ev)) { expect.insert(expect.end(), f.begin(), f.begin() + static_cast<long>(r.bytesSent)); ++teardowns; alive = false; }
                else { if (r.bytesSent != 0) ++violations; ++droppedEvents; }
                if (!l.up && alive) { // link dropped between frames: next send must fail with 0 bytes
                    auto r2 = l.send(mk(20, 1), att, false);
                    if (r2.complete || r2.bytesSent) ++violations;
                    alive = false; ++teardowns;
                }
            }
            if (l.rx != expect) ++violations; // exact: whole frames + at most one torn tail at teardown
        }
        rec("F2-BLE-STREAM-INTEGRITY-ATT" + std::to_string(att), "3000 frames", "0x" + std::to_string(seed), violations == 0,
            "sessions=" + std::to_string(sessions) + " complete=" + std::to_string(complete) + " droppedEvents=" + std::to_string(droppedEvents) +
                " teardowns=" + std::to_string(teardowns) + " violations=" + std::to_string(violations) + " maxBlockMs=" + std::to_string(maxBlock));
    }

    // ---- TCP sender: short / zero / -1 / -2 / partial+disconnect / deadline ----------
    struct Sock { uint32_t now = 0; bool up = true; Bytes rx; std::function<ptrdiff_t(size_t)> w;
        TcpFrameSendResult send(const Bytes& f, bool ev) {
            return sendTcpFrame(f.data(), f.size(), ev, [&](const uint8_t* p, size_t n) -> ptrdiff_t { ptrdiff_t k = w(n); if (k > 0) rx.insert(rx.end(), p, p + k); return k; },
                                [&] { return up; }, [&](uint32_t ms) { now += ms; }, [&] { return now; }); } };
    const Bytes big = mk(4102, 3);
    { Sock s; s.w = [](size_t) -> ptrdiff_t { return 1; }; auto r = s.send(big, false);
      rec("F2-TCP-SHORT-WRITE-1B", "4102B", "-", !r.complete && r.bytesSent == 250 && s.now == 250, "bytes=" + std::to_string(r.bytesSent) + " blockedMs=" + std::to_string(s.now) + " teardown"); }
    { Sock s; s.w = [](size_t n) -> ptrdiff_t { return static_cast<ptrdiff_t>(n > 1000 ? 1000 : n); }; auto r = s.send(big, false);
      rec("F2-TCP-SHORT-WRITE-1000B", "4102B", "-", r.complete && s.rx == big, "blockedMs=" + std::to_string(s.now)); }
    for (bool ev : {false, true}) { Sock s; s.w = [](size_t) -> ptrdiff_t { return 0; }; auto r = s.send(big, ev);
      rec(std::string("F2-TCP-ZERO-WRITE-") + (ev ? "EVENT" : "REPLY"), "4102B", "-", ev ? (!r.complete && r.bytesSent == 0 && s.now == 0) : (!r.complete && s.now == 250),
          "bytes=" + std::to_string(r.bytesSent) + " blockedMs=" + std::to_string(s.now)); }
    { Sock s; int calls = 0; s.w = [&](size_t n) -> ptrdiff_t { return ++calls == 1 ? 100 : (calls < 5 ? 0 : static_cast<ptrdiff_t>(n)); }; auto r = s.send(big, true);
      rec("F2-TCP-EVENT-PARTIAL-THEN-ZERO", "4102B", "-", r.complete && s.rx == big, "event kept writing after first byte; blockedMs=" + std::to_string(s.now)); }
    { Sock s; s.w = [](size_t) -> ptrdiff_t { return -2; }; auto r = s.send(big, false);
      rec("F2-TCP-BROKEN", "1", "-", !r.complete && r.bytesSent == 0 && s.now == 0, "immediate"); }
    { Sock s; int calls = 0; s.w = [&](size_t) -> ptrdiff_t { if (++calls == 2) s.up = false; return 500; }; auto r = s.send(big, false);
      // the 2nd write is accepted, then connected() is false before the 3rd
      rec("F2-TCP-PARTIAL-THEN-DISCONNECT", "1", "-", !r.complete && r.bytesSent == 1000 && s.rx.size() == 1000, "bytes=" + std::to_string(r.bytesSent) + " teardown"); }
    for (unsigned x : {249U, 250U, 251U}) { Sock s; s.w = [&](size_t n) -> ptrdiff_t { return s.now < x ? -1 : static_cast<ptrdiff_t>(n); }; auto r = s.send(big, false);
      bool expectOk = x < 250;
      rec("F2-TCP-DEADLINE-" + std::to_string(x) + "MS", std::to_string(x), "-", r.complete == expectOk, "complete=" + std::to_string(r.complete) + " blockedMs=" + std::to_string(s.now)); }
    { const uint64_t seed = 0x7C9ULL; Rng rng(seed); unsigned frames = 0, violations = 0, teardowns = 0, dropped = 0;
      while (frames < 3000) { Sock s; Bytes expect; bool alive = true;
        s.w = [&](size_t n) -> ptrdiff_t { uint32_t k = rng.below(100); if (k < 5) return -1; if (k < 7) return 0; if (k == 7 && rng.below(50) == 0) return -2; return static_cast<ptrdiff_t>(1 + rng.below(static_cast<uint32_t>(n))); };
        while (alive && frames < 3000) { size_t total = 6 + rng.below(4097); bool ev = rng.below(2) == 0; Bytes f = mk(total, static_cast<uint8_t>(frames++));
          auto r = s.send(f, ev);
          if (r.complete) expect.insert(expect.end(), f.begin(), f.end());
          else if (!ev || r.bytesSent > 0) { expect.insert(expect.end(), f.begin(), f.begin() + static_cast<long>(r.bytesSent)); alive = false; ++teardowns; }
          else ++dropped; }
        if (s.rx != expect) ++violations; }
      rec("F2-TCP-STREAM-INTEGRITY", "3000 frames", "0x7c9", violations == 0, "teardowns=" + std::to_string(teardowns) + " droppedEvents=" + std::to_string(dropped) + " violations=" + std::to_string(violations)); }

    std::cout << "SUMMARY F2 pass=" << gPass << " fail=" << gFail << std::endl;
    return 0;
}
