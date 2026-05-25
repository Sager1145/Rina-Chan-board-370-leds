#include "buttons.h"
#include "state.h"
#include "config.h"
#include "led_renderer.h"
#include "faces.h"
#include "button_animations.h"

// ---------------------------------------------------------------------------
// Button table
// ---------------------------------------------------------------------------

static ButtonRuntime buttons[] = {
    {"B1", BUTTON_B1_PIN},
    {"B2", BUTTON_B2_PIN},
    {"B3", BUTTON_B3_PIN},
    {"B4", BUTTON_B4_PIN},
    {"B5", BUTTON_B5_PIN},
    {"B6", BUTTON_B6_PIN},
};
static constexpr uint8_t BUTTON_COUNT = sizeof(buttons) / sizeof(buttons[0]);

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * @brief Find a button runtime record by symbolic code.
 * @param code Null-terminated button code.
 * @return Pointer to the matching record, or nullptr.
 */
static ButtonRuntime* buttonByCode(const char* code) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        if (strcmp(buttons[i].code, code) == 0) return &buttons[i];
    }
    return nullptr;
}

/**
 * @brief Check whether a button repeats face navigation while held.
 * @param button Runtime button record.
 * @return true for B1/B2.
 */
static bool isFaceRepeatButton(const ButtonRuntime& button) {
    return strcmp(button.code, "B1") == 0 || strcmp(button.code, "B2") == 0;
}

/**
 * @brief Check whether a button repeats brightness changes while held.
 * @param button Runtime button record.
 * @return true for B4/B5.
 */
static bool isBrightnessRepeatButton(const ButtonRuntime& button) {
    return strcmp(button.code, "B4") == 0 || strcmp(button.code, "B5") == 0;
}

/**
 * @brief Read the debounced pressed state for another button.
 * @param code Button code to inspect.
 * @return true when that button is currently pressed.
 */
static bool isHardwareButtonPressed(const char* code) {
    ButtonRuntime* b = buttonByCode(code);
    return b && b->pressed;
}

/**
 * @brief Prevent a button release from also firing after it was used in a combo.
 * @param code Button code to mark as consumed.
 * @return None.
 */
static void markButtonComboConsumed(const char* code) {
    ButtonRuntime* b = buttonByCode(code);
    if (b) b->comboConsumed = true;
}

/**
 * @brief Run the public action path for a hardware-originated button event.
 * @param code Button or combo code.
 * @return None.
 */
static void fireHardwareButtonAction(const char* code) {
    if (!runButtonAction(String(code), "gpio")) {
        Serial.printf("GPIO button action ignored: %s\n", code);
    }
}

/**
 * @brief Identify GPIO buttons that should notify WebUI when they interrupt scroll.
 * @param code Normalized button code.
 * @return true when the button can stop firmware scroll or preview playback.
 */
static bool isScrollInterruptButton(const String& code) {
    return code == "B1" || code == "B2" || code == "B3";
}

/**
 * @brief Check whether a scroll-like firmware activity is currently visible.
 * @param None.
 * @return true when scroll state or playback says a scroll/preview is active.
 */
static bool isFirmwareScrollOrPreviewActive() {
    return runtimeState().firmwareScrollActive ||
           runtimeState().firmwareScrollPaused ||
           isScrollPlayback(runtimeState().playback);
}

/**
 * @brief Finish an action and start any GPIO-only feedback overlay.
 * @param code Button or combo code.
 * @param source Source label; only gpio triggers local overlays here.
 * @param handled Whether the action succeeded.
 * @return handled unchanged.
 */
static bool finishButtonAction(const String& code, const String& source, bool handled) {
    if (handled && source == "gpio") {
        startButtonAnimationForGpioAction(code);
    }
    return handled;
}

/**
 * @brief Publish a scroll-stop event for the WebUI polling layer.
 * @param code Button code that interrupted scroll.
 * @param source Source string, normally gpio.
 * @return None.
 */
static void markScrollStoppedByButton(const String& code, const String& source) {
    ++runtimeState().scrollStopEventSeq;
    runtimeState().scrollStopEventMs     = millis();
    runtimeState().scrollStopEventButton = code;
    runtimeState().scrollStopEventSource = source;
    runtimeState().scrollStopEventReason = runtimeState().lastReason;
    touchRuntimeState();
}

