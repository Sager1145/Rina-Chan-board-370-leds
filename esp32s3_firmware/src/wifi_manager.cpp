#include "wifi_manager.h"
#include "board_identity.h"
#include "config.h"
#include "utils.h"
#include "serial_log.h"
#include <WiFi.h>
#include <Preferences.h>
#include <ESPmDNS.h>

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

void startSoftAp() {
    WiFi.softAPConfig(apIP(), apGateway(), apSubnet());
    if (g_apPass.length() > 0)
        WiFi.softAP(g_apSsid.c_str(), g_apPass.c_str());
    else
        WiFi.softAP(g_apSsid.c_str());
    g_apActive = true;
}

void setActiveProfile(const String& profile) {
    if (g_activeProfile != profile) {
        g_activeProfile = profile;
        markChanged();
    }
}

bool ssidVisibleInScan(const String& ssid) {
    if (ssid.isEmpty())
        return false;
    for (uint8_t i = 0; i < g_scanResultCount; i++) {
        if (g_scanResults[i].ssid == ssid)
            return true;
    }
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
            if (n > 0) {
                int idx[64];
                int cnt = n > 64 ? 64 : n;
                for (int i = 0; i < cnt; i++)
                    idx[i] = i;
                for (int i = 0; i < cnt; i++) {
                    for (int j = i + 1; j < cnt; j++) {
                        if (WiFi.RSSI(idx[j]) > WiFi.RSSI(idx[i])) {
                            int t = idx[i];
                            idx[i] = idx[j];
                            idx[j] = t;
                        }
                    }
                }
                uint8_t limit = (uint8_t)(cnt < MAX_SCAN_RESULTS ? cnt : MAX_SCAN_RESULTS);
                for (uint8_t i = 0; i < limit; i++) {
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
            // Restore mode: only "ap" needed the STA bit added purely for the
            // scan; sta / sta_or_ap keep STA enabled regardless.
            if (g_mode == "ap")
                WiFi.enableSTA(false);
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
    wifi_mode_t m = WiFi.getMode();
    if (m == WIFI_AP) {
        // Add the STA bit without dropping the SoftAP (Arduino-ESP32 keeps AP
        // running when enableSTA(true) is called while mode is WIFI_AP).
        WiFi.enableSTA(true);
    } else if (m == WIFI_OFF) {
        WiFi.mode(WIFI_STA);
    }
    WiFi.setSleep(false);
    int res = WiFi.scanNetworks(true /*async*/, false, false, 300);
    if (res == WIFI_SCAN_FAILED) {
        if (m == WIFI_AP)
            WiFi.enableSTA(false);
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

void wifiManagerClearCredentials() {
    g_homeSsid = "";
    g_homePass = "";
    prefs.putString("ssid", "");
    prefs.putString("pass", "");
    g_homeFailCount = 0;
    markChanged();
}

bool wifiManagerSetHotspotCredentials(const String& ssid, const String& password) {
    if (ssid.isEmpty())
        return false;
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

void wifiManagerClearHotspotCredentials() {
    g_hotspotSsid = "";
    g_hotspotPass = "";
    prefs.putString("hssid", "");
    prefs.putString("hpass", "");
    g_hotspotFailCount = 0;
    markChanged();
}

bool wifiManagerSetMode(const String& mode) {
    if (mode != "off" && mode != "ap" && mode != "sta" && mode != "sta_or_ap")
        return false;
    g_mode = mode;
    prefs.putString("mode", g_mode);
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
    const bool cleared = prefs.clear();
    g_homeSsid = "";
    g_homePass = "";
    g_hotspotSsid = "";
    g_hotspotPass = "";
    g_apSsid = boardDefaultApSsid();
    g_apPass = AP_PASSWORD;
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

bool wifiManagerSetAp(const String& ssid, const String& password) {
    if (ssid.isEmpty())
        return false;
    if (ssid == LEGACY_AP_SSID) {
        // Sending the retired shared SSID means "reset to my unique default".
        g_apSsid = boardDefaultApSsid();
        if (prefs.isKey("apssid"))
            prefs.remove("apssid");
    } else {
        g_apSsid = ssid;
        prefs.putString("apssid", g_apSsid);
    }
    g_apPass = password;
    prefs.putString("appass", g_apPass);
    if (g_mode == "ap" || g_mode == "sta_or_ap")
        startSoftAp();
    markChanged();
    return true;
}

String wifiManagerApSsid() { return g_apSsid; }
