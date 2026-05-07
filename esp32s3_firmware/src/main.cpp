#include <Arduino.h>
#include <WiFi.h>
#include <esp_task_wdt.h>
#include "AppLogic.h"
#include "AssetManager.h"
#include "Config.h"
#include "DisplayEngine.h"
#include "HardwareMonitor.h"
#include "NetworkManager.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

TaskHandle_t LedRenderTask = nullptr;
TaskHandle_t NetworkTask = nullptr;
TaskHandle_t AssetIoTask = nullptr;
TaskHandle_t HardwareTask = nullptr;
TaskHandle_t AppLogicTask = nullptr;

namespace {

rina::DisplayEngine displayEngine;
rina::HardwareMonitor hardwareMonitor;
rina::AssetManager assetManager;
rina::NetworkManager networkManager;
rina::AppLogic appLogic;

void logDisplayStats() {
    static uint32_t lastLogMs = 0;
    static uint32_t lastFrameCount = 0;

    const uint32_t nowMs = millis();
    if (nowMs - lastLogMs < 1000) {
        return;
    }

    const auto stats = displayEngine.stats();
    const uint32_t fps = stats.frameCounter - lastFrameCount;
    lastFrameCount = stats.frameCounter;
    lastLogMs = nowMs;

    Serial.printf(
        "display fps=%lu current=%lumA out=%lumA dps_q16=%lu render=%luus dropped=%lu driver=%s\r\n",
        static_cast<unsigned long>(fps),
        static_cast<unsigned long>(stats.lastEstimatedCurrentMa),
        static_cast<unsigned long>(stats.lastOutputCurrentMa),
        static_cast<unsigned long>(stats.lastDpsScaleQ16),
        static_cast<unsigned long>(stats.lastRenderUs),
        static_cast<unsigned long>(stats.droppedFrameCount),
        displayEngine.driverName());
}

void logHardwareStatus() {
    static uint32_t lastLogMs = 0;

    const uint32_t nowMs = millis();
    if (nowMs - lastLogMs < 500) {
        return;
    }
    lastLogMs = nowMs;

    const auto stats = hardwareMonitor.stats();
    Serial.printf(
        "hw battery=%.3fV adc=%lumV charge=%.3fV charging=%u charge_adc=%lumV buttons=0x%02x raw=(%u,%u) adc_samples=%lu q_ovf=%lu\r\n",
        hardwareMonitor.batteryVoltage(),
        static_cast<unsigned long>(hardwareMonitor.batteryAdcMilliVolts()),
        hardwareMonitor.chargeVoltage(),
        hardwareMonitor.isCharging(),
        static_cast<unsigned long>(hardwareMonitor.chargeAdcMilliVolts()),
        hardwareMonitor.currentButtonMask(),
        stats.lastBatteryRaw,
        stats.lastChargeRaw,
        static_cast<unsigned long>(stats.adcSampleCount),
        static_cast<unsigned long>(stats.queueOverflowCount));
}

void logAssetStatus() {
    static uint32_t lastLogMs = 0;

    const uint32_t nowMs = millis();
    if (nowMs - lastLogMs < 2000) {
        return;
    }
    lastLogMs = nowMs;

    const auto settings = assetManager.settings();
    const auto stats = assetManager.stats();
    Serial.printf(
        "asset mounted=%u loaded=%u dirty=%u brightness=%u cap=%u face=%u flush=%lu/%lu fail=%lu\r\n",
        stats.mounted,
        stats.settingsLoaded,
        stats.settingsDirty,
        settings.brightnessPct,
        settings.brightnessCap,
        settings.faceIndex,
        static_cast<unsigned long>(stats.flushSuccessCount),
        static_cast<unsigned long>(stats.flushAttemptCount),
        static_cast<unsigned long>(stats.flushFailureCount));
}

void logNetworkStatus() {
    static uint32_t lastLogMs = 0;

    const uint32_t nowMs = millis();
    if (nowMs - lastLogMs < 3000) {
        return;
    }
    lastLogMs = nowMs;

    const auto stats = networkManager.stats();
    Serial.printf(
        "net ap=%u http=%u udp=%u dns=%u clients=%u http_req=%lu udp_pkt=%lu dns_pkt=%lu m370=%lu/%lu q_ovf=%lu\r\n",
        stats.apStarted,
        stats.httpStarted,
        stats.udpStarted,
        stats.dnsStarted,
        WiFi.softAPgetStationNum(),
        static_cast<unsigned long>(stats.httpRequests),
        static_cast<unsigned long>(stats.udpPackets),
        static_cast<unsigned long>(stats.dnsPackets),
        static_cast<unsigned long>(stats.m370Accepted),
        static_cast<unsigned long>(stats.m370Rejected),
        static_cast<unsigned long>(stats.queueOverflow));
}

void logAppLogicStatus() {
    static uint32_t lastLogMs = 0;

    const uint32_t nowMs = millis();
    if (nowMs - lastLogMs < 2000) {
        return;
    }
    lastLogMs = nowMs;

    const auto stats = appLogic.stats();
    Serial.printf(
        "app mode=%s auto=%u rnt=%u face=%u overlays=0x%02x tick=%lu compose=%lu compose_us=%lu rnt_frames=%lu rnt_err=%lu\r\n",
        rina::AppLogic::modeName(stats.mode),
        stats.autoMode,
        stats.rntActive,
        stats.faceIndex,
        stats.activeOverlays,
        static_cast<unsigned long>(stats.tickCount),
        static_cast<unsigned long>(stats.composeCount),
        static_cast<unsigned long>(stats.lastComposeUs),
        static_cast<unsigned long>(stats.rntFrameCount),
        static_cast<unsigned long>(stats.rntDecodeErrorCount));
}

void renderTaskMain(void*) {
    esp_task_wdt_add(nullptr);
    TickType_t wake = xTaskGetTickCount();
    uint32_t delayAccumulatorUs = 0;

    while (true) {
        if (displayEngine.renderTick()) {
            logDisplayStats();
        }
        esp_task_wdt_reset();
        delayAccumulatorUs += rina::config::FRAME_PERIOD_US;
        const uint32_t delayMs = delayAccumulatorUs / 1000UL;
        delayAccumulatorUs -= delayMs * 1000UL;
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(delayMs));
    }
}

