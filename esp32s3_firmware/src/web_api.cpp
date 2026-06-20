/*
 * File Description: web_api.cpp
 * Coordinates WebServer setup, DNS redirect portal, and API route endpoints.
 *
 * Responsibilities:
 * - Spins up the ESP32 Access Point (AP) mode and HTTP server on port 80.
 * - Handles captive portal DNS redirection (DNS_PORT 53).
 * - Implements REST API routes (e.g. state syncing, battery status, brightness updates, raw commands).
 * - Manages multi-chunk HTTP uploads for long text scrolling buffers (combining chunks).
 *
 * Core Interactions:
 * - Locks state variables using synchronization primitives from sync.h.
 * - Fetches runtime variables from state.h and updates settings using storage.h.
 */
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
#include "perf_counters.h"
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
// While firmware text scroll is on the LED panel, each contiguous LittleFS (flash)
// read on Core 0 must stay short: a long read disables the cache and stalls Core 1,
// starving the timing-critical WS2812/RMT transmit and garbling the panel. During an
// active scroll we therefore read in smaller chunks and yield after every chunk.
static const uint16_t STATIC_STREAM_CHUNK_SCROLL_BYTES = 1024;
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
    // Only the entry document (index.html) is served no-cache, so a freshly flashed
    // build's fingerprinted "?v=<hash>" asset URLs are always picked up. Every other
    // asset (js/css/woff2/png/json/...) is referenced with a content-hash "?v=" query
    // that is rewritten at build time by scripts/gzip_webui_assets.py, so its URL
    // changes whenever the bytes change. That makes those assets safe to cache
    // immutably -- and, crucially, it stops a plain WebUI refresh from re-streaming
    // ~100KB+ of app.js / styles.css out of LittleFS (flash) on every reload. Those
    // sustained flash reads on Core 0 were stalling the cache and starving the Core-1
    // WS2812/RMT transmit, which corrupted ("乱码") the LED panel during text scrolling.
    if (path.endsWith(".html") || path.endsWith(".htm")) {
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

    // When the LED panel is actively scrolling text, shorten each flash read and yield
    // after every chunk so the Core-1 WS2812/RMT transmit is not starved by a long
    // cache-disabling read on Core 0 (the root cause of refresh-time panel garble).
    // Checked once per request (not per chunk) to avoid extra scroll-lock traffic.
    const bool scrollDisplaying = scrollSessionSnapshot().scrolling();
    const size_t requestChunk = scrollDisplaying ? STATIC_STREAM_CHUNK_SCROLL_BYTES
                                                  : STATIC_STREAM_CHUNK_BYTES;
    const size_t yieldEvery   = scrollDisplaying ? 1U : WEB_YIELD_EVERY_CHUNKS;

    uint8_t* heapBuffer = static_cast<uint8_t*>(malloc(requestChunk));
    uint8_t  stackFallback[512];
    uint8_t* buffer    = heapBuffer ? heapBuffer : stackFallback;
    const size_t chunkBytes = heapBuffer ? requestChunk : sizeof(stackFallback);

    size_t chunksSent = 0;
    while (true) {
        size_t bytesRead = 0;
        bool hasData = false;

        // The flash read below is automatically serialized against the Core-1 WS2812
        // transmit: withStorageLock() also holds the HardwareBus mutex for the whole
        // flash transaction (see sync.cpp). A LittleFS read transiently disables the
        // flash cache on both cores, which would stall an in-flight strip.show() and
        // garble the panel ("乱码"); coupling the locks makes that overlap impossible.
        // Acquire/release is per chunk and the loop yields between chunks, so the LED
        // render task still gets the bus to show() between reads and the scroll runs.
        withStorageLock([&]() {
            hasData = file.available();
            if (hasData) {
                bytesRead = file.read(buffer, chunkBytes);
            }
        });

        if (!hasData || bytesRead == 0) break;
        server.sendContent(reinterpret_cast<const char*>(buffer), bytesRead);
        if ((++chunksSent % yieldEvery) == 0) vTaskDelay(WEB_YIELD_TICKS);
    }

    if (heapBuffer) free(heapBuffer);
}

// Streams a JsonDocument to the HTTP client in fixed-size chunks (P1-A). The old
// path serialized the whole response into an Arduino String that grows by
// doubling-reallocation in internal DRAM, then WebServer copied it again -- the
// dominant source of internal-heap fragmentation under sustained WebUI polling.
// This adapter sends the body with a known Content-Length and never holds more
// than its 512-byte chunk buffer of contiguous DRAM, mirroring streamFileChunked()'s
// proven setContentLength()+send("")+sendContent() pattern.
class ChunkedJsonPrint final : public Print {
public:
    explicit ChunkedJsonPrint(WebServer& srv) : server_(srv) {}
    size_t write(uint8_t b) override {
        buf_[len_++] = static_cast<char>(b);
        if (len_ == sizeof(buf_)) flush();
        return 1;
    }
    size_t write(const uint8_t* data, size_t size) override {
        for (size_t i = 0; i < size; ++i) write(data[i]);
        return size;
    }
    void finish() { flush(); }
private:
    void flush() {
        if (len_ == 0) return;
        server_.sendContent(buf_, len_);
        len_ = 0;
    }
    WebServer& server_;
    char   buf_[512];
    size_t len_ = 0;
};

