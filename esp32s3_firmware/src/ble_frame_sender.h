#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "inbound_frame.h"

namespace rinalink {

struct BleFrameSendResult {
    bool complete;
    size_t bytesSent;
};

inline bool bleTxNotifyEnabled(uint16_t subscriptionValue) {
    // NimBLE encodes notify as bit 0 and indicate as bit 1. RinaLink TX is
    // notify-only, so an indicate-only value cannot make the stream usable.
    return (subscriptionValue & 0x01U) != 0;
}

inline bool bleFrameCanSend(bool subscribed, bool isEvent) {
    // Replies are allowed through so a request can fail closed if the peer
    // races its CCCD update. Unsolicited events must wait for the CCCD or they
    // can consume the controller queue while the central discovers services.
    return !isEvent || subscribed;
}

inline bool bleSubscriptionChangeRequiresDisconnect(bool wasSubscribed,
                                                     uint16_t subscriptionValue) {
    // Once TX notifications are disabled the framed request/reply stream is no
    // longer usable. Release the single-central link instead of keeping
    // advertising stopped behind a session that cannot receive replies.
    return wasSubscribed && !bleTxNotifyEnabled(subscriptionValue);
}

inline bool bleSendFailureRequiresDisconnect(const BleFrameSendResult& result,
                                             bool isEvent) {
    return !result.complete && (!isEvent || result.bytesSent > 0);
}

// Tracks whether the central has completed at least one well-formed RinaLink
// request. It intentionally does not parse message semantics; protocol.cpp owns
// dispatch. Requiring a complete frame prevents arbitrary writes or a partial
// 4096-byte frame from keeping an uninitialized single-central link forever.
class BleInitialFrameTracker {
public:
    void reset() {
        mHeaderBytes = 0;
        mPayloadBytesRemaining = 0;
        mComplete = false;
    }

    bool observe(const uint8_t* data, size_t len) {
        if (mComplete)
            return true;
        if (data == nullptr)
            return false;

        for (size_t i = 0; i < len; ++i) {
            const uint8_t byte = data[i];
            if (mPayloadBytesRemaining > 0) {
                if (--mPayloadBytesRemaining == 0) {
                    mComplete = true;
                    return true;
                }
                continue;
            }

            if (mHeaderBytes == 0) {
                if (byte == FRAME_MAGIC)
                    mHeader[mHeaderBytes++] = byte;
                continue;
            }

            mHeader[mHeaderBytes++] = byte;
            if (mHeaderBytes < FRAME_HEADER_BYTES)
                continue;

            const size_t payloadBytes = static_cast<size_t>(mHeader[4]) |
                                        (static_cast<size_t>(mHeader[5]) << 8);
            if (payloadBytes <= MAX_PAYLOAD_BYTES) {
                mHeaderBytes = 0;
                if (payloadBytes == 0) {
                    mComplete = true;
                    return true;
                }
                mPayloadBytesRemaining = payloadBytes;
                continue;
            }

            // This tracker only decides whether initialization completed; the
            // protocol parser separately rejects and discards oversized frames.
            size_t nextMagic = 1;
            while (nextMagic < FRAME_HEADER_BYTES && mHeader[nextMagic] != FRAME_MAGIC)
                ++nextMagic;
            if (nextMagic == FRAME_HEADER_BYTES) {
                mHeaderBytes = 0;
            } else {
                mHeaderBytes = FRAME_HEADER_BYTES - nextMagic;
                memmove(mHeader, mHeader + nextMagic, mHeaderBytes);
            }
        }
        return false;
    }

    bool complete() const { return mComplete; }

private:
    uint8_t mHeader[FRAME_HEADER_BYTES] = {0};
    size_t mHeaderBytes = 0;
    size_t mPayloadBytesRemaining = 0;
    bool mComplete = false;
};

class BleInitializationTimer {
public:
    void start(uint32_t now) {
        mStartedAtMs = now;
        mInitialized = false;
        mExpired = false;
    }

    void confirm() {
        if (!mExpired)
            mInitialized = true;
    }

    bool expireIfDue(uint32_t now, uint32_t timeoutMs) {
        if (mInitialized || mExpired || static_cast<uint32_t>(now - mStartedAtMs) < timeoutMs)
            return false;
        mExpired = true;
        return true;
    }

    bool acceptsInitialization() const { return !mExpired; }
    bool initialized() const { return mInitialized; }

private:
    uint32_t mStartedAtMs = 0;
    bool mInitialized = false;
    bool mExpired = false;
};

class BleRetryTimer {
public:
    void request(uint32_t now, uint32_t delayMs = 0) {
        mDueMs = now + delayMs;
        mPending = true;
    }

    void cancel() { mPending = false; }

    bool takeIfDue(uint32_t now) {
        if (!mPending || static_cast<int32_t>(now - mDueMs) < 0)
            return false;
        mPending = false;
        return true;
    }

    bool pending() const { return mPending; }

private:
    uint32_t mDueMs = 0;
    bool mPending = false;
};

// A failed notify means that slice was not queued. Retry that same slice,
// yielding to the BLE host/controller. Six milliseconds is shorter than a
// connection interval; allow a bounded 250 ms total elapsed time per frame.
// An event may only be dropped before its first byte enters the stream.
template <typename Notify, typename Connected, typename Pause, typename Clock>
BleFrameSendResult sendBleFrame(const uint8_t* data, size_t len, size_t chunk,
                               bool isEvent, Notify notify, Connected connected,
                               Pause pause, Clock clock) {
    if (chunk == 0)
        return {false, 0};
    size_t offset = 0;
    const uint32_t startedAtMs = clock();
    while (offset < len) {
        const size_t n = chunk < len - offset ? chunk : len - offset;
        for (;;) {
            if (!connected() ||
                static_cast<uint32_t>(clock() - startedAtMs) >= 250)
                return {false, offset};
            if (notify(data + offset, n))
                break;
            if (isEvent && offset == 0)
                return {false, offset};
            pause(2);
        }
        offset += n;
        // Pace across short frames too, not only frames longer than four MTUs.
        // A burst of short replies otherwise fills the very same mbuf pool.
        if (offset < len)
            pause(1);
    }
    return {true, offset};
}

} // namespace rinalink
