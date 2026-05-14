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
#include <WebServer.h>
#include <WiFi.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <pgmspace.h>

static WebServer server(HTTP_PORT);

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

static const char CONTENT_TYPE_JSON_UTF8[] = "application/json; charset=utf-8";
static const char CONTENT_TYPE_HTML_UTF8[] = "text/html; charset=utf-8";
static const char CONTENT_TYPE_TEXT_PLAIN[] = "text/plain";
static const uint16_t STATIC_STREAM_CHUNK_BYTES = 1024;
static const TickType_t WEB_YIELD_TICKS = pdMS_TO_TICKS(1);

static const char* contentTypeFor(const String& path) {
    const int dotIdx = path.lastIndexOf('.');
    if (dotIdx < 0 || dotIdx == static_cast<int>(path.length()) - 1) {
        return "application/octet-stream";
    }

    String ext = path.substring(dotIdx + 1);
    ext.toLowerCase();

    if (ext == "html") return CONTENT_TYPE_HTML_UTF8;
    if (ext == "css") return "text/css; charset=utf-8";
    if (ext == "js") return "application/javascript; charset=utf-8";
    if (ext == "json") return CONTENT_TYPE_JSON_UTF8;
    if (ext == "svg") return "image/svg+xml";
    if (ext == "png") return "image/png";
    if (ext == "jpg" || ext == "jpeg") return "image/jpeg";
    if (ext == "ico") return "image/x-icon";
    if (ext == "ttf") return "font/ttf";
    if (ext == "woff2") return "font/woff2";
    if (ext == "otf") return "font/otf";
    return "application/octet-stream";
}

static void addCorsHeaders() {
    server.sendHeader("Access-Control-Allow-Origin",  "*");
    server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
    server.sendHeader("Cache-Control",                "no-store");
}

static bool littleFsExistsLocked(const String& path) {
    bool exists = false;
    lockHardwareBus();
    exists = LittleFS.exists(path);
    unlockHardwareBus();
    return exists;
}

static File littleFsOpenLocked(const String& path, const char* mode) {
    lockHardwareBus();
    File file = LittleFS.open(path, mode);
    unlockHardwareBus();
    return file;
}

static size_t fileSizeLocked(File& file) {
    lockHardwareBus();
    const size_t size = file.size();
    unlockHardwareBus();
    return size;
}

static void closeFileLocked(File& file) {
    lockHardwareBus();
    file.close();
    unlockHardwareBus();
}

