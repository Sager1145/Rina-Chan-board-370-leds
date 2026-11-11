// Regression cases for the protocol.cpp fixes of the 44-finding audit. Built by
// audit_repairs_test.py like ap_address_integration_cases.cpp:
//   RINA_AUDIT_CASE_SOURCE=test/host/fix44_protocol_cases.cpp \
//     python3 test/host/audit_repairs_test.py fix44_err507 fix44_face_reply \
//     fix44_resume fix44_apply_index fix44_terminate fix44_wifi_scan
#include "protocol.cpp"
#include "scroll.cpp"
#include "main.cpp"
#include "stress_common.h"
#include <WiFi.h>

static void require(bool condition, const char* message) {
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

static void startScroll(uint16_t frames = 5) {
    ScrollUploadMeta meta;
    meta.timelineId = "fix44-timeline";
    meta.totalFrames = frames;
    const auto txn = scrollSessionBeginUpload(meta);
    std::vector<uint8_t> bits(static_cast<size_t>(frames) * FRAME_BYTES);
    for (uint16_t i = 0; i < frames; ++i) bits[static_cast<size_t>(i) * FRAME_BYTES] = 1U << i;
    require(scrollSessionWriteFrames(txn, 0, bits.data(), frames), "write timeline");
    require(scrollSessionCommitUpload(txn, frames, true, 100, 10).valid, "commit timeline");
    require(startFirmwareScroll(100, 10) && runtimeState().firmwareScrollActive, "scroll started");
}

// The static overflow fallback must have the documented error shape.
static void err507() {
    FakeTransport carrier; TestClient client; require(client.connect(carrier), "client connected");
    StaticJsonDocument<16> tiny;
    tiny["error"] = std::string(200, 'x');
    require(tiny.overflowed(), "fixture overflows its document");
    require(emitJson(g_clients[client.id.slot], msg::ERR, 7, 0, tiny), "overflow fallback sent");
    const auto reply = client.replyFor(7);
    require(reply.first == msg::ERR, "overflow fallback is an ERR frame");
    auto doc = parse(reply.second);
    require(doc["ok"].is<bool>() && !doc["ok"].as<bool>(), "507 payload carries ok:false");
    require(doc["code"] == 507 && !doc["error"].isNull(), "507 payload keeps code and error");
}

// A stored record too large for the reply document still gets a success reply
// (without `face`) once the write is committed.
static void faceReply() {
    runtimeFsMounted() = true;
    DynamicJsonDocument library(16384); library["category"] = "unified_saved_faces";
    auto faces = library.createNestedArray("faces");
    for (int i = 0; i < 2; ++i) {
        auto face = faces.createNestedObject(); face["id"] = i == 0 ? "default1" : "big";
        face["type"] = i == 0 ? "default" : "custom"; face["name"] = "Face"; face["order"] = i + 1;
        auto frame = face.createNestedArray("frameBytes"); for (unsigned b = 0; b < FRAME_BYTES; ++b) frame.add(0);
        if (i == 1) face["note"] = std::string(4000, 'n'); // unknown field kept on overwrite
    }
    String error;
    require(writeSavedFaces(library.as<JsonVariant>(), error) != 0, "library stored");
    // All-zero frame: the last byte's unused bits must stay clear (validatePackedFrame).
    const std::string frameHex(FRAME_BYTES * 2, '0');
    FakeTransport carrier; TestClient client; require(client.connect(carrier), "client connected");

    const uint32_t genBefore = savedFacesGeneration();
    auto big = client.cmd(1, "{\"cmd\":\"face_upsert\",\"payload\":{\"face\":{\"id\":\"big\","
                             "\"type\":\"custom\",\"name\":\"Big\",\"frameHex\":\"" + frameHex + "\"}}}");
    require(big.first == (msg::CMD | 0x80), "oversized stored record still replies success");
    auto bigDoc = parse(big.second);
    require(bigDoc["ok"].as<bool>() && bigDoc["count"] == 2, "summary fields survive the fallback");
    require(bigDoc["gen"].as<uint32_t>() == savedFacesGeneration() && savedFacesGeneration() == genBefore + 1,
            "fallback reports the committed generation");
    require(bigDoc["face"].isNull(), "partial face copy is not sent");

    auto small = client.cmd(2, "{\"cmd\":\"face_upsert\",\"payload\":{\"face\":{\"id\":\"small\","
                               "\"type\":\"custom\",\"name\":\"Small\",\"frameHex\":\"" + frameHex + "\"}}}");
    require(small.first == (msg::CMD | 0x80), "normal record accepted");
    auto smallDoc = parse(small.second);
    require(smallDoc["ok"].as<bool>() && smallDoc["face"]["id"] == "small" &&
            smallDoc["face"]["frameBytes"].size() == static_cast<size_t>(FRAME_BYTES), "normal record still carried as stored");
}

static void resumeLabel() {
    FakeTransport carrier; TestClient client; require(client.connect(carrier), "client connected");
    require(setMode("manual", false), "manual mode");
    startScroll();
    require(client.cmd(1, "{\"cmd\":\"pause_scroll\"}").first == (msg::CMD | 0x80), "pause_scroll accepted");
    require(runtimeState().playback == "scroll_paused" && runtimeState().paused, "scroll paused");
    require(client.cmd(2, "{\"cmd\":\"resume\"}").first == (msg::CMD | 0x80), "resume accepted");
    require(runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused, "resume restarts the scroll");
    require(runtimeState().playback == "scroll" && !runtimeState().paused, "resumed scroll keeps its playback label");

    // A remaining system pause keeps the scroll's paused state visible.
    scrollSessionSetSystemPaused(true);
    require(client.cmd(3, "{\"cmd\":\"resume\"}").first == (msg::CMD | 0x80), "resume under system pause accepted");
    require(runtimeState().firmwareScrollPaused && runtimeState().paused &&
            runtimeState().playback == "scroll_paused", "system-paused scroll still reports paused");
    scrollSessionSetSystemPaused(false);

    require(client.cmd(4, "{\"cmd\":\"stop_scroll\",\"restoreAuto\":false}").first == (msg::CMD | 0x80), "scroll stopped");
    require(client.cmd(5, "{\"cmd\":\"pause\"}").first == (msg::CMD | 0x80), "pause accepted");
    require(runtimeState().playback == "paused" && runtimeState().paused, "paused label set");
    require(client.cmd(6, "{\"cmd\":\"resume\"}").first == (msg::CMD | 0x80), "manual resume accepted");
    require(runtimeState().playback == DEFAULT_PLAYBACK && !runtimeState().paused, "manual resume returns to idle");

    require(setMode("auto", false), "auto mode");
    client.cmd(7, "{\"cmd\":\"pause\"}"); client.cmd(8, "{\"cmd\":\"resume\"}");
    require(runtimeState().playback == "auto_saved_face" && !runtimeState().paused, "auto resume restores auto label");
}

// No loadable saved faces: the index form is rejected before it touches the scroll.
static void applyIndexUnavailable() {
    FakeTransport carrier; TestClient client; require(client.connect(carrier), "client connected");
    require(!ensureSavedFacesLoaded(), "fixture has no saved faces");
    startScroll();
    scrollSessionSetRestoreAuto(true);
    const String mode = runtimeState().mode;
    const auto reply = client.cmd(1, "{\"cmd\":\"apply_saved_face\",\"payload\":{\"index\":0}}");
    require(reply.first == msg::ERR, "index apply rejected");
    auto doc = parse(reply.second);
    require(doc["code"] == 503 && doc["error"] == "saved faces unavailable", "rejection matches the id form");
    require(runtimeState().firmwareScrollActive && runtimeState().playback == "scroll", "scroll keeps running");
    require(runtimeState().mode == mode && scrollSessionGetRestoreAuto(), "mode and restoreAuto untouched");
}

static void terminateTargetMode() {
    FakeTransport carrier; TestClient client; require(client.connect(carrier), "client connected");
    require(setMode("manual", false), "manual mode");
    startScroll();
    const auto rejected = runtimeState().commandsRejected;
    const auto bad = client.cmd(1, "{\"cmd\":\"terminate_other_activities\",\"targetMode\":\"automatic\"}");
    require(bad.first == msg::ERR && parse(bad.second)["code"] == 400, "unknown targetMode rejected");
    require(runtimeState().commandsRejected == rejected + 1, "rejection counted");
    require(runtimeState().mode == "manual" && runtimeState().firmwareScrollActive, "rejected command changes nothing");

    const auto good = client.cmd(2, "{\"cmd\":\"terminate_other_activities\",\"targetMode\":\"auto\"}");
    require(good.first == (msg::CMD | 0x80) && parse(good.second)["ok"].as<bool>(), "valid targetMode accepted");
    require(runtimeState().mode == "auto" && !runtimeState().firmwareScrollActive &&
            !runtimeState().firmwareScrollPaused, "scroll stopped and mode switched");
    startScroll();
    const auto fallback = client.cmd(3, "{\"cmd\":\"terminate_other_activities\"}");
    require(fallback.first == (msg::CMD | 0x80), "omitted targetMode accepted");
    require(runtimeState().mode == "manual" && !runtimeState().firmwareScrollActive, "omitted targetMode means manual");
}

static unsigned scanEvents(TestClient& client) {
    unsigned count = 0;
    for (const auto& frame : client.take()) count += frame.type == msg::EV_WIFI_SCAN;
    return count;
}

static void finishScan() { WiFi.scanResult = 0; wifiManagerService(); }

static void wifiScanDelivery() {
    wifiManagerSetMode("off");
    FakeTransport carrier; TestClient a, b;
    require(a.connect(carrier) && b.connect(carrier), "two clients connected");
    int dropSlot = a.id.slot;
    carrier.dropHook = [&](uint8_t slot, const uint8_t* d, size_t, bool isEvent) {
        return isEvent && slot == dropSlot && d[1] == msg::EV_WIFI_SCAN;
    };

    // Back-pressured requester: retried for it alone, never broadcast.
    require(a.cmd(1, "{\"cmd\":\"wifi_scan\"}").first == (msg::CMD | 0x80), "scan requested");
    finishScan();
    for (int pass = 0; pass < 3; ++pass) {
        serviceProtocol();
        require(scanEvents(a) == 0 && scanEvents(b) == 0, "dropped requester send is not broadcast");
    }
    dropSlot = -1; serviceProtocol();
    require(scanEvents(a) == 1 && scanEvents(b) == 0, "requester gets the result once it drains");
    serviceProtocol();
    require(scanEvents(a) == 0 && scanEvents(b) == 0 && g_wifiScanRequesterSlot == -1, "result is sent once");

    // Requester gone before completion: every connected client, once each, and a
    // recipient that drops the event does not make the others receive it again.
    TestClient c; require(c.connect(carrier), "third client connected");
    require(a.cmd(2, "{\"cmd\":\"wifi_scan\"}").first == (msg::CMD | 0x80), "second scan requested");
    rinalink::transportUnregisterClient(a.id); serviceProtocol();
    dropSlot = b.id.slot; finishScan();
    unsigned toB = 0, toC = 0;
    for (int pass = 0; pass < 3; ++pass) { serviceProtocol(); toB += scanEvents(b); toC += scanEvents(c); }
    require(toB == 0 && toC == 1, "healthy recipient is not re-sent while another one drops");
    dropSlot = -1; serviceProtocol(); serviceProtocol();
    require(scanEvents(b) == 1 && scanEvents(c) == 0, "dropped recipient catches up exactly once");

    // Requester leaves while still owed the finished result.
    require(c.cmd(3, "{\"cmd\":\"wifi_scan\"}").first == (msg::CMD | 0x80), "third scan requested");
    dropSlot = c.id.slot; finishScan(); serviceProtocol();
    require(scanEvents(b) == 0, "owed requester still not broadcast");
    rinalink::transportUnregisterClient(c.id);
    toB = 0;
    for (int pass = 0; pass < 3; ++pass) { serviceProtocol(); toB += scanEvents(b); }
    require(toB == 1, "undelivered result falls to the remaining clients once");
}

int main(int argc, char** argv) {
    require(argc == 3, "case and isolated filesystem required"); resetFakeFs(argv[2]);
    initRuntimeScrollFrameBuffer(); protocolBegin(); const std::string name = argv[1];
    if (name == "fix44_err507") err507();
    else if (name == "fix44_face_reply") faceReply();
    else if (name == "fix44_resume") resumeLabel();
    else if (name == "fix44_apply_index") applyIndexUnavailable();
    else if (name == "fix44_terminate") terminateTargetMode();
    else if (name == "fix44_wifi_scan") wifiScanDelivery();
    else require(false, "unknown fix44 protocol case");
    require(g_lockRecursion == 0 && g_lockOrderViolations == 0, "production lock discipline");
    std::cout << "PASS: " << name << '\n';
}
