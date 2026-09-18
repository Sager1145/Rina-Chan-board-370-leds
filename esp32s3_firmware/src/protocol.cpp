#include "protocol.h"
#include "transport.h"
#include "config.h"
#include "state.h"
#include "sync.h"
#include "led_renderer.h"
#include "led_driver.h"
#include "storage.h"
#include "faces.h"
#include "buttons.h"
#include "button_animations.h"
#include "power_monitor.h"
#include "scroll_session.h"
#include "wifi_manager.h"
#include "board_identity.h"
#include "group_math.h"
#include "transport_ble.h"
#include "utils.h"
#include "psram_json.h"
#include "serial_log.h"
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>
#include <math.h>
#include <string.h>
#include <freertos/task.h>

using rinalink::Carrier;
using rinalink::ClientId;
using rinalink::ITransport;
using rinalink::FRAME_MAGIC;
using rinalink::FRAME_HEADER_BYTES;
using rinalink::MAX_PAYLOAD_BYTES;
using rinalink::MAX_CLIENTS;
using rinalink::INBOUND_BUFFER_BYTES;
using rinalink::FLAG_MORE;
using rinalink::transportFrame;
using rinalink::transportPushInbound;

// --- Message types (docs/RINALINK_PROTOCOL_V1.md §3) --------------------------------
namespace msg {
constexpr uint8_t CMD              = 0x01;
constexpr uint8_t GET_STATUS       = 0x02;
constexpr uint8_t GET_POWER        = 0x03;
constexpr uint8_t GET_SCROLL_META  = 0x04;
constexpr uint8_t GET_PREVIEW_SYNC = 0x05;
constexpr uint8_t PING             = 0x06;
constexpr uint8_t SET_FRAME        = 0x10;
constexpr uint8_t GET_FRAME        = 0x11;
constexpr uint8_t BLOB_BEGIN       = 0x20;
constexpr uint8_t BLOB_CHUNK       = 0x21;
constexpr uint8_t BLOB_END         = 0x22;
constexpr uint8_t BLOB_ABORT       = 0x23;
constexpr uint8_t GET_FACES        = 0x24;
constexpr uint8_t ERR              = 0xFF;
constexpr uint8_t EV_PREVIEW_SYNC  = 0x90;
constexpr uint8_t EV_STATUS        = 0x91;
constexpr uint8_t EV_POWER         = 0x92;
constexpr uint8_t EV_WIFI          = 0x93;
constexpr uint8_t EV_LOG           = 0x94;
constexpr uint8_t EV_WIFI_SCAN     = 0x95;
} // namespace msg

// --- Blob upload/download session (§3.3) --------------------------------------------
enum class BlobKind : uint8_t { None = 0, Scroll, Faces, ScrollBitmap };

struct BlobSession {
    BlobKind kind = BlobKind::None;
    uint32_t expectedOffset = 0;
    uint32_t totalBytes = 0;
    uint32_t lastActivityMs = 0;
    uint32_t generation = 0;

    // scroll
    ScrollUploadTxn txn;
    uint8_t* scrollBuf = nullptr;
    size_t scrollCap = 0;
    uint16_t totalFrames = 0;
    uint16_t framesReceived = 0;
    bool append = false;
    bool hasExplicitTiming = false;
    uint16_t intervalMs = DEFAULT_SCROLL_INTERVAL_MS;
    uint8_t uiFps = 0;
    String scrollTimelineId;
    String scrollFontId;
    String scrollGeneratorVersion;
    String scrollSourceText;

    // faces
    uint8_t* facesBuf = nullptr;
    size_t facesCap = 0;

    // scroll_bitmap (§7.1): raw bitmap bytes are staged here. At BLOB_END, every
    // frame is expanded into a full PSRAM staging buffer BEFORE
    // scrollSessionBeginUpload() is ever called, so a BLOB_ABORT or a validation
    // failure before that point never disturbs the currently-playing timeline.
    // Expansion itself is deterministic bit math, so once the staging allocation
    // succeeds, a failure between BeginUpload and the commit (which does wipe the
    // live timeline) is possible only on OOM, not on malformed input.
    uint8_t* bitmapBuf = nullptr;
    uint16_t bitmapWidth = 0;
    uint16_t bitmapStride = 0;
    uint32_t bitmapTotalBytes = 0;
    uint16_t bitmapFrameCount = 0;
    String bitmapTimelineId;
    String bitmapFontId;
    String bitmapGeneratorVersion;
    String bitmapSourceText;
    // Board group v1 (§1.4): optional viewport into a wider virtual/stitched
    // screen. bitmapViewportX defaults to 0 so scrollBitmapPixelLit() is
    // unchanged when a legacy (non-group) upload never sets these.
    bool bitmapHasViewport = false;
    uint32_t bitmapVirtualWidth = 0;
    uint32_t bitmapViewportX = 0;

    void reset() {
        if (scrollBuf) {
            heap_caps_free(scrollBuf);
            scrollBuf = nullptr;
        }
        scrollCap = 0;
        scrollTimelineId = "";
        scrollFontId = "";
        scrollGeneratorVersion = "";
        scrollSourceText = "";
        if (facesBuf) {
            heap_caps_free(facesBuf);
            facesBuf = nullptr;
        }
        facesCap = 0;
        if (bitmapBuf) {
            heap_caps_free(bitmapBuf);
            bitmapBuf = nullptr;
        }
        bitmapWidth = 0;
        bitmapStride = 0;
        bitmapTotalBytes = 0;
        bitmapFrameCount = 0;
        bitmapTimelineId = "";
        bitmapFontId = "";
        bitmapGeneratorVersion = "";
        bitmapSourceText = "";
        bitmapHasViewport = false;
        bitmapVirtualWidth = 0;
        bitmapViewportX = 0;
        kind = BlobKind::None;
        expectedOffset = 0;
        totalBytes = 0;
        lastActivityMs = 0;
        generation = 0;
        totalFrames = 0;
        framesReceived = 0;
        append = false;
        hasExplicitTiming = false;
    }
};

// --- Client table ---------------------------------------------------------------------
struct ClientSlot {
    bool used = false;
    ITransport* transport = nullptr;
    Carrier carrier = Carrier::None;
    uint8_t* inbound = nullptr;
    size_t inboundLen = 0;
    portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;

    // Registry contract (see transport.h): these flags are set from any task
    // under g_registryMux and consumed/cleared only at the start of
    // serviceProtocol() on the loop task. Inbound fields below use mux instead.
    // No other field here is ever mutated
    // off the loop task once a slot is claimed.
    bool connectPending = false;
    bool disconnectPending = false;
    // Inbound framing loss is guarded by mux, together with inboundLen.
    bool resyncNeeded = false;
    size_t oversizedBytesRemaining = 0;

    bool subPreview = true;
    bool subStatus = true;
    bool subPower = true;
    bool subLog = false;

    bool havePreviewSeq = false;
    uint32_t lastPreviewSeq = 0;
    uint32_t lastPreviewSentMs = 0;

    bool haveStatusVersion = false;
    uint32_t lastStatusVersion = 0;
    uint32_t lastStatusSentMs = 0;

    uint32_t lastPowerSentMs = 0;
    bool haveChargingSent = false;
    bool lastChargingSent = false;
    bool wifiEventPending = false;

    BlobSession blob;
};

static ClientSlot g_clients[MAX_CLIENTS];
static bool g_rebootPending = false;
static uint32_t g_rebootAtMs = 0;

// Guards the connect/disconnect claim of g_clients[i].used/transport/carrier plus
// the connectPending/disconnectPending flags. See transport.h for the contract.
static portMUX_TYPE g_registryMux = portMUX_INITIALIZER_UNLOCKED;

// Only one client may hold an in-progress "scroll" blob upload at a time (item 10).
static int g_activeScrollBlobSlot = -1;

// Pending wifi_scan requester (item 4): only one scan can be in flight.
static int g_wifiScanRequesterSlot = -1;
static bool g_wifiScanEventPending = false;

// EV_LOG ring (item 9): filled from any task via the serial_log sink, drained on
// the loop task by serviceProtocolEvents().
struct LogRingEntry {
    char level = 'I';
    char tag[16] = {0};
    char msg[160] = {0};
};
constexpr uint8_t LOG_RING_CAP = 16;
static LogRingEntry* g_logRing = nullptr;
static uint8_t g_logHead = 0;
static uint8_t g_logCount = 0;
static portMUX_TYPE g_logRingMux = portMUX_INITIALIZER_UNLOCKED;

static void protocolLogSink(char level, const char* tag, const char* msg) {
    if (!g_logRing)
        return;
    portENTER_CRITICAL(&g_logRingMux);
    LogRingEntry& e = g_logRing[g_logHead];
    e.level = level;
    strlcpy(e.tag, tag ? tag : "", sizeof(e.tag));
    strlcpy(e.msg, msg ? msg : "", sizeof(e.msg));
    g_logHead = (uint8_t)((g_logHead + 1) % LOG_RING_CAP);
    if (g_logCount < LOG_RING_CAP)
        g_logCount++;
    portEXIT_CRITICAL(&g_logRingMux);
}

// Releases the exclusive scroll-blob slot claim (item 10) if `c` currently holds it,
// then resets the blob session. Use this instead of calling c.blob.reset() directly
// so the exclusivity tracker never gets stuck on a client that aborted/disconnected.
static void resetBlob(ClientSlot& c) {
    int selfSlot = static_cast<int>(&c - g_clients);
    if ((c.blob.kind == BlobKind::Scroll || c.blob.kind == BlobKind::ScrollBitmap) &&
        g_activeScrollBlobSlot == selfSlot)
        g_activeScrollBlobSlot = -1;
    c.blob.reset();
}

// Loop-task only. A stopped/replaced timeline invalidates outstanding uploads
// from every carrier, including a bitmap still staged before BeginUpload.
static void expireBlobSessions() {
    const uint32_t generation = scrollSessionGeneration();
    const uint32_t now = millis();
    for (auto& client : g_clients) {
        const auto& blob = client.blob;
        if (blob.kind == BlobKind::None)
            continue;
        const bool scroll = blob.kind == BlobKind::Scroll || blob.kind == BlobKind::ScrollBitmap;
        if ((scroll && blob.generation != generation) ||
            static_cast<uint32_t>(now - blob.lastActivityMs) >= 30000)
            resetBlob(client);
    }
}

// --- Framing / reply helpers -----------------------------------------------------------
// isEvent=true marks unsolicited events so a back-pressured carrier (TCP) can drop
// the send instead of blocking loop() (item 6/8). A dropped EVENT (isEvent=true,
// ok=false) is expected under back-pressure and must NOT tear the client down --
// only a failed reply/request-response send (isEvent=false) unregisters the
// client; the actual teardown happens at the top of the next serviceProtocol()
// pass (item 1/8).
static bool sendFrame(ClientSlot& c, uint8_t type, uint8_t seq, uint8_t flags,
                      const uint8_t* payload, uint16_t len, bool isEvent = false) {
    if (c.disconnectPending || !c.transport)
        return false;
    static uint8_t buf[FRAME_HEADER_BYTES + MAX_PAYLOAD_BYTES];
    size_t total = transportFrame(buf, type, seq, flags, payload, len);
    uint8_t slot = static_cast<uint8_t>(&c - g_clients);
    bool ok = c.transport->send(ClientId{slot}, buf, total, isEvent);
    if (!ok && !isEvent) {
        RLOG_DEBUG("PROTO", "event=send_failed slot=%u type=%u", (unsigned)slot, (unsigned)type);
        rinalink::transportUnregisterClient(ClientId{slot});
    }
    return ok;
}

// Single JSON emitter for every reply/event path. Serializes into one shared
// scratch buffer (sized for the largest known reply, GET_SCROLL_META's
// sourceText) and, if the result does not fit in one MAX_PAYLOAD_BYTES frame,
// splits it into multiple frames with FLAG_MORE set on all but the last (same
// type/seq). The iOS client already aggregates MORE frames. Consolidates the
// former sendJsonReply / sendEvent / sendErrorReply / sendJsonReplyChunked.
static bool emitJson(ClientSlot& c, uint8_t type, uint8_t seq, uint8_t flags, JsonDocument& doc,
                     bool isEvent = false) {
    constexpr size_t kScratchCap = static_cast<size_t>(MAX_SCROLL_TEXT_BYTES) + 2048U;
    static char scratch[kScratchCap];
    size_t n = serializeJson(doc, scratch, kScratchCap);
    if (n >= kScratchCap)
        n = kScratchCap - 1;
    if (n == 0) {
        return sendFrame(c, type, seq, flags, nullptr, 0, isEvent);
    }
    size_t off = 0;
    while (off < n) {
        size_t chunk = n - off;
        if (chunk > MAX_PAYLOAD_BYTES)
            chunk = MAX_PAYLOAD_BYTES;
        bool more = (off + chunk) < n;
        uint8_t outFlags = static_cast<uint8_t>(flags | (more ? FLAG_MORE : 0));
        if (!sendFrame(c, type, seq, outFlags,
                       reinterpret_cast<const uint8_t*>(scratch + off),
                       (uint16_t)chunk, isEvent))
            return false;
        off += chunk;
    }
    return true;
}

