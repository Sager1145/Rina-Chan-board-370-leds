#include "faces.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include "storage.h"   // for ensureSavedFacesLoaded, saveRuntimeSettings

static constexpr uint8_t DEFERRED_RESTORE_NONE            = 0;
static constexpr uint8_t DEFERRED_RESTORE_STARTUP_DEFAULT = 1;
static constexpr uint8_t DEFERRED_RESTORE_CURRENT_FACE    = 2;

// ---------------------------------------------------------------------------
// Mode helpers
// ---------------------------------------------------------------------------

bool isAutoMode() {
    return state.mode == "auto";
}

String normalizedMode(const char* input) {
    String mode = input ? String(input) : String();
    mode.trim();
    if (mode == "自动" || mode == "A") return "auto";
    if (mode == "手动" || mode == "M") return "manual";
    mode.toLowerCase();
    if (mode == "auto"   || mode == "a") return "auto";
    if (mode == "manual" || mode == "m") return "manual";
    return mode;
}

bool setMode(const char* input, bool persistSettings) {
    const String mode = normalizedMode(input);
    if (mode == "auto") {
        state.mode              = "auto";
        state.playback          = "auto_saved_face";
        state.paused            = false;
        state.lastAutoSwitchMs  = millis();
    } else if (mode == "manual") {
        state.mode = "manual";
        if (persistSettings) state.restoreAutoAfterScroll = false;
        if (state.playback == "auto_saved_face") state.playback = DEFAULT_PLAYBACK;
    } else {
        return false;
    }
    if (persistSettings) saveRuntimeSettings();
    return true;
}

void setAutoInterval(uint32_t ms, bool persistSettings) {
    state.autoIntervalMs = constrain(ms, MIN_AUTO_INTERVAL_MS, MAX_AUTO_INTERVAL_MS);
    if (persistSettings) saveRuntimeSettings();
}

// ---------------------------------------------------------------------------
// Playback state query
// ---------------------------------------------------------------------------

bool isScrollPlayback(const String& playback) {
    return playback == "scroll" ||
           playback == "scroll_paused" ||
           playback == "scroll_step";
}

bool playbackIsNonFaceActivity() {
    if (state.firmwareScrollActive || state.firmwareScrollPaused) return true;
    if (isScrollPlayback(state.playback)) return true;
    if (state.lastReason.startsWith("text_scroll_") ||
        state.lastReason.startsWith("custom_") ||
        state.lastReason.startsWith("parts_") ||
        state.lastReason.startsWith("debug_")) return true;
    if (state.playback == DEFAULT_PLAYBACK || state.playback == "auto_saved_face") return false;
    return true;
}

// ---------------------------------------------------------------------------
// Face apply helpers
// ---------------------------------------------------------------------------

bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback) {
    if (!ensureSavedFacesLoaded()) {
        Serial.println("No saved faces available for button action");
        return false;
    }

    state.autoFaceIndex = index % autoFaceCount;
    if (playback) state.playback = playback;

    String error;
    if (!applyM370(autoFaces[state.autoFaceIndex].m370, reason, error)) {
        Serial.printf("saved face apply failed: %s\n", error.c_str());
        return false;
    }
    Serial.printf("Applied saved face %u/%u via %s: %s\n",
                  state.autoFaceIndex + 1, autoFaceCount,
                  reason.c_str(), autoFaces[state.autoFaceIndex].id.c_str());
    return true;
}

bool applyRelativeSavedFace(int8_t delta, const String& reason) {
    if (!ensureSavedFacesLoaded()) return false;
    int32_t next = static_cast<int32_t>(state.autoFaceIndex) + delta;
    while (next < 0) next += autoFaceCount;
    next %= autoFaceCount;
    return applySavedFaceIndex(static_cast<uint16_t>(next), reason, DEFAULT_PLAYBACK);
}

bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode) {
    if (!ensureSavedFacesLoaded()) return false;
    const char*    playback = autoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    const uint16_t index    = autoFaceCount > 0 ? state.autoFaceIndex % autoFaceCount : 0;
    const bool     applied  = applySavedFaceIndex(index, reason, playback);
    if (applied && autoMode) state.lastAutoSwitchMs = millis();
    return applied;
}

