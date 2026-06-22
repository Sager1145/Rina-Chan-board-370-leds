#include "web_api.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include "led_driver.h"
#include "storage.h"
#include "faces.h"
#include "buttons.h"
#include "button_animations.h"
#include "power_monitor.h"
#include "scroll_session.h"
#include <DNSServer.h>
#include <WebServer.h>
#include <WiFi.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <vector>
#include "mbedtls/base64.h"

static WebServer server(HTTP_PORT);
static DNSServer dnsServer;
static bool dnsServerActive = false;
static const char JSON_CT[] = "application/json; charset=utf-8";
static const char BIN_CT[] = "application/octet-stream";
static const char TXT_CT[] = "text/plain";

static void cors() {
    server.sendHeader("Access-Control-Allow-Origin", "*");
    server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    server.sendHeader("Access-Control-Allow-Headers", "Content-Type, Accept");
    server.sendHeader("Cache-Control", "no-store");
}
static void sendJson(int code, JsonDocument& doc) {
    String out;
    serializeJson(doc, out);
    cors();
    server.send(code, JSON_CT, out);
}
static void sendError(int code, const String& msg) {
    DynamicJsonDocument d(384);
    d["ok"] = false;
    d["error"] = msg;
    sendJson(code, d);
}
static void options() {
    cors();
    server.send(204, TXT_CT, "");
}
static String body() { return server.hasArg("plain") ? server.arg("plain") : ""; }
// The sync WebServer exposes the POST body via arg("plain") as a String, which truncates at the
// first 0x00. Packed frames are mostly zeros, so the WebUI sends them base64-encoded; decode here.
static bool decodeBase64Body(const String& b64, uint8_t* out, size_t cap, size_t& outLen) {
    outLen = 0;
    if (b64.isEmpty())
        return false;
    return mbedtls_base64_decode(out, cap, &outLen, (const unsigned char*)b64.c_str(), b64.length()) == 0;
}
static bool argBool(const char* k, bool fb = false) {
    if (!server.hasArg(k))
        return fb;
    String v = server.arg(k);
    v.toLowerCase();
    return v == "1" || v == "true" || v == "yes" || v == "on";
}
static uint32_t argU32(const char* k, uint32_t fb = 0) { return server.hasArg(k) ? strtoul(server.arg(k).c_str(), nullptr, 10) : fb; }
static uint16_t argInterval(uint16_t fb) {
    if (server.hasArg("intervalMs"))
        return (uint16_t)constrain(argU32("intervalMs", fb), 1UL, 65535UL);
    if (server.hasArg("fps")) {
        float f = server.arg("fps").toFloat();
        if (f > 0)
            return (uint16_t)constrain(lroundf(1000.0f / f), 1L, 65535L);
    }
    return fb;
}
static uint8_t uiFpsFromArgs(uint16_t intervalMs) {
    if (server.hasArg("fps")) {
        int f = (int)lroundf(server.arg("fps").toFloat());
        return (uint8_t)constrain(f, 1, 60);
    }
    if (intervalMs > 0)
        return (uint8_t)constrain((int)lroundf(1000.0f / (float)intervalMs), 1, 60);
    return 0;
}

