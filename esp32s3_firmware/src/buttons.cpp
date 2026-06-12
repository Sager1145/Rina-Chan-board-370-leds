#include "buttons.h"
#include "state.h"
#include "config.h"
#include "led_renderer.h"
#include "faces.h"
#include "button_animations.h"


// 本文件处理 GPIO 按钮、组合键和按钮来源的语义动作；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 说明 GPIO 按钮、组合键或本地 overlay 反馈。
// 按钮表（Button table） 相关代码，维护 处理 GPIO 按钮、组合键和按钮来源的语义动作。
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
// 说明 GPIO 按钮和组合键 中当前代码块的职责和维护约束。
// 内部辅助函数（Internal helpers） 相关代码，维护 处理 GPIO 按钮、组合键和按钮来源的语义动作。
// ---------------------------------------------------------------------------

/**
 * 围绕 buttonByCode 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param code 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static ButtonRuntime* buttonByCode(const char* code) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        if (strcmp(buttons[i].code, code) == 0) return &buttons[i];
    }
    return nullptr;
}

/**
 * 围绕 isFaceRepeatButton 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param button 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool isFaceRepeatButton(const ButtonRuntime& button) {
    return strcmp(button.code, "B1") == 0 || strcmp(button.code, "B2") == 0;
}

/**
 * 围绕 isBrightnessRepeatButton 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param button 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool isBrightnessRepeatButton(const ButtonRuntime& button) {
    return strcmp(button.code, "B4") == 0 || strcmp(button.code, "B5") == 0;
}

/**
 * 围绕 isHardwareButtonPressed 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param code 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool isHardwareButtonPressed(const char* code) {
    ButtonRuntime* b = buttonByCode(code);
    return b && b->pressed;
}

/**
 * 围绕 markButtonComboConsumed 消费队列、标记或一次性事件，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param code 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void markButtonComboConsumed(const char* code) {
    ButtonRuntime* b = buttonByCode(code);
    if (b) b->comboConsumed = true;
}

/**
 * 围绕 fireHardwareButtonAction 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param code 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void fireHardwareButtonAction(const char* code) {
    if (!runButtonAction(String(code), "gpio")) {
        Serial.printf("GPIO button action ignored: %s\n", code);
    }
}

/**
 * 围绕 isScrollInterruptButton 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param code 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool isScrollInterruptButton(const String& code) {
    return code == "B1" || code == "B2" || code == "B3";
}

/**
 * 围绕 isFirmwareScrollOrPreviewActive 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool isFirmwareScrollOrPreviewActive() {
    return runtimeState().firmwareScrollActive ||
           runtimeState().firmwareScrollPaused ||
           isScrollPlayback(runtimeState().playback);
}

/**
 * 围绕 finishButtonAction 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param code 调用方传入或接收的参数，含义以函数签名为准。
 * @param source 调用方传入或接收的参数，含义以函数签名为准。
 * @param handled 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static bool finishButtonAction(const String& code, const String& source, bool handled) {
    if (handled && source == "gpio") {
        startButtonAnimationForGpioAction(code);
    }
    return handled;
}

/**
 * 围绕 markScrollStoppedByButton 处理停止、清理或恢复流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param code 调用方传入或接收的参数，含义以函数签名为准。
 * @param source 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
// 说明 GPIO 按钮、组合键或本地 overlay 反馈。
// runButtonAction（公共函数 public） 相关代码，维护 处理 GPIO 按钮、组合键和按钮来源的语义动作。
// ---------------------------------------------------------------------------

/**
 * 围绕 runButtonAction 处理本模块的核心流程，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param button 调用方传入或接收的参数，含义以函数签名为准。
 * @param source 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool runButtonAction(const String& button, const String& source) {
    String code = button;
    code.trim();
    code.toUpperCase();
    if (code.isEmpty()) return false;

    // 说明文字滚动、帧缓存或播放状态处理。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明文字滚动、帧缓存或播放状态处理。
    const bool shouldNotifyScrollStop = isScrollInterruptButton(code) &&
                                        source == "gpio" &&
                                        isFirmwareScrollOrPreviewActive();

    if (code == "B3") {
        // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
        // 处理 LED 矩阵、灯带刷新或硬件时序约束。
        // 说明文字滚动、帧缓存或播放状态处理。
        if (source == "gpio" && runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused) {
            return finishButtonAction(code, source, true);
        }
        const bool handled = toggleModeFromButtonAction(source);
        if (handled && shouldNotifyScrollStop) markScrollStoppedByButton(code, source);
        return finishButtonAction(code, source, handled);
    }

    if (code == "B1" || code == "B2") {
        // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
        // 说明文字滚动、帧缓存或播放状态处理。
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
// 说明 GPIO 按钮、组合键或本地 overlay 反馈。
// GPIO 事件处理函数（GPIO event handlers） 相关代码，维护 处理 GPIO 按钮、组合键和按钮来源的语义动作。
// ---------------------------------------------------------------------------

/**
 * 处理 handleHardwareButtonPress 相关逻辑，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param button 调用方传入或接收的参数，含义以函数签名为准。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void handleHardwareButtonPress(ButtonRuntime& button, uint32_t now) {
    button.pressedAtMs   = now;
    button.lastRepeatMs  = now;
    button.comboConsumed = false;
    handleButtonAnimationGpioPress(button.code);

    // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
    // 说明字体、字形、Unicode 范围或 Web font 资源处理。
    // 说明 GPIO 按钮和组合键 中当前代码块的职责和维护约束。
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

    // 说明颜色、亮度或显示参数处理。
    // 说明 GPIO 按钮和组合键 中当前代码块的职责和维护约束。
    if (isFaceRepeatButton(button) || isBrightnessRepeatButton(button)) {
        fireHardwareButtonAction(button.code);
    }
}

/**
 * 处理 handleHardwareButtonRelease 相关逻辑，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param button 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void handleHardwareButtonRelease(ButtonRuntime& button) {
    // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
    if (strcmp(button.code, "B3") == 0 && !button.comboConsumed) {
        fireHardwareButtonAction("B3");
    }
    handleButtonAnimationGpioRelease(button.code);
    button.comboConsumed = false;
}

/**
 * 轮询服务 serviceHardwareButtonRepeats 相关逻辑，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param now 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void serviceHardwareButtonRepeats(uint32_t now) {
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button = buttons[i];
        if (!button.pressed || button.comboConsumed) continue;

        const bool faceButton       = isFaceRepeatButton(button);
        const bool brightnessButton = isBrightnessRepeatButton(button);
        if (!faceButton && !brightnessButton) continue;
        // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
        // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
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
// 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
// 公共 API（Public API） 相关代码，维护 处理 GPIO 按钮、组合键和按钮来源的语义动作。
// ---------------------------------------------------------------------------

/**
 * 初始化 initHardwareButtons 相关逻辑，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 轮询服务 serviceHardwareButtons 相关逻辑，供 buttons 模块使用。
 * @brief 说明 GPIO 按钮和组合键 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void serviceHardwareButtons() {
    const uint32_t now = millis();
    for (uint8_t i = 0; i < BUTTON_COUNT; ++i) {
        ButtonRuntime& button    = buttons[i];
        const bool     rawPressed = digitalRead(button.pin) == LOW;

        // 说明 GPIO 按钮和组合键 中当前代码块的职责和维护约束。
        // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
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
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
    // 说明 GPIO 按钮和组合键 中当前代码块的职责和维护约束。
    serviceButtonAnimationButtonInputs(isHardwareButtonPressed("B6"),
                                       isHardwareButtonPressed("B2"),
                                       isHardwareButtonPressed("B3"));
}
