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

// 本文件是 ESP32-S3 固件入口，负责按硬件依赖顺序启动
// LED、LittleFS、按钮、电源监控和 Web API，并在 Core 0 主循环中调度控制面。

// ---------------------------------------------------------------------------
// 说明 固件启动和主循环 中当前代码块的职责和维护约束。
// ---------------------------------------------------------------------------

/**
 * 按硬件时序和模块依赖启动整套固件；这里的顺序会影响 LED 首帧、
 * LittleFS 资源读取、WebUI 状态以及双核任务分工。
 * @brief 说明 固件启动和主循环 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void setup() {
    // 中文块：复位后立刻压低 LED 数据线，避免 WS2812/SK6812 在串口启动前
    // 读到漂浮电平并锁存随机亮点。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, LOW);
    delay(LED_BOOT_DATA_LOW_HOLD_MS);
    delayMicroseconds(LED_SIGNAL_RESET_US);

    // 中文块：打开串口日志并记录启动时间，后续状态接口会用 bootMs 计算 uptime。
    Serial.begin(115200);
    delay(200);
    runtimeState().bootMs = millis();

    // 中文块：先准备文字滚动帧缓存；WebUI 上传 scroll frames 和渲染任务读取缓存
    // 都依赖 RuntimeStore 已经拥有这块内存。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明文字滚动、帧缓存或播放状态处理。
    initRuntimeScrollFrameBuffer();

    // 中文块：初始化跨 Core 0/Core 1 使用的 FreeRTOS mutex；后面的状态、
    // LittleFS 和 LED 总线访问都要靠这些锁保护。
    // 说明双核任务分工、FreeRTOS 同步或临界区约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    if (!initSyncPrimitives()) {
        Serial.println("Failed to create one or more FreeRTOS mutexes");
    }

    // 中文块：预计算逻辑 LED index 到物理灯珠顺序的映射，渲染前必须完成。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    initLedIndexMap();

    // 中文块：初始化灯带并先锁存一帧全灭，给 BSS138 level shifter 留出稳定时间。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    ledStripBegin();
    delay(LED_BOOT_CLEAR_HOLD_MS);

    // 中文块：只更新默认颜色状态，不排队渲染；首个真实画面应来自启动默认表情，
    // 避免任务渲染的空白帧和启动帧在 WS2812 总线上竞争。
    // 说明颜色、亮度或显示参数处理。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    setColorStateNoRender(DEFAULT_COLOR);

    // 中文块：挂载 LittleFS 并读取运行设置/保存表情；失败时直接显示文件系统
    // 诊断灯效，方便无串口时定位问题。
    // 说明 LittleFS 文件系统、静态资源或 gzip 打包流程。
    if (!mountFilesystem()) {
        showFilesystemErrorPattern();
    } else {
        loadRuntimeSettings();
        loadSavedFaces(true);
    }

    // 中文块：在启动渲染任务前同步输出第一帧，随后清掉加载表情时留下的渲染请求，
    // 防止任务醒来后重复刷同一帧。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    // 处理 M370 帧、队列、校验或状态同步。
    renderCurrentFrameToLedStrip();
    consumeLedRenderRequest();
    delay(LED_BOOT_STARTUP_SETTLE_MS);

    // 中文块：启动 Core 1 专用的 LED render/scroll task，把严格时序的灯带刷新
    // 从 WebServer 和按钮轮询中隔离出来。
    // 处理 LED 矩阵、灯带刷新或硬件时序约束。
    startScrollRenderTask();

    // 中文块：初始化实体按钮；按钮既会改变播放状态，也会触发本地 overlay animation。
    // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    initHardwareButtons();

    // 中文块：电源监控会把电池/充电状态发布给 WebUI 和 B6 overlay，所以在 HTTP
    // 路由开放前先采一次样。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    initPowerMonitor();

    // 中文块：最后启动网络；此时文件系统、播放状态、渲染队列、按钮和电源状态
    // 都已就绪，客户端连上来即可读取完整状态。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    // 说明电源、电池、充电或 ADC 校准相关逻辑。
    startAccessPoint();
    startWebServer();
}

// ---------------------------------------------------------------------------
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// ---------------------------------------------------------------------------
// 中文块：platformio.ini 通过 -D ARDUINO_RUNNING_CORE=0 把 loop() 固定在 Core 0。
// WebServer/HTTP、按钮、电源和帧队列都在这里合作式调度；Core 1 专门留给
// LED render/scroll task，避免网络负载破坏 WS2812/RMT 时序。
// 说明双核任务分工、FreeRTOS 同步或临界区约束。
// 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
// 处理 LED 矩阵、灯带刷新或硬件时序约束。
// 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
// 处理 LED 矩阵、灯带刷新或硬件时序约束。

/**
 * 在 Core 0 上轮询控制面任务，把网络、按钮、电源和延迟恢复逻辑
 * 以轻量合作式循环串起来。
 * @brief 说明 固件启动和主循环 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
void loop() {
    // 中文块：顺序有语义。帧队列先发布，Web/status 随后处理；按钮/API 本轮影响
    // 稳定后，再执行延迟恢复和自动播放。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明 固件启动和主循环 中当前代码块的职责和维护约束。
    serviceM370FrameQueue();
    webServerTick();
    serviceRuntimeSlowStatePublish();
    serviceHardwareButtons();
    serviceButtonAnimations();
    servicePowerMonitor();
    serviceDeferredFaceRestore();
    serviceAutoPlayback();
    vTaskDelay(pdMS_TO_TICKS(1));
}