static void streamFileChunked(File& file, const char* contentType) {
    server.setContentLength(fileSizeLocked(file));
    server.send(200, contentType, "");

    uint8_t buffer[STATIC_STREAM_CHUNK_BYTES];
    while (true) {
        size_t bytesRead = 0;
        bool hasData = false;

        lockHardwareBus();
        hasData = file.available();
        if (hasData) {
            bytesRead = file.read(buffer, sizeof(buffer));
        }
        unlockHardwareBus();

        if (!hasData || bytesRead == 0) break;
        server.sendContent(reinterpret_cast<const char*>(buffer), bytesRead);
        vTaskDelay(WEB_YIELD_TICKS);
    }
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

static void addPowerStatus(JsonObject power) {
    const bool batteryOk = powerStatus.batteryValid;
    const bool chargeOk = powerStatus.chargeValid;
    const char* batteryIconClass = "status-dot dim";
    const char* batteryIconColor = "#9aa6b2";
    if (batteryOk) {
        if (powerStatus.batteryPercent < 20) {
            batteryIconClass = "status-dot danger";
            batteryIconColor = "#ef4444";
        } else if (powerStatus.batteryPercent < 50) {
            batteryIconClass = "status-dot warn";
            batteryIconColor = "#f59e0b";
        } else {
            batteryIconClass = "status-dot";
            batteryIconColor = "#59d98e";
        }
    }

    const char* chargeIconClass = (chargeOk && powerStatus.charging) ? "status-dot" : "status-dot dim";
    const char* chargeIconColor = (chargeOk && powerStatus.charging) ? "#59d98e" : "#9aa6b2";

    power["batteryGpio"]      = BATTERY_ADC_PIN;
    power["chargeGpio"]       = CHARGE_ADC_PIN;
    if (powerStatus.batteryValid) power["vbat"]           = powerStatus.vbat;
    else                          power["vbat"]           = nullptr;
    if (powerStatus.batteryValid) power["batteryPercent"] = powerStatus.batteryPercent;
    else                          power["batteryPercent"] = nullptr;
    if (powerStatus.chargeValid)  power["vcharge"]        = powerStatus.vcharge;
    else                          power["vcharge"]        = nullptr;
    if (powerStatus.chargeValid)  power["charging"]       = powerStatus.charging;
    else                          power["charging"]       = nullptr;
    power["batteryAdcMv"]     = powerStatus.batteryAdcMv;
    power["chargeAdcMv"]      = powerStatus.chargeAdcMv;
    power["batteryValid"]     = powerStatus.batteryValid;
    power["chargeValid"]      = powerStatus.chargeValid;
    power["ok"]               = powerStatus.batteryValid || powerStatus.chargeValid;
    power["batteryIconClass"] = batteryIconClass;
    power["batteryIconColor"] = batteryIconColor;
    power["chargeIconClass"]  = chargeIconClass;
    power["chargeIconColor"]  = chargeIconColor;
    power["batteryRangeMin"]  = powerStatus.batteryCalibMinV;
    power["batteryRangeMax"]  = powerStatus.batteryCalibMaxV;
    power["batteryNominalMin"] = BATTERY_EMPTY_V;
    power["batteryNominalMax"] = BATTERY_FULL_V;
    power["batteryCalibLoaded"] = powerStatus.batteryCalibLoaded;
    power["batteryCalibDirty"] = powerStatus.batteryCalibDirty;
    power["batteryCalibPath"] = BATTERY_CALIB_PATH;
    power["chargeThreshold"]  = CHARGE_PRESENT_V;
    power["batterySampleMs"]  = BATTERY_SAMPLE_MS;
    power["chargeSampleMs"]   = CHARGE_SAMPLE_MS;
    power["lastBatteryMs"]    = powerStatus.lastBatteryMs;
    power["lastChargeMs"]     = powerStatus.lastChargeMs;
    power["lastCalibMaxMs"]   = powerStatus.lastCalibMaxMs;
    power["lastCalibMinMs"]   = powerStatus.lastCalibMinMs;
}

static String requestBody() {
    return server.hasArg("plain") ? server.arg("plain") : "";
}

static bool parseJsonBody(DynamicJsonDocument& doc, String& error) {
    const String body = requestBody();
    if (body.isEmpty()) { error = "empty JSON body"; return false; }
    DeserializationError err = deserializeJson(doc, body);
    if (err) { error = String("invalid JSON: ") + err.c_str(); return false; }
    return true;
}

static int jsonFieldValuePosition(const String& body, const char* key) {
    const String token = String("\"") + key + "\"";
    const int keyPos = body.indexOf(token);
    if (keyPos < 0) return -1;

    const int colon = body.indexOf(':', keyPos);
    if (colon < 0) return -1;

    int p = colon + 1;
    while (p >= 0 && static_cast<size_t>(p) < body.length() &&
           isspace(static_cast<unsigned char>(body.charAt(p)))) {
        ++p;
    }
    return p;
}

static int findJsonStringEnd(const String& body, size_t quotePos) {
    if (quotePos >= body.length() || body.charAt(quotePos) != '"') return -1;

    bool escaped = false;
    for (size_t i = quotePos + 1; i < body.length(); ++i) {
        const char c = body.charAt(i);
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') return static_cast<int>(i);
    }
    return -1;
}

static bool extractJsonStringAt(const String& body, size_t quotePos, String& value, int& endQuote) {
    endQuote = findJsonStringEnd(body, quotePos);
    if (endQuote < 0) return false;

    const String raw = body.substring(quotePos + 1, endQuote);
    if (raw.indexOf('\\') < 0) {
        value = raw;
        return true;
    }

    value = "";
    value.reserve(raw.length());
    bool escaped = false;
    for (size_t i = 0; i < raw.length(); ++i) {
        const char c = raw.charAt(i);
        if (!escaped) {
            if (c == '\\') {
                escaped = true;
            } else {
                value += c;
            }
            continue;
        }

        switch (c) {
            case '"': value += '"'; break;
            case '\\': value += '\\'; break;
            case '/': value += '/'; break;
            case 'b': value += '\b'; break;
            case 'f': value += '\f'; break;
            case 'n': value += '\n'; break;
            case 'r': value += '\r'; break;
            case 't': value += '\t'; break;
            default:
                value += c;
                break;
        }
        escaped = false;
    }
    return !escaped;
}

static bool jsonBoolField(const String& body, const char* key, bool defaultValue) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0) return defaultValue;
    if (body.substring(p, p + 4) == "true") return true;
    if (body.substring(p, p + 5) == "false") return false;
    return defaultValue;
}

