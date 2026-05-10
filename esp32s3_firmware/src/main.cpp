#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <WebServer.h>
#include <WiFi.h>
#include <cstdlib>
#include <cstring>

namespace {

constexpr char AP_SSID[] = "RinaChanBoard-V2";
constexpr char AP_PASSWORD[] = "rinachan";
const IPAddress AP_IP(192, 168, 1, 14);
const IPAddress AP_GATEWAY(192, 168, 1, 14);
const IPAddress AP_SUBNET(255, 255, 255, 0);

constexpr uint16_t HTTP_PORT = 80;
constexpr uint16_t LED_PIN = 2;
constexpr uint16_t LED_COUNT = 370;
constexpr uint8_t BUTTON_B1_PIN = 17;
constexpr uint8_t BUTTON_B2_PIN = 16;
constexpr uint8_t BUTTON_B3_PIN = 15;
constexpr uint8_t BUTTON_B4_PIN = 40;
constexpr uint8_t BUTTON_B5_PIN = 41;
constexpr uint8_t BUTTON_B6_PIN = 42;
constexpr uint16_t M370_HEX_CHARS = 93;
constexpr uint16_t M370_BITS = 370;
constexpr uint16_t FRAME_BYTES = (LED_COUNT + 7) / 8;
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
constexpr uint32_t DEFAULT_AUTO_INTERVAL_MS = 3000;
constexpr uint32_t MIN_AUTO_INTERVAL_MS = 500;
constexpr uint32_t MAX_AUTO_INTERVAL_MS = 10000;
constexpr uint32_t AUTO_INTERVAL_BUTTON_STEP_MS = 500;
constexpr int8_t BRIGHTNESS_BUTTON_STEP = 8;
constexpr uint32_t BUTTON_DEBOUNCE_MS = 25;
constexpr uint32_t FACE_REPEAT_DELAY_MS = 650;
constexpr uint32_t FACE_REPEAT_MS = 350;
constexpr uint32_t BRIGHTNESS_REPEAT_DELAY_MS = 450;
constexpr uint32_t BRIGHTNESS_REPEAT_MS = 120;
constexpr uint16_t MAX_AUTO_FACES = 128;
constexpr uint16_t MAX_SCROLL_FRAMES = 512;
constexpr uint16_t DEFAULT_SCROLL_INTERVAL_MS = 33;
constexpr char DEFAULT_COLOR[] = "#f971d4";
constexpr char DEFAULT_MODE[] = "manual";
constexpr char DEFAULT_PLAYBACK[] = "idle";
constexpr char STARTUP_FACE_REASON[] = "startup_sequence_complete_saved_face";
constexpr char LITTLEFS_BASE_PATH[] = "/littlefs";
constexpr char LITTLEFS_PARTITION_LABEL[] = "littlefs";
constexpr char SAVED_FACES_PATH[] = "/resources/saved_faces.json";
constexpr char SETTINGS_PATH[] = "/resources/runtime_settings.json";

WebServer server(HTTP_PORT);
Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);
bool fsMounted = false;

struct RuntimeState {
    String colorHex = DEFAULT_COLOR;
    uint8_t colorR = 0xf9;
    uint8_t colorG = 0x71;
    uint8_t colorB = 0xd4;
    uint8_t brightness = DEFAULT_BRIGHTNESS;
    uint8_t defaultBrightness = DEFAULT_BRIGHTNESS;
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
    uint32_t settingsWrites = 0;
    uint32_t bootMs = 0;
    uint32_t autoIntervalMs = DEFAULT_AUTO_INTERVAL_MS;
    uint32_t lastAutoSwitchMs = 0;
    uint16_t autoFaceIndex = 0;
    bool firmwareScrollActive = false;
    bool firmwareScrollPaused = false;
    bool restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount = 0;
    uint16_t scrollFrameIndex = 0;
    uint16_t scrollIntervalMs = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t lastScrollFrameMs = 0;
};

RuntimeState state;
uint8_t frameBits[FRAME_BYTES] = {};
uint8_t scrollFrameBits[MAX_SCROLL_FRAMES][FRAME_BYTES] = {};

struct RuntimeFace {
    String id;
    String name;
    String m370;
    int32_t order = 0;
    uint16_t jsonIndex = 0;
    bool isDefault = false;
    bool isStartupDefault = false;
};

RuntimeFace autoFaces[MAX_AUTO_FACES];
uint16_t autoFaceCount = 0;