static bool sendJsonReply(ClientSlot& c, uint8_t reqType, uint8_t seq, JsonDocument& doc) {
    return emitJson(c, static_cast<uint8_t>(reqType | 0x80), seq, 0, doc, false);
}

static bool sendEvent(ClientSlot& c, uint8_t evType, JsonDocument& doc) {
    return emitJson(c, evType, 0, 0, doc, true);
}

static void sendErrorReply(ClientSlot& c, uint8_t seq, int code, const String& msg, int32_t expectedOffset = -1) {
    StaticJsonDocument<384> d;
    d["ok"] = false;
    d["error"] = msg;
    d["code"] = code;
    if (expectedOffset >= 0)
        d["expectedOffset"] = expectedOffset;
    emitJson(c, msg::ERR, seq, 0, d, false);
}

// --- Storage helpers -----------------------------------------------------------------
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

// --- JSON builders --------------------------------------------------------------------
static void addScroll(JsonObject o) {
    ScrollSessionSnapshot s = scrollSessionSnapshot();
    o["firmwareScrollActive"] = s.firmwareScrollActive;
    o["firmwareScrollPaused"] = s.firmwareScrollPaused;
    o["firmwareScrollUserPaused"] = s.firmwareScrollUserPaused;
    o["firmwareScrollSystemPaused"] = s.firmwareScrollSystemPaused;
    o["restoreAutoAfterScroll"] = s.restoreAutoAfterScroll;
    o["scrollLoop"] = s.scrollLoop;
    o["groupTimed"] = s.groupTimed;
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
    p["battCalibMaxV"] = s.batteryCalibMaxV;
    p["battCalibCutoffV"] = s.batteryCalibMinV;
    p["battCalibMaxLearned"] = s.batteryCalibMaxLearned;
    p["battCalibCutoffLearned"] = s.batteryCalibCutoffLearned;
    p["batteryAdcSaturated"] = s.batteryAdcMv >= BATTERY_ADC_CLIP_MV;
}

