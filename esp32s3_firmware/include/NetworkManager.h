#pragma once

#include <cstdint>

#include <AsyncUDP.h>
#include <ESPAsyncWebServer.h>
#include <IPAddress.h>

#include "Config.h"
#include "Protocol.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

namespace rina {

struct NetworkStats {
    bool apStarted = false;
    bool httpStarted = false;
    bool udpStarted = false;
    uint32_t httpRequests = 0;
    uint32_t webuiRequests = 0;
    uint32_t statusRequests = 0;
    uint32_t apiRequestCount = 0;
    uint32_t notFoundRequests = 0;
    uint32_t wifiBoundaryRejects = 0;
    uint32_t udpPackets = 0;
    uint32_t udpBytes = 0;
    uint32_t udpReplies = 0;
    uint32_t m370Accepted = 0;
    uint32_t m370Rejected = 0;
    uint32_t m370Dequeued = 0;
    uint32_t rntCommandAccepted = 0;
    uint32_t rntCommandRejected = 0;
    uint32_t queueOverflow = 0;
    uint32_t lastM370Ms = 0;
    uint32_t lastUdpMs = 0;
};

struct NetworkRuntimeSnapshot {
    uint8_t brightnessPct = config::DEFAULT_BRIGHTNESS_PCT;
    uint8_t brightnessCap = config::MAX_BRIGHTNESS_DEFAULT;
    uint16_t faceIndex = config::DEFAULT_FACE;
    uint32_t powerBudgetMa = config::POWER_BUDGET_MA_DEFAULT;
    uint32_t displayFrames = 0;
    uint32_t displayDropped = 0;
    uint32_t batteryMv = 0;
    uint32_t chargeMv = 0;
    bool settingsDirty = false;
};

class NetworkManager {
public:
    NetworkManager();

    bool begin();
    bool pollCommand(protocol::Command& out);
    void setRuntimeSnapshot(const NetworkRuntimeSnapshot& snapshot);

    NetworkStats stats() const;
    NetworkRuntimeSnapshot runtimeSnapshot() const;
    IPAddress apIp() const;

private:
    static void udpThunk(void* arg, AsyncUDPPacket& packet);

    void configureRoutes();
    void handleWebUi(AsyncWebServerRequest* request);
    void handleStatus(AsyncWebServerRequest* request);
    void handleApiRequest(AsyncWebServerRequest* request);
    void handleNotFound(AsyncWebServerRequest* request);
    void handleUdpPacket(AsyncUDPPacket& packet);
    bool enqueueM370(const uint8_t* data, size_t len, uint32_t remoteIp, uint16_t remotePort);
    bool enqueueTextCommand(const uint8_t* data, size_t len, uint32_t remoteIp, uint16_t remotePort);
    bool enqueueCommand(const protocol::Command& command);
    bool isApSubnet(IPAddress ip) const;
    void sendPlain(AsyncWebServerRequest* request, int code, const char* body);

    AsyncWebServer server_;
    AsyncUDP udp_;
    QueueHandle_t commandQueue_;
    mutable portMUX_TYPE statsMux_;
    mutable portMUX_TYPE runtimeMux_;
    NetworkStats stats_;
    NetworkRuntimeSnapshot runtime_;
    IPAddress apIp_;
    IPAddress gateway_;
    IPAddress netmask_;
    bool routesConfigured_;
};

}  // namespace rina