static bool existsFs(const String& p) {
    bool e = false;
    withStorageLock([&]() { e = LittleFS.exists(p); });
    return e;
}
static File openFs(const String& p, const char* m) {
    File f;
    withStorageLock([&]() { f = LittleFS.open(p, m); });
    return f;
}
static const char* typeFor(const String& p) {
    if (p.endsWith(".html"))
        return "text/html; charset=utf-8";
    if (p.endsWith(".css"))
        return "text/css; charset=utf-8";
    if (p.endsWith(".js"))
        return "application/javascript; charset=utf-8";
    if (p.endsWith(".json"))
        return JSON_CT;
    if (p.endsWith(".png"))
        return "image/png";
    if (p.endsWith(".svg"))
        return "image/svg+xml";
    if (p.endsWith(".woff2"))
        return "font/woff2";
    return BIN_CT;
}
// Static-asset cache policy. Previously every static file was sent with `Cache-Control: no-store`
// (via cors()), so the browser re-downloaded index.html + styles.css + app.js (~414KB) + fonts +
// images on EVERY load. On the single-threaded sync WebServer that re-download contends with the
// browser's parallel connections on every visit, which is why a cold load often needs a refresh.
// index.html must always revalidate (it is the unversioned entry point); the heavy text assets are
// version-stamped with ?v= in index.html so they are safe to cache immutably; images/json get a
// short TTL so an in-place update is still picked up within a day.
static void staticCacheHeaders(const String& p) {
    server.sendHeader("Access-Control-Allow-Origin", "*");
    if (p.endsWith(".html")) {
        server.sendHeader("Cache-Control", "no-cache");
    } else if (p.endsWith(".js") || p.endsWith(".css") || p.endsWith(".woff2")) {
        server.sendHeader("Cache-Control", "public, max-age=31536000, immutable");
    } else {
        server.sendHeader("Cache-Control", "public, max-age=86400");
    }
}
static bool clientAcceptsGzip() { return server.hasHeader("Accept-Encoding") && server.header("Accept-Encoding").indexOf("gzip") >= 0; }
// Serve `p`, preferring a pre-compressed `<p>.gz` sibling (built by scripts/gzip_webui_assets.py)
// when the client accepts gzip. Content-Type and cache policy are derived from the ORIGINAL path.
// IMPORTANT: WebServer::streamFile() AUTOMATICALLY emits `Content-Encoding: gzip` when the streamed
// file name ends in ".gz" — so we must NOT add that header ourselves (doing so sends it twice and
// the browser fails to decode every asset). We only add Vary; streamFile handles the encoding.
static bool serveFile(String p) {
    if (!runtimeFsMounted())
        return false;
    if (p == "/")
        p = "/index.html";
    String served = p;
    bool gz = false;
    if (clientAcceptsGzip()) {
        String gzp = p + ".gz";
        if (existsFs(gzp)) {
            served = gzp;
            gz = true;
        }
    }
    if (!gz && !existsFs(p))
        return false;
    File f = openFs(served, "r");
    if (!f)
        return false;
    staticCacheHeaders(p);
    if (gz)
        server.sendHeader("Vary", "Accept-Encoding");
    server.streamFile(f, typeFor(p)); // sets Content-Length + (for .gz) Content-Encoding: gzip
    withStorageLock([&]() { f.close(); });
    return true;
}

static void addScroll(JsonObject o) {
    ScrollSessionSnapshot s = scrollSessionSnapshot();
    o["firmwareScrollActive"] = s.firmwareScrollActive;
    o["firmwareScrollPaused"] = s.firmwareScrollPaused;
    o["firmwareScrollUserPaused"] = s.firmwareScrollUserPaused;
    o["firmwareScrollSystemPaused"] = s.firmwareScrollSystemPaused;
    o["restoreAutoAfterScroll"] = s.restoreAutoAfterScroll;
    o["scrollFrameCount"] = s.scrollFrameCount;
    o["scrollFrameIndex"] = s.scrollFrameIndex;
    o["scrollIntervalMs"] = s.scrollIntervalMs;
    o["uiFps"] = s.uiFps;
    o["scrollFps"] = s.uiFps;
    o["scrollTimelineId"] = String(s.scrollTimelineId);
    o["scrollUploadComplete"] = s.scrollUploadComplete;
    o["scrollHasSourceText"] = s.scrollHasSourceText;
}
static void addFace(JsonObject o) {
    if (runtimeAutoFaceCount() == 0 || runtimeState().autoFaceIndex >= runtimeAutoFaceCount())
        return;
    RuntimeFace& f = runtimeAutoFaces()[runtimeState().autoFaceIndex];
    o["autoFaceId"] = f.id;
    o["autoFaceName"] = f.name;
}
static void addPower(JsonObject p) {
    PowerStatus s = readPowerStatusSnapshot();
    p["ok"] = s.batteryValid || s.chargeValid;
    p["charging"] = s.chargeValid ? s.charging : false;
    p["chargeValid"] = s.chargeValid;
    p["batteryValid"] = s.batteryValid;
    p["batteryPercent"] = s.batteryValid ? s.batteryPercent : 0;
    p["vbat"] = s.batteryValid ? s.vbat : 0.0f;
    p["vcharge"] = s.chargeValid ? s.vcharge : 0.0f;
    p["batteryPowered"] = s.batteryValid && !(s.batteryDisconnected || s.batteryLowVoltageUnpowered);
    p["batteryDisconnected"] = s.batteryDisconnected;
    p["batteryLowVoltageUnpowered"] = s.batteryLowVoltageUnpowered;
}

