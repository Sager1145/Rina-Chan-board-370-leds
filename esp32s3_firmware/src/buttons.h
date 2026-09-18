#pragma once
#include <Arduino.h>

struct ButtonRuntime {
    const char* code;
    uint8_t pin;
    bool rawPressed = false;
    bool pressed = false;
    bool comboConsumed = false;
    bool longResetFired = false;
    uint32_t lastRawChangeMs = 0;
    uint32_t pressedAtMs = 0;
    uint32_t lastRepeatMs = 0;

    ButtonRuntime(const char* buttonCode, uint8_t gpioPin)
        : code(buttonCode), pin(gpioPin) {}
};

void initHardwareButtons();

void serviceHardwareButtons();

bool runButtonAction(const String& button, const String& source);

// Board group v1 (§1.5, docs/RINALINK_PROTOCOL_V1.md v1.2): true for the
// brightness buttons (B4/B5), normalizing the same way runButtonAction()
// does (trim + uppercase). Brightness never affects scroll timing, so a
// group-timed playback should not be exited by these -- matching what the
// physical gpio buttons already do (they never call
// scrollSessionExitGroupTimed() at all).
bool isBrightnessButtonCode(const String& button);