static bool jsonUintField(const String& body, const char* key, uint32_t& value) {
    int p = jsonFieldValuePosition(body, key);
    if (p < 0) return false;

    uint32_t parsed = 0;
    bool foundDigit = false;
    while (static_cast<size_t>(p) < body.length() &&
           isdigit(static_cast<unsigned char>(body.charAt(p)))) {
        foundDigit = true;
        parsed = parsed * 10 + static_cast<uint32_t>(body.charAt(p++) - '0');
    }
    if (!foundDigit) return false;
    value = parsed;
    return true;
}

static bool jsonFloatField(const String& body, const char* key, float& value) {
    int p = jsonFieldValuePosition(body, key);
    if (p < 0) return false;

    int q = p;
    while (static_cast<size_t>(q) < body.length()) {
        const char c = body.charAt(q);
        if (!(isdigit(static_cast<unsigned char>(c)) || c == '.' || c == '-' ||
              c == '+' || c == 'e' || c == 'E')) {
            break;
        }
        ++q;
    }
    if (q == p) return false;
    value = body.substring(p, q).toFloat();
    return true;
}

static bool jsonStringField(const String& body, const char* key, String& value) {
    const int p = jsonFieldValuePosition(body, key);
    if (p < 0 || static_cast<size_t>(p) >= body.length() || body.charAt(p) != '"') return false;

    int endQuote = -1;
    return extractJsonStringAt(body, static_cast<size_t>(p), value, endQuote);
}

static void pauseFirmwareScrollIfActive(bool& changed) {
    withScrollLock([&]() {
        if (state.firmwareScrollActive) {
            state.firmwareScrollPaused = true;
            state.paused               = true;
            state.playback             = "scroll_paused";
            changed                    = true;
        }
    });
}

static void resumeFirmwareScrollIfCached(bool& changed, bool requirePaused = false) {
    withScrollLock([&]() {
        if (state.scrollFrameCount > 0 && (!requirePaused || state.firmwareScrollPaused)) {
            state.firmwareScrollActive  = true;
            state.firmwareScrollPaused  = false;
            state.lastScrollFrameMs     = millis();
            state.paused                = false;
            state.playback              = "scroll";
            changed                     = true;
        }
    });
}

