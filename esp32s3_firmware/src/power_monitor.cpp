#include "power_monitor.h"
#include "config.h"

#include <algorithm>
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

static uint8_t batteryPercentFromVoltage(float vbat) {
    const float span = BATTERY_FULL_V - BATTERY_EMPTY_V;
    if (!(span > 0.0f) || !isfinite(vbat)) return 0;
    const float pct = (vbat - BATTERY_EMPTY_V) * 100.0f / span;
    return static_cast<uint8_t>(constrain(lroundf(pct), 0L, 100L));
}

static void sampleBattery(uint32_t now) {
    const uint16_t adcMv = readTrimmedAdcMilliVolts(BATTERY_ADC_PIN);
    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    powerStatus.batteryAdcMv = adcMv;
    powerStatus.vbat = vadc * dividerScale(BATTERY_DIVIDER_R1_K, BATTERY_DIVIDER_R2_K);
    powerStatus.batteryPercent = batteryPercentFromVoltage(powerStatus.vbat);
    powerStatus.batteryValid = true;
    powerStatus.lastBatteryMs = now;
}

static void sampleCharge(uint32_t now) {
    const uint16_t adcMv = readTrimmedAdcMilliVolts(CHARGE_ADC_PIN);
    const float vadc = static_cast<float>(adcMv) / 1000.0f;
    powerStatus.chargeAdcMv = adcMv;
    powerStatus.vcharge = vadc * dividerScale(CHARGE_DIVIDER_R1_K, CHARGE_DIVIDER_R2_K);
    powerStatus.charging = powerStatus.vcharge > CHARGE_PRESENT_V;
    powerStatus.chargeValid = true;
    powerStatus.lastChargeMs = now;
}

void initPowerMonitor() {
    analogReadResolution(12);
    analogSetPinAttenuation(BATTERY_ADC_PIN, ADC_11db);
    analogSetPinAttenuation(CHARGE_ADC_PIN, ADC_11db);
    servicePowerMonitor(true);
}

void servicePowerMonitor(bool force) {
    const uint32_t now = millis();
    if (force || !powerStatus.batteryValid || now - powerStatus.lastBatteryMs >= BATTERY_SAMPLE_MS) {
        sampleBattery(now);
    }
    if (force || !powerStatus.chargeValid || now - powerStatus.lastChargeMs >= CHARGE_SAMPLE_MS) {
        sampleCharge(now);
    }
}
