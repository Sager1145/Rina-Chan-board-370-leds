#include "transport_tcp.h"
#include "transport.h"
#include "config.h"
#include "utils.h"
#include "serial_log.h"
#include <WiFi.h>
#include <lwip/sockets.h>
#include <errno.h>
#include "tcp_frame_sender.h"
#include "led_renderer.h"

using rinalink::Carrier;
using rinalink::ClientId;
using rinalink::ITransport;

namespace {

constexpr uint8_t MAX_TCP_SLOTS = 2;

struct TcpSlot {
    WiFiClient client;
    ClientId id{0xFF};
    bool registered = false;
    uint32_t lastActivityMs = 0;
    // Sent bytes don't count: this tracks only inbound data, so a peer that
    // has gone quiet (dropped Wi-Fi, backgrounded app, etc.) loses any hint
    // LED it owns even while we're still pushing frames/status to it.
    uint32_t lastInboundMs = 0;
};

TcpSlot g_slots[MAX_TCP_SLOTS];
WiFiServer g_server(RINALINK_TCP_PORT);
bool g_serverStarted = false;
static uint32_t g_droppedEvents = 0;

TcpSlot* findSlot(ClientId id) {
    for (auto& s : g_slots) {
        if (s.registered && s.id.slot == id.slot)
            return &s;
    }
    return nullptr;
}

class TcpTransport final : public ITransport {
  public:
    Carrier carrier() const override { return Carrier::Tcp; }

    bool send(ClientId id, const uint8_t* data, size_t len, bool isEvent = false) override {
        TcpSlot* s = findSlot(id);
        const uint32_t startedMs = millis();
        const auto logFailure = [&](const char* reason, size_t bytesSent, int socket,
                                    int sendErrno, bool connected, bool deadline) {
            // Header: magic, type, sequence, flags, little-endian payload size.
            // A wholly unsent event is expected back-pressure and stays DEBUG.
            RLOG_AT(!isEvent || bytesSent > 0 ? RINA_LOG_WARN : RINA_LOG_DEBUG, "TCP",
                    "event=send_failed reason=%s slot=%u fd=%d errno=%d connected=%d deadline=%d deadline_ms=250 sent=%u total=%u is_event=%d type=%u seq=%u flags=%u elapsed_ms=%lu",
                    reason, static_cast<unsigned>(id.slot), socket, sendErrno,
                    connected ? 1 : 0, deadline ? 1 : 0,
                    static_cast<unsigned>(bytesSent), static_cast<unsigned>(len), isEvent ? 1 : 0,
                    data && len > 1 ? static_cast<unsigned>(data[1]) : 0U,
                    data && len > 2 ? static_cast<unsigned>(data[2]) : 0U,
                    data && len > 3 ? static_cast<unsigned>(data[3]) : 0U,
                    static_cast<unsigned long>(millis() - startedMs));
        };
        if (!s || !s->client.connected()) {
            logFailure(s ? "disconnected" : "slot_missing", 0, s ? s->client.fd() : -1,
                       0, false, false);
            return false;
        }

        // NetworkClient inherits Print::availableForWrite(), which returns 0
        // in the pinned Arduino 3.3.9 core. NetworkClient::write() also retries
        // select() internally for seconds, outside any deadline around it.
        // Use the socket's nonblocking send directly so this layer owns pacing.
        const int socket = s->client.fd();
        int lastSendErrno = 0;
        bool brokenSocket = false;
        bool predicateDisconnected = false;
        const auto result = rinalink::sendTcpFrame(
            data, len, isEvent,
            [&](const uint8_t* bytes, size_t count) -> ptrdiff_t {
                const int n = ::send(socket, bytes, count, MSG_DONTWAIT);
                if (n >= 0)
                    return n;
                // connected()/logging may change errno, so retain the syscall's
                // value before calling either or consulting the retry policy.
                const int sendErrno = errno;
                lastSendErrno = sendErrno;
                const bool retryable = sendErrno == EAGAIN || sendErrno == EWOULDBLOCK || sendErrno == EINTR;
                brokenSocket = !retryable;
                return retryable ? -1 : -2;
            },
            [&]() {
                const bool connected = socket >= 0 && s->client.fd() == socket && s->client.connected();
                predicateDisconnected = !connected;
                return connected;
            },
            [](uint32_t ms) { delay(ms); },
            []() { return millis(); });
        if (!result.complete) {
            const bool deadline = !predicateDisconnected && !brokenSocket &&
                                  static_cast<uint32_t>(millis() - startedMs) >= 250;
            const char* reason = predicateDisconnected ? "disconnected" :
                                 brokenSocket ? "socket_error" :
                                 deadline ? "deadline" : "event_backpressure";
            logFailure(reason, result.bytesSent, socket, lastSendErrno,
                       !predicateDisconnected, deadline);
            if (!isEvent || result.bytesSent > 0)
                rinalink::transportUnregisterClient(id);
            else
                ++g_droppedEvents;
            return false;
        }
        s->lastActivityMs = millis();
        return true;
    }