// ---------------------------------------------------------------------------
// runButtonAction  (public)
// ---------------------------------------------------------------------------

/**
 * @brief Execute a named button action from GPIO or Web API entry points.
 * @param button Button code such as B1, B2, B3, B3B1, B4, or B5.
 * @param source Event source used in runtime lastReason strings.
 * @return true when the action was handled.
 */
bool runButtonAction(const String& button, const String& source) {
    String code = button;
    code.trim();
    code.toUpperCase();
    if (code.isEmpty()) return false;

    // Capture the scroll-interrupt condition before the action mutates playback.
    // That lets the WebUI receive a precise event that the GPIO action caused
    // the stop, even if later calls have already reset scroll state.
    const bool shouldNotifyScrollStop = isScrollInterruptButton(code) &&
                                        source == "gpio" &&
                                        isFirmwareScrollOrPreviewActive();

    if (code == "B3") {
        // B3 is both mode toggle and scroll control.  During active unpaused
        // firmware scroll, the press is treated as an overlay-only acknowledgement
        // so it does not accidentally toggle auto/manual mid-scroll.
        if (source == "gpio" && runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused) {
            return finishButtonAction(code, source, true);
        }
        const bool handled = toggleModeFromButtonAction(source);
        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
        return finishButtonAction(code, source, handled);
    }

    if (code == "B1" || code == "B2") {
        // Button face navigation owns the visible frame after it fires, so it
        // first terminates scroll playback and clears any auto-restore intent.
        stopFirmwareScroll(false);
        runtimeState().restoreAutoAfterScroll = false;
    }
    if (code == "B1") {
        const bool handled = applyRelativeSavedFace( 1, source + "_B1_next_saved_face");
        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
        return handled;
    }
    if (code == "B2") {
        const bool handled = applyRelativeSavedFace(-1, source + "_B2_prev_saved_face");
        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
        return handled;
    }

    if (code == "B4") {
        setBrightness(static_cast<int>(runtimeState().brightness) - BRIGHTNESS_BUTTON_STEP);
        runtimeState().lastReason = source + "_B4_brightness_down";
        touchRuntimeStateSlow();
        return finishButtonAction(code, source, true);
    }
    if (code == "B5") {
        setBrightness(static_cast<int>(runtimeState().brightness) + BRIGHTNESS_BUTTON_STEP);
        runtimeState().lastReason = source + "_B5_brightness_up";
        touchRuntimeStateSlow();
        return finishButtonAction(code, source, true);
    }

    if (code == "B3B1") {
        setAutoInterval(runtimeState().autoIntervalMs > AUTO_INTERVAL_BUTTON_STEP_MS
                            ? runtimeState().autoIntervalMs - AUTO_INTERVAL_BUTTON_STEP_MS
                            : MIN_AUTO_INTERVAL_MS);
        runtimeState().lastReason = source + "_B3B1_auto_interval_down";
        touchRuntimeState();
        return finishButtonAction(code, source, true);
    }
    if (code == "B3B2") {
        setAutoInterval(runtimeState().autoIntervalMs + AUTO_INTERVAL_BUTTON_STEP_MS);
        runtimeState().lastReason = source + "_B3B2_auto_interval_up";
        touchRuntimeState();
        return finishButtonAction(code, source, true);
    }

    return false;
}

// ---------------------------------------------------------------------------
// GPIO event handlers
// ---------------------------------------------------------------------------

/**
 * @brief Handle a debounced button press edge.
 * @param button Runtime button record being pressed.
 * @param now Current millis() timestamp.
 * @return None.
 */
