#include "faces.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include "storage.h"   // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
#include "utils.h"


// 本文件管理保存表情、手动/自动模式和默认表情恢复；注释保留必要 English identifier，便于和代码/API 对照。
static constexpr uint8_t DEFERRED_RESTORE_NONE            = 0;
static constexpr uint8_t DEFERRED_RESTORE_STARTUP_DEFAULT = 1;
static constexpr uint8_t DEFERRED_RESTORE_CURRENT_FACE    = 2;

// ---------------------------------------------------------------------------
// 模式辅助函数（Mode helpers） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

bool isAutoMode() {
    return runtimeState().mode == "auto";
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
    const bool settingsChanged = runtimeState().mode != mode;
    bool changed = false;

    if (mode == "auto") {
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

void setAutoInterval(uint32_t ms, bool persistSettings) {
    const uint32_t nextInterval = constrain(ms, MIN_AUTO_INTERVAL_MS, MAX_AUTO_INTERVAL_MS);
    if (runtimeState().autoIntervalMs == nextInterval) return;
    runtimeState().autoIntervalMs = nextInterval;
    touchRuntimeState();
    if (persistSettings) saveRuntimeSettings();
}

// ---------------------------------------------------------------------------
// 播放状态查询（Playback state query） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

bool isScrollPlayback(const String& playback) {
    return playback == "scroll" ||
           playback == "scroll_paused" ||
           playback == "scroll_step";
}

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

static bool firmwareScrollHasRuntimeStateLocked() {
    return runtimeState().firmwareScrollActive ||
           runtimeState().firmwareScrollPaused ||
           runtimeState().restoreAutoAfterScroll ||
           runtimeState().lastScrollFrameMs != 0 ||
           runtimeState().scrollFrameCount != 0 ||
           runtimeState().scrollFrameIndex != 0 ||
           runtimeState().paused ||
           isScrollPlayback(runtimeState().playback);
}

static void resetFirmwareScrollStateLocked() {
    runtimeState().firmwareScrollActive       = false;
    runtimeState().firmwareScrollPaused       = false;
    runtimeState().firmwareScrollUserPaused   = false;
    runtimeState().firmwareScrollSystemPaused = false;
    runtimeState().restoreAutoAfterScroll     = false;
    runtimeState().lastScrollFrameMs          = 0;
    runtimeState().scrollFrameCount           = 0;
    runtimeState().scrollFrameIndex           = 0;
    runtimeState().paused                     = false;
    if (isScrollPlayback(runtimeState().playback)) {
        runtimeState().playback = DEFAULT_PLAYBACK;
    }
}

// ---------------------------------------------------------------------------
// 表情应用辅助函数（Face apply helpers） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

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

bool applyRelativeSavedFace(int8_t delta, const String& reason) {
    if (!ensureSavedFacesLoaded()) return false;
    int32_t next = static_cast<int32_t>(runtimeState().autoFaceIndex) + delta;
    while (next < 0) next += runtimeAutoFaceCount();
    next %= runtimeAutoFaceCount();
    return applySavedFaceIndex(static_cast<uint16_t>(next), reason, DEFAULT_PLAYBACK);
}

bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode) {
    if (!ensureSavedFacesLoaded()) return false;
    const char*    playback = autoMode ? "auto_saved_face" : DEFAULT_PLAYBACK;
    const uint16_t index    = runtimeAutoFaceCount() > 0 ? runtimeState().autoFaceIndex % runtimeAutoFaceCount() : 0;
    const bool     applied  = applySavedFaceIndex(index, reason, playback);
    if (applied && autoMode) runtimeState().lastAutoSwitchMs = millis();
    return applied;
}

bool toggleModeFromButtonAction(const String& source) {
    const bool targetAuto       = !isAutoMode();
    const bool hadOtherPlayback = playbackIsNonFaceActivity();

    stopFirmwareScroll(false, false);
    runtimeState().restoreAutoAfterScroll = false;

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
// 滚动停止 / 启动表情恢复（Scroll stop / startup face restore） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

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

static void scheduleDeferredFaceRestore(uint8_t kind, bool autoMode, const String& reason) {
    runtimeState().deferredFaceRestoreActive   = true;
    runtimeState().deferredFaceRestoreKind     = kind;
    runtimeState().deferredFaceRestoreAutoMode = autoMode;
    runtimeState().deferredFaceRestoreDueMs    = millis() + LED_STOP_CLEAR_BLANK_HOLD_MS;
    runtimeState().deferredFaceRestoreReason   = reason;
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

bool setFirmwareScrollUserPaused(bool paused) {
    return setFirmwareScrollPauseFlag(true, paused);
}

bool setFirmwareScrollSystemPaused(bool paused) {
    return setFirmwareScrollPauseFlag(false, paused);
}

void stopFirmwareScroll(bool restoreAuto, bool clearDisplay) {
    cancelDeferredFaceRestore();

    bool shouldRestoreAuto = false;
    bool changed = false;
    withScrollLock([&]() {
        changed = firmwareScrollHasRuntimeStateLocked();
        shouldRestoreAuto               = restoreAuto && runtimeState().restoreAutoAfterScroll;
        resetFirmwareScrollStateLocked();
    });
    if (changed) touchRuntimeState();
    if (changed || clearDisplay) clearQueuedM370Frames();

    if (clearDisplay) {
        applyBlankFrame("firmware_text_scroll_stop_clear");
        scheduleStartupDefaultFaceRestoreAfterBlank(shouldRestoreAuto);
    } else if (shouldRestoreAuto) {
        setMode("auto", false);
    }
}

void startFirmwareScroll(uint16_t intervalMs) {
    cancelDeferredFaceRestore();
    clearQueuedM370Frames();

    uint8_t firstFrame[FRAME_BYTES];
    bool    hasFirstFrame = false;

    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
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
// 自动播放（Auto-playback，从 loop() 调用） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

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
