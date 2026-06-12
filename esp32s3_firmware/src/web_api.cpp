#include "web_api.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "storage.h"
#include "faces.h"
#include "buttons.h"
#include "power_monitor.h"
#include "web_json.h"
#include "psram_json.h"
#include <DNSServer.h>
#include <WebServer.h>
#include <WiFi.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <pgmspace.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>


// 本文件注册 SoftAP、DNS captive portal 和 HTTP API 路由；注释保留必要 English identifier，便于和代码/API 对照。
static WebServer server(HTTP_PORT);
static DNSServer dnsServer;
static bool dnsServerActive = false;

// ---------------------------------------------------------------------------
// 内部辅助函数（Internal helpers） 相关代码，维护 注册 SoftAP、DNS captive portal 和 HTTP API 路由。
// ---------------------------------------------------------------------------

static const char CONTENT_TYPE_JSON_UTF8[] = "application/json; charset=utf-8";
static const char CONTENT_TYPE_HTML_UTF8[] = "text/html; charset=utf-8";
static const char CONTENT_TYPE_TEXT_PLAIN[] = "text/plain";
static const uint16_t STATIC_STREAM_CHUNK_BYTES = 8192;
static const TickType_t WEB_YIELD_TICKS = pdMS_TO_TICKS(1);
static const size_t WEB_YIELD_EVERY_CHUNKS = 4;

struct ScrollStateSnapshot {
    bool     firmwareScrollActive       = false;
    bool     firmwareScrollPaused       = false;
    bool     firmwareScrollUserPaused   = false;
    bool     firmwareScrollSystemPaused = false;
    bool     restoreAutoAfterScroll     = false;
    uint16_t scrollFrameCount           = 0;
    uint16_t scrollFrameIndex           = 0;
    uint16_t scrollIntervalMs           = DEFAULT_SCROLL_INTERVAL_MS;

    bool scrolling() const {
        return firmwareScrollActive || firmwareScrollPaused;
    }
};

static bool pathEndsWithIgnoreCase(const String& path, const char* suffix) {
    const size_t suffixLen = strlen(suffix);
    if (suffixLen == 0 || path.length() < suffixLen) return false;

    const size_t offset = path.length() - suffixLen;
    for (size_t i = 0; i < suffixLen; ++i) {
        const char a = static_cast<char>(tolower(static_cast<unsigned char>(path.charAt(offset + i))));
        const char b = static_cast<char>(tolower(static_cast<unsigned char>(suffix[i])));
        if (a != b) return false;
    }
    return true;
}

static const char* contentTypeFor(const String& path) {
    if (pathEndsWithIgnoreCase(path, ".html") || pathEndsWithIgnoreCase(path, ".htm")) {
        return CONTENT_TYPE_HTML_UTF8;
    }
    if (pathEndsWithIgnoreCase(path, ".css")) return "text/css; charset=utf-8";
    if (pathEndsWithIgnoreCase(path, ".js")) return "application/javascript; charset=utf-8";
    if (pathEndsWithIgnoreCase(path, ".json")) return CONTENT_TYPE_JSON_UTF8;
    if (pathEndsWithIgnoreCase(path, ".svg")) return "image/svg+xml";
    if (pathEndsWithIgnoreCase(path, ".png")) return "image/png";
    if (pathEndsWithIgnoreCase(path, ".jpg") || pathEndsWithIgnoreCase(path, ".jpeg")) {
        return "image/jpeg";
    }
    if (pathEndsWithIgnoreCase(path, ".ico")) return "image/x-icon";
    if (pathEndsWithIgnoreCase(path, ".ttf")) return "font/ttf";
    if (pathEndsWithIgnoreCase(path, ".woff2")) return "font/woff2";
    if (pathEndsWithIgnoreCase(path, ".otf")) return "font/otf";
    return "application/octet-stream";
}

static void addCorsHeaders() {
    server.sendHeader("Access-Control-Allow-Origin",  "*");
    server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
    server.sendHeader("Cache-Control",                "no-store");
}

static void addStaticAssetHeaders(const String& path) {
    server.sendHeader("Access-Control-Allow-Origin", "*");
    if (path.endsWith(".html") || path.endsWith(".htm")) {
        server.sendHeader("Cache-Control", "no-cache");
    } else {
        server.sendHeader("Cache-Control", "public, max-age=31536000, immutable");
    }
}

static bool littleFsExistsLocked(const String& path) {
    bool exists = false;
    withHardwareBusLock([&]() {
        exists = LittleFS.exists(path);
    });
    return exists;
}

static File littleFsOpenLocked(const String& path, const char* mode) {
    File file;
    withHardwareBusLock([&]() {
        file = LittleFS.open(path, mode);
    });
    return file;
}

static size_t fileSizeLocked(File& file) {
    size_t size = 0;
    withHardwareBusLock([&]() {
        size = file.size();
    });
    return size;
}

static void closeFileLocked(File& file) {
    withHardwareBusLock([&]() {
        file.close();
    });
}

static void streamFileChunked(File& file, const char* contentType) {
    server.setContentLength(fileSizeLocked(file));
    server.send(200, contentType, "");

    uint8_t* heapBuffer = static_cast<uint8_t*>(malloc(STATIC_STREAM_CHUNK_BYTES));
    uint8_t  stackFallback[512];
    uint8_t* buffer    = heapBuffer ? heapBuffer : stackFallback;
    const size_t chunkBytes = heapBuffer ? STATIC_STREAM_CHUNK_BYTES : sizeof(stackFallback);

    size_t chunksSent = 0;
    while (true) {
        size_t bytesRead = 0;
        bool hasData = false;

        withHardwareBusLock([&]() {
            hasData = file.available();
            if (hasData) {
                bytesRead = file.read(buffer, chunkBytes);
            }
        });

        if (!hasData || bytesRead == 0) break;
        server.sendContent(reinterpret_cast<const char*>(buffer), bytesRead);
        if ((++chunksSent % WEB_YIELD_EVERY_CHUNKS) == 0) vTaskDelay(WEB_YIELD_TICKS);
    }

    if (heapBuffer) free(heapBuffer);
}

static void sendJsonDocument(int status, JsonDocument& doc) {
    String out;
    serializeJson(doc, out);
    addCorsHeaders();
    server.send(status, CONTENT_TYPE_JSON_UTF8, out);
}

