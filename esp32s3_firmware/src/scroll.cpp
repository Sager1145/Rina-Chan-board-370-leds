#include "scroll.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include <freertos/task.h>

// ---------------------------------------------------------------------------
// Scroll render task  (pinned to Core 1)
// ---------------------------------------------------------------------------

static TaskHandle_t sScrollTaskHandle = nullptr;

static void scrollRenderTask(void* parameter) {
    (void)parameter;
    uint8_t nextFrame[FRAME_BYTES];

    for (;;) {
        // consumeLedRenderRequest() returns true when the main task (Core 0)
        // has written a new frame via applyM370 / applyBlankFrame / applyPackedFrame
        // and wants it displayed immediately.  We track this separately from the
        // scroll timer so a non-scroll frame always wins over a coincident scroll step.
        bool mainTaskRenderPending = consumeLedRenderRequest();
        bool shouldRender          = mainTaskRenderPending;
        bool hasScrollFrame        = false;

        lockScroll();
        if (runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused &&
            runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            const uint32_t now = millis();
            if (runtimeState().lastScrollFrameMs == 0) runtimeState().lastScrollFrameMs = now;

            const uint16_t intervalMs = constrain(
                runtimeState().scrollIntervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            const uint32_t elapsedMs = now - runtimeState().lastScrollFrameMs;

            if (elapsedMs >= intervalMs) {
                const uint32_t rawSteps = elapsedMs / intervalMs;
                uint32_t steps = rawSteps % runtimeState().scrollFrameCount;
                if (steps == 0) steps = 1;

                runtimeState().scrollFrameIndex  = (runtimeState().scrollFrameIndex + steps) % runtimeState().scrollFrameCount;
                runtimeState().lastScrollFrameMs += rawSteps * intervalMs;
                // Reset the scroll clock after a long suspension so playback
                // resumes smoothly instead of chasing stale elapsed time.
                if (now - runtimeState().lastScrollFrameMs >
                    static_cast<uint32_t>(intervalMs) * SCROLL_DRIFT_RESET_INTERVALS) {
                    runtimeState().lastScrollFrameMs = now;
                }
                memcpy(nextFrame, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
                ++runtimeState().framesAccepted;
                hasScrollFrame = true;
                shouldRender   = true;
            }
        }
        unlockScroll();

        if (hasScrollFrame) {
            // Re-check under frameMutex that:
            //   (a) firmware scroll is still the active source, and
            //   (b) the main task has NOT concurrently written a higher-priority
            //       non-scroll frame (mainTaskRenderPending).
            //
            // If the main task called applyM370/applyBlankFrame between
            // unlockScroll() and here it has already written runtimeFrameBits() and either
            // cleared firmwareScrollActive or set mainTaskRenderPending. In either
            // case we must not overwrite it with the stale scroll snapshot —
            // that would cause exactly one garbage/flash frame on the LEDs.
            lockFrame();
            if (runtimeState().firmwareScrollActive && !mainTaskRenderPending) {
                memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
            } else {
                // Main task frame takes priority; drop this scroll step silently.
                // shouldRender stays true if mainTaskRenderPending so the
                // main-task frame still gets displayed.
                if (!mainTaskRenderPending) shouldRender = false;
            }
            unlockFrame();
        }

        if (shouldRender) {
            renderCurrentFrameToLedStrip();
        }

        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1));
    }
}

// ---------------------------------------------------------------------------
// Task creation
// ---------------------------------------------------------------------------

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
