#pragma once
// RinaLink transport abstraction. One instance per physical carrier (TCP, BLE).
// Threading contract:
//   * Carriers may receive bytes on any task/core. They MUST NOT parse or dispatch;
//     they only append raw bytes to the per-client inbound buffer via
//     transportPushInbound(), which is safe to call from any task (mutex inside).
//   * protocol.cpp drains inbound buffers and dispatches ONLY from the Core-0
//     Arduino loop() (serviceProtocol()). Replies/events are sent from loop() via
//     ITransport::send(), which every carrier must make safe to call from loop().
//   * Client registry contract (transportRegisterClient/transportUnregisterClient):
//     these may be called from ANY task (e.g. the NimBLE host task) but they only
//     claim/release a slot under a spinlock and enqueue a connect/disconnect
//     request; they never touch BlobSession, free buffers, or otherwise tear down
//     client state. The actual finalize (subs reset) / teardown (blob.reset(),
//     clearing transport/carrier, freeing state) happens exclusively at the start
//     of serviceProtocol() on the Core-0 loop task. sendFrame()/
//     serviceProtocolEvents() check a per-slot disconnectPending flag and skip
//     clients that are pending teardown. transportRegisterClient() returns false
//     immediately (no slot claimed) if no free slot has a pre-allocated inbound
//     buffer -- callers must disconnect the peer in that case.
#include <Arduino.h>
#include <stdint.h>
#include <stddef.h>
#include "inbound_frame.h"

namespace rinalink {

enum class Carrier : uint8_t { None = 0, Tcp = 1, Ble = 2 };

struct ClientId { uint8_t slot; };   // index into the client table, 0..MAX_CLIENTS-1

class ITransport {
public:
    virtual ~ITransport() = default;
    virtual Carrier carrier() const = 0;
    // Send one complete framed message (header + payload already assembled).
    // Must be callable from loop(); may slice for BLE MTU internally. Returns false if
    // the client is gone. `isEvent` hints that this is an unsolicited event (as
    // opposed to a reply to a request): carriers that can back-pressure (TCP) may
    // drop an event outright under back-pressure instead of blocking loop().
    virtual bool send(ClientId id, const uint8_t* data, size_t len, bool isEvent = false) = 0;
    // Preferred max payload for chunked blob replies / event throttling hints.
    virtual uint16_t preferredChunkBytes(ClientId id) const = 0;
    virtual void disconnect(ClientId id) = 0;
};

// --- Client registry (implemented in protocol.cpp) ---------------------------------
// Carriers call these when a peer connects/disconnects. Returns false if no slot.
bool transportRegisterClient(ITransport* transport, Carrier carrier, ClientId* outId);
void transportUnregisterClient(ClientId id);
// Append raw bytes to the client's inbound buffer (any task). Returns the number of
// bytes actually accepted (may be less than len if the buffer is full); callers that
// can back-pressure (TCP) should leave any unaccepted bytes in the socket and retry
// next pass. Carriers that cannot back-pressure (BLE) must disconnect the affected
// client if a whole incoming write will not fit; after dropping bytes, neither the
// request sequence nor the next frame boundary is trustworthy.
size_t transportPushInbound(ClientId id, const uint8_t* data, size_t len);
// Bytes currently free in the client's inbound buffer (any task).
size_t transportInboundFree(ClientId id);
// Mark a client's inbound stream as needing a resync: drops any buffered bytes and
// clears any outstanding oversized-payload discard count, then
// causes an ERR(413) frame to be sent to the client on the next serviceProtocol()
// pass. Only use this when the caller knows the next byte begins a new frame.
void transportMarkResyncNeeded(ClientId id);

// Build a framed message into out (capacity >= FRAME_HEADER_BYTES + payloadLen).
size_t transportFrame(uint8_t* out, uint8_t type, uint8_t seq, uint8_t flags,
                      const uint8_t* payload, uint16_t payloadLen);

} // namespace rinalink