static void currentFrame() {
    if (server.method() == HTTP_OPTIONS) {
        options();
        return;
    }
    if (server.method() != HTTP_GET) {
        sendError(405, "method not allowed");
        return;
    }
    uint8_t f[FRAME_BYTES];
    withFrameLock([&]() { memcpy(f, runtimeFrameBits(), FRAME_BYTES); });
    unsigned char b64[80];
    size_t olen = 0;
    if (mbedtls_base64_encode(b64, sizeof(b64), &olen, f, FRAME_BYTES) != 0) {
        sendError(500, "failed to base64-encode frame");
        return;
    }
    cors();
    server.send(200, TXT_CT, String((const char*)b64).substring(0, olen));
}

static void status() {
    if (server.method() == HTTP_OPTIONS) {
        options();
        return;
    }
    if (server.method() != HTTP_GET) {
        sendError(405, "method not allowed");
        return;
    }
    servicePowerMonitor();
    DynamicJsonDocument d(6144);
    FrameStateSnapshot fs = readFrameStateSnapshot();
    d["ok"] = true;
    d["v"] = runtimeStateVersion();
    d["version"] = runtimeStateVersion();
    d["device"] = "RinaChanBoard";
    d["uptimeMs"] = millis() - runtimeState().bootMs;
    JsonObject ap = d.createNestedObject("ap");
    ap["ssid"] = AP_SSID;
    ap["ip"] = WiFi.softAPIP().toString();
    ap["domain"] = AP_DOMAIN;
    ap["url"] = String("http://") + AP_DOMAIN + "/";
    ap["clients"] = WiFi.softAPgetStationNum();
    addPower(d.createNestedObject("power"));
    JsonObject r = d.createNestedObject("renderer");
    r["color"] = fs.colorHex;
    r["brightness"] = fs.brightness;
    r["brightnessMin"] = MIN_BRIGHTNESS;
    r["brightnessMax"] = MAX_BRIGHTNESS;
    r["mode"] = runtimeState().mode;
    r["playback"] = runtimeState().playback;
    r["paused"] = runtimeState().paused;
    r["autoIntervalMs"] = runtimeState().autoIntervalMs;
    r["autoFaceCount"] = runtimeAutoFaceCount();
    r["autoFaceIndex"] = runtimeState().autoFaceIndex;
    r["frameEncoding"] = "packed-lsb-first";
    r["frameBytes"] = FRAME_BYTES;
    r["frameBits"] = LED_COUNT;
    r["frameQueueDepth"] = PACKED_FRAME_QUEUE_DEPTH;
    r["frameQueueCount"] = queuedPackedFrameCount();
    r["lit"] = fs.litLeds;
    r["lastReason"] = fs.lastReason;
    r["ledBackend"] = leddrv::backendName();
    r["ledDma"] = leddrv::dmaEnabled();
    r["ledRefreshUs"] = leddrv::lastRefreshUs();
    r["ledRefreshMaxUs"] = leddrv::maxRefreshUs();
    r["ledRefreshFail"] = leddrv::refreshFailCount();
    addFace(r);
    addScroll(r);
    JsonObject m = d.createNestedObject("matrix");
    m["leds"] = LED_COUNT;
    m["frameBytes"] = FRAME_BYTES;
    m["frameEncoding"] = "packed-lsb-first";
    JsonObject e = d.createNestedObject("endpoints");
    e["frame"] = "/api/frame";
    e["currentFrame"] = "/api/frame/current";
    e["command"] = "/api/command";
    e["scroll"] = "/api/scroll";
    e["savedFaces"] = "/api/saved_faces";
    e["power"] = "/api/power";
    e["status"] = "/api/status";
    JsonObject st = d.createNestedObject("stats");
    st["framesAccepted"] = fs.framesAccepted;
    st["framesRejected"] = runtimeState().framesRejected;
    st["framesQueued"] = runtimeState().framesQueued;
    st["framesDequeued"] = runtimeState().framesDequeued;
    st["framesDropped"] = runtimeState().framesDropped;
    st["commandsAccepted"] = runtimeState().commandsAccepted;
    st["commandsRejected"] = runtimeState().commandsRejected;
    sendJson(200, d);
}

static void power() {
    if (server.method() == HTTP_OPTIONS) {
        options();
        return;
    }
    if (server.method() != HTTP_GET) {
        sendError(405, "method not allowed");
        return;
    }
    servicePowerMonitor();
    DynamicJsonDocument d(1024);
    d["ok"] = true;
    addPower(d.createNestedObject("power"));
    sendJson(200, d);
}

