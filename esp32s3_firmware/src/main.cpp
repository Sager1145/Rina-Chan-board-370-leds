#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <WebServer.h>
#include <WiFi.h>
#include <cstdlib>
#include <cstring>

namespace {

constexpr char AP_SSID[] = "RinaChanBoard-ESP32S3";
constexpr char AP_PASSWORD[] = "rinachan";
const IPAddress AP_IP(192, 168, 1, 14);
const IPAddress AP_GATEWAY(192, 168, 1, 14);
const IPAddress AP_SUBNET(255, 255, 255, 0);

constexpr uint16_t HTTP_PORT = 80;
constexpr uint16_t LED_PIN = 2;
constexpr uint16_t LED_COUNT = 370;
constexpr uint16_t M370_HEX_CHARS = 93;
constexpr uint16_t M370_BITS = 370;
constexpr uint8_t MATRIX_ROWS = 18;
constexpr bool SERPENTINE_WIRING = true;
constexpr bool SERPENTINE_ODD_ROWS_REVERSED = true;
constexpr uint8_t ROW_LENGTHS[MATRIX_ROWS] = {
    18, 20, 20, 20, 22, 22, 22, 22, 22,
    22, 22, 22, 22, 20, 20, 20, 18, 16
};
constexpr uint16_t ROW_OFFSETS[MATRIX_ROWS] = {
    0, 18, 38, 58, 78, 100, 122, 144, 166,
    188, 210, 232, 254, 276, 296, 316, 336, 354
};
static_assert(ROW_OFFSETS[MATRIX_ROWS - 1] + ROW_LENGTHS[MATRIX_ROWS - 1] == LED_COUNT,
              "matrix row layout must cover exactly LED_COUNT logical cells");
constexpr uint8_t DEFAULT_BRIGHTNESS = 50;
constexpr uint8_t MIN_BRIGHTNESS = 10;
constexpr uint8_t MAX_BRIGHTNESS = 200;
constexpr char DEFAULT_COLOR[] = "#f971d4";
constexpr char DEFAULT_MODE[] = "manual";
constexpr char DEFAULT_PLAYBACK[] = "idle";
constexpr char STARTUP_FACE_REASON[] = "startup_sequence_complete_saved_face";
constexpr char LITTLEFS_BASE_PATH[] = "/littlefs";
constexpr char LITTLEFS_PARTITION_LABEL[] = "littlefs";
constexpr char SAVED_FACES_PATH[] = "/resources/saved_faces.json";

WebServer server(HTTP_PORT);
Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);
bool fsMounted = false;

struct RuntimeState {
    String colorHex = DEFAULT_COLOR;
    uint8_t colorR = 0xf9;
    uint8_t colorG = 0x71;
    uint8_t colorB = 0xd4;
    uint8_t brightness = DEFAULT_BRIGHTNESS;
    String mode = DEFAULT_MODE;
    String playback = DEFAULT_PLAYBACK;
    String lastM370;
    String lastReason = "boot";
    String lastCommand;
    String lastButton;
    bool paused = false;
    uint32_t framesAccepted = 0;
    uint32_t framesRejected = 0;
    uint32_t commandsAccepted = 0;
    uint32_t commandsRejected = 0;
    uint32_t savedFacesWrites = 0;
    uint32_t bootMs = 0;
};

RuntimeState state;
uint8_t frameBits[(LED_COUNT + 7) / 8] = {};

size_t jsonCapacityFor(size_t sourceBytes) {
    const size_t estimated = sourceBytes * 2 + 4096;
    return estimated < 32768 ? 32768 : estimated;
}

int hexNibble(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    return -1;
}

void setFrameBit(uint16_t index, bool on) {
    const uint16_t byteIndex = index >> 3;
    const uint8_t bitMask = 1U << (index & 7U);
    if (on) {
        frameBits[byteIndex] |= bitMask;
    } else {
        frameBits[byteIndex] &= ~bitMask;
    }
}

bool frameBit(uint16_t index) {
    return (frameBits[index >> 3] & (1U << (index & 7U))) != 0;
}