static void sendJsonDocument(int status, JsonDocument& doc) {
    addCorsHeaders();
    server.setContentLength(measureJson(doc));
    server.send(status, CONTENT_TYPE_JSON_UTF8, "");
    ChunkedJsonPrint sink(server);
    serializeJson(doc, sink);
    sink.finish();
}

static void sendError(int status, const String& message) {
    // Error responses must not allocate, because they are emitted exactly when the
    // device is already low on / fragmented internal heap (the 503 admission path,
    // invalid-request storms, 404s). The old path built a DynamicJsonDocument plus a
    // growing output String plus WebServer's own copy. Instead, use a stack-resident
    // StaticJsonDocument and the same fixed-512-byte chunked-stream path as success
    // responses, so no heap String is ever materialized here.
    StaticJsonDocument<384> doc;
    doc["ok"] = false;
    char err[M370_FRAME_REASON_CHARS * 3];   // bounded copy; long messages are truncated, never grown
    strlcpy(err, message.c_str(), sizeof(err));
    doc["error"] = err;
    sendJsonDocument(status, doc);
}

// HTTP memory admission guard -- crash protection against sudden WebUI refreshes.
//
// A refresh aborts the in-flight request and fires a burst of new ones, each of
// which allocates internal DRAM (body copy, JSON response String, temporaries). If
// a burst lands while internal heap is low/fragmented, an allocation -- ours or the
// WiFi/LwIP stack's -- can fail and panic the board. Calling this at the top of a
// dynamic handler sheds the request with 503 (instead of allocating and risking an
// OOM crash) whenever free internal heap is below HTTP_MIN_FREE_HEAP_BYTES. Returns
// true when the request was rejected; the caller must then return immediately.
//
// Mode-independent: every mode (manual / auto / scroll) shares these endpoints, so
// guarding them here protects all of them. The check itself allocates nothing
// except the small 503 body, which is only built when we are already shedding load.
static bool httpRejectIfLowMemory(const char* what) {
    const uint32_t freeHeap = ESP.getFreeHeap();
    // Fragmentation guard (P1-A): plenty of free bytes but a small largest
    // contiguous block will still OOM-panic on a contiguous allocation (a response
    // buffer, or a WiFi/LwIP buffer). Shed when EITHER total free OR the largest
    // internal block is below its floor, so fragmentation can no longer slip past.
    const uint32_t largestBlock =
        heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (freeHeap >= HTTP_MIN_FREE_HEAP_BYTES &&
        largestBlock >= HTTP_MIN_LARGEST_BLOCK_BYTES) {
        return false;
    }
    RLOG_WARN("WEB", "event=shed_low_heap what=%s freeHeap=%u floor=%u largest=%u largestFloor=%u",
              what ? what : "?", static_cast<unsigned>(freeHeap),
              static_cast<unsigned>(HTTP_MIN_FREE_HEAP_BYTES),
              static_cast<unsigned>(largestBlock),
              static_cast<unsigned>(HTTP_MIN_LARGEST_BLOCK_BYTES));
    server.sendHeader("Retry-After", "1");
    sendError(503, "device temporarily low on memory; please retry");
    return true;
}

static uint16_t statusNextPollMs(bool scrolling, bool summaryOnly) {
    if (runtimeState().deferredFaceRestoreActive) return 250;
    if (scrolling) return summaryOnly ? 3000 : 3000;
    return 1000;
}

static ScrollSessionSnapshot readScrollStateSnapshot() {
    return scrollSessionSnapshot();
}

