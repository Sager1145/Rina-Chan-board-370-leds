#include "power_monitor.h"
#include "config.h"
#include "state.h"
#include "sync.h"
#include "storage.h"
#include "utils.h"
#include "serial_log.h"

#include <algorithm>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <math.h>

PowerStatus powerStatus;

// powerStatus is written by the Core 0 control loop (servicePowerMonitor) and read
// by the Core 1 button/battery overlay and HTTP handlers. Consumer-visible fields
// are committed under this spinlock so readPowerStatusSnapshot() yields a coherent,
// tear-free copy across cores (Bug 8 / Addendum A2).
static portMUX_TYPE sPowerStatusMux = portMUX_INITIALIZER_UNLOCKED;

constexpr float BATTERY_EMA_TAU_S = 20.0f; // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
constexpr float CHARGE_EMA_ALPHA = 0.20f;

static uint16_t trimmedMeanMilliVolts(uint16_t* samples) {
    std::sort(samples, samples + POWER_ADC_SAMPLES);
    constexpr uint8_t first = POWER_ADC_TRIM_COUNT;
    constexpr uint8_t last = POWER_ADC_SAMPLES - POWER_ADC_TRIM_COUNT;
    uint32_t sum = 0;
    for (uint8_t i = first; i < last; ++i)
        sum += samples[i];
    return static_cast<uint16_t>(sum / (last - first));
}

// Blocking acquisition: 16 reads + 250 us pauses ~= 4 ms per pin. Used ONLY on the
// force path (boot), where routes are not open yet and a valid first sample matters.
static uint16_t readTrimmedAdcMilliVoltsBlocking(uint8_t pin) {
    uint16_t samples[POWER_ADC_SAMPLES];
    for (uint8_t i = 0; i < POWER_ADC_SAMPLES; ++i) {
        samples[i] = static_cast<uint16_t>(analogReadMilliVolts(pin));
        delayMicroseconds(250);
    }
    return trimmedMeanMilliVolts(samples);
}

// Optimization (O1): periodic sampling no longer busy-waits ~8 ms per second inside
// the cooperative loop (which stalled webServerTick/buttons/frame queue). Instead,
// servicePowerMonitor() takes ONE ~100 us ADC conversion per call and finalizes the
// same 16-sample trimmed mean once the set is complete (~16 loop passes ~= 16 ms,
// negligible against the 1000 ms sample period). Sample spacing grows from 250 us to
// ~1 ms+, which if anything improves rejection of periodic (Wi-Fi burst) noise; the
// trimming/averaging math and all downstream processing are unchanged.
struct NonBlockingAdcAcq {
    uint16_t samples[POWER_ADC_SAMPLES];
    uint8_t count = 0;
    bool acquiring = false;
};
static NonBlockingAdcAcq sBatteryAcq;
static NonBlockingAdcAcq sChargeAcq;

static float sanitizedCalibMax(float value) {
    if (!isfinite(value))
        return BATTERY_FULL_V;
    return max(value, BATTERY_FULL_V);
}

static float sanitizedCalibMin(float value) {
    if (!isfinite(value))
        return BATTERY_EMPTY_V;
    return min(value, BATTERY_EMPTY_V);
}

static float jsonFloatOr(JsonVariantConst value, float fallback) {
    if (value.isNull())
        return fallback;
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
    if (powerStatus.lastCalibMaxMs == 0)
        powerStatus.lastCalibMaxMs = now;
    if (powerStatus.lastCalibMinMs == 0)
        powerStatus.lastCalibMinMs = now;
}

static void markBatteryCalibrationDirty(uint32_t now) {
    if (!powerStatus.batteryCalibDirty) {
        powerStatus.batteryCalibDirtySinceMs = now;
    }
    powerStatus.batteryCalibDirty = true;
}

static uint8_t batteryPercentFromVoltage(float vbat) {
    if (!isfinite(vbat))
        return 0;
    const uint8_t n = BATTERY_PERCENT_LUT_SIZE;
    if (vbat >= BATTERY_PERCENT_LUT[0].voltage)
        return 100;
    if (vbat <= BATTERY_PERCENT_LUT[n - 1].voltage)
        return 0;
    for (uint8_t i = 0; i + 1 < n; ++i) {
        const float vHi = BATTERY_PERCENT_LUT[i].voltage;
        const float vLo = BATTERY_PERCENT_LUT[i + 1].voltage;
        if (vbat < vHi && vbat >= vLo) {
            const float pHi = static_cast<float>(BATTERY_PERCENT_LUT[i].percent);
            const float pLo = static_cast<float>(BATTERY_PERCENT_LUT[i + 1].percent);
            const float t = (vbat - vLo) / (vHi - vLo);
            return static_cast<uint8_t>(lroundf(pLo + t * (pHi - pLo)));
        }
    }
    return 0;
}

