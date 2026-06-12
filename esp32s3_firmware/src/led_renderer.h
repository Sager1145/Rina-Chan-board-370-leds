#pragma once
#include <Arduino.h>
#include "config.h"


// 本文件解析 M370 帧并把逻辑 LED 状态渲染到物理灯带；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// M370 帧编解码器（M370 frame codec） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

bool normalizeM370(const String& input, String& normalized, String& error);

bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error);

String blankM370();

// ---------------------------------------------------------------------------
// 帧位辅助函数（Frame bit helpers，通过 state.h 操作 frameBits） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
void setFrameBit(uint16_t index, bool on);

bool frameBit(uint16_t index);

bool packedFrameBit(const uint8_t* bits, uint16_t index);

uint16_t countLitLeds();

// ---------------------------------------------------------------------------
// 帧应用辅助函数（Frame apply helpers，在内部获取 frameMutex） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

bool applyM370(const String& input, const String& reason, String& error);

void applyPackedFrame(const uint8_t* packedBits, const String& reason);

void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason);

void applyBlankFrame(const String& reason);

void serviceM370FrameQueue();

void clearQueuedM370Frames();

uint8_t queuedM370FrameCount();

// ---------------------------------------------------------------------------
// 颜色 / 亮度（Color / brightness，必要时在内部获取 frameMutex） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------

void setColorStateNoRender(const String& input);

bool setColor(const String& input, String& error);

void setBrightness(int raw);

// ---------------------------------------------------------------------------
// 渲染请求 / 消费（Render request / consume，通过 portMUX 实现 ISR 安全） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
void requestLedRender();

bool consumeLedRenderRequest();

void showCurrentFrameNoLock();

// ---------------------------------------------------------------------------
// 物理渲染（Physical render，仅从 Core 1 上的渲染任务调用） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
void renderCurrentFrameToLedStrip();

// ---------------------------------------------------------------------------
// LED 索引映射（LED index map，在启动时、任何渲染之前调用一次） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
void initLedIndexMap();

// ---------------------------------------------------------------------------
// 灯带初始化（Strip initialization，从 setup() 调用一次） 相关代码，维护 解析 M370 帧并把逻辑 LED 状态渲染到物理灯带。
// ---------------------------------------------------------------------------
void ledStripBegin();
