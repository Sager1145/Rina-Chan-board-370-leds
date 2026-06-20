/*
 * File Description: faces.cpp
 * Implements saved expression face lists, timeline controls, and autoplay mode.
 *
 * Responsibilities:
 * - Coordinates expression playback queues (auto-advance intervals, manual triggers, timeline steps).
 * - Tracks startup defaults and currently selected expressions.
 * - Restores expressions automatically from settings when recovering from page reload.
 *
 * Core Interactions:
 * - Saves and loads expression details from SPIFFS/LittleFS storage files via storage.h.
 * - Renders updated pixel frames on the hardware LED bus using led_renderer.h.
 */
#include "faces.h"
#include "state.h"
#include "config.h"
#include "led_renderer.h"
#include "storage.h"   // Describes the responsibilities and maintenance constraints of the current code block in saved faces and playback mode.
#include "utils.h"
#include "sync.h"
#include "scroll_session.h"
#include "serial_log.h"

static constexpr uint8_t DEFERRED_RESTORE_NONE            = 0;
static constexpr uint8_t DEFERRED_RESTORE_STARTUP_DEFAULT = 1;
static constexpr uint8_t DEFERRED_RESTORE_CURRENT_FACE    = 2;

bool isAutoMode() {
    return strcmp(runtimeState().mode, "auto") == 0;
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

bool firmwareIsDisplayingTextScroll() {
    bool displaying = false;
    withScrollLock([&]() {
        displaying = runtimeState().firmwareScrollActive ||
                     runtimeState().firmwareScrollPaused;
    });
    return displaying;
}

bool stopFirmwareScrollForNonScrollOutput(const String& reason) {
    if (!firmwareIsDisplayingTextScroll()) return false;
    (void)reason;
    stopFirmwareScroll(false, true);
    scrollSessionSetRestoreAuto(false);
    return true;
}

bool setMode(const char* input, bool persistSettings) {
    const String mode = normalizedMode(input);
    if (mode != "auto" && mode != "manual") return false;

    const String oldMode = runtimeState().mode;
    const bool settingsChanged = mode != runtimeState().mode;
    bool changed = false;

    // Any entry into a non-scroll mode while text scroll is displayed is equivalent
    // to pressing Stop/Clear first. This covers WebUI, GPIO, Serial, and internal
    // callers that route through setMode().
    stopFirmwareScrollForNonScrollOutput("mode_change_non_scroll");

    if (mode == "auto") {
        if (strcmp(runtimeState().mode, "auto") != 0) {
            assignText(runtimeState().mode, "auto");
            changed = true;
        }
        if (strcmp(runtimeState().playback, "auto_saved_face") != 0) {
            assignText(runtimeState().playback, "auto_saved_face");
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
        if (strcmp(runtimeState().mode, "manual") != 0) {
            assignText(runtimeState().mode, "manual");
            changed = true;
        }
        if (persistSettings && scrollSessionGetRestoreAuto()) {
            scrollSessionSetRestoreAuto(false);
            changed = true;
        }
        if (strcmp(runtimeState().playback, "auto_saved_face") == 0) {
            assignText(runtimeState().playback, DEFAULT_PLAYBACK);
            changed = true;
        }
    } else {
        return false;
    }
    if (changed) touchRuntimeState();
    if (persistSettings && settingsChanged) saveRuntimeSettings();
    if (settingsChanged) {
        RLOG_INFO("MODE", "event=change from=%s to=%s persist=%d",
                  oldMode.c_str(), mode.c_str(), persistSettings ? 1 : 0);
    }
    return true;
}

void setAutoInterval(uint32_t ms, bool persistSettings) {
    const uint32_t nextInterval = constrain(ms, MIN_AUTO_INTERVAL_MS, MAX_AUTO_INTERVAL_MS);
    if (runtimeState().autoIntervalMs == nextInterval) return;
    runtimeState().autoIntervalMs = nextInterval;
    touchRuntimeState();
    if (persistSettings) saveRuntimeSettings();
    RLOG_INFO("AUTO", "event=interval_change interval_ms=%lu persist=%d",
              static_cast<unsigned long>(nextInterval), persistSettings ? 1 : 0);
}

bool playbackIsNonFaceActivity() {
    if (runtimeState().firmwareScrollActive || runtimeState().firmwareScrollPaused) return true;
    if (isScrollPlayback(runtimeState().playback)) return true;
    const char* lastReason = runtimeState().lastReason;
    if (strncmp(lastReason, "text_scroll_", 12) == 0 ||
        strncmp(lastReason, "custom_", 7) == 0 ||
        strncmp(lastReason, "parts_", 6) == 0 ||
        strncmp(lastReason, "debug_", 6) == 0) return true;
    if (strcmp(runtimeState().playback, DEFAULT_PLAYBACK) == 0 ||
        strcmp(runtimeState().playback, "auto_saved_face") == 0) return false;
    return true;
}

bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback,
                         bool immediate) {
    if (!ensureSavedFacesLoaded()) {
        Serial.println("No saved faces available for button action");
        return false;
    }

    // Saved-face display is a non-scroll mode. If text scrolling is currently on
    // the LEDs, leave it by the same Stop/Clear path before applying the face.
    stopFirmwareScrollForNonScrollOutput("saved_face_apply_non_scroll");

    runtimeState().autoFaceIndex = index % runtimeAutoFaceCount();
    if (playback) assignText(runtimeState().playback, playback);

    String error;
    if (immediate) clearQueuedM370Frames();
    const bool applied = immediate
        ? applyM370Immediate(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, reason, error)
        : applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, reason, error);
    if (!applied) {
        Serial.printf("saved face apply failed: %s\n", error.c_str());
        return false;
    }
    LOGV("Applied saved face %u/%u via %s: %s\n",
         runtimeState().autoFaceIndex + 1, runtimeAutoFaceCount(),
         reason.c_str(), runtimeAutoFaces()[runtimeState().autoFaceIndex].id);
    RLOG_INFO("FACE", "event=apply idx=%u/%u id=%s reason=%s",
              static_cast<unsigned>(runtimeState().autoFaceIndex + 1),
              static_cast<unsigned>(runtimeAutoFaceCount()),
              runtimeAutoFaces()[runtimeState().autoFaceIndex].id,
              reason.c_str());
    return true;
}