uint16_t logicalToPhysicalLedIndex(uint16_t logicalIndex) {
    if (!SERPENTINE_WIRING || logicalIndex >= LED_COUNT) {
        return logicalIndex;
    }

    for (uint8_t row = 0; row < MATRIX_ROWS; ++row) {
        const uint16_t rowStart = ROW_OFFSETS[row];
        const uint8_t rowLength = ROW_LENGTHS[row];
        if (logicalIndex < rowStart || logicalIndex >= rowStart + rowLength) {
            continue;
        }

        const uint16_t localX = logicalIndex - rowStart;
        const bool reverseRow = SERPENTINE_ODD_ROWS_REVERSED && ((row & 1U) != 0);
        return reverseRow ? rowStart + (rowLength - 1U - localX) : logicalIndex;
    }

    return logicalIndex;
}

void showCurrentFrame() {
    strip.setBrightness(state.brightness);
    const uint32_t rgb = strip.Color(state.colorR, state.colorG, state.colorB);
    for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
        strip.setPixelColor(logicalToPhysicalLedIndex(logical), frameBit(logical) ? rgb : 0);
    }
    strip.show();
}

String contentTypeFor(const String& path) {
    if (path.endsWith(".html")) {
        return "text/html; charset=utf-8";
    }
    if (path.endsWith(".css")) {
        return "text/css; charset=utf-8";
    }
    if (path.endsWith(".js")) {
        return "application/javascript; charset=utf-8";
    }
    if (path.endsWith(".json")) {
        return "application/json; charset=utf-8";
    }
    if (path.endsWith(".svg")) {
        return "image/svg+xml";
    }
    if (path.endsWith(".png")) {
        return "image/png";
    }
    if (path.endsWith(".jpg") || path.endsWith(".jpeg")) {
        return "image/jpeg";
    }
    if (path.endsWith(".ico")) {
        return "image/x-icon";
    }
    if (path.endsWith(".ttf")) {
        return "font/ttf";
    }
    if (path.endsWith(".woff2")) {
        return "font/woff2";
    }
    return "application/octet-stream";
}

void addCorsHeaders() {
    server.sendHeader("Access-Control-Allow-Origin", "*");
    server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
    server.sendHeader("Cache-Control", "no-store");
}

void sendJsonDocument(int status, JsonDocument& doc) {
    String out;
    serializeJson(doc, out);
    addCorsHeaders();
    server.send(status, "application/json; charset=utf-8", out);
}

void sendError(int status, const String& message) {
    DynamicJsonDocument doc(512);
    doc["ok"] = false;
    doc["error"] = message;
    addCorsHeaders();
    String out;
    serializeJson(doc, out);
    server.send(status, "application/json; charset=utf-8", out);
}

String requestBody() {
    if (server.hasArg("plain")) {
        return server.arg("plain");
    }
    return "";
}

bool normalizeM370(const String& input, String& normalized, String& error) {
    String compact;
    compact.reserve(M370_HEX_CHARS);

    String payload = input;
    payload.trim();
    if (payload.length() >= 5 && payload.substring(0, 5).equalsIgnoreCase("M370:")) {
        payload = payload.substring(5);
    }

    for (size_t i = 0; i < payload.length(); ++i) {
        const char c = payload.charAt(i);
        if (c == ' ' || c == '\r' || c == '\n' || c == '\t') {
            continue;
        }
        if (hexNibble(c) < 0) {
            error = "M370 contains a non-hex character";
            return false;
        }
        compact += c;
    }

    if (compact.length() != M370_HEX_CHARS) {
        error = "M370 must be 93 hex chars, optionally prefixed with M370:";
        return false;
    }

    compact.toUpperCase();
    normalized = "M370:" + compact;
    return true;
}

bool applyM370(const String& input, const String& reason, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) {
        ++state.framesRejected;
        return false;
    }

    const String payload = normalized.substring(5);
    for (uint16_t bit = 0; bit < M370_BITS; ++bit) {
        const int nibble = hexNibble(payload.charAt(bit / 4));
        const bool on = (nibble & (1 << (3 - (bit % 4)))) != 0;
        setFrameBit(bit, on);
    }

    state.lastM370 = normalized;
    state.lastReason = reason;
    ++state.framesAccepted;
    showCurrentFrame();
    return true;
}

