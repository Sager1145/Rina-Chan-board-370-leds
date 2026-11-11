// Wi-Fi manager regressions for the 44-finding audit. Built and run by
// audit_repairs_test.py against the production translation units:
//   RINA_AUDIT_CASE_SOURCE=test/host/fix44_wifi_cases.cpp python3 test/host/audit_repairs_test.py \
//     fix44_sta_timeout fix44_profile_reconcile fix44_credential_limits fix44_scan_utf8 fix44_factory_erase
#include "protocol.cpp"
#include "scroll.cpp"
#include "main.cpp"
#include "stress_common.h"
#include <Preferences.h>
#include <WiFi.h>

static void require(bool condition, const char* message) {
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

static JsonObject wifiStatus(DynamicJsonDocument& doc) {
    JsonObject status = doc.to<JsonObject>(); wifiManagerGetStatusJson(status); return status;
}

// Home profile stored, sta_or_ap, scan sees it: leaves a WiFi.begin("Home") in flight.
static void beginHomeJoin() {
    wifiManagerBegin();
    require(wifiManagerSetCredentials("Home", "home-pass"), "home credentials accepted");
    require(wifiManagerSetMode("sta_or_ap"), "AP+STA mode enabled");
    WiFi.networks.push_back({"Home", -27});
    WiFi.scanResult = 1; wifiManagerService();
    require(WiFi.joinedSsid == "Home", "scan-selected home join started");
}

static void staTimeout() {
    beginHomeJoin();
    DynamicJsonDocument doc(2048);
    advanceMs(WIFI_STA_CONNECT_TIMEOUT_MS - 1); wifiManagerService();
    require(WiFi.joinedSsid == "Home", "join keeps running until the watchdog expires");
    advanceMs(1); wifiManagerService();
    require(WiFi.joinedSsid.isEmpty(), "watchdog timeout stops the driver's own join attempt");
    require(WiFi.storedStaSsid == "Home" && WiFi.storedStaPass == "home-pass",
            "watchdog timeout keeps the driver's stored station config");
    auto status = wifiStatus(doc);
    require(status["activeProfile"] == "none" && status["apActive"].as<bool>() &&
            !status["staConnected"].as<bool>(), "timeout falls back to the still-serving SoftAP");
    // A link that comes up outside a tracked attempt is still attributed.
    WiFi.joinedSsid = "Home"; WiFi.stationStatus = WL_CONNECTED; wifiManagerService();
    status = wifiStatus(doc);
    require(status["staConnected"].as<bool>() && status["activeProfile"] == "home",
            "late join is reconciled to its owning profile");
}

static void profileReconcile() {
    beginHomeJoin();
    DynamicJsonDocument doc(2048);
    WiFi.stationStatus = WL_CONNECTED; wifiManagerService();
    require(wifiStatus(doc)["activeProfile"] == "home", "tracked join owns the station");
    // wifi_connect while joined, with the joined SSID missing from that one scan.
    wifiManagerConnect();
    WiFi.scanResult = 0; wifiManagerService(); wifiManagerService();
    auto status = wifiStatus(doc);
    require(WiFi.status() == WL_CONNECTED && WiFi.joinedSsid == "Home" && status["activeProfile"] == "home",
            "a scan that misses the joined network keeps link and profile");
    // Replacement credentials for a network the scan cannot see.
    require(wifiManagerSetCredentials("Elsewhere", "other-pass"), "replacement credentials accepted");
    WiFi.scanResult = 0; wifiManagerService();
    advanceMs(1000); wifiManagerService(); // reconciliation is polled once a second
    status = wifiStatus(doc);
    require(WiFi.status() != WL_CONNECTED && WiFi.joinedSsid.isEmpty(),
            "station leaves a network whose credentials were replaced");
    require(status["activeProfile"] == "none" && status["homeSsid"] == "Elsewhere" &&
            status["apActive"].as<bool>(), "status no longer reports the replaced network as joined");
    // The next retry cycle joins the replacement once it is visible.
    advanceMs(WIFI_STA_RETRY_MS); wifiManagerService();
    WiFi.networks.push_back({"Elsewhere", -40});
    WiFi.scanResult = 1; wifiManagerService();
    require(WiFi.joinedSsid == "Elsewhere", "retry timer joins the replacement network");
    // A stale WL_CONNECTED for another SSID must not complete this attempt.
    WiFi.joinedSsid = "Home"; WiFi.stationStatus = WL_CONNECTED; wifiManagerService();
    require(wifiStatus(doc)["activeProfile"] == "none", "connected to another SSID is not a successful join");
    WiFi.joinedSsid = "Elsewhere"; wifiManagerService();
    require(wifiStatus(doc)["activeProfile"] == "home", "attempted SSID joined completes the attempt");
}

static void credentialLimits() {
    wifiManagerBegin();
    const String ssid32(std::string(32, 's')), ssid33(std::string(33, 's'));
    const String pass64(std::string(64, 'a')), pass65(std::string(65, 'a'));
    require(wifiManagerSetCredentials("Home", "home-pass"), "valid home credentials accepted");
    require(wifiManagerSetHotspotCredentials("Hotspot", "hotspot-pass"), "valid hotspot credentials accepted");
    const auto writes = Preferences::writes;
    for (const auto& invalid : {std::pair<String, String>{"", "12345678"}, {ssid33, "12345678"},
            {String(std::string(400, 's')), ""}, {"Bad", "short"}, {"Bad", pass65}}) {
        require(!wifiManagerSetCredentials(invalid.first, invalid.second), "invalid home byte lengths rejected");
        require(!wifiManagerSetHotspotCredentials(invalid.first, invalid.second), "invalid hotspot byte lengths rejected");
        require(Preferences::writes == writes && Preferences::values["ssid"] == "Home" &&
                Preferences::values["hssid"] == "Hotspot", "rejected credentials preserve stored profiles");
    }
    require(wifiManagerSetCredentials(ssid32, pass64), "maximum home byte lengths accepted");
    require(wifiManagerSetHotspotCredentials(ssid32, ""), "open hotspot network accepted");
    require(Preferences::values["ssid"] == ssid32 && Preferences::values["hpass"].isEmpty(),
            "accepted credentials are persisted");
    // An oversized SSID persisted by older firmware is ignored after reboot.
    Preferences::values["ssid"] = String(std::string(400, 's'));
    wifiManagerBegin();
    DynamicJsonDocument doc(2048);
    auto status = wifiStatus(doc);
    require(status["homeSsid"] == "" && status["hotspotSsid"] == ssid32.c_str() && !status["scanPending"].isNull(),
            "oversized stored SSID cannot truncate the status document");
}

static void scanUtf8() {
    wifiManagerBegin();
    require(wifiManagerStartScan(), "scan starts");
    WiFi.networks.push_back({"Good", -30});
    WiFi.networks.push_back({"\xC4\xE3\xBA\xC3", -20});            // GBK, not UTF-8
    WiFi.networks.push_back({"Tab\tname", -25});                   // control byte
    WiFi.networks.push_back({"\xE7\x92\x83\xE5\xA5\x88", -40});    // well-formed UTF-8
    WiFi.networks.push_back({"\xF0\x9F\x98", -45});                // truncated sequence
    WiFi.networks.push_back({"\xC0\xAF", -50});                    // overlong form
    WiFi.networks.push_back({"\xED\xA0\x80", -55});                // surrogate
    WiFi.scanResult = static_cast<int>(WiFi.networks.size()); wifiManagerService();
    DynamicJsonDocument doc(2048); auto networks = doc.to<JsonArray>(); wifiManagerGetScanJson(networks);
    require(networks.size() == 2, "SSIDs that would break the JSON reply are left out");
    require(networks[0]["ssid"] == "Good" && networks[1]["ssid"] == "\xE7\x92\x83\xE5\xA5\x88",
            "ASCII and well-formed UTF-8 SSIDs are reported in signal order");
}

static void factoryErase() {
    wifiManagerBegin();
    for (const char* mode : {"ap", "off"}) {
        require(wifiManagerSetMode(mode), "station-less mode applied");
        require(!(WiFi.getMode() & WIFI_MODE_STA), "station interface is down before the reset");
        WiFi.storedStaSsid = "Home"; WiFi.storedStaPass = "home-pass";
        wifiManagerFactoryReset();
        require(WiFi.storedStaSsid.isEmpty() && WiFi.storedStaPass.isEmpty(),
                "factory reset erases driver-stored station credentials with the station down");
        require(WiFi.getMode() == WIFI_AP && WiFi.AP.active, "factory reset ends in AP-only mode");
    }
}

int main(int argc, char** argv) {
    require(argc == 3, "case and isolated filesystem required"); resetFakeFs(argv[2]);
    initRuntimeScrollFrameBuffer(); protocolBegin(); const std::string name = argv[1];
    if (name == "fix44_sta_timeout") staTimeout();
    else if (name == "fix44_profile_reconcile") profileReconcile();
    else if (name == "fix44_credential_limits") credentialLimits();
    else if (name == "fix44_scan_utf8") scanUtf8();
    else if (name == "fix44_factory_erase") factoryErase();
    else require(false, "unknown fix44 Wi-Fi case");
    require(g_lockRecursion == 0 && g_lockOrderViolations == 0, "production lock discipline");
    std::cout << "PASS: " << name << '\n';
}
