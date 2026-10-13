#include "wifi_manager.h"
#include "board_identity.h"
#include "config.h"
#include "ap_address_policy.h"
#include "utils.h"
#include "serial_log.h"
#include <WiFi.h>
#include <Preferences.h>
#include <ESPmDNS.h>
#include <esp_wifi.h>
#include <esp_netif.h>
#include <dhcpserver/dhcpserver.h>

namespace {

Preferences prefs;

String g_mode = "ap";          // off | ap | sta | sta_or_ap

// Two station credential profiles (docs/RINALINK_PROTOCOL_V1.md §8): "home"
// (the router) and "hotspot" (the phone's Personal Hotspot).
String g_homeSsid;
String g_homePass;
String g_hotspotSsid;
String g_hotspotPass;
// "" here, not boardDefaultApSsid(): the board's BT MAC (esp_read_mac) is not
// guaranteed ready at static-init time. Resolved to the real default in
// wifiManagerBegin()/wifiManagerFactoryReset() instead.
String g_apSsid = "";
String g_apPass = AP_PASSWORD;

String g_activeProfile = "none";     // none | home | hotspot — currently joined/joining profile
String g_connectingProfile = "none"; // profile the in-flight WiFi.begin() belongs to
uint8_t g_homeFailCount = 0;
uint8_t g_hotspotFailCount = 0;
bool g_staSelectionPending = false;  // waiting on a scan completion to pick a profile

// Only the radio side of a TCP mutation is deferred. Validation and NVS updates
// still finish before its ACK; this grace lets the socket's queued bytes leave
// before disconnecting the interface that carried the command.
constexpr uint32_t WIFI_REPLY_GRACE_MS = 100;
bool g_deferredHomeForget = false;
bool g_deferredHotspotForget = false;
bool g_deferredModeApply = false;
String g_deferredHomeSsid;
String g_deferredHotspotSsid;
uint32_t g_deferredRadioDueMs = 0;

void scheduleDeferredRadio() {
    g_deferredRadioDueMs = millis() + WIFI_REPLY_GRACE_MS;
}

bool g_staTrying = false;      // currently attempting a STA connection
uint32_t g_staAttemptStartMs = 0;
uint32_t g_lastStaRetryMs = 0;
bool g_apActive = false;
bool g_mdnsStarted = false;
IPAddress g_mdnsIp;
bool g_mdnsIsSta = false;

bool g_prevStaConnected = false;
bool g_prevApActive = false;
String g_prevMode;
bool g_stateChanged = false;

// --- Async scan state (item 4) ------------------------------------------------
struct ScanNetwork {
    String ssid;
    int32_t rssi = 0;
    bool secure = false;
};
constexpr uint8_t MAX_SCAN_RESULTS = 20;
bool g_scanInProgress = false;
bool g_scanResultReady = false;
ScanNetwork g_scanResults[MAX_SCAN_RESULTS];
uint8_t g_scanResultCount = 0;
bool g_homeVisibleInScan = false;
bool g_hotspotVisibleInScan = false;
wifi_mode_t g_scanRestoreMode = WIFI_OFF;
bool g_scanRestorePending = false;
uint32_t g_scanStartedAtMs = 0;

void restoreScanMode() {
    if (!g_scanRestorePending)
        return;
    g_scanRestorePending = false;
    RLOG_INFO("WIFI", "event=scan_lifecycle stage=restore_begin mode=%u elapsed_ms=%lu",
              static_cast<unsigned>(g_scanRestoreMode),
              static_cast<unsigned long>(millis() - g_scanStartedAtMs));
    const bool restored = WiFi.mode(g_scanRestoreMode);
    RLOG_INFO("WIFI", "event=scan_lifecycle stage=restore_end mode=%u result=%d elapsed_ms=%lu",
              static_cast<unsigned>(g_scanRestoreMode), restored ? 1 : 0,
              static_cast<unsigned long>(millis() - g_scanStartedAtMs));
}

void markChanged() { g_stateChanged = true; }

// Preferences::getString(key, default) logs an [E] line when the key (or the
// whole namespace) doesn't exist yet, which is the normal state on a fresh
// board. isKey() probes without logging, so guard every possibly-absent read.
String readStringOrDefault(Preferences& p, const char* key, const String& def) {
    return p.isKey(key) ? p.getString(key, def) : def;
}

void refreshMdns() {
    bool staConnected = WiFi.status() == WL_CONNECTED;
    if (!staConnected && !g_apActive)
        return;
    IPAddress ip = staConnected ? WiFi.localIP() : WiFi.softAPIP();
    bool changed = !g_mdnsStarted || ip != g_mdnsIp || staConnected != g_mdnsIsSta;
    if (!changed)
        return;
    if (g_mdnsStarted)
        MDNS.end();
    g_mdnsStarted = false;
    if (MDNS.begin(boardHostname().c_str())) {
        MDNS.setInstanceName(boardServiceInstanceName().c_str());
        MDNS.addService("rinalink", "tcp", RINALINK_TCP_PORT);
        g_mdnsStarted = true;
        g_mdnsIp = ip;
        g_mdnsIsSta = staConnected;
    }
}

bool configureApNetwork() {
    // Match Arduino's softAPConfig lifecycle: AP.begin waits for AP_STARTED
    // before touching the netif/DHCP server. WiFi.mode alone does not wait.
    if (!WiFi.AP.begin())
        return false;
    esp_netif_t* netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    if (!netif)
        return false;
    const esp_err_t stopped = esp_netif_dhcps_stop(netif);
    if (stopped != ESP_OK && stopped != ESP_ERR_ESP_NETIF_DHCP_ALREADY_STOPPED)
        return false;
    esp_netif_ip_info_t info{};
    info.ip.addr = static_cast<uint32_t>(apIP());
    info.gw.addr = static_cast<uint32_t>(apGateway());
    info.netmask.addr = static_cast<uint32_t>(apSubnet());
    if (esp_netif_set_ip_info(netif, &info) != ESP_OK)
        return false;
    const auto range = ap_address::leaseRange(apIP()[3]);
    dhcps_lease_t lease{};
    lease.enable = true;
    lease.start_ip.addr = static_cast<uint32_t>(IPAddress(apIP()[0], apIP()[1], apIP()[2], range.first));
    lease.end_ip.addr = static_cast<uint32_t>(IPAddress(apIP()[0], apIP()[1], apIP()[2], range.last));
    if (esp_netif_dhcps_option(netif, ESP_NETIF_OP_SET, ESP_NETIF_REQUESTED_IP_ADDRESS,
                              &lease, sizeof(lease)) != ESP_OK)
        return false;
    return esp_netif_dhcps_start(netif) == ESP_OK;
}

bool startSoftAp() {
    const bool wasActive = g_apActive;
    const bool applied = configureApNetwork() &&
        (g_apPass.length() > 0
             ? WiFi.softAP(g_apSsid.c_str(), g_apPass.c_str())
             : WiFi.softAP(g_apSsid.c_str()));
    // A rejected driver configuration can leave the previous AP serving. Keep
    // that recovery surface available, while reporting the update's failure.
    g_apActive = applied || (wasActive && WiFi.AP.started());
    return applied;
}

void setActiveProfile(const String& profile) {
    if (g_activeProfile != profile) {
        g_activeProfile = profile;
        markChanged();
    }
}

// The manager's profiles and IDF's last station configuration live in separate
// NVS namespaces. Forget the driver copy too, without resetting the AP/BLE or
// disconnecting a station owned by the other profile.
void forgetStationProfile(const char* profile, const String& forgottenSsid) {
    const bool noProfiles = g_homeSsid.isEmpty() && g_hotspotSsid.isEmpty();
    const bool ownsStation = g_activeProfile == profile ||
                             (g_staTrying && g_connectingProfile == profile);
    const bool otherOwnsStation = (g_activeProfile != "none" && g_activeProfile != profile) ||
                                  (g_staTrying && g_connectingProfile != profile);
    const wifi_mode_t originalMode = WiFi.getMode();
    wifi_config_t config{};
    esp_err_t readResult = esp_wifi_get_config(WIFI_IF_STA, &config);
    bool stationEnabled = false;
    // An off radio has no initialized driver to query. Start only the station
    // interface long enough to inspect/erase its historical persisted config.
    if (readResult != ESP_OK && originalMode == WIFI_OFF) {
        stationEnabled = WiFi.STA.begin(false);
        if (stationEnabled)
            readResult = esp_wifi_get_config(WIFI_IF_STA, &config);
    }
    char driverSsid[sizeof(config.sta.ssid) + 1]{};
    memcpy(driverSsid, config.sta.ssid, sizeof(config.sta.ssid));
    const bool matchesForgotten = readResult == ESP_OK && !forgottenSsid.isEmpty() &&
                                  forgottenSsid == driverSsid;
    const bool mustErase = noProfiles || ownsStation || (!otherOwnsStation && matchesForgotten);
    if (mustErase) {
        // begin(false) waits for STA_STARTED; enableSTA(true) alone does not.
        if (!stationEnabled)
            stationEnabled = WiFi.STA.begin(false);
        const bool erased = stationEnabled && WiFi.disconnect(false, true /* eraseap */);
        if (erased) {
            g_staTrying = false;
            g_connectingProfile = "none";
            if (noProfiles)
                g_staSelectionPending = false;
            g_lastStaRetryMs = millis();
            setActiveProfile("none");
        }
        RLOG_INFO("WIFI", "event=credentials_clear driver_erased=%d mode=%u",
                  erased ? 1 : 0, static_cast<unsigned>(originalMode));
    }
    if (!(originalMode & WIFI_MODE_STA) && stationEnabled)
        WiFi.mode(originalMode);
}

bool ssidVisibleInScan(const String& ssid) {
    if (ssid.isEmpty())
        return false;
    if (ssid == g_homeSsid)
        return g_homeVisibleInScan;
    if (ssid == g_hotspotSsid)
        return g_hotspotVisibleInScan;
    return false;
}

void beginProfile(const String& profile, const String& ssid, const String& pass) {
    WiFi.begin(ssid.c_str(), pass.c_str());
    g_connectingProfile = profile;
    g_staTrying = true;
    g_staAttemptStartMs = millis();
}

// Scan couldn't even start (e.g. driver busy) — join directly instead of
// churning forever on an empty scan result. Prefers "home", then "hotspot";
// skips a profile that just hit its fail limit unless it's the only one.
void staDirectFallback() {
    bool homeOk = g_homeSsid.length() && g_homeFailCount < WIFI_PROFILE_FAIL_LIMIT;
    bool hotspotOk = g_hotspotSsid.length() && g_hotspotFailCount < WIFI_PROFILE_FAIL_LIMIT;
    if (homeOk) {
        beginProfile("home", g_homeSsid, g_homePass);
    } else if (hotspotOk) {
        beginProfile("hotspot", g_hotspotSsid, g_hotspotPass);
    } else if (g_homeSsid.length()) {
        g_homeFailCount = 0;
        beginProfile("home", g_homeSsid, g_homePass);
    } else if (g_hotspotSsid.length()) {
        g_hotspotFailCount = 0;
        beginProfile("hotspot", g_hotspotSsid, g_hotspotPass);
    }
}

// Whenever a STA attempt is due (boot, wifi_connect, credentials change,
// retry timer) start (or piggyback on) the shared async scan; the result is
// consumed by evaluateScanResults() to pick "home" over "hotspot", or fall
// back to AP-only serving (sta_or_ap) / keep retrying (sta).
void startStaSelection() {
    if (!(g_homeSsid.length() || g_hotspotSsid.length()))
        return;
    if (wifiManagerScanInProgress()) {
        g_staSelectionPending = true;
        return;
    }
    g_staSelectionPending = true;
    if (!wifiManagerStartScan()) {
        g_staSelectionPending = false;
        staDirectFallback();
    }
}

void evaluateScanResults() {
    g_staSelectionPending = false;
    bool homeEligible = g_homeSsid.length() && ssidVisibleInScan(g_homeSsid);
    bool hotspotEligible = g_hotspotSsid.length() && ssidVisibleInScan(g_hotspotSsid);
    // A profile that just hit its fail limit is skipped for exactly this one
    // selection cycle, then its counter resets for a fresh set of tries.
    if (homeEligible && g_homeFailCount >= WIFI_PROFILE_FAIL_LIMIT) {
        homeEligible = false;
        g_homeFailCount = 0;
    }
    if (hotspotEligible && g_hotspotFailCount >= WIFI_PROFILE_FAIL_LIMIT) {
        hotspotEligible = false;
        g_hotspotFailCount = 0;
    }

    if (homeEligible) {
        beginProfile("home", g_homeSsid, g_homePass);
    } else if (hotspotEligible) {
        beginProfile("hotspot", g_hotspotSsid, g_hotspotPass);
    } else {
        // Nothing configured is visible: sta_or_ap keeps the SoftAP up, sta
        // just keeps retrying; both cases wait for the retry timer below.
        g_lastStaRetryMs = millis();
        setActiveProfile("none");
    }
}

void applyMode() {
    // A requested mode supersedes any temporary radio mode from an old scan.
    g_scanRestorePending = false;
    g_staTrying = false;
    g_staSelectionPending = false;
    g_apActive = false;
    setActiveProfile("none");
    // DHCP hostname must be set before the interface (re)starts below.
    WiFi.setHostname(boardHostname().c_str());
    if (g_mode == "off") {
        WiFi.softAPdisconnect(true);
        WiFi.disconnect(true);
        WiFi.mode(WIFI_OFF);
        markChanged();
        return;
    }
    if (g_mode == "ap") {
        WiFi.mode(WIFI_AP);
        WiFi.setSleep(false);
        startSoftAp();
        markChanged();
        return;
    }
    if (g_mode == "sta") {
        WiFi.mode(WIFI_STA);
        WiFi.setSleep(false);
        startStaSelection();
        markChanged();
        return;
    }
    // sta_or_ap
    WiFi.mode(WIFI_AP_STA);
    WiFi.setSleep(false);
    startSoftAp();
    startStaSelection();
    markChanged();
}

} // namespace