static bool serveStaticFile(String path) {
    if (!fsMounted) return false;
    if (path == "/") path = "/index.html";
    if (path.endsWith("/")) path += "index.html";
    if (!littleFsExistsLocked(path)) return false;
    File file = littleFsOpenLocked(path, "r");
    if (!file) return false;
    addCorsHeaders();
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
// Route handlers
// ---------------------------------------------------------------------------

static void handleOptions() {
    addCorsHeaders();
    server.send(204, CONTENT_TYPE_TEXT_PLAIN, "");
}

static void handleApiStatus() {
    servicePowerMonitor();

    bool     firmwareScrollActive   = false;
    bool     firmwareScrollPaused   = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount       = 0;
    uint16_t scrollFrameIndex       = 0;
    uint16_t scrollIntervalMs       = DEFAULT_SCROLL_INTERVAL_MS;

    withScrollLock([&]() {
        firmwareScrollActive   = state.firmwareScrollActive;
        firmwareScrollPaused   = state.firmwareScrollPaused;
        restoreAutoAfterScroll = state.restoreAutoAfterScroll;
        scrollFrameCount       = state.scrollFrameCount;
        scrollFrameIndex       = state.scrollFrameIndex;
        scrollIntervalMs       = state.scrollIntervalMs;
    });

    const bool scrolling   = firmwareScrollActive || firmwareScrollPaused;
    const bool runtimeOnly = server.hasArg("runtimeOnly");
    const bool summaryOnly = runtimeOnly || server.hasArg("summary") || server.hasArg("noFrame");
    DynamicJsonDocument doc((runtimeOnly || scrolling || summaryOnly) ? 4096 : 6144);
    doc["ok"]     = true;
    doc["device"] = "RinaChanBoard";
    doc["uptimeMs"] = millis() - state.bootMs;
    if (runtimeOnly) doc["runtimeOnly"] = true;

    JsonObject ap = doc.createNestedObject("ap");
    ap["ssid"]    = AP_SSID;
    ap["ip"]      = WiFi.softAPIP().toString();
    ap["clients"] = WiFi.softAPgetStationNum();

    addPowerStatus(doc.createNestedObject("power"));

    JsonObject renderer = doc.createNestedObject("renderer");
    renderer["color"]                   = state.colorHex;
    renderer["brightness"]              = state.brightness;
    renderer["brightnessMin"]           = MIN_BRIGHTNESS;
    renderer["brightnessMax"]           = MAX_BRIGHTNESS;
    renderer["mode"]                    = state.mode;
    renderer["playback"]                = state.playback;
    renderer["paused"]                  = state.paused;
    renderer["autoIntervalMs"]          = state.autoIntervalMs;
    renderer["autoFaceCount"]           = autoFaceCount;
    renderer["autoFaceIndex"]           = state.autoFaceIndex;
    renderer["firmwareScrollActive"]    = firmwareScrollActive;
    renderer["firmwareScrollPaused"]    = firmwareScrollPaused;
    renderer["restoreAutoAfterScroll"]  = restoreAutoAfterScroll;
    renderer["deferredFaceRestoreActive"] = state.deferredFaceRestoreActive;
    renderer["scrollFrameCount"]        = scrollFrameCount;
    renderer["scrollFrameIndex"]        = scrollFrameIndex;
    renderer["scrollIntervalMs"]        = scrollIntervalMs;
    renderer["scrollMaxFrames"]         = MAX_SCROLL_FRAMES;
    if (autoFaceCount > 0 && state.autoFaceIndex < autoFaceCount) {
        renderer["autoFaceId"]   = autoFaces[state.autoFaceIndex].id;
        renderer["autoFaceName"] = autoFaces[state.autoFaceIndex].name;
    }
    if (!scrolling && !summaryOnly) {
        renderer["lastM370"] = state.lastM370;
        renderer["lit"]      = countLitLeds();
    } else if (summaryOnly) {
        renderer["lastM370Skipped"] = true;
    } else {
        renderer["lastM370Deferred"] = true;
    }
    renderer["lastReason"] = state.lastReason;

    // The WebUI boot path uses runtimeOnly=1&noFrame=1.  Return immediately
    // after runtime state so the first visible page can be built from current
    // firmware color/brightness/power/mode without paying for matrix, storage,
    // statistics, or last-frame serialization.
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
    storage["mounted"]           = fsMounted;
    storage["savedFacesPath"]    = SAVED_FACES_PATH;
    storage["savedFacesExists"]  = fsMounted && littleFsExistsLocked(SAVED_FACES_PATH);
    storage["settingsPath"]      = SETTINGS_PATH;
    storage["settingsExists"]    = fsMounted && littleFsExistsLocked(SETTINGS_PATH);
    if (fsMounted && !scrolling && !summaryOnly) {
        lockHardwareBus();
        storage["totalBytes"] = static_cast<uint32_t>(LittleFS.totalBytes());
        storage["usedBytes"]  = static_cast<uint32_t>(LittleFS.usedBytes());
        unlockHardwareBus();
    } else if (summaryOnly) {
        storage["capacitySkippedInSummary"] = true;
    } else if (scrolling) {
        storage["capacityDeferredDuringScroll"] = true;
    }

    JsonObject stats = doc.createNestedObject("stats");
    stats["framesAccepted"]    = state.framesAccepted;
    stats["framesRejected"]    = state.framesRejected;
    stats["commandsAccepted"]  = state.commandsAccepted;
    stats["commandsRejected"]  = state.commandsRejected;
    stats["savedFacesWrites"]  = state.savedFacesWrites;
    stats["settingsWrites"]    = state.settingsWrites;

    sendJsonDocument(200, doc);
}

static void handleApiPower() {
    servicePowerMonitor();

    DynamicJsonDocument doc(1024);
    doc["ok"] = true;
    addPowerStatus(doc.createNestedObject("power"));
    sendJsonDocument(200, doc);
}

static void handleApiFrame() {
    String error;
    DynamicJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) { sendError(400, error); return; }

    const char* m370 = doc["m370"] | "";
    if (strlen(m370) == 0) {
        ++state.framesRejected;
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
        setMode("manual", true);
    }
    state.playback = mode;

    if (!applyM370(m370, reason, error)) { sendError(400, error); return; }

    DynamicJsonDocument reply(768);
    reply["ok"]            = true;
    reply["accepted"]      = true;
    reply["leds"]          = LED_COUNT;
    reply["color"]         = state.colorHex;
    reply["brightness"]    = state.brightness;
    reply["reason"]        = state.lastReason;
    reply["mode"]          = state.mode;
    reply["autoIntervalMs"] = state.autoIntervalMs;
    reply["autoFaceIndex"] = state.autoFaceIndex;
    reply["m370"]          = state.lastM370;
    reply["lit"]           = countLitLeds();
    sendJsonDocument(200, reply);
}