static void buildStatusJson(JsonDocument& d, bool lite) {
    FrameStateSnapshot fs = readFrameStateSnapshot();
    d["ok"] = true;
    d["v"] = runtimeStateVersion();
    d["version"] = runtimeStateVersion();
    if (!lite) {
        d["device"] = "RinaChanBoard";
        d["uptimeMs"] = millis() - runtimeState().bootMs;
        wifiManagerGetStatusJson(d.createNestedObject("wifi"));
    }
    addPower(d.createNestedObject("power"));
    JsonObject r = d.createNestedObject("renderer");
    r["color"] = fs.colorHex;
    r["brightness"] = fs.brightness;
    r["brightnessMin"] = MIN_BRIGHTNESS;
    r["brightnessMax"] = MAX_BRIGHTNESS;
    r["mode"] = runtimeState().mode;
    r["outputMode"] = runtimeState().outputMode;
    r["outputStreamID"] = runtimeState().outputStreamID;
    r["outputPositionMs"] = runtimeState().outputPositionMs;
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
    if (!lite) {
        JsonObject m = d.createNestedObject("matrix");
        m["leds"] = LED_COUNT;
        m["frameBytes"] = FRAME_BYTES;
        m["frameEncoding"] = "packed-lsb-first";
        JsonObject st = d.createNestedObject("stats");
        st["framesAccepted"] = fs.framesAccepted;
        st["framesRejected"] = runtimeState().framesRejected;
        st["framesQueued"] = runtimeState().framesQueued;
        st["framesDequeued"] = runtimeState().framesDequeued;
        st["framesDropped"] = runtimeState().framesDropped;
        st["commandsAccepted"] = runtimeState().commandsAccepted;
        st["commandsRejected"] = runtimeState().commandsRejected;
    }
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
// u64 fields (group_start's atUs) can exceed the int32 range cint() handles, so
// presence is checked by null-ness (like cstr()) rather than is<int>().
static uint64_t cu64(JsonDocument& d, JsonVariant p, const char* k, uint64_t fb) {
    if (!p.isNull() && !p[k].isNull())
        return p[k].as<uint64_t>();
    if (!d[k].isNull())
        return d[k].as<uint64_t>();
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
// Explicit intervalMs wins; an fps-only request derives the interval from it. Falling back to
// the current interval there left the board ticking at the old speed while reporting the new fps.
static uint16_t cScrollInterval(JsonDocument& d, JsonVariant p) {
    const int interval = cint(d, p, "intervalMs", 0);
    if (interval > 0)
        return (uint16_t)constrain(interval, (int)MIN_SCROLL_INTERVAL_MS, (int)MAX_SCROLL_INTERVAL_MS);
    int f = cint(d, p, "fps", 0);
    if (f <= 0)
        f = cint(d, p, "uiFps", 0);
    if (f > 0)
        return (uint16_t)constrain((int)lroundf(1000.0f / (float)f), (int)MIN_SCROLL_INTERVAL_MS,
                                   (int)MAX_SCROLL_INTERVAL_MS);
    return runtimeState().scrollIntervalMs;
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

// --- CMD dispatcher (docs/RINALINK_PROTOCOL_V1.md §3.4) ---------------------------------
static void handleWifiCmd(ClientSlot& c, uint8_t seq, const char* cmd, JsonDocument& d, JsonVariant p) {
    if (strcmp(cmd, "wifi_status") == 0) {
        DynamicJsonDocument out(768);
        wifiManagerGetStatusJson(out.to<JsonObject>());
        sendJsonReply(c, msg::CMD, seq, out);
    } else if (strcmp(cmd, "wifi_scan") == 0) {
        int selfSlot = static_cast<int>(&c - g_clients);
        if (wifiManagerScanInProgress()) {
            g_wifiScanRequesterSlot = selfSlot;
            DynamicJsonDocument out(64);
            out["ok"] = true;
            out["scanning"] = true;
            sendJsonReply(c, msg::CMD, seq, out);
        } else if (wifiManagerStartScan()) {
            g_wifiScanRequesterSlot = selfSlot;
            DynamicJsonDocument out(64);
            out["ok"] = true;
            out["scanning"] = true;
            sendJsonReply(c, msg::CMD, seq, out);
        } else {
            sendErrorReply(c, seq, 500, "failed to start wifi scan");
        }
    } else if (strcmp(cmd, "wifi_scan_result") == 0) {
        DynamicJsonDocument out(2560);
        out["ok"] = true;
        out["scanning"] = wifiManagerScanInProgress();
        JsonArray arr = out.createNestedArray("networks");
        wifiManagerGetScanJson(arr);
        sendJsonReply(c, msg::CMD, seq, out);
    } else if (strcmp(cmd, "wifi_set_credentials") == 0) {
        bool ok = wifiManagerSetCredentials(cstr(d, p, "ssid", ""), cstr(d, p, "password", ""));
        DynamicJsonDocument out(128);
        out["ok"] = ok;
        if (!ok)
            out["error"] = "ssid required";
        sendJsonReply(c, msg::CMD, seq, out);
    } else if (strcmp(cmd, "wifi_clear_credentials") == 0) {
        wifiManagerClearCredentials();
        DynamicJsonDocument out(64);
        out["ok"] = true;
        sendJsonReply(c, msg::CMD, seq, out);
    } else if (strcmp(cmd, "wifi_set_hotspot_credentials") == 0) {
        bool ok = wifiManagerSetHotspotCredentials(cstr(d, p, "ssid", ""), cstr(d, p, "password", ""));
        DynamicJsonDocument out(128);
        out["ok"] = ok;
        if (!ok)
            out["error"] = "ssid required";
        sendJsonReply(c, msg::CMD, seq, out);
    } else if (strcmp(cmd, "wifi_clear_hotspot_credentials") == 0) {
        wifiManagerClearHotspotCredentials();
        DynamicJsonDocument out(64);
        out["ok"] = true;
        sendJsonReply(c, msg::CMD, seq, out);
    } else if (strcmp(cmd, "wifi_set_mode") == 0) {
        bool ok = wifiManagerSetMode(cstr(d, p, "mode", ""));
        DynamicJsonDocument out(128);
        out["ok"] = ok;
        if (!ok)
            out["error"] = "invalid mode";
        sendJsonReply(c, msg::CMD, seq, out);
    } else if (strcmp(cmd, "wifi_connect") == 0) {
        wifiManagerConnect();
        DynamicJsonDocument out(64);
        out["ok"] = true;
        sendJsonReply(c, msg::CMD, seq, out);
    } else if (strcmp(cmd, "wifi_set_ap") == 0) {
        bool ok = wifiManagerSetAp(cstr(d, p, "ssid", ""), cstr(d, p, "password", ""));
        DynamicJsonDocument out(128);
        out["ok"] = ok;
        if (!ok)
            out["error"] = "ssid required";
        sendJsonReply(c, msg::CMD, seq, out);
    } else {
        sendErrorReply(c, seq, 400, String("unknown command: ") + cmd);
    }
}

static void handleGetInfo(ClientSlot& c, uint8_t seq) {
    DynamicJsonDocument out(768);
    out["ok"] = true;
    out["device"] = "RinaChanBoard";
    // Board identity: `name` is what the board advertises over BLE and what the
    // app lists it under; `defaultName` is the MAC-derived fallback so the app
    // can show what clearing the custom name would restore.
    char nameBuf[MAX_DEVICE_NAME_BYTES + 1];
    char defaultNameBuf[MAX_DEVICE_NAME_BYTES + 1];
    bleTransportDeviceName(nameBuf, sizeof(nameBuf));
    bleTransportDefaultDeviceName(defaultNameBuf, sizeof(defaultNameBuf));
    out["name"] = nameBuf;
    out["defaultName"] = defaultNameBuf;
    out["customName"] = runtimeState().deviceName.length() > 0;
    out["fw"] = FIRMWARE_VERSION;
    out["build"] = String(__DATE__) + " " + String(__TIME__);
    out["ledBackend"] = leddrv::backendName();
    out["ledDma"] = leddrv::dmaEnabled();
    out["heapFree"] = ESP.getFreeHeap();
    out["psramFree"] = ESP.getFreePsram();
    out["psramSize"] = ESP.getPsramSize();
    out["uptimeMs"] = millis() - runtimeState().bootMs;
    out["proto"] = 1;
    // Board group v1 (docs/BOARD_GROUP_SPEC.md §1.1).
    out["bootId"] = boardBootId();
    JsonArray caps = out.createNestedArray("caps");
    caps.add("identify");
    caps.add("clock_sample");
    caps.add("scroll_viewport");
    caps.add("group_start");
    sendJsonReply(c, msg::CMD, seq, out);
}

// --- Incremental saved-face commands (docs/RINALINK_PROTOCOL_V1.md §7.2) ---------------
// Read saved_faces.json -> mutate in place -> validate -> atomic write -> hot reload ->
// gen++ -> reply {ok,v,gen,count}. `mutate` returns false with (errCode,errMsg) set to
// abort before any write; a false result with errCode==0 is treated as 400.
template <typename Fn>
static void mutateFacesDocument(ClientSlot& c, uint8_t seq, const char* cmdName, Fn mutate) {
    if (!runtimeFsMounted()) {
        sendErrorReply(c, seq, 503, "LittleFS is not mounted");
        return;
    }
    size_t fileSize = 0;
    char* contentBuf = nullptr;
    if (!readBufferFromFileLocked(SAVED_FACES_PATH, contentBuf, fileSize)) {
        sendErrorReply(c, seq, 500, String(cmdName) + ": saved_faces.json not found or unreadable");
        return;
    }
    PsramJsonDocument doc(savedFacesJsonCapacityFor(fileSize) + 8192);
    // Deserialize in copy mode (const char*) so doc's string storage is independent
    // of contentBuf: zero-copy mode (non-const char*) would leave doc's strings
    // pointing into contentBuf, which is freed below (item A2: use-after-free).
    DeserializationError de = deserializeJson(doc, (const char*)contentBuf, fileSize, DeserializationOption::NestingLimit(32));
    free(contentBuf);
    if (de) {
        sendErrorReply(c, seq, 500, String(cmdName) + ": saved_faces.json parse failed: " + de.c_str());
        return;
    }

    int errCode = 400;
    String errMsg;
    if (!mutate(doc, errCode, errMsg)) {
        sendErrorReply(c, seq, errCode ? errCode : 400, errMsg);
        return;
    }

    String err;
    if (!validateSavedFaces(doc.as<JsonVariant>(), err)) {
        sendErrorReply(c, seq, 400, err);
        return;
    }
    if (measureJson(doc) > MAX_FACES_DOCUMENT_BYTES) {
        sendErrorReply(c, seq, 413, "saved_faces.json exceeds firmware size limit");
        return;
    }
    size_t written = writeSavedFaces(doc.as<JsonVariant>(), err);
    if (written == 0) {
        sendErrorReply(c, seq, 500, err);
        return;
    }
    loadSavedFaces(false);
    touchRuntimeState();

    const size_t count = doc["faces"].as<JsonArray>().size();
    DynamicJsonDocument out(160);
    out["ok"] = true;
    out["v"] = runtimeStateVersion();
    out["gen"] = savedFacesGeneration();
    out["count"] = count;
    sendJsonReply(c, msg::CMD, seq, out);
}

static bool parseFaceFrameInput(JsonVariant faceIn, uint8_t* out, String& error) {
    if (faceIn["frameHex"].is<const char*>()) {
        const char* hex = faceIn["frameHex"].as<const char*>();
        const size_t hexLen = hex ? strlen(hex) : 0;
        if (hexLen != (size_t)FRAME_BYTES * 2) {
            error = "face.frameHex must be 94 hex chars";
            return false;
        }
        for (size_t i = 0; i < FRAME_BYTES; ++i) {
            const int hi = hexNibble(hex[i * 2]);
            const int lo = hexNibble(hex[i * 2 + 1]);
            if (hi < 0 || lo < 0) {
                error = "face.frameHex contains invalid hex digit";
                return false;
            }
            out[i] = static_cast<uint8_t>((hi << 4) | lo);
        }
    } else if (faceIn["frameBytes"].is<JsonArray>()) {
        JsonArray bytes = faceIn["frameBytes"].as<JsonArray>();
        if (bytes.size() != FRAME_BYTES) {
            error = String("face.frameBytes must contain ") + FRAME_BYTES + " bytes";
            return false;
        }
        size_t i = 0;
        for (JsonVariant v : bytes) {
            if (!v.is<int>()) {
                error = "face.frameBytes entries must be 0..255";
                return false;
            }
            const int iv = v.as<int>();
            if (iv < 0 || iv > 255) {
                error = "face.frameBytes entries must be 0..255";
                return false;
            }
            out[i++] = static_cast<uint8_t>(iv);
        }
    } else {
        error = "face requires frameHex or frameBytes";
        return false;
    }
    return validatePackedFrame(out, error);
}

static String millisBase36() {
    uint32_t v = millis();
    char buf[14];
    int i = static_cast<int>(sizeof(buf)) - 1;
    buf[i--] = '\0';
    static const char kDigits[] = "0123456789abcdefghijklmnopqrstuvwxyz";
    if (v == 0) {
        buf[i--] = '0';
    } else {
        while (v > 0 && i >= 0) {
            buf[i--] = kDigits[v % 36];
            v /= 36;
        }
    }
    return String(&buf[i + 1]);
}

static void handleFaceRename(ClientSlot& c, uint8_t seq, JsonDocument& d, JsonVariant p) {
    const String id = cstr(d, p, "id", "");
    const String name = cstr(d, p, "name", "");
    if (id.isEmpty()) {
        sendErrorReply(c, seq, 400, "id is required");
        return;
    }
    if (name.length() < 1 || name.length() > MAX_FACE_NAME_BYTES) {
        sendErrorReply(c, seq, 400, "name must be 1..64 chars");
        return;
    }
    mutateFacesDocument(c, seq, "face_rename", [&](PsramJsonDocument& doc, int& errCode, String& errMsg) -> bool {
        JsonArray faces = doc["faces"].as<JsonArray>();
        for (JsonObject face : faces) {
            if (id == (const char*)(face["id"] | "")) {
                face["name"] = name;
                face["updatedAtMs"] = millis();
                return true;
            }
        }
        errCode = 404;
        errMsg = "unknown face id";
        return false;
    });
}

static void handleFaceReorder(ClientSlot& c, uint8_t seq, JsonDocument& d, JsonVariant p) {
    JsonVariant idsVar = (!p.isNull() && !p["ids"].isNull()) ? p["ids"].as<JsonVariant>() : d["ids"].as<JsonVariant>();
    JsonArray ids = idsVar.as<JsonArray>();
    if (ids.isNull()) {
        sendErrorReply(c, seq, 400, "ids array is required");
        return;
    }
    mutateFacesDocument(c, seq, "face_reorder", [&](PsramJsonDocument& doc, int& errCode, String& errMsg) -> bool {
        JsonArray faces = doc["faces"].as<JsonArray>();
        const size_t faceCount = faces.size();
        if (faceCount > MAX_AUTO_FACES) {
            errCode = 413;
            errMsg = "too many faces on disk for reorder";
            return false;
        }
        if (ids.size() != faceCount) {
            errCode = 400;
            errMsg = "ids must list every face exactly once";
            return false;
        }
        bool used[MAX_AUTO_FACES] = {false};
        int32_t order = 1;
        for (JsonVariant idVar : ids) {
            if (!idVar.is<const char*>()) {
                errCode = 400;
                errMsg = "ids must be strings";
                return false;
            }
            const char* wantId = idVar.as<const char*>();
            bool found = false;
            size_t idx = 0;
            for (JsonObject face : faces) {
                if (!used[idx] && strcmp(face["id"] | "", wantId) == 0) {
                    face["order"] = order;
                    used[idx] = true;
                    found = true;
                    break;
                }
                ++idx;
            }
            if (!found) {
                errCode = 400;
                errMsg = String("ids must list every face exactly once (bad id: ") + wantId + ")";
                return false;
            }
            ++order;
        }
        if (doc.containsKey("updatedAt"))
            doc["updatedAt"] = (uint32_t)millis();
        return true;
    });
}

static void handleFaceDelete(ClientSlot& c, uint8_t seq, JsonDocument& d, JsonVariant p) {
    const String id = cstr(d, p, "id", "");
    if (id.isEmpty()) {
        sendErrorReply(c, seq, 400, "id is required");
        return;
    }
    mutateFacesDocument(c, seq, "face_delete", [&](PsramJsonDocument& doc, int& errCode, String& errMsg) -> bool {
        JsonArray faces = doc["faces"].as<JsonArray>();
        int foundIdx = -1;
        int defaultCount = 0;
        size_t idx = 0;
        for (JsonObject face : faces) {
            if (strcmp(face["type"] | "", "default") == 0)
                ++defaultCount;
            if (foundIdx < 0 && id == (const char*)(face["id"] | ""))
                foundIdx = (int)idx;
            ++idx;
        }
        if (foundIdx < 0) {
            errCode = 404;
            errMsg = "unknown face id";
            return false;
        }
        JsonObject target = faces[foundIdx];
        const bool targetIsDefault = strcmp(target["type"] | "", "default") == 0;
        if (targetIsDefault) {
            errCode = 400;
            errMsg = "cannot delete a default face";
            return false;
        }
        const int remainingDefaults = defaultCount - (targetIsDefault ? 1 : 0);
        if (remainingDefaults <= 0) {
            errCode = 400;
            errMsg = "cannot remove the last default face";
            return false;
        }
        faces.remove(foundIdx);
        return true;
    });
}

static void handleFaceUpsert(ClientSlot& c, uint8_t seq, JsonDocument& d, JsonVariant p) {
    JsonVariant faceIn = (!p.isNull() && !p["face"].isNull()) ? p["face"].as<JsonVariant>() : d["face"].as<JsonVariant>();
    if (faceIn.isNull()) {
        sendErrorReply(c, seq, 400, "face object is required");
        return;
    }
    const char* type = faceIn["type"] | "";
    if (strcmp(type, "custom") != 0 && strcmp(type, "parts") != 0) {
        sendErrorReply(c, seq, 400, "face.type must be custom or parts");
        return;
    }
    const char* name = faceIn["name"] | "";
    const size_t nameBytes = strlen(name);
    if (nameBytes < 1 || nameBytes > MAX_FACE_NAME_BYTES) {
        sendErrorReply(c, seq, 400, "face.name must be 1..64 bytes");
        return;
    }
    uint8_t frame[FRAME_BYTES];
    String ferr;
    if (!parseFaceFrameInput(faceIn, frame, ferr)) {
        sendErrorReply(c, seq, 400, ferr);
        return;
    }
    const char* idIn = faceIn["id"] | "";
    const String nameStr(name);
    const String typeStr(type);
    const String idInStr(idIn);
    JsonVariant callIn = faceIn["call"];
    const char* savedAt = faceIn["savedAt"] | "";
    const String savedAtStr(savedAt);

    mutateFacesDocument(c, seq, "face_upsert", [&](PsramJsonDocument& doc, int& errCode, String& errMsg) -> bool {
        JsonArray faces = doc["faces"].as<JsonArray>();
        JsonObject existing;
        int32_t maxOrder = 0;
        for (JsonObject face : faces) {
            const int32_t ord = face["order"].is<int32_t>() ? face["order"].as<int32_t>() : 0;
            if (ord > maxOrder)
                maxOrder = ord;
            if (!idInStr.isEmpty() && idInStr == (const char*)(face["id"] | ""))
                existing = face;
        }
        if (!idInStr.isEmpty() && !existing.isNull()) {
            if (strcmp(existing["type"] | "", "default") == 0) {
                errCode = 400;
                errMsg = "cannot overwrite a default face";
                return false;
            }
            existing["name"] = nameStr;
            existing["type"] = typeStr;
            existing.remove("frameHex");
            JsonArray fb = existing.createNestedArray("frameBytes");
            fb.clear();
            for (size_t i = 0; i < FRAME_BYTES; ++i)
                fb.add(frame[i]);
            existing.remove("call");
            if (!callIn.isNull())
                existing["call"] = callIn;
            existing["updatedAtMs"] = (uint32_t)millis();
            return true;
        }
        if (faces.size() >= MAX_AUTO_FACES) {
            errCode = 413;
            errMsg = String("too many faces; firmware max is ") + MAX_AUTO_FACES;
            return false;
        }
        JsonObject nf = faces.createNestedObject();
        const String newId = !idInStr.isEmpty() ? idInStr : (String("custom_") + millisBase36());
        nf["id"] = newId;
        nf["name"] = nameStr;
        nf["type"] = typeStr;
        JsonArray fb = nf.createNestedArray("frameBytes");
        for (size_t i = 0; i < FRAME_BYTES; ++i)
            fb.add(frame[i]);
        if (!callIn.isNull())
            nf["call"] = callIn;
        nf["order"] = maxOrder + 1;
        nf["editable"] = true;
        nf["deletable"] = true;
        nf["locked"] = false;
        nf["is_startup_default"] = false;
        nf["sourceFile"] = "saved_faces.json";
        nf["savedAtMs"] = (uint32_t)millis();
        if (!savedAtStr.isEmpty())
            nf["savedAt"] = savedAtStr;
        return true;
    });
}

static void handleFacesClearUser(ClientSlot& c, uint8_t seq) {
    mutateFacesDocument(c, seq, "faces_clear_user", [](PsramJsonDocument& doc, int& errCode, String& errMsg) -> bool {
        (void)errCode;
        (void)errMsg;
        JsonArray faces = doc["faces"].as<JsonArray>();
        for (int i = (int)faces.size() - 1; i >= 0; --i) {
            JsonObject face = faces[i];
            if (strcmp(face["type"] | "", "default") != 0)
                faces.remove(i);
        }
        return true;
    });
}

static void handleCmd(ClientSlot& c, uint8_t seq, const uint8_t* payload, uint16_t len) {
    // clock_sample (§1.3) wants rxUs "as early as possible when the command is
    // dispatched"; sampling here (before JSON parsing) is the earliest point at
    // which handleCmd is entered for every command, not just clock_sample.
    const uint64_t cmdRxUs = static_cast<uint64_t>(esp_timer_get_time());
    if (len == 0) {
        sendErrorReply(c, seq, 400, "empty CMD payload");
        return;
    }
    constexpr size_t kCmdDocCeiling = (size_t)MAX_SCROLL_TEXT_BYTES + 4096;
    const size_t cmdDocCap = (size_t)len * 3U + 512U;
    PsramJsonDocument d(cmdDocCap < kCmdDocCeiling ? cmdDocCap : kCmdDocCeiling);
    DeserializationError e = deserializeJson(d, payload, len);
    if (e) {
        sendErrorReply(c, seq, 400, String("invalid JSON: ") + e.c_str());
        return;
    }
    const char* cmd = d["cmd"] | "";
    JsonVariant p = d["payload"];
    RLOG_INFO("PROTO", "event=command slot=%u seq=%u name=%s bytes=%u",
              static_cast<unsigned>(&c - g_clients), static_cast<unsigned>(seq), cmd,
              static_cast<unsigned>(len));

    if (strncmp(cmd, "wifi_", 5) == 0) {
        handleWifiCmd(c, seq, cmd, d, p);
        return;
    }
    if (strcmp(cmd, "get_info") == 0) {
        handleGetInfo(c, seq);
        return;
    }
    // Board group v1 (docs/BOARD_GROUP_SPEC.md §1.3): cheap, never rate-limited
    // or coalesced -- answered directly here, not through the ok/err chain below.
    if (strcmp(cmd, "clock_sample") == 0) {
        DynamicJsonDocument out(160);
        out["ok"] = true;
        out["rxUs"] = cmdRxUs;
        out["txUs"] = static_cast<uint64_t>(esp_timer_get_time());
        out["bootId"] = boardBootId();
        sendJsonReply(c, msg::CMD, seq, out);
        return;
    }
    // §1.2: a render overlay, not board state -- no touchRuntimeState() call,
    // matching set_hint_led's style below.
    if (strcmp(cmd, "identify") == 0) {
        const int number = cint(d, p, "number", -1);
        const int ttlMs = cint(d, p, "ttlMs", 5000);
        if (number < 1 || number > 9 || ttlMs < 0 || ttlMs > 30000) {
            ++runtimeState().commandsRejected;
            sendErrorReply(c, seq, 400, "identify requires number 1..9 and ttlMs 0..30000");
            return;
        }
        setIdentifyOverlay(number, ttlMs);
        ++runtimeState().commandsAccepted;
        StaticJsonDocument<96> out;
        out["ok"] = true;
        out["shown"] = ttlMs > 0;
        out["number"] = number;
        out["ttlMs"] = ttlMs;
        sendJsonReply(c, msg::CMD, seq, out);
        return;
    }
    // §1.5: enter/re-anchor group-timed playback.
    if (strcmp(cmd, "group_start") == 0) {
        const char* bootId = cstr(d, p, "bootId", "");
        if (strcmp(bootId, boardBootId()) != 0) {
            ++runtimeState().commandsRejected;
            sendErrorReply(c, seq, 409, "boot_mismatch");
            return;
        }
        // F4: atUs must be an explicit unsigned integer -- a missing or
        // wrong-typed atUs silently defaulting to 0 (via cu64()) would anchor
        // the schedule at time zero instead of being rejected. Check it on
        // whichever object (payload or top-level) the other fields are read
        // from, same selection cu64()/cint() use.
        JsonVariant atUsSrc = (!p.isNull() && !p["atUs"].isNull()) ? p["atUs"] : d["atUs"];
        const int intervalMs = cint(d, p, "intervalMs", -1);
        const int startFrame = cint(d, p, "startFrame", 0);
        const bool loop = cbool(d, p, "loop", true);
        if (!atUsSrc.is<uint64_t>() || intervalMs < 20 || intervalMs > 2000 ||
            startFrame < 0 || startFrame > 65535) {
            ++runtimeState().commandsRejected;
            sendErrorReply(c, seq, 400,
                           "group_start requires atUs (u64), intervalMs 20..2000, startFrame 0..65535");
            return;
        }
        const uint64_t atUs = cu64(d, p, "atUs", 0);
        const uint16_t frameCount = runtimeState().scrollFrameCount;
        if (frameCount > 0 && static_cast<uint32_t>(startFrame) > static_cast<uint32_t>(frameCount - 1)) {
            ++runtimeState().commandsRejected;
            sendErrorReply(c, seq, 400, "startFrame exceeds frameCount-1");
            return;
        }
        if (!scrollSessionGroupStart(atUs, static_cast<uint16_t>(startFrame),
                                     static_cast<uint16_t>(intervalMs), loop)) {
            ++runtimeState().commandsRejected;
            sendErrorReply(c, seq, 409, "no_timeline");
            return;
        }
        ++runtimeState().commandsAccepted;
        DynamicJsonDocument out(128);
        out["ok"] = true;
        out["nowUs"] = static_cast<uint64_t>(esp_timer_get_time());
        out["frameCount"] = runtimeState().scrollFrameCount;
        sendJsonReply(c, msg::CMD, seq, out);
        return;
    }
    if (strcmp(cmd, "reboot") == 0) {
        g_rebootPending = true;
        g_rebootAtMs = millis() + 200;
        DynamicJsonDocument out(64);
        out["ok"] = true;
        sendJsonReply(c, msg::CMD, seq, out);
        return;
    }
    if (strcmp(cmd, "subscribe") == 0 || strcmp(cmd, "log_subscribe") == 0) {
        if (strcmp(cmd, "log_subscribe") == 0) {
            c.subLog = cbool(d, p, "on", c.subLog);
        } else {
            if (!p.isNull() && p["preview"].is<bool>()) c.subPreview = p["preview"].as<bool>();
            else if (d["preview"].is<bool>()) c.subPreview = d["preview"].as<bool>();
            if (!p.isNull() && p["status"].is<bool>()) c.subStatus = p["status"].as<bool>();
            else if (d["status"].is<bool>()) c.subStatus = d["status"].as<bool>();
            if (!p.isNull() && p["power"].is<bool>()) c.subPower = p["power"].as<bool>();
            else if (d["power"].is<bool>()) c.subPower = d["power"].as<bool>();
            if (!p.isNull() && p["log"].is<bool>()) c.subLog = p["log"].as<bool>();
            else if (d["log"].is<bool>()) c.subLog = d["log"].as<bool>();
        }
        DynamicJsonDocument out(128);
        out["ok"] = true;
        sendJsonReply(c, msg::CMD, seq, out);
        return;
    }
    if (strcmp(cmd, "face_rename") == 0) {
        handleFaceRename(c, seq, d, p);
        return;
    }
    if (strcmp(cmd, "face_reorder") == 0) {
        handleFaceReorder(c, seq, d, p);
        return;
    }
    if (strcmp(cmd, "face_delete") == 0) {
        handleFaceDelete(c, seq, d, p);
        return;
    }
    if (strcmp(cmd, "face_upsert") == 0) {
        handleFaceUpsert(c, seq, d, p);
        return;
    }
    if (strcmp(cmd, "faces_clear_user") == 0) {
        handleFacesClearUser(c, seq);
        return;
    }

    if (strcmp(cmd, "set_device_name") == 0) {
        // Absent/null `name` clears the override and restores the MAC default.
        const char* requested = cstr(d, p, "name", "");
        String nameErr;
        if (!bleTransportSetDeviceName(requested, nameErr)) {
            ++runtimeState().commandsRejected;
            touchRuntimeStateSlow();
            sendErrorReply(c, seq, 400, nameErr);
            return;
        }
        const bool persisted = saveRuntimeSettings();
        char effective[MAX_DEVICE_NAME_BYTES + 1];
        bleTransportDeviceName(effective, sizeof(effective));
        ++runtimeState().commandsAccepted;
        touchRuntimeState();
        DynamicJsonDocument out(256);
        out["ok"] = true;
        out["name"] = effective;
        out["customName"] = runtimeState().deviceName.length() > 0;
        // Report persistence separately: the name is already live over BLE even
        // if LittleFS was unavailable, but it would not survive a reboot.
        out["persisted"] = persisted;
        sendJsonReply(c, msg::CMD, seq, out);
        return;
    }

    // Sent on every LED a hovering pencil crosses: answered with a bare ack,
    // not the status document, and it is not board state, so no state bump.
    if (strcmp(cmd, "set_hint_led") == 0) {
        int led = cint(d, p, "led", -1);
        // Range first, so a bad LED is a 400 in every output mode.
        if (led < -1 || led >= static_cast<int>(LED_COUNT)) {
            ++runtimeState().commandsRejected;
            sendErrorReply(c, seq, 400, "led must be -1 or 0.." + String(LED_COUNT - 1));
            return;
        }
        bool shown = false;
        const bool isControlOutput = runtimeState().outputMode == "control";
        if (led >= 0 && !isControlOutput) {
            // Only the control output shows the hint LED; silently decline
            // without touching the renderer while another output owns it.
            shown = false;
        } else {
            String hintErr;
            if (!setHintLed(led, static_cast<uint8_t>(&c - g_clients), hintErr)) {
                ++runtimeState().commandsRejected;
                sendErrorReply(c, seq, 400, hintErr);
                return;
            }
            shown = (led >= 0) && isControlOutput;
        }
        ++runtimeState().commandsAccepted;
        StaticJsonDocument<48> out;
        out["ok"] = true;
        out["shown"] = shown;
        sendJsonReply(c, msg::CMD, seq, out);
        return;
    }

    String err;
    bool ok = true;
    if (strcmp(cmd, "set_color") == 0)
        ok = setColor(cstr(d, p, "hex", ""), err);
    else if (strcmp(cmd, "set_brightness") == 0)
        setBrightness(cint(d, p, "raw", cint(d, p, "brightness", DEFAULT_BRIGHTNESS)));
    else if (strcmp(cmd, "set_mode") == 0) {
        ok = setMode(cstr(d, p, "mode", DEFAULT_MODE), true);
        if (ok)
            stopFirmwareScroll(false, false, false);
    }
    else if (strcmp(cmd, "set_auto_interval") == 0)
        setAutoInterval((uint32_t)cint(d, p, "ms", DEFAULT_AUTO_INTERVAL_MS), true);
    else if (strcmp(cmd, "set_scroll_interval") == 0) {
        uint16_t interval = cScrollInterval(d, p);
        scrollSessionSetInterval(interval, cUiFps(d, p, interval));
    } else if (strcmp(cmd, "start_scroll") == 0) {
        uint16_t interval = cScrollInterval(d, p);
        uint8_t uiFps = cUiFps(d, p, interval);
        const char* st = cstr(d, p, "sourceText", nullptr);
        if (st && st[0]) {
            size_t sl = strlen(st);
            if (sl > MAX_SCROLL_TEXT_BYTES) {
                sendErrorReply(c, seq, 413, "sourceText too large");
                return;
            }
            scrollSessionSetSourceText(st, (uint16_t)sl);
        }
        if ((!p.isNull() && p["loop"].is<bool>()) || d["loop"].is<bool>())
            scrollSessionSetLoop(cbool(d, p, "loop", true));
        startFirmwareScroll(interval, uiFps);
    } else if (strcmp(cmd, "set_scroll_loop") == 0) {
        scrollSessionSetLoop(cbool(d, p, "loop", true));
    } else if (strcmp(cmd, "scroll_step") == 0) {
        uint8_t f[FRAME_BYTES];
        if (scrollSessionStep(cint(d, p, "direction", 1) < 0 ? -1 : 1, f)) {
            clearQueuedPackedFrames();
            LedPresentationContext stepCtx;
            scrollSessionFillPresentationContext(stepCtx, LedPresentationSource::ScrollStep, "firmware_text_scroll_step", false);
            applyPackedFrameImmediate(f, "firmware_text_scroll_step", &stepCtx);
        }
    } else if (strcmp(cmd, "scroll_seek") == 0) {
        scrollSessionSeek(static_cast<uint16_t>(constrain(cint(d, p, "frameIndex", 0), 0, 0xFFFF)));
    } else if (strcmp(cmd, "pause_scroll") == 0)
        scrollSessionSetUserPaused(true);
    else if (strcmp(cmd, "resume_scroll") == 0) {
        scrollSessionRewindIfEnded();
        scrollSessionSetUserPaused(false);
    } else if (strcmp(cmd, "stop_scroll") == 0)
        stopFirmwareScroll(cbool(d, p, "restoreAuto", scrollSessionGetRestoreAuto()), cbool(d, p, "clear", true), true);
    else if (strcmp(cmd, "pause") == 0) {
        runtimeState().paused = true;
        runtimeState().playback = "paused";
        touchRuntimeState();
    } else if (strcmp(cmd, "resume") == 0) {
        scrollSessionRewindIfEnded();
        scrollSessionSetUserPaused(false);
        runtimeState().paused = false;
        runtimeState().playback = DEFAULT_PLAYBACK;
        touchRuntimeState();
    } else if (strcmp(cmd, "apply_saved_face") == 0) {
        stopFirmwareScroll(false, false, false);
        setMode("manual", false);
        scrollSessionSetRestoreAuto(false);
        const int index = cint(d, p, "index", runtimeState().autoFaceIndex);
        ok = applySavedFaceIndex(
            static_cast<uint16_t>(index < 0 ? 0 : index),
            String(cstr(d, p, "reason", "rinalink_apply_saved_face")),
            cstr(d, p, "playback", DEFAULT_PLAYBACK));
    } else if (strcmp(cmd, "button") == 0) {
        // §1.5: a button always ends group-timed playback, even if this
        // particular button does not itself stop/replace the scroll.
        scrollSessionExitGroupTimed();
        ok = runButtonAction(String(cstr(d, p, "button", "")), "rinalink");
    }
    else if (strcmp(cmd, "terminate_other_activities") == 0) {
        stopFirmwareScroll(false, true, false);
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
        sendErrorReply(c, seq, 400, err);
        return;
    }
    ++runtimeState().commandsAccepted;
    touchRuntimeState();
    DynamicJsonDocument out(2048);
    reply(out, cmd);
    sendJsonReply(c, msg::CMD, seq, out);
}

// --- GET_* handlers ------------------------------------------------------------------
static void handleGetStatus(ClientSlot& c, uint8_t seq, const uint8_t* payload, uint16_t len) {
    bool lite = false;
    if (len > 0) {
        StaticJsonDocument<128> d;
        if (!deserializeJson(d, payload, len))
            lite = d["lite"] | false;
    }
    PsramJsonDocument d(lite ? 1536 : 3072);
    buildStatusJson(d, lite);
    sendJsonReply(c, msg::GET_STATUS, seq, d);
}

static void handleGetPower(ClientSlot& c, uint8_t seq) {
    DynamicJsonDocument d(1024);
    d["ok"] = true;
    addPower(d.createNestedObject("power"));
    sendJsonReply(c, msg::GET_POWER, seq, d);
}

static void handleGetScrollMeta(ClientSlot& c, uint8_t seq) {
    const size_t textCap = static_cast<size_t>(MAX_SCROLL_TEXT_BYTES) + 1U;
    char* text = static_cast<char*>(heap_caps_malloc(textCap, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (!text)
        text = static_cast<char*>(malloc(textCap));
    if (!text) {
        sendErrorReply(c, seq, 507, "insufficient memory for scroll meta");
        return;
    }
    PsramJsonDocument d(static_cast<size_t>(MAX_SCROLL_TEXT_BYTES) + 2048);
    ScrollMetaOut o;
    bool copied = scrollSessionCopyMeta(o, text, textCap);
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
    d["firmwareScrollUserPaused"] = o.userPaused;
    d["firmwareScrollSystemPaused"] = o.systemPaused;
    d["scrollLoop"] = o.loop;
    d["groupTimed"] = o.groupTimed;

    // The serialized JSON (sourceText up to 4 KB) can exceed MAX_PAYLOAD_BYTES;
    // emitJson (via sendJsonReply) spans it across multiple FLAG_MORE frames as
    // needed (item 2).
    sendJsonReply(c, msg::GET_SCROLL_META, seq, d);
    free(text);
}

static void buildPreviewSyncJson(JsonDocument& d) {
    // Presentation identity/timing comes from the last successful LED latch.
    // Control flags come from a fresh scroll-lock snapshot because pause/loop
    // commands do not themselves render a frame and would otherwise leave the
    // reply advertising stale state until the next presentation.
    ScrollSessionSnapshot live = scrollSessionSnapshot();
    FrameStateSnapshot fs = readFrameStateSnapshot();
    // Read the latch sample last, immediately before sampledAtUs, so a Core-1
    // tick concurrent with the slower state snapshots cannot make the reply
    // one presentation older than necessary.
    LedPresentedSample s = readLedPresentedSample();
    const uint64_t sampledAtUs = static_cast<uint64_t>(esp_timer_get_time());
    d["ok"] = true;
    d["v"] = runtimeStateVersion();
    d["mode"] = runtimeState().mode;
    d["outputMode"] = runtimeState().outputMode;
    d["outputStreamID"] = runtimeState().outputStreamID;
    d["outputPositionMs"] = runtimeState().outputPositionMs;
    d["playback"] = runtimeState().playback;
    d["autoFaceIndex"] = runtimeState().autoFaceIndex;
    d["autoFaceCount"] = runtimeAutoFaceCount();
    d["lastReason"] = fs.lastReason;
    d["valid"] = s.valid;
    d["presentedSeq"] = s.presentedSeq;
    d["scrollAdvanceSeq"] = s.scrollAdvanceSeq;
    d["source"] = ledPresentationSourceName(s.source);
    d["reason"] = s.reason;
    d["scrollTimelineId"] = s.timelineId;
    d["presentedFrameIndex"] = s.presentedFrameIndex;
    d["presentedFrameCount"] = s.presentedFrameCount;
    d["frameIndex"] = s.presentedFrameIndex;
    d["frameCount"] = s.presentedFrameCount;
    d["presentedAtUs"] = s.presentedAtUs;
    d["sampledAtUs"] = sampledAtUs;
    d["renderStartUs"] = s.renderStartUs;
    d["renderDurationUs"] = s.renderDurationUs;
    d["scrollIntervalMs"] = s.nominalIntervalMs;
    d["uiFps"] = s.uiFps;
    d["firmwareScrollActive"] = live.firmwareScrollActive;
    d["firmwareScrollPaused"] = live.firmwareScrollPaused;
    d["firmwareScrollUserPaused"] = live.firmwareScrollUserPaused;
    d["firmwareScrollSystemPaused"] = live.firmwareScrollSystemPaused;
    d["scrollLoop"] = live.scrollLoop;
    d["groupTimed"] = live.groupTimed;
    d["rateEligible"] = s.rateEligible;
}

static void handleGetPreviewSync(ClientSlot& c, uint8_t seq) {
    DynamicJsonDocument d(1280);
    buildPreviewSyncJson(d);
    sendJsonReply(c, msg::GET_PREVIEW_SYNC, seq, d);
}

static void handlePing(ClientSlot& c, uint8_t seq) {
    DynamicJsonDocument d(96);
    d["ok"] = true;
    d["uptimeMs"] = millis() - runtimeState().bootMs;
    sendJsonReply(c, msg::PING, seq, d);
}

// --- SET_FRAME / GET_FRAME (binary, §3.2) ---------------------------------------------
static const char* playbackForEnum(uint8_t v) {
    switch (v) {
    case 0: return "idle";
    case 1: return "paused";
    case 2: return "scroll";
    case 3: return "auto";
    default: return DEFAULT_PLAYBACK;
    }
}

static void handleSetFrame(ClientSlot& c, uint8_t seq, const uint8_t* payload, uint16_t len) {
    if (len < 2) {
        sendErrorReply(c, seq, 400, "SET_FRAME payload too short");
        return;
    }
    uint8_t playbackEnum = payload[0];
    uint8_t reasonLen = payload[1];
    if (len < (size_t)2 + reasonLen + FRAME_BYTES) {
        sendErrorReply(c, seq, 400, "SET_FRAME payload truncated");
        return;
    }
    String reason;
    if (reasonLen)
        reason = String(reinterpret_cast<const char*>(payload + 2), reasonLen);
    else
        reason = "rinalink_frame";
    const uint8_t* frameBits = payload + 2 + reasonLen;

    String err;
    if (!validatePackedFrame(frameBits, err)) {
        ++runtimeState().framesRejected;
        touchRuntimeStateSlow();
        sendErrorReply(c, seq, 400, err);
        return;
    }
    String playback = playbackForEnum(playbackEnum);
    // SET_FRAME is an externally driven stream in every playback enum. It
    // replaces firmware scroll/auto ownership regardless of a caller's reason.
    takeOverExternalFrame();
    runtimeState().playback = playback;
    if (!applyPackedFrameQueued(frameBits, reason, err)) {
        sendErrorReply(c, seq, 400, err);
        return;
    }
    setRuntimeOutputFromFrameReason(reason.c_str());
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
    sendJsonReply(c, msg::SET_FRAME, seq, d);
}

static void handleGetFrame(ClientSlot& c, uint8_t seq) {
    uint8_t f[FRAME_BYTES];
    withFrameLock([&]() { memcpy(f, runtimeFrameBits(), FRAME_BYTES); });
    sendFrame(c, static_cast<uint8_t>(msg::GET_FRAME | 0x80), seq, 0, f, FRAME_BYTES);
}

// --- Blob handlers (§3.3) --------------------------------------------------------------
constexpr size_t MAX_FACES_BLOB_BYTES = MAX_FACES_DOCUMENT_BYTES;

static void handleBlobBegin(ClientSlot& c, uint8_t seq, const uint8_t* payload, uint16_t len) {
    expireBlobSessions();
    resetBlob(c);
    int selfSlot = static_cast<int>(&c - g_clients);
    if (len == 0) {
        resetBlob(c);
        sendErrorReply(c, seq, 400, "empty BLOB_BEGIN payload");
        return;
    }
    PsramJsonDocument d(jsonCapacityFor(len));
    if (deserializeJson(d, payload, len)) {
        resetBlob(c);
        sendErrorReply(c, seq, 400, "invalid BLOB_BEGIN JSON");
        return;
    }
    const char* kind = d["kind"] | "";
    uint32_t totalBytes = d["totalBytes"] | 0;
    uint16_t chunkMax = c.transport->preferredChunkBytes(ClientId{static_cast<uint8_t>(selfSlot)});
    if (chunkMax == 0 || chunkMax > 4032)
        chunkMax = 4032;

    if (strcmp(kind, "scroll") == 0) {
        // Item 10: only one client may hold an in-progress scroll upload at a time.
        if (g_activeScrollBlobSlot != -1 && g_activeScrollBlobSlot != selfSlot) {
            resetBlob(c);
            sendErrorReply(c, seq, 409, "scroll upload already in progress");
            return;
        }
        if (!runtimeScrollFrameBufferReady()) {
            resetBlob(c);
            sendErrorReply(c, seq, 507, "scroll frame buffer unavailable");
            return;
        }
        bool append = d["append"] | false;
        JsonVariant noPayload;
        uint16_t interval = cScrollInterval(d, noPayload);
        uint8_t uiFps = cUiFps(d, noPayload, interval);
        uint32_t implied = totalBytes / FRAME_BYTES;
        uint32_t totalFrames = d["totalFrames"] | (append ? runtimeState().scrollFrameCount + implied : implied);
        if (totalFrames > MAX_SCROLL_FRAMES) {
            resetBlob(c);
            sendErrorReply(c, seq, 413, "too many scroll frames");
            return;
        }
        // Gather + validate everything (including sourceText length) BEFORE marking
        // the session live, so a validation failure never leaves c.blob.kind set to
        // Scroll with a half-initialized txn (item 5: BLOB_CHUNK would otherwise
        // write into the live scroll buffer after a failed BLOB_BEGIN).
        const char* tid = d["timelineId"] | "";
        const char* fid = d["fontId"] | "";
        const char* gen = d["generatorVersion"] | "";
        const char* txt = d["sourceText"] | (const char*)nullptr;
        if (!append && txt && strlen(txt) > MAX_SCROLL_TEXT_BYTES) {
            resetBlob(c);
            sendErrorReply(c, seq, 413, "sourceText too large");
            return;
        }
        uint8_t* scrollBuf = static_cast<uint8_t*>(heap_caps_malloc(
            totalBytes ? totalBytes : 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (!scrollBuf)
            scrollBuf = static_cast<uint8_t*>(malloc(totalBytes ? totalBytes : 1));
        if (!scrollBuf) {
            resetBlob(c);
            sendErrorReply(c, seq, 507, "insufficient memory for scroll upload");
            return;
        }
        c.blob.kind = BlobKind::Scroll;
        c.blob.append = append;
        c.blob.hasExplicitTiming = d["intervalMs"].is<int>() || d["fps"].is<int>() || d["uiFps"].is<int>();
        c.blob.intervalMs = interval;
        c.blob.uiFps = uiFps;
        c.blob.totalFrames = (uint16_t)totalFrames;
        c.blob.framesReceived = 0;
        c.blob.expectedOffset = 0;
        c.blob.scrollBuf = scrollBuf;
        c.blob.scrollCap = totalBytes;
        c.blob.scrollTimelineId = tid;
        c.blob.scrollFontId = fid;
        c.blob.scrollGeneratorVersion = gen;
        c.blob.scrollSourceText = txt ? txt : "";
        g_activeScrollBlobSlot = selfSlot;
    } else if (strcmp(kind, "scroll_bitmap") == 0) {
        // Item 10 (shared with kind:"scroll"): only one client may hold an
        // in-progress scroll upload of either kind at a time.
        if (g_activeScrollBlobSlot != -1 && g_activeScrollBlobSlot != selfSlot) {
            resetBlob(c);
            sendErrorReply(c, seq, 409, "scroll upload already in progress");
            return;
        }
        if (!runtimeScrollFrameBufferReady()) {
            resetBlob(c);
            sendErrorReply(c, seq, 507, "scroll frame buffer unavailable");
            return;
        }
        uint32_t width = d["width"] | 0;
        uint32_t rows = d["rows"] | 0;
        if (width < 22 || width > 3093) {
            resetBlob(c);
            sendErrorReply(c, seq, 400, "scroll_bitmap width out of range");
            return;
        }
        if (rows != MATRIX_ROWS) {
            resetBlob(c);
            sendErrorReply(c, seq, 400, "scroll_bitmap rows must be 18");
            return;
        }
        uint32_t stride = (width + 7) / 8;
        if (totalBytes != MATRIX_ROWS * stride) {
            resetBlob(c);
            sendErrorReply(c, seq, 400, "scroll_bitmap totalBytes mismatch");
            return;
        }
        // Board group v1 (§1.4): optional viewport into a wider virtual/stitched
        // screen. Both fields must be present and valid together, else 400.
        const bool hasVirtualWidth = !d["virtualWidth"].isNull();
        const bool hasViewportX = !d["viewportX"].isNull();
        bool hasViewport = false;
        uint32_t virtualWidth = 22;
        uint32_t viewportX = 0;
        if (hasVirtualWidth || hasViewportX) {
            if (!hasVirtualWidth || !hasViewportX) {
                resetBlob(c);
                sendErrorReply(c, seq, 400, "scroll_bitmap viewportX/virtualWidth must both be present");
                return;
            }
            const int vw = d["virtualWidth"] | 0;
            const int vx = d["viewportX"] | -1;
            if (vw < 22 || vw > 200) {
                resetBlob(c);
                sendErrorReply(c, seq, 400, "scroll_bitmap virtualWidth out of range");
                return;
            }
            if (vx < 0 || vx > vw - 22) {
                resetBlob(c);
                sendErrorReply(c, seq, 400, "scroll_bitmap viewportX out of range");
                return;
            }
            if (width < (uint32_t)vw) {
                resetBlob(c);
                sendErrorReply(c, seq, 400, "scroll_bitmap width must be >= virtualWidth");
                return;
            }
            hasViewport = true;
            virtualWidth = (uint32_t)vw;
            viewportX = (uint32_t)vx;
        }
        // frameCount = max(1, width-V) + 1, computed without unsigned underflow.
        // V defaults to 22 (the legacy single-board width) when no viewport is given.
        uint32_t frameCount = group_math::viewportFrameCount(width, virtualWidth);
        if (frameCount > MAX_SCROLL_FRAMES) {
            resetBlob(c);
            sendErrorReply(c, seq, 413, "too many scroll frames");
            return;
        }
        const char* txt = d["sourceText"] | (const char*)nullptr;
        if (txt && strlen(txt) > MAX_SCROLL_TEXT_BYTES) {
            resetBlob(c);
            sendErrorReply(c, seq, 413, "sourceText too large");
            return;
        }
        uint8_t* bmBuf = static_cast<uint8_t*>(heap_caps_malloc(totalBytes ? totalBytes : 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (!bmBuf)
            bmBuf = static_cast<uint8_t*>(malloc(totalBytes ? totalBytes : 1));
        if (!bmBuf) {
            resetBlob(c);
            sendErrorReply(c, seq, 507, "insufficient memory for scroll_bitmap upload");
            return;
        }
        JsonVariant noPayload;
        uint16_t interval = cScrollInterval(d, noPayload);
        uint8_t uiFps = cUiFps(d, noPayload, interval);
        c.blob.kind = BlobKind::ScrollBitmap;
        c.blob.bitmapBuf = bmBuf;
        c.blob.bitmapWidth = (uint16_t)width;
        c.blob.bitmapStride = (uint16_t)stride;
        c.blob.bitmapTotalBytes = totalBytes;
        c.blob.bitmapFrameCount = (uint16_t)frameCount;
        c.blob.bitmapTimelineId = d["timelineId"] | "";
        c.blob.bitmapFontId = d["fontId"] | "";
        c.blob.bitmapGeneratorVersion = d["generatorVersion"] | "";
        c.blob.bitmapSourceText = txt ? txt : "";
        c.blob.hasExplicitTiming = d["intervalMs"].is<int>() || d["fps"].is<int>() || d["uiFps"].is<int>();
        c.blob.intervalMs = interval;
        c.blob.uiFps = uiFps;
        c.blob.expectedOffset = 0;
        c.blob.bitmapHasViewport = hasViewport;
        c.blob.bitmapVirtualWidth = virtualWidth;
        c.blob.bitmapViewportX = viewportX;
        g_activeScrollBlobSlot = selfSlot;
    } else if (strcmp(kind, "faces") == 0) {
        if (totalBytes > MAX_FACES_DOCUMENT_BYTES) {
            resetBlob(c);
            sendErrorReply(c, seq, 413, "faces document too large");
            return;
        }
        uint8_t* buf = static_cast<uint8_t*>(heap_caps_malloc(totalBytes ? totalBytes : 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (!buf)
            buf = static_cast<uint8_t*>(malloc(totalBytes ? totalBytes : 1));
        if (!buf) {
            resetBlob(c);
            sendErrorReply(c, seq, 507, "insufficient memory for faces upload");
            return;
        }
        c.blob.kind = BlobKind::Faces;
        c.blob.facesBuf = buf;
        c.blob.facesCap = totalBytes;
        c.blob.expectedOffset = 0;
    } else {
        resetBlob(c);
        sendErrorReply(c, seq, 400, "unknown blob kind");
        return;
    }
    c.blob.totalBytes = totalBytes;
    c.blob.lastActivityMs = millis();
    c.blob.generation = scrollSessionGeneration();
    DynamicJsonDocument out(128);
    out["ok"] = true;
    out["chunkMax"] = chunkMax;
    out["offset"] = 0; // always 0: BLOB_BEGIN never resumes a prior session.
    sendJsonReply(c, msg::BLOB_BEGIN, seq, out);
}

static void handleBlobChunk(ClientSlot& c, uint8_t seq, const uint8_t* payload, uint16_t len) {
    expireBlobSessions();
    if (c.blob.kind == BlobKind::None) {
        sendErrorReply(c, seq, 400, "no active blob session");
        return;
    }
    if (len < 4) {
        sendErrorReply(c, seq, 400, "BLOB_CHUNK payload too short");
        return;
    }
    uint32_t offset = (uint32_t)payload[0] | ((uint32_t)payload[1] << 8) |
                       ((uint32_t)payload[2] << 16) | ((uint32_t)payload[3] << 24);
    const uint8_t* data = payload + 4;
    uint16_t dataLen = len - 4;
    if (offset != c.blob.expectedOffset) {
        sendErrorReply(c, seq, 400, "unexpected chunk offset", (int32_t)c.blob.expectedOffset);
        return;
    }
    if (static_cast<uint64_t>(offset) + dataLen > c.blob.totalBytes) {
        sendErrorReply(c, seq, 413, "chunk exceeds declared blob size");
        return;
    }
    if (c.blob.kind == BlobKind::Scroll) {
        if (dataLen % FRAME_BYTES != 0) {
            sendErrorReply(c, seq, 400, "scroll chunk must be a multiple of 47 bytes");
            return;
        }
        uint16_t n = dataLen / FRAME_BYTES;
        if ((uint32_t)c.blob.framesReceived + n > c.blob.totalFrames) {
            sendErrorReply(c, seq, 413, "scroll chunk exceeds totalFrames");
            return;
        }
        String err;
        for (uint16_t i = 0; i < n; i++) {
            if (!validatePackedFrame(data + (size_t)i * FRAME_BYTES, err)) {
                sendErrorReply(c, seq, 400, String("invalid scroll frame: ") + err);
                return;
            }
        }
        if (c.blob.expectedOffset + dataLen > c.blob.scrollCap) {
            sendErrorReply(c, seq, 413, "scroll upload too large");
            return;
        }
        memcpy(c.blob.scrollBuf + c.blob.expectedOffset, data, dataLen);
        c.blob.framesReceived += n;
        c.blob.expectedOffset += dataLen;
        c.blob.lastActivityMs = millis();
        DynamicJsonDocument out(128);
        out["ok"] = true;
        out["offset"] = c.blob.expectedOffset;
        out["frames"] = c.blob.framesReceived;
        sendJsonReply(c, msg::BLOB_CHUNK, seq, out);
    } else if (c.blob.kind == BlobKind::ScrollBitmap) {
        if ((uint64_t)c.blob.expectedOffset + dataLen > c.blob.bitmapTotalBytes) {
            sendErrorReply(c, seq, 413, "scroll_bitmap upload too large");
            return;
        }
        memcpy(c.blob.bitmapBuf + c.blob.expectedOffset, data, dataLen);
        c.blob.expectedOffset += dataLen;
        c.blob.lastActivityMs = millis();
        DynamicJsonDocument out(64);
        out["ok"] = true;
        out["offset"] = c.blob.expectedOffset;
        sendJsonReply(c, msg::BLOB_CHUNK, seq, out);
    } else {
        if (c.blob.expectedOffset + dataLen > c.blob.facesCap) {
            sendErrorReply(c, seq, 413, "faces document too large");
            return;
        }
        memcpy(c.blob.facesBuf + c.blob.expectedOffset, data, dataLen);
        c.blob.expectedOffset += dataLen;
        c.blob.lastActivityMs = millis();
        DynamicJsonDocument out(64);
        out["ok"] = true;
        out["offset"] = c.blob.expectedOffset;
        sendJsonReply(c, msg::BLOB_CHUNK, seq, out);
    }
}

// --- scroll_bitmap expansion (§7.1, §1.4) ---------------------------------------------
// Maps a bitmap column `x` (0..21, absolute grid coordinate) at row `y` through the
// centred valid-x-range + logical LED index math (config.h ROW_LENGTHS/ROW_OFFSETS,
// mirrors MatrixGeometry.swift: xStart = (22 - rowLength) / 2, logical index =
// ROW_OFFSETS[y] + (x - xStart)). bitmapViewportX (default 0) folds in the
// board-group viewport offset (§1.4: pixel = (f + X + x, y)) via the same pure
// math used by the host tests.
static inline bool scrollBitmapPixelLit(const BlobSession& b, uint32_t offset, uint8_t x, uint8_t y) {
    uint32_t srcX = 0;
    if (!group_math::viewportColumnFor(offset, b.bitmapViewportX, x, b.bitmapWidth, srcX))
        return false;
    uint32_t byteIndex = (uint32_t)y * b.bitmapStride + (srcX >> 3);
    return ((b.bitmapBuf[byteIndex] >> (srcX & 7)) & 1U) != 0;
}

static bool scrollBitmapFrameHasAnyLit(const BlobSession& b, uint32_t offset) {
    for (uint8_t y = 0; y < MATRIX_ROWS; ++y) {
        const uint8_t rowLength = ROW_LENGTHS[y];
        const uint8_t xStart = (uint8_t)((22 - rowLength) / 2);
        for (uint8_t lx = 0; lx < rowLength; ++lx) {
            if (scrollBitmapPixelLit(b, offset, (uint8_t)(xStart + lx), y))
                return true;
        }
    }
    return false;
}

static void scrollBitmapBuildFrame(const BlobSession& b, uint32_t offset, uint8_t* outFrame) {
    memset(outFrame, 0, FRAME_BYTES);
    for (uint8_t y = 0; y < MATRIX_ROWS; ++y) {
        const uint8_t rowLength = ROW_LENGTHS[y];
        const uint8_t xStart = (uint8_t)((22 - rowLength) / 2);
        const uint16_t rowOffset = ROW_OFFSETS[y];
        for (uint8_t lx = 0; lx < rowLength; ++lx) {
            if (scrollBitmapPixelLit(b, offset, (uint8_t)(xStart + lx), y)) {
                uint16_t idx = rowOffset + lx;
                outFrame[idx >> 3] |= (uint8_t)(1U << (idx & 7));
            }
        }
    }
}

static void handleBlobEnd(ClientSlot& c, uint8_t seq, const uint8_t* payload, uint16_t len) {
    expireBlobSessions();
    if (c.blob.kind == BlobKind::None) {
        sendErrorReply(c, seq, 400, "no active blob session");
        return;
    }
    if (c.blob.expectedOffset != c.blob.totalBytes) {
        resetBlob(c);
        sendErrorReply(c, seq, 400, "incomplete blob upload");
        return;
    }
    bool start = false;
    if (len > 0) {
        StaticJsonDocument<128> d;
        if (!deserializeJson(d, payload, len))
            start = d["start"] | false;
    }
    if (c.blob.kind == BlobKind::Scroll) {
        // BEGIN and CHUNK only fill a PSRAM staging buffer. Replace the live
        // timeline now that the complete upload has been validated.
        if (c.blob.append) {
            c.blob.txn = scrollSessionBeginAppend();
        } else {
            ScrollUploadMeta meta;
            meta.timelineId = c.blob.scrollTimelineId.c_str();
            meta.fontId = c.blob.scrollFontId.c_str();
            meta.generatorVersion = c.blob.scrollGeneratorVersion.c_str();
            meta.sourceText = c.blob.scrollSourceText.length()
                                  ? c.blob.scrollSourceText.c_str() : nullptr;
            meta.sourceTextBytes = (uint16_t)c.blob.scrollSourceText.length();
            meta.totalFrames = c.blob.totalFrames;
            meta.uiFps = c.blob.uiFps;
            c.blob.txn = scrollSessionBeginUpload(meta);
        }
        if (c.blob.framesReceived > 0 &&
            !scrollSessionWriteFrames(c.blob.txn, c.blob.txn.baseIndex,
                                      c.blob.scrollBuf, c.blob.framesReceived)) {
            resetBlob(c);
            sendErrorReply(c, seq, 500, "failed to write scroll frames");
            return;
        }
        ScrollUploadResult res = scrollSessionCommitUpload(c.blob.txn, c.blob.framesReceived,
                                                            c.blob.hasExplicitTiming, c.blob.intervalMs, c.blob.uiFps);
        if (!res.valid) {
            resetBlob(c);
            sendErrorReply(c, seq, 409, "scroll upload was superseded");
            return;
        }
        const bool started = start &&
            startFirmwareScroll(c.blob.intervalMs, c.blob.uiFps);
        ScrollSessionSnapshot snap = scrollSessionSnapshot();
        DynamicJsonDocument out(768);
        out["ok"] = true;
        out["frames"] = res.frameCount;
        out["chunkFrames"] = c.blob.framesReceived;
        out["append"] = c.blob.append;
        out["started"] = started;
        out["timelineId"] = res.timelineId;
        out["uploadComplete"] = res.uploadComplete;
        out["frameBytes"] = FRAME_BYTES;
        out["scrollIntervalMs"] = snap.scrollIntervalMs;
        out["uiFps"] = snap.uiFps;
        out["scrollFps"] = snap.uiFps;
        resetBlob(c);
        sendJsonReply(c, msg::BLOB_END, seq, out);
    } else if (c.blob.kind == BlobKind::ScrollBitmap) {
        if (c.blob.expectedOffset != c.blob.bitmapTotalBytes) {
            resetBlob(c);
            sendErrorReply(c, seq, 400, "incomplete scroll_bitmap upload");
            return;
        }
        if (!runtimeScrollFrameBufferReady()) {
            resetBlob(c);
            sendErrorReply(c, seq, 507, "scroll frame buffer unavailable");
            return;
        }
        const uint16_t frameCount = c.blob.bitmapFrameCount;

        // Rotate so index 0 is the first frame with any lit LED (0 if nothing lit).
        // §1.4: viewport uploads never rotate (every board must show frame f at
        // the same instant; rotating would desync the group), so rotation stays 0.
        uint32_t t0 = micros();
        uint16_t rotation = 0;
        if (!c.blob.bitmapHasViewport) {
            for (uint16_t i = 0; i < frameCount; ++i) {
                if (scrollBitmapFrameHasAnyLit(c.blob, i)) {
                    rotation = i;
                    break;
                }
                if ((i & 0xFF) == 0xFF)
                    vTaskDelay(pdMS_TO_TICKS(1));
            }
        }

        // Item A7: expand every frame into a PSRAM staging buffer BEFORE touching
        // the live timeline. Expansion is deterministic bit math over
        // c.blob.bitmapBuf, so once this allocation succeeds it cannot fail;
        // scrollSessionBeginUpload() (which wipes the currently-playing timeline)
        // and the single WriteFrames call below only run after the full
        // expansion already exists in hand, so a failure after BeginUpload is
        // possible only on OOM.
        const size_t stagingBytes = (size_t)frameCount * FRAME_BYTES;
        uint8_t* stagingBuf = static_cast<uint8_t*>(heap_caps_malloc(stagingBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (!stagingBuf)
            stagingBuf = static_cast<uint8_t*>(malloc(stagingBytes));
        if (!stagingBuf) {
            resetBlob(c);
            sendErrorReply(c, seq, 507, "insufficient memory for scroll_bitmap expansion");
            return;
        }
        uint16_t framesSinceYield = 0;
        for (uint16_t i = 0; i < frameCount; ++i) {
            uint32_t srcOffset = (uint32_t)(i + rotation) % frameCount;
            scrollBitmapBuildFrame(c.blob, srcOffset, stagingBuf + (size_t)i * FRAME_BYTES);
            // Yield roughly every 256 frames so a large expansion never starves loop().
            if (++framesSinceYield >= 256) {
                framesSinceYield = 0;
                vTaskDelay(pdMS_TO_TICKS(1));
            }
        }
        uint32_t dt = micros() - t0;
        RLOG_INFO("PROTO", "event=scroll_bitmap_expand frames=%u width=%u rotation=%u durationUs=%lu",
                  (unsigned)frameCount, (unsigned)c.blob.bitmapWidth, (unsigned)rotation, (unsigned long)dt);

        ScrollUploadMeta meta;
        meta.timelineId = c.blob.bitmapTimelineId.c_str();
        meta.fontId = c.blob.bitmapFontId.c_str();
        meta.generatorVersion = c.blob.bitmapGeneratorVersion.c_str();
        meta.sourceText = c.blob.bitmapSourceText.length() ? c.blob.bitmapSourceText.c_str() : nullptr;
        meta.sourceTextBytes = (uint16_t)c.blob.bitmapSourceText.length();
        meta.totalFrames = frameCount;
        meta.uiFps = c.blob.uiFps;
        ScrollUploadTxn txn = scrollSessionBeginUpload(meta);

        bool writeOk = scrollSessionWriteFrames(txn, 0, stagingBuf, frameCount);
        heap_caps_free(stagingBuf);
        if (!writeOk) {
            resetBlob(c);
            sendErrorReply(c, seq, 500, "failed to write scroll frames");
            return;
        }
        uint16_t written = frameCount;

        ScrollUploadResult res = scrollSessionCommitUpload(txn, written, c.blob.hasExplicitTiming,
                                                            c.blob.intervalMs, c.blob.uiFps);
        if (!res.valid) {
            resetBlob(c);
            sendErrorReply(c, seq, 409, "scroll upload was superseded");
            return;
        }
        const bool started = start &&
            startFirmwareScroll(c.blob.intervalMs, c.blob.uiFps);
        ScrollSessionSnapshot snap = scrollSessionSnapshot();
        DynamicJsonDocument out(768);
        out["ok"] = true;
        out["frames"] = res.frameCount;
        out["chunkFrames"] = written;
        out["append"] = false;
        out["started"] = started;
        out["timelineId"] = res.timelineId;
        out["uploadComplete"] = res.uploadComplete;
        out["frameBytes"] = FRAME_BYTES;
        out["scrollIntervalMs"] = snap.scrollIntervalMs;
        out["uiFps"] = snap.uiFps;
        out["scrollFps"] = snap.uiFps;
        out["width"] = c.blob.bitmapWidth;
        out["rotation"] = rotation;
        if (c.blob.bitmapHasViewport) {
            out["viewportX"] = c.blob.bitmapViewportX;
            out["virtualWidth"] = c.blob.bitmapVirtualWidth;
        }
        resetBlob(c);
        sendJsonReply(c, msg::BLOB_END, seq, out);
    } else {
        PsramJsonDocument d(savedFacesJsonCapacityFor(c.blob.expectedOffset));
        DeserializationError e = deserializeJson(d, c.blob.facesBuf, c.blob.expectedOffset, DeserializationOption::NestingLimit(32));
        if (e) {
            resetBlob(c);
            sendErrorReply(c, seq, 400, String("invalid JSON: ") + e.c_str());
            return;
        }
        JsonVariant doc = d["document"];
        if (doc.isNull())
            doc = d.as<JsonVariant>();
        String err;
        if (!validateSavedFaces(doc, err)) {
            resetBlob(c);
            sendErrorReply(c, seq, 400, err);
            return;
        }
        size_t written = writeSavedFaces(doc, err);
        if (written == 0) {
            resetBlob(c);
            sendErrorReply(c, seq, 500, err);
            return;
        }
        loadSavedFaces(false);
        DynamicJsonDocument out(384);
        out["ok"] = true;
        out["v"] = runtimeStateVersion();
        out["path"] = SAVED_FACES_PATH;
        out["bytes"] = written;
        resetBlob(c);
        sendJsonReply(c, msg::BLOB_END, seq, out);
    }
}

static void handleBlobAbort(ClientSlot& c, uint8_t seq) {
    resetBlob(c);
    DynamicJsonDocument out(64);
    out["ok"] = true;
    sendJsonReply(c, msg::BLOB_ABORT, seq, out);
}

// GET_FACES reply payload = [gen:4 bytes LE][file bytes from offset]. The request
// may carry {"offset":n,"gen":g}; if gen is present and no longer matches the
// current saved_faces.json generation, the transfer is aborted with 409 so a
// multi-chunk download never silently splices together two different documents
// (item 12).
static void handleGetFaces(ClientSlot& c, uint8_t seq, const uint8_t* payload, uint16_t len) {
    uint32_t offset = 0;
    bool haveGen = false;
    uint32_t reqGen = 0;
    if (len > 0) {
        StaticJsonDocument<128> d;
        if (!deserializeJson(d, payload, len)) {
            offset = d["offset"] | 0;
            if (!d["gen"].isNull()) {
                haveGen = true;
                reqGen = d["gen"] | 0;
            }
        }
    }
    if (!runtimeFsMounted()) {
        sendErrorReply(c, seq, 503, "LittleFS is not mounted");
        return;
    }
    if (!existsFs(SAVED_FACES_PATH)) {
        sendErrorReply(c, seq, 404, "saved_faces.json not found");
        return;
    }
    uint32_t curGen = savedFacesGeneration();
    if (haveGen && reqGen != curGen) {
        sendErrorReply(c, seq, 409, "saved_faces.json changed mid-transfer");
        return;
    }
    File f = openFs(SAVED_FACES_PATH, "r");
    if (!f) {
        sendErrorReply(c, seq, 500, "failed to open saved_faces.json");
        return;
    }
    size_t total = 0;
    withStorageLock([&]() { total = f.size(); });
    if (offset > total)
        offset = (uint32_t)total;
    uint16_t chunkMax = c.transport->preferredChunkBytes(ClientId{static_cast<uint8_t>(&c - g_clients)});
    if (chunkMax == 0 || chunkMax > MAX_PAYLOAD_BYTES)
        chunkMax = 2048;
    if (chunkMax < 5)
        chunkMax = 5; // must fit the 4-byte gen prefix plus at least 1 data byte
    static uint8_t buf[MAX_PAYLOAD_BYTES];
    buf[0] = (uint8_t)(curGen & 0xFF);
    buf[1] = (uint8_t)((curGen >> 8) & 0xFF);
    buf[2] = (uint8_t)((curGen >> 16) & 0xFF);
    buf[3] = (uint8_t)((curGen >> 24) & 0xFF);
    size_t want = total - offset;
    size_t dataCap = (size_t)chunkMax - 4;
    if (want > dataCap)
        want = dataCap;
    size_t n = 0;
    withStorageLock([&]() {
        f.seek(offset);
        n = f.read(buf + 4, want);
        f.close();
    });
    bool more = (offset + n) < total;
    sendFrame(c, static_cast<uint8_t>(msg::GET_FACES | 0x80), seq, more ? FLAG_MORE : 0, buf, (uint16_t)(n + 4));
}

// --- Top-level dispatch ----------------------------------------------------------------
static void dispatch(ClientSlot& c, uint8_t type, uint8_t seq, uint8_t /*flags*/,
                      const uint8_t* payload, uint16_t len) {
    switch (type) {
    case msg::CMD: handleCmd(c, seq, payload, len); break;
    case msg::GET_STATUS: handleGetStatus(c, seq, payload, len); break;
    case msg::GET_POWER: handleGetPower(c, seq); break;
    case msg::GET_SCROLL_META: handleGetScrollMeta(c, seq); break;
    case msg::GET_PREVIEW_SYNC: handleGetPreviewSync(c, seq); break;
    case msg::PING: handlePing(c, seq); break;
    case msg::SET_FRAME: handleSetFrame(c, seq, payload, len); break;
    case msg::GET_FRAME: handleGetFrame(c, seq); break;
    case msg::BLOB_BEGIN: handleBlobBegin(c, seq, payload, len); break;
    case msg::BLOB_CHUNK: handleBlobChunk(c, seq, payload, len); break;
    case msg::BLOB_END: handleBlobEnd(c, seq, payload, len); break;
    case msg::BLOB_ABORT: handleBlobAbort(c, seq); break;
    case msg::GET_FACES: handleGetFaces(c, seq, payload, len); break;
    default:
        sendErrorReply(c, seq, 400, String("unknown message type: ") + String(type));
        break;
    }
}

// --- Registry (transport.h contract) ---------------------------------------------------
// See the contract comment in transport.h. transportRegisterClient/
// transportUnregisterClient may run on any task (notably the NimBLE host task) and
// only ever touch used/transport/carrier/connectPending/disconnectPending, all
// under g_registryMux. Everything else (blob teardown, sub resets, freeing
// buffers) happens exclusively in finalizePendingRegistryChanges(), called once at
// the very start of serviceProtocol() on the loop task.
namespace rinalink {

bool transportRegisterClient(ITransport* transport, Carrier carrier, ClientId* outId) {
    bool claimed = false;
    uint8_t claimedSlot = 0;
    portENTER_CRITICAL(&g_registryMux);
    for (uint8_t i = 0; i < MAX_CLIENTS; i++) {
        ClientSlot& c = g_clients[i];
        if (c.used || c.connectPending)
            continue;
        // Item 14: refuse the connection if this slot never got a usable inbound
        // buffer (allocated once, eagerly, in protocolBegin()) rather than trying
        // to allocate here off the loop task.
        if (!c.inbound)
            continue;
        c.used = true;
        c.transport = transport;
        c.carrier = carrier;
        c.disconnectPending = false;
        c.connectPending = true; // finalized (subs reset etc.) on the loop task
        claimed = true;
        claimedSlot = i;
        break;
    }
    portEXIT_CRITICAL(&g_registryMux);
    if (!claimed)
        return false;
    if (outId)
        *outId = ClientId{claimedSlot};
    RLOG_INFO("PROTO", "event=client_connect slot=%u carrier=%d", (unsigned)claimedSlot, (int)carrier);
    return true;
}

void transportUnregisterClient(ClientId id) {
    if (id.slot >= MAX_CLIENTS)
        return;
    ClientSlot& c = g_clients[id.slot];
    portENTER_CRITICAL(&g_registryMux);
    if (c.used)
        c.disconnectPending = true;
    portEXIT_CRITICAL(&g_registryMux);
}

size_t transportPushInbound(ClientId id, const uint8_t* data, size_t len) {
    if (id.slot >= MAX_CLIENTS)
        return 0;
    ClientSlot& c = g_clients[id.slot];
    if (!c.used || c.disconnectPending || !c.inbound)
        return 0;
    portENTER_CRITICAL(&c.mux);
    size_t room = INBOUND_BUFFER_BYTES - c.inboundLen;
    size_t take = len > room ? room : len;
    if (take > 0) {
        memcpy(c.inbound + c.inboundLen, data, take);
        c.inboundLen += take;
    }
    portEXIT_CRITICAL(&c.mux);
    if (take < len) {
        RLOG_WARN("PROTO", "event=inbound_overflow slot=%u dropped=%u", (unsigned)id.slot, (unsigned)(len - take));
    }
    return take;
}

size_t transportInboundFree(ClientId id) {
    if (id.slot >= MAX_CLIENTS)
        return 0;
    ClientSlot& c = g_clients[id.slot];
    if (!c.used || !c.inbound)
        return 0;
    portENTER_CRITICAL(&c.mux);
    size_t freeBytes = INBOUND_BUFFER_BYTES - c.inboundLen;
    portEXIT_CRITICAL(&c.mux);
    return freeBytes;
}

void transportMarkResyncNeeded(ClientId id) {
    if (id.slot >= MAX_CLIENTS)
        return;
    ClientSlot& c = g_clients[id.slot];
    if (!c.used)
        return;
    portENTER_CRITICAL(&c.mux);
    c.inboundLen = 0;
    c.oversizedBytesRemaining = 0;
    c.resyncNeeded = true;
    portEXIT_CRITICAL(&c.mux);
}

size_t transportFrame(uint8_t* out, uint8_t type, uint8_t seq, uint8_t flags,
                      const uint8_t* payload, uint16_t payloadLen) {
    out[0] = FRAME_MAGIC;
    out[1] = type;
    out[2] = seq;
    out[3] = flags;
    out[4] = (uint8_t)(payloadLen & 0xFF);
    out[5] = (uint8_t)((payloadLen >> 8) & 0xFF);
    if (payloadLen && payload)
        memcpy(out + FRAME_HEADER_BYTES, payload, payloadLen);
    return FRAME_HEADER_BYTES + payloadLen;
}

} // namespace rinalink

// --- Per-client inbound processing ------------------------------------------------------
// Caps frames dispatched per client per serviceProtocol() pass (item 7) so one
// chatty client cannot starve the others sharing the loop() budget. Remaining
// complete frames retain their buffer space until the next pass.
constexpr uint8_t MAX_FRAMES_PER_CLIENT_PASS = 8;

static void processClientInbound(ClientSlot& c) {
    static uint8_t frame[FRAME_HEADER_BYTES + MAX_PAYLOAD_BYTES];
    for (uint8_t dispatched = 0; dispatched < MAX_FRAMES_PER_CLIENT_PASS; ++dispatched) {
        portENTER_CRITICAL(&g_registryMux);
        const bool active = c.used && !c.disconnectPending;
        portEXIT_CRITICAL(&g_registryMux);
        if (!active)
            return;

        portENTER_CRITICAL(&c.mux);
        const bool needsResync = c.resyncNeeded;
        c.resyncNeeded = false;
        const rinalink::InboundFrameResult popped = rinalink::popInboundFrame(
            c.inbound, c.inboundLen, frame, c.oversizedBytesRemaining);
        portEXIT_CRITICAL(&c.mux);
        if (needsResync)
            sendErrorReply(c, 0, 413, "inbound overflow");
        if (popped.oversized) {
            sendErrorReply(c, popped.rejectedSeq, 413, "frame payload too large");
            uint8_t slot = static_cast<uint8_t>(&c - g_clients);
            RLOG_WARN("PROTO", "event=oversized_frame_disconnect slot=%u seq=%u",
                      (unsigned)slot, (unsigned)popped.rejectedSeq);
            rinalink::transportUnregisterClient(ClientId{slot});
            return;
        }
        if (popped.frameBytes == 0 || c.disconnectPending)
            return;
        dispatch(c, frame[1], frame[2], frame[3], frame + FRAME_HEADER_BYTES,
                 static_cast<uint16_t>(popped.frameBytes - FRAME_HEADER_BYTES));
    }
}

// --- Event fan-out (§3.5) ---------------------------------------------------------------
static void serviceProtocolEvents() {
    uint32_t now = millis();
    bool wifiChanged = wifiManagerStateChanged();
    bool wifiScanReady = wifiManagerScanResultReady();
    if (wifiChanged) {
        for (auto& client : g_clients) {
            if (client.used && !client.disconnectPending)
                client.wifiEventPending = true;
        }
    }
    if (wifiScanReady)
        g_wifiScanEventPending = true;

    // Drain the EV_LOG ring (item 9): copy out under the lock, then fan out to
    // subscribed clients without holding it.
    if (g_logRing && g_logCount > 0) {
        static LogRingEntry local[LOG_RING_CAP]; // loop-task only; avoid ~2.8 KB of stack
        uint8_t count;
        portENTER_CRITICAL(&g_logRingMux);
        count = g_logCount;
        uint8_t start = (uint8_t)((g_logHead + LOG_RING_CAP - count) % LOG_RING_CAP);
        for (uint8_t i = 0; i < count; i++)
            local[i] = g_logRing[(start + i) % LOG_RING_CAP];
        g_logCount = 0;
        portEXIT_CRITICAL(&g_logRingMux);
        for (uint8_t i = 0; i < count; i++) {
            char lvl[2] = {local[i].level ? local[i].level : 'I', 0};
            for (uint8_t ci = 0; ci < MAX_CLIENTS; ci++) {
                ClientSlot& lc = g_clients[ci];
                if (!lc.used || lc.disconnectPending || !lc.subLog)
                    continue;
                DynamicJsonDocument d(256);
                d["level"] = lvl;
                d["tag"] = local[i].tag;
                d["msg"] = local[i].msg;
                sendEvent(lc, msg::EV_LOG, d);
            }
        }
    }

    if (g_wifiScanEventPending) {
        DynamicJsonDocument out(2560);
        out["ok"] = true;
        JsonArray arr = out.createNestedArray("networks");
        wifiManagerGetScanJson(arr);
        int slot = g_wifiScanRequesterSlot;
        bool sentToRequester = false;
        if (slot >= 0 && slot < MAX_CLIENTS && g_clients[slot].used && !g_clients[slot].disconnectPending) {
            sentToRequester = sendEvent(g_clients[slot], msg::EV_WIFI_SCAN, out);
        }
        if (!sentToRequester) {
            bool anyRecipient = false;
            bool allSent = true;
            for (uint8_t i = 0; i < MAX_CLIENTS; i++) {
                if (g_clients[i].used && !g_clients[i].disconnectPending) {
                    anyRecipient = true;
                    allSent = sendEvent(g_clients[i], msg::EV_WIFI_SCAN, out) && allSent;
                }
            }
            sentToRequester = anyRecipient && allSent;
        }
        if (sentToRequester) {
            g_wifiScanRequesterSlot = -1;
            g_wifiScanEventPending = false;
        }
    }

    for (uint8_t i = 0; i < MAX_CLIENTS; i++) {
        ClientSlot& c = g_clients[i];
        if (!c.used)
            continue;

        if (c.subPreview) {
            LedPresentedSample s = readLedPresentedSample();
            uint32_t minGapMs = (c.carrier == Carrier::Ble) ? 250 : 100; // 4 Hz / 10 Hz
            if ((!c.havePreviewSeq || s.presentedSeq != c.lastPreviewSeq) &&
                millisElapsed(now, c.lastPreviewSentMs, minGapMs)) {
                DynamicJsonDocument d(1280);
                buildPreviewSyncJson(d);
                if (sendEvent(c, msg::EV_PREVIEW_SYNC, d)) {
                    c.lastPreviewSeq = s.presentedSeq;
                    c.havePreviewSeq = true;
                    c.lastPreviewSentMs = now;
                }
            }
        }

        if (c.subStatus) {
            uint32_t v = runtimeStateVersion();
            if ((!c.haveStatusVersion || v != c.lastStatusVersion) && millisElapsed(now, c.lastStatusSentMs, 200)) {
                PsramJsonDocument d(1536);
                buildStatusJson(d, true);
                if (sendEvent(c, msg::EV_STATUS, d)) {
                    c.lastStatusVersion = v;
                    c.haveStatusVersion = true;
                    c.lastStatusSentMs = now;
                }
            }
        }

        if (c.subPower) {
            PowerStatus ps = readPowerStatusSnapshot();
            bool chargingFlipped = c.haveChargingSent && ps.charging != c.lastChargingSent;
            if (chargingFlipped || millisElapsed(now, c.lastPowerSentMs, 1000)) {
                DynamicJsonDocument d(1024);
                d["ok"] = true;
                addPower(d.createNestedObject("power"));
                if (sendEvent(c, msg::EV_POWER, d)) {
                    c.lastPowerSentMs = now;
                    c.lastChargingSent = ps.charging;
                    c.haveChargingSent = true;
                }
            }
        }

        if (c.wifiEventPending) {
            DynamicJsonDocument d(768);
            wifiManagerGetStatusJson(d.to<JsonObject>());
            if (sendEvent(c, msg::EV_WIFI, d))
                c.wifiEventPending = false;
        }
    }
}

void protocolBegin() {
    g_wifiScanRequesterSlot = -1;
    g_wifiScanEventPending = false;
    for (auto& c : g_clients)
        c = ClientSlot{};
    // Item 14: pre-allocate every slot's inbound buffer eagerly here (loop task,
    // before any carrier starts) so transportRegisterClient() (which may run on
    // the NimBLE host task) never has to allocate off the loop task.
    for (auto& c : g_clients) {
        c.inbound = static_cast<uint8_t*>(heap_caps_malloc(INBOUND_BUFFER_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (!c.inbound)
            c.inbound = static_cast<uint8_t*>(malloc(INBOUND_BUFFER_BYTES));
    }
    if (!g_logRing) {
        g_logRing = static_cast<LogRingEntry*>(
            heap_caps_malloc(sizeof(LogRingEntry) * LOG_RING_CAP, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (!g_logRing)
            g_logRing = static_cast<LogRingEntry*>(malloc(sizeof(LogRingEntry) * LOG_RING_CAP));
        if (g_logRing)
            memset(g_logRing, 0, sizeof(LogRingEntry) * LOG_RING_CAP);
    }
    g_logHead = 0;
    g_logCount = 0;
    rinaLogSetSink(protocolLogSink);
}


// Loop-task half of the registry contract (transport.h). Consumes the
// connectPending/disconnectPending flags set by carriers on any task and performs
// all per-slot (re)initialisation and teardown here, so no protocol-owned state is
// ever touched off the loop task. Must be the first thing serviceProtocol() does.
static void resetSlotSessionState(ClientSlot& c, bool clearInbound = true) {
    resetBlob(c);
    if (clearInbound) {
        portENTER_CRITICAL(&c.mux);
        c.inboundLen = 0;
        c.resyncNeeded = false;
        c.oversizedBytesRemaining = 0;
        portEXIT_CRITICAL(&c.mux);
    }
    c.subPreview = true;
    c.subStatus = true;
    c.subPower = true;
    c.subLog = false;
    c.havePreviewSeq = false;
    c.lastPreviewSeq = 0;
    c.lastPreviewSentMs = 0;
    c.haveStatusVersion = false;
    c.lastStatusVersion = 0;
    c.lastStatusSentMs = 0;
    c.lastPowerSentMs = 0;
    c.haveChargingSent = false;
    c.lastChargingSent = false;
    c.wifiEventPending = false;
    int selfSlot = static_cast<int>(&c - g_clients);
    if (g_wifiScanRequesterSlot == selfSlot)
        g_wifiScanRequesterSlot = -1;
}

static void finalizePendingRegistryChanges() {
    for (uint8_t i = 0; i < MAX_CLIENTS; i++) {
        ClientSlot& c = g_clients[i];
        bool doConnect = false;
        bool doDisconnect = false;
        portENTER_CRITICAL(&g_registryMux);
        if (c.used) {
            if (c.disconnectPending) {
                doDisconnect = true;
            } else if (c.connectPending) {
                doConnect = true;
                c.connectPending = false;
            }
        }
        portEXIT_CRITICAL(&g_registryMux);

        if (doDisconnect) {
            Carrier carrier = c.carrier;
            // Item A3: capture the transport before clearing the slot so we can
            // still tell the carrier to tear this client down after the registry
            // no longer claims it (TCP stops the socket + clears its slot
            // mapping; BLE clears its own mapping and disconnects the peer).
            // Without this, a carrier could keep pushing bytes into a slot that
            // a different client later claims.
            ITransport* transport = c.transport;
            // A hint left lit by a client that is gone would never be cleared.
            clearHintLedOwnedBy(static_cast<uint8_t>(i));
            resetSlotSessionState(c);
            portENTER_CRITICAL(&g_registryMux);
            c.transport = nullptr;
            c.carrier = Carrier::None;
            c.connectPending = false;
            c.disconnectPending = false;
            c.used = false;
            portEXIT_CRITICAL(&g_registryMux);
            if (transport)
                transport->disconnect(ClientId{i});
            RLOG_INFO("PROTO", "event=client_disconnect slot=%u carrier=%d", (unsigned)i, (int)carrier);
        } else if (doConnect) {
            // The peer can send between onConnect and this loop pass. Those
            // bytes belong to the new session, not to the prior occupant.
            resetSlotSessionState(c, false);
        }
    }
}

void serviceProtocol() {
    finalizePendingRegistryChanges();
    // The hint LED is only meaningful while the control output is on screen;
    // if a face/text/etc. output has taken over, drop it. Loop task only.
    if (runtimeState().outputMode != "control")
        clearHintLed();
    expireBlobSessions();
    if (g_rebootPending && millisReached(millis(), g_rebootAtMs)) {
        ESP.restart();
    }
    for (uint8_t i = 0; i < MAX_CLIENTS; i++) {
        if (g_clients[i].used && !g_clients[i].disconnectPending)
            processClientInbound(g_clients[i]);
    }
    serviceProtocolEvents();
}
