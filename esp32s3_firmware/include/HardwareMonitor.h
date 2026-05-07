#pragma once

#include <array>
#include <cstdint>

#include "Config.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/timers.h"

namespace rina {

enum class ButtonId : uint8_t {
    Prev = 0,
    Next,
    Auto,
    BrightnessDown,
    BrightnessUp,
    ResetBattery,
    None = 0xff,
};

enum class ButtonEventType : uint8_t {
    Pressed,
    Released,
    ShortPress,
    LongPress,
    ComboPressed,
    ComboReleased,
};

struct ButtonEvent {
    ButtonEventType type = ButtonEventType::Pressed;
    ButtonId button = ButtonId::None;
    uint8_t buttonMask = 0;
    uint32_t durationMs = 0;
    uint32_t timestampMs = 0;
};

struct HardwareMonitorStats {
    uint32_t scanCount = 0;
    uint32_t adcSampleCount = 0;
    uint32_t buttonEventCount = 0;
    uint32_t queueOverflowCount = 0;
    uint16_t lastBatteryRaw = 0;
    uint16_t lastChargeRaw = 0;
};

class HardwareMonitor {
public:
    HardwareMonitor();

    bool begin();
    bool pollButtonEvent(ButtonEvent& event);

    uint32_t batteryMilliVolts() const;
    uint32_t batteryAdcMilliVolts() const;
    uint32_t chargeMilliVolts() const;
    uint32_t chargeAdcMilliVolts() const;
    float batteryVoltage() const;
    float chargeVoltage() const;
    uint8_t batteryPercent() const;
    bool isCharging() const;
    uint8_t currentButtonMask() const;
    HardwareMonitorStats stats() const;

    static const char* buttonName(ButtonId button);
    static const char* eventName(ButtonEventType type);

private:
    struct ButtonRuntime {
        ButtonRuntime() = default;
        ButtonRuntime(ButtonId buttonId, uint8_t gpio, uint8_t bitMask)
            : id(buttonId), pin(gpio), mask(bitMask) {}

        ButtonId id;
        uint8_t pin;
        uint8_t mask;
        bool lastRawDown = false;
        bool debouncedDown = false;
        uint16_t stableMs = 0;
        uint32_t pressedAtMs = 0;
        bool longEmitted = false;
        bool comboConsumed = false;
    };

    static void timerThunk(TimerHandle_t timer);
    static uint8_t popcount8(uint8_t value);
    static uint32_t rawToAdcMilliVolts(uint16_t raw);
    static uint32_t applyDivider(uint32_t adcMv, uint32_t r1, uint32_t r2);
    static uint16_t voltageToPercentTenths(uint32_t mv);

    uint16_t medianMean16(uint8_t gpio) const;
    void timerTick();
    void scanButtons(uint32_t nowMs);
    void sampleAdc();
    void emitButtonEvent(ButtonEventType type, ButtonId button, uint8_t mask, uint32_t durationMs, uint32_t nowMs);
    void updateComboState(uint8_t downMask, uint32_t nowMs);

    std::array<ButtonRuntime, 6> buttons_;
    QueueHandle_t buttonQueue_;
    TimerHandle_t scanTimer_;
    mutable portMUX_TYPE dataMux_;
    uint8_t debouncedMask_;
    uint8_t activeComboMask_;
    uint32_t batteryAdcMv_;
    uint32_t batteryMv_;
    uint32_t chargeAdcMv_;
    uint32_t chargeMv_;
    uint8_t batteryPercent_;
    bool batteryPercentInitialized_;
    bool charging_;
    bool chargingInitialized_;
    bool begun_;
    HardwareMonitorStats stats_;
};

}  // namespace rina
