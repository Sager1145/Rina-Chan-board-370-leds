#include "power_monitor.h"
#include "config.h"
#include "state.h"
#include "sync.h"
#include "storage.h"
#include "utils.h"
#include "serial_log.h"
#include "battery_calibration.h"

#include <algorithm>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <esp_system.h>
#include <nvs.h>
#include <math.h>

PowerStatus powerStatus;

// powerStatus is written by the Core 0 control loop (servicePowerMonitor) and read
// by the Core 1 button/battery overlay and the RinaLink protocol handlers. Consumer-visible fields
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
// the cooperative loop (which stalled protocol/buttons/frame queue servicing). Instead,
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

// Auto-calibration state (highest measurable pack voltage + discharge cutoff).
// See battery_calibration.h for the pure logic; this file wires it into
// PowerStatus, battery_calib.json and the "rina_batt" NVS namespace (the
// discharge low-point is written to NVS, not LittleFS, so it survives a
// brown-out/power-loss reset that can happen before a delayed LittleFS save).
static BatteryCalibState sCalib;
constexpr char BATTERY_CALIB_NVS_NAMESPACE[] = "rina_batt";
constexpr char BATTERY_CALIB_NVS_PENDING_LOW_KEY[] = "pend_low";
constexpr float BATTERY_CALIB_RESET_MARGIN_V = 0.50f;
// Discharge low-point tracking is not fed until the EMA has settled this long
// since it was last restarted (boot / recovering from disconnect or low-voltage):
// the first sample after a restart is the raw, momentarily-unloaded reading.
constexpr uint32_t BATTERY_CALIB_DISCHARGE_STABLE_MS = 30000;
// A flapping charge-present flag must not repeatedly erase+rewrite the NVS
// pending-low key: RAM clears immediately, but the NVS key is only erased once
// charging has held continuously this long (or vbat itself recovered).
constexpr uint32_t BATTERY_CALIB_CHARGE_ERASE_HOLD_MS = 30000;

static uint32_t sBatteryEmaRestartMs = 0;
static bool sBatteryEmaRestartKnown = false;
static bool sChargingForCalibPrev = false;
static uint32_t sChargingForCalibSinceMs = 0;
// Mirrors what is actually persisted at BATTERY_CALIB_NVS_PENDING_LOW_KEY, so we
// only touch NVS when the on-flash value would actually change.
static float sLastPersistedLowV = NAN;

static float jsonFloatOr(JsonVariantConst value, float fallback) {
    if (value.isNull())
        return fallback;
    const float parsed = value.as<float>();
    return isfinite(parsed) ? parsed : fallback;
}

// Publishes the calibration state into the consumer-visible PowerStatus copy
// (batteryCalibMaxV/MinV keep their historical names; MinV now holds the
// cutoff voltage).
static void publishBatteryCalibToStatus() {
    portENTER_CRITICAL(&sPowerStatusMux);
    powerStatus.batteryCalibMaxV = sCalib.maxV;
    powerStatus.batteryCalibMinV = sCalib.cutoffV;
    powerStatus.batteryCalibMaxLearned = sCalib.maxLearned;
    powerStatus.batteryCalibCutoffLearned = sCalib.cutoffLearned;
    portEXIT_CRITICAL(&sPowerStatusMux);
}

// Reads the pending-low value via the IDF NVS API directly rather than
// Preferences: a fresh board has neither the "rina_batt" namespace nor the
// key yet, and Preferences::begin()/getFloat() both log an [E] line for that
// normal "not present yet" condition. Preferences::putFloat() stores the
// value as a raw sizeof(float) blob, so nvs_get_blob() with the same size
// reads back the identical on-flash format.
static float loadBatteryPendingLowFromNvs() {
    nvs_handle_t handle;
    esp_err_t err = nvs_open(BATTERY_CALIB_NVS_NAMESPACE, NVS_READONLY, &handle);
    if (err == ESP_ERR_NVS_NOT_FOUND)
        return NAN; // namespace never created yet: no pending value, quietly.
    if (err != ESP_OK)
        return NAN;
    float v = NAN;
    size_t len = sizeof(v);
    err = nvs_get_blob(handle, BATTERY_CALIB_NVS_PENDING_LOW_KEY, &v, &len);
    nvs_close(handle);
    if (err != ESP_OK || len != sizeof(v))
        return NAN;
    return v;
}