bool setColor(const String& input, String& error) {
    String value = input;
    value.trim();
    if (value.startsWith("#")) {
        value = value.substring(1);
    }
    if (value.length() != 6) {
        error = "color must be #RRGGBB or RRGGBB";
        return false;
    }
    for (size_t i = 0; i < value.length(); ++i) {
        if (hexNibble(value.charAt(i)) < 0) {
            error = "color contains a non-hex character";
            return false;
        }
    }

    value.toLowerCase();
    state.colorHex = "#" + value;
    state.colorR = strtoul(value.substring(0, 2).c_str(), nullptr, 16);
    state.colorG = strtoul(value.substring(2, 4).c_str(), nullptr, 16);
    state.colorB = strtoul(value.substring(4, 6).c_str(), nullptr, 16);
    showCurrentFrame();
    return true;
}

void setBrightness(int raw) {
    raw = constrain(raw, MIN_BRIGHTNESS, MAX_BRIGHTNESS);
    state.brightness = static_cast<uint8_t>(raw);
    showCurrentFrame();
}

bool serveStaticFile(String path) {
    if (!fsMounted) {
        return false;
    }
    if (path == "/") {
        path = "/index.html";
    }
    if (path.endsWith("/")) {
        path += "index.html";
    }
    if (!LittleFS.exists(path)) {
        return false;
    }

    File file = LittleFS.open(path, "r");
    if (!file) {
        return false;
    }

    addCorsHeaders();
    server.streamFile(file, contentTypeFor(path));
    file.close();
    return true;
}

void showFilesystemErrorPattern() {
    state.colorHex = "#ff0000";
    state.colorR = 0xff;
    state.colorG = 0x00;
    state.colorB = 0x00;
    state.brightness = DEFAULT_BRIGHTNESS;
    memset(frameBits, 0, sizeof(frameBits));
    for (uint16_t i = 0; i < 12 && i < LED_COUNT; ++i) {
        setFrameBit(i, true);
    }
    state.lastReason = "littlefs_mount_failed";
    showCurrentFrame();
}

void sendFilesystemErrorPage() {
    addCorsHeaders();
    server.send(
        503,
        "text/html; charset=utf-8",
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
        "</main></body></html>");
}

uint16_t countLitLeds() {
    uint16_t lit = 0;
    for (uint16_t i = 0; i < LED_COUNT; ++i) {
        if (frameBit(i)) {
            ++lit;
        }
    }
    return lit;
}

void handleOptions() {
    addCorsHeaders();
    server.send(204, "text/plain", "");
}

void handleApiStatus() {
    DynamicJsonDocument doc(2048);
    doc["ok"] = true;
    doc["device"] = "RinaChanBoard";
    doc["uptimeMs"] = millis() - state.bootMs;

    JsonObject ap = doc.createNestedObject("ap");
    ap["ssid"] = AP_SSID;
    ap["ip"] = WiFi.softAPIP().toString();
    ap["clients"] = WiFi.softAPgetStationNum();

    JsonObject matrix = doc.createNestedObject("matrix");
    matrix["leds"] = LED_COUNT;
    matrix["m370HexChars"] = M370_HEX_CHARS;
    matrix["gpio"] = LED_PIN;
    matrix["m370BitOrder"] = "logical_row_major";
    matrix["physicalWiring"] = SERPENTINE_WIRING ? "serpentine" : "linear";
    matrix["serpentineOddRowsReversed"] = SERPENTINE_ODD_ROWS_REVERSED;

    JsonObject renderer = doc.createNestedObject("renderer");
    renderer["color"] = state.colorHex;
    renderer["brightness"] = state.brightness;
    renderer["brightnessMin"] = MIN_BRIGHTNESS;
    renderer["brightnessMax"] = MAX_BRIGHTNESS;
    renderer["mode"] = state.mode;
    renderer["playback"] = state.playback;
    renderer["paused"] = state.paused;
    renderer["lit"] = countLitLeds();
    renderer["lastReason"] = state.lastReason;

    JsonObject endpoints = doc.createNestedObject("endpoints");
    endpoints["frame"] = "/api/frame";
    endpoints["command"] = "/api/command";
    endpoints["savedFaces"] = "/api/saved_faces";
    endpoints["status"] = "/api/status";

    JsonObject storage = doc.createNestedObject("storage");
    storage["mounted"] = fsMounted;
    storage["savedFacesPath"] = SAVED_FACES_PATH;
    storage["savedFacesExists"] = fsMounted && LittleFS.exists(SAVED_FACES_PATH);
    if (fsMounted) {
        storage["totalBytes"] = static_cast<uint32_t>(LittleFS.totalBytes());
        storage["usedBytes"] = static_cast<uint32_t>(LittleFS.usedBytes());
    }

    JsonObject stats = doc.createNestedObject("stats");
    stats["framesAccepted"] = state.framesAccepted;
    stats["framesRejected"] = state.framesRejected;
    stats["commandsAccepted"] = state.commandsAccepted;
    stats["commandsRejected"] = state.commandsRejected;
    stats["savedFacesWrites"] = state.savedFacesWrites;

    sendJsonDocument(200, doc);
}