void wifiManagerBegin() {
    prefs.begin("rinawifi", false);
    g_homeSsid = readStringOrDefault(prefs, "ssid", "");
    g_homePass = readStringOrDefault(prefs, "pass", "");
    g_hotspotSsid = readStringOrDefault(prefs, "hssid", "");
    g_hotspotPass = readStringOrDefault(prefs, "hpass", "");
    String storedApSsid = readStringOrDefault(prefs, "apssid", "");
    if (storedApSsid.isEmpty() || storedApSsid == LEGACY_AP_SSID) {
        // Pre-identity firmware shared one SSID across every board; migrate to
        // this board's unique default and drop the stale stored value.
        if (storedApSsid == LEGACY_AP_SSID && prefs.isKey("apssid"))
            prefs.remove("apssid");
        g_apSsid = boardDefaultApSsid();
    } else {
        g_apSsid = storedApSsid;
    }
    g_apPass = readStringOrDefault(prefs, "appass", AP_PASSWORD);
    ap_address::IPv4 storedAddress{};
    const String storedApIp = readStringOrDefault(prefs, "apip", "");
    if (ap_address::parsePrivateHost(storedApIp.c_str(), storedAddress)) {
        setApIP(IPAddress(storedAddress.octets[0], storedAddress.octets[1],
                          storedAddress.octets[2], storedAddress.octets[3]));
    } else {
        setApIP(factoryApIP());
        // First production boot and invalid old overrides migrate only this
        // key; faces, station credentials and all other settings are retained.
        prefs.putString("apip", apIP().toString());
    }
    String storedMode = readStringOrDefault(prefs, "mode", "");
    if (storedMode.length()) {
        g_mode = storedMode;
    } else {
        g_mode = (g_homeSsid.length() || g_hotspotSsid.length()) ? "sta_or_ap" : "ap";
    }
    g_prevMode = g_mode;
    applyMode();
}