struct ButtonRuntime {
    const char* code;
    uint8_t pin;
    bool rawPressed = false;
    bool pressed = false;
    bool comboConsumed = false;
    uint32_t lastRawChangeMs = 0;
    uint32_t pressedAtMs = 0;
    uint32_t lastRepeatMs = 0;

    ButtonRuntime(const char* buttonCode, uint8_t gpioPin) : code(buttonCode), pin(gpioPin) {}
};

ButtonRuntime buttons[] = {
    {"B1", BUTTON_B1_PIN},
    {"B2", BUTTON_B2_PIN},
    {"B3", BUTTON_B3_PIN},
    {"B4", BUTTON_B4_PIN},
    {"B5", BUTTON_B5_PIN},
    {"B6", BUTTON_B6_PIN},
};
constexpr uint8_t BUTTON_COUNT = sizeof(buttons) / sizeof(buttons[0]);

bool loadSavedFaces(bool applyStartupFace);
bool loadRuntimeSettings();
bool saveRuntimeSettings();
bool runButtonAction(const String& button, const String& source);
void stopFirmwareScroll(bool restoreAuto);

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

bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) {
        return false;
    }

    memset(outBits, 0, FRAME_BYTES);
    const String payload = normalized.substring(5);
    for (uint16_t bit = 0; bit < M370_BITS; ++bit) {
        const int nibble = hexNibble(payload.charAt(bit / 4));
        const bool on = (nibble & (1 << (3 - (bit % 4)))) != 0;
        if (on) {
            outBits[bit >> 3] |= 1U << (bit & 7U);
        }
    }
    return true;
}