static void sendError(int status, const String& message) {
    DynamicJsonDocument doc(512);
    doc["ok"]    = false;
    doc["error"] = message;
    addCorsHeaders();
    String out;
    serializeJson(doc, out);
    server.send(status, CONTENT_TYPE_JSON_UTF8, out);
}

static uint16_t statusNextPollMs(bool scrolling, bool summaryOnly) {
    if (runtimeState().deferredFaceRestoreActive) return 250;
    if (scrolling) return summaryOnly ? 250 : 1000;
    return 1000;
}

static ScrollStateSnapshot readScrollStateSnapshot() {
    ScrollStateSnapshot snapshot;
    withScrollLock([&]() {
        snapshot.firmwareScrollActive       = runtimeState().firmwareScrollActive;
        snapshot.firmwareScrollPaused       = runtimeState().firmwareScrollPaused;
        snapshot.firmwareScrollUserPaused   = runtimeState().firmwareScrollUserPaused;
        snapshot.firmwareScrollSystemPaused = runtimeState().firmwareScrollSystemPaused;
        snapshot.restoreAutoAfterScroll     = runtimeState().restoreAutoAfterScroll;
        snapshot.scrollFrameCount           = runtimeState().scrollFrameCount;
        snapshot.scrollFrameIndex           = runtimeState().scrollFrameIndex;
        snapshot.scrollIntervalMs           = runtimeState().scrollIntervalMs;
    });
    return snapshot;
}

static void addScrollStateFields(JsonObject target, const ScrollStateSnapshot& snapshot) {
    target["firmwareScrollActive"]       = snapshot.firmwareScrollActive;
    target["firmwareScrollPaused"]       = snapshot.firmwareScrollPaused;
    target["firmwareScrollUserPaused"]   = snapshot.firmwareScrollUserPaused;
    target["firmwareScrollSystemPaused"] = snapshot.firmwareScrollSystemPaused;
    target["restoreAutoAfterScroll"]     = snapshot.restoreAutoAfterScroll;
    target["scrollFrameCount"]           = snapshot.scrollFrameCount;
    target["scrollFrameIndex"]           = snapshot.scrollFrameIndex;
    target["scrollIntervalMs"]           = snapshot.scrollIntervalMs;
}

static void addScrollStopEvent(JsonObject target) {
    JsonObject scrollStopEvent = target.createNestedObject("scrollStopEvent");
    scrollStopEvent["seq"]    = runtimeState().scrollStopEventSeq;
    scrollStopEvent["ms"]     = runtimeState().scrollStopEventMs;
    scrollStopEvent["button"] = runtimeState().scrollStopEventButton;
    scrollStopEvent["source"] = runtimeState().scrollStopEventSource;
    scrollStopEvent["reason"] = runtimeState().scrollStopEventReason;
}

static void addCurrentFaceFields(JsonObject target) {
    if (runtimeAutoFaceCount() == 0 || runtimeState().autoFaceIndex >= runtimeAutoFaceCount()) return;

    const RuntimeFace& face = runtimeAutoFaces()[runtimeState().autoFaceIndex];
    target["autoFaceId"]   = face.id;
    target["autoFaceName"] = face.name;
}

static void addPowerStatus(JsonObject power, bool includeSlow = true, bool clearDirty = false) {
    const bool batteryOk = powerStatus.batteryValid;
    const bool chargeOk = powerStatus.chargeValid;
    const bool chargerPresent = chargeOk && powerStatus.charging;
    const bool batteryUnpowered = !chargerPresent &&
        (powerStatus.batteryDisconnected || powerStatus.batteryLowVoltageUnpowered);
    const bool batteryPowered = batteryOk && !batteryUnpowered;
    const char* batteryIconClass = "status-dot dim";
    const char* batteryIconColor = "#9aa6b2";
    const char* batteryStateText = batteryPowered ? "电池" : "未上电";
    if (batteryPowered) {
        if (powerStatus.batteryPercent < 10) {
            batteryIconClass = "status-dot danger";
            batteryIconColor = "#ef4444";
        } else if (powerStatus.batteryPercent < 30) {
            batteryIconClass = "status-dot warn";
            batteryIconColor = "#f59e0b";
        } else {
            batteryIconClass = "status-dot";
            batteryIconColor = "#59d98e";
        }
    }

    const char* chargeIconClass = chargerPresent ? "status-dot" : "status-dot dim";
    const char* chargeIconColor = chargerPresent ? "#59d98e" : "#9aa6b2";

    power["partial"]         = !includeSlow;
    power["chargeGpio"]      = CHARGE_ADC_PIN;
    if (powerStatus.chargeValid)  power["charging"]       = powerStatus.charging;
    else                          power["charging"]       = nullptr;
    power["chargeValid"]      = powerStatus.chargeValid;
    power["chargeIconClass"]  = chargeIconClass;
    power["chargeIconColor"]  = chargeIconColor;
    power["ok"]               = powerStatus.batteryValid || powerStatus.chargeValid;
    power["chargeSampleMs"]   = CHARGE_SAMPLE_MS;
    power["slowPublishMs"]    = POWER_WEB_SLOW_PUBLISH_MS;
    power["batteryPowered"]   = batteryPowered;
    power["batteryDisconnected"] = powerStatus.batteryDisconnected;
    power["batteryLowVoltageUnpowered"] = powerStatus.batteryLowVoltageUnpowered;
    power["batteryStateText"] = batteryStateText;
    power["batteryIconClass"] = batteryIconClass;
    power["batteryIconColor"] = batteryIconColor;

    if (includeSlow) {
        power["batteryGpio"]      = BATTERY_ADC_PIN;
        if (powerStatus.batteryValid) power["vbat"]           = powerStatus.vbat;
        else                          power["vbat"]           = nullptr;
        if (powerStatus.batteryValid) power["batteryPercent"] = powerStatus.batteryPercent;
        else                          power["batteryPercent"] = nullptr;
        if (powerStatus.chargeValid)  power["vcharge"]        = powerStatus.vcharge;
        else                          power["vcharge"]        = nullptr;
        power["batteryAdcMv"]     = powerStatus.batteryAdcMv;
        power["batteryPrevAdcMv"] = powerStatus.batteryPrevAdcMv;
        power["batteryDisconnectDropMv"] = powerStatus.batteryDisconnectDropMv;
        power["batteryDisconnectDropThresholdMv"] = BATTERY_DISCONNECT_ADC_DROP_MV;
        power["batteryDisconnectLowThresholdMv"]  = BATTERY_DISCONNECT_ADC_LOW_MV;
        power["batteryReconnectThresholdMv"]      = BATTERY_RECONNECT_ADC_MV;
        power["batteryUnpoweredLowThreshold"] = BATTERY_UNPOWERED_LOW_V;
        if (isfinite(powerStatus.batteryLastInstantVbat)) power["batteryLastInstantVbat"] = powerStatus.batteryLastInstantVbat;
        else power["batteryLastInstantVbat"] = nullptr;
        power["batteryDisconnectedSinceMs"] = powerStatus.batteryDisconnectedSinceMs;
        power["lastBatteryDisconnectEventMs"] = powerStatus.lastBatteryDisconnectEventMs;
        power["chargeAdcMv"]      = powerStatus.chargeAdcMv;
        power["batteryValid"]     = powerStatus.batteryValid;
        power["batteryRangeMin"]  = powerStatus.batteryCalibMinV;
        power["batteryRangeMax"]  = powerStatus.batteryCalibMaxV;
        power["batteryNominalMin"] = BATTERY_EMPTY_V;
        power["batteryNominalMax"] = BATTERY_FULL_V;
        power["batteryCalibLoaded"] = powerStatus.batteryCalibLoaded;
        power["batteryCalibDirty"] = powerStatus.batteryCalibDirty;
        power["batteryCalibPath"] = BATTERY_CALIB_PATH;
        power["chargeThreshold"]  = CHARGE_PRESENT_V;
        power["batterySampleMs"]  = BATTERY_SAMPLE_MS;
        power["lastBatteryMs"]    = powerStatus.lastBatteryMs;
        power["lastChargeMs"]     = powerStatus.lastChargeMs;
        power["lastCalibMaxMs"]   = powerStatus.lastCalibMaxMs;
        power["lastCalibMinMs"]   = powerStatus.lastCalibMinMs;
    }

    if (clearDirty) {
        powerStatus.webFastDirty = false;
        if (includeSlow) powerStatus.webSlowDirty = false;
    }
}

