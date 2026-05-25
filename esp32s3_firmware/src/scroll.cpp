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

/**
 * @brief Core-1 task that arbitrates scroll timing and physical LED renders.
 * @param parameter Unused FreeRTOS task parameter.
 * @return Does not return.
 */
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

        withScrollLock([&]() {
            if (runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused &&
                runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
                const uint32_t now = millis();
                if (runtimeState().lastScrollFrameMs == 0) runtimeState().lastScrollFrameMs = now;

                const uint16_t intervalMs = constrain(
                    runtimeState().scrollIntervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
                const uint32_t elapsedMs = now - runtimeState().lastScrollFrameMs;

                if (elapsedMs >= intervalMs) {
                    // Advance EXACTLY one frame per qualifying render cycle. The task
                    // polls every ~1ms, so while it is not starved it steps once per
                    // intervalMs and reaches the intended frame rate. We deliberately
                    // do NOT "catch up" by stepping several frames at once: a
                    // multi-frame jump makes scrolling text visibly skip/tear and can
                    // read as the display stepping backward.
                    runtimeState().scrollFrameIndex =
                        (runtimeState().scrollFrameIndex + 1) % runtimeState().scrollFrameCount;

                    // Keep cadence locked to the interval grid under normal jitter by
                    // advancing the scroll clock one interval at a time. After a long
                    // stall (more than SCROLL_DRIFT_RESET_INTERVALS behind) hard-resync
                    // to now, otherwise the accumulated backlog would fire a burst of
                    // frames over the next few cycles and look like tearing.
                    if (elapsedMs <= static_cast<uint32_t>(intervalMs) * SCROLL_DRIFT_RESET_INTERVALS) {
                        runtimeState().lastScrollFrameMs += intervalMs;
                    } else {
                        runtimeState().lastScrollFrameMs = now;
                    }

                    memcpy(nextFrame, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
                    hasScrollFrame = true;
                    shouldRender   = true;
                }
            }
        });

        if (hasScrollFrame) {
            // Re-check under frameMutex that:
            //   (a) firmware scroll is still the active source, and
            //   (b) the main task has NOT concurrently written a higher-priority
            //       non-scroll frame (mainTaskRenderPending).
            //
            // If the main task called applyM370/applyBlankFrame between
            // unlockScroll() and here it has already written runtimeFrameBits() and either
            // cleared firmwareScrollActive or raised ledRenderRequested. In either
            // case we must not overwrite it with the stale scroll snapshot:
            // that would cause exactly one garbage/flash frame on the LEDs.
            withFrameLock([&]() {
                if (!mainTaskRenderPending) {
                    mainTaskRenderPending = consumeLedRenderRequest();
                    if (mainTaskRenderPending) shouldRender = true;
                }
                if (runtimeState().firmwareScrollActive && !mainTaskRenderPending) {
                    memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
                    // Count a scroll frame as accepted only once it is actually
                    // committed, and do it under frameMutex so this increment matches
                    // publishPackedFrameNow() (which also bumps framesAccepted under
                    // frameMutex). Previously this ran under scrollMutex, racing the
                    // counter with the main task.
                    ++runtimeState().framesAccepted;
                } else {
                    // Main task frame takes priority; drop this scroll step silently.
                    // shouldRender stays true if mainTaskRenderPending so the
                    // main-task frame still gets displayed.
                    if (!mainTaskRenderPending) shouldRender = false;
                }
            });
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

/**
 * @brief Start the pinned LED scroll/render task if it is not already running.
 * @param None.
 * @return None.
 */
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

/**
 * @brief Wake the render task from task or ISR context.
 * @param None.
 * @return None.
 */
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
