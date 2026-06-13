#pragma once
#include <Arduino.h>

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

void initHardwareButtons();

void serviceHardwareButtons();

bool runButtonAction(const String& button, const String& source);
