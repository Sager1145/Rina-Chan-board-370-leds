#pragma once
#include <stdint.h>
#include <stddef.h>

namespace rinalink {
struct TcpFrameSendResult { bool complete; size_t bytesSent; };

// write returns bytes accepted, -1 for temporary back-pressure, -2 for a
// broken socket. Only wholly unsent events may be dropped from a byte stream.
// The deadline applies even to a peer making continuous tiny progress.
template <typename Write, typename Connected, typename Pause, typename Clock>
TcpFrameSendResult sendTcpFrame(const uint8_t* data, size_t length, bool isEvent,
                               Write write, Connected connected, Pause pause, Clock clock) {
    size_t offset = 0;
    const uint32_t started = clock();
    while (offset < length) {
        if (!connected() || static_cast<uint32_t>(clock() - started) >= 250)
            return {false, offset};
        const ptrdiff_t n = write(data + offset, length - offset);
        if (n == -2)
            return {false, offset};
        if (n <= 0) {
            if (isEvent && offset == 0)
                return {false, 0};
        } else {
            offset += static_cast<size_t>(n);
        }
        if (offset < length)
            pause(1);
    }
    return {true, offset};
}
} // namespace rinalink