static void addScrollStateFields(JsonObject target, const ScrollSessionSnapshot& snapshot) {
    const bool displayingScroll = snapshot.scrolling();
    target["firmwareScrollDisplaying"]   = displayingScroll;
    target["firmwareScrollActive"]       = snapshot.firmwareScrollActive;
    target["firmwareScrollPaused"]       = snapshot.firmwareScrollPaused;
    target["firmwareScrollUserPaused"]   = snapshot.firmwareScrollUserPaused;
    target["firmwareScrollSystemPaused"] = snapshot.firmwareScrollSystemPaused;
    target["restoreAutoAfterScroll"]     = snapshot.restoreAutoAfterScroll;
    target["scrollFrameCount"]           = displayingScroll ? snapshot.scrollFrameCount : 0;
    target["scrollFrameIndex"]           = displayingScroll ? snapshot.scrollFrameIndex : 0;
    target["scrollIntervalMs"]           = snapshot.scrollIntervalMs;
    target["scrollTimelineId"]           = displayingScroll ? String(snapshot.scrollTimelineId) : String();
    target["scrollUploadComplete"]       = displayingScroll && snapshot.scrollUploadComplete;
    target["scrollHasSourceText"]        = displayingScroll && snapshot.scrollHasSourceText;
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
        const bool displayingScroll = runtimeState().firmwareScrollActive ||
                                      runtimeState().firmwareScrollPaused;
        canResume = displayingScroll && runtimeState().scrollFrameCount > 0 &&
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

    // Scroll limits exposed so the WebUI can validate before upload instead of
    // hardcoding firmware constants (P1-5). sourceText is bounded by UTF-8 BYTES,
    // not characters, so the WebUI must compare encoded byte length to maxTextBytes.
    JsonObject scrollLimits = doc.createNestedObject("scrollLimits");
    scrollLimits["maxTextBytes"] = MAX_SCROLL_TEXT_BYTES;
    scrollLimits["maxFrames"]    = MAX_SCROLL_FRAMES;

    JsonObject endpoints = doc.createNestedObject("endpoints");
    endpoints["frame"]        = "/api/frame";
    endpoints["command"]      = "/api/command";
    endpoints["scroll"]       = "/api/scroll";
    endpoints["scrollSource"] = "/api/scroll/source";
    endpoints["savedFaces"]   = "/api/saved_faces";
    endpoints["power"]        = "/api/power";
    endpoints["status"]       = "/api/status";

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

static bool ledDeltaValue(JsonVariant value, bool& out) {
    if (value.is<bool>()) {
        out = value.as<bool>();
        return true;
    }
    if (value.is<int>()) {
        out = value.as<int>() != 0;
        return true;
    }
    if (value.is<const char*>()) {
        String text = value.as<const char*>();
        text.trim();
        text.toLowerCase();
        if (text == "1" || text == "true" || text == "on") {
            out = true;
            return true;
        }
        if (text == "0" || text == "false" || text == "off") {
            out = false;
            return true;
        }
    }
    return false;
}

static bool readLedDeltaList(JsonDocument& doc, uint16_t* indices, bool* values,
                             uint16_t& count, String& error) {
    count = 0;
    JsonVariant changesVariant = doc["changes"];
    if (changesVariant.isNull()) changesVariant = doc["deltas"];

    auto appendDelta = [&](uint32_t idxRaw, JsonVariant valueVariant) -> bool {
        if (idxRaw >= LED_COUNT) {
            error = "LED delta index out of range";
            return false;
        }
        if (count >= LED_COUNT) {
            error = "too many LED delta changes";
            return false;
        }
        bool on = false;
        if (!ledDeltaValue(valueVariant, on)) {
            error = "invalid LED delta value";
            return false;
        }
        indices[count] = static_cast<uint16_t>(idxRaw);
        values[count] = on;
        ++count;
        return true;
    };

    if (!changesVariant.isNull()) {
        JsonArray changes = changesVariant.as<JsonArray>();
        if (changes.isNull()) {
            error = "changes must be an array";
            return false;
        }
        for (JsonVariant item : changes) {
            if (item.is<JsonArray>()) {
                JsonArray pair = item.as<JsonArray>();
                if (pair.size() < 2 || !pair[0].is<unsigned int>()) {
                    error = "invalid LED delta pair";
                    return false;
                }
                if (!appendDelta(pair[0].as<uint32_t>(), pair[1])) return false;
            } else {
                uint32_t idxRaw = LED_COUNT;
                if (item["idx"].is<unsigned int>()) idxRaw = item["idx"].as<uint32_t>();
                else if (item["index"].is<unsigned int>()) idxRaw = item["index"].as<uint32_t>();
                else if (item["led"].is<unsigned int>()) idxRaw = item["led"].as<uint32_t>();
                else {
                    error = "missing LED delta index";
                    return false;
                }
                JsonVariant valueVariant = item["on"];
                if (valueVariant.isNull()) valueVariant = item["value"];
                if (!appendDelta(idxRaw, valueVariant)) return false;
            }
        }
    } else if (doc["idx"].is<unsigned int>() || doc["index"].is<unsigned int>() || doc["led"].is<unsigned int>()) {
        uint32_t idxRaw = doc["idx"].is<unsigned int>()
            ? doc["idx"].as<uint32_t>()
            : (doc["index"].is<unsigned int>() ? doc["index"].as<uint32_t>() : doc["led"].as<uint32_t>());
        JsonVariant valueVariant = doc["on"];
        if (valueVariant.isNull()) valueVariant = doc["value"];
        if (!appendDelta(idxRaw, valueVariant)) return false;
    }
    if (count == 0) {
        error = "missing LED delta changes";
        return false;
    }
    return true;
}

static void handleApiFrame() {
#if ENABLE_PERF_PROFILING
    uint32_t t0 = micros();
#endif
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_POST)    { sendError(405, "method not allowed"); return; }

    // Crash protection (manual mode): shed live frame draws under low heap.
    if (httpRejectIfLowMemory("frame")) return;

#if ENABLE_PERF_PROFILING
    uint32_t tParseStart = micros();
#endif
    String error;
    PsramJsonDocument doc(4096);
    if (!parseJsonBody(doc, error)) { sendError(400, error); return; }

    const char* m370 = doc["m370"] | "";
    const bool hasM370 = strlen(m370) > 0;
    // Kept off the loop-task stack: the synchronous WebServer services one request
    // at a time on Core 0, so a single function-local static scratch buffer is safe
    // and saves ~1.1 KB of stack on every /api/frame while WebServer/JSON/HTTP
    // parsing frames are already nested below this handler.
    static uint16_t deltaIndices[LED_COUNT];
    static bool deltaValues[LED_COUNT];
    uint16_t deltaCount = 0;
    const bool hasDeltaPayload =
        doc["changes"].is<JsonArray>() || doc["deltas"].is<JsonArray>() ||
        doc["idx"].is<unsigned int>() || doc["index"].is<unsigned int>() || doc["led"].is<unsigned int>();

    if (!hasM370 && !hasDeltaPayload) {
        ++runtimeState().framesRejected;
        touchRuntimeStateSlow();
        sendError(400, "missing m370 or LED delta changes");
        return;
    }
    if (!hasM370 && !readLedDeltaList(doc, deltaIndices, deltaValues, deltaCount, error)) {
        ++runtimeState().framesRejected;
        touchRuntimeStateSlow();
        sendError(400, error);
        return;
    }
#if ENABLE_PERF_PROFILING
    uint32_t parseUs = micros() - tParseStart;
#else
    uint32_t parseUs = 0;
#endif

    String normalizedM370;
    if (hasM370 && !normalizeM370(String(m370), normalizedM370, error)) {
        ++runtimeState().framesRejected;
        touchRuntimeStateSlow();
        sendError(400, error);
        return;
    }

    const char* mode = doc["mode"] | "";
    if (strlen(mode) == 0) mode = doc["playback"] | "idle";
    const String reason = doc["reason"] | "api_frame";
    const bool liveFrame = reason.startsWith("custom_live_") || reason.startsWith("parts_live_");

    // Sequence number check
    const uint32_t seq = doc["seq"] | 0;
    static uint32_t lastLiveSeq = 0;
    if (liveFrame && seq > 0) {
        if (seq == 1) {
            lastLiveSeq = 1;
        } else if (seq <= lastLiveSeq) {
            server.send(204);
#if ENABLE_PERF_PROFILING
            perfRecordApiFrame(micros() - t0, parseUs, 0, 0, server.arg("plain").length(), deltaCount, liveFrame, deltaCount > 0);
#endif
            return;
        }
        lastLiveSeq = seq;
    }

    if (!isScrollPlayback(mode)) {
        // A non-scroll frame replaces text scrolling, equivalent to Stop/Clear
        // before entering the target display mode.
        stopFirmwareScrollForNonScrollOutput("api_frame_non_scroll");
    }
    if (reason.startsWith("custom_") || reason.startsWith("parts_")) {
        setMode("manual", false);
    }
    assignText(runtimeState().playback, mode);

#if ENABLE_PERF_PROFILING
    uint32_t tApplyStart = micros();
#endif
    if (deltaCount > 0) {
        clearQueuedM370Frames();
        if (!applyLedDeltasImmediate(deltaIndices, deltaValues, deltaCount, reason, error)) {
            sendError(400, error);
            return;
        }
    } else if (liveFrame) {
        clearQueuedM370Frames();
        if (!applyM370Immediate(normalizedM370, reason, error)) { sendError(400, error); return; }
    } else if (!applyM370(normalizedM370, reason, error)) {
        sendError(400, error);
        return;
    }
#if ENABLE_PERF_PROFILING
    uint32_t applyUs = micros() - tApplyStart;
#else
    uint32_t applyUs = 0;
#endif

    const char* faceId = doc["faceId"] | "";
    if (strlen(faceId) > 0 && ensureSavedFacesLoaded()) {
        for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
            if (strcmp(runtimeAutoFaces()[i].id, faceId) == 0) {
                if (runtimeState().autoFaceIndex != i) {
                    runtimeState().autoFaceIndex = i;
                    touchRuntimeState();
                }
                break;
            }
        }
    }