static String requestBody() {
    return server.hasArg("plain") ? server.arg("plain") : "";
}

static bool parseJsonBody(JsonDocument& doc, String& error) {
    const String body = requestBody();
    if (body.isEmpty()) { error = "empty JSON body"; return false; }
    DeserializationError err = deserializeJson(doc, body);
    if (err) { error = String("invalid JSON: ") + err.c_str(); return false; }
    return true;
}

static uint16_t rawScrollIntervalToUint16(uint32_t rawInterval) {
    return static_cast<uint16_t>(rawInterval > 65535UL ? 65535UL : rawInterval);
}

static bool scrollIntervalFromFps(float fps, uint16_t& intervalMs) {
    if (fps <= 0.0f) return false;
    intervalMs = static_cast<uint16_t>(roundf(1000.0f / fps));
    return true;
}

static bool scrollTimingFromBody(const String& body, uint16_t& intervalMs) {
    uint32_t intervalValue = 0;
    if (jsonUintField(body, "intervalMs", intervalValue) && intervalValue > 0) {
        intervalMs = rawScrollIntervalToUint16(intervalValue);
        return true;
    }

    float fps = 0.0f;
    return jsonFloatField(body, "fps", fps) && scrollIntervalFromFps(fps, intervalMs);
}

static bool commandUintField(JsonDocument& doc, JsonVariant payload,
                             const char* key, uint32_t& value) {
    if (!payload.isNull() && payload[key].is<uint32_t>()) {
        value = payload[key].as<uint32_t>();
        return true;
    }
    if (doc[key].is<uint32_t>()) {
        value = doc[key].as<uint32_t>();
        return true;
    }
    return false;
}

static bool commandFloatField(JsonDocument& doc, JsonVariant payload,
                              const char* key, float& value) {
    if (!payload.isNull() && (payload[key].is<float>() || payload[key].is<int>())) {
        value = payload[key].as<float>();
        return true;
    }
    if (doc[key].is<float>() || doc[key].is<int>()) {
        value = doc[key].as<float>();
        return true;
    }
    return false;
}

static bool commandBoolField(JsonDocument& doc, JsonVariant payload,
                             const char* key, bool& value) {
    if (!payload.isNull() && payload[key].is<bool>()) {
        value = payload[key].as<bool>();
        return true;
    }
    if (doc[key].is<bool>()) {
        value = doc[key].as<bool>();
        return true;
    }
    return false;
}

static void pauseFirmwareScrollIfActive(bool& changed) {
    changed = setFirmwareScrollUserPaused(true);
}

static void resumeFirmwareScrollIfCached(bool& changed, bool requirePaused = false) {
    bool canResume = false;
    withScrollLock([&]() {
        canResume = runtimeState().scrollFrameCount > 0 &&
                    (!requirePaused || runtimeState().firmwareScrollPaused);
    });
    if (canResume) changed = setFirmwareScrollUserPaused(false);
}

static bool serveStaticFile(String path) {
    if (!runtimeFsMounted()) return false;
    if (path == "/") path = "/index.html";
    if (path.endsWith("/")) path += "index.html";

    const bool clientAcceptsGzip = server.hasHeader("Accept-Encoding") &&
        server.header("Accept-Encoding").indexOf("gzip") >= 0;
    const String gzPath   = path + ".gz";
    const bool   gzExists  = littleFsExistsLocked(gzPath);
    const bool   rawExists = littleFsExistsLocked(path);
    if (!gzExists && !rawExists) return false;

    const bool   useGzip  = gzExists && (clientAcceptsGzip || !rawExists);
    const String diskPath = useGzip ? gzPath : path;

    File file = littleFsOpenLocked(diskPath, "r");
    if (!file) return false;

    addStaticAssetHeaders(path);
    if (useGzip) {
        server.sendHeader("Content-Encoding", "gzip");
        server.sendHeader("Vary",             "Accept-Encoding");
    }
    streamFileChunked(file, contentTypeFor(path));
    closeFileLocked(file);
    return true;
}