bool parseJsonBody(DynamicJsonDocument& doc, String& error) {
    const String body = requestBody();
    if (body.isEmpty()) {
        error = "empty JSON body";
        return false;
    }

    DeserializationError err = deserializeJson(doc, body);
    if (err) {
        error = String("invalid JSON: ") + err.c_str();
        return false;
    }
    return true;
}

void handleApiFrame() {
    String error;
    DynamicJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) {
        sendError(400, error);
        return;
    }

    const char* m370 = doc["m370"] | "";
    if (strlen(m370) == 0) {
        ++state.framesRejected;
        sendError(400, "missing m370");
        return;
    }

    const char* mode = doc["mode"] | "";
    if (strlen(mode) == 0) {
        mode = doc["playback"] | "idle";
    }
    state.playback = mode;
    const String reason = doc["reason"] | "api_frame";
    if (!applyM370(m370, reason, error)) {
        sendError(400, error);
        return;
    }

    DynamicJsonDocument reply(640);
    reply["ok"] = true;
    reply["accepted"] = true;
    reply["leds"] = LED_COUNT;
    reply["color"] = state.colorHex;
    reply["brightness"] = state.brightness;
    reply["reason"] = state.lastReason;
    reply["lit"] = countLitLeds();
    sendJsonDocument(200, reply);
}

void handleApiCommand() {
    String error;
    DynamicJsonDocument doc(2048);
    if (!parseJsonBody(doc, error)) {
        ++state.commandsRejected;
        sendError(400, error);
        return;
    }

    const String cmd = doc["cmd"] | "";
    JsonVariant payload = doc["payload"];
    if (cmd.isEmpty()) {
        ++state.commandsRejected;
        sendError(400, "missing cmd");
        return;
    }

    state.lastCommand = cmd;
    if (cmd == "set_color") {
        const char* hex = payload["hex"] | "";
        if (strlen(hex) == 0) {
            hex = doc["hex"] | "";
        }
        if (!setColor(hex, error)) {
            ++state.commandsRejected;
            sendError(400, error);
            return;
        }
    } else if (cmd == "set_brightness") {
        int raw = state.brightness;
        if (payload["raw"].is<int>()) {
            raw = payload["raw"].as<int>();
        } else if (payload["brightness"].is<int>()) {
            raw = payload["brightness"].as<int>();
        } else if (doc["raw"].is<int>()) {
            raw = doc["raw"].as<int>();
        }
        setBrightness(raw);
    } else if (cmd == "set_mode") {
        const char* mode = payload["mode"] | "";
        if (strlen(mode) == 0) {
            mode = doc["mode"] | "";
        }
        if (strlen(mode) > 0) {
            state.mode = String(mode);
        }
    } else if (cmd == "pause") {
        state.paused = true;
        state.playback = "paused";
    } else if (cmd == "resume") {
        state.paused = false;
        state.playback = "idle";
    } else if (cmd == "button") {
        state.lastButton = String(payload["button"] | "");
    } else if (cmd == "set_auto_interval" || cmd == "terminate_other_activities" ||
               cmd == "adc_debug_override" || cmd == "raw_aux_command") {
        // Accepted for WebUI compatibility; this minimal firmware stores only the last command.
    } else {
        // Keep unknown commands non-fatal so the debug page can experiment.
        Serial.printf("Unknown command accepted: %s\n", cmd.c_str());
    }

    ++state.commandsAccepted;

    DynamicJsonDocument reply(640);
    reply["ok"] = true;
    reply["cmd"] = cmd;
    reply["color"] = state.colorHex;
    reply["brightness"] = state.brightness;
    reply["mode"] = state.mode;
    reply["playback"] = state.playback;
    reply["paused"] = state.paused;
    sendJsonDocument(200, reply);
}

