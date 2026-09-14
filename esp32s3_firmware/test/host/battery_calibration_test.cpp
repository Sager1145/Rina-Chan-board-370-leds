// Run: c++ -std=c++17 -Wall -Wextra -Werror -Iesp32s3_firmware/src \
//   esp32s3_firmware/src/battery_calibration.cpp \
//   esp32s3_firmware/test/host/battery_calibration_test.cpp -o /tmp/rina-batt-calib-test && /tmp/rina-batt-calib-test
#include "battery_calibration.h"

#include <cassert>
#include <cmath>
#include <cstdio>

static void test_defaults_and_sanitize() {
    BatteryCalibState d = batteryCalibDefaults();
    assert(std::fabs(d.maxV - 8.40f) < 1e-6f);
    assert(std::fabs(d.cutoffV - 6.20f) < 1e-6f);
    assert(!d.maxLearned);
    assert(!d.cutoffLearned);
    assert(!std::isfinite(d.pendingLowV));

    // Non-finite -> defaults.
    BatteryCalibState s;
    s.maxV = std::nanf("");
    s.cutoffV = std::nanf("");
    batteryCalibSanitize(s);
    assert(std::fabs(s.maxV - 8.40f) < 1e-6f);
    assert(std::fabs(s.cutoffV - 6.20f) < 1e-6f);

    // Clamp out-of-range values.
    BatteryCalibState c;
    c.maxV = 20.0f;
    c.cutoffV = 0.0f;
    batteryCalibSanitize(c);
    assert(std::fabs(c.maxV - 9.50f) < 1e-6f);
    assert(std::fabs(c.cutoffV - 5.00f) < 1e-6f);

    // Span too small -> reset to defaults and clear learned flags.
    BatteryCalibState span;
    span.maxV = 7.00f;
    span.cutoffV = 6.80f; // span 0.20 < 0.50
    span.maxLearned = true;
    span.cutoffLearned = true;
    batteryCalibSanitize(span);
    assert(std::fabs(span.maxV - 8.40f) < 1e-6f);
    assert(std::fabs(span.cutoffV - 6.20f) < 1e-6f);
    assert(!span.maxLearned);
    assert(!span.cutoffLearned);

    printf("test_defaults_and_sanitize: OK\n");
}

static void test_noise_spike_does_not_learn_max() {
    BatteryCalibState s = batteryCalibDefaults();
    uint32_t t = 0;
    bool changed = false;
    // 1 s of a spike above max, then it falls back.
    for (; t <= 1000; t += 100) {
        changed = batteryCalibObserveMax(s, 9.0f, true, t) || changed;
    }
    // Drop back below margin: cancels the candidate.
    changed = batteryCalibObserveMax(s, 8.30f, true, t) || changed;
    assert(!changed);
    assert(std::fabs(s.maxV - 8.40f) < 1e-6f);
    assert(!s.maxLearned);
    printf("test_noise_spike_does_not_learn_max: OK\n");
}

static void test_sustained_high_value_learns_minimum_in_window() {
    BatteryCalibState s = batteryCalibDefaults();
    bool changed = false;
    // 70 s sustained above max; value dips partway through, minimum should win.
    uint32_t t = 0;
    changed = batteryCalibObserveMax(s, 8.60f, true, t) || changed; // starts candidate
    for (t = 1000; t <= 30000; t += 1000)
        changed = batteryCalibObserveMax(s, 8.60f, true, t) || changed;
    // Dip to a lower (but still above-margin) value partway through the hold.
    for (; t <= 50000; t += 1000)
        changed = batteryCalibObserveMax(s, 8.55f, true, t) || changed;
    for (; t < 60000; t += 1000)
        changed = batteryCalibObserveMax(s, 8.60f, true, t) || changed;
    assert(!changed); // not yet 60s held
    changed = batteryCalibObserveMax(s, 8.60f, true, 60000 + 1) || changed;
    assert(changed);
    assert(std::fabs(s.maxV - 8.55f) < 1e-3f);
    assert(s.maxLearned);
    printf("test_sustained_high_value_learns_minimum_in_window: OK\n");
}

