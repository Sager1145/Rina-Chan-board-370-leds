// c++ -std=c++17 -Wall -Wextra -Werror -Iesp32s3_firmware/src esp32s3_firmware/test/host/stream_transport_test.cpp -o /tmp/rina-stream-test
#include "inbound_frame.h"
#include "tcp_frame_sender.h"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <vector>
using namespace rinalink;
using Bytes = std::vector<uint8_t>;
Bytes packet(uint8_t type, uint8_t seq, size_t n) {
    Bytes b{FRAME_MAGIC, type, seq, 0, static_cast<uint8_t>(n), static_cast<uint8_t>(n >> 8)};
    for (size_t i = 0; i < n; ++i) b.push_back(static_cast<uint8_t>(i));
    return b;
}
struct Socket {
    uint32_t now = 0;
    int failures = 0;
    size_t failAfter = 0;
    size_t limit = 4096;
    bool fatal = false;
    bool connected = true;
    Bytes received;
    TcpFrameSendResult send(const Bytes& data, bool event = false) {
        return sendTcpFrame(data.data(), data.size(), event,
            [&](const uint8_t* p, size_t n) -> ptrdiff_t {
                if (fatal) return -2;
                if (received.size() >= failAfter && failures > 0) { --failures; return -1; }
                n = std::min(n, limit);
                received.insert(received.end(), p, p + n);
                return static_cast<ptrdiff_t>(n);
            }, [&] { return connected; }, [&](uint32_t ms) { now += ms; }, [&] { return now; });
    }
};
int main() {
    // Exercise every request family, fragmented/coalesced exactly as either
    // BLE ATT writes or TCP reads can arrive. Concurrent appends cannot steal
    // the buffer space still occupied by undispatched frames.
    const uint8_t types[] = {1,2,3,4,5,6,0x10,0x11,0x20,0x21,0x22,0x23,0x24};
    Bytes stream;
    std::vector<Bytes> expected;
    for (size_t i = 0; i < 1000; ++i) {
        auto b = packet(types[i % 13], static_cast<uint8_t>(i), i % 257);
        stream.insert(stream.end(), b.begin(), b.end());
        expected.push_back(b);
    }
    uint8_t inbound[INBOUND_BUFFER_BYTES] = {}, frame[FRAME_HEADER_BYTES + MAX_PAYLOAD_BYTES];
    size_t length = 0, input = 0, output = 0;
    size_t oversizedRemaining = 0;
    for (size_t pass = 0; output < expected.size(); ++pass) {
        assert(pass < 10000);
        auto append = [&] {
            const size_t n = std::min({stream.size() - input, INBOUND_BUFFER_BYTES - length, 1 + pass % 511});
            std::copy_n(stream.data() + input, n, inbound + length);
            length += n; input += n;
        };
        append();
        for (int budget = 0; budget < 8; ++budget) {
            const auto popped = popInboundFrame(inbound, length, frame, oversizedRemaining);
            assert(!popped.oversized);
            if (!popped.frameBytes) break;
            assert(Bytes(frame, frame + popped.frameBytes) == expected.at(output++));
            append(); // mimics RX while the main task dispatches the prior frame
        }
    }
    assert(length == 0);
    auto maxFrame = packet(0x21, 7, MAX_PAYLOAD_BYTES);
    std::copy(maxFrame.begin(), maxFrame.end() - 1, inbound);
    length = maxFrame.size() - 1;
    assert(popInboundFrame(inbound, length, frame, oversizedRemaining).frameBytes == 0 &&
           length == maxFrame.size() - 1);
    inbound[length++] = maxFrame.back();
    assert(popInboundFrame(inbound, length, frame, oversizedRemaining).frameBytes == maxFrame.size() &&
           length == 0);

    // Rejected payload is discarded as an opaque byte count, including a
    // frame-shaped run inside it. A following frame remains parseable.
    auto good = packet(6, 1, 0);
    auto hidden = packet(0x10, 99, 47);
    Bytes oversized{FRAME_MAGIC, 0x21, 44, 0, 0x68, 0x10}; // 4200 bytes
    Bytes body(4200, 0);
    std::copy(hidden.begin(), hidden.end(), body.begin() + 100);
    oversized.insert(oversized.end(), body.begin(), body.end());
    oversized.insert(oversized.end(), good.begin(), good.end());
    size_t oversizedInput = 0;
    bool rejected = false;
    while (oversizedInput < oversized.size() || length > 0) {
        const size_t n = std::min(oversized.size() - oversizedInput,
                                  INBOUND_BUFFER_BYTES - length);
        std::copy_n(oversized.data() + oversizedInput, n, inbound + length);
        oversizedInput += n;
        length += n;
        const auto popped = popInboundFrame(inbound, length, frame, oversizedRemaining);
        rejected = rejected || (popped.oversized && popped.rejectedSeq == 44);
        if (popped.frameBytes) {
            assert(Bytes(frame, frame + popped.frameBytes) == good);
            break;
        }
    }
    assert(rejected && oversizedRemaining == 0);

    const Bytes garbage{0, 1, 2, 3};
    std::copy(garbage.begin(), garbage.end(), inbound);
    std::copy(good.begin(), good.end(), inbound + garbage.size());
    length = garbage.size() + good.size();
    assert(popInboundFrame(inbound, length, frame, oversizedRemaining).frameBytes == good.size() &&
           length == 0);
    auto data = packet(0x90, 1, 100);
    { Socket s; s.failures=40; assert(s.send(data).complete && s.received == data); }
    { Socket s; s.failures=10000; assert(!s.send(data).complete && s.now == 250); }
    { Socket s; s.failures=10000; auto r=s.send(data,true); assert(!r.complete && r.bytesSent==0 && s.now==0); }
    { Socket s; s.limit=20; s.failAfter=20; s.failures=40; assert(s.send(data,true).complete && s.received==data); }
    { Socket s; s.limit=20; s.failAfter=20; s.failures=10000; auto r=s.send(data,true); assert(!r.complete && r.bytesSent==20 && s.now==250); }
    { Socket s; s.limit=1; auto r=s.send(maxFrame); assert(!r.complete && r.bytesSent==250 && s.now==250); }
    { Socket s; s.now=UINT32_MAX-10; s.failures=40; assert(s.send(data).complete && s.received==data); }
    { Socket s; s.fatal=true; assert(!s.send(data).complete && s.now==0); }
    { Socket s; s.connected=false; assert(!s.send(data).complete && s.received.empty()); }
    std::puts("Stream transport: 1000 mixed frames, fragmented maximum frame, resync and 9 TCP fault scenarios passed");
}