void wifiManagerService() {
    if ((g_deferredHomeForget || g_deferredHotspotForget || g_deferredModeApply) &&
        millisReached(millis(), g_deferredRadioDueMs)) {
        const bool forgetHome = g_deferredHomeForget;
        const bool forgetHotspot = g_deferredHotspotForget;
        const bool applyRequestedMode = g_deferredModeApply;
        g_deferredHomeForget = g_deferredHotspotForget = g_deferredModeApply = false;
        if (forgetHome)
            forgetStationProfile("home", g_deferredHomeSsid);
        // Clearing both profiles needs one driver erase, since noProfiles in
        // forgetStationProfile already disconnects/erases any station owner.
        if (forgetHotspot && !(forgetHome && g_homeSsid.isEmpty() && g_hotspotSsid.isEmpty()))
            forgetStationProfile("hotspot", g_deferredHotspotSsid);
        g_deferredHomeSsid = g_deferredHotspotSsid = "";
        if (applyRequestedMode)
            applyMode(); // latest accepted mode supersedes earlier requests
        markChanged();
    }
    if (g_mode != "off") {
        bool staConfigured = g_homeSsid.length() || g_hotspotSsid.length();
        // STA connection watchdog: sta_or_ap falls back to AP-only-serving
        // after the timeout (SoftAP is already up); `sta` retries via the
        // same WIFI_STA_RETRY_MS timer below.
        if (g_staTrying) {
            if (WiFi.status() == WL_CONNECTED) {
                g_staTrying = false;
                if (g_connectingProfile == "home")
                    g_homeFailCount = 0;
                else if (g_connectingProfile == "hotspot")
                    g_hotspotFailCount = 0;
                setActiveProfile(g_connectingProfile);
                markChanged();
            } else if (millisReached(millis(), g_staAttemptStartMs + WIFI_STA_CONNECT_TIMEOUT_MS)) {
                g_staTrying = false;
                g_lastStaRetryMs = millis();
                if (g_connectingProfile == "home" && g_homeFailCount < 255)
                    g_homeFailCount++;
                else if (g_connectingProfile == "hotspot" && g_hotspotFailCount < 255)
                    g_hotspotFailCount++;
                setActiveProfile("none");
                markChanged(); // dropped into AP fallback / will retry
            }
        } else if (!g_staSelectionPending && staConfigured && WiFi.status() != WL_CONNECTED &&
                   (g_mode == "sta" || g_mode == "sta_or_ap")) {
            if (millisReached(millis(), g_lastStaRetryMs + WIFI_STA_RETRY_MS)) {
                g_lastStaRetryMs = millis();
                startStaSelection();
            }
        }

        refreshMdns();

        bool staConnected = WiFi.status() == WL_CONNECTED;
        if (staConnected != g_prevStaConnected || g_apActive != g_prevApActive || g_mode != g_prevMode) {
            g_prevStaConnected = staConnected;
            g_prevApActive = g_apActive;
            g_prevMode = g_mode;
            markChanged();
        }
    }

    // Poll an in-progress async scan regardless of mode (a scan may have been
    // started while in "ap" mode by temporarily flipping on the STA bit).
    if (g_scanInProgress) {
        int n = WiFi.scanComplete();
        if (n >= 0 || n == WIFI_SCAN_FAILED) {
            RLOG_INFO("WIFI", "event=scan_lifecycle stage=driver_complete count=%d elapsed_ms=%lu",
                      n, static_cast<unsigned long>(millis() - g_scanStartedAtMs));
            g_homeVisibleInScan = false;
            g_hotspotVisibleInScan = false;
            if (n > 0) {
                // Resolve profile visibility across the entire scan, while
                // retaining only the strongest 20 entries for the UI response.
                int idx[MAX_SCAN_RESULTS];
                uint8_t limit = 0;
                for (int i = 0; i < n; ++i) {
                    const String ssid = WiFi.SSID(i);
                    if (ssid == g_homeSsid && !ssid.isEmpty())
                        g_homeVisibleInScan = true;
                    if (ssid == g_hotspotSsid && !ssid.isEmpty())
                        g_hotspotVisibleInScan = true;
                    uint8_t position = 0;
                    while (position < limit && WiFi.RSSI(idx[position]) >= WiFi.RSSI(i))
                        ++position;
                    if (position >= MAX_SCAN_RESULTS)
                        continue;
                    if (limit < MAX_SCAN_RESULTS)
                        ++limit;
                    for (uint8_t j = limit - 1; j > position; --j)
                        idx[j] = idx[j - 1];
                    idx[position] = i;
                }
                for (uint8_t i = 0; i < limit; ++i) {
                    g_scanResults[i].ssid = WiFi.SSID(idx[i]);
                    g_scanResults[i].rssi = WiFi.RSSI(idx[i]);
                    g_scanResults[i].secure = WiFi.encryptionType(idx[i]) != WIFI_AUTH_OPEN;
                }
                g_scanResultCount = limit;
            } else {
                g_scanResultCount = 0;
            }
            WiFi.scanDelete();
            g_scanInProgress = false;
            g_scanResultReady = true;
            RLOG_INFO("WIFI", "event=scan_lifecycle stage=cache_ready count=%u elapsed_ms=%lu",
                      static_cast<unsigned>(g_scanResultCount),
                      static_cast<unsigned long>(millis() - g_scanStartedAtMs));
            restoreScanMode();
            if (g_staSelectionPending)
                evaluateScanResults();
        }
    }
}

