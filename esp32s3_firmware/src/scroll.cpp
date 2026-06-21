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

// Build the presentation context for a scroll frame. MUST be called while holding the
// scroll lock (reads runtimeState()/runtimeScrollMeta()).
static void fillScrollPresentationContextLocked(LedPresentationContext& ctx,
                                                LedPresentationSource source,
                                                const char* reason, bool rateEligible) {
    const RuntimeState& rs = runtimeState();
    const ScrollTimelineMeta& meta = runtimeScrollMeta();
    ctx = LedPresentationContext{};
    ctx.valid = true;
    ctx.source = source;
    strlcpy(ctx.timelineId, meta.timelineId, sizeof(ctx.timelineId));
    ctx.frameIndex        = rs.scrollFrameIndex;
    ctx.frameCount        = rs.scrollFrameCount;
    ctx.nominalIntervalMs = rs.scrollIntervalMs;
    ctx.uiFps             = meta.uiFps;
    ctx.firmwareScrollActive = rs.firmwareScrollActive;
    ctx.firmwareScrollPaused = rs.firmwareScrollPaused;
    ctx.userPaused           = rs.firmwareScrollUserPaused;
    ctx.systemPaused         = rs.firmwareScrollSystemPaused;
    ctx.rateEligible = rateEligible && rs.firmwareScrollActive &&
                       !rs.firmwareScrollPaused && rs.scrollFrameCount > 0;
    strlcpy(ctx.reason, reason ? reason : "", sizeof(ctx.reason));
}

static void scrollRenderTask(void* parameter) {
    (void)parameter;
    uint8_t nextFrame[FRAME_BYTES];

    for (;;) {
        bool mainTaskRenderPending = consumeLedRenderRequest();
        bool shouldRender          = mainTaskRenderPending;
        bool hasScrollFrame        = false;
        LedPresentationContext scrollCtx;
        bool hasScrollCtx = false;

        withScrollLock([&]() {
            hasScrollFrame = scrollSessionTickCursorLocked(millis(), nextFrame);
            if (hasScrollFrame) {
                shouldRender = true;
                fillScrollPresentationContextLocked(
                    scrollCtx, LedPresentationSource::ScrollTick,
                    "firmware_text_scroll_tick", true);
                hasScrollCtx = true;
            }
        });

        if (hasScrollFrame) {
            //
            withFrameLock([&]() {
                if (!mainTaskRenderPending) {
                    mainTaskRenderPending = consumeLedRenderRequest();
                    if (mainTaskRenderPending) shouldRender = true;
                }
                if (runtimeState().firmwareScrollActive) {
                    memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
                    ++runtimeState().framesAccepted;
                    // Hand the renderer this tick's exact frame identity before it latches.
                    if (hasScrollCtx) setPendingLedPresentationContext(scrollCtx);
                } else {
                    if (!mainTaskRenderPending) shouldRender = false;
                }
            });
        }

        if (hasScrollFrame) {
            // Core-1 tick telemetry: TRACE-only (off by default) and rate-limited
            // to <=1/sec, emitted OUTSIDE the scroll lock so it can never stall a
            // locked section or the WS2812 render. One single-write line.
            static uint32_t sLastTickLogMs = 0;
            if (rinaLogShouldEmit(RINA_LOG_TRACE) && rinaLogRateReady(sLastTickLogMs, 1000)) {
                RLOG_TRACE("SCROLL", "event=tick idx=%u/%u",
                           static_cast<unsigned>(runtimeState().scrollFrameIndex),
                           static_cast<unsigned>(runtimeState().scrollFrameCount));
            }
        }

        if (shouldRender) {
            renderCurrentFrameToLedStrip();
        }

        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1));
    }
}

void startScrollRenderTask() {
    if (sScrollTaskHandle) return;

    const BaseType_t ok = xTaskCreatePinnedToCore(
        scrollRenderTask,
        "led_scroll_render",
        LED_RENDER_TASK_STACK_BYTES,
        nullptr,
        LED_RENDER_TASK_PRIORITY,
        &sScrollTaskHandle,
        LED_RENDER_TASK_CORE
    );

    if (ok != pdPASS) {
        sScrollTaskHandle = nullptr;
        Serial.println("Failed to start LED scroll render task; firmware scroll unavailable");
    }
}

void notifyScrollRenderTask() {
    if (!sScrollTaskHandle) return;

    if (xPortInIsrContext()) {
        BaseType_t higherPriorityTaskWoken = pdFALSE;
        vTaskNotifyGiveFromISR(sScrollTaskHandle, &higherPriorityTaskWoken);
        portYIELD_FROM_ISR(higherPriorityTaskWoken);
    } else {
        xTaskNotifyGive(sScrollTaskHandle);
    }
}