bool toggleModeFromButtonAction(const String& source) {
    const bool targetAuto       = !isAutoMode();
    const bool hadOtherPlayback = playbackIsNonFaceActivity();

    // B3 also serves as an emergency exit from text scroll / overlays.
    stopFirmwareScroll(false, false);
    state.restoreAutoAfterScroll = false;

    if (!setMode(targetAuto ? "auto" : "manual", true)) return false;

    const String restoreReason = source +
        (targetAuto ? "_B3_auto_current_saved_face" : "_B3_manual_current_saved_face");

    if (hadOtherPlayback) {
        applyBlankFrame(source + "_B3_clear_before_saved_face");
        scheduleCurrentSavedFaceRestoreAfterBlank(targetAuto, restoreReason);
        return true;
    }

    const bool faceApplied = applyCurrentSavedFaceForMode(restoreReason, targetAuto);
    if (!faceApplied) {
        Serial.println("B3/M-A switched mode but no saved face was available to apply");
    }
    return true;
}

// ---------------------------------------------------------------------------
// Scroll stop / startup face restore
// ---------------------------------------------------------------------------

static int16_t findStartupDefaultFaceIndex() {
    if (!ensureSavedFacesLoaded()) return -1;

    int16_t firstDefaultIndex = -1;
    for (uint16_t i = 0; i < autoFaceCount; ++i) {
        if (autoFaces[i].isStartupDefault) return static_cast<int16_t>(i);
        if (autoFaces[i].isDefault && firstDefaultIndex < 0) {
            firstDefaultIndex = static_cast<int16_t>(i);
        }
    }
    return firstDefaultIndex >= 0 ? firstDefaultIndex : 0;
}

static bool applyStartupDefaultFaceAfterScrollStop(bool restoreAutoMode) {
    setMode(restoreAutoMode ? "auto" : "manual", false);
    state.paused = false;

    const int16_t defaultIndex = findStartupDefaultFaceIndex();
    if (defaultIndex < 0) {
        Serial.println("No saved default face available after text scroll stop; leaving blank frame");
        state.playback = DEFAULT_PLAYBACK;
        return false;
    }

    const char* playback = restoreAutoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    if (!applySavedFaceIndex(static_cast<uint16_t>(defaultIndex),
                             "firmware_text_scroll_stop_default_saved_face",
                             playback)) {
        return false;
    }
    state.lastAutoSwitchMs = millis();
    return true;
}

void cancelDeferredFaceRestore() {
    state.deferredFaceRestoreActive   = false;
    state.deferredFaceRestoreKind     = DEFERRED_RESTORE_NONE;
    state.deferredFaceRestoreAutoMode = false;
    state.deferredFaceRestoreDueMs    = 0;
    state.deferredFaceRestoreReason   = String();
}

static void scheduleDeferredFaceRestore(uint8_t kind, bool autoMode, const String& reason) {
    state.deferredFaceRestoreActive   = true;
    state.deferredFaceRestoreKind     = kind;
    state.deferredFaceRestoreAutoMode = autoMode;
    state.deferredFaceRestoreDueMs    = millis() + LED_STOP_CLEAR_BLANK_HOLD_MS;
    state.deferredFaceRestoreReason   = reason;
}

static void scheduleStartupDefaultFaceRestoreAfterBlank(bool autoMode) {
    scheduleDeferredFaceRestore(DEFERRED_RESTORE_STARTUP_DEFAULT,
                                autoMode,
                                "firmware_text_scroll_stop_default_saved_face");
}

void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason) {
    scheduleDeferredFaceRestore(DEFERRED_RESTORE_CURRENT_FACE, autoMode, reason);
}