#if ENABLE_PERF_PROFILING
    uint32_t tResponseStart = micros();
#endif
    if (liveFrame) {
        server.send(204);
#if ENABLE_PERF_PROFILING
        uint32_t responseUs = micros() - tResponseStart;
        perfRecordApiFrame(micros() - t0, parseUs, applyUs, responseUs, server.arg("plain").length(), deltaCount, liveFrame, deltaCount > 0);
#endif
        return;
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
#if ENABLE_PERF_PROFILING
    uint32_t responseUs = micros() - tResponseStart;
    perfRecordApiFrame(micros() - t0, parseUs, applyUs, responseUs, server.arg("plain").length(), deltaCount, liveFrame, deltaCount > 0);
#endif
}

static String getBinaryReasonString(uint8_t reasonEnum) {
    switch (reasonEnum) {
        case 1: return "custom_live_send";
        case 2: return "parts_live_send";
        case 3: return "webui_frame";
        case 4: return "webui_delta";
        default: return "binary_frame";
    }
}

// Read exactly `len` bytes from the raw socket with a hard wall-clock deadline.
// Used instead of WiFiClient::readBytes()/setTimeout() because the latter blocks
// up to the ~1000 ms default stream timeout per call (P1-B: a slow/lossy client
// would stall the whole Core-0 cooperative loop), and because setTimeout()'s unit
// (seconds vs milliseconds) is not consistent across arduino-esp32 versions. This
// helper is unambiguous: it never blocks longer than timeoutMs total and yields to
// the scheduler while waiting. Returns true only when all bytes arrived in time.
static bool readSocketBytesBounded(WiFiClient& client, uint8_t* out, size_t len,
                                   uint32_t timeoutMs) {
    const uint32_t start = millis();
    size_t got = 0;
    while (got < len) {
        if (client.available() > 0) {
            const int n = client.read(out + got, len - got);
            if (n > 0) { got += static_cast<size_t>(n); continue; }
        }
        if (!client.connected() && client.available() == 0) return false;
        if (millis() - start >= timeoutMs) return false;
        vTaskDelay(pdMS_TO_TICKS(1));  // yield; total wait bounded by timeoutMs
    }
    return true;
}

