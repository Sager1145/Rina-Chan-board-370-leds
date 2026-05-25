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

    /**
     * @brief Construct one button runtime record.
     * @param buttonCode Symbolic button code.
     * @param gpioPin Physical GPIO pin.
     * @return Initialized runtime record.
     */
    ButtonRuntime(const char* buttonCode, uint8_t gpioPin)
        : code(buttonCode), pin(gpioPin) {}
};

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

/**
 * @brief Initialize GPIO pins and seed debounce/repeat state from current levels.
 * @param None.
 * @return None.
 */
void initHardwareButtons();

/**
 * @brief Poll GPIO, debounce transitions, fire actions, and update overlay inputs.
 * @param None.
 * @return None.
 */
void serviceHardwareButtons();

/**
 * @brief Execute a named button action from GPIO or the Web API.
 * @param button Button code such as B1, B3B1, or B5.
 * @param source Event source string used in runtime reasons and scroll-stop notices.
 * @return true when the action was recognized and completed.
 */
bool runButtonAction(const String& button, const String& source);