static void saveBatteryPendingLowToNvs(float v) {
    Preferences prefs;
    if (!prefs.begin(BATTERY_CALIB_NVS_NAMESPACE, false))
        return;
    prefs.putFloat(BATTERY_CALIB_NVS_PENDING_LOW_KEY, v);
    prefs.end();
}

static void clearBatteryPendingLowFromNvs() {
    Preferences prefs;
    if (!prefs.begin(BATTERY_CALIB_NVS_NAMESPACE, false))
        return;
    // Preferences::remove() logs an [E] line if the key isn't present (e.g.
    // it was already cleared, or never written this boot); isKey() itself
    // never logs, so guard the call.
    if (prefs.isKey(BATTERY_CALIB_NVS_PENDING_LOW_KEY))
        prefs.remove(BATTERY_CALIB_NVS_PENDING_LOW_KEY);
    prefs.end();
}

static void markBatteryCalibrationDirty(uint32_t now) {
    if (!powerStatus.batteryCalibDirty) {
        powerStatus.batteryCalibDirtySinceMs = now;
    }
    powerStatus.batteryCalibDirty = true;
}

static uint8_t batteryPercentFromVoltage(float vbatRaw) {
    const float vbat = batteryCalibNormalizedVoltage(sCalib, vbatRaw);
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
    sCalib = batteryCalibDefaults();
    powerStatus.lastCalibMaxMs = now;
    powerStatus.lastCalibMinMs = now;

    bool calibExists = false;
    if (runtimeFsMounted()) {
        withStorageLock([&]() {
            calibExists = LittleFS.exists(BATTERY_CALIB_PATH);
        });
    }
    if (!runtimeFsMounted() || !calibExists) {
        publishBatteryCalibToStatus();
        return false;
    }

    File file;
    withStorageLock([&]() {
        file = LittleFS.open(BATTERY_CALIB_PATH, "r");
    });
    if (!file) {
        publishBatteryCalibToStatus();
        return false;
    }

    DynamicJsonDocument doc(512);
    DeserializationError err;
    withStorageLock([&]() {
        err = deserializeJson(doc, file, DeserializationOption::NestingLimit(6));
        file.close();
    });
    if (err) {
        Serial.printf("battery_calib.json parse failed: %s\n", err.c_str());
        publishBatteryCalibToStatus();
        return false;
    }

    const int version = doc["version"] | 1;
    const float vMaxDefault = batteryCalibDefaults().maxV; // 8.40 (LUT top)
    const float vMax = jsonFloatOr(doc["v_max"], vMaxDefault);
    const float vMin = jsonFloatOr(doc["v_min"], BATTERY_EMPTY_V);
    sCalib.cutoffV = vMin;
    if (version >= 2) {
        sCalib.maxV = vMax;
        sCalib.maxLearned = doc["max_learned"] | false;
        sCalib.cutoffLearned = doc["cutoff_learned"] | false;
    } else {
        // v1 files could only widen via the old sanitize (max >= 8.0, min <= 6.2).
        // The old default was 8.0 (not the LUT top of 8.40), so a v1 file at/below
        // 8.0 must load as the current default (8.40), not as a stale 8.0 ceiling
        // that would read 100% far too early. A value actually widened past 8.0
        // is treated as learned.
        if (vMax <= BATTERY_FULL_V + 0.001f) {
            sCalib.maxV = vMaxDefault;
            sCalib.maxLearned = false;
        } else {
            sCalib.maxV = vMax;
            sCalib.maxLearned = true;
        }
        sCalib.cutoffLearned = vMin < BATTERY_EMPTY_V;
    }
    batteryCalibSanitize(sCalib);
    publishBatteryCalibToStatus();
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
    doc["format"] = "rina_battery_calibration_v2";
    doc["version"] = 2;
    doc["v_max"] = sCalib.maxV;
    doc["v_min"] = sCalib.cutoffV;
    doc["max_learned"] = sCalib.maxLearned;
    doc["cutoff_learned"] = sCalib.cutoffLearned;
    doc["v_max_nominal"] = batteryCalibDefaults().maxV; // 8.40, the LUT top
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
    return true;
}