static bool loadBatteryCalibration(uint32_t now) {
    powerStatus.batteryCalibMaxV = BATTERY_FULL_V;
    powerStatus.batteryCalibMinV = BATTERY_EMPTY_V;
    powerStatus.lastCalibMaxMs = now;
    powerStatus.lastCalibMinMs = now;
    powerStatus.batteryCalibLoaded = false;

    bool calibExists = false;
    if (runtimeFsMounted()) {
        withStorageLock([&]() {
            calibExists = LittleFS.exists(BATTERY_CALIB_PATH);
        });
    }
    if (!runtimeFsMounted() || !calibExists) {
        return false;
    }

    File file;
    withStorageLock([&]() {
        file = LittleFS.open(BATTERY_CALIB_PATH, "r");
    });
    if (!file)
        return false;

    DynamicJsonDocument doc(512);
    DeserializationError err;
    withStorageLock([&]() {
        err = deserializeJson(doc, file, DeserializationOption::NestingLimit(6));
        file.close();
    });
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
    if (!runtimeFsMounted())
        return false;
    bool resourcesOk = false;
    withStorageLock([&]() {
        resourcesOk = LittleFS.exists("/resources") || LittleFS.mkdir("/resources");
    });
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

// Note: automatic running min/max calibration is intentionally disabled. The manual
// reset commands (resetBatteryVoltageMinimum/Maximum) are the only paths that change
// batteryCalibMinV/MaxV; they sanitize via ensureBatteryCalibrationDefaults themselves.

static void serviceBatteryCalibrationSave(uint32_t now) {
    if (!powerStatus.batteryCalibDirty)
        return;
    if (!millisElapsed(now, powerStatus.batteryCalibDirtySinceMs, BATTERY_CALIB_SAVE_DELAY_MS))
        return;
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
    if (!isfinite(previous) && !isfinite(current))
        return false;
    if (!isfinite(previous) || !isfinite(current))
        return true;
    return fabsf(previous - current) >= epsilon;
}

static void markPowerWebSlowDirty(uint32_t now) {
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
        touchRuntimeState();
    }

    if (!force && !millisElapsed(now, powerStatus.lastWebSlowPublishMs, POWER_WEB_SLOW_PUBLISH_MS))
        return;

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
struct BatteryEdge {
    bool hugeRawDrop;
    bool stillDisconnected;
};
static BatteryEdge detectBatteryDisconnect(uint16_t adcMv, uint16_t prevAdcMv, bool hadPrev, bool wasDisconnected) {
    const bool drop = hadPrev && prevAdcMv > adcMv &&
                      static_cast<uint16_t>(prevAdcMv - adcMv) >= BATTERY_DISCONNECT_ADC_DROP_MV &&
                      adcMv <= BATTERY_DISCONNECT_ADC_LOW_MV;
    return {drop, wasDisconnected && adcMv < BATTERY_RECONNECT_ADC_MV};
}

static void sampleBattery(uint32_t now, uint16_t adcMv) {
    const uint16_t prevAdcMv = powerStatus.batteryAdcMv;
    const bool hadPreviousAdc = powerStatus.batteryPrevAdcKnown;
    const BatteryEdge edge = detectBatteryDisconnect(adcMv, prevAdcMv, hadPreviousAdc, powerStatus.batteryDisconnected);
    const bool hugeRawDrop = edge.hugeRawDrop;
    const bool stillDisconnected = edge.stillDisconnected;

    powerStatus.batteryPrevAdcMv = hadPreviousAdc ? prevAdcMv : adcMv;
    powerStatus.batteryAdcMv = adcMv;
    powerStatus.batteryPrevAdcKnown = true;

    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    const float instantVbat = vadc * BATTERY_CAL_SCALE + BATTERY_CAL_OFFSET_V;
    powerStatus.batteryLastInstantVbat = instantVbat;

    const bool chargerPresent = powerStatus.chargeValid && powerStatus.charging;
    const bool rawDropUnpowered = (hugeRawDrop || stillDisconnected) && !chargerPresent;
    const bool lowVoltageUnpowered = !chargerPresent && instantVbat < BATTERY_UNPOWERED_LOW_V;

    if (rawDropUnpowered) {
        if (!powerStatus.batteryDisconnected) {
            powerStatus.batteryDisconnectedSinceMs = now;
            powerStatus.lastBatteryDisconnectEventMs = now;
            powerStatus.batteryDisconnectDropMv = static_cast<uint16_t>(prevAdcMv - adcMv);
        }
        portENTER_CRITICAL(&sPowerStatusMux);
        powerStatus.batteryDisconnected = true;
        powerStatus.batteryLowVoltageUnpowered = false;
        powerStatus.vbat = 0.0f;
        powerStatus.batteryPercent = 0;
        powerStatus.batteryValid = true;
        portEXIT_CRITICAL(&sPowerStatusMux);
        powerStatus.lastBatteryMs = now;
        markPowerWebSlowDirty(now);
        return;
    }

    // Consistency fix (C1): never write consumer-visible fields (batteryDisconnected,
    // batteryLowVoltageUnpowered, vbat, batteryPercent, batteryValid) outside
    // sPowerStatusMux. Previously the disconnect/low-voltage transitions wrote
    // vbat = NAN and batteryDisconnected = false unlocked, so a Core 1 reader
    // (battery overlay) could snapshot a half-updated state (e.g. vbat = NAN with
    // batteryValid = true). All transitional values are now computed into locals
    // and committed in a single critical section per exit path.
    const bool wasDisconnected = powerStatus.batteryDisconnected;
    const bool wasLowVoltageUnpowered = powerStatus.batteryLowVoltageUnpowered;

    if (lowVoltageUnpowered) {
        portENTER_CRITICAL(&sPowerStatusMux);
        powerStatus.batteryDisconnected = false;
        powerStatus.batteryLowVoltageUnpowered = true;
        powerStatus.vbat = 0.0f;
        powerStatus.batteryPercent = 0;
        powerStatus.batteryValid = true;
        portEXIT_CRITICAL(&sPowerStatusMux);
        if (wasDisconnected) {
            powerStatus.batteryDisconnectedSinceMs = 0;
            powerStatus.batteryDisconnectDropMv = 0;
        }
        powerStatus.lastBatteryMs = now;
        if (!wasLowVoltageUnpowered)
            markPowerWebSlowDirty(now);
        return;
    }

    // Battery is powered: restart the EMA (rather than blend with a stale/invalid
    // value) if we are recovering from a disconnect or low-voltage state — the same
    // effect the old code achieved by poking vbat = NAN before the EMA step.
    float nextVbat;
    if (wasDisconnected || wasLowVoltageUnpowered ||
        !powerStatus.batteryValid || !isfinite(powerStatus.vbat)) {
        nextVbat = instantVbat;
    } else {
        const uint32_t elapsedMs = now - powerStatus.lastBatteryMs;
        if (elapsedMs > 0x7FFFFFFFu) {
            nextVbat = instantVbat;
        } else {
            const float dtS = constrain(
                static_cast<float>(elapsedMs) * 0.001f,
                0.001f, 10.0f);
            const float emaAlpha = 1.0f - expf(-dtS / BATTERY_EMA_TAU_S);
            nextVbat = (powerStatus.vbat * (1.0f - emaAlpha)) +
                       (instantVbat * emaAlpha);
        }
    }

    uint8_t nextPercent = powerStatus.batteryPercent;
    {
        const uint8_t rawPct = batteryPercentFromVoltage(nextVbat);
        const int16_t delta = static_cast<int16_t>(rawPct) -
                              static_cast<int16_t>(powerStatus.batteryPercent);
        if (!powerStatus.batteryValid || delta > 1 || delta < -1) {
            nextPercent = rawPct;
        }
    }
    portENTER_CRITICAL(&sPowerStatusMux);
    powerStatus.batteryDisconnected = false;
    powerStatus.batteryLowVoltageUnpowered = false;
    powerStatus.vbat = nextVbat;
    powerStatus.batteryPercent = nextPercent;
    powerStatus.batteryValid = true;
    portEXIT_CRITICAL(&sPowerStatusMux);
    if (wasDisconnected) {
        powerStatus.batteryDisconnectedSinceMs = 0;
        powerStatus.batteryDisconnectDropMv = 0;
    }
    powerStatus.lastBatteryMs = now;
    if (wasDisconnected || wasLowVoltageUnpowered)
        markPowerWebSlowDirty(now);
    RLOG_DEBUG("ADC", "event=battery vbat_raw=%u vbat=%.2f percent=%u charging=%d",
               powerStatus.batteryAdcMv, nextVbat, nextPercent,
               powerStatus.charging ? 1 : 0);
}

static void sampleCharge(uint32_t now, uint16_t adcMv) {
    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    powerStatus.chargeAdcMv = adcMv;

    const float instantVcharge = vadc * CHARGE_CAL_SCALE + CHARGE_CAL_OFFSET_V;

    //
    const bool instantCharging = instantVcharge > CHARGE_PRESENT_V;
    const bool chargerStateChange = (powerStatus.charging != instantCharging);

    float nextVcharge;
    if (!powerStatus.chargeValid || !isfinite(powerStatus.vcharge) || chargerStateChange) {
        nextVcharge = instantVcharge;
    } else {
        nextVcharge = (powerStatus.vcharge * (1.0f - CHARGE_EMA_ALPHA)) +
                      (instantVcharge * CHARGE_EMA_ALPHA);
    }

    portENTER_CRITICAL(&sPowerStatusMux);
    powerStatus.vcharge = nextVcharge;
    powerStatus.charging = nextVcharge > CHARGE_PRESENT_V;
    powerStatus.chargeValid = true;
    portEXIT_CRITICAL(&sPowerStatusMux);
    powerStatus.lastChargeMs = now;
    RLOG_DEBUG("ADC", "event=charge vcharge_raw=%u vcharge=%.2f charging=%d",
               powerStatus.chargeAdcMv, nextVcharge, powerStatus.charging ? 1 : 0);
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

    if (force) {
        // Boot/manual path: synchronous acquisition, identical to the old behavior.
        // Discard any in-flight non-blocking acquisition so samples never mix.
        sBatteryAcq.acquiring = false;
        sBatteryAcq.count = 0;
        sChargeAcq.acquiring = false;
        sChargeAcq.count = 0;
        sampleBattery(now, readTrimmedAdcMilliVoltsBlocking(BATTERY_ADC_PIN));
        sampleCharge(now, readTrimmedAdcMilliVoltsBlocking(CHARGE_ADC_PIN));
    } else {
        // O1: start an acquisition when its window is due.
        if (!sBatteryAcq.acquiring &&
            (powerStatus.lastBatteryMs == 0 ||
             millisElapsed(now, powerStatus.lastBatteryMs, BATTERY_SAMPLE_MS))) {
            sBatteryAcq.acquiring = true;
            sBatteryAcq.count = 0;
        }
        if (!sChargeAcq.acquiring &&
            (powerStatus.lastChargeMs == 0 ||
             millisElapsed(now, powerStatus.lastChargeMs, CHARGE_SAMPLE_MS))) {
            sChargeAcq.acquiring = true;
            sChargeAcq.count = 0;
        }
        // One ADC conversion (~100 us) per service call; battery first, then charge.
        if (sBatteryAcq.acquiring) {
            sBatteryAcq.samples[sBatteryAcq.count++] =
                static_cast<uint16_t>(analogReadMilliVolts(BATTERY_ADC_PIN));
            if (sBatteryAcq.count >= POWER_ADC_SAMPLES) {
                sBatteryAcq.acquiring = false;
                sampleBattery(now, trimmedMeanMilliVolts(sBatteryAcq.samples));
            }
        } else if (sChargeAcq.acquiring) {
            sChargeAcq.samples[sChargeAcq.count++] =
                static_cast<uint16_t>(analogReadMilliVolts(CHARGE_ADC_PIN));
            if (sChargeAcq.count >= POWER_ADC_SAMPLES) {
                sChargeAcq.acquiring = false;
                sampleCharge(now, trimmedMeanMilliVolts(sChargeAcq.samples));
            }
        }
    }

    serviceBatteryCalibrationSave(now);
    servicePowerWebPublish(now, force);
}

PowerStatus readPowerStatusSnapshot() {
    // powerStatus is updated by the Core 0 control loop; the Core 1 overlay and the
    // HTTP handlers must read a coherent copy. Writers commit the consumer-visible
    // fields under sPowerStatusMux, so copying under the same lock yields a tear-free
    // snapshot rather than a mix of old/new fields.
    PowerStatus snapshot;
    portENTER_CRITICAL(&sPowerStatusMux);
    snapshot = powerStatus;
    portEXIT_CRITICAL(&sPowerStatusMux);
    return snapshot;
}