void applyPackedFrame(const uint8_t* packedBits, const String& reason) {
    memcpy(frameBits, packedBits, FRAME_BYTES);
    state.lastReason = reason;
    ++state.framesAccepted;
    showCurrentFrame();
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

bool isAutoMode() {
    return state.mode == "auto";
}

String normalizedMode(const char* input) {
    String mode = input ? String(input) : String();
    mode.trim();
    if (mode == "自动" || mode == "A") {
        return "auto";
    }
    if (mode == "手动" || mode == "M") {
        return "manual";
    }
    mode.toLowerCase();
    if (mode == "auto" || mode == "a") {
        return "auto";
    }
    if (mode == "manual" || mode == "m") {
        return "manual";
    }
    return mode;
}

bool setMode(const char* input, bool persistSettings = true) {
    const String mode = normalizedMode(input);
    if (mode == "auto") {
        state.mode = "auto";
        state.playback = "auto_saved_face";
        state.paused = false;
        state.lastAutoSwitchMs = millis();
    } else if (mode == "manual") {
        state.mode = "manual";
        if (persistSettings) {
            state.restoreAutoAfterScroll = false;
        }
        if (state.playback == "auto_saved_face") {
            state.playback = DEFAULT_PLAYBACK;
        }
    } else {
        return false;
    }
    if (persistSettings) {
        saveRuntimeSettings();
    }
    return true;
}

void setAutoInterval(uint32_t ms, bool persistSettings = true) {
    state.autoIntervalMs = constrain(ms, MIN_AUTO_INTERVAL_MS, MAX_AUTO_INTERVAL_MS);
    if (persistSettings) {
        saveRuntimeSettings();
    }
}

bool ensureResourcesDirectory() {
    if (!fsMounted) {
        return false;
    }
    if (LittleFS.exists("/resources")) {
        return true;
    }
    return LittleFS.mkdir("/resources");
}

bool saveRuntimeSettings() {
    if (!fsMounted) {
        return false;
    }
    if (!ensureResourcesDirectory()) {
        Serial.println("Failed to ensure /resources for runtime settings");
        return false;
    }

    DynamicJsonDocument doc(384);
    doc["format"] = "rina_runtime_settings_v1";
    doc["version"] = 1;
    doc["mode"] = state.mode;
    doc["autoIntervalMs"] = state.autoIntervalMs;
    doc["updatedAtMs"] = millis();

    File file = LittleFS.open(SETTINGS_PATH, "w");
    if (!file) {
        Serial.println("Failed to open runtime_settings.json for write");
        return false;
    }
    serializeJson(doc, file);
    file.close();
    ++state.settingsWrites;
    return true;
}

bool loadRuntimeSettings() {
    if (!fsMounted) {
        return false;
    }
    if (!LittleFS.exists(SETTINGS_PATH)) {
        Serial.println("runtime_settings.json not found; writing defaults");
        saveRuntimeSettings();
        return false;
    }

    File file = LittleFS.open(SETTINGS_PATH, "r");
    if (!file) {
        Serial.println("Failed to open runtime_settings.json");
        return false;
    }

    DynamicJsonDocument doc(768);
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(8));
    file.close();
    if (err) {
        Serial.printf("runtime_settings.json parse failed: %s\n", err.c_str());
        return false;
    }

    const char* mode = doc["mode"] | DEFAULT_MODE;
    if (!setMode(mode, false)) {
        setMode(DEFAULT_MODE, false);
    }
    if (doc["autoIntervalMs"].is<uint32_t>()) {
        setAutoInterval(doc["autoIntervalMs"].as<uint32_t>(), false);
    } else if (doc["auto_interval_ms"].is<uint32_t>()) {
        setAutoInterval(doc["auto_interval_ms"].as<uint32_t>(), false);
    }
    Serial.printf("Runtime settings loaded: mode=%s autoIntervalMs=%lu\n",
                  state.mode.c_str(),
                  static_cast<unsigned long>(state.autoIntervalMs));
    return true;
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
    DynamicJsonDocument doc(3072);
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
    renderer["defaultBrightness"] = state.defaultBrightness;
    renderer["brightnessMin"] = MIN_BRIGHTNESS;
    renderer["brightnessMax"] = MAX_BRIGHTNESS;
    renderer["mode"] = state.mode;
    renderer["playback"] = state.playback;
    renderer["paused"] = state.paused;
    renderer["autoIntervalMs"] = state.autoIntervalMs;
    renderer["autoFaceCount"] = autoFaceCount;
    renderer["autoFaceIndex"] = state.autoFaceIndex;
    renderer["firmwareScrollActive"] = state.firmwareScrollActive;
    renderer["firmwareScrollPaused"] = state.firmwareScrollPaused;
    renderer["restoreAutoAfterScroll"] = state.restoreAutoAfterScroll;
    renderer["scrollFrameCount"] = state.scrollFrameCount;
    renderer["scrollFrameIndex"] = state.scrollFrameIndex;
    renderer["scrollIntervalMs"] = state.scrollIntervalMs;
    if (autoFaceCount > 0 && state.autoFaceIndex < autoFaceCount) {
        renderer["autoFaceId"] = autoFaces[state.autoFaceIndex].id;
        renderer["autoFaceName"] = autoFaces[state.autoFaceIndex].name;
    }
    renderer["lastM370"] = state.lastM370;
    renderer["lit"] = countLitLeds();
    renderer["lastReason"] = state.lastReason;

    JsonObject endpoints = doc.createNestedObject("endpoints");
    endpoints["frame"] = "/api/frame";
    endpoints["command"] = "/api/command";
    endpoints["scroll"] = "/api/scroll";
    endpoints["savedFaces"] = "/api/saved_faces";
    endpoints["settings"] = "/api/status";
    endpoints["status"] = "/api/status";

    JsonObject storage = doc.createNestedObject("storage");
    storage["mounted"] = fsMounted;
    storage["savedFacesPath"] = SAVED_FACES_PATH;
    storage["savedFacesExists"] = fsMounted && LittleFS.exists(SAVED_FACES_PATH);
    storage["settingsPath"] = SETTINGS_PATH;
    storage["settingsExists"] = fsMounted && LittleFS.exists(SETTINGS_PATH);
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
    stats["settingsWrites"] = state.settingsWrites;

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
    const String reason = doc["reason"] | "api_frame";
    if (strcmp(mode, "scroll") != 0 && strcmp(mode, "scroll_step") != 0) {
        stopFirmwareScroll(false);
    }
    if (reason.startsWith("custom_") || reason.startsWith("parts_")) {
        setMode("manual", true);
    }
    state.playback = mode;
    if (!applyM370(m370, reason, error)) {
        sendError(400, error);
        return;
    }

    DynamicJsonDocument reply(768);
    reply["ok"] = true;
    reply["accepted"] = true;
    reply["leds"] = LED_COUNT;
    reply["color"] = state.colorHex;
    reply["brightness"] = state.brightness;
    reply["reason"] = state.lastReason;
    reply["mode"] = state.mode;
    reply["autoIntervalMs"] = state.autoIntervalMs;
    reply["autoFaceIndex"] = state.autoFaceIndex;
    reply["m370"] = state.lastM370;
    reply["lit"] = countLitLeds();
    sendJsonDocument(200, reply);
}

