#include "power_monitor.h"
#include "config.h"
#include "state.h"
#include "sync.h"
#include "storage.h"

#include <algorithm>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <math.h>

PowerStatus powerStatus;

// EMA low-pass filters for ADC-derived voltages.
// Lower alpha = smoother output and slower response. These filters stabilize
// battery / charge readings under WS2812B load transients without adding any
// monotonic percentage lock.
constexpr float BATTERY_EMA_ALPHA = 0.05f;
constexpr float CHARGE_EMA_ALPHA  = 0.20f;

static float dividerScale(float r1k, float r2k) {
    return (r1k + r2k) / r2k;
}

static uint16_t readTrimmedAdcMilliVolts(uint8_t pin) {
    uint16_t samples[POWER_ADC_SAMPLES];
    for (uint8_t i = 0; i < POWER_ADC_SAMPLES; ++i) {
        samples[i] = static_cast<uint16_t>(analogReadMilliVolts(pin));
        delayMicroseconds(250);
    }

    std::sort(samples, samples + POWER_ADC_SAMPLES);

    constexpr uint8_t first = POWER_ADC_TRIM_COUNT;
    constexpr uint8_t last = POWER_ADC_SAMPLES - POWER_ADC_TRIM_COUNT;
    uint32_t sum = 0;
    for (uint8_t i = first; i < last; ++i) sum += samples[i];
    return static_cast<uint16_t>(sum / (last - first));
}

static float sanitizedCalibMax(float value) {
    if (!isfinite(value)) return BATTERY_FULL_V;
    return max(value, BATTERY_FULL_V);
}

static float sanitizedCalibMin(float value) {
    if (!isfinite(value)) return BATTERY_EMPTY_V;
    return min(value, BATTERY_EMPTY_V);
}

static float jsonFloatOr(JsonVariantConst value, float fallback) {
    if (value.isNull()) return fallback;
    const float parsed = value.as<float>();
    return isfinite(parsed) ? parsed : fallback;
}

static void ensureBatteryCalibrationDefaults(uint32_t now) {
    powerStatus.batteryCalibMaxV = sanitizedCalibMax(powerStatus.batteryCalibMaxV);
    powerStatus.batteryCalibMinV = sanitizedCalibMin(powerStatus.batteryCalibMinV);
    if (powerStatus.batteryCalibMaxV - powerStatus.batteryCalibMinV < BATTERY_CALIB_MIN_SPAN_V) {
        powerStatus.batteryCalibMaxV = BATTERY_FULL_V;
        powerStatus.batteryCalibMinV = BATTERY_EMPTY_V;
    }
    if (powerStatus.lastCalibMaxMs == 0) powerStatus.lastCalibMaxMs = now;
    if (powerStatus.lastCalibMinMs == 0) powerStatus.lastCalibMinMs = now;
}

static void markBatteryCalibrationDirty(uint32_t now) {
    if (!powerStatus.batteryCalibDirty) {
        powerStatus.batteryCalibDirtySinceMs = now;
    }
    powerStatus.batteryCalibDirty = true;
}

static uint8_t batteryPercentFromVoltage(float vbat) {
    const float maxV = sanitizedCalibMax(powerStatus.batteryCalibMaxV);
    const float minV = sanitizedCalibMin(powerStatus.batteryCalibMinV);
    const float span = maxV - minV;
    if (!(span > 0.0f) || !isfinite(vbat)) return 0;
    const float pct = (vbat - minV) * 100.0f / span;
    return static_cast<uint8_t>(constrain(lroundf(pct), 0L, 100L));
}