bool validateSavedFaces(JsonVariant document, String& error) {
    const char* category = document["category"] | "";
    if (strcmp(category, "unified_saved_faces") != 0) {
        error = "document.category must be unified_saved_faces";
        return false;
    }

    JsonArray faces = document["faces"].as<JsonArray>();
    if (faces.isNull()) {
        error = "document.faces must be an array";
        return false;
    }

    uint16_t defaultCount = 0;
    for (JsonObject face : faces) {
        const char* type = face["type"] | "";
        const char* m370 = face["m370"] | "";
        if (strcmp(type, "default") == 0) {
            ++defaultCount;
        }
        if (strlen(m370) > 0) {
            String normalized;
            if (!normalizeM370(m370, normalized, error)) {
                error = String("invalid face m370: ") + error;
                return false;
            }
        }
    }

    if (defaultCount == 0) {
        error = "saved_faces.json must keep at least one type:\"default\" face";
        return false;
    }
    return true;
}

void handleSavedFacesGet() {
    if (!fsMounted) {
        sendError(503, "LittleFS is not mounted; run pio run -t uploadfs");
        return;
    }
    if (!LittleFS.exists(SAVED_FACES_PATH)) {
        sendError(404, "saved_faces.json not found; run pio run -t uploadfs");
        return;
    }

    File file = LittleFS.open(SAVED_FACES_PATH, "r");
    if (!file) {
        sendError(500, "failed to open saved_faces.json");
        return;
    }
    addCorsHeaders();
    server.streamFile(file, "application/json; charset=utf-8");
    file.close();
}

void handleSavedFacesPost() {
    if (!fsMounted) {
        sendError(503, "LittleFS is not mounted; cannot write saved_faces.json");
        return;
    }

    const String body = requestBody();
    if (body.isEmpty()) {
        sendError(400, "empty JSON body");
        return;
    }

    const size_t capacity = jsonCapacityFor(body.length());
    DynamicJsonDocument doc(capacity);
    DeserializationError err = deserializeJson(doc, body, DeserializationOption::NestingLimit(32));
    if (err) {
        sendError(400, String("invalid JSON: ") + err.c_str());
        return;
    }

    JsonVariant document = doc["document"];
    if (document.isNull()) {
        document = doc.as<JsonVariant>();
    }

    String error;
    if (!validateSavedFaces(document, error)) {
        sendError(400, error);
        return;
    }

    if (!LittleFS.exists("/resources")) {
        LittleFS.mkdir("/resources");
    }

    File file = LittleFS.open(SAVED_FACES_PATH, "w");
    if (!file) {
        sendError(500, "failed to write saved_faces.json");
        return;
    }
    serializeJson(document, file);
    file.close();
    ++state.savedFacesWrites;

    DynamicJsonDocument reply(384);
    reply["ok"] = true;
    reply["path"] = SAVED_FACES_PATH;
    File saved = LittleFS.open(SAVED_FACES_PATH, "r");
    reply["bytes"] = saved ? saved.size() : 0;
    if (saved) {
        saved.close();
    }
    reply["writes"] = state.savedFacesWrites;
    sendJsonDocument(200, reply);
}

void handleApiSavedFaces() {
    if (server.method() == HTTP_GET) {
        handleSavedFacesGet();
    } else if (server.method() == HTTP_POST) {
        handleSavedFacesPost();
    } else if (server.method() == HTTP_OPTIONS) {
        handleOptions();
    } else {
        sendError(405, "method not allowed");
    }
}

void handleNotFound() {
    if (server.method() == HTTP_GET && serveStaticFile(server.uri())) {
        return;
    }
    if (server.method() == HTTP_GET && !fsMounted) {
        sendFilesystemErrorPage();
        return;
    }
    sendError(404, "not found: " + server.uri());
}