void stopFirmwareScroll(bool restoreAuto) {
    const bool shouldRestoreAuto = restoreAuto && state.restoreAutoAfterScroll;
    state.firmwareScrollActive = false;
    state.firmwareScrollPaused = false;
    state.restoreAutoAfterScroll = false;
    state.lastScrollFrameMs = 0;
    if (state.playback == "scroll" || state.playback == "scroll_paused") {
        state.playback = DEFAULT_PLAYBACK;
    }
    if (shouldRestoreAuto) {
        setMode("auto", false);
    }
}

void startFirmwareScroll(uint16_t intervalMs) {
    if (state.scrollFrameCount == 0) {
        return;
    }
    state.restoreAutoAfterScroll = isAutoMode();
    if (state.restoreAutoAfterScroll) {
        state.mode = "manual";
    }
    state.scrollIntervalMs = constrain(intervalMs, static_cast<uint16_t>(10), static_cast<uint16_t>(1000));
    state.scrollFrameIndex = 0;
    state.lastScrollFrameMs = millis();
    state.firmwareScrollActive = true;
    state.firmwareScrollPaused = false;
    state.paused = false;
    state.playback = "scroll";
    applyPackedFrame(scrollFrameBits[0], "firmware_text_scroll_start");
}

void handleApiScroll() {
    if (server.method() == HTTP_OPTIONS) {
        handleOptions();
        return;
    }
    if (server.method() != HTTP_POST) {
        sendError(405, "method not allowed");
        return;
    }

    const String body = requestBody();
    if (body.isEmpty()) {
        sendError(400, "empty JSON body");
        return;
    }

    DynamicJsonDocument doc(jsonCapacityFor(body.length()));
    DeserializationError err = deserializeJson(doc, body, DeserializationOption::NestingLimit(16));
    if (err) {
        sendError(400, String("invalid JSON: ") + err.c_str());
        return;
    }

    JsonArray frames = doc["frames"].as<JsonArray>();
    if (frames.isNull()) {
        sendError(400, "frames must be an array");
        return;
    }

    stopFirmwareScroll(false);
    uint16_t count = 0;
    String error;
    for (JsonVariant frame : frames) {
        if (count >= MAX_SCROLL_FRAMES) {
            break;
        }
        const char* m370 = frame | "";
        if (!m370ToPackedBits(String(m370), scrollFrameBits[count], error)) {
            sendError(400, String("invalid scroll frame ") + count + ": " + error);
            state.scrollFrameCount = 0;
            return;
        }
        ++count;
    }

    if (count == 0) {
        sendError(400, "frames must include at least one valid M370 frame");
        return;
    }

    state.scrollFrameCount = count;
    state.scrollFrameIndex = 0;
    const uint16_t intervalMs = doc["intervalMs"].is<uint16_t>()
                                    ? doc["intervalMs"].as<uint16_t>()
                                    : DEFAULT_SCROLL_INTERVAL_MS;
    if (doc["start"] | true) {
        startFirmwareScroll(intervalMs);
    } else {
        state.scrollIntervalMs = constrain(intervalMs, static_cast<uint16_t>(10), static_cast<uint16_t>(1000));
    }

    DynamicJsonDocument reply(768);
    reply["ok"] = true;
    reply["frames"] = state.scrollFrameCount;
    reply["started"] = state.firmwareScrollActive;
    reply["mode"] = state.mode;
    reply["playback"] = state.playback;
    reply["restoreAutoAfterScroll"] = state.restoreAutoAfterScroll;
    reply["scrollIntervalMs"] = state.scrollIntervalMs;
    sendJsonDocument(200, reply);
}

bool ensureSavedFacesLoaded() {
    if (autoFaceCount > 0) {
        return true;
    }
    return loadSavedFaces(false) && autoFaceCount > 0;
}

bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback) {
    if (!ensureSavedFacesLoaded()) {
        Serial.println("No saved faces available for button action");
        return false;
    }

    state.autoFaceIndex = index % autoFaceCount;
    if (playback) {
        state.playback = playback;
    }

    String error;
    if (!applyM370(autoFaces[state.autoFaceIndex].m370, reason, error)) {
        Serial.printf("saved face apply failed: %s\n", error.c_str());
        return false;
    }
    Serial.printf("Applied saved face %u/%u via %s: %s\n",
                  state.autoFaceIndex + 1,
                  autoFaceCount,
                  reason.c_str(),
                  autoFaces[state.autoFaceIndex].id.c_str());
    return true;
}

