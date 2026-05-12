#include "web_api.h"
#include "state.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "storage.h"
#include "faces.h"
#include "buttons.h"
#include <WebServer.h>
#include <WiFi.h>
#include <ArduinoJson.h>
#include <LittleFS.h>

static WebServer server(HTTP_PORT);

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

static String contentTypeFor(const String& path) {
    if (path.endsWith(".html"))          return "text/html; charset=utf-8";
    if (path.endsWith(".css"))           return "text/css; charset=utf-8";
    if (path.endsWith(".js"))            return "application/javascript; charset=utf-8";
    if (path.endsWith(".json"))          return "application/json; charset=utf-8";
    if (path.endsWith(".svg"))           return "image/svg+xml";
    if (path.endsWith(".png"))           return "image/png";
    if (path.endsWith(".jpg") ||
        path.endsWith(".jpeg"))          return "image/jpeg";
    if (path.endsWith(".ico"))           return "image/x-icon";
    if (path.endsWith(".ttf"))           return "font/ttf";
    if (path.endsWith(".woff2"))         return "font/woff2";
    if (path.endsWith(".otf"))           return "font/otf";
    return "application/octet-stream";
}

static void addCorsHeaders() {
    server.sendHeader("Access-Control-Allow-Origin",  "*");
    server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
    server.sendHeader("Cache-Control",                "no-store");
}

static void sendJsonDocument(int status, JsonDocument& doc) {
    String out;
    serializeJson(doc, out);
    addCorsHeaders();
    server.send(status, "application/json; charset=utf-8", out);
}

