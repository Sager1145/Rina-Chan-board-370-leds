#include "scroll.h"
#include "state.h"
#include "config.h"
#include "led_renderer.h"

// ---------------------------------------------------------------------------
// Scroll render task  (pinned to Core 1)
// ---------------------------------------------------------------------------

void scrollRenderTask(void* parameter) {
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
        if (state.firmwareScrollActive && !state.firmwareScrollPaused && state.scrollFrameCount > 0) {
            const uint32_t now = millis();
            if (state.lastScrollFrameMs == 0) state.lastScrollFrameMs = now;

            const uint16_t intervalMs = constrain(
                state.scrollIntervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            const uint32_t elapsedMs = now - state.lastScrollFrameMs;

            if (elapsedMs >= intervalMs) {
                const uint32_t rawSteps = elapsedMs / intervalMs;
                uint32_t steps = rawSteps % state.scrollFrameCount;
                if (steps == 0) steps = 1;

                state.scrollFrameIndex  = (state.scrollFrameIndex + steps) % state.scrollFrameCount;
                state.lastScrollFrameMs += rawSteps * intervalMs;
                // Guard against runaway drift after a long suspension
                if (now - state.lastScrollFrameMs > static_cast<uint32_t>(intervalMs) * 4U) {
                    state.lastScrollFrameMs = now;
                }
                memcpy(nextFrame, scrollFrameBits[state.scrollFrameIndex], FRAME_BYTES);
                ++state.framesAccepted;
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
            // unlockScroll() and here it has already written frameBits and either
            // cleared firmwareScrollActive or set mainTaskRenderPending. In either
            // case we must not overwrite it with the stale scroll snapshot —
            // that would cause exactly one garbage/flash frame on the LEDs.
            lockFrame();
            if (state.firmwareScrollActive && !mainTaskRenderPending) {
                memcpy(frameBits, nextFrame, FRAME_BYTES);
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
    if (scrollTaskHandle) return;

    const BaseType_t ok = xTaskCreatePinnedToCore(
        scrollRenderTask,
        "led_scroll_render",
        LED_RENDER_TASK_STACK_BYTES,
        nullptr,
        LED_RENDER_TASK_PRIORITY,
        &scrollTaskHandle,
        LED_RENDER_TASK_CORE
    );

    if (ok != pdPASS) {
        scrollTaskHandle = nullptr;
        Serial.println("Failed to start LED scroll render task; firmware scroll unavailable");
    }
}