static bool loadBatteryCalibration(uint32_t now) {
    powerStatus.batteryCalibMaxV = BATTERY_FULL_V;
    powerStatus.batteryCalibMinV = BATTERY_EMPTY_V;
    powerStatus.lastCalibMaxMs = now;
    powerStatus.lastCalibMinMs = now;
    powerStatus.batteryCalibLoaded = false;

    bool calibExists = false;
    if (runtimeFsMounted()) {
        lockHardwareBus();
        calibExists = LittleFS.exists(BATTERY_CALIB_PATH);
        unlockHardwareBus();
    }
    if (!runtimeFsMounted() || !calibExists) {
        return false;
    }

    lockHardwareBus();
    File file = LittleFS.open(BATTERY_CALIB_PATH, "r");
    unlockHardwareBus();
    if (!file) return false;

    DynamicJsonDocument doc(512);
    lockHardwareBus();
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(6));
    file.close();
    unlockHardwareBus();
    if (err) {
        Serial.printf("battery_calib.json parse failed: %s\n", err.c_str());
        return false;
    }

    powerStatus.batteryCalibMaxV = sanitizedCalibMax(jsonFloatOr(doc["v_max"], BATTERY_FULL_V));
    powerStatus.batteryCalibMinV = sanitizedCalibMin(jsonFloatOr(doc["v_min"], BATTERY_EMPTY_V));
    ensureBatteryCalibrationDefaults(now);
    powerStatus.batteryCalibLoaded = true;
    Serial.printf("Battery calibration loaded: v_min=%.3f v_max=%.3f\n",
                  powerStatus.batteryCalibMinV,
                  powerStatus.batteryCalibMaxV);
    return true;
}

static bool saveBatteryCalibration(uint32_t now) {
    if (!runtimeFsMounted()) return false;
    bool resourcesOk = false;
    lockHardwareBus();
    resourcesOk = LittleFS.exists("/resources") || LittleFS.mkdir("/resources");
    unlockHardwareBus();
    if (!resourcesOk) {
        Serial.println("Failed to ensure /resources for battery calibration");
        return false;
    }

    DynamicJsonDocument doc(512);
    doc["format"] = "rina_battery_calibration_v1";
    doc["version"] = 1;
    doc["v_max"] = powerStatus.batteryCalibMaxV;
    doc["v_min"] = powerStatus.batteryCalibMinV;
    doc["v_max_nominal"] = BATTERY_FULL_V;
    doc["v_min_nominal"] = BATTERY_EMPTY_V;
    doc["last_max_ms"] = powerStatus.lastCalibMaxMs;
    doc["last_min_ms"] = powerStatus.lastCalibMinMs;
    doc["updated_at_ms"] = now;

    size_t written = 0;
    String error;
    if (!writeJsonFileAtomic(BATTERY_CALIB_PATH, doc.as<JsonVariant>(), written, error)) {
        Serial.printf("Failed to write battery_calib.json: %s\n", error.c_str());
        return false;
    }
    powerStatus.batteryCalibDirty = false;
    powerStatus.batteryCalibDirtySinceMs = 0;
    powerStatus.batteryCalibLoaded = true;
    return true;
}

static void updateBatteryCalibration(float vbat, bool freezeCalibration, uint32_t now) {
    ensureBatteryCalibrationDefaults(now);
    if (!isfinite(vbat)) return;

    // Charging, disconnected, and sub-5V unpowered readings must never teach
    // the automatic min/max range. In particular, a boot-time battery ADC below
    // 5V is treated as not powered rather than as a new minimum voltage.
    if (freezeCalibration || vbat < BATTERY_UNPOWERED_LOW_V) {
        powerStatus.lastCalibMaxMs = now;
        powerStatus.lastCalibMinMs = now;
        return;
    }

    if (vbat > powerStatus.batteryCalibMaxV) {
        powerStatus.batteryCalibMaxV = vbat;
        powerStatus.lastCalibMaxMs = now;
        markBatteryCalibrationDirty(now);
    } else if (vbat < powerStatus.batteryCalibMinV) {
        powerStatus.batteryCalibMinV = vbat;
        powerStatus.lastCalibMinMs = now;
        markBatteryCalibrationDirty(now);
    }

    if (now - powerStatus.lastCalibMaxMs > BATTERY_CALIB_SHRINK_TIMEOUT_MS) {
        const float nextMax = max(BATTERY_FULL_V, powerStatus.batteryCalibMaxV - BATTERY_CALIB_SHRINK_STEP_V);
        if (fabsf(nextMax - powerStatus.batteryCalibMaxV) > 0.0001f) {
            powerStatus.batteryCalibMaxV = nextMax;
            markBatteryCalibrationDirty(now);
        }
        powerStatus.lastCalibMaxMs = now;
    }

    if (now - powerStatus.lastCalibMinMs > BATTERY_CALIB_SHRINK_TIMEOUT_MS) {
        const float nextMin = min(BATTERY_EMPTY_V, powerStatus.batteryCalibMinV + BATTERY_CALIB_SHRINK_STEP_V);
        if (fabsf(nextMin - powerStatus.batteryCalibMinV) > 0.0001f) {
            powerStatus.batteryCalibMinV = nextMin;
            markBatteryCalibrationDirty(now);
        }
        powerStatus.lastCalibMinMs = now;
    }
}