bool wifiManagerStateChanged() {
    bool v = g_stateChanged;
    g_stateChanged = false;
    return v;
}

// Non-consuming variant for observers that must not steal the EV_WIFI edge
// (web_setup.cpp uses it to decide when to re-check whether HTTP should be up).
bool wifiManagerStateChangedPeek() {
    return g_stateChanged;
}

void wifiManagerGetStatusJson(JsonObject out) {
    bool staConnected = WiFi.status() == WL_CONNECTED;
    out["ok"] = true;
    out["mode"] = g_mode;
    out["staConnected"] = staConnected;
    out["ssid"] = staConnected ? WiFi.SSID() : g_homeSsid;
    out["ip"] = staConnected ? WiFi.localIP().toString() : String("");
    out["rssi"] = staConnected ? WiFi.RSSI() : 0;
    out["apActive"] = g_apActive;
    out["apSsid"] = g_apSsid;
    out["apIp"] = apIP().toString();
    out["hostname"] = boardHostname();
    out["boardId"] = boardId();
    out["tcpPort"] = RINALINK_TCP_PORT;
    out["clients"] = g_apActive ? WiFi.softAPgetStationNum() : 0;
    out["homeSsid"] = g_homeSsid;
    out["hotspotSsid"] = g_hotspotSsid;
    out["activeProfile"] = g_activeProfile;
    out["scanPending"] = g_scanInProgress;
}