static void test_clipped_ceiling_learns_and_normalizes() {
    BatteryCalibState s = batteryCalibDefaults();
    bool changed = false;
    for (uint32_t t = 0; t <= 60000; t += 1000)
        changed = batteryCalibObserveMax(s, 8.73f, true, t) || changed;
    assert(changed);
    assert(std::fabs(s.maxV - 8.73f) < 1e-3f);
    assert(s.maxLearned);

    const float norm = batteryCalibNormalizedVoltage(s, 8.73f);
    assert(norm >= 8.40f);
    printf("test_clipped_ceiling_learns_and_normalizes: OK\n");
}

static void test_discharge_writes_pending_low_on_steps_only() {
    BatteryCalibState s = batteryCalibDefaults(); // maxV 8.40, cutoffV 6.20 -> low zone <= 6.97
    int writes = 0;
    // Slow ramp down from 7.0 to 6.0 V in 0.01 V steps (100 samples).
    for (int i = 0; i <= 100; ++i) {
        const float v = 7.0f - 0.01f * static_cast<float>(i);
        if (batteryCalibObserveDischarge(s, v, true, false))
            ++writes;
    }
    // ~ (7.0-6.0)/0.05 = 20 writes, not hundreds.
    assert(writes >= 15 && writes <= 25);
    assert(std::isfinite(s.pendingLowV));
    printf("test_discharge_writes_pending_low_on_steps_only: writes=%d OK\n", writes);
}

static void test_charging_clears_pending() {
    BatteryCalibState s = batteryCalibDefaults();
    bool wrote = batteryCalibObserveDischarge(s, 6.50f, true, false);
    assert(wrote);
    assert(std::isfinite(s.pendingLowV));
    bool cleared = batteryCalibObserveDischarge(s, 6.55f, true, true);
    assert(cleared);
    assert(!std::isfinite(s.pendingLowV));
    printf("test_charging_clears_pending: OK\n");
}

static void test_switch_off_moderate_charge_does_not_adopt() {
    // A power-switch-off at ~17% (6.95 V) also reports ESP_RST_POWERON, same as a
    // true over-discharge cutoff. It must not be adopted as the new cutoff.
    BatteryCalibState s = batteryCalibDefaults();
    s.pendingLowV = 6.95f;
    bool changed = batteryCalibAdoptPendingOnBoot(s, true);
    assert(!changed);
    assert(std::fabs(s.cutoffV - 6.20f) < 1e-6f);
    assert(!s.cutoffLearned);
    printf("test_switch_off_moderate_charge_does_not_adopt: OK\n");
}

static void test_repeated_switch_offs_never_creep_cutoff_up() {
    BatteryCalibState s = batteryCalibDefaults();
    for (int i = 0; i < 5; ++i) {
        s.pendingLowV = 7.10f;
        bool changed = batteryCalibAdoptPendingOnBoot(s, true);
        // The 0.15-of-span rule rejects 7.10 V against a cutoff still at/near
        // default, so this never adopts and the cutoff can't creep upward.
        assert(!changed);
        assert(s.cutoffV <= 6.20f + 0.05f * static_cast<float>(i + 1) + 1e-6f);
    }
    assert(std::fabs(s.cutoffV - 6.20f) < 1e-6f);
    assert(!s.cutoffLearned);
    printf("test_repeated_switch_offs_never_creep_cutoff_up: OK\n");
}

