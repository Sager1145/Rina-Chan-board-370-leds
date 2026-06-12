#pragma once
#include <Arduino.h>
#include "config.h"


// 本文件解析 M370 帧并把逻辑 LED 状态渲染到物理灯带；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 处理 M370 帧、队列、校验或状态同步。
// M370 帧编解码器（M370 frame codec） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 规范化 normalizeM370 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param normalized 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool normalizeM370(const String& input, String& normalized, String& error);

/**
 * 围绕 m370ToPackedBits 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param outBits 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error);

/**
 * 围绕 blankM370 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
String blankM370();

// ---------------------------------------------------------------------------
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
// 帧位辅助函数（Frame bit helpers，通过 state.h 操作 frameBits） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
/**
 * 设置 setFrameBit 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @param on 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void setFrameBit(uint16_t index, bool on);

/**
 * 围绕 frameBit 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool frameBit(uint16_t index);

/**
 * 围绕 packedFrameBit 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param bits 调用方传入或接收的参数，含义以函数签名为准。
 * @param index 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool packedFrameBit(const uint8_t* bits, uint16_t index);

/**
 * 统计 countLitLeds 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint16_t countLitLeds();

// ---------------------------------------------------------------------------
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 帧应用辅助函数（Frame apply helpers，在内部获取 frameMutex） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 应用 applyM370 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool applyM370(const String& input, const String& reason, String& error);

/**
 * 应用 applyPackedFrame 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param packedBits 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void applyPackedFrame(const uint8_t* packedBits, const String& reason);

/**
 * 应用 applyPackedFrameImmediate 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param packedBits 调用方传入或接收的参数，含义以函数签名为准。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason);

/**
 * 应用 applyBlankFrame 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param reason 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void applyBlankFrame(const String& reason);

/**
 * 轮询服务、排队 serviceM370FrameQueue 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceM370FrameQueue();

/**
 * 清除、排队 clearQueuedM370Frames 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void clearQueuedM370Frames();

/**
 * 排队、统计 queuedM370FrameCount 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
uint8_t queuedM370FrameCount();

// ---------------------------------------------------------------------------
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 颜色 / 亮度（Color / brightness，必要时在内部获取 frameMutex） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

/**
 * 设置、渲染 setColorStateNoRender 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void setColorStateNoRender(const String& input);

/**
 * 设置 setColor 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param input 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool setColor(const String& input, String& error);

/**
 * 设置 setBrightness 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param raw 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void setBrightness(int raw);

// ---------------------------------------------------------------------------
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
// 渲染请求 / 消费（Render request / consume，通过 portMUX 实现 ISR 安全） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
/**
 * 请求、渲染 requestLedRender 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void requestLedRender();

/**
 * 消费、渲染、请求 consumeLedRenderRequest 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool consumeLedRenderRequest();

/**
 * 围绕 showCurrentFrameNoLock 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void showCurrentFrameNoLock();

// ---------------------------------------------------------------------------
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// 物理渲染（Physical render，仅从 Core 1 上的渲染任务调用） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
/**
 * 渲染 renderCurrentFrameToLedStrip 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void renderCurrentFrameToLedStrip();

// ---------------------------------------------------------------------------
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// LED 索引映射（LED index map，在启动时、任何渲染之前调用一次） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
/**
 * 初始化 initLedIndexMap 相关逻辑，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void initLedIndexMap();

// ---------------------------------------------------------------------------
// 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
// 灯带初始化（Strip initialization，从 setup() 调用一次） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
/**
 * 围绕 ledStripBegin 处理本模块的核心流程，供 led_renderer 模块使用。
 * @brief 说明 M370 帧解析和 LED 渲染 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void ledStripBegin();