static void serviceBatteryCalibrationSave(uint32_t now) {
    if (!powerStatus.batteryCalibDirty) return;
    if (now - powerStatus.batteryCalibDirtySinceMs < BATTERY_CALIB_SAVE_DELAY_MS) return;
    saveBatteryCalibration(now);
}

static bool batteryHasPoweredVoltage() {
    return powerStatus.batteryValid &&
           !powerStatus.batteryDisconnected &&
           !powerStatus.batteryLowVoltageUnpowered &&
           isfinite(powerStatus.vbat) &&
           powerStatus.vbat >= BATTERY_UNPOWERED_LOW_V;
}

static bool batteryCanRecordMinimumVoltage() {
    return batteryHasPoweredVoltage() && !powerStatus.charging;
}

static void markPowerCalibrationChanged(uint32_t now) {
    markBatteryCalibrationDirty(now);
    saveBatteryCalibration(now);
    powerStatus.webFastDirty = true;
    powerStatus.webSlowDirty = true;
    powerStatus.lastWebSlowPublishMs = now;
    touchRuntimeState();
}

void resetBatteryVoltageMaximum() {
    const uint32_t now = millis();
    ensureBatteryCalibrationDefaults(now);
    const float minV = sanitizedCalibMin(powerStatus.batteryCalibMinV);
    const float currentV = powerStatus.vbat;
    if (batteryHasPoweredVoltage() && currentV > minV + BATTERY_CALIB_MIN_SPAN_V) {
        powerStatus.batteryCalibMaxV = currentV;
    } else {
        powerStatus.batteryCalibMaxV = BATTERY_FULL_V;
    }
    powerStatus.lastCalibMaxMs = now;
    ensureBatteryCalibrationDefaults(now);
    markPowerCalibrationChanged(now);
}

void resetBatteryVoltageMinimum() {
    const uint32_t now = millis();
    ensureBatteryCalibrationDefaults(now);
    const float maxV = sanitizedCalibMax(powerStatus.batteryCalibMaxV);
    const float currentV = powerStatus.vbat;
    if (batteryCanRecordMinimumVoltage() && currentV < maxV - BATTERY_CALIB_MIN_SPAN_V) {
        powerStatus.batteryCalibMinV = currentV;
    } else {
        powerStatus.batteryCalibMinV = BATTERY_EMPTY_V;
    }
    powerStatus.lastCalibMinMs = now;
    ensureBatteryCalibrationDefaults(now);
    markPowerCalibrationChanged(now);
}

static bool finiteChanged(float previous, float current, float epsilon) {
    if (!isfinite(previous) && !isfinite(current)) return false;
    if (!isfinite(previous) || !isfinite(current)) return true;
    return fabsf(previous - current) >= epsilon;
}

static void markPowerWebFastDirty() {
    powerStatus.webFastDirty = true;
    touchRuntimeState();
}