// Per-sample structure below mirrors power_monitor.cpp's sampleBattery(): the
// write gate is checked only when ObserveDischarge just changed something, but
// the erase gate (batteryCalibShouldErasePersisted) is checked on EVERY sample,
// independent of ObserveDischarge's return value this sample.
static void test_charging_flap_limits_nvs_churn() {
    BatteryCalibState s = batteryCalibDefaults();
    float lastPersisted = std::nanf("");
    int writes = 0;
    int erases = 0;
    bool chargingPrev = false;
    uint32_t chargingSinceMs = 0;
    const float vbat = 6.50f; // inside the low zone (<= 6.97 for default state)
    for (uint32_t t = 0; t < 3600000; t += 1000) {
        const bool charging = ((t / 1000) % 2) == 0; // flips every second
        if (charging && !chargingPrev)
            chargingSinceMs = t;
        chargingPrev = charging;
        const bool chargingContinuous30s = charging && (t - chargingSinceMs) >= 30000;

        if (batteryCalibObserveDischarge(s, vbat, true, charging) &&
            batteryCalibShouldPersistLow(s, lastPersisted)) {
            lastPersisted = s.pendingLowV;
            ++writes;
        }
        if (batteryCalibShouldErasePersisted(s, lastPersisted, chargingContinuous30s, vbat)) {
            lastPersisted = std::nanf("");
            ++erases;
        }
    }
    assert(erases == 0); // never continuously charging 30s, vbat never recovers
    assert(writes + erases <= 5);
    printf("test_charging_flap_limits_nvs_churn: writes=%d erases=%d OK\n", writes, erases);
}

static void test_continuous_charging_erases_persisted_once() {
    BatteryCalibState s = batteryCalibDefaults();
    float lastPersisted = std::nanf("");

    // Discharge near cutoff long enough to persist a low point.
    for (uint32_t t = 0; t < 5000; t += 1000) {
        if (batteryCalibObserveDischarge(s, 6.30f, true, false) &&
            batteryCalibShouldPersistLow(s, lastPersisted)) {
            lastPersisted = s.pendingLowV;
        }
    }
    assert(std::isfinite(lastPersisted));

    int erases = 0;
    uint32_t chargingSinceMs = 5000;
    for (uint32_t t = 5000; t <= 40000; t += 1000) {
        const bool chargingContinuous30s = (t - chargingSinceMs) >= 30000;
        batteryCalibObserveDischarge(s, 8.0f, true, true); // clears RAM pendingLowV
        if (batteryCalibShouldErasePersisted(s, lastPersisted, chargingContinuous30s, 8.0f)) {
            lastPersisted = std::nanf("");
            ++erases;
        }
    }
    assert(erases == 1);
    assert(!std::isfinite(lastPersisted));
    printf("test_continuous_charging_erases_persisted_once: OK\n");
}

// Reproduces the reviewer-reported scenario: discharge to 6.30 V (persists a
// low point) -> charge for 2 h (must erase the stale NVS value well before the
// 2 h are up, not just clear RAM once) -> run 1 h at 8.3 V -> power-switch off.
// Boot must NOT adopt a stale 6.3xx cutoff from NVS.
static void test_full_charge_cycle_does_not_leave_stale_nvs_value() {
    BatteryCalibState s = batteryCalibDefaults();
    float lastPersisted = std::nanf("");

    for (uint32_t t = 0; t < 5000; t += 1000) {
        if (batteryCalibObserveDischarge(s, 6.30f, true, false) &&
            batteryCalibShouldPersistLow(s, lastPersisted)) {
            lastPersisted = s.pendingLowV;
        }
    }
    assert(std::isfinite(lastPersisted));

    uint32_t t = 5000;
    const uint32_t chargingSinceMs = t;
    for (; t < 5000 + 2u * 3600000u; t += 1000) {
        const bool chargingContinuous30s = (t - chargingSinceMs) >= 30000;
        batteryCalibObserveDischarge(s, 8.3f, true, true);
        if (batteryCalibShouldErasePersisted(s, lastPersisted, chargingContinuous30s, 8.3f))
            lastPersisted = std::nanf("");
    }
    assert(!std::isfinite(lastPersisted)); // erased long before the 2 h charge ends

    for (; t < 5000 + 2u * 3600000u + 3600000u; t += 1000) {
        batteryCalibObserveDischarge(s, 8.3f, true, false);
        if (batteryCalibShouldErasePersisted(s, lastPersisted, false, 8.3f))
            lastPersisted = std::nanf("");
    }

    // Power-switch off: boot loads whatever is (correctly, now) in NVS.
    BatteryCalibState boot = s;
    boot.pendingLowV = lastPersisted;
    bool changed = batteryCalibAdoptPendingOnBoot(boot, true);
    assert(!changed);
    assert(std::fabs(boot.cutoffV - 6.20f) < 1e-6f);
    printf("test_full_charge_cycle_does_not_leave_stale_nvs_value: OK\n");
}