static const char FILESYSTEM_ERROR_HTML[] PROGMEM = R"rawliteral(<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LittleFS not mounted</title><style>body{margin:0;padding:28px;background:#0f1117;color:#f4f7fb;font-family:system-ui,-apple-system,Segoe UI,sans-serif;line-height:1.5}code{background:#1e2430;padding:2px 5px;border-radius:5px}.box{max-width:720px;margin:auto;border:1px solid #2b3344;border-radius:12px;padding:20px;background:#161a24}</style></head><body><main class="box"><h1>LittleFS data is not mounted</h1><p>The ESP32-S3 AP is running, but the WebUI files are missing or the filesystem failed to mount.</p><p>Upload the data image, then reboot:</p><p><code>pio run -t uploadfs</code></p><p>Expected files include <code>/index.html</code> and <code>/resources/saved_faces.json</code>.</p></main></body></html>)rawliteral";

static void sendFilesystemErrorPage() {
    addCorsHeaders();
    server.send_P(503, CONTENT_TYPE_HTML_UTF8, FILESYSTEM_ERROR_HTML);
}

// ---------------------------------------------------------------------------
// 路由处理函数（Route handlers） 相关代码，维护 注册 SoftAP、DNS captive portal 和 HTTP API 路由。
// ---------------------------------------------------------------------------

static void handleOptions() {
    addCorsHeaders();
    server.send(204, CONTENT_TYPE_TEXT_PLAIN, "");
}

static void handleApiStatus() {
    servicePowerMonitor();

    const ScrollStateSnapshot scrollState = readScrollStateSnapshot();
    const bool scrolling   = scrollState.scrolling();
    const bool runtimeOnly = server.hasArg("runtimeOnly");
    const bool summaryOnly = runtimeOnly || server.hasArg("summary") || server.hasArg("noFrame");
    const uint32_t version = runtimeStateVersion();
    const bool hasSince = server.hasArg("since");
    const bool includeSlowPower = !hasSince || powerStatus.webSlowDirty || server.hasArg("fullPower");

    if (hasSince) {
        const uint32_t since = static_cast<uint32_t>(strtoul(server.arg("since").c_str(), nullptr, 10));
        if (since == version) {
            DynamicJsonDocument unchanged(192);
            unchanged["ok"]           = true;
            unchanged["v"]            = version;
            unchanged["version"]      = version;
            unchanged["unchanged"]    = true;
            unchanged["next_poll_ms"] = statusNextPollMs(scrolling, summaryOnly);
            sendJsonDocument(200, unchanged);
            return;
        }
    }

    PsramJsonDocument doc((runtimeOnly || scrolling || summaryOnly) ? 4096 : 6144);
    doc["ok"]     = true;
    doc["v"]      = version;
    doc["version"] = version;
    doc["next_poll_ms"] = statusNextPollMs(scrolling, summaryOnly);
    doc["device"] = "RinaChanBoard";
    doc["uptimeMs"] = millis() - runtimeState().bootMs;
    if (runtimeOnly) doc["runtimeOnly"] = true;

    JsonObject ap = doc.createNestedObject("ap");
    ap["ssid"]    = AP_SSID;
    ap["ip"]      = WiFi.softAPIP().toString();
    ap["domain"]  = AP_DOMAIN;
    ap["url"]     = String("http://") + AP_DOMAIN + "/";
    ap["clients"] = WiFi.softAPgetStationNum();

    addPowerStatus(doc.createNestedObject("power"), includeSlowPower, true);

    JsonObject renderer = doc.createNestedObject("renderer");
    renderer["color"]                   = runtimeState().colorHex;
    renderer["brightness"]              = runtimeState().brightness;
    renderer["brightnessMin"]           = MIN_BRIGHTNESS;
    renderer["brightnessMax"]           = MAX_BRIGHTNESS;
    renderer["mode"]                    = runtimeState().mode;
    renderer["playback"]                = runtimeState().playback;
    renderer["paused"]                  = runtimeState().paused;
    renderer["autoIntervalMs"]          = runtimeState().autoIntervalMs;
    renderer["autoFaceCount"]           = runtimeAutoFaceCount();
    renderer["autoFaceIndex"]           = runtimeState().autoFaceIndex;
    addScrollStateFields(renderer, scrollState);
    renderer["deferredFaceRestoreActive"] = runtimeState().deferredFaceRestoreActive;
    renderer["scrollMaxFrames"]         = MAX_SCROLL_FRAMES;
    renderer["m370FrameMinIntervalMs"]  = M370_FRAME_MIN_INTERVAL_MS;
    renderer["m370FrameQueueDepth"]     = M370_FRAME_QUEUE_DEPTH;
    renderer["m370FrameQueueCount"]     = queuedM370FrameCount();
    addCurrentFaceFields(renderer);
    if (!scrolling && !summaryOnly) {
        renderer["lastM370"] = runtimeState().lastM370;
        renderer["lit"]      = countLitLeds();
    } else if (summaryOnly) {
        renderer["lastM370Skipped"] = true;
    } else {
        renderer["lastM370Deferred"] = true;
    }
    renderer["lastReason"] = runtimeState().lastReason;

    addScrollStopEvent(renderer);

    JsonObject memory = doc.createNestedObject("memory");
    memory["freeHeap"]               = static_cast<uint32_t>(ESP.getFreeHeap());
    memory["psramSize"]              = static_cast<uint32_t>(ESP.getPsramSize());
    memory["freePsram"]              = static_cast<uint32_t>(ESP.getFreePsram());
    memory["scrollBufferBytes"]      = static_cast<uint32_t>(runtimeScrollFrameBufferBytes());
    memory["scrollBufferReady"]      = runtimeScrollFrameBufferReady();
    memory["scrollBufferInPsram"]    = runtimeScrollFrameBufferInPsram();

    if (runtimeOnly) {
        sendJsonDocument(200, doc);
        return;
    }

    JsonObject matrix = doc.createNestedObject("matrix");
    matrix["leds"]                   = LED_COUNT;
    matrix["m370HexChars"]           = M370_HEX_CHARS;
    matrix["gpio"]                   = LED_PIN;
    matrix["m370BitOrder"]           = "logical_row_major";
    matrix["physicalWiring"]         = SERPENTINE_WIRING ? "serpentine" : "linear";
    matrix["serpentineOddRowsReversed"] = SERPENTINE_ODD_ROWS_REVERSED;

    JsonObject endpoints = doc.createNestedObject("endpoints");
    endpoints["frame"]      = "/api/frame";
    endpoints["command"]    = "/api/command";
    endpoints["scroll"]     = "/api/scroll";
    endpoints["savedFaces"] = "/api/saved_faces";
    endpoints["power"]      = "/api/power";
    endpoints["status"]     = "/api/status";

    JsonObject storage = doc.createNestedObject("storage");
    storage["mounted"]           = runtimeFsMounted();
    storage["savedFacesPath"]    = SAVED_FACES_PATH;
    storage["savedFacesExists"]  = runtimeFsMounted() && littleFsExistsLocked(SAVED_FACES_PATH);
    storage["settingsPath"]      = SETTINGS_PATH;
    storage["settingsExists"]    = runtimeFsMounted() && littleFsExistsLocked(SETTINGS_PATH);
    if (runtimeFsMounted() && !scrolling && !summaryOnly) {
        withHardwareBusLock([&]() {
            storage["totalBytes"] = static_cast<uint32_t>(LittleFS.totalBytes());
            storage["usedBytes"]  = static_cast<uint32_t>(LittleFS.usedBytes());
        });
    } else if (summaryOnly) {
        storage["capacitySkippedInSummary"] = true;
    } else if (scrolling) {
        storage["capacityDeferredDuringScroll"] = true;
    }

    JsonObject stats = doc.createNestedObject("stats");
    stats["framesAccepted"]    = runtimeState().framesAccepted;
    stats["framesRejected"]    = runtimeState().framesRejected;
    stats["framesQueued"]      = runtimeState().framesQueued;
    stats["framesDequeued"]    = runtimeState().framesDequeued;
    stats["framesDropped"]     = runtimeState().framesDropped;
    stats["commandsAccepted"]  = runtimeState().commandsAccepted;
    stats["commandsRejected"]  = runtimeState().commandsRejected;
    stats["savedFacesWrites"]  = runtimeState().savedFacesWrites;
    stats["settingsWrites"]    = runtimeState().settingsWrites;

    sendJsonDocument(200, doc);
}