static void markPowerWebSlowDirty(uint32_t now) {
    powerStatus.webSlowDirty = true;
    powerStatus.lastWebSlowPublishMs = now;
    powerStatus.webPublishedBatteryValid = powerStatus.batteryValid;
    powerStatus.webPublishedChargeValid = powerStatus.chargeValid;
    powerStatus.webPublishedVbat = powerStatus.vbat;
    powerStatus.webPublishedVcharge = powerStatus.vcharge;
    powerStatus.webPublishedBatteryPercent = powerStatus.batteryPercent;
    touchRuntimeState();
}

static void servicePowerWebPublish(uint32_t now, bool force) {
    if (force || !powerStatus.webPublishedChargingKnown ||
        powerStatus.webPublishedChargeValid != powerStatus.chargeValid ||
        powerStatus.webPublishedCharging != powerStatus.charging) {
        powerStatus.webPublishedChargeValid = powerStatus.chargeValid;
        powerStatus.webPublishedCharging = powerStatus.charging;
        powerStatus.webPublishedChargingKnown = true;
        markPowerWebFastDirty();
        powerStatus.webSlowDirty = true;
    }

    if (!force && now - powerStatus.lastWebSlowPublishMs < POWER_WEB_SLOW_PUBLISH_MS) return;

    const bool slowChanged =
        force ||
        powerStatus.webPublishedBatteryValid != powerStatus.batteryValid ||
        powerStatus.webPublishedChargeValid != powerStatus.chargeValid ||
        finiteChanged(powerStatus.webPublishedVbat, powerStatus.vbat, POWER_WEB_VBAT_EPS_V) ||
        finiteChanged(powerStatus.webPublishedVcharge, powerStatus.vcharge, POWER_WEB_VCHARGE_EPS_V) ||
        powerStatus.webPublishedBatteryPercent != powerStatus.batteryPercent;

    if (slowChanged) {
        markPowerWebSlowDirty(now);
    } else {
        powerStatus.lastWebSlowPublishMs = now;
    }
}

