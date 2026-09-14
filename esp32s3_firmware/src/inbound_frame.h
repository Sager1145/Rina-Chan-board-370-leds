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

struct InboundFrameResult {
    size_t frameBytes = 0;
    bool oversized = false;
    uint8_t rejectedSeq = 0;
};

// Caller holds its inbound lock. Once an oversized header is accepted, every byte
// in its declared payload is discarded across subsequent carrier reads. This
// prevents a frame-shaped byte sequence inside rejected payload from executing.
// The caller receives `oversized` once, when the header is first consumed, so it
// can return ERR(413) for the rejected sequence.
inline InboundFrameResult popInboundFrame(uint8_t* inbound, size_t& length,
                                          uint8_t* frame,
                                          size_t& oversizedBytesRemaining) {
    InboundFrameResult result;
    size_t offset = 0;

    if (oversizedBytesRemaining > 0) {
        const size_t discarded = length < oversizedBytesRemaining
                                     ? length : oversizedBytesRemaining;
        offset = discarded;
        oversizedBytesRemaining -= discarded;
        if (oversizedBytesRemaining > 0) {
            length -= offset;
            memmove(inbound, inbound + offset, length);
            return result;
        }
    }

    while (length - offset >= FRAME_HEADER_BYTES) {
        if (inbound[offset] != FRAME_MAGIC) {
            ++offset;
            continue;
        }
        const size_t payloadBytes = static_cast<size_t>(inbound[offset + 4]) |
                                    (static_cast<size_t>(inbound[offset + 5]) << 8);
        if (payloadBytes > MAX_PAYLOAD_BYTES) {
            result.oversized = true;
            result.rejectedSeq = inbound[offset + 2];
            offset += FRAME_HEADER_BYTES;
            const size_t available = length - offset;
            const size_t discarded = available < payloadBytes ? available : payloadBytes;
            offset += discarded;
            oversizedBytesRemaining = payloadBytes - discarded;
            break;
        }
        const size_t total = FRAME_HEADER_BYTES + payloadBytes;
        if (length - offset < total)
            break;
        memcpy(frame, inbound + offset, total);
        result.frameBytes = total;
        offset += total;
        break;
    }
    if (offset > 0) {
        length -= offset;
        memmove(inbound, inbound + offset, length);
    }
    return result;
}
} // namespace rinalink