bool applyRelativeSavedFace(int8_t delta, const String& reason, bool immediate) {
    if (!ensureSavedFacesLoaded()) return false;
    int32_t next = static_cast<int32_t>(runtimeState().autoFaceIndex) + delta;
    while (next < 0) next += runtimeAutoFaceCount();
    next %= runtimeAutoFaceCount();
    return applySavedFaceIndex(static_cast<uint16_t>(next), reason, DEFAULT_PLAYBACK, immediate);
}

bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode, bool immediate) {
    if (!ensureSavedFacesLoaded()) return false;
    const char*    playback = autoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    const uint16_t index    = runtimeAutoFaceCount() > 0 ? runtimeState().autoFaceIndex % runtimeAutoFaceCount() : 0;
    const bool     applied  = applySavedFaceIndex(index, reason, playback, immediate);
    if (applied && autoMode) runtimeState().lastAutoSwitchMs = millis();
    return applied;
}

bool toggleModeFromButtonAction(const String& source) {
    const bool targetAuto       = !isAutoMode();
    const bool hadOtherPlayback = playbackIsNonFaceActivity();
    const bool immediateFace    = source == "gpio" || source == "api_button";

    stopFirmwareScrollForNonScrollOutput("button_mode_toggle_non_scroll");

    if (!setMode(targetAuto ? "auto" : "manual", true)) return false;

    const String restoreReason = source +
        (targetAuto ? "_B3_auto_current_saved_face" : "_B3_manual_current_saved_face");

    if (hadOtherPlayback) {
        applyBlankFrame(source + "_B3_clear_before_saved_face");
        scheduleCurrentSavedFaceRestoreAfterBlank(targetAuto, restoreReason);
        return true;
    }

    const bool faceApplied = applyCurrentSavedFaceForMode(restoreReason, targetAuto, immediateFace);
    if (!faceApplied) {
        Serial.println("B3/M-A switched mode but no saved face was available to apply");
    }
    return true;
}

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