bool wifiManagerStartScan() {
    if (g_scanInProgress)
        return true;
    g_scanStartedAtMs = millis();
    RLOG_INFO("WIFI", "event=scan_lifecycle stage=start_begin");
    wifi_mode_t m = WiFi.getMode();
    RLOG_INFO("WIFI", "event=scan_lifecycle stage=mode_read mode=%u",
              static_cast<unsigned>(m));
    g_scanRestoreMode = m;
    g_scanRestorePending = m == WIFI_AP || m == WIFI_OFF;
    if (m == WIFI_AP) {
        // Add the STA bit without dropping the SoftAP (Arduino-ESP32 keeps AP
        // running when enableSTA(true) is called while mode is WIFI_AP).
        RLOG_INFO("WIFI", "event=scan_lifecycle stage=sta_enable_begin mode=%u",
                  static_cast<unsigned>(m));
        const bool enabled = WiFi.enableSTA(true);
        RLOG_INFO("WIFI", "event=scan_lifecycle stage=sta_enable_end result=%d elapsed_ms=%lu",
                  enabled ? 1 : 0, static_cast<unsigned long>(millis() - g_scanStartedAtMs));
    } else if (m == WIFI_OFF) {
        RLOG_INFO("WIFI", "event=scan_lifecycle stage=sta_enable_begin mode=%u",
                  static_cast<unsigned>(m));
        const bool enabled = WiFi.mode(WIFI_STA);
        RLOG_INFO("WIFI", "event=scan_lifecycle stage=sta_enable_end result=%d elapsed_ms=%lu",
                  enabled ? 1 : 0, static_cast<unsigned long>(millis() - g_scanStartedAtMs));
    }
    WiFi.setSleep(false);
    RLOG_INFO("WIFI", "event=scan_lifecycle stage=driver_start_begin elapsed_ms=%lu",
              static_cast<unsigned long>(millis() - g_scanStartedAtMs));
    int res = WiFi.scanNetworks(true /*async*/, false, false, 300);
    RLOG_INFO("WIFI", "event=scan_lifecycle stage=driver_start_end result=%d elapsed_ms=%lu",
              res, static_cast<unsigned long>(millis() - g_scanStartedAtMs));
    if (res == WIFI_SCAN_FAILED) {
        restoreScanMode();
        return false;
    }
    g_scanInProgress = true;
    g_scanResultReady = false;
    return true;
}