static void handleApiPower() {
    servicePowerMonitor();

    DynamicJsonDocument doc(3072);
    doc["ok"] = true;
    addPowerStatus(doc.createNestedObject("power"), true, true);
    sendJsonDocument(200, doc);
}

static void handleApiFrame() {
    String error;
    PsramJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) { sendError(400, error); return; }

    const char* m370 = doc["m370"] | "";
    if (strlen(m370) == 0) {
        ++runtimeState().framesRejected;
        sendError(400, "missing m370");
        return;
    }

    const char* mode = doc["mode"] | "";
    if (strlen(mode) == 0) mode = doc["playback"] | "idle";
    const String reason = doc["reason"] | "api_frame";

    if (!isScrollPlayback(String(mode))) {
        stopFirmwareScroll(false);
    }
    if (reason.startsWith("custom_") || reason.startsWith("parts_")) {
        setMode("manual", false);
    }
    runtimeState().playback = mode;

    if (!applyM370(m370, reason, error)) { sendError(400, error); return; }

    const char* faceId = doc["faceId"] | "";
    if (strlen(faceId) > 0 && ensureSavedFacesLoaded()) {
        for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
            if (runtimeAutoFaces()[i].id == faceId) {
                if (runtimeState().autoFaceIndex != i) {
                    runtimeState().autoFaceIndex = i;
                    touchRuntimeState();
                }
                break;
            }
        }
    }

    DynamicJsonDocument reply(1024);
    reply["ok"]            = true;
    reply["v"]             = runtimeStateVersion();
    reply["version"]       = runtimeStateVersion();
    reply["next_poll_ms"]  = statusNextPollMs(false, false);
    reply["accepted"]      = true;
    reply["queued"]        = queuedM370FrameCount() > 0;
    reply["queueDepth"]    = M370_FRAME_QUEUE_DEPTH;
    reply["queueCount"]    = queuedM370FrameCount();
    reply["frameMinIntervalMs"] = M370_FRAME_MIN_INTERVAL_MS;
    reply["leds"]          = LED_COUNT;
    reply["color"]         = runtimeState().colorHex;
    reply["brightness"]    = runtimeState().brightness;
    reply["reason"]        = runtimeState().lastReason;
    reply["mode"]          = runtimeState().mode;
    reply["autoIntervalMs"] = runtimeState().autoIntervalMs;
    reply["autoFaceIndex"] = runtimeState().autoFaceIndex;
    addCurrentFaceFields(reply.as<JsonObject>());
    reply["m370"]          = runtimeState().lastM370;
    reply["lit"]           = countLitLeds();
    sendJsonDocument(200, reply);
}

