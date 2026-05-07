#include "DisplayEngine.h"

#include <Arduino.h>

namespace rina {
namespace {

constexpr uint32_t kQ16One = 65536UL;
constexpr uint32_t kMilliampDivisor = 3UL * 255UL;

uint8_t scaleByteQ16(uint8_t value, uint32_t scaleQ16) {
    return static_cast<uint8_t>((static_cast<uint32_t>(value) * scaleQ16) >> 16);
}

}  // namespace

DisplayEngine::DisplayEngine()
    : pixels_(config::NUM_LEDS, config::LED_PIN),
      framebuffer_{},
      staging_{},
      frameMutex_(nullptr),
      statsMux_(portMUX_INITIALIZER_UNLOCKED),
      brightnessPct_(config::DEFAULT_BRIGHTNESS_PCT),
      brightnessCap_(config::MAX_BRIGHTNESS_DEFAULT),
      powerBudgetMa_(config::POWER_BUDGET_MA_DEFAULT),
      nextFrameDueUs_(0),
      begun_(false),
      demoMode_(false),
      stats_() {
}

void DisplayEngine::begin() {
    if (frameMutex_ == nullptr) {
        frameMutex_ = xSemaphoreCreateMutex();
    }
    if (frameMutex_ == nullptr) {
        begun_ = false;
        return;
    }

    framebuffer_.fill(0);
    staging_.fill(0);

    pixels_.Begin();
    pixels_.Dirty();

    nextFrameDueUs_ = micros();
    begun_ = true;
}

bool DisplayEngine::renderTick() {
    return renderTick(micros());
}

bool DisplayEngine::renderTick(uint32_t nowUs) {
    if (!begun_) {
        return false;
    }

    if (static_cast<int32_t>((nowUs + config::FRAME_SCHEDULER_TOLERANCE_US) - nextFrameDueUs_) < 0) {
        return false;
    }

    if (!pixels_.CanShow()) {
        recordDroppedFrame();
        advanceDeadline(nowUs);
        return false;
    }

    const uint32_t startUs = micros();

    if (!lockFrame(pdMS_TO_TICKS(2))) {
        recordDroppedFrame();
        advanceDeadline(nowUs);
        return false;
    }

    if (demoMode_) {
        drawDemoFrame();
    }

    applyBrightness();
    applyFrameDps();
    pushStagingToBus();
    unlockFrame();

    pixels_.Show(false);

    const uint32_t elapsedUs = micros() - startUs;
    portENTER_CRITICAL(&statsMux_);
    stats_.lastRenderUs = elapsedUs;
    if (elapsedUs > stats_.maxRenderUs) {
        stats_.maxRenderUs = elapsedUs;
    }
    ++stats_.frameCounter;
    portEXIT_CRITICAL(&statsMux_);

    advanceDeadline(nowUs);
    return true;
}

void DisplayEngine::clear() {
    if (!lockFrame()) {
        return;
    }
    framebuffer_.fill(0);
    unlockFrame();
}

void DisplayEngine::fill(uint8_t r, uint8_t g, uint8_t b) {
    if (!lockFrame()) {
        return;
    }
    for (size_t i = 0; i < config::NUM_LEDS; ++i) {
        const size_t base = i * 3;
        framebuffer_[base] = r;
        framebuffer_[base + 1] = g;
        framebuffer_[base + 2] = b;
    }
    unlockFrame();
}

void DisplayEngine::submitBaseFrame(const FrameBuffer& frame) {
    if (!lockFrame()) {
        return;
    }
    setFrameLocked(frame);
    unlockFrame();
}

void DisplayEngine::submitOverlay(const FrameBuffer& overlay) {
    if (!lockFrame()) {
        return;
    }

    for (size_t i = 0; i < config::NUM_LEDS; ++i) {
        const size_t base = i * 3U;
        const bool visible =
            overlay[base] != 0 ||
            overlay[base + 1U] != 0 ||
            overlay[base + 2U] != 0;
        if (visible) {
            framebuffer_[base] = overlay[base];
            framebuffer_[base + 1U] = overlay[base + 1U];
            framebuffer_[base + 2U] = overlay[base + 2U];
        }
    }

    unlockFrame();
}

void DisplayEngine::setPixel(size_t index, uint8_t r, uint8_t g, uint8_t b) {
    if (index >= config::NUM_LEDS) {
        return;
    }

    if (!lockFrame()) {
        return;
    }
    const size_t base = index * 3;
    framebuffer_[base] = r;
    framebuffer_[base + 1] = g;
    framebuffer_[base + 2] = b;
    unlockFrame();
}

void DisplayEngine::setDemoMode(bool enabled) {
    if (!lockFrame()) {
        return;
    }
    demoMode_ = enabled;
    unlockFrame();
}

void DisplayEngine::setBrightnessPct(uint8_t pct) {
    if (!lockFrame()) {
        return;
    }
    brightnessPct_ = clampBrightnessPct(pct);
    brightnessCap_ = capFromPct(brightnessPct_);
    unlockFrame();
}

void DisplayEngine::setBrightnessCap(uint8_t cap) {
    if (!lockFrame()) {
        return;
    }
    if (cap > config::MAX_BRIGHTNESS_HARD_CAP) {
        cap = config::MAX_BRIGHTNESS_HARD_CAP;
    }
    brightnessCap_ = cap;
    brightnessPct_ = static_cast<uint8_t>(
        (static_cast<uint16_t>(cap) * 100U + config::MAX_BRIGHTNESS_HARD_CAP / 2U) /
        config::MAX_BRIGHTNESS_HARD_CAP);
    unlockFrame();
}

void DisplayEngine::setPowerBudgetMa(uint32_t budgetMa) {
    if (!lockFrame()) {
        return;
    }
    if (budgetMa < config::POWER_BUDGET_MA_CONFIG_MIN) {
        budgetMa = config::POWER_BUDGET_MA_CONFIG_MIN;
    } else if (budgetMa > config::POWER_BUDGET_MA_ABSOLUTE_MAX) {
        budgetMa = config::POWER_BUDGET_MA_ABSOLUTE_MAX;
    }
    powerBudgetMa_ = budgetMa;
    unlockFrame();
}

void DisplayEngine::applyBrightness() {
    const uint16_t cap = brightnessCap_;

    for (size_t i = 0; i < config::LED_FRAME_BYTES; ++i) {
        const uint16_t v = framebuffer_[i];
        staging_[i] = static_cast<uint8_t>((v * cap + 127U) / 255U);
    }
}

void DisplayEngine::applyFrameDps() {
    const uint32_t estimatedMa = estimateCurrentMa(staging_);
    portENTER_CRITICAL(&statsMux_);
    stats_.lastEstimatedCurrentMa = estimatedMa;
    stats_.lastOutputCurrentMa = estimatedMa;
    stats_.lastDpsScaleQ16 = kQ16One;
    portEXIT_CRITICAL(&statsMux_);

    if (estimatedMa == 0 || estimatedMa <= powerBudgetMa_) {
        return;
    }

    const uint32_t scaleQ16 =
        static_cast<uint32_t>((static_cast<uint64_t>(powerBudgetMa_) << 16) / estimatedMa);

    for (size_t i = 0; i < config::LED_FRAME_BYTES; ++i) {
        staging_[i] = scaleByteQ16(staging_[i], scaleQ16);
    }

    const uint32_t outputMa = estimateCurrentMa(staging_);
    portENTER_CRITICAL(&statsMux_);
    stats_.lastDpsScaleQ16 = scaleQ16;
    stats_.lastOutputCurrentMa = outputMa;
    ++stats_.dpsLimitedFrameCount;
    portEXIT_CRITICAL(&statsMux_);
}

bool DisplayEngine::canShow() const {
    return begun_ && pixels_.CanShow();
}

bool DisplayEngine::isReady() const {
    return begun_;
}

uint8_t DisplayEngine::brightnessPct() const {
    return brightnessPct_;
}

uint8_t DisplayEngine::brightnessCap() const {
    return brightnessCap_;
}

uint32_t DisplayEngine::powerBudgetMa() const {
    return powerBudgetMa_;
}

DisplayEngineStats DisplayEngine::stats() const {
    DisplayEngineStats copy;
    portENTER_CRITICAL(&statsMux_);
    copy = stats_;
    portEXIT_CRITICAL(&statsMux_);
    return copy;
}

const char* DisplayEngine::driverName() const {
    return "NeoPixelBus<NeoGrbFeature, NeoEsp32Rmt1Ws2812xMethod>";
}

uint8_t DisplayEngine::clampBrightnessPct(uint8_t pct) {
    if (pct < config::BRIGHTNESS_MIN) {
        return config::BRIGHTNESS_MIN;
    }
    if (pct > config::BRIGHTNESS_MAX) {
        return config::BRIGHTNESS_MAX;
    }
    return pct;
}

uint8_t DisplayEngine::capFromPct(uint8_t pct) {
    pct = clampBrightnessPct(pct);
    return static_cast<uint8_t>(
        (static_cast<uint16_t>(pct) * config::MAX_BRIGHTNESS_HARD_CAP + 50U) / 100U);
}

uint32_t DisplayEngine::estimateCurrentMa(const FrameBuffer& frame) {
    uint32_t rgbSum = 0;
    for (uint8_t value : frame) {
        rgbSum += value;
    }

    return (rgbSum * config::LED_FULL_WHITE_MA + kMilliampDivisor / 2U) / kMilliampDivisor;
}

void DisplayEngine::drawDemoFrame() {
    const uint8_t phase = static_cast<uint8_t>((stats().frameCounter * 5U) & 0xffU);

    for (size_t i = 0; i < config::NUM_LEDS; ++i) {
        const uint8_t wave = static_cast<uint8_t>((i * 7U + phase) & 0xffU);
        const size_t base = i * 3;

        framebuffer_[base] = 255;
        framebuffer_[base + 1] = wave;
        framebuffer_[base + 2] = static_cast<uint8_t>(255U - wave);
    }
}

void DisplayEngine::setFrameLocked(const FrameBuffer& frame) {
    framebuffer_ = frame;
}

void DisplayEngine::pushStagingToBus() {
    uint8_t* pixels = pixels_.Pixels();

    for (size_t i = 0; i < config::NUM_LEDS; ++i) {
        const size_t base = i * 3;
        const uint8_t r = staging_[base];
        const uint8_t g = staging_[base + 1];
        const uint8_t b = staging_[base + 2];

        pixels[base] = g;
        pixels[base + 1] = r;
        pixels[base + 2] = b;
    }

    pixels_.Dirty();
}

void DisplayEngine::advanceDeadline(uint32_t nowUs) {
    nextFrameDueUs_ += config::FRAME_PERIOD_US;

    if (static_cast<int32_t>(nowUs - nextFrameDueUs_) >= 0) {
        nextFrameDueUs_ = nowUs + config::FRAME_PERIOD_US;
        recordDroppedFrame();
    }
}

void DisplayEngine::recordDroppedFrame() {
    portENTER_CRITICAL(&statsMux_);
    ++stats_.droppedFrameCount;
    portEXIT_CRITICAL(&statsMux_);
}

bool DisplayEngine::lockFrame(TickType_t ticks) const {
    return frameMutex_ != nullptr && xSemaphoreTake(frameMutex_, ticks) == pdTRUE;
}

void DisplayEngine::unlockFrame() const {
    xSemaphoreGive(frameMutex_);
}

}  // namespace rina
