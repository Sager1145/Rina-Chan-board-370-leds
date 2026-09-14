#pragma once
// Pure, Arduino-free battery calibration logic (host-testable). No Arduino.h,
// no LittleFS, no Preferences here — power_monitor.cpp owns persistence and
// wires this module's state into PowerStatus / NVS / battery_calib.json.
#include <cstdint>

struct BatteryCalibState {
    float maxV = 8.40f;
    float cutoffV = 6.20f;
    bool maxLearned = false;
    bool cutoffLearned = false;

    // Max-candidate tracking (sustained-high-reading detector).
    bool candidateActive = false;
    uint32_t candidateSinceMs = 0;
    float candidateMinV = 0.0f;

    // Discharge low-point tracking, persisted to NVS close to power loss.
    float pendingLowV = 0.0f; // NAN if none pending
};

// Defaults: maxV = LUT top (8.40 V), cutoffV = LUT bottom (6.20 V).
BatteryCalibState batteryCalibDefaults();

// Clamp/repair state in place: non-finite -> defaults; maxV clamped to
// [7.00, 9.50]; cutoffV clamped to [5.00, 7.20]; if maxV - cutoffV < 0.50,
// reset both to defaults and clear the learned flags.
void batteryCalibSanitize(BatteryCalibState& state);

// Sustained-high-reading detector for the highest measurable pack voltage
// (including an ADC-clipped ceiling — that IS the value we want to learn).
// Only evaluated when poweredValid. Returns true if state.maxV changed.
bool batteryCalibObserveMax(BatteryCalibState& state, float vbatEma, bool poweredValid, uint32_t nowMs);

// Tracks the lowest voltage seen while discharging in the "low zone" near
// cutoff, so a value is ready to persist just before a possible power loss.
// Returns true if state.pendingLowV changed (set or cleared).
bool batteryCalibObserveDischarge(BatteryCalibState& state, float vbatEma, bool poweredValid, bool charging);

// Called once at boot. If powerLossReset is true and pendingLowV is a plausible
// cutoff (within [5.00,7.20], < maxV - 0.50, and not more than 15% of the
// [cutoffV,maxV] span above the current cutoffV — this rejects a power-SWITCH-off
// at a comfortable charge level, which also reports ESP_RST_POWERON), adopts it
// into cutoffV. If cutoffV was already learned, the result is a 50/50 blend that
// may fall freely but may rise by at most 0.05 V per adoption (so a wrong,
// switch-off-induced high reading cannot creep the cutoff upward over many boots).
// pendingLowV is cleared after being considered when powerLossReset is true.
// Returns true if state.cutoffV changed.
bool batteryCalibAdoptPendingOnBoot(BatteryCalibState& state, bool powerLossReset);

// The fixed-floor discharge "low zone" edge used by batteryCalibObserveDischarge:
// anchored to the LUT bottom (not the learned cutoffV) so the zone doesn't drift.
float batteryCalibLowZoneEdgeV(const BatteryCalibState& state);

// True if vbat has recovered far enough above the low zone to be a durable
// (not momentary) reason to drop a pending low-point, e.g. before erasing NVS.
bool batteryCalibAboveClearMargin(const BatteryCalibState& state, float vbat);

// NVS persistence gates for state.pendingLowV, evaluated independently of
// whether batteryCalibObserveDischarge changed anything THIS sample — the
// caller must re-check the erase condition on every sample (not just the one
// where pendingLowV first went to NAN), otherwise a stale NVS value survives
// past a single-sample RAM clear (e.g. a charging flag that only flips once).
bool batteryCalibShouldPersistLow(const BatteryCalibState& state, float lastPersistedLowV);
bool batteryCalibShouldErasePersisted(const BatteryCalibState& state, float lastPersistedLowV,
                                      bool chargingContinuous30s, float vbatEma);

// Maps a measured pack voltage from [cutoffV, maxV] onto the LUT's nominal
// [6.20, 8.40] span for percent lookup. Values above maxV map above 8.40
// (-> 100%); values below cutoffV map below 6.20 (-> 0%).
float batteryCalibNormalizedVoltage(const BatteryCalibState& state, float vbat);