static bool applyStartupDefaultFaceAfterScrollStop(bool restoreAutoMode) {
    setMode(restoreAutoMode ? "auto" : "manual", false);
    runtimeState().paused = false;

    const int16_t defaultIndex = findStartupDefaultFaceIndex();
    if (defaultIndex < 0) {
        Serial.println("No saved default face available after text scroll stop; leaving blank frame");
        assignText(runtimeState().playback, DEFAULT_PLAYBACK);
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

void cancelDeferredFaceRestore() {
    const bool changed = runtimeState().deferredFaceRestoreActive ||
                         runtimeState().deferredFaceRestoreKind != DEFERRED_RESTORE_NONE ||
                         runtimeState().deferredFaceRestoreDueMs != 0;
    runtimeState().deferredFaceRestoreActive   = false;
    runtimeState().deferredFaceRestoreKind     = DEFERRED_RESTORE_NONE;
    runtimeState().deferredFaceRestoreAutoMode = false;
    runtimeState().deferredFaceRestoreDueMs    = 0;
    runtimeState().deferredFaceRestoreReason[0] = '\0';
    if (changed) touchRuntimeState();
}

static void scheduleDeferredFaceRestore(uint8_t kind, bool autoMode, const String& reason) {
    runtimeState().deferredFaceRestoreActive   = true;
    runtimeState().deferredFaceRestoreKind     = kind;
    runtimeState().deferredFaceRestoreAutoMode = autoMode;
    runtimeState().deferredFaceRestoreDueMs    = millis() + LED_STOP_CLEAR_BLANK_HOLD_MS;
    assignText(runtimeState().deferredFaceRestoreReason, reason.c_str());
    touchRuntimeState();
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
    if (!runtimeState().deferredFaceRestoreActive) return;

    const uint32_t now = millis();
    if (!millisReached(now, runtimeState().deferredFaceRestoreDueMs)) return;

    const uint8_t kind     = runtimeState().deferredFaceRestoreKind;
    const bool    autoMode = runtimeState().deferredFaceRestoreAutoMode;
    const String  reason   = runtimeState().deferredFaceRestoreReason;

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

void stopFirmwareScroll(bool restoreAuto, bool clearDisplay) {
    cancelDeferredFaceRestore();
    const ScrollStopResult r = scrollSessionStop(restoreAuto, clearDisplay);
    if (r.cleared) {
        if (r.shouldRestoreDefault) scheduleStartupDefaultFaceRestoreAfterBlank(r.restoreAuto);
    } else if (r.restoreAuto) {
        setMode("auto", false);
    }
}

void startFirmwareScroll(uint16_t intervalMs) {
    cancelDeferredFaceRestore();
    const ScrollStartResult r = scrollSessionStart(intervalMs, isAutoMode());
    if (r.engagedRestoreAuto) assignText(runtimeState().mode, "manual");
}

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
    assignText(runtimeState().playback, "auto_saved_face");
    RLOG_INFO("FACE", "event=auto_change idx=%u/%u reason=firmware_auto_saved_face",
              static_cast<unsigned>(runtimeState().autoFaceIndex + 1),
              static_cast<unsigned>(runtimeAutoFaceCount()));
    String error;
    if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, "firmware_auto_saved_face", error)) {
        Serial.printf("auto face apply failed: %s\n", error.c_str());
        RLOG_ERROR("FACE", "event=auto_change_failed err=%s", error.c_str());
    }
}