static void handleApiScroll() {
    if (server.method() == HTTP_OPTIONS) { handleOptions(); return; }
    if (server.method() != HTTP_POST)    { sendError(405, "method not allowed"); return; }

    const String body = requestBody();
    if (body.isEmpty()) { sendError(400, "empty JSON body"); return; }

    uint16_t intervalMs = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t intervalValue = 0;
    if (jsonUintField(body, "intervalMs", intervalValue) && intervalValue > 0) {
        intervalMs = static_cast<uint16_t>(intervalValue > 65535UL ? 65535UL : intervalValue);
    } else {
        float fps = 0.0f;
        if (jsonFloatField(body, "fps", fps) && fps > 0.0f) {
            intervalMs = static_cast<uint16_t>(roundf(1000.0f / fps));
        }
    }

    // Long text scroll uploads are sent in small RAM-only chunks by the WebUI.
    // append=false clears the previous RAM timeline; append=true adds frames.
    // The final chunk sets start=true.
    const bool shouldStart = jsonBoolField(body, "start", true);
    const bool appendFrames = jsonBoolField(body, "append", false);
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

    // --- Parse frames array ---
    const int framesKey = body.indexOf("\"frames\"");
    if (framesKey < 0) { sendError(400, "frames must be an array"); return; }
    const int arrayStart = body.indexOf('[', framesKey);
    if (arrayStart < 0) { sendError(400, "frames must be an array"); return; }
    size_t pos = static_cast<size_t>(arrayStart + 1);

    uint16_t baseIndex = 0;
    if (!appendFrames) {
        stopFirmwareScroll(false);
        withScrollLock([]() {
            state.scrollFrameCount = 0;
            state.scrollFrameIndex = 0;
        });
    } else {
        withScrollLock([&]() {
            baseIndex = state.scrollFrameCount;
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
        if (!m370ToPackedBits(m370, scrollFrameBits[targetIndex], error)) {
            sendError(400, String("invalid scroll frame ") + targetIndex + ": " + error);
            withScrollLock([]() { state.scrollFrameCount = 0; });
            return;
        }
        ++count;
        pos = static_cast<size_t>(endQuote + 1);
    }

    if (count == 0) {
        sendError(400, "frames must include at least one valid M370 frame"); return;
    }

    withScrollLock([&]() {
        state.scrollFrameCount = baseIndex + count;
        state.scrollFrameIndex = 0;
        state.scrollIntervalMs = constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
    });

    if (shouldStart) startFirmwareScroll(intervalMs);

    DynamicJsonDocument reply(768);
    reply["ok"]                   = true;
    reply["frames"]               = state.scrollFrameCount;
    reply["chunkFrames"]          = count;
    reply["chunkIndex"]           = chunkIndex;
    reply["totalFrames"]          = totalFrames;
    reply["append"]               = appendFrames;
    reply["started"]              = state.firmwareScrollActive;
    reply["source"]               = source;
    reply["storage"]              = "ram";
    reply["persist"]              = false;
    reply["saveToFlash"]          = false;
    reply["mode"]                 = state.mode;
    reply["playback"]             = state.playback;
    reply["restoreAutoAfterScroll"] = state.restoreAutoAfterScroll;
    reply["scrollIntervalMs"]     = state.scrollIntervalMs;
    reply["scrollMaxFrames"]      = MAX_SCROLL_FRAMES;
    reply["stepLedPerFrame"]      = 1;
    sendJsonDocument(200, reply);
}


using ApiCommandHandler = bool (*)(DynamicJsonDocument& doc, JsonVariant payload, String& error);

static bool commandSetColor(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    const char* hex = payload["hex"] | "";
    if (strlen(hex) == 0) hex = doc["hex"] | "";
    return setColor(hex, error);
}

static bool commandSetBrightness(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    int raw = state.brightness;
    if      (payload["raw"].is<int>())        raw = payload["raw"].as<int>();
    else if (payload["brightness"].is<int>()) raw = payload["brightness"].as<int>();
    else if (doc["raw"].is<int>())            raw = doc["raw"].as<int>();
    setBrightness(raw);
    return true;
}

static bool commandSetMode(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    cancelDeferredFaceRestore();
    const char* mode = payload["mode"] | "";
    if (strlen(mode) == 0) mode = doc["mode"] | "";
    if (strlen(mode) == 0 || !setMode(mode)) {
        error = "invalid mode";
        return false;
    }
    return true;
}

static bool commandSetAutoInterval(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    uint32_t ms = state.autoIntervalMs;
    if      (payload["ms"].is<uint32_t>()) ms = payload["ms"].as<uint32_t>();
    else if (doc["ms"].is<uint32_t>())     ms = doc["ms"].as<uint32_t>();
    setAutoInterval(ms);
    return true;
}

static bool commandSetScrollInterval(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    uint16_t iMs = state.scrollIntervalMs;
    if (payload["intervalMs"].is<uint16_t>()) {
        iMs = payload["intervalMs"].as<uint16_t>();
    } else if (payload["fps"].is<float>()) {
        const float fps = payload["fps"].as<float>();
        if (fps > 0.0f) iMs = static_cast<uint16_t>(roundf(1000.0f / fps));
    } else if (doc["intervalMs"].is<uint16_t>()) {
        iMs = doc["intervalMs"].as<uint16_t>();
    }
    withScrollLock([&]() {
        state.scrollIntervalMs  = constrain(iMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        state.lastScrollFrameMs = millis();
    });
    return true;
}

static bool commandScrollStep(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    uint8_t steppedFrame[FRAME_BYTES];
    bool    hasSteppedFrame = false;
    withScrollLock([&]() {
        if (state.scrollFrameCount > 0) {
            state.scrollFrameIndex = (state.scrollFrameIndex + 1) % state.scrollFrameCount;
            state.playback         = "scroll_step";
            memcpy(steppedFrame, scrollFrameBits[state.scrollFrameIndex], FRAME_BYTES);
            hasSteppedFrame = true;
        }
    });
    if (hasSteppedFrame) applyPackedFrame(steppedFrame, "firmware_text_scroll_step");
    return true;
}

static bool commandPauseScroll(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool ignored = false;
    pauseFirmwareScrollIfActive(ignored);
    return true;
}

static bool commandResumeScroll(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool ignored = false;
    resumeFirmwareScrollIfCached(ignored);
    return true;
}

static bool commandStopScroll(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)error;
    bool clearDisplay = true;
    bool restoreAuto  = true;
    if (payload["clear"].is<bool>())         clearDisplay = payload["clear"].as<bool>();
    else if (doc["clear"].is<bool>())        clearDisplay = doc["clear"].as<bool>();
    if (payload["restoreAuto"].is<bool>())   restoreAuto  = payload["restoreAuto"].as<bool>();
    else if (doc["restoreAuto"].is<bool>())  restoreAuto  = doc["restoreAuto"].as<bool>();
    stopFirmwareScroll(restoreAuto, clearDisplay);
    return true;
}

static bool commandPause(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool pausedScroll = false;
    pauseFirmwareScrollIfActive(pausedScroll);
    if (!pausedScroll) {
        state.paused   = true;
        state.playback = "paused";
    }
    return true;
}

static bool commandResume(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)payload;
    (void)error;
    bool resumedScroll = false;
    resumeFirmwareScrollIfCached(resumedScroll, true);
    if (!resumedScroll) {
        state.paused   = false;
        state.playback = DEFAULT_PLAYBACK;
    }
    return true;
}

static bool commandButton(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    const char* button = payload["button"] | "";
    if (strlen(button) == 0) button = doc["button"] | "";
    if (!runButtonAction(String(button), "api_button")) {
        error = "unsupported button or no saved faces available";
        return false;
    }
    return true;
}

static bool commandTerminateOtherActivities(DynamicJsonDocument& doc, JsonVariant payload, String& error) {
    (void)doc;
    (void)error;
    const char* targetMode = payload["targetMode"] | "";
    if (strcmp(targetMode, "scroll") != 0) stopFirmwareScroll(false, false);
    if (strcmp(targetMode, "face") != 0 && strcmp(targetMode, "scroll") != 0) {
        setMode("manual", true);
    } else if (strcmp(targetMode, "scroll") == 0 && isAutoMode()) {
        state.restoreAutoAfterScroll = true;
        state.mode                   = "manual";
    }
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
    {"scroll_step",                commandScrollStep},
    {"pause_scroll",               commandPauseScroll},
    {"resume_scroll",              commandResumeScroll},
    {"stop_scroll",                commandStopScroll},
    {"pause",                      commandPause},
    {"resume",                     commandResume},
    {"button",                     commandButton},
    {"terminate_other_activities", commandTerminateOtherActivities},
};

static const ApiCommandRoute* findApiCommandRoute(const String& cmd) {
    for (const ApiCommandRoute& route : API_COMMAND_ROUTES) {
        if (cmd == route.name) return &route;
    }
    return nullptr;
}

static void handleApiCommand() {
    String error;
    DynamicJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) {
        ++state.commandsRejected;
        sendError(400, error);
        return;
    }

    const String  cmd     = doc["cmd"] | "";
    JsonVariant   payload = doc["payload"];
    if (cmd.isEmpty()) {
        ++state.commandsRejected;
        sendError(400, "missing cmd");
        return;
    }

    const ApiCommandRoute* route = findApiCommandRoute(cmd);
    if (route == nullptr) {
        ++state.commandsRejected;
        sendError(400, String("unknown command: ") + cmd);
        return;
    }

    if (!route->handler(doc, payload, error)) {
        ++state.commandsRejected;
        sendError(400, error);
        return;
    }

    ++state.commandsAccepted;

    DynamicJsonDocument reply(1024);
    reply["ok"]                   = true;
    reply["cmd"]                  = cmd;
    reply["color"]                = state.colorHex;
    reply["brightness"]           = state.brightness;
    reply["mode"]                 = state.mode;
    reply["autoIntervalMs"]       = state.autoIntervalMs;
    reply["playback"]             = state.playback;
    reply["paused"]               = state.paused;
    reply["autoFaceIndex"]        = state.autoFaceIndex;
    reply["firmwareScrollActive"] = state.firmwareScrollActive;
    reply["firmwareScrollPaused"] = state.firmwareScrollPaused;
    reply["restoreAutoAfterScroll"] = state.restoreAutoAfterScroll;
    reply["deferredFaceRestoreActive"] = state.deferredFaceRestoreActive;
    reply["scrollFrameCount"]     = state.scrollFrameCount;
    reply["scrollFrameIndex"]     = state.scrollFrameIndex;
    reply["scrollIntervalMs"]     = state.scrollIntervalMs;
    if (autoFaceCount > 0 && state.autoFaceIndex < autoFaceCount) {
        reply["autoFaceId"]   = autoFaces[state.autoFaceIndex].id;
        reply["autoFaceName"] = autoFaces[state.autoFaceIndex].name;
    }
    reply["m370"]       = state.lastM370;
    reply["lastReason"] = state.lastReason;
    sendJsonDocument(200, reply);
}

