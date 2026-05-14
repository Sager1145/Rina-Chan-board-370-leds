#include "power_monitor.h"
#include "config.h"
#include "state.h"
#include "sync.h"

#include <algorithm>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <math.h>

PowerStatus powerStatus;

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
    if (fsMounted) {
        lockHardwareBus();
        calibExists = LittleFS.exists(BATTERY_CALIB_PATH);
        unlockHardwareBus();
    }
    if (!fsMounted || !calibExists) {
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
    if (!fsMounted) return false;
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

    lockHardwareBus();
    File file = LittleFS.open(BATTERY_CALIB_PATH, "w");
    unlockHardwareBus();
    if (!file) {
        Serial.println("Failed to open battery_calib.json for write");
        return false;
    }
    lockHardwareBus();
    serializeJson(doc, file);
    file.close();
    unlockHardwareBus();
    powerStatus.batteryCalibDirty = false;
    powerStatus.batteryCalibDirtySinceMs = 0;
    powerStatus.batteryCalibLoaded = true;
    return true;
}

static void updateBatteryCalibration(float vbat, bool isCharging, uint32_t now) {
    ensureBatteryCalibrationDefaults(now);
    if (!isfinite(vbat)) return;

    if (isCharging) {
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

static void sampleBattery(uint32_t now) {
    const uint16_t adcMv = readTrimmedAdcMilliVolts(BATTERY_ADC_PIN);
    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    powerStatus.batteryAdcMv = adcMv;
    powerStatus.vbat = vadc * BATTERY_CAL_SCALE + BATTERY_CAL_OFFSET_V;
    updateBatteryCalibration(powerStatus.vbat, powerStatus.charging, now);
    powerStatus.batteryPercent = batteryPercentFromVoltage(powerStatus.vbat);
    powerStatus.batteryValid = true;
    powerStatus.lastBatteryMs = now;
}

static void sampleCharge(uint32_t now) {
    const uint16_t adcMv = readTrimmedAdcMilliVolts(CHARGE_ADC_PIN);
    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    powerStatus.chargeAdcMv = adcMv;
    powerStatus.vcharge = vadc * CHARGE_CAL_SCALE + CHARGE_CAL_OFFSET_V;
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
    serviceBatteryCalibrationSave(now);
}
