#pragma once
#include <Arduino.h>

struct PowerStatus {
    float vbat = NAN;
    float vcharge = NAN;
    uint8_t batteryPercent = 0;
    bool charging = false;
    bool batteryValid = false;
    bool chargeValid = false;
    bool batteryDisconnected = false;
    bool batteryLowVoltageUnpowered = false;
    float batteryCalibMaxV = NAN;
    float batteryCalibMinV = NAN;
    bool batteryCalibDirty = false;
    uint16_t batteryAdcMv = 0;
    uint16_t chargeAdcMv = 0;
    uint32_t lastBatteryMs = 0;
    uint32_t lastChargeMs = 0;
    bool batteryPrevAdcKnown = false;
    uint32_t lastCalibMaxMs = 0;
    uint32_t lastCalibMinMs = 0;
    uint32_t batteryCalibDirtySinceMs = 0;
    uint32_t lastSlowPublishMs = 0;
    float slowPublishedVbat = NAN;
    float slowPublishedVcharge = NAN;
    uint8_t slowPublishedBatteryPercent = 0;
    bool slowPublishedBatteryValid = false;
    bool slowPublishedChargeValid = false;
    bool slowPublishedCharging = false;
    bool slowPublishedChargingKnown = false;
};

extern PowerStatus powerStatus;

void initPowerMonitor();

void servicePowerMonitor(bool force = false);

PowerStatus readPowerStatusSnapshot();

void resetBatteryVoltageMinimum();

void resetBatteryVoltageMaximum();
