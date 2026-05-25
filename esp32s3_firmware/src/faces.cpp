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

/**
 * @brief Check whether runtime playback is in auto mode.
 * @param None.
 * @return true when runtimeState().mode is "auto".
 */
bool isAutoMode() {
    return runtimeState().mode == "auto";
}

/**
 * @brief Normalize UI/API/button mode aliases into firmware mode strings.
 * @param input Mode text from JSON, saved settings, or button UI glyphs.
 * @return "auto", "manual", or the trimmed lowercase fallback.
 */
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

/**
 * @brief Apply manual/auto mode and optionally persist settings.
 * @param input Requested mode text.
 * @param persistSettings true to write runtime_settings.json when mode changes.
 * @return true when input was a supported mode.
 */
bool setMode(const char* input, bool persistSettings) {
    const String mode = normalizedMode(input);
    const bool settingsChanged = runtimeState().mode != mode;
    bool changed = false;

    if (mode == "auto") {
        // Auto mode owns playback and clears pause state so the auto timer can
        // resume changing saved faces without stale manual pause flags.
        if (runtimeState().mode != "auto") {
            runtimeState().mode = "auto";
            changed = true;
        }
        if (runtimeState().playback != "auto_saved_face") {
            runtimeState().playback = "auto_saved_face";
            changed = true;
        }
        if (runtimeState().paused) {
            runtimeState().paused = false;
            changed = true;
        }
        const uint32_t now = millis();
        if (runtimeState().lastAutoSwitchMs != now) {
            runtimeState().lastAutoSwitchMs = now;
            changed = true;
        }
    } else if (mode == "manual") {
        // Manual mode keeps the current frame visible unless it is specifically
        // leaving auto playback, in which case playback returns to idle.
        if (runtimeState().mode != "manual") {
            runtimeState().mode = "manual";
            changed = true;
        }
        if (persistSettings && runtimeState().restoreAutoAfterScroll) {
            runtimeState().restoreAutoAfterScroll = false;
            changed = true;
        }
        if (runtimeState().playback == "auto_saved_face") {
            runtimeState().playback = DEFAULT_PLAYBACK;
            changed = true;
        }
    } else {
        return false;
    }
    if (changed) touchRuntimeState();
    if (persistSettings && settingsChanged) saveRuntimeSettings();
    return true;
}

/**
 * @brief Clamp and apply the auto-playback interval.
 * @param ms Requested interval in milliseconds.
 * @param persistSettings true to write runtime_settings.json.
 * @return None.
 */
void setAutoInterval(uint32_t ms, bool persistSettings) {
    const uint32_t nextInterval = constrain(ms, MIN_AUTO_INTERVAL_MS, MAX_AUTO_INTERVAL_MS);
    if (runtimeState().autoIntervalMs == nextInterval) return;
    runtimeState().autoIntervalMs = nextInterval;
    touchRuntimeState();
    if (persistSettings) saveRuntimeSettings();
}

// ---------------------------------------------------------------------------
// Playback state query
// ---------------------------------------------------------------------------

/**
 * @brief Check whether a playback label belongs to firmware scroll.
 * @param playback Runtime playback string.
 * @return true for scroll, scroll_paused, or scroll_step.
 */
bool isScrollPlayback(const String& playback) {
    return playback == "scroll" ||
           playback == "scroll_paused" ||
           playback == "scroll_step";
}

/**
 * @brief Decide whether current playback should be interrupted before face changes.
 * @param None.
 * @return true when current state is not a normal saved-face display.
 */
bool playbackIsNonFaceActivity() {
    if (runtimeState().firmwareScrollActive || runtimeState().firmwareScrollPaused) return true;
    if (isScrollPlayback(runtimeState().playback)) return true;
    if (runtimeState().lastReason.startsWith("text_scroll_") ||
        runtimeState().lastReason.startsWith("custom_") ||
        runtimeState().lastReason.startsWith("parts_") ||
        runtimeState().lastReason.startsWith("debug_")) return true;
    if (runtimeState().playback == DEFAULT_PLAYBACK || runtimeState().playback == "auto_saved_face") return false;
    return true;
}