static void handleApiScroll() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_POST)    { sendError(405, "method not allowed"); return; }

    const String body = requestBody();
    if (body.isEmpty()) { sendError(400, "empty JSON body"); return; }

    if (!runtimeScrollFrameBufferReady()) {
        sendError(507, "scroll frame buffer unavailable (insufficient PSRAM/SRAM)");
        return;
    }

    uint16_t intervalMs = runtimeState().scrollIntervalMs;
    const bool hasExplicitTiming = scrollTimingFromBody(body, intervalMs);

    const bool appendFrames = jsonBoolField(body, "append", false);
    const bool explicitStart = jsonHasField(body, "start");
    bool shouldStart = jsonBoolField(body, "start", false);
    const bool persist = jsonBoolField(body, "persist", false);
    const bool saveToFlash = jsonBoolField(body, "saveToFlash", false);
    uint32_t chunkIndex = 0;
    uint32_t totalFrames = 0;
    jsonUintField(body, "chunkIndex", chunkIndex);
    jsonUintField(body, "totalFrames", totalFrames);
    String source;
    String storageTarget;
    jsonStringField(body, "source", source);
    jsonStringField(body, "storage", storageTarget);
    storageTarget.toLowerCase();
    if (persist || saveToFlash || (!storageTarget.isEmpty() && storageTarget != "ram")) {
        sendError(400, "scroll uploads are RAM-only; persist/saveToFlash/storage flash is unsupported");
        return;
    }

    size_t framesValueOffset = 0;
    if (!jsonFieldValueOffset(body, "frames", framesValueOffset) ||
        framesValueOffset >= body.length() ||
        body.charAt(framesValueOffset) != '[') {
        sendError(400, "frames must be an array");
        return;
    }
    size_t pos = framesValueOffset + 1U;

    uint16_t baseIndex = 0;
    if (!appendFrames) {
        stopFirmwareScroll(false);
        withScrollLock([]() {
            runtimeState().scrollFrameCount = 0;
            runtimeState().scrollFrameIndex = 0;
        });
    } else {
        withScrollLock([&]() {
            baseIndex = runtimeState().scrollFrameCount;
        });
    }

    uint16_t count = 0;
    String   error;
    while (pos < body.length()) {
        while (pos < body.length()) {
            const char c = body.charAt(pos);
            if (c == ' ' || c == '\r' || c == '\n' || c == '\t' || c == ',') { ++pos; continue; }
            break;
        }
        if (pos >= body.length()) { sendError(400, "unterminated frames array"); return; }
        if (body.charAt(pos) == ']') break;
        if (body.charAt(pos) != '"') {
            sendError(400, String("expected M370 string at frame ") + count); return;
        }

        int endQuote = -1;
        String m370;
        if (!extractJsonStringAt(body, pos, m370, endQuote)) {
            sendError(400, String("unterminated M370 string at frame ") + count); return;
        }

        const uint32_t targetIndex = static_cast<uint32_t>(baseIndex) + count;
        if (targetIndex >= MAX_SCROLL_FRAMES) {
            sendError(413, String("too many scroll frames; firmware cache max is ") + MAX_SCROLL_FRAMES);
            return;
        }
        if (!m370ToPackedBits(m370, runtimeScrollFrameBits(targetIndex), error)) {
            sendError(400, String("invalid scroll frame ") + targetIndex + ": " + error);
            withScrollLock([]() { runtimeState().scrollFrameCount = 0; });
            return;
        }
        ++count;
        pos = static_cast<size_t>(endQuote + 1);
    }

    if (count == 0) {
        sendError(400, "frames must include at least one valid M370 frame"); return;
    }

    if (!explicitStart) {
        const uint32_t cachedFrames = static_cast<uint32_t>(baseIndex) + count;
        shouldStart = totalFrames > 0 ? (cachedFrames >= totalFrames) : !appendFrames;
    }

    withScrollLock([&]() {
        runtimeState().scrollFrameCount = baseIndex + count;
        if (!appendFrames ||
            (!runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused)) {
            runtimeState().scrollFrameIndex = 0;
        }
        if (hasExplicitTiming) {
            runtimeState().scrollIntervalMs = constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        }
    });

    if (shouldStart) startFirmwareScroll(intervalMs);
    const ScrollStateSnapshot scrollState = readScrollStateSnapshot();

    DynamicJsonDocument reply(768);
    reply["ok"]                   = true;
    reply["frames"]               = scrollState.scrollFrameCount;
    reply["chunkFrames"]          = count;
    reply["chunkIndex"]           = chunkIndex;
    reply["totalFrames"]          = totalFrames;
    reply["append"]               = appendFrames;
    reply["started"]              = scrollState.firmwareScrollActive;
    reply["source"]               = source;
    reply["storage"]              = "ram";
    reply["persist"]              = false;
    reply["saveToFlash"]          = false;
    reply["mode"]                 = runtimeState().mode;
    reply["playback"]             = runtimeState().playback;
    reply["restoreAutoAfterScroll"] = scrollState.restoreAutoAfterScroll;
    reply["scrollIntervalMs"]     = scrollState.scrollIntervalMs;
    reply["scrollMaxFrames"]      = MAX_SCROLL_FRAMES;
    reply["stepLedPerFrame"]      = 1;
    sendJsonDocument(200, reply);
}


using ApiCommandHandler = bool (*)(JsonDocument& doc, JsonVariant payload, String& error);

static bool commandSetColor(JsonDocument& doc, JsonVariant payload, String& error) {
    const char* hex = payload["hex"] | "";
    if (strlen(hex) == 0) hex = doc["hex"] | "";
    return setColor(hex, error);
}

static bool commandSetBrightness(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    int raw = runtimeState().brightness;
    if      (payload["raw"].is<int>())        raw = payload["raw"].as<int>();
    else if (payload["brightness"].is<int>()) raw = payload["brightness"].as<int>();
    else if (doc["raw"].is<int>())            raw = doc["raw"].as<int>();
    setBrightness(raw);
    return true;
}

static bool commandSetMode(JsonDocument& doc, JsonVariant payload, String& error) {
    cancelDeferredFaceRestore();
    const char* mode = payload["mode"] | "";
    if (strlen(mode) == 0) mode = doc["mode"] | "";
    if (strlen(mode) == 0 || !setMode(mode)) {
        error = "invalid mode";
        return false;
    }
    return true;
}

static bool commandSetAutoInterval(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    uint32_t ms = runtimeState().autoIntervalMs;
    if      (payload["ms"].is<uint32_t>()) ms = payload["ms"].as<uint32_t>();
    else if (doc["ms"].is<uint32_t>())     ms = doc["ms"].as<uint32_t>();
    setAutoInterval(ms);
    return true;
}

static bool scrollIntervalFromCommand(JsonDocument& doc, JsonVariant payload, uint16_t& intervalMs) {
    uint32_t rawInterval = 0;
    if (commandUintField(doc, payload, "intervalMs", rawInterval) && rawInterval > 0) {
        intervalMs = rawScrollIntervalToUint16(rawInterval);
        return true;
    }

    float fps = 0.0f;
    return commandFloatField(doc, payload, "fps", fps) && scrollIntervalFromFps(fps, intervalMs);
}

static bool commandSetScrollInterval(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    uint16_t iMs = runtimeState().scrollIntervalMs;
    scrollIntervalFromCommand(doc, payload, iMs);
    withScrollLock([&]() {
        runtimeState().scrollIntervalMs  = constrain(iMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        runtimeState().lastScrollFrameMs = millis();
    });
    touchRuntimeState();
    return true;
}

static bool commandStartScroll(JsonDocument& doc, JsonVariant payload, String& error) {
    uint16_t iMs = runtimeState().scrollIntervalMs;
    scrollIntervalFromCommand(doc, payload, iMs);
    bool hasCachedFrames = false;
    withScrollLock([&]() {
        hasCachedFrames = runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady();
    });
    if (!hasCachedFrames) {
        error = "no cached scroll frames";
        return false;
    }
    startFirmwareScroll(iMs);
    return true;
}

static bool commandScrollStep(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)error;
    int8_t direction = 1;
    if (!payload.isNull() && payload["direction"].is<int>()) {
        direction = payload["direction"].as<int>() < 0 ? -1 : 1;
    }
    uint8_t steppedFrame[FRAME_BYTES];
    bool    hasSteppedFrame = false;
    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            const uint16_t frameCount = runtimeState().scrollFrameCount;
            runtimeState().scrollFrameIndex =
                direction < 0
                    ? static_cast<uint16_t>((runtimeState().scrollFrameIndex + frameCount - 1U) % frameCount)
                    : static_cast<uint16_t>((runtimeState().scrollFrameIndex + 1U) % frameCount);
            runtimeState().playback         = "scroll_step";
            memcpy(steppedFrame, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
            hasSteppedFrame = true;
        }
    });
    if (hasSteppedFrame) {
        clearQueuedM370Frames();
        applyPackedFrameImmediate(steppedFrame, "firmware_text_scroll_step");
    }
    return true;
}

