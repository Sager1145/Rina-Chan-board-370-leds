#include "scroll.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include "led_presentation.h"
#include "scroll_session.h"
#include "serial_log.h"
#include <freertos/task.h>
#include <string.h>

static TaskHandle_t sScrollTaskHandle = nullptr;

static void scrollRenderTask(void* parameter) {
    (void)parameter;
    uint8_t nextFrame[FRAME_BYTES];

    for (;;) {
        bool mainTaskRenderPending = consumeLedRenderRequest();
        bool shouldRender = mainTaskRenderPending;
        bool hasScrollFrame = false;
        LedPresentationContext scrollCtx;
        uint16_t scrollFrameIndexLocked = 0;
        uint16_t scrollFrameCountLocked = 0;

        // Keep ownership through publication. Releasing Scroll before taking Frame
        // lets a stop/new face win, then be overwritten by this obsolete tick.
        // This is the global Scroll -> Frame lock order; hardware I/O stays outside.
        withScrollLock([&]() {
            hasScrollFrame = scrollSessionTickCursorLocked(millis(), nextFrame);
            if (!hasScrollFrame)
                return;
            scrollSessionFillPresentationContextLocked(
                scrollCtx, LedPresentationSource::ScrollTick,
                "firmware_text_scroll_tick", true);
            scrollFrameIndexLocked = runtimeState().scrollFrameIndex;
            scrollFrameCountLocked = runtimeState().scrollFrameCount;
            withFrameLock([&]() {
                memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
                ++runtimeState().framesAccepted;
                setPendingLedPresentationContext(scrollCtx);
            });
            shouldRender = true;
        });

        if (hasScrollFrame) {
            // Core-1 tick telemetry: TRACE-only (off by default) and rate-limited
            // to <=1/sec, emitted OUTSIDE the scroll lock so it can never stall a
            // locked section or the WS2812 render. One single-write line.
            static uint32_t sLastTickLogMs = 0;
            if (rinaLogShouldEmit(RINA_LOG_TRACE) && rinaLogRateReady(sLastTickLogMs, 1000)) {
                RLOG_TRACE("SCROLL", "event=tick idx=%u/%u",
                           static_cast<unsigned>(scrollFrameIndexLocked),
                           static_cast<unsigned>(scrollFrameCountLocked));
            }
        }

        if (shouldRender) {
            renderCurrentFrameToLedStrip();
        }

        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1));
    }
}

void startScrollRenderTask() {
    if (sScrollTaskHandle)
        return;

    const BaseType_t ok = xTaskCreatePinnedToCore(
        scrollRenderTask,
        "led_scroll_render",
        LED_RENDER_TASK_STACK_BYTES,
        nullptr,
        LED_RENDER_TASK_PRIORITY,
        &sScrollTaskHandle,
        LED_RENDER_TASK_CORE);

    if (ok != pdPASS) {
        sScrollTaskHandle = nullptr;
        Serial.println("Failed to start LED scroll render task; firmware scroll unavailable");
    }
}

void notifyScrollRenderTask() {
    if (!sScrollTaskHandle)
        return;

    // No ISR callers exist (only loop-task and Core-1 task code calls this).
    xTaskNotifyGive(sScrollTaskHandle);
}
