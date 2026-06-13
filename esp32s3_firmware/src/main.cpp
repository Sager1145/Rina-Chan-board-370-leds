#include <Arduino.h>

#include "config.h"
#include "state.h"
#include "sync.h"
#include "led_renderer.h"
#include "storage.h"
#include "faces.h"
#include "scroll.h"
#include "buttons.h"
#include "button_animations.h"
#include "web_api.h"
#include "power_monitor.h"
#include <freertos/task.h>

static bool g_syncReady = false;

// LED、LittleFS、按钮、电源监控和 Web API，并在 Core 0 主循环中调度控制面。

// Setup

void setup() {
    // 读到漂浮电平并锁存随机亮点。
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, LOW);
    delay(LED_BOOT_DATA_LOW_HOLD_MS);
    delayMicroseconds(LED_SIGNAL_RESET_US);

    Serial.begin(115200);
    delay(200);
    runtimeState().bootMs = millis();

    // 都依赖 RuntimeStore 已经拥有这块内存。
    initRuntimeScrollFrameBuffer();

    // LittleFS 和 LED 总线访问都要靠这些锁保护。
    g_syncReady = initSyncPrimitives();
    if (!g_syncReady) {
        Serial.println("FATAL: FreeRTOS mutexes unavailable; render task disabled, running single-core");
        showFilesystemErrorPattern();
    }

    initLedIndexMap();

    ledStripBegin();
    delay(LED_BOOT_CLEAR_HOLD_MS);

    // 避免任务渲染的空白帧和启动帧在 WS2812 总线上竞争。
    setColorStateNoRender(DEFAULT_COLOR);

    // 诊断灯效，方便无串口时定位问题。
    if (!mountFilesystem()) {
        showFilesystemErrorPattern();
    } else {
        loadRuntimeSettings();
        loadSavedFaces(true);
    }

    // 防止任务醒来后重复刷同一帧。
    renderCurrentFrameToLedStrip();
    consumeLedRenderRequest();
    delay(LED_BOOT_STARTUP_SETTLE_MS);

    // 从 WebServer 和按钮轮询中隔离出来。
    if (g_syncReady) startScrollRenderTask();

    initHardwareButtons();

    // 路由开放前先采一次样。
    initPowerMonitor();

    // 都已就绪，客户端连上来即可读取完整状态。
    startAccessPoint();
    startWebServer();
}

// Main loop
// WebServer/HTTP、按钮、电源和帧队列都在这里合作式调度；Core 1 专门留给
// LED render/scroll task，避免网络负载破坏 WS2812/RMT 时序。

void loop() {
    // 稳定后，再执行延迟恢复和自动播放。
    serviceM370FrameQueue();
    if (!g_syncReady) {
        renderCurrentFrameToLedStrip();
    }
    webServerTick();
    serviceRuntimeSlowStatePublish();
    serviceHardwareButtons();
    serviceButtonAnimations();
    servicePowerMonitor();
    serviceDeferredFaceRestore();
    serviceAutoPlayback();
    vTaskDelay(pdMS_TO_TICKS(1));
}
