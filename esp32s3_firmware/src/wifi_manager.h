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
// Forget this profile from manager/driver NVS and disconnect it if active or
// connecting. Preserve the other station profile, requested mode, AP and BLE.
// RinaLink TCP callers defer radio disruption until the queued reply has had
// time to leave the socket; credential persistence remains synchronous.
void wifiManagerClearCredentials(bool deferRadio = false);

// v1.2 (docs/RINALINK_PROTOCOL_V1.md §8): second station profile, the phone's
// Personal Hotspot. Stored in NVS keys hssid/hpass alongside the home ssid/pass.
bool wifiManagerSetHotspotCredentials(const String& ssid, const String& password);
void wifiManagerClearHotspotCredentials(bool deferRadio = false);

bool wifiManagerSetMode(const String& mode, bool deferRadio = false);
void wifiManagerConnect();
// nullptr retains the configured address. An explicit IP with empty SSID and
// password updates only the address; legacy credential-only calls are unchanged.
bool wifiManagerSetAp(const String& ssid, const String& password, const char* ip = nullptr);

// Current SoftAP SSID (board-unique default unless overridden). Used by
// serial_console.cpp's STATUS line.
String wifiManagerApSsid();

// Physical-button factory reset (B6 held 10 s): wipes the "rinawifi" NVS
// namespace, restores AP-only defaults, and re-applies the mode live.
void wifiManagerFactoryReset();
