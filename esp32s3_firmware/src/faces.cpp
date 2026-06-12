#include "faces.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include "storage.h"   // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。


// 本文件管理保存表情、手动/自动模式和默认表情恢复；注释保留必要 English identifier，便于和代码/API 对照。
static constexpr uint8_t DEFERRED_RESTORE_NONE            = 0;
static constexpr uint8_t DEFERRED_RESTORE_STARTUP_DEFAULT = 1;
static constexpr uint8_t DEFERRED_RESTORE_CURRENT_FACE    = 2;

// ---------------------------------------------------------------------------
// 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
// 模式辅助函数（Mode helpers） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

/**
 * 围绕 isAutoMode 处理本模块的核心流程，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool isAutoMode() {
    return runtimeState().mode == "auto";
}

/**
 * 规范化 normalizedMode 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 设置 setMode 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param persistSettings 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool setMode(const char* input, bool persistSettings) {
    const String mode = normalizedMode(input);
    const bool settingsChanged = runtimeState().mode != mode;
    bool changed = false;

    if (mode == "auto") {
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
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
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
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
 * 设置 setAutoInterval 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param ms 调用方传入或接收的参数，含义以函数签名为准。
 * @param persistSettings 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void setAutoInterval(uint32_t ms, bool persistSettings) {
    const uint32_t nextInterval = constrain(ms, MIN_AUTO_INTERVAL_MS, MAX_AUTO_INTERVAL_MS);
    if (runtimeState().autoIntervalMs == nextInterval) return;
    runtimeState().autoIntervalMs = nextInterval;
    touchRuntimeState();
    if (persistSettings) saveRuntimeSettings();
}

// ---------------------------------------------------------------------------
// 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
// 播放状态查询（Playback state query） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

/**
 * 围绕 isScrollPlayback 处理本模块的核心流程，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param playback 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool isScrollPlayback(const String& playback) {
    return playback == "scroll" ||
           playback == "scroll_paused" ||
           playback == "scroll_step";
}

/**
 * 围绕 playbackIsNonFaceActivity 处理本模块的核心流程，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
// 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
// 表情应用辅助函数（Face apply helpers） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

/**
 * 应用、保存 applySavedFaceIndex 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @param playback 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 应用、保存 applyRelativeSavedFace 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param delta 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool applyRelativeSavedFace(int8_t delta, const String& reason) {
    if (!ensureSavedFacesLoaded()) return false;
    int32_t next = static_cast<int32_t>(runtimeState().autoFaceIndex) + delta;
    while (next < 0) next += runtimeAutoFaceCount();
    next %= runtimeAutoFaceCount();
    return applySavedFaceIndex(static_cast<uint16_t>(next), reason, DEFAULT_PLAYBACK);
}

/**
 * 应用、保存 applyCurrentSavedFaceForMode 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @param autoMode 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 切换 toggleModeFromButtonAction 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param source 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool toggleModeFromButtonAction(const String& source) {
    const bool targetAuto       = !isAutoMode();
    const bool hadOtherPlayback = playbackIsNonFaceActivity();

    // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
    // 说明文字滚动、帧缓存或播放状态处理。
    // 说明文字滚动、帧缓存或播放状态处理。
    stopFirmwareScroll(false, false);
    runtimeState().restoreAutoAfterScroll = false;

    if (!setMode(targetAuto ? "auto" : "manual", true)) return false;

    const String restoreReason = source +
        (targetAuto ? "_B3_auto_current_saved_face" : "_B3_manual_current_saved_face");

    if (hadOtherPlayback) {
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
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
// 说明文字滚动、帧缓存或播放状态处理。
// 滚动停止 / 启动表情恢复（Scroll stop / startup face restore） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

/**
 * 查找、启动 findStartupDefaultFaceIndex 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 应用、启动、停止 applyStartupDefaultFaceAfterScrollStop 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param restoreAutoMode 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 围绕 cancelDeferredFaceRestore 处理本模块的核心流程，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 围绕 scheduleDeferredFaceRestore 处理本模块的核心流程，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param kind 调用方传入或接收的参数，含义以函数签名为准。
 * @param autoMode 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 启动 scheduleStartupDefaultFaceRestoreAfterBlank 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param autoMode 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void scheduleStartupDefaultFaceRestoreAfterBlank(bool autoMode) {
    scheduleDeferredFaceRestore(DEFERRED_RESTORE_STARTUP_DEFAULT,
                                autoMode,
                                "firmware_text_scroll_stop_default_saved_face");
}

/**
 * 保存 scheduleCurrentSavedFaceRestoreAfterBlank 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param autoMode 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason) {
    scheduleDeferredFaceRestore(DEFERRED_RESTORE_CURRENT_FACE, autoMode, reason);
}

/**
 * 轮询服务 serviceDeferredFaceRestore 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceDeferredFaceRestore() {
    if (!runtimeState().deferredFaceRestoreActive) return;

    const uint32_t now = millis();
    if (static_cast<int32_t>(now - runtimeState().deferredFaceRestoreDueMs) < 0) return;

    const uint8_t kind     = runtimeState().deferredFaceRestoreKind;
    const bool    autoMode = runtimeState().deferredFaceRestoreAutoMode;
    const String  reason   = runtimeState().deferredFaceRestoreReason;

    // 说明字体、字形、Unicode 范围或 Web font 资源处理。
    // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
    // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
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
 * 应用 applyFirmwareScrollPauseIntentLocked 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 设置 setFirmwareScrollPauseFlag 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param userFlag 调用方传入或接收的参数，含义以函数签名为准。
 * @param paused 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 设置 setFirmwareScrollUserPaused 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param paused 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool setFirmwareScrollUserPaused(bool paused) {
    return setFirmwareScrollPauseFlag(true, paused);
}

/**
 * 设置 setFirmwareScrollSystemPaused 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param paused 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool setFirmwareScrollSystemPaused(bool paused) {
    return setFirmwareScrollPauseFlag(false, paused);
}

/**
 * 围绕 stopFirmwareScroll 处理停止、清理或恢复流程，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param restoreAuto 调用方传入或接收的参数，含义以函数签名为准。
 * @param clearDisplay 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
        // 说明文字滚动、帧缓存或播放状态处理。
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
        // 处理 LED 矩阵、灯带刷新或硬件时序约束。
        applyBlankFrame("firmware_text_scroll_stop_clear");
        scheduleStartupDefaultFaceRestoreAfterBlank(shouldRestoreAuto);
    } else if (shouldRestoreAuto) {
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
        // 说明 保存表情和播放模式 中当前代码块的职责和维护约束。
        setMode("auto", false);
    }
}

/**
 * 启动 startFirmwareScroll 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param intervalMs 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void startFirmwareScroll(uint16_t intervalMs) {
    cancelDeferredFaceRestore();
    clearQueuedM370Frames();

    uint8_t firstFrame[FRAME_BYTES];
    bool    hasFirstFrame = false;

    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            // 说明文字滚动、帧缓存或播放状态处理。
            // 说明文字滚动、帧缓存或播放状态处理。
            // 说明文字滚动、帧缓存或播放状态处理。
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
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// 自动播放（Auto-playback，从 loop() 调用） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

/**
 * 轮询服务 serviceAutoPlayback 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