static void frame() {
    if (server.method() == HTTP_OPTIONS) {
        options();
        return;
    }
    if (server.method() == HTTP_GET) {
        currentFrame();
        return;
    }
    if (server.method() != HTTP_POST) {
        sendError(405, "method not allowed");
        return;
    }
    String b = body();
    uint8_t fr[FRAME_BYTES];
    size_t flen = 0;
    if (!decodeBase64Body(b, fr, sizeof(fr), flen) || flen != FRAME_BYTES) {
        ++runtimeState().framesRejected;
        touchRuntimeStateSlow();
        sendError(400, String("packed frame body must base64-decode to exactly ") + FRAME_BYTES + " bytes");
        return;
    }
    const uint8_t* p = fr;
    String err;
    if (!validatePackedFrame(p, err)) {
        ++runtimeState().framesRejected;
        touchRuntimeStateSlow();
        sendError(400, err);
        return;
    }
    String playback = server.arg("playback");
    if (playback.isEmpty())
        playback = server.arg("mode");
    if (playback.isEmpty())
        playback = DEFAULT_PLAYBACK;
    String reason = server.arg("reason");
    if (reason.isEmpty())
        reason = "api_frame";
    if (!isScrollPlayback(playback))
        stopFirmwareScroll(false);
    if (reason.startsWith("custom_") || reason.startsWith("parts_") || reason.startsWith("debug_"))
        setMode("manual", false);
    runtimeState().playback = playback;
    if (!applyPackedFrameQueued(p, reason, err)) {
        sendError(400, err);
        return;
    }
    DynamicJsonDocument d(1024);
    FrameStateSnapshot fs = readFrameStateSnapshot();
    d["ok"] = true;
    d["accepted"] = true;
    d["binary"] = true;
    d["v"] = runtimeStateVersion();
    d["frameBytes"] = FRAME_BYTES;
    d["frameEncoding"] = "packed-lsb-first";
    d["queued"] = queuedPackedFrameCount() > 0;
    d["queueCount"] = queuedPackedFrameCount();
    d["queueDepth"] = PACKED_FRAME_QUEUE_DEPTH;
    d["leds"] = LED_COUNT;
    d["color"] = fs.colorHex;
    d["brightness"] = fs.brightness;
    d["reason"] = fs.lastReason;
    d["mode"] = runtimeState().mode;
    d["playback"] = runtimeState().playback;
    d["autoIntervalMs"] = runtimeState().autoIntervalMs;
    d["autoFaceIndex"] = runtimeState().autoFaceIndex;
    d["lit"] = fs.litLeds;
    addFace(d.as<JsonObject>());
    sendJson(200, d);
}

