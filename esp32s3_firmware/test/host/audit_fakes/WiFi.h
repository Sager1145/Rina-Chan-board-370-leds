#pragma once
#include <Arduino.h>
#include <IPAddress.h>
#include <vector>
enum wifi_mode_t { WIFI_OFF = 0, WIFI_STA = 1, WIFI_AP = 2, WIFI_AP_STA = 3 };
constexpr int WIFI_MODE_STA = WIFI_STA, WL_CONNECTED = 3;
constexpr int WIFI_SCAN_FAILED = -2, WIFI_SCAN_RUNNING = -1, WIFI_AUTH_OPEN = 0;
struct FakeNetwork { String ssid; int32_t rssi; int auth = 1; };
struct FakeAp {
    bool active = false;
    bool endResult = true;
    unsigned endCalls = 0, clients = 0;
    bool begin();
    bool end();
    bool started() const { return active; }
};
struct FakeSta { bool begin(bool tryConnect = true); };
struct FakeWifi {
    wifi_mode_t currentMode = WIFI_OFF;
    bool apResult = true, configResult = true;
    bool apStopsOnFailure = false;
    IPAddress configuredApIp;
    FakeAp AP;
    FakeSta STA;
    int stationStatus = 0;
    String storedStaSsid, storedStaPass;
    int scanStartResult = WIFI_SCAN_RUNNING, scanResult = WIFI_SCAN_RUNNING;
    String joinedSsid, appliedApSsid;
    unsigned apCalls = 0;
    std::vector<FakeNetwork> networks;
    bool setHostname(const char*) { return true; }
    wifi_mode_t getMode() const { return currentMode; }
    bool mode(wifi_mode_t mode) { currentMode = mode; if (!(mode & WIFI_AP)) AP.active = false; return true; }
    bool enableSTA(bool enabled) { currentMode = static_cast<wifi_mode_t>(enabled ? currentMode | WIFI_STA : currentMode & ~WIFI_STA); return true; }
    void setSleep(bool) {}
    bool softAPConfig(IPAddress, IPAddress, IPAddress) { return configResult; }
    bool softAP(const char* ssid, const char* = nullptr) {
        ++apCalls;
        if (apResult) { appliedApSsid = ssid; AP.active = true; }
        else if (apStopsOnFailure) AP.active = false;
        return apResult;
    }
    void softAPdisconnect(bool) { AP.active = false; }
    bool disconnect(bool off, bool erase = false) {
        if (!(currentMode & WIFI_STA)) return false;
        stationStatus = 0; joinedSsid = "";
        if (erase) { storedStaSsid = ""; storedStaPass = ""; }
        if (off) enableSTA(false);
        return true;
    }
    int status() { return stationStatus; }
    void begin(const char* ssid, const char* pass) {
        joinedSsid = ssid; storedStaSsid = ssid; storedStaPass = pass;
    }
    IPAddress localIP() { return {}; }
    IPAddress softAPIP() { return configuredApIp; }
    int softAPgetStationNum() { return AP.clients; }
    String SSID() { return joinedSsid; }
    String SSID(int i) { return networks.at(i).ssid; }
    int32_t RSSI() { return -30; }
    int32_t RSSI(int i) { return networks.at(i).rssi; }
    int encryptionType(int i) { return networks.at(i).auth; }
    int scanNetworks(bool, bool, bool, int) { return scanStartResult; }
    int scanComplete() { return scanResult; }
    void scanDelete() { networks.clear(); scanResult = WIFI_SCAN_RUNNING; }
};
extern FakeWifi WiFi;
inline bool FakeAp::begin() {
    WiFi.currentMode = static_cast<wifi_mode_t>(WiFi.currentMode | WIFI_AP);
    return true;
}
inline bool FakeAp::end() {
    ++endCalls;
    if (!endResult) return false;
    active = false; clients = 0;
    WiFi.currentMode = static_cast<wifi_mode_t>(WiFi.currentMode & ~WIFI_AP);
    return true;
}
inline bool FakeSta::begin(bool) { return WiFi.enableSTA(true); }
