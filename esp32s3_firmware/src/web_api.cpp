#include "web_api.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "storage.h"
#include "faces.h"
#include "buttons.h"
#include "button_animations.h"
#include "power_monitor.h"
#include "web_json.h"
#include "psram_json.h"
#include "scroll.h"
#include "scroll_session.h"
#include "serial_log.h"
#include <DNSServer.h>
#include <WebServer.h>
#include <WiFi.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <pgmspace.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

static WebServer server(HTTP_PORT);
static DNSServer dnsServer;
static bool dnsServerActive = false;

static const char CONTENT_TYPE_JSON_UTF8[] = "application/json; charset=utf-8";
static const char CONTENT_TYPE_HTML_UTF8[] = "text/html; charset=utf-8";
static const char CONTENT_TYPE_TEXT_PLAIN[] = "text/plain";
static const uint16_t STATIC_STREAM_CHUNK_BYTES = 8192;
static const TickType_t WEB_YIELD_TICKS = pdMS_TO_TICKS(1);
static const size_t WEB_YIELD_EVERY_CHUNKS = 4;

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
    if (path.endsWith(".html") || path.endsWith(".htm") ||
        path.endsWith(".js") || path.endsWith(".css")) {
        server.sendHeader("Cache-Control", "no-cache");
    } else {
        server.sendHeader("Cache-Control", "public, max-age=31536000, immutable");
    }
}

static bool littleFsExistsLocked(const String& path) {
    bool exists = false;
    withStorageLock([&]() {
        exists = LittleFS.exists(path);
    });
    return exists;
}

static File littleFsOpenLocked(const String& path, const char* mode) {
    File file;
    withStorageLock([&]() {
        file = LittleFS.open(path, mode);
    });
    return file;
}

static size_t fileSizeLocked(File& file) {
    size_t size = 0;
    withStorageLock([&]() {
        size = file.size();
    });
    return size;
}

