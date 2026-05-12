#pragma once
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Hardware button runtime record
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
// API
// ---------------------------------------------------------------------------

// Initialize GPIO pins and debounce state.
void initHardwareButtons();

// Poll GPIO, debounce, and fire actions.  Call every loop() iteration.
void serviceHardwareButtons();

// Execute a named button action from any context (GPIO or API).
// Returns false if the action is unknown or preconditions are not met.
bool runButtonAction(const String& button, const String& source);