static bool commandPauseScroll(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool ignored = false;
    pauseFirmwareScrollIfActive(ignored);
    return true;
}

static bool commandResumeScroll(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool ignored = false;
    resumeFirmwareScrollIfCached(ignored);
    return true;
}

static bool commandStopScroll(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    bool clearDisplay = true;
    bool restoreAuto  = true;
    commandBoolField(doc, payload, "clear", clearDisplay);
    commandBoolField(doc, payload, "restoreAuto", restoreAuto);
    stopFirmwareScroll(restoreAuto, clearDisplay);
    return true;
}

static bool commandPause(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool pausedScroll = false;
    pauseFirmwareScrollIfActive(pausedScroll);
    if (!pausedScroll) {
        runtimeState().paused   = true;
        runtimeState().playback = "paused";
        touchRuntimeState();
    }
    return true;
}

static bool commandResume(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool resumedScroll = false;
    resumeFirmwareScrollIfCached(resumedScroll, true);
    if (!resumedScroll) {
        runtimeState().paused   = false;
        runtimeState().playback = DEFAULT_PLAYBACK;
        touchRuntimeState();
    }
    return true;
}

static bool commandButton(JsonDocument& doc, JsonVariant payload, String& error) {
    const char* button = payload["button"] | "";
    if (strlen(button) == 0) button = doc["button"] | "";
    if (!runButtonAction(String(button), "api_button")) {
        error = "unsupported button or no saved faces available";
        return false;
    }
    return true;
}

static bool commandTerminateOtherActivities(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)error;
    const char* targetMode = payload["targetMode"] | "";
    if (strcmp(targetMode, "scroll") != 0) stopFirmwareScroll(false, false);
    if (strcmp(targetMode, "face") != 0 && strcmp(targetMode, "scroll") != 0) {
        setMode("manual", true);
    } else if (strcmp(targetMode, "scroll") == 0 && isAutoMode()) {
        runtimeState().restoreAutoAfterScroll = true;
        runtimeState().mode                   = "manual";
        touchRuntimeState();
    }
    return true;
}

static bool commandResetBatteryMinimum(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    resetBatteryVoltageMinimum();
    return true;
}

static bool commandResetBatteryMaximum(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    resetBatteryVoltageMaximum();
    return true;
}

struct ApiCommandRoute {
    const char*       name;
    ApiCommandHandler handler;
};

static const ApiCommandRoute API_COMMAND_ROUTES[] = {
    {"set_color",                  commandSetColor},
    {"set_brightness",             commandSetBrightness},
    {"set_mode",                   commandSetMode},
    {"set_auto_interval",          commandSetAutoInterval},
    {"set_scroll_interval",        commandSetScrollInterval},
    {"start_scroll",               commandStartScroll},
    {"scroll_step",                commandScrollStep},
    {"pause_scroll",               commandPauseScroll},
    {"resume_scroll",              commandResumeScroll},
    {"stop_scroll",                commandStopScroll},
    {"pause",                      commandPause},
    {"resume",                     commandResume},
    {"button",                     commandButton},
    {"terminate_other_activities", commandTerminateOtherActivities},
    {"reset_battery_min",          commandResetBatteryMinimum},
    {"reset_battery_max",          commandResetBatteryMaximum},
};

static const ApiCommandRoute* findApiCommandRoute(const String& cmd) {
    for (const ApiCommandRoute& route : API_COMMAND_ROUTES) {
        if (cmd == route.name) return &route;
    }
    return nullptr;
}

static void handleApiCommand() {
    String error;
    PsramJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) {
        ++runtimeState().commandsRejected;
        sendError(400, error);
        return;
    }

    const String  cmd     = doc["cmd"] | "";
    JsonVariant   payload = doc["payload"];
    if (cmd.isEmpty()) {
        ++runtimeState().commandsRejected;
        sendError(400, "missing cmd");
        return;
    }

    const ApiCommandRoute* route = findApiCommandRoute(cmd);
    if (route == nullptr) {
        ++runtimeState().commandsRejected;
        sendError(400, String("unknown command: ") + cmd);
        return;
    }

    if (!route->handler(doc, payload, error)) {
        ++runtimeState().commandsRejected;
        sendError(400, error);
        return;
    }

    ++runtimeState().commandsAccepted;

    const ScrollStateSnapshot scrollState = readScrollStateSnapshot();
    PsramJsonDocument reply(3072);
    reply["ok"]                   = true;
    reply["v"]                    = runtimeStateVersion();
    reply["version"]              = runtimeStateVersion();
    reply["next_poll_ms"]         = statusNextPollMs(scrollState.scrolling(), false);
    reply["cmd"]                  = cmd;
    reply["color"]                = runtimeState().colorHex;
    reply["brightness"]           = runtimeState().brightness;
    reply["mode"]                 = runtimeState().mode;
    reply["autoIntervalMs"]       = runtimeState().autoIntervalMs;
    reply["playback"]             = runtimeState().playback;
    reply["paused"]               = runtimeState().paused;
    reply["autoFaceIndex"]        = runtimeState().autoFaceIndex;
    JsonObject replyRoot = reply.as<JsonObject>();
    addScrollStateFields(replyRoot, scrollState);
    reply["deferredFaceRestoreActive"] = runtimeState().deferredFaceRestoreActive;
    addScrollStopEvent(replyRoot);
    addCurrentFaceFields(reply.as<JsonObject>());
    reply["m370"]       = runtimeState().lastM370;
    reply["lastReason"] = runtimeState().lastReason;
    if (cmd == "reset_battery_min" || cmd == "reset_battery_max") {
        servicePowerMonitor(true);
        addPowerStatus(reply.createNestedObject("power"), true, true);
    }
    sendJsonDocument(200, reply);
}