static void sampleBattery(uint32_t now) {
    const uint16_t adcMv = readTrimmedAdcMilliVolts(BATTERY_ADC_PIN);
    const uint16_t prevAdcMv = powerStatus.batteryAdcMv;
    const bool hadPreviousAdc = powerStatus.batteryPrevAdcKnown;
    const bool hugeRawDrop = hadPreviousAdc &&
        prevAdcMv > adcMv &&
        static_cast<uint16_t>(prevAdcMv - adcMv) >= BATTERY_DISCONNECT_ADC_DROP_MV &&
        adcMv <= BATTERY_DISCONNECT_ADC_LOW_MV;
    const bool stillDisconnected = powerStatus.batteryDisconnected && adcMv < BATTERY_RECONNECT_ADC_MV;

    powerStatus.batteryPrevAdcMv = hadPreviousAdc ? prevAdcMv : adcMv;
    powerStatus.batteryAdcMv = adcMv;
    powerStatus.batteryPrevAdcKnown = true;

    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    const float instantVbat = vadc * BATTERY_CAL_SCALE + BATTERY_CAL_OFFSET_V;
    powerStatus.batteryLastInstantVbat = instantVbat;

    // A charger-present state intentionally overrides the visual "unpowered"
    // state: while charging, the WebUI must show the measured battery voltage
    // and a red battery icon, but this reading still must not update v_min.
    const bool chargerPresent = powerStatus.chargeValid && powerStatus.charging;
    const bool rawDropUnpowered = (hugeRawDrop || stillDisconnected) && !chargerPresent;
    const bool lowVoltageUnpowered = !chargerPresent && instantVbat < BATTERY_UNPOWERED_LOW_V;

    if (rawDropUnpowered) {
        if (!powerStatus.batteryDisconnected) {
            powerStatus.batteryDisconnectedSinceMs = now;
            powerStatus.lastBatteryDisconnectEventMs = now;
            powerStatus.batteryDisconnectDropMv = static_cast<uint16_t>(prevAdcMv - adcMv);
        }
        powerStatus.batteryDisconnected = true;
        powerStatus.batteryLowVoltageUnpowered = false;
        powerStatus.vbat = 0.0f;
        powerStatus.batteryPercent = 0;
        powerStatus.batteryValid = true;
        powerStatus.lastBatteryMs = now;
        markPowerWebSlowDirty(now);
        return;
    }

    const bool wasDisconnected = powerStatus.batteryDisconnected;
    const bool wasLowVoltageUnpowered = powerStatus.batteryLowVoltageUnpowered;
    if (wasDisconnected) {
        powerStatus.batteryDisconnected = false;
        powerStatus.batteryDisconnectedSinceMs = 0;
        powerStatus.batteryDisconnectDropMv = 0;
        powerStatus.vbat = NAN;
    }

    if (lowVoltageUnpowered) {
        powerStatus.batteryLowVoltageUnpowered = true;
        powerStatus.vbat = 0.0f;
        powerStatus.batteryPercent = 0;
        powerStatus.batteryValid = true;
        powerStatus.lastBatteryMs = now;
        updateBatteryCalibration(instantVbat, true, now);
        if (!wasLowVoltageUnpowered) markPowerWebSlowDirty(now);
        return;
    }

    powerStatus.batteryLowVoltageUnpowered = false;
    if (wasDisconnected || wasLowVoltageUnpowered || !powerStatus.batteryValid || !isfinite(powerStatus.vbat)) {
        powerStatus.vbat = instantVbat;
    } else {
        powerStatus.vbat = (powerStatus.vbat * (1.0f - BATTERY_EMA_ALPHA)) +
                            (instantVbat * BATTERY_EMA_ALPHA);
    }

    const bool freezeCalibration = chargerPresent ||
        powerStatus.batteryDisconnected ||
        powerStatus.batteryLowVoltageUnpowered ||
        powerStatus.vbat < BATTERY_UNPOWERED_LOW_V;
    updateBatteryCalibration(powerStatus.vbat, freezeCalibration, now);
    powerStatus.batteryPercent = batteryPercentFromVoltage(powerStatus.vbat);
    powerStatus.batteryValid = true;
    powerStatus.lastBatteryMs = now;
    if (wasDisconnected || wasLowVoltageUnpowered) markPowerWebSlowDirty(now);
}

static void sampleCharge(uint32_t now) {
    const uint16_t adcMv = readTrimmedAdcMilliVolts(CHARGE_ADC_PIN);
    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    powerStatus.chargeAdcMv = adcMv;

    const float instantVcharge = vadc * CHARGE_CAL_SCALE + CHARGE_CAL_OFFSET_V;
    if (!powerStatus.chargeValid || !isfinite(powerStatus.vcharge)) {
        powerStatus.vcharge = instantVcharge;
    } else {
        powerStatus.vcharge = (powerStatus.vcharge * (1.0f - CHARGE_EMA_ALPHA)) +
                               (instantVcharge * CHARGE_EMA_ALPHA);
    }

    powerStatus.charging = powerStatus.vcharge > CHARGE_PRESENT_V;
    powerStatus.chargeValid = true;
    powerStatus.lastChargeMs = now;
}

void initPowerMonitor() {
    const uint32_t now = millis();
    loadBatteryCalibration(now);
    ensureBatteryCalibrationDefaults(now);
    analogReadResolution(12);
    analogSetPinAttenuation(BATTERY_ADC_PIN, ADC_11db);
    analogSetPinAttenuation(CHARGE_ADC_PIN, ADC_11db);
    servicePowerMonitor(true);
}

void servicePowerMonitor(bool force) {
    const uint32_t now = millis();
    if (force || !powerStatus.chargeValid || now - powerStatus.lastChargeMs >= CHARGE_SAMPLE_MS) {
        sampleCharge(now);
    }
    if (force || !powerStatus.batteryValid || now - powerStatus.lastBatteryMs >= BATTERY_SAMPLE_MS) {
        sampleBattery(now);
    }
    servicePowerWebPublish(now, force);
    serviceBatteryCalibrationSave(now);
}