// Automatic learning is guarded rather than a naive running min/max: LED-load sag and
// ADC noise can transiently push a reading past the true ceiling or floor, so the max
// is only adopted after it is held continuously for 60 s (batteryCalibObserveMax), and
// the cutoff is only adopted from a discharge low-point captured right before an actual
// power-loss/brown-out reset (batteryCalibAdoptPendingOnBoot), never from a soft reboot
// or a momentary dip mid-discharge.

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
    powerStatus.lastSlowPublishMs = now;
    touchRuntimeState();
}

void resetBatteryVoltageMaximum() {
    const uint32_t now = millis();
    const float currentV = powerStatus.vbat;
    sCalib.candidateActive = false;
    if (batteryHasPoweredVoltage() && currentV > sCalib.cutoffV + BATTERY_CALIB_RESET_MARGIN_V) {
        sCalib.maxV = currentV;
        sCalib.maxLearned = true;
    } else {
        const BatteryCalibState def = batteryCalibDefaults();
        sCalib.maxV = def.maxV;
        sCalib.maxLearned = false;
    }
    batteryCalibSanitize(sCalib);
    publishBatteryCalibToStatus();
    powerStatus.lastCalibMaxMs = now;
    markPowerCalibrationChanged(now);
}

void resetBatteryVoltageMinimum() {
    const uint32_t now = millis();
    const float currentV = powerStatus.vbat;
    if (batteryCanRecordMinimumVoltage() && currentV < sCalib.maxV - BATTERY_CALIB_RESET_MARGIN_V) {
        sCalib.cutoffV = currentV;
        sCalib.cutoffLearned = true;
    } else {
        const BatteryCalibState def = batteryCalibDefaults();
        sCalib.cutoffV = def.cutoffV;
        sCalib.cutoffLearned = false;
    }
    sCalib.pendingLowV = NAN;
    if (isfinite(sLastPersistedLowV)) {
        clearBatteryPendingLowFromNvs();
        sLastPersistedLowV = NAN;
    }
    batteryCalibSanitize(sCalib);
    publishBatteryCalibToStatus();
    powerStatus.lastCalibMinMs = now;
    markPowerCalibrationChanged(now);
}

static bool finiteChanged(float previous, float current, float epsilon) {
    if (!isfinite(previous) && !isfinite(current))
        return false;
    if (!isfinite(previous) || !isfinite(current))
        return true;
    return fabsf(previous - current) >= epsilon;
}

static void markPowerSlowPublishDirty(uint32_t now) {
    powerStatus.lastSlowPublishMs = now;
    powerStatus.slowPublishedBatteryValid = powerStatus.batteryValid;
    powerStatus.slowPublishedChargeValid = powerStatus.chargeValid;
    powerStatus.slowPublishedVbat = powerStatus.vbat;
    powerStatus.slowPublishedVcharge = powerStatus.vcharge;
    powerStatus.slowPublishedBatteryPercent = powerStatus.batteryPercent;
    touchRuntimeState();
}