    uint16_t preferredChunkBytes(ClientId /*id*/) const override { return 4032; }

    void disconnect(ClientId id) override {
        TcpSlot* s = findSlot(id);
        if (!s)
            return;
        s->client.stop();
        s->registered = false;
    }
};

TcpTransport g_transport;

void closeSlot(TcpSlot& s) {
    if (s.registered) {
        transportUnregisterClient(s.id);
        s.registered = false;
    }
    s.client.stop();
}

} // namespace

void tcpTransportBegin() {
    // Server (re)start happens lazily in service() once Wi-Fi is up; nothing to
    // do here besides making sure the port is configured.
}

void tcpTransportService() {
    // (Re)start the listener once any interface is up (STA or AP); WiFi.getMode()
    // is WIFI_OFF only when neither is active. Stop it when Wi-Fi goes down.
    bool ifaceUp = (WiFi.getMode() != WIFI_OFF);
    if (ifaceUp && !g_serverStarted) {
        g_server.begin();
        g_server.setNoDelay(true);
        g_serverStarted = true;
        RLOG_INFO("TCP", "event=listen port=%u", (unsigned)RINALINK_TCP_PORT);
    } else if (!ifaceUp && g_serverStarted) {
        for (auto& s : g_slots)
            closeSlot(s);
        g_server.end();
        g_serverStarted = false;
    }
    if (!g_serverStarted)
        return;

    // Accept a new client into a free slot.
    if (g_server.hasClient()) {
        WiFiClient incoming = g_server.accept();
        int freeIdx = -1;
        for (int i = 0; i < MAX_TCP_SLOTS; i++) {
            if (!g_slots[i].registered) {
                freeIdx = i;
                break;
            }
        }
        if (freeIdx < 0) {
            incoming.stop(); // no room; refuse
        } else {
            TcpSlot& s = g_slots[freeIdx];
            s.client = incoming;
            s.client.setNoDelay(true);
            s.lastActivityMs = millis();
            s.lastInboundMs = millis();
            if (transportRegisterClient(&g_transport, Carrier::Tcp, &s.id)) {
                s.registered = true;
                RLOG_INFO("TCP", "event=connect slot=%d", freeIdx);
            } else {
                s.client.stop();
            }
        }
    }

    uint8_t buf[512];
    for (auto& s : g_slots) {
        if (!s.registered)
            continue;
        if (!s.client.connected()) {
            RLOG_INFO("TCP", "event=disconnect");
            closeSlot(s);
            continue;
        }
        int avail = s.client.available();
        if (avail > 0) {
            // Back-pressure: never read more than the inbound buffer has room
            // for; leftover bytes stay queued in the socket for the next pass.
            size_t free = rinalink::transportInboundFree(s.id);
            size_t toRead = (size_t)avail;
            if (toRead > free)
                toRead = free;
            if (toRead > 0) {
                s.lastActivityMs = millis();
                s.lastInboundMs = millis();
                size_t remaining = toRead;
                while (remaining > 0) {
                    size_t want = remaining > sizeof(buf) ? sizeof(buf) : remaining;
                    int n = s.client.read(buf, (int)want);
                    if (n <= 0)
                        break;
                    transportPushInbound(s.id, buf, (size_t)n);
                    remaining -= (size_t)n;
                }
            }
        } else if (millisElapsed(millis(), s.lastActivityMs, TCP_IDLE_TIMEOUT_MS)) {
            RLOG_INFO("TCP", "event=idle_timeout");
            closeSlot(s);
            continue;
        }
        // Doesn't disconnect and doesn't touch lastActivityMs/idle-disconnect
        // semantics above; just drops a hint LED this peer may still own once
        // it's gone quiet inbound. s.id.slot is the protocol client-table
        // index (the hint owner slot), not this TCP array index.
        if (millisElapsed(millis(), s.lastInboundMs, TCP_HINT_SILENCE_MS))
            clearHintLedOwnedBy(s.id.slot);
    }
}
