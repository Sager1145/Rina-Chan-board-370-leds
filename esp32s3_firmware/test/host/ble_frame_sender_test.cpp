// Run: c++ -std=c++17 -Wall -Wextra -Werror -Iesp32s3_firmware/src \
//   esp32s3_firmware/test/host/ble_frame_sender_test.cpp -o /tmp/rina-ble-test && /tmp/rina-ble-test
#include "ble_frame_sender.h"
#include <cassert>
#include <cstdio>
#include <vector>

struct Link {
    uint32_t now = 0;
    uint32_t stalled = 0;
    bool active = true;
    int failures = 0;
    int calls = 0;
    size_t failAfter = 0;
    size_t disconnectAfter = SIZE_MAX;
    std::vector<uint8_t> received;

    rinalink::BleFrameSendResult send(const std::vector<uint8_t>& data, bool event = false) {
        return rinalink::sendBleFrame(data.data(), data.size(), 20, event,
            [&](const uint8_t* bytes, size_t n) {
                ++calls;
                if (received.size() >= failAfter && failures > 0) {
                    --failures;
                    return false;
                }
                received.insert(received.end(), bytes, bytes + n);
                if (received.size() >= disconnectAfter)
                    active = false;
                return true;
            }, [&] { return active; },
            [&](uint32_t ms) { now += ms; if (ms == 2) stalled += ms; },
            [&] { return now; });
    }
};

int main() {
    std::vector<uint8_t> frame(67);
    for (size_t i = 0; i < frame.size(); ++i) frame[i] = static_cast<uint8_t>(i);
    {
        Link link;
        link.failures = 20; // 40ms congestion: longer than the previous retry window.
        auto result = link.send(frame);
        assert(result.complete && link.received == frame && link.stalled == 40);
    }
    {
        Link link;
        link.failures = 10000;
        auto result = link.send(frame);
        assert(!result.complete && result.bytesSent == 0 && link.stalled == 250);
    }
    {
        Link link;
        link.failures = 1;
        auto result = link.send(frame, true);
        assert(!result.complete && result.bytesSent == 0 && link.now == 0);
    }
    {
        Link link;
        link.failAfter = 20;
        link.failures = 20;
        auto result = link.send(frame, true);
        assert(result.complete && link.received == frame); // never skip a failed slice
    }
    {
        Link link;
        link.failAfter = 20;
        link.failures = 10000;
        auto result = link.send(frame, true);
        assert(!result.complete && result.bytesSent == 20 && link.stalled == 250);
    }
    {
        Link link;
        link.disconnectAfter = 20;
        auto result = link.send(frame);
        assert(!result.complete && result.bytesSent == 20 && link.calls == 1);
    }
    {
        Link link;
        link.now = UINT32_MAX - 5;
        link.failures = 20;
        auto result = link.send(frame);
        assert(result.complete && link.received == frame && link.stalled == 40);
    }
    {
        Link link;
        for (int i = 0; i < 1000; ++i) {
            link.received.clear();
            link.failures = i % 25;
            assert(link.send(frame).complete && link.received == frame);
        }
    }
    std::puts("BLE frame sender: 8 scenarios passed (including 1000-frame congestion burst)");
}