bool loadStartupFace() {
    if (!fsMounted) {
        Serial.println("LittleFS not mounted; startup face cannot be loaded");
        return false;
    }
    if (!LittleFS.exists(SAVED_FACES_PATH)) {
        Serial.println("No saved_faces.json; LED output starts blank");
        return false;
    }

    File file = LittleFS.open(SAVED_FACES_PATH, "r");
    if (!file) {
        Serial.println("Failed to open saved_faces.json");
        return false;
    }

    DynamicJsonDocument doc(jsonCapacityFor(file.size()));
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(32));
    file.close();
    if (err) {
        Serial.printf("saved_faces.json parse failed: %s\n", err.c_str());
        return false;
    }

    const String startupId = doc["startupDefaultId"] | "";
    JsonArray faces = doc["faces"].as<JsonArray>();
    JsonObject selected;
    JsonObject firstDefault;
    JsonObject firstFace;

    for (JsonObject face : faces) {
        if (firstFace.isNull()) {
            firstFace = face;
        }
        const char* type = face["type"] | "";
        if (strcmp(type, "default") == 0 && firstDefault.isNull()) {
            firstDefault = face;
        }
        const char* id = face["id"] | "";
        if ((!startupId.isEmpty() && startupId == id) || face["is_startup_default"].as<bool>()) {
            selected = face;
            break;
        }
    }

    if (selected.isNull()) {
        if (!firstDefault.isNull()) {
            selected = firstDefault;
        } else {
            selected = firstFace;
        }
    }
    if (selected.isNull()) {
        Serial.println("saved_faces.json has no faces");
        return false;
    }

    String error;
    const char* m370 = selected["m370"] | "";
    state.brightness = DEFAULT_BRIGHTNESS;
    state.mode = DEFAULT_MODE;
    state.playback = DEFAULT_PLAYBACK;
    state.paused = false;
    if (!applyM370(m370, STARTUP_FACE_REASON, error)) {
        Serial.printf("startup M370 failed: %s\n", error.c_str());
        return false;
    }

    Serial.printf("Loaded startup face: %s\n", (const char*)(selected["id"] | ""));
    return true;
}

void startAccessPoint() {
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(AP_IP, AP_GATEWAY, AP_SUBNET);
    WiFi.softAP(AP_SSID, AP_PASSWORD);

    Serial.printf("AP started: ssid=%s password=%s ip=%s\n",
                  AP_SSID,
                  AP_PASSWORD,
                  WiFi.softAPIP().toString().c_str());
}

void startWebServer() {
    server.on("/", HTTP_GET, []() {
        if (!serveStaticFile("/")) {
            if (!fsMounted) {
                sendFilesystemErrorPage();
            } else {
                sendError(404, "index.html not found; run pio run -t uploadfs");
            }
        }
    });
    server.on("/index.html", HTTP_GET, []() {
        if (!serveStaticFile("/index.html")) {
            if (!fsMounted) {
                sendFilesystemErrorPage();
            } else {
                sendError(404, "index.html not found; run pio run -t uploadfs");
            }
        }
    });
    server.on("/api/status", HTTP_GET, handleApiStatus);
    server.on("/api/status", HTTP_OPTIONS, handleOptions);
    server.on("/api/frame", HTTP_POST, handleApiFrame);
    server.on("/api/frame", HTTP_OPTIONS, handleOptions);
    server.on("/api/command", HTTP_POST, handleApiCommand);
    server.on("/api/command", HTTP_OPTIONS, handleOptions);
    server.on("/api/saved_faces", handleApiSavedFaces);
    server.onNotFound(handleNotFound);
    server.begin();
    Serial.printf("HTTP server listening on http://%s/\n", WiFi.softAPIP().toString().c_str());
}

}  // namespace

void setup() {
    Serial.begin(115200);
    delay(200);
    state.bootMs = millis();

    strip.begin();
    state.brightness = DEFAULT_BRIGHTNESS;
    state.mode = DEFAULT_MODE;
    state.playback = DEFAULT_PLAYBACK;
    state.paused = false;
    strip.setBrightness(state.brightness);
    strip.clear();
    strip.show();

    String colorError;
    setColor(DEFAULT_COLOR, colorError);

    fsMounted = LittleFS.begin(false, LITTLEFS_BASE_PATH, 10, LITTLEFS_PARTITION_LABEL);
    if (!fsMounted) {
        Serial.println("LittleFS mount failed. Upload data with: pio run -t uploadfs");
        showFilesystemErrorPattern();
    } else {
        loadStartupFace();
    }

    startAccessPoint();
    startWebServer();
}

void loop() {
    server.handleClient();
    delay(2);
}