bool applyRelativeSavedFace(int8_t delta, const String& reason) {
    if (!ensureSavedFacesLoaded()) {
        return false;
    }
    int32_t next = static_cast<int32_t>(state.autoFaceIndex) + delta;
    while (next < 0) {
        next += autoFaceCount;
    }
    next %= autoFaceCount;
    return applySavedFaceIndex(static_cast<uint16_t>(next), reason, DEFAULT_PLAYBACK);
}

bool runButtonAction(const String& button, const String& source) {
    String code = button;
    code.trim();
    code.toUpperCase();
    if (code.isEmpty()) {
        return false;
    }

    state.lastButton = code;
    if (code == "B1") {
        return applyRelativeSavedFace(1, source + "_B1_next_saved_face");
    }
    if (code == "B2") {
        return applyRelativeSavedFace(-1, source + "_B2_prev_saved_face");
    }
    if (code == "B3") {
        return setMode(isAutoMode() ? "manual" : "auto");
    }
    if (code == "B4") {
        setBrightness(static_cast<int>(state.brightness) - BRIGHTNESS_BUTTON_STEP);
        state.lastReason = source + "_B4_brightness_down";
        return true;
    }
    if (code == "B5") {
        setBrightness(static_cast<int>(state.brightness) + BRIGHTNESS_BUTTON_STEP);
        state.lastReason = source + "_B5_brightness_up";
        return true;
    }
    if (code == "B3B1") {
        setAutoInterval(state.autoIntervalMs > AUTO_INTERVAL_BUTTON_STEP_MS
                            ? state.autoIntervalMs - AUTO_INTERVAL_BUTTON_STEP_MS
                            : MIN_AUTO_INTERVAL_MS);
        state.lastReason = source + "_B3B1_auto_interval_down";
        return true;
    }
    if (code == "B3B2") {
        setAutoInterval(state.autoIntervalMs + AUTO_INTERVAL_BUTTON_STEP_MS);
        state.lastReason = source + "_B3B2_auto_interval_up";
        return true;
    }
    if (code == "B6B3") {
        state.playback = "network_info";
        state.lastReason = source + "_B6B3_network_info";
        return true;
    }
    if (code == "B6S" || code == "B6L") {
        // Battery overlay is intentionally left to the future battery monitor path.
        state.lastReason = source + "_" + code + "_battery_unhandled";
        return true;
    }
    return false;
}

ButtonRuntime* buttonByCode(const char* code) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        if (strcmp(buttons[i].code, code) == 0) {
            return &buttons[i];
        }
    }
    return nullptr;
}

bool isHardwareButtonPressed(const char* code) {
    ButtonRuntime* button = buttonByCode(code);
    return button && button->pressed;
}

void markButtonComboConsumed(const char* code) {
    ButtonRuntime* button = buttonByCode(code);
    if (button) {
        button->comboConsumed = true;
    }
}

void fireHardwareButtonAction(const char* code) {
    if (!runButtonAction(String(code), "gpio")) {
        Serial.printf("GPIO button action ignored: %s\n", code);
    }
}

void handleHardwareButtonPress(ButtonRuntime& button, uint32_t now) {
    button.pressedAtMs = now;
    button.lastRepeatMs = now;
    button.comboConsumed = false;

    if ((strcmp(button.code, "B3") == 0 && isHardwareButtonPressed("B6")) ||
        (strcmp(button.code, "B6") == 0 && isHardwareButtonPressed("B3"))) {
        markButtonComboConsumed("B3");
        markButtonComboConsumed("B6");
        fireHardwareButtonAction("B6B3");
        return;
    }

    if (strcmp(button.code, "B1") == 0 && isHardwareButtonPressed("B3")) {
        button.comboConsumed = true;
        markButtonComboConsumed("B3");
        fireHardwareButtonAction("B3B1");
        return;
    }
    if (strcmp(button.code, "B2") == 0 && isHardwareButtonPressed("B3")) {
        button.comboConsumed = true;
        markButtonComboConsumed("B3");
        fireHardwareButtonAction("B3B2");
        return;
    }

    if (strcmp(button.code, "B1") == 0 || strcmp(button.code, "B2") == 0 ||
        strcmp(button.code, "B4") == 0 || strcmp(button.code, "B5") == 0) {
        fireHardwareButtonAction(button.code);
    }
}