static void handleApiFrameBin() {
#if ENABLE_PERF_PROFILING
    uint32_t t0 = micros();
#endif
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_POST)    { sendError(405, "method not allowed"); return; }

    // Crash protection (parity with the JSON frame path): shed under low/fragmented
    // heap before touching frame state or the WiFi stack.
    if (httpRejectIfLowMemory("frame_bin")) return;

    WiFiClient client = server.client();

    uint8_t header[6];
    if (!readSocketBytesBounded(client, header, 6, BIN_FRAME_READ_TIMEOUT_MS)) {
        sendError(400, "incomplete binary header");
        return;
    }
    
    uint8_t type = header[0];
    uint8_t reasonEnum = header[1];
    uint32_t seq = (uint32_t)header[2] | ((uint32_t)header[3] << 8) | ((uint32_t)header[4] << 16) | ((uint32_t)header[5] << 24);
    
    String reason = getBinaryReasonString(reasonEnum);
    const bool liveFrame = reason.startsWith("custom_live_") || reason.startsWith("parts_live_");

    // Sequence number check
    static uint32_t lastLiveSeq = 0;
    if (liveFrame && seq > 0) {
        if (seq == 1) {
            lastLiveSeq = 1;
        } else if (seq <= lastLiveSeq) {
            server.send(204);
#if ENABLE_PERF_PROFILING
            perfRecordApiFrame(micros() - t0, 0, 0, 0, 6, 0, liveFrame, false);
#endif
            return;
        }
        lastLiveSeq = seq;
    }

    if (reason.startsWith("custom_") || reason.startsWith("parts_")) {
        setMode("manual", false);
    }

    // Stop text scroll when a new frame is received
    stopFirmwareScrollForNonScrollOutput("api_frame_bin_non_scroll");

#if ENABLE_PERF_PROFILING
    uint32_t tApplyStart = micros();
#endif

    if (type == 1) {
        uint8_t packed[FRAME_BYTES];
        if (!readSocketBytesBounded(client, packed, FRAME_BYTES, BIN_FRAME_READ_TIMEOUT_MS)) {
            sendError(400, "incomplete binary frame body");
            return;
        }
        
        clearQueuedM370Frames();
        applyPackedFrameImmediate(packed, reason);

#if ENABLE_PERF_PROFILING
        uint32_t applyUs = micros() - tApplyStart;
#endif
        server.send(204);
#if ENABLE_PERF_PROFILING
        perfRecordApiFrame(micros() - t0, 0, applyUs, 0, 6 + FRAME_BYTES, 0, liveFrame, false);
#endif
        return;
    } else if (type == 2) {
        uint8_t countByte;
        if (!readSocketBytesBounded(client, &countByte, 1, BIN_FRAME_READ_TIMEOUT_MS)) {
            sendError(400, "incomplete binary delta count");
            return;
        }

        uint16_t count = countByte;
        // Off the loop-task stack (synchronous single-request WebServer on Core 0):
        // these three scratch buffers total ~1.5 KB and were stacked beneath HTTP
        // parsing + the socket read. Function-local static is safe here.
        static uint16_t indices[256];
        static bool values[256];
        static uint8_t entryBuf[256 * 3];

        // P1-B: read the whole delta body in ONE bounded read instead of `count`
        // separate blocking reads. Previously up to 255 sequential reads could each
        // stall for the socket timeout, multiplying the worst-case Core-0 freeze.
        const size_t bodyBytes = static_cast<size_t>(count) * 3U;
        if (count > 0 &&
            !readSocketBytesBounded(client, entryBuf, bodyBytes, BIN_FRAME_READ_TIMEOUT_MS)) {
            sendError(400, "incomplete binary delta body");
            return;
        }
        for (uint16_t i = 0; i < count; i++) {
            const uint8_t* entry = &entryBuf[static_cast<size_t>(i) * 3U];
            indices[i] = (uint16_t)entry[0] | ((uint16_t)entry[1] << 8);
            values[i] = entry[2] != 0;
        }

        String error;
        clearQueuedM370Frames();
        if (!applyLedDeltasImmediate(indices, values, count, reason, error)) {
            sendError(400, error);
            return;
        }

#if ENABLE_PERF_PROFILING
        uint32_t applyUs = micros() - tApplyStart;
#endif
        server.send(204);
#if ENABLE_PERF_PROFILING
        perfRecordApiFrame(micros() - t0, 0, applyUs, 0, 7 + count * 3, count, liveFrame, true);
#endif
        return;
    } else {
        sendError(400, "invalid binary packet type");
    }
}

static void handleApiPerf() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    
    if (server.method() == HTTP_POST) {
#if ENABLE_PERF_PROFILING
        perfClearCounters();
#endif
        DynamicJsonDocument doc(128);
        doc["ok"] = true;
        doc["cleared"] = true;
        sendJsonDocument(200, doc);
        return;
    }
    
    if (server.method() != HTTP_GET) { sendError(405, "method not allowed"); return; }
    
    DynamicJsonDocument doc(4096);
    doc["ok"] = true;
