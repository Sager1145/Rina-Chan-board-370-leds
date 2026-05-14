#pragma once
#include <Arduino.h>

struct PowerStatus {
    float    vbat             = NAN;
    float    vcharge          = NAN;
    uint8_t  batteryPercent   = 0;
    bool     charging         = false;
    bool     batteryValid     = false;
    bool     chargeValid      = false;
    uint16_t batteryAdcMv     = 0;
    uint16_t chargeAdcMv      = 0;
    uint32_t lastBatteryMs    = 0;
    uint32_t lastChargeMs     = 0;
};

extern PowerStatus powerStatus;

void initPowerMonitor();
void servicePowerMonitor(bool force = false);
