#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include <NeoPixelBus.h>

#include "Config.h"

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

namespace rina {

struct DisplayEngineStats {
    uint32_t frameCounter = 0;
    uint32_t droppedFrameCount = 0;
    uint32_t dpsLimitedFrameCount = 0;
    uint32_t lastEstimatedCurrentMa = 0;
    uint32_t lastOutputCurrentMa = 0;
    uint32_t lastDpsScaleQ16 = 65536;
    uint32_t lastRenderUs = 0;
    uint32_t maxRenderUs = 0;
};

class DisplayEngine {
public:
    using FrameBuffer = std::array<uint8_t, config::LED_FRAME_BYTES>;
    using PixelBus = NeoPixelBus<NeoGrbFeature, NeoEsp32Rmt1Ws2812xMethod>;

    DisplayEngine();

    void begin();
    bool renderTick();
    bool renderTick(uint32_t nowUs);

    void clear();
    void fill(uint8_t r, uint8_t g, uint8_t b);
    void submitBaseFrame(const FrameBuffer& frame);
    void submitOverlay(const FrameBuffer& overlay);
    void setPixel(size_t index, uint8_t r, uint8_t g, uint8_t b);
    void setDemoMode(bool enabled);

    void setBrightnessPct(uint8_t pct);
    void setBrightnessCap(uint8_t cap);
    void setPowerBudgetMa(uint32_t budgetMa);

    void applyBrightness();
    void applyFrameDps();

    bool canShow() const;
    bool isReady() const;
    uint8_t brightnessPct() const;
    uint8_t brightnessCap() const;
    uint32_t powerBudgetMa() const;
    DisplayEngineStats stats() const;
    const char* driverName() const;

private:
    static uint8_t clampBrightnessPct(uint8_t pct);
    static uint8_t capFromPct(uint8_t pct);
    static uint32_t estimateCurrentMa(const FrameBuffer& frame);

    void drawDemoFrame();
    void setFrameLocked(const FrameBuffer& frame);
    void pushStagingToBus();
    void advanceDeadline(uint32_t nowUs);
    void recordDroppedFrame();
    bool lockFrame(TickType_t ticks = portMAX_DELAY) const;
    void unlockFrame() const;

    PixelBus pixels_;
    FrameBuffer framebuffer_;
    FrameBuffer staging_;
    mutable SemaphoreHandle_t frameMutex_;
    mutable portMUX_TYPE statsMux_;
    uint8_t brightnessPct_;
    uint8_t brightnessCap_;
    uint32_t powerBudgetMa_;
    uint32_t nextFrameDueUs_;
    bool begun_;
    bool demoMode_;
    DisplayEngineStats stats_;
};

}  // namespace rina