bool wifiManagerScanInProgress() { return g_scanInProgress; }

bool wifiManagerScanResultReady() {
    bool v = g_scanResultReady;
    g_scanResultReady = false;
    return v;
}

void wifiManagerGetScanJson(JsonArray out) {
    for (uint8_t i = 0; i < g_scanResultCount; i++) {
        JsonObject o = out.createNestedObject();
        o["ssid"] = g_scanResults[i].ssid;
        o["rssi"] = g_scanResults[i].rssi;
        o["secure"] = g_scanResults[i].secure;
    }
}

bool wifiManagerSetCredentials(const String& ssid, const String& password) {
    if (ssid.isEmpty())
        return false;
    // A replacement supersedes a deferred forget of this profile. Never let
    // the old clear erase the replacement driver's credentials on a later tick.
    g_deferredHomeForget = false;
    g_deferredHomeSsid = "";
    g_homeSsid = ssid;
    g_homePass = password;
    prefs.putString("ssid", g_homeSsid);
    prefs.putString("pass", g_homePass);
    g_homeFailCount = 0;
    markChanged();
    if (g_mode == "sta" || g_mode == "sta_or_ap")
        startStaSelection();
    return true;
}

void wifiManagerClearCredentials(bool deferRadio) {
    const String forgottenSsid = g_homeSsid;
    g_homeSsid = "";
    g_homePass = "";
    prefs.putString("ssid", "");
    prefs.putString("pass", "");
    g_homeFailCount = 0;
    g_deferredHomeForget = deferRadio;
    g_deferredHomeSsid = deferRadio ? forgottenSsid : String();
    if (deferRadio)
        scheduleDeferredRadio();
    else
        forgetStationProfile("home", forgottenSsid);
    markChanged();
}

