#include "power_monitor.h"
#include "config.h"
#include "state.h"
#include "sync.h"
#include "storage.h"

#include <algorithm>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <math.h>


// 本文件采样电池/充电电压并发布电源状态；注释保留必要 English identifier，便于和代码/API 对照。
PowerStatus powerStatus;

// 说明电源、电池、充电或 ADC 校准相关逻辑。
// 说明电源、电池、充电或 ADC 校准相关逻辑。
// 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
// 说明电源、电池、充电或 ADC 校准相关逻辑。
// 说明电源、电池、充电或 ADC 校准相关逻辑。
// 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
// 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
constexpr float BATTERY_EMA_TAU_S = 20.0f;   // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
constexpr float CHARGE_EMA_ALPHA  = 0.20f;

/**
 * 读取 readTrimmedAdcMilliVolts 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param pin 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
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

/**
 * 围绕 sanitizedCalibMax 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static float sanitizedCalibMax(float value) {
    if (!isfinite(value)) return BATTERY_FULL_V;
    return max(value, BATTERY_FULL_V);
}

/**
 * 围绕 sanitizedCalibMin 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static float sanitizedCalibMin(float value) {
    if (!isfinite(value)) return BATTERY_EMPTY_V;
    return min(value, BATTERY_EMPTY_V);
}

/**
 * 围绕 jsonFloatOr 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param value 调用方传入或接收的参数，含义以函数签名为准。
 * @param fallback 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static float jsonFloatOr(JsonVariantConst value, float fallback) {
    if (value.isNull()) return fallback;
    const float parsed = value.as<float>();
    return isfinite(parsed) ? parsed : fallback;
}

/**
 * 确保 ensureBatteryCalibrationDefaults 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
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

/**
 * 围绕 markBatteryCalibrationDirty 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void markBatteryCalibrationDirty(uint32_t now) {
    if (!powerStatus.batteryCalibDirty) {
        powerStatus.batteryCalibDirtySinceMs = now;
    }
    powerStatus.batteryCalibDirty = true;
}

/**
 * 围绕 batteryPercentFromVoltage 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param vbat 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static uint8_t batteryPercentFromVoltage(float vbat) {
    if (!isfinite(vbat)) return 0;
    const uint8_t n = BATTERY_PERCENT_LUT_SIZE;
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    if (vbat >= BATTERY_PERCENT_LUT[0].voltage)     return 100;
    if (vbat <= BATTERY_PERCENT_LUT[n - 1].voltage) return 0;
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    for (uint8_t i = 0; i + 1 < n; ++i) {
        const float vHi = BATTERY_PERCENT_LUT[i    ].voltage;
        const float vLo = BATTERY_PERCENT_LUT[i + 1].voltage;
        if (vbat < vHi && vbat >= vLo) {
            const float pHi = static_cast<float>(BATTERY_PERCENT_LUT[i    ].percent);
            const float pLo = static_cast<float>(BATTERY_PERCENT_LUT[i + 1].percent);
            const float t   = (vbat - vLo) / (vHi - vLo);
            return static_cast<uint8_t>(lroundf(pLo + t * (pHi - pLo)));
        }
    }
    return 0;
}

/**
 * 加载 loadBatteryCalibration 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool loadBatteryCalibration(uint32_t now) {
    powerStatus.batteryCalibMaxV = BATTERY_FULL_V;
    powerStatus.batteryCalibMinV = BATTERY_EMPTY_V;
    powerStatus.lastCalibMaxMs = now;
    powerStatus.lastCalibMinMs = now;
    powerStatus.batteryCalibLoaded = false;

    bool calibExists = false;
    if (runtimeFsMounted()) {
        withHardwareBusLock([&]() {
            calibExists = LittleFS.exists(BATTERY_CALIB_PATH);
        });
    }
    if (!runtimeFsMounted() || !calibExists) {
        return false;
    }

    File file;
    withHardwareBusLock([&]() {
        file = LittleFS.open(BATTERY_CALIB_PATH, "r");
    });
    if (!file) return false;

    DynamicJsonDocument doc(512);
    DeserializationError err;
    withHardwareBusLock([&]() {
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

/**
 * 保存 saveBatteryCalibration 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool saveBatteryCalibration(uint32_t now) {
    if (!runtimeFsMounted()) return false;
    bool resourcesOk = false;
    withHardwareBusLock([&]() {
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

/**
 * 更新 updateBatteryCalibration 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param vbat 调用方传入或接收的参数，含义以函数签名为准。
 * @param freezeCalibration 调用方传入或接收的参数，含义以函数签名为准。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void updateBatteryCalibration(float vbat, bool freezeCalibration, uint32_t now) {
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    //
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    ensureBatteryCalibrationDefaults(now);
    (void)vbat;
    (void)freezeCalibration;
}

/**
 * 轮询服务、保存 serviceBatteryCalibrationSave 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void serviceBatteryCalibrationSave(uint32_t now) {
    if (!powerStatus.batteryCalibDirty) return;
    if (now - powerStatus.batteryCalibDirtySinceMs < BATTERY_CALIB_SAVE_DELAY_MS) return;
    saveBatteryCalibration(now);
}

/**
 * 围绕 batteryHasPoweredVoltage 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool batteryHasPoweredVoltage() {
    return powerStatus.batteryValid &&
           !powerStatus.batteryDisconnected &&
           !powerStatus.batteryLowVoltageUnpowered &&
           isfinite(powerStatus.vbat) &&
           powerStatus.vbat >= BATTERY_UNPOWERED_LOW_V;
}

/**
 * 围绕 batteryCanRecordMinimumVoltage 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool batteryCanRecordMinimumVoltage() {
    return batteryHasPoweredVoltage() && !powerStatus.charging;
}

/**
 * 围绕 markPowerCalibrationChanged 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void markPowerCalibrationChanged(uint32_t now) {
    markBatteryCalibrationDirty(now);
    saveBatteryCalibration(now);
    powerStatus.webFastDirty = true;
    powerStatus.webSlowDirty = true;
    powerStatus.lastWebSlowPublishMs = now;
    touchRuntimeState();
}

/**
 * 重置 resetBatteryVoltageMaximum 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
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

/**
 * 重置 resetBatteryVoltageMinimum 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
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

/**
 * 围绕 finiteChanged 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param previous 调用方传入或接收的参数，含义以函数签名为准。
 * @param current 调用方传入或接收的参数，含义以函数签名为准。
 * @param epsilon 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool finiteChanged(float previous, float current, float epsilon) {
    if (!isfinite(previous) && !isfinite(current)) return false;
    if (!isfinite(previous) || !isfinite(current)) return true;
    return fabsf(previous - current) >= epsilon;
}

/**
 * 围绕 markPowerWebFastDirty 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void markPowerWebFastDirty() {
    powerStatus.webFastDirty = true;
    touchRuntimeState();
}

/**
 * 围绕 markPowerWebSlowDirty 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
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

/**
 * 轮询服务、发布 servicePowerWebPublish 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @param force 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
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

/**
 * 围绕 sampleBattery 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
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

    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
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

    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    //
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    if (wasLowVoltageUnpowered) powerStatus.vbat = NAN;
    powerStatus.batteryLowVoltageUnpowered = false;  // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。

    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    //
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    if (!powerStatus.batteryValid || !isfinite(powerStatus.vbat)) {
        powerStatus.vbat = instantVbat;
    } else {
        // 说明电源、电池、充电或 ADC 校准相关逻辑。
        // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
        const float dtS = constrain(
            static_cast<float>(now - powerStatus.lastBatteryMs) * 0.001f,
            0.001f, 10.0f);
        const float emaAlpha = 1.0f - expf(-dtS / BATTERY_EMA_TAU_S);
        powerStatus.vbat = (powerStatus.vbat * (1.0f - emaAlpha)) +
                            (instantVbat * emaAlpha);
    }

    const bool freezeCalibration = chargerPresent ||
        powerStatus.batteryDisconnected ||
        powerStatus.batteryLowVoltageUnpowered ||
        powerStatus.vbat < BATTERY_UNPOWERED_LOW_V;
    updateBatteryCalibration(powerStatus.vbat, freezeCalibration, now);

    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    {
        const uint8_t rawPct = batteryPercentFromVoltage(powerStatus.vbat);
        const int16_t delta  = static_cast<int16_t>(rawPct) -
                                static_cast<int16_t>(powerStatus.batteryPercent);
        if (!powerStatus.batteryValid || delta > 1 || delta < -1) {
            powerStatus.batteryPercent = rawPct;
        }
    }
    powerStatus.batteryValid = true;
    powerStatus.lastBatteryMs = now;
    if (wasDisconnected || wasLowVoltageUnpowered) markPowerWebSlowDirty(now);
}

/**
 * 围绕 sampleCharge 处理本模块的核心流程，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void sampleCharge(uint32_t now) {
    const uint16_t adcMv = readTrimmedAdcMilliVolts(CHARGE_ADC_PIN);
    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    powerStatus.chargeAdcMv = adcMv;

    const float instantVcharge = vadc * CHARGE_CAL_SCALE + CHARGE_CAL_OFFSET_V;

    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    //
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明 电源、电池和 ADC 采样 中当前代码块的职责和维护约束。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    const bool instantCharging    = instantVcharge > CHARGE_PRESENT_V;
    const bool chargerStateChange = (powerStatus.charging != instantCharging);

    if (!powerStatus.chargeValid || !isfinite(powerStatus.vcharge) || chargerStateChange) {
        powerStatus.vcharge = instantVcharge;
    } else {
        powerStatus.vcharge = (powerStatus.vcharge * (1.0f - CHARGE_EMA_ALPHA)) +
                               (instantVcharge * CHARGE_EMA_ALPHA);
    }

    powerStatus.charging = powerStatus.vcharge > CHARGE_PRESENT_V;
    powerStatus.chargeValid = true;
    powerStatus.lastChargeMs = now;
}

/**
 * 初始化 initPowerMonitor 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void initPowerMonitor() {
    const uint32_t now = millis();
    loadBatteryCalibration(now);
    ensureBatteryCalibrationDefaults(now);
    analogReadResolution(12);
    analogSetPinAttenuation(BATTERY_ADC_PIN, ADC_11db);
    analogSetPinAttenuation(CHARGE_ADC_PIN, ADC_11db);
    servicePowerMonitor(true);
}

/**
 * 轮询服务 servicePowerMonitor 相关逻辑，供 power_monitor 模块使用。
 * @brief 说明 电源、电池和 ADC 采样 中当前函数或声明的用途。
 * @param force 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
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