// ---------------------------------------------------------------------------
// Face apply helpers
// ---------------------------------------------------------------------------

/**
 * @brief Apply a saved face by runtime index.
 * @param index Requested saved-face index; wrapped by face count.
 * @param reason Diagnostic reason passed to renderer.
 * @param playback Playback label to store, or nullptr to leave unchanged.
 * @return true when a face existed and its M370 was accepted.
 */
bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback) {
    if (!ensureSavedFacesLoaded()) {
        Serial.println("No saved faces available for button action");
        return false;
    }

    runtimeState().autoFaceIndex = index % runtimeAutoFaceCount();
    if (playback) runtimeState().playback = playback;

    String error;
    if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, reason, error)) {
        Serial.printf("saved face apply failed: %s\n", error.c_str());
        return false;
    }
    Serial.printf("Applied saved face %u/%u via %s: %s\n",
                  runtimeState().autoFaceIndex + 1, runtimeAutoFaceCount(),
                  reason.c_str(), runtimeAutoFaces()[runtimeState().autoFaceIndex].id.c_str());
    return true;
}

/**
 * @brief Navigate saved faces relative to the current index.
 * @param delta Signed index offset, wrapped around the face table.
 * @param reason Diagnostic reason passed to renderer.
 * @return true when a target face was applied.
 */
bool applyRelativeSavedFace(int8_t delta, const String& reason) {
    if (!ensureSavedFacesLoaded()) return false;
    int32_t next = static_cast<int32_t>(runtimeState().autoFaceIndex) + delta;
    while (next < 0) next += runtimeAutoFaceCount();
    next %= runtimeAutoFaceCount();
    return applySavedFaceIndex(static_cast<uint16_t>(next), reason, DEFAULT_PLAYBACK);
}

/**
 * @brief Re-apply the current saved face under manual or auto playback semantics.
 * @param reason Diagnostic reason passed to renderer.
 * @param autoMode true to mark playback as auto_saved_face.
 * @return true when a face was applied.
 */
bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode) {
    if (!ensureSavedFacesLoaded()) return false;
    const char*    playback = autoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    const uint16_t index    = runtimeAutoFaceCount() > 0 ? runtimeState().autoFaceIndex % runtimeAutoFaceCount() : 0;
    const bool     applied  = applySavedFaceIndex(index, reason, playback);
    if (applied && autoMode) runtimeState().lastAutoSwitchMs = millis();
    return applied;
}

/**
 * @brief Toggle manual/auto mode from the physical or API B3 action.
 * @param source Source prefix used in runtime reason strings.
 * @return true when the mode switch was accepted.
 */
