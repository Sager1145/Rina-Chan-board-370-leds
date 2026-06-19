/*
 * File Description: main.cpp
 * Main entry point of the ESP32-S3 firmware.
 *
 * Responsibilities:
 * - Coordinates hardware initialization (NeoPixel/RMT, GPIOs, ADC, SPIFFS/LittleFS).
 * - Spawns the dedicated LED rendering/scrolling task on Core 1.
 * - Schedules all network services (WiFi AP, HTTP WebServer) and device diagnostics on Core 0.
 * - Runs the cooperative main scheduler in loop() to service queues, inputs, power, and state.
 *
 * Core Interactions:
 * - Mutexes from sync.h guard access to shared frame buffers and filesystem resources.
 * - PlatformIO core affinities restrict networking to Core 0 to prevent NeoPixel RMT signal degradation.
 */
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
#include "serial_log.h"
#include "serial_console.h"
#include <freertos/task.h>

static bool g_syncReady = false;

// LED, LittleFS, buttons, power monitoring, and Web API, scheduling the control plane in the Core 0 main loop.

// Setup

void setup() {
    // Read floating level and latch random bright spots.
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, LOW);
    delay(LED_BOOT_DATA_LOW_HOLD_MS);
    delayMicroseconds(LED_SIGNAL_RESET_US);

    Serial.begin(115200);
    delay(200);
    runtimeState().bootMs = millis();

    // Bring up the diagnostic logger + serial test console early (both no-ops
    // when their feature gates are 0). Non-blocking; only adds serial output.
    initSerialConsole();
    RLOG_INFO("SYS", "event=boot stage=serial_ready");

    // All rely on RuntimeStore already owning this memory.
    initRuntimeScrollFrameBuffer();

    // Both LittleFS and LED bus access depend on these locks for protection.
    g_syncReady = initSyncPrimitives();
    if (!g_syncReady) {
        Serial.println("FATAL: FreeRTOS mutexes unavailable; render task disabled, running single-core");
        showFilesystemErrorPattern();
    }

    initLedIndexMap();

    ledStripBegin();
    delay(LED_BOOT_CLEAR_HOLD_MS);

    // Avoid race conditions between blank frames rendered by tasks and startup frames on the WS2812 bus.
    setColorStateNoRender(DEFAULT_COLOR);

    // Diagnostic light effects, convenient for locating issues when no serial port is available.
    if (!mountFilesystem()) {
        showFilesystemErrorPattern();
    } else {
        loadRuntimeSettings();
        loadSavedFaces(true);
    }

    // Prevent tasks from repeatedly brushing the same frame after waking up.
    renderCurrentFrameToLedStrip();
    consumeLedRenderRequest();
    delay(LED_BOOT_STARTUP_SETTLE_MS);

    // Isolated from the WebServer and button polling.
    if (g_syncReady) startScrollRenderTask();

    initHardwareButtons();

    // Take a sample before opening the routes.
    initPowerMonitor();

    // All ready, clients can read the complete state once connected.
    startAccessPoint();
    startWebServer();

    RLOG_INFO("SYS", "event=boot stage=ready faces=%u mode=%s",
              static_cast<unsigned>(runtimeAutoFaceCount()), runtimeState().mode.c_str());
}

// Main loop
// WebServer/HTTP, buttons, power, and frame queues are cooperatively scheduled here; Core 1 is reserved
// for the LED render/scroll task to prevent network loads from disrupting WS2812/RMT timings.

void loop() {
    // After stabilizing, perform deferred recovery and auto playback.
    serviceM370FrameQueue();
    if (!g_syncReady) {
        renderCurrentFrameToLedStrip();
    }
    webServerTick();
    serviceRuntimeSlowStatePublish();
    serviceHardwareButtons();
    serviceSerialConsole();
    serviceButtonAnimations();
    servicePowerMonitor();
    serviceDeferredFaceRestore();
    serviceAutoPlayback();
    vTaskDelay(pdMS_TO_TICKS(1));
}
