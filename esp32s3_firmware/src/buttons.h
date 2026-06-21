#pragma once
#include <Arduino.h>

struct ButtonRuntime {
    const char* code;
    uint8_t pin;
    bool rawPressed = false;
    bool pressed = false;
    bool comboConsumed = false;
    uint32_t lastRawChangeMs = 0;
    uint32_t pressedAtMs = 0;
    uint32_t lastRepeatMs = 0;
    // Serial diagnostics emulation overlay. emuPressed is OR'd into the raw read
    // so an emulated button flows through the identical debounce/repeat/combo
    // state machine as the GPIO. pressFromSerial records whether the *currently
    // latched* logical press originated from serial (for source tagging).
    bool emuPressed = false;
    bool pressFromSerial = false;

    ButtonRuntime(const char* buttonCode, uint8_t gpioPin)
        : code(buttonCode), pin(gpioPin) {}
};

void initHardwareButtons();

void serviceHardwareButtons();

bool runButtonAction(const String& button, const String& source);

// --- Serial diagnostics button emulation (no-op effect unless used) ---------
// Engage/clear the emulated-press overlay for a button code (B1..B6). The next
// serviceHardwareButtons() pass debounces it exactly like a physical edge.
void emulateButtonRawSet(const char* code, bool pressed);
// True if `code` names a real button (B1..B6).
bool buttonCodeValid(const char* code);
// Live state inspection for `btn status`.
bool buttonPhysicalPressed(const char* code);
bool buttonEmulatedPressed(const char* code);