static void scroll() {
    if (server.method() == HTTP_OPTIONS) {
        options();
        return;
    }
    if (server.method() != HTTP_POST) {
        sendError(405, "method not allowed");
        return;
    }
    if (!runtimeScrollFrameBufferReady()) {
        sendError(507, "scroll frame buffer unavailable");
        return;
    }
    String b = body();
    if (b.isEmpty()) {
        sendError(400, "empty packed scroll body");
        return;
    }
    std::vector<uint8_t> rawvec((b.length() / 4) * 3 + 4);
    size_t rawLen = 0;
    if (!decodeBase64Body(b, rawvec.data(), rawvec.size(), rawLen) || rawLen == 0 || (rawLen % FRAME_BYTES) != 0) {
        sendError(400, "scroll body must base64-decode to N * 47 bytes");
        return;
    }
    uint16_t n = (uint16_t)(rawLen / FRAME_BYTES);
    bool append = argBool("append", false);
    bool start = argBool("start", false);
    uint16_t interval = argInterval(runtimeState().scrollIntervalMs);
    uint8_t uiFps = uiFpsFromArgs(interval);
    uint32_t total = argU32("totalFrames", append ? runtimeState().scrollFrameCount + n : n);
    if (total > MAX_SCROLL_FRAMES) {
        sendError(413, "too many scroll frames");
        return;
    }
    ScrollUploadTxn txn;
    if (append)
        txn = scrollSessionBeginAppend();
    else {
        ScrollUploadMeta meta;
        String tid = server.arg("timelineId");
        String fid = server.arg("fontId");
        String gen = server.arg("generatorVersion");
        String txt = server.arg("sourceText");
        if (txt.length() > MAX_SCROLL_TEXT_BYTES) {
            sendError(413, "sourceText too large");
            return;
        }
        meta.timelineId = tid.c_str();
        meta.fontId = fid.c_str();
        meta.generatorVersion = gen.c_str();
        meta.sourceText = txt.length() ? txt.c_str() : nullptr;
        meta.sourceTextBytes = (uint16_t)txt.length();
        meta.totalFrames = (uint16_t)total;
        meta.uiFps = uiFps;
        txn = scrollSessionBeginUpload(meta);
    }
    const uint8_t* raw = rawvec.data();
    String err;
    for (uint16_t i = 0; i < n; i++) {
        const uint8_t* fr = raw + (size_t)i * FRAME_BYTES;
        if (!validatePackedFrame(fr, err)) {
            sendError(400, String("invalid scroll frame: ") + err);
            return;
        }
        if (!scrollSessionWriteFrame(txn, txn.baseIndex + i, fr)) {
            sendError(500, "failed to write scroll frame");
            return;
        }
    }
    ScrollUploadResult res = scrollSessionCommitUpload(txn, n, server.hasArg("intervalMs") || server.hasArg("fps"), interval, uiFps);
    if (start)
        startFirmwareScroll(interval, uiFps);
    ScrollSessionSnapshot snap = scrollSessionSnapshot();
    DynamicJsonDocument d(768);
    d["ok"] = true;
    d["frames"] = res.frameCount;
    d["chunkFrames"] = n;
    d["append"] = append;
    d["started"] = start;
    d["timelineId"] = res.timelineId;
    d["uploadComplete"] = res.uploadComplete;
    d["frameBytes"] = FRAME_BYTES;
    d["scrollIntervalMs"] = snap.scrollIntervalMs;
    d["uiFps"] = snap.uiFps;
    d["scrollFps"] = snap.uiFps;
    sendJson(200, d);
}

static void scrollMeta() {
    if (server.method() == HTTP_OPTIONS) {
        options();
        return;
    }
    if (server.method() != HTTP_GET) {
        sendError(405, "method not allowed");
        return;
    }
    DynamicJsonDocument d(1024);
    ScrollMetaOut o;
    char text[MAX_SCROLL_TEXT_BYTES + 1];
    bool copied = scrollSessionCopyMeta(o, text, sizeof(text));
    d["ok"] = true;
    d["scrollTimelineId"] = o.meta.timelineId;
    d["hasSourceText"] = o.meta.hasSourceText && copied;
    if (o.meta.hasSourceText && copied)
        d["sourceText"] = text;
    d["sourceTextBytes"] = o.meta.sourceTextByteLength;
    d["fontId"] = o.meta.fontId;
    d["generatorVersion"] = o.meta.generatorVersion;
    d["uiFps"] = o.meta.uiFps;
    d["scrollIntervalMs"] = o.scrollIntervalMs;
    d["frameCount"] = o.frameCount;
    d["frameIndex"] = o.frameIndex;
    d["uploadComplete"] = o.meta.uploadComplete;
    d["firmwareScrollActive"] = o.active;
    d["firmwareScrollPaused"] = o.paused;
    sendJson(200, d);
}

static const char* ledPresentationSourceToJson(LedPresentationSource source) {
    switch (source) {
    case LedPresentationSource::ScrollTick:
        return "scroll_tick";
    case LedPresentationSource::ScrollStart:
        return "scroll_start";
    case LedPresentationSource::ScrollStep:
        return "scroll_step";
    case LedPresentationSource::ManualFrame:
        return "manual_frame";
    case LedPresentationSource::Clear:
        return "clear";
    case LedPresentationSource::Overlay:
        return "overlay";
    default:
        return "unknown";
    }
}
// Lightweight: ONLY the actually-presented (LED-latched) frame index + device timestamp. Never the
// full packed frame and never the (potentially large) sourceText. Polled ~4x/sec while scrolling.
static void previewSync() {
    if (server.method() == HTTP_OPTIONS) {
        options();
        return;
    }
    if (server.method() != HTTP_GET) {
        sendError(405, "method not allowed");
        return;
    }
    LedPresentedSample s = readLedPresentedSample();
    DynamicJsonDocument d(1024);
    d["ok"] = true;
    d["v"] = runtimeStateVersion();
    d["valid"] = s.valid;
    d["presentedSeq"] = s.presentedSeq;
    d["source"] = ledPresentationSourceToJson(s.source);
    d["reason"] = s.reason;
    d["scrollTimelineId"] = s.timelineId;
    d["presentedFrameIndex"] = s.presentedFrameIndex;
    d["presentedFrameCount"] = s.presentedFrameCount;
    d["frameIndex"] = s.presentedFrameIndex;
    d["frameCount"] = s.presentedFrameCount;
    d["presentedAtUs"] = s.presentedAtUs;
    d["renderStartUs"] = s.renderStartUs;
    d["renderDurationUs"] = s.renderDurationUs;
    d["scrollIntervalMs"] = s.nominalIntervalMs;
    d["uiFps"] = s.uiFps;
    d["firmwareScrollActive"] = s.firmwareScrollActive;
    d["firmwareScrollPaused"] = s.firmwareScrollPaused;
    d["firmwareScrollUserPaused"] = s.userPaused;
    d["firmwareScrollSystemPaused"] = s.systemPaused;
    d["rateEligible"] = s.rateEligible;
    sendJson(200, d);
}

