#include "buttons.h"
#include "state.h"
#include "config.h"
#include "led_renderer.h"
#include "faces.h"
#include "button_animations.h"
#include "scroll.h"

static ButtonRuntime buttons[] = {
    {"B1", BUTTON_B1_PIN},
    {"B2", BUTTON_B2_PIN},
    {"B3", BUTTON_B3_PIN},
    {"B4", BUTTON_B4_PIN},
    {"B5", BUTTON_B5_PIN},
    {"B6", BUTTON_B6_PIN},
};
static constexpr uint8_t BUTTON_COUNT = sizeof(buttons) / sizeof(buttons[0]);

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

static bool finishButtonAction(const String& code, const String& source, bool handled) {
    if (handled && source == "gpio") {
        startButtonAnimationForGpioAction(code);
    }
    return handled;
}

static void markScrollStoppedByButton(const String& code, const String& source) {
    ++runtimeState().scrollStopEventSeq;
    runtimeState().scrollStopEventMs     = millis();
    runtimeState().scrollStopEventButton = code;
    runtimeState().scrollStopEventSource = source;
    runtimeState().scrollStopEventReason = runtimeState().lastReason;
    touchRuntimeState();
}

static bool adjustBrightnessFromButton(const String& code, const String& source,
                                       int delta, const char* reasonSuffix) {
    setBrightness(static_cast<int>(runtimeState().brightness) + delta);
    runtimeState().lastReason = source + reasonSuffix;
    touchRuntimeStateSlow();
    return finishButtonAction(code, source, true);
}

static bool adjustAutoIntervalFromButton(const String& code, const String& source,
                                         int32_t deltaMs, const char* reasonSuffix) {
    uint32_t nextInterval = runtimeState().autoIntervalMs;
    if (deltaMs < 0) {
        const uint32_t step = static_cast<uint32_t>(-deltaMs);
        nextInterval = nextInterval > step ? nextInterval - step : MIN_AUTO_INTERVAL_MS;
    } else {
        nextInterval += static_cast<uint32_t>(deltaMs);
    }

    setAutoInterval(nextInterval);
    runtimeState().lastReason = source + reasonSuffix;
    touchRuntimeState();
    return finishButtonAction(code, source, true);
}

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
        return finishButtonAction(code, source, handled);
    }

    if (code == "B1" || code == "B2") {
        stopFirmwareScroll(false);
        setRestoreAutoAfterScroll(false);
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
        return adjustBrightnessFromButton(code, source,
                                          -BRIGHTNESS_BUTTON_STEP,
                                          "_B4_brightness_down");
    }
    if (code == "B5") {
        return adjustBrightnessFromButton(code, source,
                                          BRIGHTNESS_BUTTON_STEP,
                                          "_B5_brightness_up");
    }

    if (code == "B3B1") {
        return adjustAutoIntervalFromButton(code, source,
                                            -static_cast<int32_t>(AUTO_INTERVAL_BUTTON_STEP_MS),
                                            "_B3B1_auto_interval_down");
    }
    if (code == "B3B2") {
        return adjustAutoIntervalFromButton(code, source,
                                            AUTO_INTERVAL_BUTTON_STEP_MS,
                                            "_B3B2_auto_interval_up");
    }

    return false;
}

static void handleHardwareButtonPress(ButtonRuntime& button, uint32_t now) {
    button.pressedAtMs   = now;
    button.lastRepeatMs  = now;
    button.comboConsumed = false;
    handleButtonAnimationGpioPress(button.code);

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

    if (isFaceRepeatButton(button) || isBrightnessRepeatButton(button)) {
        fireHardwareButtonAction(button.code);
    }
}

static void handleHardwareButtonRelease(ButtonRuntime& button) {
    if (strcmp(button.code, "B3") == 0 && !button.comboConsumed) {
        fireHardwareButtonAction("B3");
    }
    handleButtonAnimationGpioRelease(button.code);
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
    serviceButtonAnimationButtonInputs(isHardwareButtonPressed("B6"),
                                       isHardwareButtonPressed("B2"),
                                       isHardwareButtonPressed("B3"));
}