void handleHardwareButtonRelease(ButtonRuntime& button) {
    if (strcmp(button.code, "B3") == 0 && !button.comboConsumed) {
        fireHardwareButtonAction("B3");
    }
    button.comboConsumed = false;
}

void serviceHardwareButtonRepeats(uint32_t now) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button = buttons[i];
        if (!button.pressed || button.comboConsumed) {
            continue;
        }

        const bool faceButton = strcmp(button.code, "B1") == 0 || strcmp(button.code, "B2") == 0;
        const bool brightnessButton = strcmp(button.code, "B4") == 0 || strcmp(button.code, "B5") == 0;
        if (!faceButton && !brightnessButton) {
            continue;
        }
        if (faceButton && isHardwareButtonPressed("B3")) {
            continue;
        }

        const uint32_t repeatDelay = faceButton ? FACE_REPEAT_DELAY_MS : BRIGHTNESS_REPEAT_DELAY_MS;
        const uint32_t repeatEvery = faceButton ? FACE_REPEAT_MS : BRIGHTNESS_REPEAT_MS;
        if (now - button.pressedAtMs < repeatDelay || now - button.lastRepeatMs < repeatEvery) {
            continue;
        }

        button.lastRepeatMs = now;
        fireHardwareButtonAction(button.code);
    }
}

void initHardwareButtons() {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        pinMode(buttons[i].pin, INPUT_PULLUP);
        buttons[i].rawPressed = digitalRead(buttons[i].pin) == LOW;
        buttons[i].pressed = buttons[i].rawPressed;
        buttons[i].lastRawChangeMs = millis();
        buttons[i].pressedAtMs = buttons[i].pressed ? buttons[i].lastRawChangeMs : 0;
        buttons[i].lastRepeatMs = buttons[i].pressedAtMs;
        buttons[i].comboConsumed = false;
    }
}

void serviceHardwareButtons() {
    const uint32_t now = millis();
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button = buttons[i];
        const bool rawPressed = digitalRead(button.pin) == LOW;
        if (rawPressed != button.rawPressed) {
            button.rawPressed = rawPressed;
            button.lastRawChangeMs = now;
        }
        if (now - button.lastRawChangeMs < BUTTON_DEBOUNCE_MS || rawPressed == button.pressed) {
            continue;
        }

        button.pressed = rawPressed;
        if (button.pressed) {
            handleHardwareButtonPress(button, now);
        } else {
            handleHardwareButtonRelease(button);
        }
    }
    serviceHardwareButtonRepeats(now);
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
        if (strlen(mode) == 0 || !setMode(mode)) {
            ++state.commandsRejected;
            sendError(400, "invalid mode");
            return;
        }
    } else if (cmd == "set_auto_interval") {
        uint32_t ms = state.autoIntervalMs;
        if (payload["ms"].is<uint32_t>()) {
            ms = payload["ms"].as<uint32_t>();
        } else if (doc["ms"].is<uint32_t>()) {
            ms = doc["ms"].as<uint32_t>();
        }
        setAutoInterval(ms);
    } else if (cmd == "pause_scroll") {
        if (state.firmwareScrollActive) {
            state.firmwareScrollPaused = true;
            state.playback = "scroll_paused";
        }
    } else if (cmd == "resume_scroll") {
        if (state.scrollFrameCount > 0) {
            state.firmwareScrollActive = true;
            state.firmwareScrollPaused = false;
            state.lastScrollFrameMs = millis();
            state.playback = "scroll";
        }
    } else if (cmd == "stop_scroll") {
        stopFirmwareScroll(true);
    } else if (cmd == "pause") {
        state.paused = true;
        state.playback = "paused";
    } else if (cmd == "resume") {
        state.paused = false;
        state.playback = "idle";
    } else if (cmd == "button") {
        const char* button = payload["button"] | "";
        if (strlen(button) == 0) {
            button = doc["button"] | "";
        }
        if (!runButtonAction(String(button), "api_button")) {
            ++state.commandsRejected;
            sendError(400, "unsupported button or no saved faces available");
            return;
        }
    } else if (cmd == "terminate_other_activities") {
        const char* targetMode = payload["targetMode"] | "";
        if (strcmp(targetMode, "scroll") != 0) {
            stopFirmwareScroll(false);
        }
        if (strcmp(targetMode, "face") != 0 && strcmp(targetMode, "scroll") != 0) {
            setMode("manual", true);
        } else if (strcmp(targetMode, "scroll") == 0 && isAutoMode()) {
            state.restoreAutoAfterScroll = true;
            state.mode = "manual";
        }
    } else if (cmd == "adc_debug_override" || cmd == "raw_aux_command") {
        // Accepted for WebUI compatibility; this minimal firmware stores only the last command.
    } else {
        // Keep unknown commands non-fatal so the debug page can experiment.
        Serial.printf("Unknown command accepted: %s\n", cmd.c_str());
    }

    ++state.commandsAccepted;

    DynamicJsonDocument reply(1024);
    reply["ok"] = true;
    reply["cmd"] = cmd;
    reply["color"] = state.colorHex;
    reply["brightness"] = state.brightness;
    reply["mode"] = state.mode;
    reply["autoIntervalMs"] = state.autoIntervalMs;
    reply["playback"] = state.playback;
    reply["paused"] = state.paused;
    reply["autoFaceIndex"] = state.autoFaceIndex;
    reply["firmwareScrollActive"] = state.firmwareScrollActive;
    reply["firmwareScrollPaused"] = state.firmwareScrollPaused;
    reply["restoreAutoAfterScroll"] = state.restoreAutoAfterScroll;
    reply["scrollFrameCount"] = state.scrollFrameCount;
    reply["scrollFrameIndex"] = state.scrollFrameIndex;
    reply["scrollIntervalMs"] = state.scrollIntervalMs;
    if (autoFaceCount > 0 && state.autoFaceIndex < autoFaceCount) {
        reply["autoFaceId"] = autoFaces[state.autoFaceIndex].id;
        reply["autoFaceName"] = autoFaces[state.autoFaceIndex].name;
    }
    reply["m370"] = state.lastM370;
    reply["lastReason"] = state.lastReason;
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
    loadSavedFaces(false);

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