static bool parseJson(JsonDocument& d, String& err) {
    String b = body();
    if (b.isEmpty()) {
        err = "empty JSON body";
        return false;
    }
    DeserializationError e = deserializeJson(d, b);
    if (e) {
        err = String("invalid JSON: ") + e.c_str();
        return false;
    }
    return true;
}
static const char* cstr(JsonDocument& d, JsonVariant p, const char* k, const char* fb = "") {
    if (!p.isNull() && p[k].is<const char*>())
        return p[k].as<const char*>();
    if (d[k].is<const char*>())
        return d[k].as<const char*>();
    return fb;
}
static int cint(JsonDocument& d, JsonVariant p, const char* k, int fb) {
    if (!p.isNull() && p[k].is<int>())
        return p[k].as<int>();
    if (d[k].is<int>())
        return d[k].as<int>();
    return fb;
}
static bool cbool(JsonDocument& d, JsonVariant p, const char* k, bool fb) {
    if (!p.isNull() && p[k].is<bool>())
        return p[k].as<bool>();
    if (d[k].is<bool>())
        return d[k].as<bool>();
    return fb;
}
static uint8_t cUiFps(JsonDocument& d, JsonVariant p, uint16_t intervalMs) {
    int f = cint(d, p, "fps", 0);
    if (f <= 0)
        f = cint(d, p, "uiFps", 0);
    if (f > 0)
        return (uint8_t)constrain(f, 1, 60);
    if (intervalMs > 0)
        return (uint8_t)constrain((int)lroundf(1000.0f / (float)intervalMs), 1, 60);
    return 0;
}
static void reply(JsonDocument& d, const char* cmd) {
    FrameStateSnapshot fs = readFrameStateSnapshot();
    d["ok"] = true;
    d["v"] = runtimeStateVersion();
    d["cmd"] = cmd;
    d["color"] = fs.colorHex;
    d["brightness"] = fs.brightness;
    d["mode"] = runtimeState().mode;
    d["playback"] = runtimeState().playback;
    d["paused"] = runtimeState().paused;
    d["autoIntervalMs"] = runtimeState().autoIntervalMs;
    d["autoFaceIndex"] = runtimeState().autoFaceIndex;
    d["frameBytes"] = FRAME_BYTES;
    d["frameEncoding"] = "packed-lsb-first";
    d["queueCount"] = queuedPackedFrameCount();
    d["lastReason"] = fs.lastReason;
    d["lit"] = fs.litLeds;
    addFace(d.as<JsonObject>());
    addScroll(d.as<JsonObject>());
}

