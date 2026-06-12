#include "scroll.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include <freertos/task.h>


// 本文件播放固件端文字滚动帧并协调滚动状态；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 滚动渲染任务（Scroll render task，固定到 Core 1） 相关代码，维护 播放固件端文字滚动帧并协调滚动状态。
// ---------------------------------------------------------------------------

static TaskHandle_t sScrollTaskHandle = nullptr;

/**
 * 渲染 scrollRenderTask 相关逻辑，供 scroll 模块使用。
 * @brief 说明 文字滚动播放 中当前函数或声明的用途。
 * @param parameter 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
static void scrollRenderTask(void* parameter) {
    (void)parameter;
    uint8_t nextFrame[FRAME_BYTES];

    for (;;) {
        // 处理 LED 矩阵、灯带刷新或硬件时序约束。
        // 处理 M370 帧、队列、校验或状态同步。
        // 说明 文字滚动播放 中当前代码块的职责和维护约束。
        // 说明文字滚动、帧缓存或播放状态处理。
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
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
                    // 说明文字滚动、帧缓存或播放状态处理。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
                    runtimeState().scrollFrameIndex =
                        (runtimeState().scrollFrameIndex + 1) % runtimeState().scrollFrameCount;

                    // 说明界面布局、组件状态或响应式规则。
                    // 说明文字滚动、帧缓存或播放状态处理。
                    // 说明文字滚动、帧缓存或播放状态处理。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
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
            // 说明双核任务分工、FreeRTOS 同步或临界区约束。
            // 说明文字滚动、帧缓存或播放状态处理。
            // 说明 文字滚动播放 中当前代码块的职责和维护约束。
            // 说明文字滚动、帧缓存或播放状态处理。
            //
            // 处理 M370 帧、队列、校验或状态同步。
            // 说明文字滚动、帧缓存或播放状态处理。
            // 处理 LED 矩阵、灯带刷新或硬件时序约束。
            // 说明文字滚动、帧缓存或播放状态处理。
            // 处理 LED 矩阵、灯带刷新或硬件时序约束。
            withFrameLock([&]() {
                if (!mainTaskRenderPending) {
                    mainTaskRenderPending = consumeLedRenderRequest();
                    if (mainTaskRenderPending) shouldRender = true;
                }
                if (runtimeState().firmwareScrollActive && !mainTaskRenderPending) {
                    memcpy(runtimeFrameBits(), nextFrame, FRAME_BYTES);
                    // 说明文字滚动、帧缓存或播放状态处理。
                    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
                    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
                    ++runtimeState().framesAccepted;
                } else {
                    // 说明文字滚动、帧缓存或播放状态处理。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
                    // 说明 文字滚动播放 中当前代码块的职责和维护约束。
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
// 说明 文字滚动播放 中当前代码块的职责和维护约束。
// 任务创建（Task creation） 相关代码，维护 播放固件端文字滚动帧并协调滚动状态。
// ---------------------------------------------------------------------------

/**
 * 启动、渲染 startScrollRenderTask 相关逻辑，供 scroll 模块使用。
 * @brief 说明 文字滚动播放 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 渲染 notifyScrollRenderTask 相关逻辑，供 scroll 模块使用。
 * @brief 说明 文字滚动播放 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