bool toggleModeFromButtonAction(const String& source) {
    const bool targetAuto       = !isAutoMode();
    const bool hadOtherPlayback = playbackIsNonFaceActivity();

    // B3 also serves as an emergency exit from text scroll / overlays.  Stop
    // scroll before switching modes so the restored saved face is not later
    // overwritten by a stale scroll frame.
    stopFirmwareScroll(false, false);
    runtimeState().restoreAutoAfterScroll = false;

    if (!setMode(targetAuto ? "auto" : "manual", true)) return false;

    const String restoreReason = source +
        (targetAuto ? "_B3_auto_current_saved_face" : "_B3_manual_current_saved_face");

    if (hadOtherPlayback) {
        // When leaving text/custom playback, push a blank first and restore the
        // saved face asynchronously so the all-off frame can physically latch.
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

/**
 * @brief Locate startup default face with fallback to first default.
 * @param None.
 * @return Runtime face index, or -1 when no face exists.
 */
static int16_t findStartupDefaultFaceIndex() {
    if (!ensureSavedFacesLoaded()) return -1;

    int16_t firstDefaultIndex = -1;
    for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
        if (runtimeAutoFaces()[i].isStartupDefault) return static_cast<int16_t>(i);
        if (runtimeAutoFaces()[i].isDefault && firstDefaultIndex < 0) {
            firstDefaultIndex = static_cast<int16_t>(i);
        }
    }
    return firstDefaultIndex >= 0 ? firstDefaultIndex : 0;
}

/**
 * @brief Restore the startup/default face after scroll stop blanking.
 * @param restoreAutoMode true to restore auto playback label/mode.
 * @return true when a default face was applied.
 */
static bool applyStartupDefaultFaceAfterScrollStop(bool restoreAutoMode) {
    setMode(restoreAutoMode ? "auto" : "manual", false);
    runtimeState().paused = false;

    const int16_t defaultIndex = findStartupDefaultFaceIndex();
    if (defaultIndex < 0) {
        Serial.println("No saved default face available after text scroll stop; leaving blank frame");
        runtimeState().playback = DEFAULT_PLAYBACK;
        return false;
    }

    const char* playback = restoreAutoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    if (!applySavedFaceIndex(static_cast<uint16_t>(defaultIndex),
                             "firmware_text_scroll_stop_default_saved_face",
                             playback)) {
        return false;
    }
    runtimeState().lastAutoSwitchMs = millis();
    return true;
}

/**
 * @brief Cancel any pending deferred saved-face restore.
 * @param None.
 * @return None.
 */
void cancelDeferredFaceRestore() {
    const bool changed = runtimeState().deferredFaceRestoreActive ||
                         runtimeState().deferredFaceRestoreKind != DEFERRED_RESTORE_NONE ||
                         runtimeState().deferredFaceRestoreDueMs != 0;
    runtimeState().deferredFaceRestoreActive   = false;
    runtimeState().deferredFaceRestoreKind     = DEFERRED_RESTORE_NONE;
    runtimeState().deferredFaceRestoreAutoMode = false;
    runtimeState().deferredFaceRestoreDueMs    = 0;
    runtimeState().deferredFaceRestoreReason   = String();
    if (changed) touchRuntimeState();
}

/**
 * @brief Schedule a saved-face restore after the blank-frame hold time.
 * @param kind Deferred restore type.
 * @param autoMode Whether restore should resume auto playback.
 * @param reason Diagnostic reason for the eventual face apply.
 * @return None.
 */
static void scheduleDeferredFaceRestore(uint8_t kind, bool autoMode, const String& reason) {
    runtimeState().deferredFaceRestoreActive   = true;
    runtimeState().deferredFaceRestoreKind     = kind;
    runtimeState().deferredFaceRestoreAutoMode = autoMode;
    runtimeState().deferredFaceRestoreDueMs    = millis() + LED_STOP_CLEAR_BLANK_HOLD_MS;
    runtimeState().deferredFaceRestoreReason   = reason;
    touchRuntimeState();
}

/**
 * @brief Schedule startup/default face restore after an all-off clear frame.
 * @param autoMode Whether restore should resume auto playback.
 * @return None.
 */
static void scheduleStartupDefaultFaceRestoreAfterBlank(bool autoMode) {
    scheduleDeferredFaceRestore(DEFERRED_RESTORE_STARTUP_DEFAULT,
                                autoMode,
                                "firmware_text_scroll_stop_default_saved_face");
}

/**
 * @brief Schedule current saved-face restore after an all-off clear frame.
 * @param autoMode Whether restore should use auto playback semantics.
 * @param reason Diagnostic reason for the eventual face apply.
 * @return None.
 */
void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason) {
    scheduleDeferredFaceRestore(DEFERRED_RESTORE_CURRENT_FACE, autoMode, reason);
}

/**
 * @brief Run pending deferred face restore when its blank-frame delay expires.
 * @param None.
 * @return None.
 */