#if ENABLE_PERF_PROFILING
    perfSerializeCounters(doc);
#else
    doc["profilingEnabled"] = false;
#endif
    sendJsonDocument(200, doc);
}

static void handleApiScroll() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_POST)    { sendError(405, "method not allowed"); return; }

    // Crash protection: shed the request if internal heap is too low to parse a
    // chunk body + build the JSON reply. Prevents an OOM panic when a WebUI refresh
    // bursts requests during an upload (see config.h HTTP_MIN_FREE_HEAP_BYTES).
    if (httpRejectIfLowMemory("scroll_upload")) return;

    // Section-J telemetry: capture the internal-heap picture before we parse the
    // body / write frames so the upload_commit / upload_reject lines below can
    // report the heap delta of one chunk. INFO-gated and compiled out entirely
    // when ENABLE_SERIAL_DIAGNOSTICS=0; never on the LED render path.
    const uint32_t scrollUploadHeapBefore = ESP.getFreeHeap();
    const uint32_t scrollUploadLargestBefore =
        heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);

    const String body = requestBody();
    if (body.isEmpty()) { sendError(400, "empty JSON body"); return; }
    // Bound the body we are willing to parse. The WebUI keeps a single chunk well
    // under this; rejecting anything larger caps per-request DRAM and stops a
    // malformed/huge body from exhausting the heap.
    if (body.length() > SCROLL_MAX_UPLOAD_BODY_BYTES) {
        sendError(413, String("scroll chunk body exceeds ") + SCROLL_MAX_UPLOAD_BODY_BYTES + " bytes");
        return;
    }

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

    RLOG_INFO("SCROLL",
              "event=upload_recv append=%d chunkIndex=%u totalFrames=%u bodyBytes=%u heap=%u largest=%u",
              appendFrames ? 1 : 0, static_cast<unsigned>(chunkIndex),
              static_cast<unsigned>(totalFrames), static_cast<unsigned>(body.length()),
              static_cast<unsigned>(scrollUploadHeapBefore),
              static_cast<unsigned>(scrollUploadLargestBefore));
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
        // First chunk (append:false): strictly follow v6 1.5 sequence, validate before modifying any state.
        if (totalFrames > MAX_SCROLL_FRAMES) {                                  // Step 2a
            sendError(413, String("totalFrames exceeds firmware cache max ") + MAX_SCROLL_FRAMES);
            return;
        }
        // E3: timelineId / fontId / generatorVersion are validated whenever present (independent of sourceText).
        if (timelineIdPresent && !validateMetaIdString(timelineId.c_str(), MAX_SCROLL_TIMELINE_ID_CHARS)) {
            sendError(400, "invalid timelineId"); return;
        }
        if (fontIdPresent && !validateMetaIdString(fontId.c_str(), MAX_SCROLL_FONT_ID_CHARS)) {
            sendError(400, "invalid fontId"); return;
        }
        if (generatorPresent && !validateMetaIdString(generatorVersion.c_str(), MAX_SCROLL_GENERATOR_CHARS)) {
            sendError(400, "invalid generatorVersion"); return;
        }
        // D1: sourceText is all-or-nothing, must be accompanied by timelineId + fontId + generatorVersion.
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
        // E2: timeline-backed uploads must specify totalFrames > 0, otherwise uploadComplete will never
        // be true, and D2 will permanently block playback.
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

        clearQueuedM370Frames();
        // Audit M1 (atomic timeline replacement): with a PSRAM staging buffer the new upload
        // is assembled off-screen and swapped in only on commit, so the running scroll must
        // NOT be torn down here -- an interrupted/failed upload then leaves the old timeline
        // playing. Only the single-buffer in-place path still halts the old player up front
        // (it overwrites the live buffer, so it has no choice).
        if (!runtimeScrollDoubleBuffered()) {
            stopFirmwareScroll(false, false);
        }
        clearQueuedM370Frames();
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
        // Append chunk (append:true): snapshot metadata first, then validate according to v6 1.5.
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
            // EH-B: legacy pure-frame upload; timelineId/chunkIndex is optional, chunkIndex must be in order if present.
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

        // E1: Frame count limit check also applies to the first chunk (timeline/totalFrames backed upload).
        if (uploadTxn.totalFramesExpected > 0 &&
            static_cast<uint32_t>(uploadTxn.framesReceivedBase) + count + 1U > uploadTxn.totalFramesExpected) {
            scrollSessionInvalidateCache();
            RLOG_WARN("SCROLL", "event=upload_reject reason=too_many_frames base=%u received=%u expected=%u",
                      static_cast<unsigned>(uploadTxn.framesReceivedBase), static_cast<unsigned>(count),
                      static_cast<unsigned>(uploadTxn.totalFramesExpected));
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
            // EH-A: Bad frame data invalidates the playback cache (frame count reset to zero + uploadComplete=false),
            // but sourceText is intentionally preserved, so recovery can still reconstruct the preview from the text.
            scrollSessionInvalidateCache();
            RLOG_WARN("SCROLL", "event=upload_reject reason=bad_frame index=%u detail=%s",
                      static_cast<unsigned>(targetIndex), error.c_str());
            sendError(400, String("invalid scroll frame ") + targetIndex + ": " + error);
            return;
        }
        if (!scrollSessionWriteFrame(uploadTxn, static_cast<uint16_t>(targetIndex), packedBits)) {
            RLOG_WARN("SCROLL", "event=upload_reject reason=not_writable index=%u",
                      static_cast<unsigned>(targetIndex));
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
    // D2: Incomplete timeline-backed caches are never playable (including explicit start:true).
    if (uploadTxn.timelineBacked && !uploadCompleteNow) shouldStart = false;

    // Audit M1: promote the staged replacement timeline to active as soon as it is complete,
    // OR when we are about to auto-start a legacy (totalFrames==0) upload. Promoting on
    // completion is essential because the WebUI's normal flow uploads with start:false and
    // then issues a SEPARATE start_scroll command -- that command starts the *active* slot,
    // so the new timeline must already be swapped in by then. promoteStaging is a no-op on
    // single-buffer boards / non-staged uploads, leaving the legacy in-place path unchanged.
    if (uploadCompleteNow || shouldStart) scrollSessionPromoteStaging();
    // Use the effective interval after promotion (the new timeline's interval is applied to
    // scrollIntervalMs at the atomic swap) rather than a timing-less append chunk's stale value.
    if (shouldStart) startFirmwareScroll(runtimeState().scrollIntervalMs);
    const ScrollSessionSnapshot scrollState = readScrollStateSnapshot();

    RLOG_INFO("SCROLL",
              "event=upload_commit frames=%u chunkFrames=%u sourceTextBytes=%u uploadComplete=%d started=%d bufferBytes=%u heapAfter=%u largestAfter=%u",
              static_cast<unsigned>(scrollState.scrollFrameCount), static_cast<unsigned>(count),
              static_cast<unsigned>(sourceText.length()), uploadCompleteNow ? 1 : 0,
              scrollState.firmwareScrollActive ? 1 : 0,
              static_cast<unsigned>(runtimeScrollFrameBufferBytes()),
              static_cast<unsigned>(ESP.getFreeHeap()),
              static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)));

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