static void closeFileLocked(File& file) {
    withStorageLock([&]() {
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

        withStorageLock([&]() {
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

static ScrollSessionSnapshot readScrollStateSnapshot() {
    return scrollSessionSnapshot();
}

static void addScrollStateFields(JsonObject target, const ScrollSessionSnapshot& snapshot) {
    target["firmwareScrollActive"]       = snapshot.firmwareScrollActive;
    target["firmwareScrollPaused"]       = snapshot.firmwareScrollPaused;
    target["firmwareScrollUserPaused"]   = snapshot.firmwareScrollUserPaused;
    target["firmwareScrollSystemPaused"] = snapshot.firmwareScrollSystemPaused;
    target["restoreAutoAfterScroll"]     = snapshot.restoreAutoAfterScroll;
    target["scrollFrameCount"]           = snapshot.scrollFrameCount;
    target["scrollFrameIndex"]           = snapshot.scrollFrameIndex;
    target["scrollIntervalMs"]           = snapshot.scrollIntervalMs;
    target["scrollTimelineId"]           = String(snapshot.scrollTimelineId);
    target["scrollUploadComplete"]       = snapshot.scrollUploadComplete;
    target["scrollHasSourceText"]        = snapshot.scrollHasSourceText;
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

static void addPowerStatus(JsonObject power, const PowerStatus& snapshot,
                           bool includeSlow = true, bool clearDirty = false) {
    const bool batteryOk = snapshot.batteryValid;
    const bool chargeOk = snapshot.chargeValid;
    const bool chargerPresent = chargeOk && snapshot.charging;
    const bool batteryUnpowered = !chargerPresent &&
        (snapshot.batteryDisconnected || snapshot.batteryLowVoltageUnpowered);
    const bool batteryPowered = batteryOk && !batteryUnpowered;
    const char* batteryIconClass = "status-dot dim";
    const char* batteryIconColor = "#9aa6b2";
    const char* batteryStateText = batteryPowered ? "电池" : "未上电";
    if (batteryPowered) {
        if (snapshot.batteryPercent < 10) {
            batteryIconClass = "status-dot danger";
            batteryIconColor = "#ef4444";
        } else if (snapshot.batteryPercent < 30) {
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
    if (snapshot.chargeValid)  power["charging"]       = snapshot.charging;
    else                          power["charging"]       = nullptr;
    power["chargeValid"]      = snapshot.chargeValid;
    power["chargeIconClass"]  = chargeIconClass;
    power["chargeIconColor"]  = chargeIconColor;
    power["ok"]               = snapshot.batteryValid || snapshot.chargeValid;
    power["chargeSampleMs"]   = CHARGE_SAMPLE_MS;
    power["slowPublishMs"]    = POWER_WEB_SLOW_PUBLISH_MS;
    power["batteryPowered"]   = batteryPowered;
    power["batteryDisconnected"] = snapshot.batteryDisconnected;
    power["batteryLowVoltageUnpowered"] = snapshot.batteryLowVoltageUnpowered;
    power["batteryStateText"] = batteryStateText;
    power["batteryIconClass"] = batteryIconClass;
    power["batteryIconColor"] = batteryIconColor;

    if (includeSlow) {
        power["batteryGpio"]      = BATTERY_ADC_PIN;
        if (snapshot.batteryValid) power["vbat"]           = snapshot.vbat;
        else                          power["vbat"]           = nullptr;
        if (snapshot.batteryValid) power["batteryPercent"] = snapshot.batteryPercent;
        else                          power["batteryPercent"] = nullptr;
        if (snapshot.chargeValid)  power["vcharge"]        = snapshot.vcharge;
        else                          power["vcharge"]        = nullptr;
        power["batteryAdcMv"]     = snapshot.batteryAdcMv;
        power["batteryPrevAdcMv"] = snapshot.batteryPrevAdcMv;
        power["batteryDisconnectDropMv"] = snapshot.batteryDisconnectDropMv;
        power["batteryDisconnectDropThresholdMv"] = BATTERY_DISCONNECT_ADC_DROP_MV;
        power["batteryDisconnectLowThresholdMv"]  = BATTERY_DISCONNECT_ADC_LOW_MV;
        power["batteryReconnectThresholdMv"]      = BATTERY_RECONNECT_ADC_MV;
        power["batteryUnpoweredLowThreshold"] = BATTERY_UNPOWERED_LOW_V;
        if (isfinite(snapshot.batteryLastInstantVbat)) power["batteryLastInstantVbat"] = snapshot.batteryLastInstantVbat;
        else power["batteryLastInstantVbat"] = nullptr;
        power["batteryDisconnectedSinceMs"] = snapshot.batteryDisconnectedSinceMs;
        power["lastBatteryDisconnectEventMs"] = snapshot.lastBatteryDisconnectEventMs;
        power["chargeAdcMv"]      = snapshot.chargeAdcMv;
        power["batteryValid"]     = snapshot.batteryValid;
        power["batteryRangeMin"]  = snapshot.batteryCalibMinV;
        power["batteryRangeMax"]  = snapshot.batteryCalibMaxV;
        power["batteryNominalMin"] = BATTERY_EMPTY_V;
        power["batteryNominalMax"] = BATTERY_FULL_V;
        power["batteryCalibLoaded"] = snapshot.batteryCalibLoaded;
        power["batteryCalibDirty"] = snapshot.batteryCalibDirty;
        power["batteryCalibPath"] = BATTERY_CALIB_PATH;
        power["chargeThreshold"]  = CHARGE_PRESENT_V;
        power["batterySampleMs"]  = BATTERY_SAMPLE_MS;
        power["lastBatteryMs"]    = snapshot.lastBatteryMs;
        power["lastChargeMs"]     = snapshot.lastChargeMs;
        power["lastCalibMaxMs"]   = snapshot.lastCalibMaxMs;
        power["lastCalibMinMs"]   = snapshot.lastCalibMinMs;
    }

    if (clearDirty) {
        clearPowerStatusWebDirty(includeSlow);
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
    changed = scrollSessionSetUserPaused(true);
}

static void resumeFirmwareScrollIfCached(bool& changed, bool requirePaused = false) {
    bool canResume = false;
    withScrollLock([&]() {
        canResume = runtimeState().scrollFrameCount > 0 &&
                    (!requirePaused || runtimeState().firmwareScrollPaused);
    });
    if (canResume) changed = scrollSessionSetUserPaused(false);
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

static void handleOptions() {
    addCorsHeaders();
    server.send(204, CONTENT_TYPE_TEXT_PLAIN, "");
}

static void handleApiStatus() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_GET)     { sendError(405, "method not allowed"); return; }
    servicePowerMonitor();

    const ScrollSessionSnapshot scrollState = readScrollStateSnapshot();
    const bool scrolling   = scrollState.scrolling();
    const bool runtimeOnly = server.hasArg("runtimeOnly");
    const bool summaryOnly = runtimeOnly || server.hasArg("summary") || server.hasArg("noFrame");
    const uint32_t version = runtimeStateVersion();
    const bool hasSince = server.hasArg("since");
    const PowerStatus powerSnapshot = readPowerStatusSnapshot();
    const bool includeSlowPower = !hasSince || powerStatusWebSlowDirty() || server.hasArg("fullPower");

    if (hasSince) {
        const uint32_t since = static_cast<uint32_t>(strtoul(server.arg("since").c_str(), nullptr, 10));
        const bool allowUnchangedShortcut = !scrolling;
        if (allowUnchangedShortcut && since == version) {
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

    PsramJsonDocument doc((runtimeOnly || scrolling || summaryOnly) ? 4608 : 6656);
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

    addPowerStatus(doc.createNestedObject("power"), powerSnapshot, includeSlowPower, true);

    JsonObject renderer = doc.createNestedObject("renderer");
    const FrameStateSnapshot fs = readFrameStateSnapshot();
    renderer["color"]                   = fs.colorHex;
    renderer["brightness"]              = fs.brightness;
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
        renderer["lastM370"] = fs.lastM370;
        renderer["lit"]      = fs.litLeds;
    } else if (summaryOnly) {
        renderer["lastM370Skipped"] = true;
    } else {
        renderer["lastM370Deferred"] = true;
    }
    renderer["lastReason"] = fs.lastReason;

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
        withStorageLock([&]() {
            storage["totalBytes"] = static_cast<uint32_t>(LittleFS.totalBytes());
            storage["usedBytes"]  = static_cast<uint32_t>(LittleFS.usedBytes());
        });
    } else if (summaryOnly) {
        storage["capacitySkippedInSummary"] = true;
    } else if (scrolling) {
        storage["capacityDeferredDuringScroll"] = true;
    }

    JsonObject stats = doc.createNestedObject("stats");
    stats["framesAccepted"]    = fs.framesAccepted;
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
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_GET)     { sendError(405, "method not allowed"); return; }
    servicePowerMonitor();

    DynamicJsonDocument doc(3072);
    doc["ok"] = true;
    const PowerStatus powerSnapshot = readPowerStatusSnapshot();
    addPowerStatus(doc.createNestedObject("power"), powerSnapshot, true, true);
    sendJsonDocument(200, doc);
}

static void handleApiFrame() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_POST)    { sendError(405, "method not allowed"); return; }
    String error;
    PsramJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) { sendError(400, error); return; }

    const char* m370 = doc["m370"] | "";
    if (strlen(m370) == 0) {
        ++runtimeState().framesRejected;
        touchRuntimeStateSlow();
        sendError(400, "missing m370");
        return;
    }

    String normalizedM370;
    if (!normalizeM370(String(m370), normalizedM370, error)) {
        ++runtimeState().framesRejected;
        touchRuntimeStateSlow();
        sendError(400, error);
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

    if (!applyM370(normalizedM370, reason, error)) { sendError(400, error); return; }

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
    const FrameStateSnapshot fs = readFrameStateSnapshot();
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
    reply["color"]         = fs.colorHex;
    reply["brightness"]    = fs.brightness;
    reply["reason"]        = fs.lastReason;
    reply["mode"]          = runtimeState().mode;
    reply["autoIntervalMs"] = runtimeState().autoIntervalMs;
    reply["autoFaceIndex"] = runtimeState().autoFaceIndex;
    addCurrentFaceFields(reply.as<JsonObject>());
    reply["m370"]          = fs.lastM370;
    reply["lit"]           = fs.litLeds;
    sendJsonDocument(200, reply);
}

static void handleApiScroll() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_POST)    { sendError(405, "method not allowed"); return; }

    const String body = requestBody();
    if (body.isEmpty()) { sendError(400, "empty JSON body"); return; }

    String jsonError;
    if (!jsonValidateCompleteObject(body, jsonError)) {
        sendError(400, jsonError);
        return;
    }

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
    const bool hasChunkIndex = jsonUintField(body, "chunkIndex", chunkIndex);
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

    String timelineId, sourceText, fontId, generatorVersion;
    const bool timelineIdPresent = jsonHasField(body, "timelineId");
    const bool sourceTextPresent = jsonHasField(body, "sourceText");
    const bool fontIdPresent     = jsonHasField(body, "fontId");
    const bool generatorPresent  = jsonHasField(body, "generatorVersion");
    if (timelineIdPresent && !jsonStringField(body, "timelineId", timelineId)) {
        sendError(400, "invalid timelineId"); return;
    }
    if (sourceTextPresent && !jsonStringField(body, "sourceText", sourceText)) {
        sendError(400, "invalid sourceText"); return;
    }
    if (fontIdPresent && !jsonStringField(body, "fontId", fontId)) {
        sendError(400, "invalid fontId"); return;
    }
    if (generatorPresent && !jsonStringField(body, "generatorVersion", generatorVersion)) {
        sendError(400, "invalid generatorVersion"); return;
    }
    float uiFpsRaw = 0.0f;
    jsonFloatField(body, "fps", uiFpsRaw);

    size_t framesValueOffset = 0;
    if (!jsonFieldValueOffset(body, "frames", framesValueOffset) ||
        framesValueOffset >= body.length() ||
        body.charAt(framesValueOffset) != '[') {
        sendError(400, "frames must be an array");
        return;
    }
    size_t pos = framesValueOffset + 1U;

    ScrollUploadTxn uploadTxn;

    if (!appendFrames) {
        // 首块（append:false）：严格按 v6 1.5 顺序，先校验再触碰任何状态。
        if (totalFrames > MAX_SCROLL_FRAMES) {                                  // 步骤 2a
            sendError(413, String("totalFrames exceeds firmware cache max ") + MAX_SCROLL_FRAMES);
            return;
        }
        // E3：timelineId / fontId / generatorVersion 只要出现就校验（与 sourceText 无关）。
        if (timelineIdPresent && !validateMetaIdString(timelineId.c_str(), MAX_SCROLL_TIMELINE_ID_CHARS)) {
            sendError(400, "invalid timelineId"); return;
        }
        if (fontIdPresent && !validateMetaIdString(fontId.c_str(), MAX_SCROLL_FONT_ID_CHARS)) {
            sendError(400, "invalid fontId"); return;
        }
        if (generatorPresent && !validateMetaIdString(generatorVersion.c_str(), MAX_SCROLL_GENERATOR_CHARS)) {
            sendError(400, "invalid generatorVersion"); return;
        }
        // D1：sourceText 是 all-or-nothing，必须同时带 timelineId + fontId + generatorVersion。
        if (sourceTextPresent) {
            if (!timelineIdPresent || !fontIdPresent || !generatorPresent) {
                sendError(400, "sourceText requires timelineId, fontId and generatorVersion"); return;
            }
            if (!runtimeScrollSourceTextReady()) {
                sendError(507, "scroll source-text buffer unavailable"); return;
            }
            if (sourceText.length() > MAX_SCROLL_TEXT_BYTES) {
                sendError(413, String("sourceText exceeds ") + MAX_SCROLL_TEXT_BYTES + " bytes"); return;
            }
            if (!validateScrollSourceText(sourceText.c_str(), sourceText.length())) {
                sendError(400, "sourceText contains invalid UTF-8 or control characters"); return;
            }
        }
        // E2：timeline-backed 上传必须带 totalFrames > 0，否则 uploadComplete 永远
        // 无法为 true，D2 会永久阻塞播放。
        if (timelineIdPresent && totalFrames == 0) {
            sendError(400, "timeline-backed upload requires totalFrames > 0"); return;
        }

        // PRE-FLIGHT: Validate all frames in the first chunk before clearing state
        size_t prePos = pos;
        uint16_t preCount = 0;
        String preError;
        while (prePos < body.length()) {
            while (prePos < body.length()) {
                const char c = body.charAt(prePos);
                if (c == ' ' || c == '\r' || c == '\n' || c == '\t' || c == ',') { ++prePos; continue; }
                break;
            }
            if (prePos >= body.length()) { sendError(400, "unterminated frames array"); return; }
            if (body.charAt(prePos) == ']') break;
            if (body.charAt(prePos) != '"') { sendError(400, String("expected M370 string at frame ") + preCount); return; }

            int endQuote = -1;
            String m370;
            if (!extractJsonStringAt(body, prePos, m370, endQuote)) {
                sendError(400, String("unterminated M370 string at frame ") + preCount); return;
            }
            uint8_t dummyBits[FRAME_BYTES];
            if (!m370ToPackedBits(m370, dummyBits, preError)) {
                sendError(400, String("invalid scroll frame ") + preCount + ": " + preError); return;
            }
            ++preCount;
            prePos = static_cast<size_t>(endQuote + 1);
        }
        if (preCount == 0) { sendError(400, "frames must include at least one valid M370 frame"); return; }
        if (preCount > MAX_SCROLL_FRAMES) {
            sendError(413, String("too many scroll frames; firmware cache max is ") + MAX_SCROLL_FRAMES);
            return;
        }
        if (totalFrames > 0 && preCount > totalFrames) { sendError(409, "too many frames"); return; }

        uint8_t uiFps = 0;
        if (uiFpsRaw > 0.0f) {
            const float rounded = roundf(uiFpsRaw);
            uiFps = static_cast<uint8_t>(rounded < 1.0f ? 1.0f : (rounded > 255.0f ? 255.0f : rounded));
        }

        stopFirmwareScroll(false);
        ScrollUploadMeta uploadMeta;
        uploadMeta.timelineId       = timelineIdPresent ? timelineId.c_str() : "";
        uploadMeta.fontId           = fontIdPresent ? fontId.c_str() : "";
        uploadMeta.generatorVersion = generatorPresent ? generatorVersion.c_str() : "";
        uploadMeta.sourceText       = sourceTextPresent ? sourceText.c_str() : nullptr;
        uploadMeta.sourceTextBytes  = static_cast<uint16_t>(sourceText.length());
        uploadMeta.totalFrames      = static_cast<uint16_t>(totalFrames);
        uploadMeta.uiFps            = uiFps;
        uploadTxn = scrollSessionBeginUpload(uploadMeta);
    } else {
        // 追加块（append:true）：先快照元数据，再按 v6 1.5 校验。
        uploadTxn = scrollSessionBeginAppend();
        if (uploadTxn.timelineBacked) {
            if (uploadTxn.uploadComplete) { sendError(409, "upload already complete"); return; }      // D3
            if (!timelineIdPresent) { sendError(409, "timeline required"); return; }
            if (strcmp(timelineId.c_str(), uploadTxn.timelineId) != 0) {
                sendError(409, "timeline mismatch"); return;
            }
            if (!hasChunkIndex) { sendError(409, "chunk index required"); return; }
            if (chunkIndex != uploadTxn.nextChunkIndex) { sendError(409, "chunk out of order"); return; }
        } else {
            // EH-B：legacy 纯帧上传；timelineId/chunkIndex 可选，chunkIndex 出现时必须按序。
            if (hasChunkIndex && chunkIndex != uploadTxn.nextChunkIndex) {
                sendError(409, "chunk out of order"); return;
            }
        }
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

        // E1：帧数超限检查也适用于首块（timeline/totalFrames 背书的上传）。
        if (uploadTxn.totalFramesExpected > 0 &&
            static_cast<uint32_t>(uploadTxn.framesReceivedBase) + count + 1U > uploadTxn.totalFramesExpected) {
            scrollSessionInvalidateCache();
            sendError(409, "too many frames");
            return;
        }

        const uint32_t targetIndex = static_cast<uint32_t>(uploadTxn.baseIndex) + count;
        if (targetIndex >= MAX_SCROLL_FRAMES) {
            sendError(413, String("too many scroll frames; firmware cache max is ") + MAX_SCROLL_FRAMES);
            return;
        }
        uint8_t packedBits[FRAME_BYTES];
        if (!m370ToPackedBits(m370, packedBits, error)) {
            // EH-A：坏帧数据使播放缓存失效（帧计数归零 + uploadComplete=false），
            // 但有意保留 sourceText，恢复仍可从文本重建预览。
            scrollSessionInvalidateCache();
            sendError(400, String("invalid scroll frame ") + targetIndex + ": " + error);
            return;
        }
        if (!scrollSessionWriteFrame(uploadTxn, static_cast<uint16_t>(targetIndex), packedBits)) {
            sendError(409, "scroll frame target not writable");
            return;
        }
        ++count;
        pos = static_cast<size_t>(endQuote + 1);
    }

    if (count == 0) {
        sendError(400, "frames must include at least one valid M370 frame"); return;
    }

    const ScrollUploadResult uploadResult =
        scrollSessionCommitUpload(uploadTxn, count, hasExplicitTiming, intervalMs);
    const bool uploadCompleteNow = uploadResult.uploadComplete;

    if (!explicitStart) {
        const uint32_t cachedFrames = static_cast<uint32_t>(uploadTxn.baseIndex) + count;
        shouldStart = totalFrames > 0 ? (cachedFrames >= totalFrames) : !appendFrames;
    }
    // D2：不完整的 timeline-backed 缓存永远不可播放（含显式 start:true）。
    if (uploadTxn.timelineBacked && !uploadCompleteNow) shouldStart = false;

    if (shouldStart) startFirmwareScroll(intervalMs);
    const ScrollSessionSnapshot scrollState = readScrollStateSnapshot();

    DynamicJsonDocument reply(1024);
    reply["ok"]                   = true;
    reply["frames"]               = scrollState.scrollFrameCount;
    reply["chunkFrames"]          = count;
    reply["chunkIndex"]           = chunkIndex;
    reply["totalFrames"]          = totalFrames;
    reply["append"]               = appendFrames;
    reply["started"]              = scrollState.firmwareScrollActive;
    reply["timelineId"]           = String(uploadResult.timelineId);
    reply["uploadComplete"]       = uploadCompleteNow;
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

// 锁内拷贝（meta 结构 + 文本 memcpy），锁外序列化；容量/溢出 -> 507（H-C）。
static void handleApiScrollMeta() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_GET)     { sendError(405, "method not allowed"); return; }

    ScrollMetaOut metaOut;

    char* textCopy = nullptr;
    const size_t textCapacity = static_cast<size_t>(MAX_SCROLL_TEXT_BYTES) + 1U;
    if (runtimeScrollSourceTextReady()) {
        textCopy = static_cast<char*>(heap_caps_malloc(textCapacity, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (textCopy == nullptr) {
            textCopy = static_cast<char*>(heap_caps_malloc(textCapacity, MALLOC_CAP_8BIT));
        }
        if (textCopy != nullptr) textCopy[0] = '\0';
    }

    const bool textCopyFailed = !scrollSessionCopyMeta(metaOut, textCopy, textCapacity);
    if (textCopyFailed) {
        if (textCopy != nullptr) heap_caps_free(textCopy);
        sendError(507, "metadata text alloc failed");
        return;
    }

    PsramJsonDocument doc(16384);
    if (doc.capacity() == 0) {
        if (textCopy != nullptr) heap_caps_free(textCopy);
        sendError(507, "metadata json alloc failed");
        return;
    }
    doc["ok"]                   = true;
    doc["scrollTimelineId"]     = String(metaOut.meta.timelineId);
    doc["hasSourceText"]        = metaOut.meta.hasSourceText;
    doc["sourceText"]           = (metaOut.meta.hasSourceText && textCopy != nullptr)
                                      ? static_cast<const char*>(textCopy) : "";
    doc["sourceTextBytes"]      = metaOut.meta.sourceTextByteLength;
    doc["fontId"]               = String(metaOut.meta.fontId);
    doc["generatorVersion"]     = String(metaOut.meta.generatorVersion);
    doc["uiFps"]                = metaOut.meta.uiFps;
    doc["scrollIntervalMs"]     = metaOut.scrollIntervalMs;
    doc["frameCount"]           = metaOut.frameCount;
    doc["frameIndex"]           = metaOut.frameIndex;
    doc["uploadComplete"]       = metaOut.meta.uploadComplete;
    doc["firmwareScrollActive"] = metaOut.active;
    doc["firmwareScrollPaused"] = metaOut.paused;
    doc["firmwareScrollUserPaused"] = metaOut.userPaused;
    doc["firmwareScrollSystemPaused"] = metaOut.systemPaused;
    if (doc.overflowed()) {
        if (textCopy != nullptr) heap_caps_free(textCopy);
        sendError(507, "metadata json overflow");
        return;
    }
    sendJsonDocument(200, doc);
    if (textCopy != nullptr) heap_caps_free(textCopy);
}

using ApiCommandHandler = bool (*)(JsonDocument& doc, JsonVariant payload, String& error);

// 冲突需要 409，其余保持 400。每次分发前重置。
static int sCommandErrorStatus = 400;

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
    scrollSessionSetInterval(iMs);
    return true;
}

static bool commandStartScroll(JsonDocument& doc, JsonVariant payload, String& error) {
    uint16_t iMs = runtimeState().scrollIntervalMs;
    scrollIntervalFromCommand(doc, payload, iMs);

    // E6：进锁前把 payload timelineId 抽到栈缓冲并校验长度/字符集；
    // 永远不要用截断后的 ID 做比较。
    char payloadTimelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
    const char* raw = payload["timelineId"] | "";
    if (raw[0] == '\0') raw = doc["timelineId"] | "";
    const size_t rawLen = strlen(raw);
    if (rawLen > MAX_SCROLL_TIMELINE_ID_CHARS) {
        error = "timeline id too long";
        return false;  // 400
    }
    if (rawLen > 0 && !validateMetaIdString(raw, MAX_SCROLL_TIMELINE_ID_CHARS)) {
        error = "invalid timeline id";
        return false;  // 400
    }
    memcpy(payloadTimelineId, raw, rawLen);

    // D2/D8/H-D：一次 scrollMutex 快照内完成所有判定，错误用枚举带出，
    // 锁内不做任何 heap String 写入。
    enum class StartScrollError : uint8_t {
        None, TimelineMismatch, UploadIncomplete, NoCachedFrames
    };
    StartScrollError serr = StartScrollError::None;
    withScrollLock([&]() {
        const ScrollTimelineMeta& meta = runtimeScrollMeta();
        const bool timelineBacked = meta.timelineId[0] != '\0';
        const bool hasFrames = runtimeState().scrollFrameCount > 0 &&
                               runtimeScrollFrameBufferReady();
        if (timelineBacked) {
            if (rawLen > 0 && strcmp(payloadTimelineId, meta.timelineId) != 0) {
                serr = StartScrollError::TimelineMismatch;
                return;
            }
            if (!meta.uploadComplete) {   // D2：payload 不带 timelineId 也要拦
                serr = StartScrollError::UploadIncomplete;
                return;
            }
        }
        if (!hasFrames) {
            serr = StartScrollError::NoCachedFrames;
            return;
        }
    });
    // 锁外映射：TimelineMismatch / UploadIncomplete -> 409，NoCachedFrames -> 400。
    if (serr == StartScrollError::TimelineMismatch) {
        sCommandErrorStatus = 409;
        error = "timeline mismatch";
        return false;
    }
    if (serr == StartScrollError::UploadIncomplete) {
        sCommandErrorStatus = 409;
        error = "upload incomplete";
        return false;
    }
    if (serr == StartScrollError::NoCachedFrames) {
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
    const bool hasSteppedFrame = scrollSessionStep(direction, steppedFrame);
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
    bool restoreAuto  = scrollSessionGetRestoreAuto();
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
        scrollSessionSetRestoreAuto(true);
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

static bool commandBatteryOverlay(JsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)error;
    bool singleShot = true;
    commandBoolField(doc, payload, "singleShot", singleShot);
    showBatteryOverlay(singleShot);
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
    {"battery_overlay",            commandBatteryOverlay},
};

static const ApiCommandRoute* findApiCommandRoute(const String& cmd) {
    for (const ApiCommandRoute& route : API_COMMAND_ROUTES) {
        if (cmd == route.name) return &route;
    }
    return nullptr;
}

static bool commandWantsPower(const String& cmd) {
    return cmd == "reset_battery_min" || cmd == "reset_battery_max" || cmd == "battery_overlay";
}

static void buildCommandReply(JsonObject reply, const String& cmd, const ScrollSessionSnapshot& scrollState) {
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
    addScrollStateFields(reply, scrollState);
    reply["deferredFaceRestoreActive"] = runtimeState().deferredFaceRestoreActive;
    addScrollStopEvent(reply);
    addCurrentFaceFields(reply);
    reply["m370"]       = runtimeState().lastM370;
    reply["lastReason"] = runtimeState().lastReason;
}

static void handleApiCommand() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_POST)    { sendError(405, "method not allowed"); return; }
    String error;
    PsramJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) {
        ++runtimeState().commandsRejected;
        touchRuntimeStateSlow();
        sendError(400, error);
        return;
    }

    const String  cmd     = doc["cmd"] | "";
    JsonVariant   payload = doc["payload"];
    if (cmd.isEmpty()) {
        ++runtimeState().commandsRejected;
        touchRuntimeStateSlow();
        sendError(400, "missing cmd");
        return;
    }

    const ApiCommandRoute* route = findApiCommandRoute(cmd);
    if (route == nullptr) {
        ++runtimeState().commandsRejected;
        touchRuntimeStateSlow();
        RLOG_WARN("CMD", "event=reject source=webui cmd=%s err=unknown_command", cmd.c_str());
        sendError(400, String("unknown command: ") + cmd);
        return;
    }

    sCommandErrorStatus = 400;
    if (!route->handler(doc, payload, error)) {
        ++runtimeState().commandsRejected;
        touchRuntimeStateSlow();
        RLOG_WARN("CMD", "event=reject source=webui cmd=%s err=%s", cmd.c_str(), error.c_str());
        sendError(sCommandErrorStatus, error);
        return;
    }

    ++runtimeState().commandsAccepted;
    touchRuntimeStateSlow();
    RLOG_INFO("CMD", "event=accept source=webui cmd=%s", cmd.c_str());

    const ScrollSessionSnapshot scrollState = readScrollStateSnapshot();
    PsramJsonDocument replyDoc(3584);
    JsonObject replyRoot = replyDoc.to<JsonObject>();
    buildCommandReply(replyRoot, cmd, scrollState);

    if (commandWantsPower(cmd)) {
        servicePowerMonitor(true);
        const PowerStatus powerSnapshot = readPowerStatusSnapshot();
        addPowerStatus(replyRoot.createNestedObject("power"), powerSnapshot, true, true);
    }
    sendJsonDocument(200, replyDoc);
}

static void handleSavedFacesGet() {
    if (!runtimeFsMounted()) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_read err=fs_not_mounted");
        sendError(503, "LittleFS is not mounted; run pio run -t uploadfs"); return;
    }
    if (!littleFsExistsLocked(SAVED_FACES_PATH)) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_read err=file_not_found");
        sendError(404, "saved_faces.json not found; run pio run -t uploadfs"); return;
    }
    File file = littleFsOpenLocked(SAVED_FACES_PATH, "r");
    if (!file) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_read err=open_failed");
        sendError(500, "failed to open saved_faces.json"); return;
    }
    const size_t bytes = fileSizeLocked(file);
    RLOG_INFO("CMD", "event=accept source=webui cmd=saved_faces_read bytes=%u", static_cast<unsigned>(bytes));
    addCorsHeaders();
    streamFileChunked(file, CONTENT_TYPE_JSON_UTF8);
    closeFileLocked(file);
}

