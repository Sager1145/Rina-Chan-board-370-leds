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
    bool batteryCalibLoaded = false;
    bool batteryCalibDirty = false;
    uint16_t batteryAdcMv = 0;
    uint16_t batteryPrevAdcMv = 0;
    uint16_t batteryDisconnectDropMv = 0;
    float batteryLastInstantVbat = NAN;
    uint16_t chargeAdcMv = 0;
    uint32_t lastBatteryMs = 0;
    uint32_t lastChargeMs = 0;
    uint32_t batteryDisconnectedSinceMs = 0;
    uint32_t lastBatteryDisconnectEventMs = 0;
    bool batteryPrevAdcKnown = false;
    uint32_t lastCalibMaxMs = 0;
    uint32_t lastCalibMinMs = 0;
    uint32_t batteryCalibDirtySinceMs = 0;
    uint32_t lastWebSlowPublishMs = 0;
    float webPublishedVbat = NAN;
    float webPublishedVcharge = NAN;
    uint8_t webPublishedBatteryPercent = 0;
    bool webPublishedBatteryValid = false;
    bool webPublishedChargeValid = false;
    bool webPublishedCharging = false;
    bool webPublishedChargingKnown = false;
    bool webFastDirty = true;
    bool webSlowDirty = true;
};

extern PowerStatus powerStatus;

void initPowerMonitor();

void servicePowerMonitor(bool force = false);

PowerStatus readPowerStatusSnapshot();

bool powerStatusWebSlowDirty();

void clearPowerStatusWebDirty(bool includeSlow);

void resetBatteryVoltageMinimum();

void resetBatteryVoltageMaximum();