bool wifiManagerSetHotspotCredentials(const String& ssid, const String& password) {
    if (ssid.isEmpty())
        return false;
    g_deferredHotspotForget = false;
    g_deferredHotspotSsid = "";
    g_hotspotSsid = ssid;
    g_hotspotPass = password;
    prefs.putString("hssid", g_hotspotSsid);
    prefs.putString("hpass", g_hotspotPass);
    g_hotspotFailCount = 0;
    markChanged();
    if (g_mode == "sta" || g_mode == "sta_or_ap")
        startStaSelection();
    return true;
}

void wifiManagerClearHotspotCredentials(bool deferRadio) {
    const String forgottenSsid = g_hotspotSsid;
    g_hotspotSsid = "";
    g_hotspotPass = "";
    prefs.putString("hssid", "");
    prefs.putString("hpass", "");
    g_hotspotFailCount = 0;
    g_deferredHotspotForget = deferRadio;
    g_deferredHotspotSsid = deferRadio ? forgottenSsid : String();
    if (deferRadio)
        scheduleDeferredRadio();
    else
        forgetStationProfile("hotspot", forgottenSsid);
    markChanged();
}

bool wifiManagerSetMode(const String& mode, bool deferRadio) {
    if (mode != "off" && mode != "ap" && mode != "sta" && mode != "sta_or_ap")
        return false;
    g_mode = mode;
    prefs.putString("mode", g_mode);
    g_deferredModeApply = deferRadio;
    if (deferRadio)
        scheduleDeferredRadio();
    else
        applyMode();
    markChanged();
    return true;
}

void wifiManagerConnect() {
    if (g_mode == "off")
        return;
    g_lastStaRetryMs = millis() - WIFI_STA_RETRY_MS; // make the next service() tick eligible to retry
    startStaSelection();
}

