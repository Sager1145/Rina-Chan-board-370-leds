#include "scroll.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include <freertos/task.h>

static TaskHandle_t sScrollTaskHandle = nullptr;

bool getRestoreAutoAfterScroll() {
    bool value = false;
    withScrollLock([&]() { value = runtimeState().restoreAutoAfterScroll; });
    return value;
}

void setRestoreAutoAfterScroll(bool value) {
    withScrollLock([&]() {
        runtimeState().restoreAutoAfterScroll = value;
    });
}

static void scrollRenderTask(void* parameter) {
    (void)parameter;
    uint8_t nextFrame[FRAME_BYTES];

    for (;;) {
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
                    runtimeState().scrollFrameIndex =
                        (runtimeState().scrollFrameIndex + 1) % runtimeState().scrollFrameCount;

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