static void sendError(int status, const String& message) {
    DynamicJsonDocument doc(512);
    doc["ok"]    = false;
    doc["error"] = message;
    addCorsHeaders();
    String out;
    serializeJson(doc, out);
    server.send(status, "application/json; charset=utf-8", out);
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

static bool serveStaticFile(String path) {
    if (!fsMounted) return false;
    if (path == "/") path = "/index.html";
    if (path.endsWith("/")) path += "index.html";
    if (!LittleFS.exists(path)) return false;
    File file = LittleFS.open(path, "r");
    if (!file) return false;
    addCorsHeaders();
    server.streamFile(file, contentTypeFor(path));
    file.close();
    return true;
}

static void sendFilesystemErrorPage() {
    addCorsHeaders();
    server.send(
        503, "text/html; charset=utf-8",
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" "
        "content=\"width=device-width,initial-scale=1\"><title>LittleFS not mounted</title>"
        "<style>body{margin:0;padding:28px;background:#0f1117;color:#f4f7fb;"
        "font-family:system-ui,-apple-system,Segoe UI,sans-serif;line-height:1.5}"
        "code{background:#1e2430;padding:2px 5px;border-radius:5px}"
        ".box{max-width:720px;margin:auto;border:1px solid #2b3344;border-radius:12px;"
        "padding:20px;background:#161a24}</style></head><body><main class=\"box\">"
        "<h1>LittleFS data is not mounted</h1>"
        "<p>The ESP32-S3 AP is running, but the WebUI files are missing or the "
        "filesystem failed to mount.</p>"
        "<p>Upload the data image, then reboot:</p>"
        "<p><code>pio run -t uploadfs</code></p>"
        "<p>Expected files include <code>/index.html</code> and "
        "<code>/resources/saved_faces.json</code>.</p>"
        "</main></body></html>"
    );
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

static void handleOptions() {
    addCorsHeaders();
    server.send(204, "text/plain", "");
}

static void handleApiStatus() {
    bool     firmwareScrollActive   = false;
    bool     firmwareScrollPaused   = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount       = 0;
    uint16_t scrollFrameIndex       = 0;
    uint16_t scrollIntervalMs       = state.scrollIntervalMs;

    lockScroll();
    firmwareScrollActive   = state.firmwareScrollActive;
    firmwareScrollPaused   = state.firmwareScrollPaused;
    restoreAutoAfterScroll = state.restoreAutoAfterScroll;
    scrollFrameCount       = state.scrollFrameCount;
    scrollFrameIndex       = state.scrollFrameIndex;
    scrollIntervalMs       = state.scrollIntervalMs;
    unlockScroll();

    const bool scrolling = firmwareScrollActive || firmwareScrollPaused;
    DynamicJsonDocument doc(scrolling ? 2304 : 3072);
    doc["ok"]     = true;
    doc["device"] = "RinaChanBoard";
    doc["uptimeMs"] = millis() - state.bootMs;

    JsonObject ap = doc.createNestedObject("ap");
    ap["ssid"]    = AP_SSID;
    ap["ip"]      = WiFi.softAPIP().toString();
    ap["clients"] = WiFi.softAPgetStationNum();

    JsonObject matrix = doc.createNestedObject("matrix");
    matrix["leds"]                   = LED_COUNT;
    matrix["m370HexChars"]           = M370_HEX_CHARS;
    matrix["gpio"]                   = LED_PIN;
    matrix["m370BitOrder"]           = "logical_row_major";
    matrix["physicalWiring"]         = SERPENTINE_WIRING ? "serpentine" : "linear";
    matrix["serpentineOddRowsReversed"] = SERPENTINE_ODD_ROWS_REVERSED;

    JsonObject renderer = doc.createNestedObject("renderer");
    renderer["color"]                   = state.colorHex;
    renderer["brightness"]              = state.brightness;
    renderer["defaultBrightness"]       = state.defaultBrightness;
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
    if (!scrolling) {
        renderer["lastM370"] = state.lastM370;
        renderer["lit"]      = countLitLeds();
    } else {
        renderer["lastM370Deferred"] = true;
    }
    renderer["lastReason"] = state.lastReason;

    JsonObject endpoints = doc.createNestedObject("endpoints");
    endpoints["frame"]      = "/api/frame";
    endpoints["command"]    = "/api/command";
    endpoints["scroll"]     = "/api/scroll";
    endpoints["savedFaces"] = "/api/saved_faces";
    endpoints["status"]     = "/api/status";

    JsonObject storage = doc.createNestedObject("storage");
    storage["mounted"]           = fsMounted;
    storage["savedFacesPath"]    = SAVED_FACES_PATH;
    storage["savedFacesExists"]  = fsMounted && LittleFS.exists(SAVED_FACES_PATH);
    storage["settingsPath"]      = SETTINGS_PATH;
    storage["settingsExists"]    = fsMounted && LittleFS.exists(SETTINGS_PATH);
    if (fsMounted && !scrolling) {
        storage["totalBytes"] = static_cast<uint32_t>(LittleFS.totalBytes());
        storage["usedBytes"]  = static_cast<uint32_t>(LittleFS.usedBytes());
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

    if (strcmp(mode, "scroll") != 0 && strcmp(mode, "scroll_step") != 0) {
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

    // --- Parse intervalMs / fps (lightweight, no full JSON parse) ---
    uint16_t intervalMs = DEFAULT_SCROLL_INTERVAL_MS;
    int keyPos = body.indexOf("\"intervalMs\"");
    if (keyPos >= 0) {
        int colon = body.indexOf(':', keyPos);
        if (colon >= 0) {
            int p = colon + 1;
            while (p < (int)body.length() && isspace((unsigned char)body.charAt(p))) ++p;
            uint32_t value = 0;
            while (p < (int)body.length() && isdigit((unsigned char)body.charAt(p))) {
                value = value * 10 + (uint32_t)(body.charAt(p++) - '0');
            }
            if (value > 0) intervalMs = (uint16_t)(value > 65535UL ? 65535UL : value);
        }
    } else {
        keyPos = body.indexOf("\"fps\"");
        if (keyPos >= 0) {
            int colon = body.indexOf(':', keyPos);
            if (colon >= 0) {
                int p = colon + 1;
                while (p < (int)body.length() && isspace((unsigned char)body.charAt(p))) ++p;
                int q = p;
                while (q < (int)body.length()) {
                    const char c = body.charAt(q);
                    if (!(isdigit((unsigned char)c) || c == '.')) break;
                    ++q;
                }
                const float fps = body.substring(p, q).toFloat();
                if (fps > 0.0f) intervalMs = (uint16_t)roundf(1000.0f / fps);
            }
        }
    }

    // --- Parse start flag ---
    bool shouldStart = true;
    keyPos = body.indexOf("\"start\"");
    if (keyPos >= 0) {
        int colon = body.indexOf(':', keyPos);
        if (colon >= 0) {
            int p = colon + 1;
            while (p < (int)body.length() && isspace((unsigned char)body.charAt(p))) ++p;
            if (body.substring(p, p + 5) == "false") shouldStart = false;
        }
    }

    // --- Parse frames array ---
    const int framesKey = body.indexOf("\"frames\"");
    if (framesKey < 0) { sendError(400, "frames must be an array"); return; }
    int pos = body.indexOf('[', framesKey);
    if (pos < 0)       { sendError(400, "frames must be an array"); return; }
    ++pos;

    stopFirmwareScroll(false);
    lockScroll();
    state.scrollFrameCount = 0;
    state.scrollFrameIndex = 0;
    unlockScroll();

    uint16_t count = 0;
    String   error;
    while (pos < (int)body.length()) {
        while (pos < (int)body.length()) {
            const char c = body.charAt(pos);
            if (c == ' ' || c == '\r' || c == '\n' || c == '\t' || c == ',') { ++pos; continue; }
            break;
        }
        if (pos >= (int)body.length()) { sendError(400, "unterminated frames array"); return; }
        if (body.charAt(pos) == ']') break;
        if (body.charAt(pos) != '"') {
            sendError(400, String("expected M370 string at frame ") + count); return;
        }
        const int endQuote = body.indexOf('"', pos + 1);
        if (endQuote < 0) {
            sendError(400, String("unterminated M370 string at frame ") + count); return;
        }
        if (count >= MAX_SCROLL_FRAMES) {
            sendError(413, String("too many scroll frames; firmware cache max is ") + MAX_SCROLL_FRAMES);
            return;
        }
        const String m370 = body.substring(pos + 1, endQuote);
        if (!m370ToPackedBits(m370, scrollFrameBits[count], error)) {
            sendError(400, String("invalid scroll frame ") + count + ": " + error);
            lockScroll(); state.scrollFrameCount = 0; unlockScroll();
            return;
        }
        ++count;
        pos = endQuote + 1;
    }

    if (count == 0) {
        sendError(400, "frames must include at least one valid M370 frame"); return;
    }

    lockScroll();
    state.scrollFrameCount = count;
    state.scrollFrameIndex = 0;
    state.scrollIntervalMs = constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
    unlockScroll();

    if (shouldStart) startFirmwareScroll(intervalMs);

    DynamicJsonDocument reply(768);
    reply["ok"]                   = true;
    reply["frames"]               = state.scrollFrameCount;
    reply["started"]              = state.firmwareScrollActive;
    reply["mode"]                 = state.mode;
    reply["playback"]             = state.playback;
    reply["restoreAutoAfterScroll"] = state.restoreAutoAfterScroll;
    reply["scrollIntervalMs"]     = state.scrollIntervalMs;
    reply["scrollMaxFrames"]      = MAX_SCROLL_FRAMES;
    reply["stepLedPerFrame"]      = 1;
    sendJsonDocument(200, reply);
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

    state.lastCommand = cmd;

    if (cmd == "set_color") {
        const char* hex = payload["hex"] | "";
        if (strlen(hex) == 0) hex = doc["hex"] | "";
        if (!setColor(hex, error)) {
            ++state.commandsRejected; sendError(400, error); return;
        }
    } else if (cmd == "set_brightness") {
        int raw = state.brightness;
        if      (payload["raw"].is<int>())        raw = payload["raw"].as<int>();
        else if (payload["brightness"].is<int>()) raw = payload["brightness"].as<int>();
        else if (doc["raw"].is<int>())            raw = doc["raw"].as<int>();
        setBrightness(raw);
    } else if (cmd == "set_mode") {
        cancelDeferredFaceRestore();
        const char* mode = payload["mode"] | "";
        if (strlen(mode) == 0) mode = doc["mode"] | "";
        if (strlen(mode) == 0 || !setMode(mode)) {
            ++state.commandsRejected; sendError(400, "invalid mode"); return;
        }
    } else if (cmd == "set_auto_interval") {
        uint32_t ms = state.autoIntervalMs;
        if      (payload["ms"].is<uint32_t>()) ms = payload["ms"].as<uint32_t>();
        else if (doc["ms"].is<uint32_t>())     ms = doc["ms"].as<uint32_t>();
        setAutoInterval(ms);
    } else if (cmd == "set_scroll_interval") {
        uint16_t iMs = state.scrollIntervalMs;
        if (payload["intervalMs"].is<uint16_t>()) {
            iMs = payload["intervalMs"].as<uint16_t>();
        } else if (payload["fps"].is<float>()) {
            const float fps = payload["fps"].as<float>();
            if (fps > 0.0f) iMs = (uint16_t)roundf(1000.0f / fps);
        } else if (doc["intervalMs"].is<uint16_t>()) {
            iMs = doc["intervalMs"].as<uint16_t>();
        }
        lockScroll();
        state.scrollIntervalMs  = constrain(iMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        state.lastScrollFrameMs = millis();
        unlockScroll();
    } else if (cmd == "scroll_step") {
        uint8_t steppedFrame[FRAME_BYTES];
        bool    hasSteppedFrame = false;
        lockScroll();
        if (state.scrollFrameCount > 0) {
            state.scrollFrameIndex = (state.scrollFrameIndex + 1) % state.scrollFrameCount;
            state.playback         = "scroll_step";
            memcpy(steppedFrame, scrollFrameBits[state.scrollFrameIndex], FRAME_BYTES);
            hasSteppedFrame = true;
        }
        unlockScroll();
        if (hasSteppedFrame) applyPackedFrame(steppedFrame, "firmware_text_scroll_step");
    } else if (cmd == "pause_scroll") {
        lockScroll();
        if (state.firmwareScrollActive) {
            state.firmwareScrollPaused = true;
            state.playback             = "scroll_paused";
        }
        unlockScroll();
    } else if (cmd == "resume_scroll") {
        lockScroll();
        if (state.scrollFrameCount > 0) {
            state.firmwareScrollActive  = true;
            state.firmwareScrollPaused  = false;
            state.lastScrollFrameMs     = millis();
            state.playback              = "scroll";
        }
        unlockScroll();
    } else if (cmd == "stop_scroll") {
        bool clearDisplay = true, restoreAuto = true;
        if (payload["clear"].is<bool>())       clearDisplay = payload["clear"].as<bool>();
        else if (doc["clear"].is<bool>())      clearDisplay = doc["clear"].as<bool>();
        if (payload["restoreAuto"].is<bool>()) restoreAuto  = payload["restoreAuto"].as<bool>();
        else if (doc["restoreAuto"].is<bool>()) restoreAuto = doc["restoreAuto"].as<bool>();
        stopFirmwareScroll(restoreAuto, clearDisplay);
    } else if (cmd == "pause") {
        state.paused   = true;
        state.playback = "paused";
    } else if (cmd == "resume") {
        state.paused   = false;
        state.playback = "idle";
    } else if (cmd == "button") {
        const char* button = payload["button"] | "";
        if (strlen(button) == 0) button = doc["button"] | "";
        if (!runButtonAction(String(button), "api_button")) {
            ++state.commandsRejected;
            sendError(400, "unsupported button or no saved faces available");
            return;
        }
    } else if (cmd == "terminate_other_activities") {
        const char* targetMode = payload["targetMode"] | "";
        if (strcmp(targetMode, "scroll") != 0) stopFirmwareScroll(false, false);
        if (strcmp(targetMode, "face") != 0 && strcmp(targetMode, "scroll") != 0) {
            setMode("manual", true);
        } else if (strcmp(targetMode, "scroll") == 0 && isAutoMode()) {
            state.restoreAutoAfterScroll = true;
            state.mode                   = "manual";
        }
    } else if (cmd == "adc_debug_override" || cmd == "raw_aux_command") {
        // Accepted for WebUI compatibility; no-op in this minimal firmware.
    } else {
        Serial.printf("Unknown command accepted: %s\n", cmd.c_str());
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
    if (!LittleFS.exists(SAVED_FACES_PATH)) {
        sendError(404, "saved_faces.json not found; run pio run -t uploadfs"); return;
    }
    File file = LittleFS.open(SAVED_FACES_PATH, "r");
    if (!file) { sendError(500, "failed to open saved_faces.json"); return; }
    addCorsHeaders();
    server.streamFile(file, "application/json; charset=utf-8");
    file.close();
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

    String error;
    if (!validateSavedFaces(document, error)) { sendError(400, error); return; }

    const size_t written = writeSavedFaces(document, error);
    if (written == 0) { sendError(500, error); return; }

    loadSavedFaces(false);

    DynamicJsonDocument reply(384);
    reply["ok"]     = true;
    reply["path"]   = SAVED_FACES_PATH;
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
    lockFrame();
    state.colorHex   = "#ff0000";
    state.colorR     = 0xff;
    state.colorG     = 0x00;
    state.colorB     = 0x00;
    state.brightness = DEFAULT_BRIGHTNESS;
    memset(frameBits, 0, sizeof(frameBits));
    for (uint16_t i = 0; i < 12 && i < LED_COUNT; ++i) setFrameBit(i, true);
    state.lastReason = "littlefs_mount_failed";
    showCurrentFrameNoLock();
    unlockFrame();
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