bool loadSavedFaces(bool applyStartupFace) {
    if (!fsMounted) {
        Serial.println("LittleFS not mounted; saved faces cannot be loaded");
        return false;
    }
    if (!LittleFS.exists(SAVED_FACES_PATH)) {
        Serial.println("No saved_faces.json; LED output starts blank");
        autoFaceCount = 0;
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
        autoFaceCount = 0;
        return false;
    }

    const String startupId = doc["startupDefaultId"] | "";
    JsonArray faces = doc["faces"].as<JsonArray>();
    String previousFaceId;
    const uint16_t previousFaceIndex = state.autoFaceIndex;
    if (autoFaceCount > 0 && state.autoFaceIndex < autoFaceCount) {
        previousFaceId = autoFaces[state.autoFaceIndex].id;
    }
    autoFaceCount = 0;
    uint16_t jsonIndex = 0;

    for (JsonObject face : faces) {
        const char* m370 = face["m370"] | "";
        String normalized;
        String error;
        if (!normalizeM370(m370, normalized, error)) {
            Serial.printf("Skipping invalid saved face: %s\n", error.c_str());
            ++jsonIndex;
            continue;
        }
        if (autoFaceCount >= MAX_AUTO_FACES) {
            break;
        }

        RuntimeFace& runtime = autoFaces[autoFaceCount++];
        runtime.id = String(face["id"] | "");
        runtime.name = String(face["name"] | runtime.id.c_str());
        runtime.m370 = normalized;
        runtime.order = face["order"].is<int32_t>() ? face["order"].as<int32_t>() : static_cast<int32_t>(jsonIndex);
        runtime.jsonIndex = jsonIndex;
        runtime.isDefault = strcmp(face["type"] | "", "default") == 0;
        runtime.isStartupDefault = face["is_startup_default"].as<bool>();
        ++jsonIndex;
    }

    if (autoFaceCount == 0) {
        Serial.println("saved_faces.json has no valid faces");
        return false;
    }

    for (uint16_t i = 0; i < autoFaceCount; ++i) {
        for (uint16_t j = i + 1; j < autoFaceCount; ++j) {
            const bool shouldSwap =
                autoFaces[j].order < autoFaces[i].order ||
                (autoFaces[j].order == autoFaces[i].order &&
                 autoFaces[j].jsonIndex < autoFaces[i].jsonIndex);
            if (shouldSwap) {
                RuntimeFace tmp = autoFaces[i];
                autoFaces[i] = autoFaces[j];
                autoFaces[j] = tmp;
            }
        }
    }

    int selectedIndex = -1;
    int firstDefaultIndex = -1;
    int firstFaceIndex = autoFaceCount > 0 ? 0 : -1;
    for (uint16_t i = 0; i < autoFaceCount; ++i) {
        if (autoFaces[i].isDefault && firstDefaultIndex < 0) {
            firstDefaultIndex = i;
        }
        if (selectedIndex < 0) {
            if (!applyStartupFace && !previousFaceId.isEmpty() && previousFaceId == autoFaces[i].id) {
                selectedIndex = i;
            } else if (applyStartupFace &&
                       ((!startupId.isEmpty() && startupId == autoFaces[i].id) || autoFaces[i].isStartupDefault)) {
                selectedIndex = i;
            }
        }
    }
    if (selectedIndex < 0) {
        if (!applyStartupFace && previousFaceIndex < autoFaceCount) {
            selectedIndex = previousFaceIndex;
        } else {
            selectedIndex = firstDefaultIndex >= 0 ? firstDefaultIndex : firstFaceIndex;
        }
    }
    state.autoFaceIndex = static_cast<uint16_t>(selectedIndex);
    Serial.printf("Loaded %u saved faces for firmware auto mode\n", autoFaceCount);

    if (applyStartupFace) {
        String error;
        const String bootMode = state.mode;
        const uint32_t bootIntervalMs = state.autoIntervalMs;
        state.defaultBrightness = DEFAULT_BRIGHTNESS;
        state.brightness = state.defaultBrightness;
        state.playback = DEFAULT_PLAYBACK;
        state.paused = false;
        if (!applyM370(autoFaces[state.autoFaceIndex].m370, STARTUP_FACE_REASON, error)) {
            Serial.printf("startup M370 failed: %s\n", error.c_str());
            return false;
        }
        state.autoIntervalMs = bootIntervalMs;
        setMode(bootMode.c_str(), false);
        Serial.printf("Loaded startup face index: %u\n", state.autoFaceIndex);
    }

    return true;
}

