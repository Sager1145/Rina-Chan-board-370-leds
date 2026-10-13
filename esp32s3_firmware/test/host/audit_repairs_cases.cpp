// Included protocol/main/scroll sources are the production implementations.
// This gives the deterministic host scheduler access to boot and teardown.
#include "protocol.cpp"
#include "scroll.cpp"
#include "main.cpp"
#include "stress_common.h"
#include <Preferences.h>
#include <WiFi.h>
#include <WebServer.h>
#include <DNSServer.h>

extern PowerStatus g_fakePower;
extern uint8_t g_fakePixels[LED_COUNT][3];
extern unsigned g_fakeRefreshCount, g_fakeRefreshFailures;
extern BaseType_t g_fakeTaskCreateResult;
extern void (*g_fakeRefreshHook)();

static void require(bool condition, const char* message) {
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

static void loadTimeline(uint16_t frames = 5) {
    ScrollUploadMeta meta;
    meta.timelineId = "audit-timeline";
    meta.totalFrames = frames;
    const auto txn = scrollSessionBeginUpload(meta);
    std::vector<uint8_t> bits(static_cast<size_t>(frames) * FRAME_BYTES);
    for (uint16_t i = 0; i < frames; ++i) bits[static_cast<size_t>(i) * FRAME_BYTES] = 1U << i;
    require(scrollSessionWriteFrames(txn, 0, bits.data(), frames), "write timeline");
    require(scrollSessionCommitUpload(txn, frames, true, 100, 10).valid, "commit timeline");
}

static JsonObject wifiStatus(DynamicJsonDocument& doc) {
    JsonObject status = doc.to<JsonObject>(); wifiManagerGetStatusJson(status); return status;
}

static void battery() {
    g_fakePower.batteryValid = true; g_fakePower.batteryPercent = 83;
    g_fakePower.vbat = 8.0f; g_fakePower.vcharge = 9.0f;
    showBatteryOverlay(true);
    uint8_t rgb[LED_COUNT * 3];
    require(copyButtonAnimationOverlay(rgb, LED_COUNT), "battery overlay active");
    // Border pixel (6,1) is green for 83%, red for the lost/default snapshot.
    const unsigned border = (ROW_OFFSETS[1] + 6 - (22 - ROW_LENGTHS[1]) / 2) * 3;
    require(rgb[border] == 0 && rgb[border + 1] == 255, "fresh battery check uses current 83% power");
    g_fakePower.batteryPercent = 0;
    showBatteryOverlay(false); advanceMs(101); serviceButtonAnimations();
    g_fakePower.batteryPercent = 95; g_fakePower.vbat = 8.3f;
    showBatteryOverlay(true);
    require(copyButtonAnimationOverlay(rgb, LED_COUNT), "repeated battery overlay active");
    require(rgb[border] == 0 && rgb[border + 1] == 255, "short battery check replaces stale long-overlay power");
}

static void groupEnd() {
    for (const auto& fixture : {std::pair<uint16_t,uint16_t>{1,0}, {5,4}, {5,0}}) {
        loadTimeline(fixture.first);
        const uint64_t at = fixture.second == 0 && fixture.first == 5 ? g_fakeMicros - 1000000 : g_fakeMicros;
        require(scrollSessionGroupStart(at, fixture.second, 100, false), "group_start accepted");
        uint8_t bits[FRAME_BYTES];
        scrollSessionTickCursorLocked(millis(), bits); serviceScrollSession();
        auto snap = scrollSessionSnapshot();
        require(snap.firmwareScrollPaused && snap.firmwareScrollUserPaused, "already-ended group latches pause");
        require(runtimeState().paused && runtimeState().playback == "scroll_paused", "already-ended group publishes paused playback");
        require(snap.scrollFrameIndex == fixture.first - 1, "already-ended group holds final index");
        require(!scrollSessionTickCursorLocked(millis() + 200, bits), "end pause is stable");
    }
}

static void groupLoop() {
    loadTimeline();
    require(scrollSessionGroupStart(g_fakeMicros, 0, 100, false), "nonloop group starts");
    require(!scrollSessionSnapshot().scrollLoop, "group loop preference is visible in metadata");
    scrollSessionSetLoop(true); advanceMs(600);
    uint8_t bits[FRAME_BYTES]; scrollSessionTickCursorLocked(millis(), bits);
    require(runtimeState().scrollFrameIndex == 1 && !runtimeState().firmwareScrollPaused, "set loop true changes active group cursor");
    scrollSessionSetLoop(false); scrollSessionTickCursorLocked(millis(), bits); serviceScrollSession();
    require(runtimeState().scrollFrameIndex == 4 && runtimeState().firmwareScrollPaused, "set loop false ends active group");
    require(scrollSessionRewindIfEnded(), "resume detects nonloop group end");
    scrollSessionSetUserPaused(false);
    require(runtimeState().scrollFrameIndex == 0 && !runtimeState().groupTimed, "resume rewinds to zero and leaves group timing");
}

static void scrollPhase() {
    loadTimeline(); scrollSessionSetLoop(true); scrollSessionStart(17, false);
    const uint32_t origin = runtimeState().lastScrollFrameMs;
    struct Fixture { uint32_t elapsed, anchor; uint16_t frame; };
    // Long/repeated stalls and render durations must skip stale frames rather
    // than slow the timeline. These expected positions are hand-derived.
    for (const auto f : {Fixture{50,34,2}, {130,119,2}, {150,136,3},
                         {166,153,4}, {666,663,4}}) {
        g_fakeMicros = static_cast<uint64_t>(origin + f.elapsed) * 1000;
        uint8_t bits[FRAME_BYTES];
        require(scrollSessionTickCursorLocked(millis(), bits), "overdue scroll presents newest frame once");
        require(runtimeState().scrollFrameIndex == f.frame && bits[0] == (1U << f.frame), "scroll retains wall-clock frame phase");
        require(runtimeState().lastScrollFrameMs == origin + f.anchor, "scroll anchor preserves fractional interval");
        require(!scrollSessionTickCursorLocked(millis(), bits), "scroll does not burst-replay overdue frames");
    }
}

static void scrollEndStall() {
    for (uint32_t elapsed : {450U, 550U}) {
        loadTimeline(); scrollSessionSetLoop(false); scrollSessionStart(100, false);
        const uint32_t origin = runtimeState().lastScrollFrameMs;
        g_fakeMicros = static_cast<uint64_t>(origin + elapsed) * 1000;
        uint8_t bits[FRAME_BYTES];
        require(scrollSessionTickCursorLocked(millis(), bits), "late nonloop tick latches final frame");
        require(runtimeState().scrollFrameIndex == 4 && bits[0] == 16, "late nonloop cursor clamps to final frame");
        require(runtimeState().firmwareScrollPaused == (elapsed == 550), "final frame holds its full interval before end pause");
        g_fakeMicros = static_cast<uint64_t>(origin + 600) * 1000;
        require(!scrollSessionTickCursorLocked(millis(), bits), "ended nonloop timeline does not present again");
        serviceScrollSession();
        require(runtimeState().paused && runtimeState().playback == "scroll_paused", "late endpoint publishes pause status");
    }
}

static void scrollPausePhase() {
    loadTimeline(); scrollSessionSetLoop(true); scrollSessionStart(100, false);
    auto origin = runtimeState().lastScrollFrameMs;
    g_fakeMicros = static_cast<uint64_t>(origin + 350) * 1000;
    uint8_t bits[FRAME_BYTES]; scrollSessionTickCursorLocked(millis(), bits);
    require(runtimeState().scrollFrameIndex == 3, "pre-pause stall catches up");
    scrollSessionSetUserPaused(true); advanceMs(500);
    require(!scrollSessionTickCursorLocked(millis(), bits) && runtimeState().scrollFrameIndex == 3, "paused timeline holds cursor");
    scrollSessionSetUserPaused(false); origin = runtimeState().lastScrollFrameMs;
    g_fakeMicros = static_cast<uint64_t>(origin + 99) * 1000;
    require(!scrollSessionTickCursorLocked(millis(), bits), "resume holds cursor for one new interval");
    advanceMs(1); require(scrollSessionTickCursorLocked(millis(), bits) && runtimeState().scrollFrameIndex == 4, "resume advances without catching up paused time");
    scrollSessionSetInterval(17); origin = runtimeState().lastScrollFrameMs;
    g_fakeMicros = static_cast<uint64_t>(origin + 50) * 1000;
    require(scrollSessionTickCursorLocked(millis(), bits) && runtimeState().scrollFrameIndex == 1, "new interval catches up using new anchor");
}

static void scrollClockWrap() {
    loadTimeline(); scrollSessionSetLoop(true);
    g_fakeMicros = static_cast<uint64_t>(UINT32_MAX - 20U) * 1000;
    scrollSessionStart(17, false);
    g_fakeMicros = (static_cast<uint64_t>(UINT32_MAX - 20U) + 50) * 1000;
    uint8_t bits[FRAME_BYTES];
    require(scrollSessionTickCursorLocked(millis(), bits) && runtimeState().scrollFrameIndex == 2, "unsigned clock wrap preserves phase");
    require(runtimeState().lastScrollFrameMs == 13, "wrapped anchor retains interval remainder");
    g_fakeMicros = 0; scrollSessionStart(17, false);
    g_fakeMicros = 51000;
    require(scrollSessionTickCursorLocked(millis(), bits) && runtimeState().scrollFrameIndex == 3, "zero is a valid active clock anchor");
}

static void apValidation() {
    wifiManagerBegin();
    require(wifiManagerSetAp("Good AP", "12345678"), "valid AP accepted");
    const auto writes = Preferences::writes;
    for (const auto& invalid : {std::pair<String,String>{"", "12345678"},
            {"Bad", "short"}, {String(std::string(33, 's')), "12345678"},
            {"Bad", String(std::string(64, 'p'))}}) {
        require(!wifiManagerSetAp(invalid.first, invalid.second), "invalid AP byte lengths rejected");
        require(wifiManagerApSsid() == "Good AP" && Preferences::writes == writes, "invalid AP preserves runtime and persisted credentials");
    }
    require(wifiManagerSetAp(String(std::string(32, 's')), String(std::string(63, 'p'))), "maximum AP byte lengths accepted");
    require(wifiManagerSetAp("Open AP", ""), "open AP accepted");
    for (auto transport : {Carrier::Ble, Carrier::Tcp}) {
        FakeTransport carrier(transport); TestClient client;
        require(client.connect(carrier), "AP command client connected");
        const auto reply = client.cmd(1, "{\"cmd\":\"wifi_set_ap\",\"payload\":{\"ssid\":\"Bad\",\"password\":\"x\"}}");
        require(!parse(reply.second)["ok"].as<bool>(), "BLE/TCP AP command reports shared validation rejection");
        require(wifiManagerApSsid() == "Open AP", "rejected AP command preserves prior AP");
        rinalink::transportUnregisterClient(client.id); serviceProtocol();
    }
}

static void apFailure() {
    wifiManagerBegin();
    require(wifiManagerSetAp("Good AP", "12345678"), "valid AP accepted");
    const auto writes = Preferences::writes;
    webSetupBegin(); webSetupService();
    require(WebServer::running && DNSServer::running, "valid AP serves HTTP and captive DNS");
    WiFi.apResult = false;
    require(!wifiManagerSetAp("Unavailable AP", "abcdefgh"), "radio AP failure reported");
    require(wifiManagerApSsid() == "Good AP" && Preferences::writes == writes, "radio AP failure preserves persisted credentials");
    DynamicJsonDocument doc(2048);
    require(wifiStatus(doc)["apActive"].as<bool>(), "rejected reconfiguration preserves still-running AP status");
    webSetupService();
    require(WebServer::running && DNSServer::running, "rejected reconfiguration preserves HTTP and captive DNS recovery");
    WiFi.configResult = false;
    require(!wifiManagerSetAp("Config rejected", "abcdefgh"), "AP IP configuration failure reported");
    require(wifiStatus(doc)["apActive"].as<bool>() && Preferences::writes == writes, "IP config failure preserves old active AP and NVS");
    WiFi.configResult = true; WiFi.apStopsOnFailure = true;
    require(!wifiManagerSetAp("Radio stopped", "abcdefgh"), "stopped AP failure reported");
    require(!wifiStatus(doc)["apActive"].as<bool>(), "genuinely stopped AP is inactive");
    webSetupService();
    require(!WebServer::running && !DNSServer::running, "stopped AP shuts down unavailable recovery servers");
}

static void apInitialFailure() {
    WiFi.apResult = false;
    wifiManagerBegin(); webSetupBegin(); webSetupService();
    DynamicJsonDocument doc(2048);
    require(!wifiStatus(doc)["apActive"].as<bool>(), "failed initial AP start is inactive");
    require(!WebServer::running && !DNSServer::running, "failed initial AP start does not advertise recovery servers");
}

static void scanVisibility() {
    wifiManagerSetCredentials("Home", "password"); wifiManagerSetHotspotCredentials("Hotspot", "password");
    wifiManagerSetMode("sta");
    for (int i = 0; i < 70; ++i) WiFi.networks.push_back({String("Busy") + i, -20 - i});
    WiFi.networks.push_back({"Home", -99}); WiFi.networks.push_back({"Hotspot", -15});
    WiFi.scanResult = static_cast<int>(WiFi.networks.size()); wifiManagerService();
    require(WiFi.joinedSsid == "Home", "home beyond 64 scan entries wins over visible hotspot");
    DynamicJsonDocument doc(4096); auto array = doc.to<JsonArray>(); wifiManagerGetScanJson(array);
    require(array.size() == 20, "scan response retains display cap");
    require(array[0]["ssid"] == "Hotspot", "strongest result beyond original prefix appears in response");
}

static void scanRestore() {
    wifiManagerSetMode("off"); require(wifiManagerStartScan(), "off-mode temporary scan starts");
    WiFi.scanResult = 0; wifiManagerService();
    require(WiFi.getMode() == WIFI_OFF, "successful off-mode scan restores radio off");
    require(!wifiManagerScanInProgress() && wifiManagerScanResultReady(), "off scan publishes completion after restoration");
    require(!wifiManagerScanResultReady(), "scan completion edge is consumed exactly once");
    WiFi.scanStartResult = WIFI_SCAN_FAILED;
    require(!wifiManagerStartScan(), "failed scan reports failure");
    require(WiFi.getMode() == WIFI_OFF, "failed off-mode scan restores radio off");
    WiFi.scanStartResult = WIFI_SCAN_RUNNING; require(wifiManagerStartScan(), "new scan starts");
    wifiManagerSetMode("ap"); WiFi.scanResult = 0; wifiManagerService();
    require(WiFi.getMode() == WIFI_AP, "scan completion preserves superseding AP mode");
    require(wifiManagerScanResultReady(), "superseded scan still publishes completion");
    require(wifiManagerStartScan(), "AP-mode temporary scan starts");
    require(WiFi.getMode() == WIFI_AP_STA && wifiManagerScanInProgress(), "AP scan enables station without dropping AP");
    require(wifiManagerStartScan(), "second requester joins in-progress scan");
    wifiManagerService();
    require(wifiManagerScanInProgress() && !wifiManagerScanResultReady(), "running scan does not publish early completion");
    WiFi.networks.push_back({"Visible network", -27}); WiFi.scanResult = 1; wifiManagerService();
    require(WiFi.getMode() == WIFI_AP && !wifiManagerScanInProgress(), "completed AP scan restores AP-only mode");
    DynamicJsonDocument doc(1024); auto networks = doc.to<JsonArray>(); wifiManagerGetScanJson(networks);
    require(networks.size() == 1 && networks[0]["ssid"] == "Visible network", "AP scan cache survives driver result deletion and mode restoration");
    require(wifiManagerScanResultReady() && !wifiManagerScanResultReady(), "AP scan completion is published exactly once");
}

static void credentialClear(const std::string& name) {
    wifiManagerBegin();
    wifiManagerSetCredentials("Home", "home-pass");
    wifiManagerSetHotspotCredentials("Hotspot", "hotspot-pass");
    FakeTransport carrier; TestClient client;
    require(client.connect(carrier), "control carrier remains available during credential clear");
    DynamicJsonDocument doc(2048);
    if (name == "clear_home" || name == "clear_hotspot" || name == "clear_pending") {
        wifiManagerSetMode("sta_or_ap");
        const bool hotspot = name == "clear_hotspot";
        WiFi.networks.push_back({hotspot ? "Hotspot" : "Home", -27});
        WiFi.scanResult = 1; wifiManagerService();
        if (name != "clear_pending") { WiFi.stationStatus = WL_CONNECTED; wifiManagerService(); }
        if (hotspot) wifiManagerClearCredentials(); else wifiManagerClearHotspotCredentials();
        require(WiFi.storedStaSsid == (hotspot ? "Hotspot" : "Home"), "clearing inactive profile preserves active station credentials");
        if (hotspot) wifiManagerClearHotspotCredentials(); else wifiManagerClearCredentials();
        require(WiFi.storedStaSsid.isEmpty() && WiFi.storedStaPass.isEmpty(), "clearing station owner erases IDF station credentials");
        require(WiFi.status() != WL_CONNECTED && WiFi.joinedSsid.isEmpty(), "clearing station owner disconnects current or pending association");
        auto status = wifiStatus(doc);
        require(status["activeProfile"] == "none" && status["apActive"].as<bool>() && status["mode"] == "sta_or_ap",
                "clearing station owner keeps hotspot serving and resets active profile");
        wifiManagerService();
        require(WiFi.joinedSsid.isEmpty(), "cleared pending profile cannot complete a stale connection");
    } else {
        if (name == "clear_off") wifiManagerSetMode("off");
        const bool retained = name == "clear_ap_retained";
        WiFi.storedStaSsid = retained ? "Hotspot" : "Home";
        WiFi.storedStaPass = retained ? "hotspot-pass" : "home-pass";
        const auto originalMode = WiFi.getMode();
        wifiManagerClearCredentials();
        if (retained)
            require(WiFi.storedStaSsid == "Hotspot" && WiFi.storedStaPass == "hotspot-pass", "clearing historical home preserves retained driver hotspot profile");
        else
            require(WiFi.storedStaSsid.isEmpty() && WiFi.storedStaPass.isEmpty(), "clearing historical AP/off profile erases IDF credentials");
        require(WiFi.getMode() == originalMode, "clearing historical credentials preserves requested radio mode");
        require(Preferences::values["hssid"] == "Hotspot" && Preferences::values["hpass"] == "hotspot-pass", "clearing home retains manager hotspot credentials");
        wifiManagerClearHotspotCredentials();
        require(WiFi.storedStaSsid.isEmpty() && WiFi.storedStaPass.isEmpty(), "clearing last profile erases remaining historical driver credentials");
        require(WiFi.getMode() == originalMode, "last-profile clear preserves requested radio mode");
    }
    require(Preferences::values["ssid"].isEmpty() && Preferences::values["pass"].isEmpty() &&
            Preferences::values["hssid"].isEmpty() && Preferences::values["hpass"].isEmpty(), "both cleared profiles leave no manager credentials");
    const auto ping = client.request(msg::PING, 19, {});
    require(ping.first == (msg::PING | 0x80), "credential clear preserves live control carrier");
}

static DynamicJsonDocument faceDocument(const char* defaultId, const char* customId) {
    DynamicJsonDocument doc(4096); doc["category"] = "unified_saved_faces";
    auto faces = doc.createNestedArray("faces");
    for (int i = 0; i < 2; ++i) {
        auto face = faces.createNestedObject(); face["id"] = i == 0 ? defaultId : customId;
        face["type"] = i == 0 ? "default" : "custom"; face["name"] = "Face"; face["order"] = i + 1;
        auto frame = face.createNestedArray("frameBytes"); for (unsigned b = 0; b < FRAME_BYTES; ++b) frame.add(0);
    }
    return doc;
}

static void faceIdentity(const std::string& fsRoot) {
    runtimeFsMounted() = true;
    auto good = faceDocument("default1", "custom1"); String error;
    require(validateSavedFaces(good.as<JsonVariant>(), error), "valid identities accepted");
    require(writeSavedFaces(good.as<JsonVariant>(), error) != 0, "valid library stored");
    const auto before = readFile(fsRoot + SAVED_FACES_PATH);
    for (const auto& ids : {std::pair<const char*,const char*>{"same", "same"}, {"", "custom1"}, {"default1", ""}, {"default1", nullptr}}) {
        auto invalid = faceDocument(ids.first, ids.second);
        require(!validateSavedFaces(invalid.as<JsonVariant>(), error), "duplicate or missing face identity rejected");
        require(readFile(fsRoot + SAVED_FACES_PATH) == before, "rejected validation preserves stored library");
    }
    // The BLOB adapter must reject the same invalid library before replacement.
    FakeTransport carrier; TestClient client; require(client.connect(carrier), "face client connected");
    auto invalid = faceDocument("same", "same"); std::string json; serializeJson(invalid, json);
    auto begin = client.request(msg::BLOB_BEGIN, 1, bytesOf("{\"kind\":\"faces\",\"totalBytes\":" + std::to_string(json.size()) + "}"));
    require(begin.first == (msg::BLOB_BEGIN | 0x80), "faces BLOB begin accepted");
    Bytes chunk(4, 0); chunk.insert(chunk.end(), json.begin(), json.end());
    client.request(msg::BLOB_CHUNK, 2, chunk);
    auto end = client.request(msg::BLOB_END, 3, {});
    require(end.first == msg::ERR && parse(end.second)["code"] == 400, "faces BLOB rejects duplicate identity");
    require(readFile(fsRoot + SAVED_FACES_PATH) == before, "rejected BLOB preserves stored library");
}

static void renderFallback() {
    g_fakeTaskCreateResult = 0; setup();
    const unsigned before = g_fakeRefreshCount;
    uint8_t bits[FRAME_BYTES] = {1}; applyPackedFrameImmediate(bits, "fallback"); loop();
    require(g_fakeRefreshCount > before, "task creation failure renders queued main-loop changes");
    // A timeline must continue advancing under this same fallback.
    loadTimeline(); scrollSessionStart(100, false, 10);
    require(runtimeState().scrollFrameCount == 5, "fallback fixture has five distinguishable frames");
    const auto scrollRefreshes = g_fakeRefreshCount;
    const auto scrollAdvances = readLedPresentedSample().scrollAdvanceSeq;
    advanceMs(200); loop();
    require(runtimeState().scrollFrameIndex == 2 && runtimeFrameBits()[0] == 4,
            "fallback selects the second due frame after two intervals");
    require(g_fakeRefreshCount == scrollRefreshes + 1, "fallback presents newest due frame once without catch-up burst");
    const auto presented = readLedPresentedSample();
    require(presented.valid && presented.source == LedPresentationSource::ScrollTick &&
            presented.presentedFrameIndex == 2 && presented.presentedFrameCount == 5 &&
            presented.scrollAdvanceSeq == scrollAdvances + 1,
            "fallback records actual successful latch of the second due frame");
    // The fixture's bit 2 is in the forward-wired first row, physical LED 2.
    for (uint16_t physical = 0; physical < LED_COUNT; ++physical) {
        const auto* pixel = g_fakePixels[physical];
        require(pixel[0] == (physical == 2 ? runtimeState().colorR : 0) &&
                pixel[1] == (physical == 2 ? runtimeState().colorG : 0) &&
                pixel[2] == (physical == 2 ? runtimeState().colorB : 0),
                "fallback renders only the second frame's lit LED");
    }
    g_fakeTaskCreateResult = pdPASS;
    g_renderTaskReady = startScrollRenderTask();
    const auto taskRefreshes = g_fakeRefreshCount;
    applyPackedFrameImmediate(bits, "task-owned"); loop();
    require(g_fakeRefreshCount == taskRefreshes, "successful task creation disables cooperative renderer");
}

struct ReconnectingCarrier : rinalink::ITransport {
    ClientId mapped{0xFF}, old{0xFF}; bool connected = false, reconnected = false;
    Carrier carrier() const override { return Carrier::Ble; }
    bool send(ClientId, const uint8_t*, size_t, bool) override { return true; }
    uint16_t preferredChunkBytes(ClientId) const override { return 128; }
    void disconnect(ClientId id) override {
        if (!reconnected) {
            // The actual BLE connect callback can run immediately before old
            // teardown acquires its carrier mutex. Register using production registry.
            require(rinalink::transportRegisterClient(this, Carrier::Ble, &mapped), "reconnect registered during carrier teardown");
            connected = true; reconnected = true;
        }
        if (connected && mapped.slot == id.slot) connected = false;
    }
};

static void registryTeardown() {
    ReconnectingCarrier carrier;
    require(rinalink::transportRegisterClient(&carrier, Carrier::Ble, &carrier.old), "old BLE registered");
    serviceProtocol(); rinalink::transportUnregisterClient(carrier.old); serviceProtocol();
    require(carrier.connected && g_clients[carrier.mapped.slot].used, "old teardown leaves new BLE peer registered and connected");
    require(!g_clients[carrier.old.slot].used, "old registry slot released after carrier teardown");
    uint8_t ping[FRAME_HEADER_BYTES]; transportFrame(ping, msg::PING, 1, 0, nullptr, 0);
    require(rinalink::transportPushInbound(carrier.mapped, ping, sizeof(ping)) == sizeof(ping), "new peer owns usable inbound registry");
}

static void supersedeDuringRefresh() {
    g_fakeRefreshHook = nullptr;
    uint8_t bits[FRAME_BYTES] = {2}; LedPresentationContext ctx;
    ctx.valid = true; ctx.source = LedPresentationSource::ScrollStep;
    ctx.frameIndex = 2; ctx.frameCount = 5; strlcpy(ctx.timelineId, "new-owner", sizeof(ctx.timelineId));
    applyPackedFrameImmediate(bits, "new-owner", &ctx);
}

static void supersedeUntrackedDuringRefresh() {
    g_fakeRefreshHook = nullptr;
    uint8_t bits[FRAME_BYTES] = {4}; applyPackedFrameImmediate(bits, "manual-owner");
}

static void presentationRetry() {
    initLedIndexMap();
    for (auto source : {LedPresentationSource::ScrollStep, LedPresentationSource::ScrollTick}) {
        uint8_t bits[FRAME_BYTES] = {1}; LedPresentationContext ctx;
        ctx.valid = true; ctx.source = source; ctx.frameIndex = 4; ctx.frameCount = 5;
        ctx.firmwareScrollPaused = true; strlcpy(ctx.timelineId, "paused-timeline", sizeof(ctx.timelineId));
        applyPackedFrameImmediate(bits, "paused-final", &ctx);
        const auto seq = readLedPresentedSample().presentedSeq;
        g_fakeRefreshFailures = 1; renderCurrentFrameToLedStrip();
        require(readLedPresentedSample().presentedSeq == seq, "failed latch does not publish telemetry");
        renderCurrentFrameToLedStrip(); auto sample = readLedPresentedSample();
        require(sample.presentedSeq == seq + 1 && sample.presentedFrameIndex == 4 && sample.firmwareScrollPaused,
                "successful retry preserves paused seek/final context");
    }
    uint8_t bits[FRAME_BYTES] = {1}; LedPresentationContext old;
    old.valid = true; old.frameIndex = 4; old.frameCount = 5;
    applyPackedFrameImmediate(bits, "old-owner", &old);
    g_fakeRefreshFailures = 1; g_fakeRefreshHook = supersedeDuringRefresh;
    renderCurrentFrameToLedStrip(); renderCurrentFrameToLedStrip();
    auto sample = readLedPresentedSample();
    require(sample.presentedFrameIndex == 2 && std::string(sample.timelineId) == "new-owner", "retry never overwrites newer presentation owner");
    require(g_fakePixels[0][0] == 0 && g_fakePixels[1][0] == runtimeState().colorR, "retry pixels match newer owner");
    const auto seq = sample.presentedSeq;
    applyPackedFrameImmediate(bits, "old-owner", &old);
    g_fakeRefreshFailures = 1; g_fakeRefreshHook = supersedeUntrackedDuringRefresh;
    renderCurrentFrameToLedStrip(); renderCurrentFrameToLedStrip();
    require(readLedPresentedSample().presentedSeq == seq, "untracked newer manual owner does not inherit stale scroll identity");
    require(g_fakePixels[0][0] == 0 && g_fakePixels[2][0] == runtimeState().colorR, "untracked manual owner keeps its pixels");
}

static void wifiReplyOrdering(const std::string& name) {
    const bool hotspot = name == "wifi_reply_hotspot";
    wifiManagerBegin();
    if (hotspot) wifiManagerSetHotspotCredentials("Fixture", "fixture password");
    else wifiManagerSetCredentials("Fixture", "fixture password");
    wifiManagerSetMode("sta");
    WiFi.networks.push_back({"Fixture", -30}); WiFi.scanResult = 1; wifiManagerService();
    WiFi.stationStatus = WL_CONNECTED; wifiManagerService();
    require(WiFi.storedStaSsid == "Fixture", "station joined fixture before command");
    FakeTransport carrier(Carrier::Tcp); TestClient client;
    require(client.connect(carrier), "TCP mutation client connected");
    bool ackObserved = false;
    carrier.dropHook = [&](uint8_t, const uint8_t* data, size_t, bool event) {
        if (!event && data[1] == 0x81) {
            // This carrier becomes unusable immediately when the fake driver
            // disconnects: the original clear-before-reply implementation fails.
            if (WiFi.status() != WL_CONNECTED || WiFi.getMode() != WIFI_STA) return true;
            const auto key = name == "wifi_reply_mode" ? "mode" : (hotspot ? "hssid" : "ssid");
            require(Preferences::values[key] == (name == "wifi_reply_mode" ? "off" : ""),
                    "accepted mutation is persisted before ACK");
            ackObserved = true;
        }
        return false;
    };
    const auto command = name == "wifi_reply_mode" ? "{\"cmd\":\"wifi_set_mode\",\"mode\":\"off\"}" :
        (hotspot ? "{\"cmd\":\"wifi_clear_hotspot_credentials\"}" : "{\"cmd\":\"wifi_clear_credentials\"}");
    const auto reply = client.cmd(137, command);
    require(reply.first == 0x81 && parse(reply.second)["ok"].as<bool>() && ackObserved,
            "mutation ACK is sent while TCP carrier still exists");
    wifiManagerService(); advanceMs(99); wifiManagerService();
    require(WiFi.status() == WL_CONNECTED && WiFi.getMode() == WIFI_STA,
            "radio unchanged during reply grace");
    if (name == "wifi_reply_replace") {
        wifiManagerSetCredentials("Replacement", "replacement fixture password");
        WiFi.begin("Replacement", "replacement fixture password");
    }
    advanceMs(1); wifiManagerService();
    if (name == "wifi_reply_mode") {
        require(WiFi.getMode() == WIFI_OFF, "accepted mode applied after ACK grace");
    } else if (name == "wifi_reply_replace") {
        require(WiFi.status() == WL_CONNECTED && WiFi.storedStaSsid == "Replacement",
                "replacement credentials cancel delayed driver erase");
    } else {
        require(WiFi.status() != WL_CONNECTED && WiFi.storedStaSsid.isEmpty(),
                "accepted clear disconnects and erases driver after ACK grace");
    }
    // Later accepted modes coalesce, and an invalid mode cannot supersede one.
    require(wifiManagerSetMode("off", true), "first deferred mode accepted");
    advanceMs(50);
    require(wifiManagerSetMode("ap", true), "later deferred mode accepted");
    require(!wifiManagerSetMode("invalid", true), "invalid mode rejected before any radio work");
    advanceMs(99); wifiManagerService();
    const auto apCalls = WiFi.apCalls;
    advanceMs(1); wifiManagerService();
    require(WiFi.getMode() == WIFI_AP && WiFi.apCalls == apCalls + 1,
            "only latest accepted mode applies after its own grace");
    advanceMs(100); wifiManagerService();
    require(WiFi.apCalls == apCalls + 1, "coalesced mode is applied exactly once");
}

static void hintPriority() {
    initLedIndexMap(); showSettingsResetOverlay(true);
    String error; require(setHintLed(0, 1, 0, error), "hint accepted"); renderCurrentFrameToLedStrip();
    require(g_fakePixels[0][0] == 125 && g_fakePixels[0][1] == 57 && g_fakePixels[0][2] == 106, "hint overrides button overlay pixel");
    require(memcmp(g_fakePixels[0], g_fakePixels[1], 3) == 0, "mirrored hint overrides button overlay");
    setIdentifyOverlay(1, 1000); renderCurrentFrameToLedStrip();
    require(g_fakePixels[0][0] == 0 && g_fakePixels[0][1] == 0, "identify suppresses hint and button overlay");
}

int main(int argc, char** argv) {
    require(argc == 3, "case and isolated filesystem required"); resetFakeFs(argv[2]);
    initRuntimeScrollFrameBuffer(); protocolBegin(); const std::string name = argv[1];
    if (name == "battery") battery();
    else if (name == "group_end") groupEnd();
    else if (name == "group_loop") groupLoop();
    else if (name == "scroll_phase") scrollPhase();
    else if (name == "scroll_end_stall") scrollEndStall();
    else if (name == "scroll_pause_phase") scrollPausePhase();
    else if (name == "scroll_clock_wrap") scrollClockWrap();
    else if (name == "ap_validation") apValidation();
    else if (name == "ap_failure") apFailure();
    else if (name == "ap_initial_failure") apInitialFailure();
    else if (name == "scan_visibility") scanVisibility();
    else if (name == "scan_restore") scanRestore();
    else if (name == "clear_home" || name == "clear_hotspot" || name == "clear_pending" || name == "clear_ap" || name == "clear_off" || name == "clear_ap_retained") credentialClear(name);
    else if (name == "face_identity") faceIdentity(argv[2]);
    else if (name == "render_fallback") renderFallback();
    else if (name == "registry_teardown") registryTeardown();
    else if (name == "presentation_retry") presentationRetry();
    else if (name == "hint_priority") hintPriority();
    else if (name == "wifi_reply_home" || name == "wifi_reply_hotspot" ||
             name == "wifi_reply_mode" || name == "wifi_reply_replace") wifiReplyOrdering(name);
    else require(false, "unknown case");
    require(g_lockRecursion == 0 && g_lockOrderViolations == 0, "production lock discipline");
    std::cout << "PASS: " << name << '\n';
}