void networkTaskMain(void*) {
    if (!networkManager.begin()) {
        Serial.println("NetworkManager failed to start AP/HTTP/UDP");
    } else {
        const IPAddress ip = WiFi.softAPIP();
        Serial.printf(
            "NetworkManager AP ssid=%s ip=%u.%u.%u.%u http=%u udp=%u\r\n",
            rina::config::AP_SSID,
            ip[0],
            ip[1],
            ip[2],
            ip[3],
            rina::config::HTTP_PORT,
            rina::config::LOCAL_UDP_PORT);
    }

    esp_task_wdt_add(nullptr);
    TickType_t wake = xTaskGetTickCount();
    while (true) {
        networkManager.setRuntimeSnapshot(appLogic.networkSnapshot());
        logNetworkStatus();
        esp_task_wdt_reset();
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(rina::config::NETWORK_TASK_PERIOD_MS));
    }
}

void assetIoTaskMain(void*) {
    assetManager.setIoTaskHandle(xTaskGetCurrentTaskHandle());
    esp_task_wdt_add(nullptr);

    while (true) {
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(rina::config::ASSET_IO_TASK_PERIOD_MS));
        assetManager.serviceIo();
        logAssetStatus();
        esp_task_wdt_reset();
    }
}

void appLogicTaskMain(void*) {
    esp_task_wdt_add(nullptr);
    TickType_t wake = xTaskGetTickCount();

    while (true) {
        appLogic.tick();
        logHardwareStatus();
        logAppLogicStatus();
        esp_task_wdt_reset();
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(rina::config::APP_LOGIC_TICK_MS));
    }
}

bool startCoreTasks() {
    BaseType_t ok = xTaskCreatePinnedToCore(
        renderTaskMain,
        "RenderTask",
        rina::config::RENDER_TASK_STACK_WORDS,
        nullptr,
        rina::config::RENDER_TASK_PRIORITY,
        &LedRenderTask,
        rina::config::RENDER_TASK_CORE);
    if (ok != pdPASS) {
        return false;
    }

    ok = xTaskCreatePinnedToCore(
        networkTaskMain,
        "NetworkTask",
        rina::config::NETWORK_TASK_STACK_WORDS,
        nullptr,
        rina::config::NETWORK_TASK_PRIORITY,
        &NetworkTask,
        rina::config::NETWORK_TASK_CORE);
    if (ok != pdPASS) {
        return false;
    }

    ok = xTaskCreatePinnedToCore(
        assetIoTaskMain,
        "AssetIoTask",
        rina::config::ASSET_IO_TASK_STACK_WORDS,
        nullptr,
        rina::config::ASSET_IO_TASK_PRIORITY,
        &AssetIoTask,
        rina::config::ASSET_IO_TASK_CORE);
    if (ok != pdPASS) {
        return false;
    }

    ok = xTaskCreatePinnedToCore(
        appLogicTaskMain,
        "AppLogicTask",
        rina::config::APP_LOGIC_TASK_STACK_WORDS,
        nullptr,
        rina::config::APP_LOGIC_TASK_PRIORITY,
        &AppLogicTask,
        rina::config::APP_LOGIC_TASK_CORE);
    return ok == pdPASS;
}

}  // namespace

void setup() {
    Serial.begin(115200);

    if (esp_task_wdt_init((rina::config::WDT_TIMEOUT_MS + 999U) / 1000U, true) != ESP_OK) {
        Serial.println("Task watchdog initialization failed");
    }

    if (!assetManager.begin(false)) {
        Serial.println("AssetManager failed to mount LittleFS; upload the data image with `pio run -t uploadfs`");
    } else {
        const auto settings = assetManager.settings();
        const auto stats = assetManager.stats();
        Serial.printf(
            "settings loaded=%u brightness=%u cap=%u face=%u auto=%u interval=%.2fs power=%lumA\r\n",
            stats.settingsLoaded,
            settings.brightnessPct,
            settings.brightnessCap,
            settings.faceIndex,
            settings.autoMode,
            settings.intervalS,
            static_cast<unsigned long>(settings.powerBudgetMa));
    }

    displayEngine.begin();

    if (!hardwareMonitor.begin()) {
        Serial.println("HardwareMonitor failed to start");
    }

    if (!appLogic.begin(displayEngine, assetManager, hardwareMonitor, networkManager)) {
        Serial.println("AppLogic failed to start");
    }

    if (!startCoreTasks()) {
        Serial.println("FreeRTOS task creation failed");
    }
}

void loop() {
    vTaskDelay(pdMS_TO_TICKS(1000));
}