static void command() {
    if (server.method() == HTTP_OPTIONS) {
        options();
        return;
    }
    if (server.method() != HTTP_POST) {
        sendError(405, "method not allowed");
        return;
    }
    String err;
    DynamicJsonDocument d((size_t)MAX_SCROLL_TEXT_BYTES + 4096);
    if (!parseJson(d, err)) {
        sendError(400, err);
        return;
    }
    const char* cmd = d["cmd"] | "";
    JsonVariant p = d["payload"];
    bool ok = true;
    if (strcmp(cmd, "set_color") == 0)
        ok = setColor(cstr(d, p, "hex", ""), err);
    else if (strcmp(cmd, "set_brightness") == 0)
        setBrightness(cint(d, p, "raw", cint(d, p, "brightness", DEFAULT_BRIGHTNESS)));
    else if (strcmp(cmd, "set_mode") == 0)
        ok = setMode(cstr(d, p, "mode", DEFAULT_MODE), true);
    else if (strcmp(cmd, "set_auto_interval") == 0)
        setAutoInterval((uint32_t)cint(d, p, "ms", DEFAULT_AUTO_INTERVAL_MS), true);
    else if (strcmp(cmd, "set_scroll_interval") == 0) {
        uint16_t interval = (uint16_t)cint(d, p, "intervalMs", runtimeState().scrollIntervalMs);
        scrollSessionSetInterval(interval, cUiFps(d, p, interval));
    } else if (strcmp(cmd, "start_scroll") == 0) {
        uint16_t interval = (uint16_t)cint(d, p, "intervalMs", runtimeState().scrollIntervalMs);
        uint8_t uiFps = cUiFps(d, p, interval);
        const char* st = cstr(d, p, "sourceText", nullptr);
        if (st && st[0]) {
            size_t sl = strlen(st);
            if (sl > MAX_SCROLL_TEXT_BYTES) {
                sendError(413, "sourceText too large");
                return;
            }
            scrollSessionSetSourceText(st, (uint16_t)sl);
        }
        startFirmwareScroll(interval, uiFps);
    } else if (strcmp(cmd, "scroll_step") == 0) {
        uint8_t f[FRAME_BYTES];
        if (scrollSessionStep(cint(d, p, "direction", 1) < 0 ? -1 : 1, f)) {
            clearQueuedPackedFrames();
            LedPresentationContext stepCtx;
            scrollSessionFillPresentationContext(stepCtx, LedPresentationSource::ScrollStep, "firmware_text_scroll_step", false);
            applyPackedFrameImmediate(f, "firmware_text_scroll_step", &stepCtx);
        }
    } else if (strcmp(cmd, "pause_scroll") == 0)
        scrollSessionSetUserPaused(true);
    else if (strcmp(cmd, "resume_scroll") == 0)
        scrollSessionSetUserPaused(false);
    else if (strcmp(cmd, "stop_scroll") == 0)
        stopFirmwareScroll(cbool(d, p, "restoreAuto", scrollSessionGetRestoreAuto()), cbool(d, p, "clear", true));
    else if (strcmp(cmd, "pause") == 0) {
        runtimeState().paused = true;
        runtimeState().playback = "paused";
        touchRuntimeState();
    } else if (strcmp(cmd, "resume") == 0) {
        scrollSessionSetUserPaused(false);
        runtimeState().paused = false;
        runtimeState().playback = DEFAULT_PLAYBACK;
        touchRuntimeState();
    } else if (strcmp(cmd, "apply_saved_face") == 0) {
        stopFirmwareScroll(false, false);
        scrollSessionSetRestoreAuto(false);
        const int index = cint(d, p, "index", runtimeState().autoFaceIndex);
        ok = applySavedFaceIndex(
            static_cast<uint16_t>(index < 0 ? 0 : index),
            String(cstr(d, p, "reason", "webui_apply_saved_face")),
            cstr(d, p, "playback", DEFAULT_PLAYBACK));
    } else if (strcmp(cmd, "button") == 0)
        ok = runButtonAction(String(cstr(d, p, "button", "")), "webui");
    else if (strcmp(cmd, "terminate_other_activities") == 0) {
        stopFirmwareScroll(false, true);
        setMode(cstr(d, p, "targetMode", "manual"), false);
    } else if (strcmp(cmd, "reset_battery_min") == 0)
        resetBatteryVoltageMinimum();
    else if (strcmp(cmd, "reset_battery_max") == 0)
        resetBatteryVoltageMaximum();
    else if (strcmp(cmd, "battery_overlay") == 0)
        showBatteryOverlay(cbool(d, p, "singleShot", true));
    else {
        ok = false;
        err = String("unknown command: ") + cmd;
    }
    if (!ok) {
        ++runtimeState().commandsRejected;
        touchRuntimeStateSlow();
        sendError(400, err);
        return;
    }
    ++runtimeState().commandsAccepted;
    touchRuntimeState();
    DynamicJsonDocument out(2048);
    reply(out, cmd);
    sendJson(200, out);
}

