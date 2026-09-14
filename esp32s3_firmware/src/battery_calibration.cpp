#include "battery_calibration.h"

#include <cmath>

namespace {
constexpr float kLutTopV = 8.40f;
constexpr float kLutBottomV = 6.20f;
constexpr float kMaxClampLoV = 7.00f;
constexpr float kMaxClampHiV = 9.50f;
constexpr float kCutoffClampLoV = 5.00f;
constexpr float kCutoffClampHiV = 7.20f;
constexpr float kMinSpanV = 0.50f;
constexpr float kMaxMarginV = 0.02f;
constexpr uint32_t kMaxHoldMs = 60000;
constexpr float kLowZoneFraction = 0.35f;
constexpr float kPendingLowStepV = 0.05f;
constexpr float kPendingLowClearMarginV = 0.20f;
constexpr float kAdoptMaxAboveCutoffFraction = 0.15f;
constexpr float kCutoffRiseCapV = 0.05f;

float nan() { return std::nanf(""); }
} // namespace

BatteryCalibState batteryCalibDefaults() {
    BatteryCalibState state;
    state.maxV = kLutTopV;
    state.cutoffV = kLutBottomV;
    state.maxLearned = false;
    state.cutoffLearned = false;
    state.candidateActive = false;
    state.candidateSinceMs = 0;
    state.candidateMinV = 0.0f;
    state.pendingLowV = nan();
    return state;
}

void batteryCalibSanitize(BatteryCalibState& state) {
    if (!std::isfinite(state.maxV))
        state.maxV = kLutTopV;
    if (!std::isfinite(state.cutoffV))
        state.cutoffV = kLutBottomV;

    if (state.maxV < kMaxClampLoV)
        state.maxV = kMaxClampLoV;
    else if (state.maxV > kMaxClampHiV)
        state.maxV = kMaxClampHiV;

    if (state.cutoffV < kCutoffClampLoV)
        state.cutoffV = kCutoffClampLoV;
    else if (state.cutoffV > kCutoffClampHiV)
        state.cutoffV = kCutoffClampHiV;

    if (state.maxV - state.cutoffV < kMinSpanV) {
        state.maxV = kLutTopV;
        state.cutoffV = kLutBottomV;
        state.maxLearned = false;
        state.cutoffLearned = false;
    }
}

bool batteryCalibObserveMax(BatteryCalibState& state, float vbatEma, bool poweredValid, uint32_t nowMs) {
    if (!poweredValid || !std::isfinite(vbatEma))
        return false;

    if (vbatEma > state.maxV + kMaxMarginV) {
        if (!state.candidateActive) {
            state.candidateActive = true;
            state.candidateSinceMs = nowMs;
            state.candidateMinV = vbatEma;
        } else if (vbatEma < state.candidateMinV) {
            state.candidateMinV = vbatEma;
        }
        const uint32_t held = nowMs - state.candidateSinceMs;
        if (held >= kMaxHoldMs) {
            state.maxV = state.candidateMinV;
            state.maxLearned = true;
            state.candidateActive = false;
            return true;
        }
        return false;
    }

    // At or below the margin: cancel any in-progress candidate.
    if (state.candidateActive) {
        state.candidateActive = false;
    }
    return false;
}

float batteryCalibLowZoneEdgeV(const BatteryCalibState& state) {
    // Anchored to the fixed LUT floor, not the learned cutoffV: if this used
    // cutoffV, a wrong cutoff learned from a power-switch-off could shrink or
    // grow the zone that decides what counts as "near cutoff" on its own.
    return kLutBottomV + kLowZoneFraction * (state.maxV - kLutBottomV);
}

bool batteryCalibAboveClearMargin(const BatteryCalibState& state, float vbat) {
    if (!std::isfinite(vbat))
        return false;
    return vbat > batteryCalibLowZoneEdgeV(state) + kPendingLowClearMarginV;
}

bool batteryCalibObserveDischarge(BatteryCalibState& state, float vbatEma, bool poweredValid, bool charging) {
    if (!std::isfinite(vbatEma))
        return false;

    const float lowZoneV = batteryCalibLowZoneEdgeV(state);

    if (poweredValid && !charging && vbatEma <= lowZoneV) {
        if (!std::isfinite(state.pendingLowV) || vbatEma <= state.pendingLowV - kPendingLowStepV) {
            state.pendingLowV = vbatEma;
            return true;
        }
        return false;
    }

    if (charging || vbatEma > lowZoneV + kPendingLowClearMarginV) {
        if (std::isfinite(state.pendingLowV)) {
            state.pendingLowV = nan();
            return true;
        }
        return false;
    }

    return false;
}

bool batteryCalibShouldPersistLow(const BatteryCalibState& state, float lastPersistedLowV) {
    return std::isfinite(state.pendingLowV) &&
           (!std::isfinite(lastPersistedLowV) || state.pendingLowV < lastPersistedLowV - kPendingLowStepV);
}

bool batteryCalibShouldErasePersisted(const BatteryCalibState& state, float lastPersistedLowV,
                                      bool chargingContinuous30s, float vbatEma) {
    return !std::isfinite(state.pendingLowV) && std::isfinite(lastPersistedLowV) &&
           (chargingContinuous30s || batteryCalibAboveClearMargin(state, vbatEma));
}

bool batteryCalibAdoptPendingOnBoot(BatteryCalibState& state, bool powerLossReset) {
    if (!powerLossReset)
        return false;

    bool changed = false;
    const float adoptCeilingV = state.cutoffV + kAdoptMaxAboveCutoffFraction * (state.maxV - state.cutoffV);
    if (std::isfinite(state.pendingLowV) &&
        state.pendingLowV >= kCutoffClampLoV && state.pendingLowV <= kCutoffClampHiV &&
        state.pendingLowV < state.maxV - kMinSpanV &&
        state.pendingLowV <= adoptCeilingV) {
        float newCutoff = state.pendingLowV;
        if (state.cutoffLearned) {
            newCutoff = 0.5f * state.cutoffV + 0.5f * state.pendingLowV;
            const float riseCapV = state.cutoffV + kCutoffRiseCapV;
            if (newCutoff > riseCapV)
                newCutoff = riseCapV;
        }
        if (newCutoff != state.cutoffV || !state.cutoffLearned)
            changed = true;
        state.cutoffV = newCutoff;
        state.cutoffLearned = true;
    }
    state.pendingLowV = nan();
    return changed;
}

float batteryCalibNormalizedVoltage(const BatteryCalibState& state, float vbat) {
    if (!std::isfinite(vbat))
        return vbat;
    const float span = state.maxV - state.cutoffV;
    if (!(span >= kMinSpanV))
        return vbat;
    const float t = (vbat - state.cutoffV) / span;
    return kLutBottomV + t * (kLutTopV - kLutBottomV);
}
