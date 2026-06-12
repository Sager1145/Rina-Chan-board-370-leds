#pragma once
#include <Arduino.h>


// 本文件管理保存表情、手动/自动模式和默认表情恢复；注释保留必要 English identifier，便于和代码/API 对照。
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
bool isAutoMode();

/**
 * 规范化 normalizedMode 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
String normalizedMode(const char* input);

/**
 * 设置 setMode 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param persistSettings 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool setMode(const char* input, bool persistSettings = true);

/**
 * 设置 setAutoInterval 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param ms 调用方传入或接收的参数，含义以函数签名为准。
 * @param persistSettings 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void setAutoInterval(uint32_t ms, bool persistSettings = true);

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
bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback);

/**
 * 应用、保存 applyRelativeSavedFace 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param delta 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool applyRelativeSavedFace(int8_t delta, const String& reason);

/**
 * 应用、保存 applyCurrentSavedFaceForMode 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @param autoMode 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode);

/**
 * 切换 toggleModeFromButtonAction 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param source 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool toggleModeFromButtonAction(const String& source);

// ---------------------------------------------------------------------------
// 说明文字滚动、帧缓存或播放状态处理。
// 滚动停止 / 启动表情恢复（Scroll stop / startup face restore） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

/**
 * 围绕 cancelDeferredFaceRestore 处理本模块的核心流程，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void cancelDeferredFaceRestore();

/**
 * 保存 scheduleCurrentSavedFaceRestoreAfterBlank 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param autoMode 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason);

/**
 * 轮询服务 serviceDeferredFaceRestore 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceDeferredFaceRestore();

// ---------------------------------------------------------------------------
// 说明文字滚动、帧缓存或播放状态处理。
// 滚动生命周期（Scroll lifecycle） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

/**
 * 围绕 stopFirmwareScroll 处理停止、清理或恢复流程，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param restoreAuto 调用方传入或接收的参数，含义以函数签名为准。
 * @param clearDisplay 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void stopFirmwareScroll(bool restoreAuto, bool clearDisplay = false);

/**
 * 启动 startFirmwareScroll 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param intervalMs 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void startFirmwareScroll(uint16_t intervalMs);

/**
 * 设置 setFirmwareScrollUserPaused 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param paused 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool setFirmwareScrollUserPaused(bool paused);

/**
 * 设置 setFirmwareScrollSystemPaused 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param paused 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool setFirmwareScrollSystemPaused(bool paused);

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
bool isScrollPlayback(const String& playback);

/**
 * 围绕 playbackIsNonFaceActivity 处理本模块的核心流程，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool playbackIsNonFaceActivity();

// ---------------------------------------------------------------------------
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// 自动播放（Auto-playback，每次 loop() 迭代时调用） 相关代码，维护 管理保存表情、手动/自动模式和默认表情恢复。
// ---------------------------------------------------------------------------

/**
 * 轮询服务 serviceAutoPlayback 相关逻辑，供 faces 模块使用。
 * @brief 说明 保存表情和播放模式 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceAutoPlayback();
