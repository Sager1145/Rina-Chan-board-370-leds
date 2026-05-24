#include <Arduino.h>

#include "config.h"
#include "state.h"
#include "sync.h"
#include "led_renderer.h"
#include "storage.h"
#include "faces.h"
#include "scroll.h"
#include "buttons.h"
#include "web_api.h"
#include "power_monitor.h"
#include <freertos/task.h>

// ---------------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------------

void setup() {
    Serial.begin(115200);
    delay(200);
    runtimeState().bootMs = millis();

    initRuntimeScrollFrameBuffer();

    // FreeRTOS primitives
    if (!initSyncPrimitives()) {
        Serial.println("Failed to create one or more FreeRTOS mutexes");
    }

    // Build logical→physical LED index map
    initLedIndexMap();

    // Initialize the LED strip: clear, latch, then hold long enough for the
    // BSS138 level shifter to settle before we write the first real frame.
    ledStripBegin();
    delay(LED_BOOT_CLEAR_HOLD_MS);

    // Set the default color without scheduling a render.  During boot, the
    // first physical frame after the all-off latch should be the startup saved
    // face, not an extra task-rendered blank frame that can race on the WS2812
    // bus through the BSS138.
    setColorStateNoRender(DEFAULT_COLOR);

    // Mount filesystem, load settings and saved faces
    if (!mountFilesystem()) {
        showFilesystemErrorPattern();
    } else {
        loadRuntimeSettings();
        loadSavedFaces(true);
    }

    // Render the first non-blank boot frame synchronously before starting the
    // render task, then drain the queued request left by loadSavedFaces /
    // applyM370 so the task does not double-render on wakeup.
    renderCurrentFrameToLedStrip();
    consumeLedRenderRequest();
    delay(LED_BOOT_STARTUP_SETTLE_MS);

    // Spawn the Core-1 LED render / scroll task
    startScrollRenderTask();

    // Initialize hardware buttons
    initHardwareButtons();

    // Initialize battery / charge ADC monitoring
    initPowerMonitor();

    // Start networking and HTTP server
    startAccessPoint();
    startWebServer();
}

// ---------------------------------------------------------------------------
// loop  (Core 0)
// ---------------------------------------------------------------------------
// Runs on Core 0 because platformio.ini sets -D ARDUINO_RUNNING_CORE=0. This
// keeps all WebServer/HTTP, button, power and frame-queue work off Core 1, which
// is reserved exclusively for the LED render/scroll task. Do NOT remove that
// build flag: without it arduino-esp32 puts loop() on Core 1, where the HTTP
// load disrupts WS2812 transmit timing (garbled / torn frames while scrolling).

void loop() {
    serviceM370FrameQueue();
    webServerTick();
    serviceRuntimeSlowStatePublish();
    serviceHardwareButtons();
    servicePowerMonitor();
    serviceDeferredFaceRestore();
    serviceAutoPlayback();
    vTaskDelay(pdMS_TO_TICKS(1));
}