static void servicePowerSlowPublish(uint32_t now, bool force) {
    if (force || !powerStatus.slowPublishedChargingKnown ||
        powerStatus.slowPublishedChargeValid != powerStatus.chargeValid ||
        powerStatus.slowPublishedCharging != powerStatus.charging) {
        powerStatus.slowPublishedChargeValid = powerStatus.chargeValid;
        powerStatus.slowPublishedCharging = powerStatus.charging;
        powerStatus.slowPublishedChargingKnown = true;
        touchRuntimeState();
    }

    if (!force && !millisElapsed(now, powerStatus.lastSlowPublishMs, POWER_SLOW_PUBLISH_MS))
        return;

    const bool slowChanged =
        force ||
        powerStatus.slowPublishedBatteryValid != powerStatus.batteryValid ||
        powerStatus.slowPublishedChargeValid != powerStatus.chargeValid ||
        finiteChanged(powerStatus.slowPublishedVbat, powerStatus.vbat, POWER_WEB_VBAT_EPS_V) ||
        finiteChanged(powerStatus.slowPublishedVcharge, powerStatus.vcharge, POWER_WEB_VCHARGE_EPS_V) ||
        powerStatus.slowPublishedBatteryPercent != powerStatus.batteryPercent;

    if (slowChanged) {
        markPowerSlowPublishDirty(now);
    } else {
        powerStatus.lastSlowPublishMs = now;
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

    powerStatus.batteryAdcMv = adcMv;
    powerStatus.batteryPrevAdcKnown = true;

    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    const float instantVbat = vadc * BATTERY_CAL_SCALE + BATTERY_CAL_OFFSET_V;

    const bool chargerPresent = powerStatus.chargeValid && powerStatus.charging;
    const bool rawDropUnpowered = (hugeRawDrop || stillDisconnected) && !chargerPresent;
    const bool lowVoltageUnpowered = !chargerPresent && instantVbat < BATTERY_UNPOWERED_LOW_V;

    if (rawDropUnpowered) {
        if (!powerStatus.batteryDisconnected) {
        }
        portENTER_CRITICAL(&sPowerStatusMux);
        powerStatus.batteryDisconnected = true;
        powerStatus.batteryLowVoltageUnpowered = false;
        powerStatus.vbat = 0.0f;
        powerStatus.batteryPercent = 0;
        powerStatus.batteryValid = true;
        portEXIT_CRITICAL(&sPowerStatusMux);
        powerStatus.lastBatteryMs = now;
        markPowerSlowPublishDirty(now);
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
        }
        powerStatus.lastBatteryMs = now;
        if (!wasLowVoltageUnpowered)
            markPowerSlowPublishDirty(now);
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

    // Auto-calibration: nextVbat/nextPercent are not yet committed to powerStatus,
    // but we are already past the disconnect/low-voltage early-return paths above,
    // so this sample is "powered" by the same definition batteryHasPoweredVoltage()
    // uses for the value about to be published.
    const bool poweredValidForCalib = isfinite(nextVbat) && nextVbat >= BATTERY_UNPOWERED_LOW_V;
    const bool chargingForCalib = powerStatus.chargeValid && powerStatus.charging;

    // The EMA was just restarted (same condition used to compute nextVbat above):
    // don't let the discharge tracker see the raw, momentarily-unloaded first
    // sample as a genuine low-point.
    const bool emaRestarted = wasDisconnected || wasLowVoltageUnpowered ||
                              !powerStatus.batteryValid || !isfinite(powerStatus.vbat);
    if (emaRestarted || !sBatteryEmaRestartKnown) {
        sBatteryEmaRestartMs = now;
        sBatteryEmaRestartKnown = true;
    }
    const bool emaStableForDischarge =
        millisElapsed(now, sBatteryEmaRestartMs, BATTERY_CALIB_DISCHARGE_STABLE_MS);

    if (chargingForCalib && !sChargingForCalibPrev)
        sChargingForCalibSinceMs = now;
    sChargingForCalibPrev = chargingForCalib;
    const bool chargingContinuous30s =
        chargingForCalib && millisElapsed(now, sChargingForCalibSinceMs, BATTERY_CALIB_CHARGE_ERASE_HOLD_MS);

    // Don't learn max off the charger's CV plateau, except on a board whose ADC
    // reading is clipped — the clipped ceiling is the only value we can ever see.
    const bool allowMaxLearning = !chargingForCalib || adcMv >= BATTERY_ADC_CLIP_MV;
    if (!allowMaxLearning) {
        // Charging (not clipped): cancel any in-progress candidate so a 60 s
        // hold window can't silently span samples we're not feeding it.
        sCalib.candidateActive = false;
    } else if (batteryCalibObserveMax(sCalib, nextVbat, poweredValidForCalib, now)) {
        publishBatteryCalibToStatus();
        markBatteryCalibrationDirty(now);
        RLOG_INFO("ADC", "event=calib_max v=%.3f", sCalib.maxV);
    }

    if (emaStableForDischarge &&
        batteryCalibObserveDischarge(sCalib, nextVbat, poweredValidForCalib, chargingForCalib) &&
        batteryCalibShouldPersistLow(sCalib, sLastPersistedLowV)) {
        saveBatteryPendingLowToNvs(sCalib.pendingLowV);
        sLastPersistedLowV = sCalib.pendingLowV;
        RLOG_INFO("ADC", "event=calib_pending_low v=%.3f", sCalib.pendingLowV);
    }

    // Erase gating runs on EVERY sample, independent of ObserveDischarge's return
    // this sample and independent of the EMA-stability gate above: charging can
    // clear the RAM pendingLowV on a single sample (e.g. the first sample after
    // charging starts), after which ObserveDischarge(charging=true) keeps
    // returning false because pendingLowV is already NAN. If the erase were only
    // evaluated behind that return value it would never run, leaving a stale
    // discharge low-point on NVS that a later power-switch-off would wrongly
    // adopt as the cutoff.
    if (batteryCalibShouldErasePersisted(sCalib, sLastPersistedLowV, chargingContinuous30s, nextVbat)) {
        clearBatteryPendingLowFromNvs();
        sLastPersistedLowV = NAN;
        RLOG_INFO("ADC", "event=calib_pending_erase");
    }

    portENTER_CRITICAL(&sPowerStatusMux);
    powerStatus.batteryDisconnected = false;
    powerStatus.batteryLowVoltageUnpowered = false;
    powerStatus.vbat = nextVbat;
    powerStatus.batteryPercent = nextPercent;
    powerStatus.batteryValid = true;
    portEXIT_CRITICAL(&sPowerStatusMux);
    if (wasDisconnected) {
    }
    powerStatus.lastBatteryMs = now;
    if (wasDisconnected || wasLowVoltageUnpowered)
        markPowerSlowPublishDirty(now);
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

    sCalib.pendingLowV = loadBatteryPendingLowFromNvs();
    const float pendingBeforeAdopt = sCalib.pendingLowV;
    sLastPersistedLowV = pendingBeforeAdopt; // mirrors whatever is currently on NVS, if anything
    const esp_reset_reason_t resetReason = esp_reset_reason();
    const bool powerLossReset = (resetReason == ESP_RST_POWERON || resetReason == ESP_RST_BROWNOUT);
    const bool cutoffChanged = batteryCalibAdoptPendingOnBoot(sCalib, powerLossReset);
    batteryCalibSanitize(sCalib);
    publishBatteryCalibToStatus();
    // Only open NVS read-write to remove the key when a pending value actually existed.
    if (powerLossReset && isfinite(pendingBeforeAdopt)) {
        clearBatteryPendingLowFromNvs();
        sLastPersistedLowV = NAN;
    }
    if (cutoffChanged) {
        RLOG_INFO("ADC", "event=calib_cutoff v=%.3f", sCalib.cutoffV);
        saveBatteryCalibration(now);
    }
    RLOG_INFO("ADC", "event=calib_boot reset=%d pending=%.3f cutoff=%.3f max=%.3f",
              static_cast<int>(resetReason), pendingBeforeAdopt, sCalib.cutoffV, sCalib.maxV);

    analogReadResolution(12);
    // arduino-esp32 v3: analogSetPinAttenuation() on a pin that has not been read yet
    // only logs "Pin is not configured as analog channel" and does nothing. The global
    // setter works before first use: it becomes the attenuation the first
    // analogReadMilliVolts() uses for the channel AND the per-unit calibration curve.
    // Both pins are on ADC1 and share 11 dB (the core default, so readings are unchanged).
    analogSetAttenuation(ADC_11db);
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
    servicePowerSlowPublish(now, force);
}

PowerStatus readPowerStatusSnapshot() {
    // powerStatus is updated by the Core 0 control loop; the Core 1 overlay and the
    // RinaLink protocol handlers must read a coherent copy. Writers commit the consumer-visible
    // fields under sPowerStatusMux, so copying under the same lock yields a tear-free
    // snapshot rather than a mix of old/new fields.
    PowerStatus snapshot;
    portENTER_CRITICAL(&sPowerStatusMux);
    snapshot = powerStatus;
    portEXIT_CRITICAL(&sPowerStatusMux);
    return snapshot;
}