void serviceDeferredFaceRestore() {
    if (!state.deferredFaceRestoreActive) return;

    const uint32_t now = millis();
    if (static_cast<int32_t>(now - state.deferredFaceRestoreDueMs) < 0) return;

    const uint8_t kind     = state.deferredFaceRestoreKind;
    const bool    autoMode = state.deferredFaceRestoreAutoMode;
    const String  reason   = state.deferredFaceRestoreReason;

    // Clear the pending marker before applying the face.  If the apply path
    // fails or schedules another render, this service routine will not repeat
    // the same deferred action indefinitely.
    cancelDeferredFaceRestore();

    if (state.firmwareScrollActive || state.firmwareScrollPaused) {
        return;
    }

    if (kind == DEFERRED_RESTORE_STARTUP_DEFAULT) {
        applyStartupDefaultFaceAfterScrollStop(autoMode);
    } else if (kind == DEFERRED_RESTORE_CURRENT_FACE) {
        const bool faceApplied = applyCurrentSavedFaceForMode(reason, autoMode);
        if (!faceApplied) {
            Serial.println("Deferred saved-face restore failed: no saved face available");
        }
    }
}

void stopFirmwareScroll(bool restoreAuto, bool clearDisplay) {
    cancelDeferredFaceRestore();

    bool shouldRestoreAuto = false;
    withScrollLock([&]() {
        shouldRestoreAuto               = restoreAuto && state.restoreAutoAfterScroll;
        state.firmwareScrollActive      = false;
        state.firmwareScrollPaused      = false;
        state.restoreAutoAfterScroll    = false;
        state.lastScrollFrameMs         = 0;
        state.scrollFrameCount          = 0;
        state.scrollFrameIndex          = 0;
        state.paused                    = false;
        if (isScrollPlayback(state.playback)) {
            state.playback = DEFAULT_PLAYBACK;
        }
    });

    if (clearDisplay) {
        // Two-stage visible sequence without blocking the caller:
        // 1) Push an all-off frame so the current scroll frame is cleared.
        // 2) Let loop() restore the default face after the blank frame has
        //    had enough time to latch through the BSS138 / WS2812 chain.
        applyBlankFrame("firmware_text_scroll_stop_clear");
        scheduleStartupDefaultFaceRestoreAfterBlank(shouldRestoreAuto);
    } else if (shouldRestoreAuto) {
        setMode("auto", false);
    }
}

void startFirmwareScroll(uint16_t intervalMs) {
    cancelDeferredFaceRestore();

    uint8_t firstFrame[FRAME_BYTES];
    bool    hasFirstFrame = false;

    withScrollLock([&]() {
        if (state.scrollFrameCount > 0) {
            state.restoreAutoAfterScroll = state.restoreAutoAfterScroll || isAutoMode();
            if (state.restoreAutoAfterScroll) state.mode = "manual";
            state.scrollIntervalMs   = constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            state.scrollFrameIndex   = 0;
            state.lastScrollFrameMs  = millis();
            state.firmwareScrollActive  = true;
            state.firmwareScrollPaused  = false;
            state.paused             = false;
            state.playback           = "scroll";
            memcpy(firstFrame, scrollFrameBits[0], FRAME_BYTES);
            hasFirstFrame = true;
        }
    });

    if (hasFirstFrame) applyPackedFrame(firstFrame, "firmware_text_scroll_start");
}

// ---------------------------------------------------------------------------
// Auto-playback  (called from loop())
// ---------------------------------------------------------------------------

void serviceAutoPlayback() {
    if (!isAutoMode() || state.paused || autoFaceCount == 0) return;

    const uint32_t now = millis();
    if (state.lastAutoSwitchMs == 0) {
        state.lastAutoSwitchMs = now;
        return;
    }
    if (now - state.lastAutoSwitchMs < state.autoIntervalMs) return;

    state.lastAutoSwitchMs  = now;
    state.autoFaceIndex     = (state.autoFaceIndex + 1) % autoFaceCount;
    state.playback          = "auto_saved_face";
    String error;
    if (!applyM370(autoFaces[state.autoFaceIndex].m370, "firmware_auto_saved_face", error)) {
        Serial.printf("auto face apply failed: %s\n", error.c_str());
    }
}