// Lightweight scroll metadata (P0-2). This endpoint is polled during boot recovery
// and while the WebUI is on the scroll page, so it must be cheap: it does NOT copy
// sourceText and does NOT allocate a large (PSRAM) JsonDocument. The previous version
// allocated a 4KB text buffer + a 16KB doc on every poll, which -- if PSRAM was
// unavailable/unstable and the allocator fell back to internal heap -- could be the
// "last straw" that reset the board after a refresh. The (potentially large)
// sourceText is now fetched separately and only on explicit user action via
// /api/scroll/source.
static void handleApiScrollMeta() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_GET)     { sendError(405, "method not allowed"); return; }

    if (httpRejectIfLowMemory("scroll_meta")) return;

    ScrollMetaOut metaOut;
    // nullptr text buffer => lightweight copy: no 4KB text alloc, hasSourceText and
    // sourceTextBytes stay populated so the WebUI knows whether text is recoverable.
    scrollSessionCopyMeta(metaOut, nullptr, 0);

    // Stack-resident, no heap: timelineId/fontId/generatorVersion are short bounded
    // strings stored by reference (metaOut outlives serialization).
    StaticJsonDocument<1024> doc;
    doc["ok"]                   = true;
    doc["scrollTimelineId"]     = static_cast<const char*>(metaOut.meta.timelineId);
    doc["hasSourceText"]        = metaOut.meta.hasSourceText;
    doc["sourceTextBytes"]      = metaOut.meta.sourceTextByteLength;
    doc["fontId"]               = static_cast<const char*>(metaOut.meta.fontId);
    doc["generatorVersion"]     = static_cast<const char*>(metaOut.meta.generatorVersion);
    doc["uiFps"]                = metaOut.meta.uiFps;
    doc["scrollIntervalMs"]     = metaOut.scrollIntervalMs;
    doc["frameCount"]           = metaOut.frameCount;
    doc["frameIndex"]           = metaOut.frameIndex;
    doc["uploadComplete"]       = metaOut.meta.uploadComplete;
    doc["firmwareScrollDisplaying"] = metaOut.active || metaOut.paused;
    doc["firmwareScrollActive"] = metaOut.active;
    doc["firmwareScrollPaused"] = metaOut.paused;
    doc["firmwareScrollUserPaused"] = metaOut.userPaused;
    doc["firmwareScrollSystemPaused"] = metaOut.systemPaused;
    doc["uploadStaleCleared"]   = scrollSessionConsumeUploadStaleCleared();
    sendJsonDocument(200, doc);
}

// Returns the scroll sourceText (P0-2). Only called on explicit user action (e.g.
// "restore text & preview"), never on the polled path. Copy under lock (meta + text
// memcpy), serialize outside the lock; capacity/overflow -> 507. The doc is sized to
// the text rather than a fixed 16KB to keep the rare allocation modest.
static void handleApiScrollSource() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_GET)     { sendError(405, "method not allowed"); return; }

    if (httpRejectIfLowMemory("scroll_source")) return;

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

    // Worst-case JSON expansion of valid sourceText is ~2x (only '"' and '\\' escape;
    // control chars are rejected at upload). Size to that plus envelope overhead.
    PsramJsonDocument doc(textCapacity * 2U + 1024U);
    if (doc.capacity() == 0) {
        if (textCopy != nullptr) heap_caps_free(textCopy);
        sendError(507, "source json alloc failed");
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
    doc["frameCount"]           = metaOut.frameCount;
    doc["frameIndex"]           = metaOut.frameIndex;
    doc["firmwareScrollDisplaying"] = metaOut.active || metaOut.paused;
    if (doc.overflowed()) {
        if (textCopy != nullptr) heap_caps_free(textCopy);
        sendError(507, "source json overflow");
        return;
    }
    sendJsonDocument(200, doc);
    if (textCopy != nullptr) heap_caps_free(textCopy);
}