void wifiManagerFactoryReset() {
    g_deferredHomeForget = g_deferredHotspotForget = g_deferredModeApply = false;
    g_deferredHomeSsid = g_deferredHotspotSsid = "";
    const IPAddress defaultApIp = factoryApIP();
    if (apIP() != defaultApIp) {
        // Resetting an edited subnet also requires reassociation: applyMode()
        // alone keeps same-SSID AP clients and their previous DHCP leases.
        // AP.end removes only the AP bit; station erasure below keeps its
        // existing factory-reset behavior.
        if (WiFi.AP.end())
            g_apActive = false;
    }
    const bool cleared = prefs.clear();
    g_homeSsid = "";
    g_homePass = "";
    g_hotspotSsid = "";
    g_hotspotPass = "";
    g_apSsid = boardDefaultApSsid();
    g_apPass = AP_PASSWORD;
    setApIP(defaultApIp);
    prefs.putString("apip", apIP().toString());
    g_mode = "ap";
    g_homeFailCount = 0;
    g_hotspotFailCount = 0;
    g_staSelectionPending = false;
    // WiFi.begin() also stored the last STA credentials in the IDF's own NVS;
    // erasing them needs the STA interface up (applyMode() drops it again).
    if (!(WiFi.getMode() & WIFI_MODE_STA))
        WiFi.enableSTA(true);
    WiFi.disconnect(false, true /* eraseap */);
    applyMode();
    markChanged();
    RLOG_INFO("WIFI", "event=factory_reset prefs_cleared=%d", cleared ? 1 : 0);
}

bool wifiManagerSetAp(const String& ssid, const String& password, const char* ip) {
    const bool ipOnly = ip != nullptr && ssid.isEmpty() && password.isEmpty();
    ap_address::IPv4 parsed{};
    if ((ip && !ap_address::parsePrivateHost(ip, parsed)) ||
        (!ipOnly && (ssid.isEmpty() || ssid.length() > 32 ||
          (password.length() > 0 && password.length() < 8) || password.length() > 63)))
        return false;
    const String previousSsid = g_apSsid;
    const String previousPass = g_apPass;
    const IPAddress previousIp = apIP();
    const IPAddress nextIp = ip ? IPAddress(parsed.octets[0], parsed.octets[1],
                                            parsed.octets[2], parsed.octets[3]) : previousIp;
    const bool servingAp = g_mode == "ap" || g_mode == "sta_or_ap";
    const bool restartAp = servingAp && nextIp != previousIp;
    if (restartAp) {
        // Existing same-SSID clients otherwise keep their previous DHCP lease
        // after a subnet edit. Remove only the AP bit so they must reassociate;
        // Arduino preserves an active STA interface and Bluetooth throughout.
        if (!WiFi.AP.end())
            return false;
        g_apActive = false;
    }
    const auto restorePreviousAp = [&]() {
        g_apSsid = previousSsid;
        g_apPass = previousPass;
        setApIP(previousIp);
        if (servingAp) {
            if (restartAp) {
                WiFi.AP.end();
                g_apActive = false;
            }
            startSoftAp();
        }
        markChanged();
    };
    if (!ipOnly) {
        g_apSsid = ssid == LEGACY_AP_SSID ? boardDefaultApSsid() : ssid;
        g_apPass = password;
    }
    setApIP(nextIp);
    if (servingAp && !startSoftAp()) {
        // Restore the serving configuration too: set_ip_info may have
        // succeeded before DHCP or the radio rejected the candidate.
        restorePreviousAp();
        return false;
    }
    if (ip && prefs.putString("apip", apIP().toString()) == 0) {
        restorePreviousAp();
        return false;
    }
    if (!ipOnly && ssid == LEGACY_AP_SSID) {
        // Sending the retired shared SSID means "reset to my unique default".
        if (prefs.isKey("apssid"))
            prefs.remove("apssid");
    } else if (!ipOnly) {
        prefs.putString("apssid", g_apSsid);
    }
    if (!ipOnly)
        prefs.putString("appass", g_apPass);
    markChanged();
    return true;
}

String wifiManagerApSsid() { return g_apSsid; }
