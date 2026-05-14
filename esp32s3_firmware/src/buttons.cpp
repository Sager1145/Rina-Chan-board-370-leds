#include "buttons.h"
#include "state.h"
#include "config.h"
#include "led_renderer.h"
#include "faces.h"

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

static ButtonRuntime* buttonByCode(const char* code) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        if (strcmp(buttons[i].code, code) == 0) return &buttons[i];
    }
    return nullptr;
}

static bool isFaceRepeatButton(const ButtonRuntime& button) {
    return strcmp(button.code, "B1") == 0 || strcmp(button.code, "B2") == 0;
}

static bool isBrightnessRepeatButton(const ButtonRuntime& button) {
    return strcmp(button.code, "B4") == 0 || strcmp(button.code, "B5") == 0;
}

static bool isHardwareButtonPressed(const char* code) {
    ButtonRuntime* b = buttonByCode(code);
    return b && b->pressed;
}

static void markButtonComboConsumed(const char* code) {
    ButtonRuntime* b = buttonByCode(code);
    if (b) b->comboConsumed = true;
}

static void fireHardwareButtonAction(const char* code) {
    if (!runButtonAction(String(code), "gpio")) {
        Serial.printf("GPIO button action ignored: %s\n", code);
    }
}

static bool isScrollInterruptButton(const String& code) {
    return code == "B1" || code == "B2" || code == "B3";
}

static bool isFirmwareScrollOrPreviewActive() {
    return runtimeState().firmwareScrollActive ||
           runtimeState().firmwareScrollPaused ||
           isScrollPlayback(runtimeState().playback);
}

static void markScrollStoppedByButton(const String& code, const String& source) {
    ++runtimeState().scrollStopEventSeq;
    runtimeState().scrollStopEventMs     = millis();
    runtimeState().scrollStopEventButton = code;
    runtimeState().scrollStopEventSource = source;
    runtimeState().scrollStopEventReason = runtimeState().lastReason;
}

// ---------------------------------------------------------------------------
// runButtonAction  (public)
// ---------------------------------------------------------------------------

bool runButtonAction(const String& button, const String& source) {
    String code = button;
    code.trim();
    code.toUpperCase();
    if (code.isEmpty()) return false;

    const bool shouldNotifyScrollStop = isScrollInterruptButton(code) &&
                                        source == "gpio" &&
                                        isFirmwareScrollOrPreviewActive();

    if (code == "B3") {
        const bool handled = toggleModeFromButtonAction(source);
        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
        return handled;
    }

    if (code == "B1" || code == "B2") {
        // Cancel scroll / other active playback first, then navigate faces.
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
        return true;
    }
    if (code == "B5") {
        setBrightness(static_cast<int>(runtimeState().brightness) + BRIGHTNESS_BUTTON_STEP);
        runtimeState().lastReason = source + "_B5_brightness_up";
        return true;
    }

    if (code == "B3B1") {
        setAutoInterval(runtimeState().autoIntervalMs > AUTO_INTERVAL_BUTTON_STEP_MS
                            ? runtimeState().autoIntervalMs - AUTO_INTERVAL_BUTTON_STEP_MS
                            : MIN_AUTO_INTERVAL_MS);
        runtimeState().lastReason = source + "_B3B1_auto_interval_down";
        return true;
    }
    if (code == "B3B2") {
        setAutoInterval(runtimeState().autoIntervalMs + AUTO_INTERVAL_BUTTON_STEP_MS);
        runtimeState().lastReason = source + "_B3B2_auto_interval_up";
        return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// GPIO event handlers
// ---------------------------------------------------------------------------

static void handleHardwareButtonPress(ButtonRuntime& button, uint32_t now) {
    button.pressedAtMs   = now;
    button.lastRepeatMs  = now;
    button.comboConsumed = false;

    // Combo: B3 + B1
    if (strcmp(button.code, "B1") == 0 && isHardwareButtonPressed("B3")) {
        button.comboConsumed = true;
        markButtonComboConsumed("B3");
        fireHardwareButtonAction("B3B1");
        return;
    }
    // Combo: B3 + B2
    if (strcmp(button.code, "B2") == 0 && isHardwareButtonPressed("B3")) {
        button.comboConsumed = true;
        markButtonComboConsumed("B3");
        fireHardwareButtonAction("B3B2");
        return;
    }

    // Single press (fire immediately for face nav and brightness)
    if (isFaceRepeatButton(button) || isBrightnessRepeatButton(button)) {
        fireHardwareButtonAction(button.code);
    }
}

static void handleHardwareButtonRelease(ButtonRuntime& button) {
    // B3 fires on release (after ensuring it was not part of a combo)
    if (strcmp(button.code, "B3") == 0 && !button.comboConsumed) {
        fireHardwareButtonAction("B3");
    }
    button.comboConsumed = false;
}

static void serviceHardwareButtonRepeats(uint32_t now) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button = buttons[i];
        if (!button.pressed || button.comboConsumed) continue;

        const bool faceButton       = isFaceRepeatButton(button);
        const bool brightnessButton = isBrightnessRepeatButton(button);
        if (!faceButton && !brightnessButton) continue;
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

void serviceHardwareButtons() {
    const uint32_t now = millis();
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button    = buttons[i];
        const bool     rawPressed = digitalRead(button.pin) == LOW;

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
}