static void handleHardwareButtonPress(ButtonRuntime& button, uint32_t now) {
    button.pressedAtMs   = now;
    button.lastRepeatMs  = now;
    button.comboConsumed = false;
    handleButtonAnimationGpioPress(button.code);

    // Combo detection connects the raw button layer to semantic auto-interval
    // actions.  Mark both physical buttons consumed so their later releases do
    // not also toggle mode or navigate faces.
    if (strcmp(button.code, "B1") == 0 && isHardwareButtonPressed("B3")) {
        button.comboConsumed = true;
        markButtonComboConsumed("B3");
        fireHardwareButtonAction("B3B1");
        return;
    }
    if (strcmp(button.code, "B2") == 0 && isHardwareButtonPressed("B3")) {
        button.comboConsumed = true;
        markButtonComboConsumed("B3");
        fireHardwareButtonAction("B3B2");
        return;
    }

    // Face and brightness controls update continuously while held, so their
    // first action fires on press and later repeats are serviced by timer.
    if (isFaceRepeatButton(button) || isBrightnessRepeatButton(button)) {
        fireHardwareButtonAction(button.code);
    }
}

/**
 * @brief Handle a debounced button release edge.
 * @param button Runtime button record being released.
 * @return None.
 */
static void handleHardwareButtonRelease(ButtonRuntime& button) {
    // B3 waits until release so combo presses can claim it first.
    if (strcmp(button.code, "B3") == 0 && !button.comboConsumed) {
        fireHardwareButtonAction("B3");
    }
    handleButtonAnimationGpioRelease(button.code);
    button.comboConsumed = false;
}

/**
 * @brief Generate held-button repeat actions after debounce has settled.
 * @param now Current millis() timestamp.
 * @return None.
 */
static void serviceHardwareButtonRepeats(uint32_t now) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button = buttons[i];
        if (!button.pressed || button.comboConsumed) continue;

        const bool faceButton       = isFaceRepeatButton(button);
        const bool brightnessButton = isBrightnessRepeatButton(button);
        if (!faceButton && !brightnessButton) continue;
        // B3+B1/B2 is reserved for interval combos, so suppress face-repeat
        // while B3 is held to keep module semantics from colliding.
        if (faceButton && isHardwareButtonPressed("B3")) continue;

        const uint32_t repeatDelay = faceButton ? FACE_REPEAT_DELAY_MS : BRIGHTNESS_REPEAT_DELAY_MS;
        const uint32_t repeatEvery = faceButton ? FACE_REPEAT_MS       : BRIGHTNESS_REPEAT_MS;
        if (now - button.pressedAtMs  < repeatDelay) continue;
        if (now - button.lastRepeatMs < repeatEvery)  continue;

        button.lastRepeatMs = now;
        fireHardwareButtonAction(button.code);
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * @brief Initialize GPIO pullups and debounce bookkeeping for all buttons.
 * @param None.
 * @return None.
 */
void initHardwareButtons() {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        pinMode(buttons[i].pin, INPUT_PULLUP);
        buttons[i].rawPressed     = digitalRead(buttons[i].pin) == LOW;
        buttons[i].pressed        = buttons[i].rawPressed;
        buttons[i].lastRawChangeMs = millis();
        buttons[i].pressedAtMs    = buttons[i].pressed ? buttons[i].lastRawChangeMs : 0;
        buttons[i].lastRepeatMs   = buttons[i].pressedAtMs;
        buttons[i].comboConsumed  = false;
    }
}

/**
 * @brief Poll hardware buttons, emit debounced actions, and feed overlay logic.
 * @param None.
 * @return None.
 */
void serviceHardwareButtons() {
    const uint32_t now = millis();
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button    = buttons[i];
        const bool     rawPressed = digitalRead(button.pin) == LOW;

        // Raw edge tracking is separate from debounced state so contact bounce
        // must remain stable for BUTTON_DEBOUNCE_MS before actions are emitted.
        if (rawPressed != button.rawPressed) {
            button.rawPressed     = rawPressed;
            button.lastRawChangeMs = now;
        }
        if (now - button.lastRawChangeMs < BUTTON_DEBOUNCE_MS || rawPressed == button.pressed) {
            continue;
        }

        button.pressed = rawPressed;
        if (button.pressed) handleHardwareButtonPress(button, now);
        else                handleHardwareButtonRelease(button);
    }
    serviceHardwareButtonRepeats(now);
    // B6 battery overlay uses live button chords rather than normal semantic
    // actions, so the button module passes debounced physical state into the
    // animation module after all edge processing is complete.
    serviceButtonAnimationButtonInputs(isHardwareButtonPressed("B6"),
                                       isHardwareButtonPressed("B2"),
                                       isHardwareButtonPressed("B3"));
}
