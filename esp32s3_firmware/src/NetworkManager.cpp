#include "NetworkManager.h"

#include <cstdio>
#include <cstring>

#include <Arduino.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <WiFi.h>
#include <esp_wifi.h>

namespace rina {
namespace {

constexpr const char* kTextPlain = "text/plain; charset=utf-8";
constexpr const char* kApplicationJson = "application/json";
constexpr const char* kTextHtml = "text/html";
constexpr const char* kCacheImmutable = "public, max-age=31536000, immutable";
constexpr const char* kNoStore = "no-store";
constexpr const char* kUdpTest = "RinaBoardUdpTest";
constexpr const char* kUdpTestReply = "RinaboardIsOn";
constexpr const char* kTimelineLoadRnt = "timeline370LoadRnt|";
constexpr const char* kTimelineStop = "timeline370Stop";
constexpr const char* kRuntimeStopMedia = "runtimeStop|media";

uint32_t ipToU32(IPAddress ip) {
    return static_cast<uint32_t>(ip);
}

bool packetEquals(const uint8_t* data, size_t len, const char* text) {
    if (data == nullptr || text == nullptr) {
        return false;
    }

    size_t expected = 0;
    while (text[expected] != '\0') {
        ++expected;
    }

    while (len > 0 && protocol::isAsciiLineEnd(data[len - 1U])) {
        --len;
    }

    if (len != expected) {
        return false;
    }

    for (size_t i = 0; i < expected; ++i) {
        if (data[i] != static_cast<uint8_t>(text[i])) {
            return false;
        }
    }
    return true;
}

size_t trimmedLength(const uint8_t* data, size_t len) {
    while (len > 0 && protocol::isAsciiLineEnd(data[len - 1U])) {
        --len;
    }
    return len;
}

bool packetStartsWith(const uint8_t* data, size_t len, const char* prefix) {
    if (data == nullptr || prefix == nullptr) {
        return false;
    }
    len = trimmedLength(data, len);

    size_t prefixLen = 0;
    while (prefix[prefixLen] != '\0') {
        ++prefixLen;
    }
    if (len < prefixLen) {
        return false;
    }
    return memcmp(data, prefix, prefixLen) == 0;
}

bool isTokenChar(uint8_t c) {
    return (c >= 'a' && c <= 'z') ||
           (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') ||
           c == '_' ||
           c == '-';
}

bool validAssetToken(const uint8_t* data, size_t len) {
    if (data == nullptr || len == 0 || len > 48U) {
        return false;
    }
    for (size_t i = 0; i < len; ++i) {
        if (!isTokenChar(data[i])) {
            return false;
        }
    }
    return true;
}

bool tokenEquals(const uint8_t* data, size_t len, const char* text) {
    size_t textLen = 0;
    while (text[textLen] != '\0') {
        ++textLen;
    }
    return len == textLen && memcmp(data, text, len) == 0;
}

bool parseLoopFlag(const uint8_t* data, size_t len) {
    return tokenEquals(data, len, "1") ||
           tokenEquals(data, len, "true") ||
           tokenEquals(data, len, "loop");
}

bool copyRntPath(char* out, size_t outLen, const uint8_t* kind, size_t kindLen, const uint8_t* key, size_t keyLen) {
    if (out == nullptr || outLen == 0 || !validAssetToken(kind, kindLen) || !validAssetToken(key, keyLen)) {
        return false;
    }
    if (!(tokenEquals(kind, kindLen, "voice") ||
          tokenEquals(kind, kindLen, "music") ||
          tokenEquals(kind, kindLen, "video"))) {
        return false;
    }

    const int written = snprintf(
        out,
        outLen,
        "%s/resources/%.*s/%.*s.rnt",
        config::ASSET_ROOT,
        static_cast<int>(kindLen),
        reinterpret_cast<const char*>(kind),
        static_cast<int>(keyLen),
        reinterpret_cast<const char*>(key));
    return written > 0 && static_cast<size_t>(written) < outLen;
}

bool parseRntStartCommand(const uint8_t* data, size_t len, protocol::Command& command) {
    if (!packetStartsWith(data, len, kTimelineLoadRnt)) {
        return false;
    }

    len = trimmedLength(data, len);
    const size_t prefixLen = strlen(kTimelineLoadRnt);
    size_t fieldStart = prefixLen;
    const uint8_t* fields[3]{};
    size_t fieldLens[3]{};
    uint8_t field = 0;

    for (size_t i = prefixLen; i <= len; ++i) {
        if (i == len || data[i] == '|') {
            if (field >= 3) {
                return false;
            }
            fields[field] = data + fieldStart;
            fieldLens[field] = i - fieldStart;
            ++field;
            fieldStart = i + 1U;
        }
    }

    if (field < 2) {
        return false;
    }

    command.type = protocol::CommandType::RntStart;
    command.rntLoop = field >= 3 ? parseLoopFlag(fields[2], fieldLens[2]) : false;
    return copyRntPath(command.rntPath, sizeof(command.rntPath), fields[0], fieldLens[0], fields[1], fieldLens[1]);
}

void addCommonHeaders(AsyncWebServerResponse* response) {
    if (response == nullptr) {
        return;
    }
    response->addHeader("X-Content-Type-Options", "nosniff");
    response->addHeader("Access-Control-Allow-Origin", "*");
}

}  // namespace

NetworkManager::NetworkManager()
    : server_(config::HTTP_PORT),
      udp_(),
      commandQueue_(nullptr),
      statsMux_(portMUX_INITIALIZER_UNLOCKED),
      runtimeMux_(portMUX_INITIALIZER_UNLOCKED),
      stats_(),
      runtime_(),
      apIp_(),
      gateway_(),
      netmask_(),
      routesConfigured_(false) {
}

bool NetworkManager::begin() {
    if (stats_.apStarted && stats_.httpStarted && stats_.udpStarted) {
        return true;
    }

    if (commandQueue_ == nullptr) {
        commandQueue_ = xQueueCreate(config::NETWORK_M370_QUEUE_DEPTH, sizeof(protocol::Command));
        if (commandQueue_ == nullptr) {
            return false;
        }
    }

    apIp_.fromString(config::AP_IP);
    gateway_.fromString(config::AP_GATEWAY);
    netmask_.fromString(config::AP_NETMASK);

    WiFi.persistent(false);
    WiFi.mode(WIFI_AP);
    esp_wifi_set_storage(WIFI_STORAGE_RAM);
    WiFi.setSleep(false);
    WiFi.softAPConfig(apIp_, gateway_, netmask_);

    const bool apOk = WiFi.softAP(
        config::AP_SSID,
        config::AP_PASSWORD,
        config::AP_CHANNEL,
        false,
        config::AP_MAX_CLIENTS);

    portENTER_CRITICAL(&statsMux_);
    stats_.apStarted = apOk;
    portEXIT_CRITICAL(&statsMux_);

    if (!apOk) {
        return false;
    }

    configureRoutes();
    server_.begin();

    const bool udpOk = udp_.listen(config::LOCAL_UDP_PORT);
    if (udpOk) {
        udp_.onPacket(&NetworkManager::udpThunk, this);
    }

    portENTER_CRITICAL(&statsMux_);
    stats_.httpStarted = true;
    stats_.udpStarted = udpOk;
    portEXIT_CRITICAL(&statsMux_);

    return udpOk;
}

bool NetworkManager::pollCommand(protocol::Command& out) {
    if (commandQueue_ == nullptr) {
        return false;
    }

    if (xQueueReceive(commandQueue_, &out, 0) != pdTRUE) {
        return false;
    }

    if (out.type == protocol::CommandType::M370Frame) {
        portENTER_CRITICAL(&statsMux_);
        ++stats_.m370Dequeued;
        portEXIT_CRITICAL(&statsMux_);
    }
    return true;
}

void NetworkManager::setRuntimeSnapshot(const NetworkRuntimeSnapshot& snapshot) {
    portENTER_CRITICAL(&runtimeMux_);
    runtime_ = snapshot;
    portEXIT_CRITICAL(&runtimeMux_);
}

NetworkStats NetworkManager::stats() const {
    NetworkStats copy;
    portENTER_CRITICAL(&statsMux_);
    copy = stats_;
    portEXIT_CRITICAL(&statsMux_);
    return copy;
}

NetworkRuntimeSnapshot NetworkManager::runtimeSnapshot() const {
    NetworkRuntimeSnapshot copy;
    portENTER_CRITICAL(&runtimeMux_);
    copy = runtime_;
    portEXIT_CRITICAL(&runtimeMux_);
    return copy;
}

IPAddress NetworkManager::apIp() const {
    return apIp_;
}

void NetworkManager::udpThunk(void* arg, AsyncUDPPacket& packet) {
    auto* self = static_cast<NetworkManager*>(arg);
    if (self != nullptr) {
        self->handleUdpPacket(packet);
    }
}

void NetworkManager::configureRoutes() {
    if (routesConfigured_) {
        return;
    }

    server_.on("/", HTTP_GET, [this](AsyncWebServerRequest* request) {
        handleWebUi(request);
    });
    server_.on("/fwlink", HTTP_GET, [this](AsyncWebServerRequest* request) {
        handleWebUi(request);
    });
    server_.on("/webui_index.html.gz", HTTP_GET, [this](AsyncWebServerRequest* request) {
        handleWebUi(request);
    });
    server_.on("/generate_204", HTTP_GET, [this](AsyncWebServerRequest* request) {
        handleWebUi(request);
    });
    server_.on("/hotspot-detect.html", HTTP_GET, [this](AsyncWebServerRequest* request) {
        handleWebUi(request);
    });
    server_.on("/connecttest.txt", HTTP_GET, [this](AsyncWebServerRequest* request) {
        handleWebUi(request);
    });
    server_.on("/api/status", HTTP_GET, [this](AsyncWebServerRequest* request) {
        handleStatus(request);
    });
    server_.on("/api/request", HTTP_GET, [this](AsyncWebServerRequest* request) {
        handleApiRequest(request);
    });
    server_.on("/api/send", HTTP_GET, [this](AsyncWebServerRequest* request) {
        handleApiRequest(request);
    });
    server_.onNotFound([this](AsyncWebServerRequest* request) {
        handleNotFound(request);
    });

    routesConfigured_ = true;
}

void NetworkManager::handleWebUi(AsyncWebServerRequest* request) {
    portENTER_CRITICAL(&statsMux_);
    ++stats_.httpRequests;
    ++stats_.webuiRequests;
    portEXIT_CRITICAL(&statsMux_);

    if (!LittleFS.exists(config::WEBUI_GZIP_FILE)) {
        sendPlain(request, 503, "webui_index.html.gz missing; run uploadfs");
        return;
    }

    AsyncWebServerResponse* response =
        request->beginResponse(LittleFS, config::WEBUI_GZIP_FILE, kTextHtml, false);
    if (response == nullptr) {
        sendPlain(request, 500, "webui response allocation failed");
        return;
    }

    addCommonHeaders(response);
    response->addHeader("Cache-Control", kCacheImmutable);
    request->send(response);
}

void NetworkManager::handleStatus(AsyncWebServerRequest* request) {
    portENTER_CRITICAL(&statsMux_);
    ++stats_.httpRequests;
    ++stats_.statusRequests;
    portEXIT_CRITICAL(&statsMux_);

    const NetworkStats statsCopy = stats();
    const NetworkRuntimeSnapshot runtimeCopy = runtimeSnapshot();

    AsyncResponseStream* response = request->beginResponseStream(kApplicationJson);
    if (response == nullptr) {
        request->send(500, kTextPlain, "status allocation failed");
        return;
    }

    JsonDocument doc;
    doc["version"] = config::VERSION;
    doc["protocol"] = config::PROTOCOL_VERSION;
    doc["mode"] = "ap";
    doc["ssid"] = config::AP_SSID;
    doc["ip"] = WiFi.softAPIP().toString();
    doc["stations"] = WiFi.softAPgetStationNum();
    doc["bright"] = runtimeCopy.brightnessPct;
    doc["bright_pct"] = runtimeCopy.brightnessPct;
    doc["bright_cap"] = runtimeCopy.brightnessCap;
    doc["face_index"] = runtimeCopy.faceIndex;
    doc["power_budget_ma"] = runtimeCopy.powerBudgetMa;
    doc["battery_mv"] = runtimeCopy.batteryMv;
    doc["charge_mv"] = runtimeCopy.chargeMv;
    doc["settings_dirty"] = runtimeCopy.settingsDirty;
    doc["display_frames"] = runtimeCopy.displayFrames;
    doc["display_dropped"] = runtimeCopy.displayDropped;
    doc["heap_free"] = ESP.getFreeHeap();
    doc["heap_min_free"] = ESP.getMinFreeHeap();

    JsonObject net = doc["network"].to<JsonObject>();
    net["ap"] = statsCopy.apStarted;
    net["http"] = statsCopy.httpStarted;
    net["udp"] = statsCopy.udpStarted;
    net["http_requests"] = statsCopy.httpRequests;
    net["webui_requests"] = statsCopy.webuiRequests;
    net["status_requests"] = statsCopy.statusRequests;
    net["api_requests"] = statsCopy.apiRequestCount;
    net["not_found"] = statsCopy.notFoundRequests;
    net["wifi_boundary_rejects"] = statsCopy.wifiBoundaryRejects;
    net["udp_packets"] = statsCopy.udpPackets;
    net["udp_bytes"] = statsCopy.udpBytes;
    net["udp_replies"] = statsCopy.udpReplies;
    net["m370_ok"] = statsCopy.m370Accepted;
    net["m370_bad"] = statsCopy.m370Rejected;
    net["m370_dequeued"] = statsCopy.m370Dequeued;
    net["rnt_cmd_ok"] = statsCopy.rntCommandAccepted;
    net["rnt_cmd_bad"] = statsCopy.rntCommandRejected;
    net["queue_overflow"] = statsCopy.queueOverflow;
    net["last_m370_ms"] = statsCopy.lastM370Ms;
    net["last_udp_ms"] = statsCopy.lastUdpMs;
    net["next_poll_ms"] = 5000;

    addCommonHeaders(response);
    response->addHeader("Cache-Control", kNoStore);
    serializeJson(doc, *response);
    request->send(response);
}

void NetworkManager::handleApiRequest(AsyncWebServerRequest* request) {
    portENTER_CRITICAL(&statsMux_);
    ++stats_.httpRequests;
    ++stats_.apiRequestCount;
    portEXIT_CRITICAL(&statsMux_);

    if (!request->hasParam("cmd")) {
        sendPlain(request, 400, "ERR:missing-cmd");
        return;
    }

    const String cmd = request->getParam("cmd")->value();
    const uint8_t* data = reinterpret_cast<const uint8_t*>(cmd.c_str());
    const size_t len = cmd.length();

    if (packetEquals(data, len, kUdpTest)) {
        sendPlain(request, 200, kUdpTestReply);
        return;
    }

    if (protocol::hasM370Prefix(data, len)) {
        const bool ok = enqueueM370(data, len, ipToU32(request->client()->remoteIP()), request->client()->remotePort());
        sendPlain(request, ok ? 202 : 400, ok ? "OK:M370" : "ERR:format");
        return;
    }

    if (cmd == "requestState" || cmd == "runtimeStatus") {
        handleStatus(request);
        return;
    }

    if (packetStartsWith(data, len, kTimelineLoadRnt) ||
        packetEquals(data, len, kTimelineStop) ||
        packetEquals(data, len, kRuntimeStopMedia)) {
        const bool ok = enqueueTextCommand(data, len, ipToU32(request->client()->remoteIP()), request->client()->remotePort());
        sendPlain(request, ok ? 202 : 400, ok ? "OK:queued" : "ERR:format");
        return;
    }

    sendPlain(request, 202, "OK");
}

void NetworkManager::handleNotFound(AsyncWebServerRequest* request) {
    portENTER_CRITICAL(&statsMux_);
    ++stats_.httpRequests;
    ++stats_.notFoundRequests;
    portEXIT_CRITICAL(&statsMux_);

    const String path = request->url();
    if (path == "/api/wifi" || path.startsWith("/api/wifi/")) {
        portENTER_CRITICAL(&statsMux_);
        ++stats_.wifiBoundaryRejects;
        portEXIT_CRITICAL(&statsMux_);
        sendPlain(request, 410, "AP-only firmware: STA/WiFi configuration is disabled");
        return;
    }

    sendPlain(request, 404, "Not Found");
}

void NetworkManager::handleUdpPacket(AsyncUDPPacket& packet) {
    const uint8_t* data = packet.data();
    const size_t len = packet.length();
    const uint32_t nowMs = millis();

    portENTER_CRITICAL(&statsMux_);
    ++stats_.udpPackets;
    stats_.udpBytes += static_cast<uint32_t>(len);
    stats_.lastUdpMs = nowMs;
    portEXIT_CRITICAL(&statsMux_);

    if (!isApSubnet(packet.remoteIP())) {
        portENTER_CRITICAL(&statsMux_);
        ++stats_.m370Rejected;
        portEXIT_CRITICAL(&statsMux_);
        return;
    }

    if (packetEquals(data, len, kUdpTest)) {
        packet.write(reinterpret_cast<const uint8_t*>(kUdpTestReply), sizeof("RinaboardIsOn") - 1U);
        portENTER_CRITICAL(&statsMux_);
        ++stats_.udpReplies;
        portEXIT_CRITICAL(&statsMux_);
        return;
    }

    if (!protocol::hasM370Prefix(data, len)) {
        if (packetStartsWith(data, len, kTimelineLoadRnt) ||
            packetEquals(data, len, kTimelineStop) ||
            packetEquals(data, len, kRuntimeStopMedia)) {
            (void)enqueueTextCommand(data, len, ipToU32(packet.remoteIP()), packet.remotePort());
        }
        return;
    }

    (void)enqueueM370(data, len, ipToU32(packet.remoteIP()), packet.remotePort());
}

bool NetworkManager::enqueueM370(const uint8_t* data, size_t len, uint32_t remoteIp, uint16_t remotePort) {
    protocol::Command command;
    command.type = protocol::CommandType::M370Frame;
    command.receivedMs = millis();
    command.remoteIp = remoteIp;
    command.remotePort = remotePort;

    const protocol::ParseResult parsed = protocol::parseM370(data, len, command.m370);
    if (parsed != protocol::ParseResult::Ok) {
        portENTER_CRITICAL(&statsMux_);
        ++stats_.m370Rejected;
        portEXIT_CRITICAL(&statsMux_);
        return false;
    }

    if (!enqueueCommand(command)) {
        return false;
    }

    portENTER_CRITICAL(&statsMux_);
    ++stats_.m370Accepted;
    stats_.lastM370Ms = command.receivedMs;
    portEXIT_CRITICAL(&statsMux_);
    return true;
}

bool NetworkManager::enqueueTextCommand(const uint8_t* data, size_t len, uint32_t remoteIp, uint16_t remotePort) {
    protocol::Command command;
    command.receivedMs = millis();
    command.remoteIp = remoteIp;
    command.remotePort = remotePort;

    const size_t trimmed = trimmedLength(data, len);
    if (packetEquals(data, trimmed, kTimelineStop) || packetEquals(data, trimmed, kRuntimeStopMedia)) {
        command.type = protocol::CommandType::RntStop;
    } else if (!parseRntStartCommand(data, trimmed, command)) {
        portENTER_CRITICAL(&statsMux_);
        ++stats_.rntCommandRejected;
        portEXIT_CRITICAL(&statsMux_);
        return false;
    }

    if (!enqueueCommand(command)) {
        return false;
    }

    portENTER_CRITICAL(&statsMux_);
    ++stats_.rntCommandAccepted;
    portEXIT_CRITICAL(&statsMux_);
    return true;
}

bool NetworkManager::enqueueCommand(const protocol::Command& command) {
    if (commandQueue_ == nullptr) {
        return false;
    }

    if (uxQueueSpacesAvailable(commandQueue_) == 0) {
        portENTER_CRITICAL(&statsMux_);
        ++stats_.queueOverflow;
        portEXIT_CRITICAL(&statsMux_);
        return false;
    }

    if (xQueueSend(commandQueue_, &command, 0) != pdTRUE) {
        portENTER_CRITICAL(&statsMux_);
        ++stats_.queueOverflow;
        portEXIT_CRITICAL(&statsMux_);
        return false;
    }
    return true;
}

bool NetworkManager::isApSubnet(IPAddress ip) const {
    return (ipToU32(ip) & ipToU32(netmask_)) == (ipToU32(apIp_) & ipToU32(netmask_));
}

void NetworkManager::sendPlain(AsyncWebServerRequest* request, int code, const char* body) {
    AsyncWebServerResponse* response = request->beginResponse(code, kTextPlain, body);
    if (response == nullptr) {
        request->send(500);
        return;
    }

    addCommonHeaders(response);
    response->addHeader("Cache-Control", kNoStore);
    request->send(response);
}

}  // namespace rina
