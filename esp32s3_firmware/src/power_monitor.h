#pragma once
#include <Arduino.h>

// Shared power snapshot read by Web API status routes and button overlays.
// The power monitor owns writes; consumers should treat fields as a best-effort
// telemetry snapshot that is refreshed from loop().
struct PowerStatus {
    float    vbat             = NAN;
    float    vcharge          = NAN;
    uint8_t  batteryPercent   = 0;
    bool     charging         = false;
    bool     batteryValid     = false;
    bool     chargeValid      = false;
    bool     batteryDisconnected = false;
    bool     batteryLowVoltageUnpowered = false;
    float    batteryCalibMaxV = NAN;
    float    batteryCalibMinV = NAN;
    bool     batteryCalibLoaded = false;
    bool     batteryCalibDirty  = false;
    uint16_t batteryAdcMv     = 0;
    uint16_t batteryPrevAdcMv = 0;
    uint16_t batteryDisconnectDropMv = 0;
    float    batteryLastInstantVbat = NAN;
    uint16_t chargeAdcMv      = 0;
    uint32_t lastBatteryMs    = 0;
    uint32_t lastChargeMs     = 0;
    uint32_t batteryDisconnectedSinceMs = 0;
    uint32_t lastBatteryDisconnectEventMs = 0;
    bool     batteryPrevAdcKnown = false;
    uint32_t lastCalibMaxMs   = 0;
    uint32_t lastCalibMinMs   = 0;
    uint32_t batteryCalibDirtySinceMs = 0;
    uint32_t lastWebSlowPublishMs = 0;
    float    webPublishedVbat     = NAN;
    float    webPublishedVcharge  = NAN;
    uint8_t  webPublishedBatteryPercent = 0;
    bool     webPublishedBatteryValid   = false;
    bool     webPublishedChargeValid    = false;
    bool     webPublishedCharging       = false;
    bool     webPublishedChargingKnown  = false;
    bool     webFastDirty               = true;
    bool     webSlowDirty               = true;
};

extern PowerStatus powerStatus;

/**
 * @brief Initialize ADC settings, load calibration, and take first samples.
 * @param None.
 * @return None.
 */
void initPowerMonitor();

/**
 * @brief Service periodic battery/charge sampling and WebUI publication.
 * @param force true to sample/publish immediately.
 * @return None.
 */
void servicePowerMonitor(bool force = false);

/**
 * @brief Reset minimum battery voltage calibration to current or nominal empty.
 * @param None.
 * @return None.
 */
void resetBatteryVoltageMinimum();

/**
 * @brief Reset maximum battery voltage calibration to current or nominal full.
 * @param None.
 * @return None.
 */
void resetBatteryVoltageMaximum();
