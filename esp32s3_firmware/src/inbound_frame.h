#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

namespace rinalink {
constexpr uint8_t  FRAME_MAGIC        = 0xA5;
constexpr size_t   FRAME_HEADER_BYTES = 6;      // magic,type,seq,flags,len(lo),len(hi)
constexpr uint16_t MAX_PAYLOAD_BYTES  = 4096;
constexpr uint8_t  FLAG_MORE          = 0x01;
constexpr uint8_t  MAX_CLIENTS        = 4;      // 2 TCP + 1 BLE + spare
constexpr size_t   INBOUND_BUFFER_BYTES = FRAME_HEADER_BYTES + MAX_PAYLOAD_BYTES + 64;

// Caller holds its inbound lock. Remove only the frame being dispatched;
// incomplete and budget-deferred frames keep their reserved buffer space.
// Copying the whole buffer out and reinserting leftovers after dispatch lets
// concurrent BLE writes consume that space twice and corrupts the byte stream.
inline size_t popInboundFrame(uint8_t* inbound, size_t& length, uint8_t* frame) {
    size_t offset = 0;
    size_t frameBytes = 0;
    while (length - offset >= FRAME_HEADER_BYTES) {
        if (inbound[offset] != FRAME_MAGIC) {
            ++offset;
            continue;
        }
        const size_t payloadBytes = static_cast<size_t>(inbound[offset + 4]) |
                                    (static_cast<size_t>(inbound[offset + 5]) << 8);
        if (payloadBytes > MAX_PAYLOAD_BYTES) {
            ++offset;
            continue;
        }
        const size_t total = FRAME_HEADER_BYTES + payloadBytes;
        if (length - offset < total)
            break;
        memcpy(frame, inbound + offset, total);
        frameBytes = total;
        offset += total;
        break;
    }
    if (offset > 0) {
        length -= offset;
        memmove(inbound, inbound + offset, length);
    }
    return frameBytes;
}
} // namespace rinalink