static void handleSavedFacesGet() {
    if (!fsMounted) { sendError(503, "LittleFS is not mounted; run pio run -t uploadfs"); return; }
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
    if (!fsMounted) { sendError(503, "LittleFS is not mounted; cannot write saved_faces.json"); return; }

    const String body = requestBody();
    if (body.isEmpty()) { sendError(400, "empty JSON body"); return; }

    const size_t capacity = jsonCapacityFor(body.length());
    DynamicJsonDocument doc(capacity);
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
    reply["path"]   = SAVED_FACES_PATH;
    reply["requestPath"] = requestPath;
    reply["reason"] = reason;
    reply["bytes"]  = written;
    reply["writes"] = state.savedFacesWrites;
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
    if (server.method() == HTTP_GET && !fsMounted) { sendFilesystemErrorPage(); return; }
    sendError(404, "not found: " + server.uri());
}

// ---------------------------------------------------------------------------
// LittleFS error pattern  (shown before web server is up)
// ---------------------------------------------------------------------------

void showFilesystemErrorPattern() {
    withFrameLock([]() {
        state.colorHex   = "#ff0000";
        state.colorR     = 0xff;
        state.colorG     = 0x00;
        state.colorB     = 0x00;
        state.brightness = DEFAULT_BRIGHTNESS;
        memset(frameBits, 0, sizeof(frameBits));
        for (uint16_t i = 0; i < 12 && i < LED_COUNT; ++i) setFrameBit(i, true);
        state.lastReason = "littlefs_mount_failed";
        showCurrentFrameNoLock();
    });
}

// ---------------------------------------------------------------------------
// Public: Access Point + WebServer startup
// ---------------------------------------------------------------------------

void startAccessPoint() {
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(apIP(), apGateway(), apSubnet());
    WiFi.softAP(AP_SSID, AP_PASSWORD);
    Serial.printf("AP started: ssid=%s password=%s ip=%s\n",
                  AP_SSID, AP_PASSWORD, WiFi.softAPIP().toString().c_str());
}

void startWebServer() {
    auto serveRoot = []() {
        if (!serveStaticFile("/")) {
            if (!fsMounted) sendFilesystemErrorPage();
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
    server.begin();
    Serial.printf("HTTP server listening on http://%s/\n",
                  WiFi.softAPIP().toString().c_str());
}

void webServerTick() {
    server.handleClient();
}
