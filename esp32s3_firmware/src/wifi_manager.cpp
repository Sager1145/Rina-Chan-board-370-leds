#include "wifi_manager.h"
#include "config.h"
#include "utils.h"
#include <WiFi.h>
#include <Preferences.h>
#include <ESPmDNS.h>

namespace {

Preferences prefs;

String g_mode = "ap";          // off | ap | sta | sta_or_ap
String g_ssid;
String g_pass;
String g_apSsid = AP_SSID;
String g_apPass = AP_PASSWORD;

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
    if (MDNS.begin(RINALINK_HOSTNAME)) {
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

void applyMode() {
    g_staTrying = false;
    g_apActive = false;
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
        if (g_ssid.length())
            WiFi.begin(g_ssid.c_str(), g_pass.c_str());
        g_staTrying = true;
        g_staAttemptStartMs = millis();
        markChanged();
        return;
    }
    // sta_or_ap
    WiFi.mode(WIFI_AP_STA);
    WiFi.setSleep(false);
    startSoftAp();
    if (g_ssid.length()) {
        WiFi.begin(g_ssid.c_str(), g_pass.c_str());
        g_staTrying = true;
        g_staAttemptStartMs = millis();
    }
    markChanged();
}

} // namespace

void wifiManagerBegin() {
    prefs.begin("rinawifi", false);
    g_ssid = prefs.getString("ssid", "");
    g_pass = prefs.getString("pass", "");
    g_apSsid = prefs.getString("apssid", AP_SSID);
    g_apPass = prefs.getString("appass", AP_PASSWORD);
    String storedMode = prefs.getString("mode", "");
    if (storedMode.length()) {
        g_mode = storedMode;
    } else {
        g_mode = g_ssid.length() ? "sta_or_ap" : "ap";
    }
    g_prevMode = g_mode;
    applyMode();
}

void wifiManagerService() {
    if (g_mode != "off") {
        // STA connection watchdog: sta_or_ap falls back to AP-only-serving after
        // the timeout (SoftAP is already up); `sta` retries forever.
        if (g_staTrying) {
            if (WiFi.status() == WL_CONNECTED) {
                g_staTrying = false;
                markChanged();
            } else if (millisReached(millis(), g_staAttemptStartMs + WIFI_STA_CONNECT_TIMEOUT_MS)) {
                g_staTrying = false;
                g_lastStaRetryMs = millis();
                if (g_mode == "sta") {
                    // keep retrying forever
                    WiFi.disconnect();
                    WiFi.begin(g_ssid.c_str(), g_pass.c_str());
                    g_staTrying = true;
                    g_staAttemptStartMs = millis();
                } else {
                    markChanged(); // dropped into AP fallback
                }
            }
        } else if (g_ssid.length() && WiFi.status() != WL_CONNECTED &&
                   (g_mode == "sta" || g_mode == "sta_or_ap")) {
            if (millisReached(millis(), g_lastStaRetryMs + WIFI_STA_RETRY_MS)) {
                g_lastStaRetryMs = millis();
                WiFi.begin(g_ssid.c_str(), g_pass.c_str());
                g_staTrying = true;
                g_staAttemptStartMs = millis();
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
        }
    }
}

bool wifiManagerStateChanged() {
    bool v = g_stateChanged;
    g_stateChanged = false;
    return v;
}

void wifiManagerGetStatusJson(JsonObject out) {
    bool staConnected = WiFi.status() == WL_CONNECTED;
    out["ok"] = true;
    out["mode"] = g_mode;
    out["staConnected"] = staConnected;
    out["ssid"] = staConnected ? WiFi.SSID() : g_ssid;
    out["ip"] = staConnected ? WiFi.localIP().toString() : String("");
    out["rssi"] = staConnected ? WiFi.RSSI() : 0;
    out["apActive"] = g_apActive;
    out["apSsid"] = g_apSsid;
    out["apIp"] = apIP().toString();
    out["hostname"] = RINALINK_HOSTNAME;
    out["tcpPort"] = RINALINK_TCP_PORT;
    out["clients"] = g_apActive ? WiFi.softAPgetStationNum() : 0;
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
    g_ssid = ssid;
    g_pass = password;
    prefs.putString("ssid", g_ssid);
    prefs.putString("pass", g_pass);
    return true;
}

void wifiManagerClearCredentials() {
    g_ssid = "";
    g_pass = "";
    prefs.putString("ssid", "");
    prefs.putString("pass", "");
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
    g_lastStaRetryMs = 0; // let the next service() tick retry immediately
    if (g_ssid.length()) {
        WiFi.begin(g_ssid.c_str(), g_pass.c_str());
        g_staTrying = true;
        g_staAttemptStartMs = millis();
    }
}

bool wifiManagerSetAp(const String& ssid, const String& password) {
    if (ssid.isEmpty())
        return false;
    g_apSsid = ssid;
    g_apPass = password;
    prefs.putString("apssid", g_apSsid);
    prefs.putString("appass", g_apPass);
    if (g_mode == "ap" || g_mode == "sta_or_ap")
        startSoftAp();
    markChanged();
    return true;
}
