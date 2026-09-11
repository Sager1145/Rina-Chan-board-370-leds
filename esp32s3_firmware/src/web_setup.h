#pragma once

// RinaLink Wi-Fi setup page (docs/RINALINK_PROTOCOL_V1.md §7.3): the only web UI
// left in the firmware. A ~10 KB PROGMEM page served on port 80 whenever Wi-Fi
// is up (STA connected or SoftAP active), plus a captive-portal DNS server
// (AP_DOMAIN -> board IP) while the SoftAP is active. Everything else is
// controlled from the RinaBoard iOS app over BLE/TCP (RinaLink protocol).

void webSetupBegin();
void webSetupService();
