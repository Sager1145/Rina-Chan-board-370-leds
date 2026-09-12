#pragma once

#include <stddef.h>
#include <stdint.h>

namespace rinalink {

struct BleFrameSendResult {
    bool complete;
    size_t bytesSent;
};

// A failed notify means that slice was not queued. Retry that same slice,
// yielding to the BLE host/controller. Six milliseconds is shorter than a
// connection interval; allow a bounded 250 ms of congestion per frame.
// An event may only be dropped before its first byte enters the stream.
template <typename Notify, typename Connected, typename Pause, typename Clock>
BleFrameSendResult sendBleFrame(const uint8_t* data, size_t len, size_t chunk,
                               bool isEvent, Notify notify, Connected connected,
                               Pause pause, Clock clock) {
    if (chunk == 0)
        return {false, 0};
    size_t offset = 0;
    uint32_t stalledMs = 0;
    while (offset < len) {
        const size_t n = chunk < len - offset ? chunk : len - offset;
        for (;;) {
            if (!connected())
                return {false, offset};
            if (notify(data + offset, n))
                break;
            if ((isEvent && offset == 0) || stalledMs >= 250)
                return {false, offset};
            const uint32_t before = clock();
            pause(2);
            const uint32_t elapsed = static_cast<uint32_t>(clock() - before);
            stalledMs += elapsed > 0 ? elapsed : 1;
        }
        offset += n;
        // Pace across short frames too, not only frames longer than four MTUs.
        // A burst of short replies otherwise fills the very same mbuf pool.
        pause(1);
    }
    return {true, offset};
}

} // namespace rinalink
