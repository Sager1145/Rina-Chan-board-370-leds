#include "transport_tcp.h"
#include "transport.h"
#include "config.h"
#include "utils.h"
#include "serial_log.h"
#include <WiFi.h>

using rinalink::Carrier;
using rinalink::ClientId;
using rinalink::ITransport;

namespace {

constexpr uint8_t MAX_TCP_SLOTS = 2;
constexpr uint32_t WRITE_DEADLINE_MS = 100;

struct TcpSlot {
    WiFiClient client;
    ClientId id{0xFF};
    bool registered = false;
    uint32_t lastActivityMs = 0;
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
        if (!s || !s->client.connected())
            return false;

        if (isEvent) {
            // Events must never block loop(): drop outright if the socket send
            // buffer cannot take the whole frame right now.
            size_t avail = (size_t)s->client.availableForWrite();
            if (avail < len) {
                ++g_droppedEvents;
                RLOG_DEBUG("TCP", "event=event_dropped avail=%u need=%u total=%u",
                           (unsigned)avail, (unsigned)len, (unsigned)g_droppedEvents);
                return false;
            }
            size_t written = s->client.write(data, len);
            return written == len;
        }

        // Reply: write whatever fits, looping (yielding) up to an overall
        // deadline; a client that cannot drain fast enough gets disconnected
        // rather than blocking loop() indefinitely.
        size_t off = 0;
        uint32_t deadline = millis() + WRITE_DEADLINE_MS;
        while (off < len) {
            if (!s->client.connected())
                return false;
            size_t availNow = (size_t)s->client.availableForWrite();
            if (availNow == 0) {
                if (millisReached(millis(), deadline)) {
                    RLOG_WARN("TCP", "event=write_timeout slot=%u", (unsigned)id.slot);
                    rinalink::transportUnregisterClient(id);
                    return false;
                }
                delay(1);
                continue;
            }
            size_t want = len - off;
            if (want > availNow)
                want = availNow;
            size_t written = s->client.write(data + off, want);
            if (written == 0) {
                if (millisReached(millis(), deadline)) {
                    RLOG_WARN("TCP", "event=write_timeout slot=%u", (unsigned)id.slot);
                    rinalink::transportUnregisterClient(id);
                    return false;
                }
                delay(1);
                continue;
            }
            off += written;
        }
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
        }
    }
}
