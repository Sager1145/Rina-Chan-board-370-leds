#pragma once
#include <Arduino.h>


// 本文件管理保存表情、手动/自动模式和默认表情恢复；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 模式辅助函数（Mode helpers） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

bool isAutoMode();

String normalizedMode(const char* input);

bool setMode(const char* input, bool persistSettings = true);

void setAutoInterval(uint32_t ms, bool persistSettings = true);

// ---------------------------------------------------------------------------
// 表情应用辅助函数（Face apply helpers） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback);

bool applyRelativeSavedFace(int8_t delta, const String& reason);

bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode);

bool toggleModeFromButtonAction(const String& source);

// ---------------------------------------------------------------------------
// 滚动停止 / 启动表情恢复（Scroll stop / startup face restore） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

void cancelDeferredFaceRestore();

void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason);

void serviceDeferredFaceRestore();

// ---------------------------------------------------------------------------
// 滚动生命周期（Scroll lifecycle） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

void stopFirmwareScroll(bool restoreAuto, bool clearDisplay = false);

void startFirmwareScroll(uint16_t intervalMs);

bool setFirmwareScrollUserPaused(bool paused);

bool setFirmwareScrollSystemPaused(bool paused);

// ---------------------------------------------------------------------------
// 播放状态查询（Playback state query） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

bool isScrollPlayback(const String& playback);

bool playbackIsNonFaceActivity();

// ---------------------------------------------------------------------------
// 自动播放（Auto-playback，每次 loop() 迭代时调用） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

void serviceAutoPlayback();
