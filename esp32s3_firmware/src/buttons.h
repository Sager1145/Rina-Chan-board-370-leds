#pragma once
#include <Arduino.h>


// 本文件处理 GPIO 按钮、组合键和按钮来源的语义动作；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 硬件按钮运行时记录（Hardware button runtime record） 相关代码，维护 处理 GPIO 按钮、组合键和按钮来源的语义动作。
// ---------------------------------------------------------------------------
struct ButtonRuntime {
    const char* code;
    uint8_t     pin;
    bool        rawPressed     = false;
    bool        pressed        = false;
    bool        comboConsumed  = false;
    uint32_t    lastRawChangeMs = 0;
    uint32_t    pressedAtMs    = 0;
    uint32_t    lastRepeatMs   = 0;

    ButtonRuntime(const char* buttonCode, uint8_t gpioPin)
        : code(buttonCode), pin(gpioPin) {}
};

// ---------------------------------------------------------------------------
// API 相关代码，维护 处理 GPIO 按钮、组合键和按钮来源的语义动作。
// ---------------------------------------------------------------------------

void initHardwareButtons();

void serviceHardwareButtons();

bool runButtonAction(const String& button, const String& source);