static void handleSavedFacesPost() {
    if (!runtimeFsMounted()) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_write err=fs_not_mounted");
        sendError(503, "LittleFS is not mounted; cannot write saved_faces.json"); return;
    }

    const String body = requestBody();
    if (body.isEmpty()) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_write err=empty_body");
        sendError(400, "empty JSON body"); return;
    }

    const size_t capacity = jsonCapacityFor(body.length());
    PsramJsonDocument doc(capacity);
    DeserializationError err = deserializeJson(doc, body, DeserializationOption::NestingLimit(32));
    if (err) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_write err=json_%s", err.c_str());
        sendError(400, String("invalid JSON: ") + err.c_str()); return;
    }

    JsonVariant document = doc["document"];
    if (document.isNull()) document = doc.as<JsonVariant>();
    const char* requestPath = doc["path"] | SAVED_FACES_PATH;
    const char* reason      = doc["reason"] | "";

    String error;
    if (!validateSavedFaces(document, error)) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_write err=validation_failed");
        sendError(400, error); return;
    }

    const size_t written = writeSavedFaces(document, error);
    if (written == 0) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_write err=write_failed");
        sendError(500, error); return;
    }

    loadSavedFaces(false);
    RLOG_INFO("CMD", "event=accept source=webui cmd=saved_faces_write reason=%s bytes=%u writes=%u faces=%u",
              reason,
              static_cast<unsigned>(written),
              static_cast<unsigned>(runtimeState().savedFacesWrites),
              static_cast<unsigned>(runtimeAutoFaceCount()));

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
            if (!runtimeFsMounted()) {
                sendFilesystemErrorPage();
                return;
            }
            sendError(404, "not found: /");
        }
    };

    server.on("/", HTTP_GET, serveRoot);

    server.on("/api/status",      HTTP_ANY, handleApiStatus);
    server.on("/api/power",       HTTP_ANY, handleApiPower);
    server.on("/api/frame",       HTTP_ANY, handleApiFrame);
    server.on("/api/scroll",      HTTP_ANY, handleApiScroll);
    server.on("/api/scroll/meta", HTTP_ANY, handleApiScrollMeta);
    server.on("/api/command",     HTTP_ANY, handleApiCommand);
    server.on("/api/saved_faces", HTTP_ANY, handleApiSavedFaces);

    server.onNotFound(handleNotFound);
    server.begin();
    Serial.printf("Web server started on port %d\n", HTTP_PORT);
}

void webServerTick() {
    if (dnsServerActive) {
        dnsServer.processNextRequest();
    }
    server.handleClient();
}