static void handleSavedFacesGet() {
    if (!runtimeFsMounted()) { sendError(503, "LittleFS is not mounted; run pio run -t uploadfs"); return; }
    if (!littleFsExistsLocked(SAVED_FACES_PATH)) {
        sendError(404, "saved_faces.json not found; run pio run -t uploadfs"); return;
    }
    File file = littleFsOpenLocked(SAVED_FACES_PATH, "r");
    if (!file) { sendError(500, "failed to open saved_faces.json"); return; }
    addCorsHeaders();
    streamFileChunked(file, CONTENT_TYPE_JSON_UTF8);
    closeFileLocked(file);
}

static void handleSavedFacesPost() {
    if (!runtimeFsMounted()) { sendError(503, "LittleFS is not mounted; cannot write saved_faces.json"); return; }

    const String body = requestBody();
    if (body.isEmpty()) { sendError(400, "empty JSON body"); return; }

    const size_t capacity = jsonCapacityFor(body.length());
    PsramJsonDocument doc(capacity);
    DeserializationError err = deserializeJson(doc, body, DeserializationOption::NestingLimit(32));
    if (err) { sendError(400, String("invalid JSON: ") + err.c_str()); return; }

    JsonVariant document = doc["document"];
    if (document.isNull()) document = doc.as<JsonVariant>();
    const char* requestPath = doc["path"] | SAVED_FACES_PATH;
    const char* reason      = doc["reason"] | "";

    String error;
    if (!validateSavedFaces(document, error)) { sendError(400, error); return; }

    const size_t written = writeSavedFaces(document, error);
    if (written == 0) { sendError(500, error); return; }

    loadSavedFaces(false);

    DynamicJsonDocument reply(384);
    reply["ok"]     = true;
    reply["v"]      = runtimeStateVersion();
    reply["version"] = runtimeStateVersion();
    reply["path"]   = SAVED_FACES_PATH;
    reply["requestPath"] = requestPath;
    reply["reason"] = reason;
    reply["bytes"]  = written;
    reply["writes"] = runtimeState().savedFacesWrites;
    sendJsonDocument(200, reply);
}

static void handleApiSavedFaces() {
    if      (server.method() == HTTP_GET)     handleSavedFacesGet();
    else if (server.method() == HTTP_POST)    handleSavedFacesPost();
    else if (server.method() == HTTP_OPTIONS) handleOptions();
    else                                       sendError(405, "method not allowed");
}

static void handleNotFound() {
    if (server.method() == HTTP_GET && serveStaticFile(server.uri())) return;
    if (server.method() == HTTP_GET && !runtimeFsMounted()) { sendFilesystemErrorPage(); return; }
    sendError(404, "not found: " + server.uri());
}

// ---------------------------------------------------------------------------
// LittleFS 错误提示图案（LittleFS error pattern，在 Web 服务器启动前显示） 相关代码，维护 注册 SoftAP、DNS captive portal 和 HTTP API 路由。
// ---------------------------------------------------------------------------

void showFilesystemErrorPattern() {
    withFrameLock([]() {
        runtimeState().colorHex   = "#ff0000";
        runtimeState().colorR     = 0xff;
        runtimeState().colorG     = 0x00;
        runtimeState().colorB     = 0x00;
        runtimeState().brightness = DEFAULT_BRIGHTNESS;
        memset(runtimeFrameBits(), 0, FRAME_BYTES);
        for (uint16_t i = 0; i < 12 && i < LED_COUNT; ++i) setFrameBit(i, true);
        runtimeState().lastReason = "littlefs_mount_failed";
        showCurrentFrameNoLock();
    });
}

// ---------------------------------------------------------------------------
// 公共接口：接入点 + WebServer 启动（Public: Access Point + WebServer startup） 相关代码，维护 注册 SoftAP、DNS captive portal 和 HTTP API 路由。
// ---------------------------------------------------------------------------

void startAccessPoint() {
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(apIP(), apGateway(), apSubnet());
    WiFi.softAP(AP_SSID, AP_PASSWORD);
    const IPAddress currentIp = WiFi.softAPIP();
    dnsServer.setTTL(60);
    dnsServerActive = dnsServer.start(DNS_PORT, AP_DOMAIN, currentIp);
    Serial.printf("AP started: ssid=%s password=%s ip=%s domain=%s dns=%s\n",
                  AP_SSID, AP_PASSWORD, currentIp.toString().c_str(), AP_DOMAIN,
                  dnsServerActive ? "on" : "off");
}

void startWebServer() {
    auto serveRoot = []() {
        if (!serveStaticFile("/")) {
            if (!runtimeFsMounted()) sendFilesystemErrorPage();
            else sendError(404, "index.html not found; run pio run -t uploadfs");
        }
    };

    server.on("/",            HTTP_GET,     serveRoot);
    server.on("/index.html",  HTTP_GET,     serveRoot);
    server.on("/api/status",  HTTP_GET,     handleApiStatus);
    server.on("/api/status",  HTTP_OPTIONS, handleOptions);
    server.on("/api/power",   HTTP_GET,     handleApiPower);
    server.on("/api/power",   HTTP_OPTIONS, handleOptions);
    server.on("/api/frame",   HTTP_POST,    handleApiFrame);
    server.on("/api/frame",   HTTP_OPTIONS, handleOptions);
    server.on("/api/scroll",               handleApiScroll);
    server.on("/api/command", HTTP_POST,    handleApiCommand);
    server.on("/api/command", HTTP_OPTIONS, handleOptions);
    server.on("/api/saved_faces",          handleApiSavedFaces);
    server.onNotFound(handleNotFound);
    static const char* COLLECTED_HEADERS[] = { "Accept-Encoding" };
    server.collectHeaders(COLLECTED_HEADERS, 1);
    server.begin();
    Serial.printf("HTTP server listening on http://%s/ and http://%s/\n",
                  AP_DOMAIN, WiFi.softAPIP().toString().c_str());
}

void webServerTick() {
    if (dnsServerActive) dnsServer.processNextRequest();
    server.handleClient();
}