static void savedFaces() {
    if (server.method() == HTTP_OPTIONS) {
        options();
        return;
    }
    if (server.method() == HTTP_GET) {
        if (!runtimeFsMounted()) {
            sendError(503, "LittleFS is not mounted");
            return;
        }
        if (!existsFs(SAVED_FACES_PATH)) {
            sendError(404, "saved_faces.json not found");
            return;
        }
        File f = openFs(SAVED_FACES_PATH, "r");
        if (!f) {
            sendError(500, "failed to open saved_faces.json");
            return;
        }
        cors();
        server.streamFile(f, JSON_CT);
        withStorageLock([&]() { f.close(); });
        return;
    }
    if (server.method() == HTTP_POST) {
        String b = body();
        if (b.isEmpty()) {
            sendError(400, "empty JSON body");
            return;
        }
        DynamicJsonDocument d(16384);
        DeserializationError e = deserializeJson(d, b, DeserializationOption::NestingLimit(32));
        if (e) {
            sendError(400, String("invalid JSON: ") + e.c_str());
            return;
        }
        JsonVariant doc = d["document"];
        if (doc.isNull())
            doc = d.as<JsonVariant>();
        String err;
        if (!validateSavedFaces(doc, err)) {
            sendError(400, err);
            return;
        }
        size_t written = writeSavedFaces(doc, err);
        if (written == 0) {
            sendError(500, err);
            return;
        }
        loadSavedFaces(false);
        DynamicJsonDocument out(384);
        out["ok"] = true;
        out["v"] = runtimeStateVersion();
        out["path"] = SAVED_FACES_PATH;
        out["bytes"] = written;
        sendJson(200, out);
        return;
    }
    sendError(405, "method not allowed");
}

static void notFound() {
    if (server.method() == HTTP_GET && serveFile(server.uri()))
        return;
    sendError(404, "not found: " + server.uri());
}

void showFilesystemErrorPattern() {
    withFrameLock([]() { runtimeState().colorHex="#ff0000"; runtimeState().colorR=0xff; runtimeState().colorG=0; runtimeState().colorB=0; runtimeState().brightness=DEFAULT_BRIGHTNESS; memset(runtimeFrameBits(),0,FRAME_BYTES); for(uint16_t i=0;i<12&&i<LED_COUNT;i++)setFrameBit(i,true); runtimeState().lastReason="littlefs_mount_failed"; showCurrentFrameNoLock(); });
}
void startAccessPoint() {
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(apIP(), apGateway(), apSubnet());
    WiFi.softAP(AP_SSID, AP_PASSWORD);
    // 中文：关闭 Wi-Fi modem-sleep (WIFI_PS_NONE)。省电休眠会带来周期性的中断延迟
    // 尖峰，正好会推迟 LED 的 RMT refill ISR 而造成乱码。常开功耗略增，但本设备有
    // 外部供电场景，优先保证 LED 时序稳定。
    WiFi.setSleep(false);
    IPAddress ip = WiFi.softAPIP();
    dnsServer.setTTL(60);
    dnsServerActive = dnsServer.start(DNS_PORT, AP_DOMAIN, ip);
    Serial.printf("AP started: ssid=%s password=%s ip=%s domain=%s dns=%s\n", AP_SSID, AP_PASSWORD, ip.toString().c_str(), AP_DOMAIN, dnsServerActive ? "on" : "off");
}
void startWebServer() {
    server.on("/", HTTP_GET, []() {if(!serveFile("/"))sendError(404,"not found: /"); });
    server.on("/api/status", HTTP_ANY, status);
    server.on("/api/power", HTTP_ANY, power);
    server.on("/api/frame", HTTP_ANY, frame);
    server.on("/api/frame/current", HTTP_ANY, currentFrame);
    server.on("/api/scroll", HTTP_ANY, scroll);
    server.on("/api/scroll/meta", HTTP_ANY, scrollMeta);
    server.on("/api/preview_sync", HTTP_ANY, previewSync);
    server.on("/api/command", HTTP_ANY, command);
    server.on("/api/saved_faces", HTTP_ANY, savedFaces);
    server.onNotFound(notFound);
    {
        static const char* kCollect[] = {"Accept-Encoding"};
        server.collectHeaders(kCollect, 1);
    }
    server.begin();
    Serial.printf("Web server started on port %d\n", HTTP_PORT);
}
void webServerTick() {
    if (dnsServerActive)
        dnsServer.processNextRequest();
    server.handleClient();
}
