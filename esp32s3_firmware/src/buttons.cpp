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

// ---------------------------------------------------------------------------
// Mode toggle (B3 / M-A)
// ---------------------------------------------------------------------------

static bool handleModeButtonAction(const String& source) {
    const bool targetAuto    = !isAutoMode();
    const bool hadOtherPlayback = playbackIsNonFaceActivity();

    // B3 also serves as an emergency exit from text scroll / overlays.
    // When leaving another playback mode: push all-off, then restore the
    // current saved-face index in the requested mode.  This prevents the old
    // scroll frame from lingering.
    stopFirmwareScroll(false, false);
    state.restoreAutoAfterScroll = false;
    if (hadOtherPlayback) {
        applyBlankFrame(source + "_B3_clear_before_saved_face");
        delay(LED_STOP_CLEAR_BLANK_HOLD_MS);
    }

    if (!setMode(targetAuto ? "auto" : "manual", true)) return false;

    const bool faceApplied = applyCurrentSavedFaceForMode(
        source + (targetAuto ? "_B3_auto_current_saved_face" : "_B3_manual_current_saved_face"),
        targetAuto
    );
    if (!faceApplied) {
        Serial.println("B3/M-A switched mode but no saved face was available to apply");
    }
    return true;
}

// ---------------------------------------------------------------------------
// runButtonAction  (public)
// ---------------------------------------------------------------------------

bool runButtonAction(const String& button, const String& source) {
    String code = button;
    code.trim();
    code.toUpperCase();
    if (code.isEmpty()) return false;

    state.lastButton = code;

    if (code == "B3") return handleModeButtonAction(source);

    if (code == "B1" || code == "B2") {
        // Cancel scroll / other active playback first, then navigate faces.
        stopFirmwareScroll(false);
        state.restoreAutoAfterScroll = false;
    }
    if (code == "B1") return applyRelativeSavedFace( 1, source + "_B1_next_saved_face");
    if (code == "B2") return applyRelativeSavedFace(-1, source + "_B2_prev_saved_face");

    if (code == "B4") {
        setBrightness(static_cast<int>(state.brightness) - BRIGHTNESS_BUTTON_STEP);
        state.lastReason = source + "_B4_brightness_down";
        return true;
    }
    if (code == "B5") {
        setBrightness(static_cast<int>(state.brightness) + BRIGHTNESS_BUTTON_STEP);
        state.lastReason = source + "_B5_brightness_up";
        return true;
    }

    if (code == "B3B1") {
        setAutoInterval(state.autoIntervalMs > AUTO_INTERVAL_BUTTON_STEP_MS
                            ? state.autoIntervalMs - AUTO_INTERVAL_BUTTON_STEP_MS
                            : MIN_AUTO_INTERVAL_MS);
        state.lastReason = source + "_B3B1_auto_interval_down";
        return true;
    }
    if (code == "B3B2") {
        setAutoInterval(state.autoIntervalMs + AUTO_INTERVAL_BUTTON_STEP_MS);
        state.lastReason = source + "_B3B2_auto_interval_up";
        return true;
    }

    if (code == "B6B3") {
        state.playback   = "network_info";
        state.lastReason = source + "_B6B3_network_info";
        return true;
    }
    if (code == "B6S" || code == "B6L") {
        state.lastReason = source + "_" + code + "_battery_unhandled";
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

    // Combo: B3 + B6
    if ((strcmp(button.code, "B3") == 0 && isHardwareButtonPressed("B6")) ||
        (strcmp(button.code, "B6") == 0 && isHardwareButtonPressed("B3"))) {
        markButtonComboConsumed("B3");
        markButtonComboConsumed("B6");
        fireHardwareButtonAction("B6B3");
        return;
    }
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
    if (strcmp(button.code, "B1") == 0 || strcmp(button.code, "B2") == 0 ||
        strcmp(button.code, "B4") == 0 || strcmp(button.code, "B5") == 0) {
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

        const bool faceButton       = strcmp(button.code, "B1") == 0 || strcmp(button.code, "B2") == 0;
        const bool brightnessButton = strcmp(button.code, "B4") == 0 || strcmp(button.code, "B5") == 0;
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
