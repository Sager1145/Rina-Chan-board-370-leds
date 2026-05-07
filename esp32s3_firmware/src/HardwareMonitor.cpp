#include "HardwareMonitor.h"

#include <algorithm>

#include <Arduino.h>

namespace rina {
namespace {

constexpr uint8_t kButtonQueueLength = 24;
constexpr uint8_t kTrimSamplesEachSide = 4;
constexpr uint8_t kMedianMeanDivisor = config::BATTERY_SAMPLES - (kTrimSamplesEachSide * 2);
constexpr uint8_t kAdcSmoothShift = 3;

uint32_t smoothIir(uint32_t previous, uint32_t sample) {
    if (previous == 0) {
        return sample;
    }
    return ((previous * ((1U << kAdcSmoothShift) - 1U)) + sample + (1U << (kAdcSmoothShift - 1U))) >> kAdcSmoothShift;
}

}  // namespace

HardwareMonitor::HardwareMonitor()
    : buttons_{
          ButtonRuntime{ButtonId::Prev, config::BUTTON_PREV_GPIO, 1U << 0},
          ButtonRuntime{ButtonId::Next, config::BUTTON_NEXT_GPIO, 1U << 1},
          ButtonRuntime{ButtonId::Auto, config::BUTTON_AUTO_GPIO, 1U << 2},
          ButtonRuntime{ButtonId::BrightnessDown, config::BUTTON_BRIGHTNESS_DOWN_GPIO, 1U << 3},
          ButtonRuntime{ButtonId::BrightnessUp, config::BUTTON_BRIGHTNESS_UP_GPIO, 1U << 4},
          ButtonRuntime{ButtonId::ResetBattery, config::BUTTON_RESET_BATTERY_GPIO, 1U << 5},
      },
      buttonQueue_(nullptr),
      scanTimer_(nullptr),
      debouncedMask_(0),
      activeComboMask_(0),
      batteryAdcMv_(0),
      batteryMv_(0),
      chargeAdcMv_(0),
      chargeMv_(0),
      begun_(false),
      stats_() {
}

bool HardwareMonitor::begin() {
    if (begun_) {
        return true;
    }

    for (auto& button : buttons_) {
        pinMode(button.pin, INPUT_PULLUP);
        button.lastRawDown = false;
        button.debouncedDown = false;
        button.stableMs = config::DEBOUNCE_MS;
    }

    analogReadResolution(12);
    analogSetPinAttenuation(config::BATTERY_ADC_GPIO, ADC_11db);
    analogSetPinAttenuation(config::CHARGE_DETECT_ADC_GPIO, ADC_11db);

    buttonQueue_ = xQueueCreate(kButtonQueueLength, sizeof(ButtonEvent));
    if (buttonQueue_ == nullptr) {
        return false;
    }

    scanTimer_ = xTimerCreate(
        "hwmon",
        pdMS_TO_TICKS(config::BUTTON_SCAN_PERIOD_MS),
        pdTRUE,
        this,
        &HardwareMonitor::timerThunk);
    if (scanTimer_ == nullptr) {
        vQueueDelete(buttonQueue_);
        buttonQueue_ = nullptr;
        return false;
    }

    begun_ = xTimerStart(scanTimer_, 0) == pdPASS;
    return begun_;
}

bool HardwareMonitor::pollButtonEvent(ButtonEvent& event) {
    if (buttonQueue_ == nullptr) {
        return false;
    }
    return xQueueReceive(buttonQueue_, &event, 0) == pdTRUE;
}

uint32_t HardwareMonitor::batteryMilliVolts() const {
    return batteryMv_;
}

uint32_t HardwareMonitor::batteryAdcMilliVolts() const {
    return batteryAdcMv_;
}

uint32_t HardwareMonitor::chargeMilliVolts() const {
    return chargeMv_;
}

uint32_t HardwareMonitor::chargeAdcMilliVolts() const {
    return chargeAdcMv_;
}

float HardwareMonitor::batteryVoltage() const {
    return batteryMv_ / 1000.0f;
}

float HardwareMonitor::chargeVoltage() const {
    return chargeMv_ / 1000.0f;
}

uint8_t HardwareMonitor::currentButtonMask() const {
    return debouncedMask_;
}

const HardwareMonitorStats& HardwareMonitor::stats() const {
    return stats_;
}

const char* HardwareMonitor::buttonName(ButtonId button) {
    switch (button) {
        case ButtonId::Prev:
            return "B1/Prev";
        case ButtonId::Next:
            return "B2/Next";
        case ButtonId::Auto:
            return "B3/Auto";
        case ButtonId::BrightnessDown:
            return "B4/BrightnessDown";
        case ButtonId::BrightnessUp:
            return "B5/BrightnessUp";
        case ButtonId::ResetBattery:
            return "B6/ResetBattery";
        case ButtonId::None:
        default:
            return "Combo";
    }
}

const char* HardwareMonitor::eventName(ButtonEventType type) {
    switch (type) {
        case ButtonEventType::Pressed:
            return "pressed";
        case ButtonEventType::Released:
            return "released";
        case ButtonEventType::ShortPress:
            return "short";
        case ButtonEventType::LongPress:
            return "long";
        case ButtonEventType::ComboPressed:
            return "combo-pressed";
        case ButtonEventType::ComboReleased:
            return "combo-released";
        default:
            return "unknown";
    }
}

void HardwareMonitor::timerThunk(TimerHandle_t timer) {
    auto* self = static_cast<HardwareMonitor*>(pvTimerGetTimerID(timer));
    if (self != nullptr) {
        self->timerTick();
    }
}

uint8_t HardwareMonitor::popcount8(uint8_t value) {
    uint8_t count = 0;
    while (value != 0) {
        count += value & 1U;
        value >>= 1U;
    }
    return count;
}

uint32_t HardwareMonitor::rawToAdcMilliVolts(uint16_t raw) {
    return (static_cast<uint32_t>(raw) * config::ADC_REF_MV + (config::ADC_MAX_RAW / 2U)) /
           config::ADC_MAX_RAW;
}

uint32_t HardwareMonitor::applyDivider(uint32_t adcMv, uint32_t r1, uint32_t r2) {
    return (static_cast<uint64_t>(adcMv) * (r1 + r2) + (r2 / 2U)) / r2;
}

uint16_t HardwareMonitor::medianMean16(uint8_t gpio) const {
    std::array<uint16_t, config::BATTERY_SAMPLES> samples{};

    for (auto& sample : samples) {
        sample = static_cast<uint16_t>(analogRead(gpio));
    }

    std::sort(samples.begin(), samples.end());

    uint32_t sum = 0;
    for (size_t i = kTrimSamplesEachSide; i < samples.size() - kTrimSamplesEachSide; ++i) {
        sum += samples[i];
    }

    return static_cast<uint16_t>((sum + (kMedianMeanDivisor / 2U)) / kMedianMeanDivisor);
}

void HardwareMonitor::timerTick() {
    const uint32_t nowMs = millis();
    scanButtons(nowMs);
    sampleAdc();
    ++stats_.scanCount;
}

void HardwareMonitor::scanButtons(uint32_t nowMs) {
    uint8_t downMask = debouncedMask_;

    for (auto& button : buttons_) {
        const bool rawDown = config::BUTTON_ACTIVE_LOW ? (digitalRead(button.pin) == LOW) : (digitalRead(button.pin) == HIGH);

        if (rawDown == button.lastRawDown) {
            if (button.stableMs < config::DEBOUNCE_MS) {
                button.stableMs += config::BUTTON_SCAN_PERIOD_MS;
            }
        } else {
            button.lastRawDown = rawDown;
            button.stableMs = 0;
        }

        if (button.stableMs >= config::DEBOUNCE_MS && rawDown != button.debouncedDown) {
            button.debouncedDown = rawDown;

            if (rawDown) {
                downMask |= button.mask;
                button.pressedAtMs = nowMs;
                button.longEmitted = false;
                button.comboConsumed = false;
                emitButtonEvent(ButtonEventType::Pressed, button.id, button.mask, 0, nowMs);
            } else {
                downMask &= static_cast<uint8_t>(~button.mask);
                const uint32_t durationMs = nowMs - button.pressedAtMs;
                emitButtonEvent(ButtonEventType::Released, button.id, button.mask, durationMs, nowMs);

                if (!button.longEmitted && !button.comboConsumed) {
                    emitButtonEvent(ButtonEventType::ShortPress, button.id, button.mask, durationMs, nowMs);
                }
            }
        }

        if (button.debouncedDown && !button.longEmitted) {
            const uint32_t durationMs = nowMs - button.pressedAtMs;
            if (durationMs >= config::BUTTON_LONG_PRESS_MS) {
                button.longEmitted = true;
                button.comboConsumed = true;
                emitButtonEvent(ButtonEventType::LongPress, button.id, button.mask, durationMs, nowMs);
            }
        }
    }

    debouncedMask_ = downMask;
    updateComboState(debouncedMask_, nowMs);
}

void HardwareMonitor::sampleAdc() {
    const uint16_t batteryRaw = medianMean16(config::BATTERY_ADC_GPIO);
    const uint16_t chargeRaw = medianMean16(config::CHARGE_DETECT_ADC_GPIO);

    const uint32_t batteryAdcMv = rawToAdcMilliVolts(batteryRaw);
    const uint32_t chargeAdcMv = rawToAdcMilliVolts(chargeRaw);
    const uint32_t batteryMv = applyDivider(batteryAdcMv, config::BATTERY_DIVIDER_R1, config::BATTERY_DIVIDER_R2);
    const uint32_t chargeMv = applyDivider(chargeAdcMv, config::CHARGE_DETECT_DIVIDER_R1, config::CHARGE_DETECT_DIVIDER_R2);

    batteryAdcMv_ = smoothIir(batteryAdcMv_, batteryAdcMv);
    chargeAdcMv_ = smoothIir(chargeAdcMv_, chargeAdcMv);
    batteryMv_ = smoothIir(batteryMv_, batteryMv);
    chargeMv_ = smoothIir(chargeMv_, chargeMv);
    stats_.lastBatteryRaw = batteryRaw;
    stats_.lastChargeRaw = chargeRaw;
    ++stats_.adcSampleCount;
}

void HardwareMonitor::emitButtonEvent(
    ButtonEventType type,
    ButtonId button,
    uint8_t mask,
    uint32_t durationMs,
    uint32_t nowMs) {
    if (buttonQueue_ == nullptr) {
        return;
    }

    ButtonEvent event;
    event.type = type;
    event.button = button;
    event.buttonMask = mask;
    event.durationMs = durationMs;
    event.timestampMs = nowMs;

    if (xQueueSend(buttonQueue_, &event, 0) == pdTRUE) {
        ++stats_.buttonEventCount;
    } else {
        ++stats_.queueOverflowCount;
    }
}

void HardwareMonitor::updateComboState(uint8_t downMask, uint32_t nowMs) {
    const bool hasCombo = popcount8(downMask) >= 2;

    if (activeComboMask_ != 0 && (!hasCombo || downMask != activeComboMask_)) {
        emitButtonEvent(ButtonEventType::ComboReleased, ButtonId::None, activeComboMask_, 0, nowMs);
        activeComboMask_ = 0;
    }

    if (hasCombo && downMask != activeComboMask_) {
        activeComboMask_ = downMask;
        for (auto& button : buttons_) {
            if ((button.mask & downMask) != 0) {
                button.comboConsumed = true;
            }
        }
        emitButtonEvent(ButtonEventType::ComboPressed, ButtonId::None, activeComboMask_, 0, nowMs);
    }
}

}  // namespace rina
