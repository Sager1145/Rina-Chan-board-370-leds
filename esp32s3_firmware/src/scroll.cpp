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

        // Audit M3: hold the scroll lock across BOTH the cursor tick and the frame
        // publish, with the frame lock nested INSIDE it. Because Stop/Clear also takes
        // the scroll lock, it can no longer interleave in a lock-handoff gap, so there
        // is no window in which a just-computed scroll frame could be published over a
        // freshly-blanked panel, and firmwareScrollActive is read only under its owning
        // scroll lock (no cross-domain read). Nesting is Scroll -> Frame, exactly the
        // documented global order (sync.h), so it cannot invert ordering or deadlock:
        // no path ever takes the scroll lock while already holding the frame lock. The
        // section only does a 47-byte memcpy plus a brief critical-section flag read, so
        // the extra scroll-lock hold time is negligible for HTTP/button contenders, and
        // the expensive strip.show() still happens later, outside both locks.
        withScrollLock([&]() {
            hasScrollFrame = scrollSessionTickCursorLocked(millis(), nextFrame);
            if (!hasScrollFrame) return;
            shouldRender = true;
            withFrameLock([&]() {
                if (!mainTaskRenderPending) {
                    mainTaskRenderPending = consumeLedRenderRequest();
                    if (mainTaskRenderPending) shouldRender = true;
                }
                memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
                ++runtimeState().framesAccepted;
            });
        });

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

TaskHandle_t scrollRenderTaskHandle() {
    return sScrollTaskHandle;
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
