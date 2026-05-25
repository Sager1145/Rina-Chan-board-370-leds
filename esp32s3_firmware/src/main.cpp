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

// ---------------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------------

/**
 * @brief Boot firmware modules in the order required by hardware and state dependencies.
 * @param None.
 * @return None.
 */
void setup() {
    // Hold the WS2812/SK6812 data line low immediately after reset.
    // Without this early clamp, the line can float during Serial startup and
    // the LEDs may latch a random first frame before strip.begin() clears them.
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, LOW);
    delay(LED_BOOT_DATA_LOW_HOLD_MS);
    delayMicroseconds(LED_SIGNAL_RESET_US);

    Serial.begin(115200);
    delay(200);
    runtimeState().bootMs = millis();

    // RuntimeStore must own scroll buffers before WebUI/API routes can upload
    // scroll frames or the render task can read them.
    initRuntimeScrollFrameBuffer();

    // Synchronization is initialized before any module can cross Core 0/Core 1
    // boundaries through runtime state, scroll state, LittleFS, or the LED bus.
    if (!initSyncPrimitives()) {
        Serial.println("Failed to create one or more FreeRTOS mutexes");
    }

    // Build logical-to-physical LED index map
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

    // Hardware buttons feed both state-changing actions and overlay animations,
    // so initialize them after playback state exists but before normal loop().
    initHardwareButtons();

    // Power monitor publishes battery/charge state into WebUI status and the B6
    // overlay, so seed its first sample before HTTP routes start answering.
    initPowerMonitor();

    // Networking is last: every route should see initialized storage, playback,
    // render queues, buttons, and power state as soon as clients connect.
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

/**
 * @brief Service Core-0 control-plane modules cooperatively.
 * @param None.
 * @return None.
 */
void loop() {
    // Ordering matters: frame queues publish before web/status polling, and
    // deferred face restore/auto playback run after button/API effects from
    // this iteration have had a chance to settle.
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
