/*
 * File Description: scroll.cpp
 * Drives the FreeRTOS background task on Core 1 for scrolling text rendering.
 *
 * Responsibilities:
 * - Creates and manages the FreeRTOS task `scrollRenderTask` running on Core 1.
 * - Polls or waits on notifications to render active text scroll sessions.
 * - Implements frame timings and delays (based on current scroll FPS) to ensure smooth transitions.
 *
 * Core Interactions:
 * - Communicates with scroll_session.cpp to retrieve character glyphs and frame buffers.
 * - Calls led_renderer.h to commit rendered scrolling frames to the physical NeoPixels.
 */
#include "scroll.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include "scroll_session.h"
#include "serial_log.h"
#include <freertos/task.h>

static TaskHandle_t sScrollTaskHandle = nullptr;

static void scrollRenderTask(void* parameter) {
    (void)parameter;
    uint8_t nextFrame[FRAME_BYTES];

    for (;;) {
        bool mainTaskRenderPending = consumeLedRenderRequest();
        bool shouldRender          = mainTaskRenderPending;
        bool hasScrollFrame        = false;

        withScrollLock([&]() {
            hasScrollFrame = scrollSessionTickCursorLocked(millis(), nextFrame);
            if (hasScrollFrame) shouldRender = true;
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