bool loadStartupFace() {
    return loadSavedFaces(true);
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
    server.on("/api/scroll", handleApiScroll);
    server.on("/api/command", HTTP_POST, handleApiCommand);
    server.on("/api/command", HTTP_OPTIONS, handleOptions);
    server.on("/api/saved_faces", handleApiSavedFaces);
    server.onNotFound(handleNotFound);
    server.begin();
    Serial.printf("HTTP server listening on http://%s/\n", WiFi.softAPIP().toString().c_str());
}

void serviceAutoPlayback() {
    if (!isAutoMode() || state.paused || autoFaceCount == 0) {
        return;
    }

    const uint32_t now = millis();
    if (state.lastAutoSwitchMs == 0) {
        state.lastAutoSwitchMs = now;
        return;
    }
    if (now - state.lastAutoSwitchMs < state.autoIntervalMs) {
        return;
    }

    state.lastAutoSwitchMs = now;
    state.autoFaceIndex = (state.autoFaceIndex + 1) % autoFaceCount;
    String error;
    state.playback = "auto_saved_face";
    if (!applyM370(autoFaces[state.autoFaceIndex].m370, "firmware_auto_saved_face", error)) {
        Serial.printf("auto face apply failed: %s\n", error.c_str());
    }
}

void serviceFirmwareScroll() {
    if (!state.firmwareScrollActive || state.firmwareScrollPaused || state.scrollFrameCount == 0) {
        return;
    }

    const uint32_t now = millis();
    if (state.lastScrollFrameMs == 0) {
        state.lastScrollFrameMs = now;
        return;
    }
    if (now - state.lastScrollFrameMs < state.scrollIntervalMs) {
        return;
    }

    state.lastScrollFrameMs = now;
    state.scrollFrameIndex = (state.scrollFrameIndex + 1) % state.scrollFrameCount;
    state.playback = "scroll";
    applyPackedFrame(scrollFrameBits[state.scrollFrameIndex], "firmware_text_scroll");
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
    initHardwareButtons();

    String colorError;
    setColor(DEFAULT_COLOR, colorError);

    fsMounted = LittleFS.begin(false, LITTLEFS_BASE_PATH, 10, LITTLEFS_PARTITION_LABEL);
    if (!fsMounted) {
        Serial.println("LittleFS mount failed. Upload data with: pio run -t uploadfs");
        showFilesystemErrorPattern();
    } else {
        loadRuntimeSettings();
        loadStartupFace();
    }

    startAccessPoint();
    startWebServer();
}

void loop() {
    server.handleClient();
    serviceHardwareButtons();
    serviceFirmwareScroll();
    serviceAutoPlayback();
    delay(2);
}
