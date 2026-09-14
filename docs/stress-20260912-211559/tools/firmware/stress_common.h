// Shared helpers for stress harnesses. Include AFTER "../../src/protocol.cpp"
// so file-static protocol state (g_clients, handlers) is reachable.
#pragma once
#include <cassert>
#include <cinttypes>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using Bytes = std::vector<uint8_t>;
extern uint64_t g_fakeMicros;
extern unsigned g_lockRecursion, g_lockOrderViolations;

inline void advanceMs(uint32_t ms) { g_fakeMicros += static_cast<uint64_t>(ms) * 1000ULL; }

inline uint64_t fnv1a(const uint8_t* p, size_t n, uint64_t h = 1469598103934665603ULL) {
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}
inline std::string hex64(uint64_t v) { char b[20]; std::snprintf(b, sizeof b, "%016" PRIx64, v); return b; }

struct XorShift {
    uint64_t s;
    explicit XorShift(uint64_t seed) : s(seed ? seed : 0x9E3779B97F4A7C15ULL) {}
    uint64_t next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
    uint32_t below(uint32_t n) { return n ? static_cast<uint32_t>(next() % n) : 0; }
};

inline Bytes frameOf(uint8_t type, uint8_t seq, const Bytes& payload, uint8_t flags = 0) {
    Bytes b{rinalink::FRAME_MAGIC, type, seq, flags, static_cast<uint8_t>(payload.size() & 0xFF),
            static_cast<uint8_t>((payload.size() >> 8) & 0xFF)};
    b.insert(b.end(), payload.begin(), payload.end());
    return b;
}
inline Bytes bytesOf(const std::string& s) { return Bytes(s.begin(), s.end()); }
inline Bytes jsonFrame(uint8_t type, uint8_t seq, const std::string& json) { return frameOf(type, seq, bytesOf(json)); }

struct RxFrame { uint8_t type, seq, flags; Bytes payload; };

// ---- case recorder: one CSV-ish line per case on stdout -------------------------
struct CaseLog {
    std::string layer, evidence;
    unsigned pass = 0, fail = 0, blocked = 0;
    void rec(const std::string& id, const std::string& load, const std::string& seed, const std::string& status,
             const std::string& metrics) {
        if (status == "PASS") ++pass; else if (status == "FAIL") ++fail; else ++blocked;
        std::string m = metrics;
        for (auto& c : m) if (c == ',') c = ';';
        std::cout << "CASE," << id << "," << layer << "," << load << "," << seed << "," << status << "," << m << ","
                  << evidence << std::endl;
    }
    void check(const std::string& id, bool ok, const std::string& metrics, const std::string& load = "1",
               const std::string& seed = "-") { rec(id, load, seed, ok ? "PASS" : "FAIL", metrics); }
};

// ---- fake carrier ---------------------------------------------------------------
struct FakeTransport final : public rinalink::ITransport {
    rinalink::Carrier car;
    uint16_t chunk;
    std::vector<Bytes> sent[rinalink::MAX_CLIENTS];
    // Return true to make this send fail with zero bytes queued.
    std::function<bool(uint8_t slot, const uint8_t* d, size_t n, bool isEvent)> dropHook;
    unsigned disconnects = 0, failedSends = 0;
    explicit FakeTransport(rinalink::Carrier c = rinalink::Carrier::Tcp, uint16_t ch = 4032) : car(c), chunk(ch) {}
    rinalink::Carrier carrier() const override { return car; }
    bool send(rinalink::ClientId id, const uint8_t* d, size_t n, bool isEvent) override {
        if (dropHook && dropHook(id.slot, d, n, isEvent)) { ++failedSends; return false; }
        sent[id.slot].push_back(Bytes(d, d + n));
        return true;
    }
    uint16_t preferredChunkBytes(rinalink::ClientId) const override { return chunk; }
    void disconnect(rinalink::ClientId) override { ++disconnects; }
};

struct TestClient {
    FakeTransport* t = nullptr;
    rinalink::ClientId id{0xFF};
    size_t cursor = 0;
    bool connect(FakeTransport& tr, bool quietEvents = true) {
        t = &tr;
        if (!rinalink::transportRegisterClient(&tr, tr.car, &id)) return false;
        const size_t before = t->sent[id.slot].size();
        serviceProtocol(); // loop task finalizes connect (and may fan out first events)
        if (quietEvents) {
            ClientSlot& c = g_clients[id.slot];
            c.subPreview = c.subStatus = c.subPower = c.subLog = false;
            cursor = t->sent[id.slot].size();
        } else {
            cursor = before; // keep events emitted in the connect pass visible
        }
        return true;
    }
    void push(const Bytes& b) { rinalink::transportPushInbound(id, b.data(), b.size()); }
    std::vector<RxFrame> take() {
        std::vector<RxFrame> out;
        auto& v = t->sent[id.slot];
        for (; cursor < v.size(); ++cursor) {
            const Bytes& f = v[cursor];
            RxFrame r{f[1], f[2], f[3], Bytes(f.begin() + 6, f.end())};
            out.push_back(r);
        }
        return out;
    }
    // Send one request, run one protocol pass, return the reassembled reply payload
    // for (seq) and its type (0 if none). Events are ignored by seq!=0 filtering.
    std::pair<uint8_t, std::string> request(uint8_t type, uint8_t seq, const Bytes& payload) {
        push(frameOf(type, seq, payload));
        serviceProtocol();
        return replyFor(seq);
    }
    std::pair<uint8_t, std::string> replyFor(uint8_t seq) {
        uint8_t rt = 0; std::string body;
        for (auto& f : take()) {
            if (f.seq != seq || (seq == 0 && f.type >= 0x90 && f.type <= 0x95)) continue;
            rt = f.type; body.append(f.payload.begin(), f.payload.end());
        }
        return {rt, body};
    }
    std::pair<uint8_t, std::string> cmd(uint8_t seq, const std::string& json) { return request(0x01, seq, bytesOf(json)); }
};

inline DynamicJsonDocument parse(const std::string& s) {
    DynamicJsonDocument d(s.size() * 4 + 4096);
    deserializeJson(d, s);
    return d;
}

inline void resetFakeFs(const std::string& root) {
    std::error_code ec;
    std::filesystem::remove_all(root, ec);
    std::filesystem::create_directories(root + "/resources", ec);
    g_fsRoot = root;
    g_fsFaults = FakeFsFaults{};
}
inline Bytes readFile(const std::string& p) {
    std::ifstream in(p, std::ios::binary);
    return Bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}
inline void writeFile(const std::string& p, const std::string& s) {
    std::ofstream o(p, std::ios::binary | std::ios::trunc); o << s;
}
