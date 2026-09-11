#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

// RinaLink Wi-Fi manager: NVS-persisted credentials + run mode state machine
// (off | ap | sta | sta_or_ap), async scan, SoftAP config. Two station
// credential profiles ("home" and "hotspot") are scan-selected on every STA
// attempt (docs/RINALINK_PROTOCOL_V1.md section 8). See section 4 for the
// wire-level CMD contract that protocol.cpp implements on top of these
// functions.

void wifiManagerBegin();
void wifiManagerService();

// True once since the last call if mode/connection/AP state changed (drives EV_WIFI).
bool wifiManagerStateChanged();
bool wifiManagerStateChangedPeek();

// Fills the same fields documented for `wifi_status` in the protocol spec.
void wifiManagerGetStatusJson(JsonObject out);

// Async scan (item 4). wifiManagerStartScan() kicks off a non-blocking
// WiFi.scanNetworks(); wifiManagerService() polls WiFi.scanComplete() and
// stores up to 20 results sorted by RSSI. wifiManagerScanResultReady() is
// consume-once: it returns true exactly once per completed scan.
bool wifiManagerStartScan();
bool wifiManagerScanInProgress();
bool wifiManagerScanResultReady();
void wifiManagerGetScanJson(JsonArray out);

bool wifiManagerSetCredentials(const String& ssid, const String& password);
void wifiManagerClearCredentials();

// v1.2 (docs/RINALINK_PROTOCOL_V1.md §8): second station profile, the phone's
// Personal Hotspot. Stored in NVS keys hssid/hpass alongside the home ssid/pass.
bool wifiManagerSetHotspotCredentials(const String& ssid, const String& password);
void wifiManagerClearHotspotCredentials();

bool wifiManagerSetMode(const String& mode);
void wifiManagerConnect();
bool wifiManagerSetAp(const String& ssid, const String& password);