static void test_adopt_pending_on_boot() {
    // Power-loss reset adopts a plausible pending value (also covers "real
    // cutoff near 6.3 adopts").
    {
        BatteryCalibState s = batteryCalibDefaults();
        s.pendingLowV = 6.30f;
        bool changed = batteryCalibAdoptPendingOnBoot(s, true);
        assert(changed);
        assert(std::fabs(s.cutoffV - 6.30f) < 1e-6f);
        assert(s.cutoffLearned);
        assert(!std::isfinite(s.pendingLowV));
    }
    // Second adoption blends with the previously learned cutoff.
    {
        BatteryCalibState s = batteryCalibDefaults();
        s.cutoffV = 6.30f;
        s.cutoffLearned = true;
        s.pendingLowV = 6.10f;
        bool changed = batteryCalibAdoptPendingOnBoot(s, true);
        assert(changed);
        assert(std::fabs(s.cutoffV - 6.20f) < 1e-3f); // 0.5*6.30 + 0.5*6.10
    }
    // Out-of-range pending value is ignored.
    {
        BatteryCalibState s = batteryCalibDefaults();
        s.pendingLowV = 4.0f; // below 5.00 clamp
        bool changed = batteryCalibAdoptPendingOnBoot(s, true);
        assert(!changed);
        assert(std::fabs(s.cutoffV - 6.20f) < 1e-6f);
        assert(!std::isfinite(s.pendingLowV));
    }
    // Value too close to maxV (span < 0.50) is ignored.
    {
        BatteryCalibState s = batteryCalibDefaults();
        s.pendingLowV = 8.20f; // maxV(8.40) - 0.50 = 7.90, 8.20 fails < 7.90
        bool changed = batteryCalibAdoptPendingOnBoot(s, true);
        assert(!changed);
        assert(!std::isfinite(s.pendingLowV));
    }
    // Non-power-loss reset keeps the pending value for later.
    {
        BatteryCalibState s = batteryCalibDefaults();
        s.pendingLowV = 6.30f;
        bool changed = batteryCalibAdoptPendingOnBoot(s, false);
        assert(!changed);
        assert(std::fabs(s.cutoffV - 6.20f) < 1e-6f);
        assert(std::isfinite(s.pendingLowV));
        assert(std::fabs(s.pendingLowV - 6.30f) < 1e-6f);
    }
    printf("test_adopt_pending_on_boot: OK\n");
}

static void test_normalization_identity_for_default_state() {
    BatteryCalibState s = batteryCalibDefaults();
    assert(std::fabs(batteryCalibNormalizedVoltage(s, 6.20f) - 6.20f) < 1e-4f);
    assert(std::fabs(batteryCalibNormalizedVoltage(s, 8.40f) - 8.40f) < 1e-4f);
    printf("test_normalization_identity_for_default_state: OK\n");
}

int main() {
    test_defaults_and_sanitize();
    test_noise_spike_does_not_learn_max();
    test_sustained_high_value_learns_minimum_in_window();
    test_clipped_ceiling_learns_and_normalizes();
    test_discharge_writes_pending_low_on_steps_only();
    test_charging_clears_pending();
    test_switch_off_moderate_charge_does_not_adopt();
    test_repeated_switch_offs_never_creep_cutoff_up();
    test_charging_flap_limits_nvs_churn();
    test_continuous_charging_erases_persisted_once();
    test_full_charge_cycle_does_not_leave_stale_nvs_value();
    test_adopt_pending_on_boot();
    test_normalization_identity_for_default_state();
    printf("All battery_calibration tests passed.\n");
    return 0;
}