void serviceDeferredFaceRestore() {
    if (!runtimeState().deferredFaceRestoreActive) return;

    const uint32_t now = millis();
    if (static_cast<int32_t>(now - runtimeState().deferredFaceRestoreDueMs) < 0) return;

    const uint8_t kind     = runtimeState().deferredFaceRestoreKind;
    const bool    autoMode = runtimeState().deferredFaceRestoreAutoMode;
    const String  reason   = runtimeState().deferredFaceRestoreReason;

    // Clear the pending marker before applying the face.  If the apply path
    // fails or schedules another render, this service routine will not repeat
    // the same deferred action indefinitely.
    cancelDeferredFaceRestore();

    if (runtimeState().firmwareScrollActive || runtimeState().firmwareScrollPaused) {
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

/**
 * @brief Recompute effective firmware-scroll pause state while scroll lock is held.
 * @param None.
 * @return None.
 */
static void applyFirmwareScrollPauseIntentLocked() {
    const bool effectivePaused =
        runtimeState().firmwareScrollUserPaused ||
        runtimeState().firmwareScrollSystemPaused;

    if (runtimeState().scrollFrameCount == 0 && !runtimeState().firmwareScrollActive &&
        !runtimeState().firmwareScrollPaused) {
        runtimeState().firmwareScrollUserPaused = false;
        runtimeState().firmwareScrollSystemPaused = false;
        runtimeState().firmwareScrollPaused = false;
        return;
    }

    runtimeState().firmwareScrollActive = true;
    runtimeState().firmwareScrollPaused = effectivePaused;
    runtimeState().paused = effectivePaused;
    if (effectivePaused) {
        runtimeState().playback = "scroll_paused";
    } else {
        runtimeState().lastScrollFrameMs = millis();
        runtimeState().playback = "scroll";
    }
}

/**
 * @brief Set user or system scroll-pause flag and update effective playback state.
 * @param userFlag true to write the user pause flag, false for system pause.
 * @param paused Requested flag value.
 * @return true when visible pause/playback state changed.
 */
static bool setFirmwareScrollPauseFlag(bool userFlag, bool paused) {
    bool changed = false;
    withScrollLock([&]() {
        const bool oldUser = runtimeState().firmwareScrollUserPaused;
        const bool oldSystem = runtimeState().firmwareScrollSystemPaused;
        const bool oldEffective = runtimeState().firmwareScrollPaused;
        const String oldPlayback = runtimeState().playback;
        const bool oldPaused = runtimeState().paused;

        if (userFlag) runtimeState().firmwareScrollUserPaused = paused;
        else          runtimeState().firmwareScrollSystemPaused = paused;

        applyFirmwareScrollPauseIntentLocked();

        changed = oldUser != runtimeState().firmwareScrollUserPaused ||
                  oldSystem != runtimeState().firmwareScrollSystemPaused ||
                  oldEffective != runtimeState().firmwareScrollPaused ||
                  oldPlayback != runtimeState().playback ||
                  oldPaused != runtimeState().paused;
    });
    if (changed) touchRuntimeState();
    return changed;
}

/**
 * @brief Set the WebUI/API controlled scroll pause flag.
 * @param paused Requested user pause state.
 * @return true when effective state changed.
 */
bool setFirmwareScrollUserPaused(bool paused) {
    return setFirmwareScrollPauseFlag(true, paused);
}

/**
 * @brief Set the firmware-overlay controlled scroll pause flag.
 * @param paused Requested system pause state.
 * @return true when effective state changed.
 */
bool setFirmwareScrollSystemPaused(bool paused) {
    return setFirmwareScrollPauseFlag(false, paused);
}

/**
 * @brief Stop firmware scroll and optionally clear/restore visible content.
 * @param restoreAuto true to restore auto mode when scroll was entered from auto.
 * @param clearDisplay true to push a blank frame before restoring default face.
 * @return None.
 */
void stopFirmwareScroll(bool restoreAuto, bool clearDisplay) {
    cancelDeferredFaceRestore();

    bool shouldRestoreAuto = false;
    bool changed = false;
    withScrollLock([&]() {
        changed = runtimeState().firmwareScrollActive ||
                  runtimeState().firmwareScrollPaused ||
                  runtimeState().restoreAutoAfterScroll ||
                  runtimeState().lastScrollFrameMs != 0 ||
                  runtimeState().scrollFrameCount != 0 ||
                  runtimeState().scrollFrameIndex != 0 ||
                  runtimeState().paused ||
                  isScrollPlayback(runtimeState().playback);
        shouldRestoreAuto               = restoreAuto && runtimeState().restoreAutoAfterScroll;
        runtimeState().firmwareScrollActive      = false;
        runtimeState().firmwareScrollPaused      = false;
        runtimeState().firmwareScrollUserPaused  = false;
        runtimeState().firmwareScrollSystemPaused = false;
        runtimeState().restoreAutoAfterScroll    = false;
        runtimeState().lastScrollFrameMs         = 0;
        runtimeState().scrollFrameCount          = 0;
        runtimeState().scrollFrameIndex          = 0;
        runtimeState().paused                    = false;
        if (isScrollPlayback(runtimeState().playback)) {
            runtimeState().playback = DEFAULT_PLAYBACK;
        }
    });
    if (changed) touchRuntimeState();
    if (changed || clearDisplay) clearQueuedM370Frames();

    if (clearDisplay) {
        // Two-stage visible sequence without blocking the caller:
        // 1) Push an all-off frame so the current scroll frame is cleared.
        // 2) Let loop() restore the default face after the blank frame has
        //    had enough time to latch through the BSS138 / WS2812 chain.
        applyBlankFrame("firmware_text_scroll_stop_clear");
        scheduleStartupDefaultFaceRestoreAfterBlank(shouldRestoreAuto);
    } else if (shouldRestoreAuto) {
        // If no blank/display restore is required, restoring auto mode is just a
        // runtime state transition; the current saved face remains visible.
        setMode("auto", false);
    }
}

/**
 * @brief Start firmware text scroll from the cached RAM timeline.
 * @param intervalMs Requested frame interval in milliseconds.
 * @return None.
 */
void startFirmwareScroll(uint16_t intervalMs) {
    cancelDeferredFaceRestore();
    clearQueuedM370Frames();

    uint8_t firstFrame[FRAME_BYTES];
    bool    hasFirstFrame = false;

    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            // Starting scroll from auto mode temporarily moves mode to manual so
            // auto playback cannot advance faces while the scroll task owns the
            // visible frame stream.  restoreAutoAfterScroll records the handoff.
            runtimeState().restoreAutoAfterScroll = runtimeState().restoreAutoAfterScroll || isAutoMode();
            if (runtimeState().restoreAutoAfterScroll) runtimeState().mode = "manual";
            runtimeState().scrollIntervalMs   = constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            runtimeState().scrollFrameIndex   = 0;
            runtimeState().lastScrollFrameMs  = millis();
            runtimeState().firmwareScrollActive  = true;
            runtimeState().firmwareScrollPaused  = false;
            runtimeState().firmwareScrollUserPaused = false;
            runtimeState().firmwareScrollSystemPaused = false;
            runtimeState().paused             = false;
            runtimeState().playback           = "scroll";
            memcpy(firstFrame, runtimeScrollFrameBits(0), FRAME_BYTES);
            hasFirstFrame = true;
        }
    });

    if (hasFirstFrame) applyPackedFrameImmediate(firstFrame, "firmware_text_scroll_start");
}

// ---------------------------------------------------------------------------
// Auto-playback  (called from loop())
// ---------------------------------------------------------------------------

/**
 * @brief Advance auto saved-face playback when its interval elapses.
 * @param None.
 * @return None.
 */
void serviceAutoPlayback() {
    if (!isAutoMode() || runtimeState().paused || runtimeAutoFaceCount() == 0) return;

    const uint32_t now = millis();
    if (runtimeState().lastAutoSwitchMs == 0) {
        runtimeState().lastAutoSwitchMs = now;
        return;
    }
    if (now - runtimeState().lastAutoSwitchMs < runtimeState().autoIntervalMs) return;

    runtimeState().lastAutoSwitchMs  = now;
    runtimeState().autoFaceIndex     = (runtimeState().autoFaceIndex + 1) % runtimeAutoFaceCount();
    runtimeState().playback          = "auto_saved_face";
    String error;
    if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, "firmware_auto_saved_face", error)) {
        Serial.printf("auto face apply failed: %s\n", error.c_str());
    }
}