using ApiCommandHandler = bool (*)(JsonDocument& doc, JsonVariant payload, String& error);

// Conflict requires 409, others remain 400. Reset before each dispatch.
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

    // E6: Extract payload timelineId to stack buffer and validate length/charset before entering the lock;
    // never compare using truncated IDs.
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

    // D2/D8/H-D: Complete all decisions within one scrollMutex snapshot, bring out errors using enum,
    // do not write any heap String inside the lock.
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
            if (!meta.uploadComplete) {   // D2: block even if payload has no timelineId
                serr = StartScrollError::UploadIncomplete;
                return;
            }
        }
        if (!hasFrames) {
            serr = StartScrollError::NoCachedFrames;
            return;
        }
    });
    // Mapping outside lock: TimelineMismatch / UploadIncomplete -> 409, NoCachedFrames -> 400.
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
    commandBoolField(doc, payload, "clear", clearDisplay);
    // M2: firmware is the SOLE authority for the post-scroll return mode. The WebUI's
    // local returnMode resets to its "manual" default across a page refresh, so trusting
    // a payload `restoreAuto` could send the board back to the wrong mode after reload.
    // The firmware-stored restoreAutoAfterScroll (latched when the scroll was entered
    // from Auto) is authoritative; the payload field is intentionally ignored. `clear`
    // stays caller-controlled because it is a display action, not a mode decision.
    const bool restoreAuto = scrollSessionGetRestoreAuto();
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
        assignText(runtimeState().playback, "paused");
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
        assignText(runtimeState().playback, DEFAULT_PLAYBACK);
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
    if (strcmp(targetMode, "scroll") != 0) stopFirmwareScrollForNonScrollOutput("api_terminate_non_scroll");
    if (strcmp(targetMode, "face") != 0 && strcmp(targetMode, "scroll") != 0) {
        setMode("manual", true);
    } else if (strcmp(targetMode, "scroll") == 0 && isAutoMode()) {
        scrollSessionSetRestoreAuto(true);
        assignText(runtimeState().mode, "manual");
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

    // Crash protection (any mode): commands drive mode switches, scroll start/stop,
    // etc. Shed under low heap rather than allocate the parse doc and risk a panic.
    if (httpRejectIfLowMemory("command")) return;

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

    // Crash protection: this parses a potentially large faces JSON (body copy + a
    // PSRAM doc sized to the body) and then writes flash. Shed it when internal heap
    // is low so a refresh-time burst cannot OOM-panic the board.
    if (httpRejectIfLowMemory("saved_faces_write")) return;

    const String body = requestBody();
    if (body.isEmpty()) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_write err=empty_body");
        sendError(400, "empty JSON body"); return;
    }
    if (body.length() > HTTP_MAX_REQUEST_BODY_BYTES) {
        RLOG_WARN("CMD", "event=reject source=webui cmd=saved_faces_write err=body_too_large bytes=%u",
                  static_cast<unsigned>(body.length()));
        sendError(413, String("saved_faces body exceeds ") + HTTP_MAX_REQUEST_BODY_BYTES + " bytes");
        return;
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
        assignText(runtimeState().colorHex, "#ff0000");
        runtimeState().colorR     = 0xff;
        runtimeState().colorG     = 0x00;
        runtimeState().colorB     = 0x00;
        runtimeState().brightness = DEFAULT_BRIGHTNESS;
        memset(runtimeFrameBits(), 0, FRAME_BYTES);
        for (uint16_t i = 0; i < 12 && i < LED_COUNT; ++i) setFrameBit(i, true);
        assignText(runtimeState().lastReason, "littlefs_mount_failed");
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
    server.on("/api/frame_bin",   HTTP_ANY, handleApiFrameBin);
    server.on("/api/perf",        HTTP_ANY, handleApiPerf);
    server.on("/api/scroll",      HTTP_ANY, handleApiScroll);
    server.on("/api/scroll/meta", HTTP_ANY, handleApiScrollMeta);
    server.on("/api/scroll/source", HTTP_ANY, handleApiScrollSource);
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

    // P1-6: periodically reclaim a staged replacement timeline left behind by an
    // interrupted upload. Throttled so it adds no per-request cost; only ever clears
    // the off-screen staging buffer (never the active/playing timeline).
    static uint32_t sLastScrollStaleCheckMs = 0;
    const uint32_t nowMs = millis();
    if (nowMs - sLastScrollStaleCheckMs >= SCROLL_UPLOAD_STALE_CHECK_MS) {
        sLastScrollStaleCheckMs = nowMs;
        scrollSessionClearStaleUpload(SCROLL_UPLOAD_STALE_TIMEOUT_MS);
    }
}
