#pragma once
#include <Arduino.h>

// Stable per-board identity, derived once from the Bluetooth MAC address, and
// reused across every wireless surface (BLE name, INFO JSON, SoftAP SSID,
// mDNS hostname, Bonjour instance name) so two boards can never be confused
// by the app. See docs/RINALINK_PROTOCOL_V1.md "Board identity".

// 12 uppercase hex chars of the BT MAC, e.g. "80B54EF48E09". Computed once and
// cached; safe to call repeatedly and from multiple translation units.
const char* boardId();

// "RinaChanBoard-" + boardId(), e.g. "RinaChanBoard-80B54EF48E09" (26 chars).
String boardDefaultApSsid();

// "rinaboard-" + lowercase boardId(), e.g. "rinaboard-80b54ef48e09".
String boardHostname();

// "RinaBoard-" + boardId(), identical to the default BLE device name.
String boardServiceInstanceName();
