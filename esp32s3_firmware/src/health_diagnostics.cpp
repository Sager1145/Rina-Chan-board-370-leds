#include "health_diagnostics.h"

#if DEBUG_HEALTH

#include <esp_heap_caps.h>
#include <esp_system.h>
#include "serial_log.h"   // RLOG_* (non-blocking, host-gated)
#include "state.h"        // runtimeState(), scroll frame count
#include "config.h"

static TaskHandle_t sRenderTask = nullptr;
static uint32_t     sLastEmitMs  = 0;
static uint32_t     sMinFreeEver = 0xFFFFFFFFu;   // tracked across the whole run

static const char* resetReasonName(esp_reset_reason_t r) {
    switch (r) {
        case ESP_RST_POWERON:   return "POWERON";
        case ESP_RST_EXT:       return "EXT";
        case ESP_RST_SW:        return "SW";
        case ESP_RST_PANIC:     return "PANIC";        // exception / abort()
        case ESP_RST_INT_WDT:   return "INT_WDT";      // interrupt watchdog
        case ESP_RST_TASK_WDT:  return "TASK_WDT";     // task watchdog (starved loop/render)
        case ESP_RST_WDT:       return "OTHER_WDT";
        case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
        case ESP_RST_BROWNOUT:  return "BROWNOUT";     // power/battery sag
        case ESP_RST_SDIO:      return "SDIO";
        default:                return "UNKNOWN";
    }
}

void healthDiagnosticsSetRenderTask(TaskHandle_t handle) {
    sRenderTask = handle;
}

void healthDiagnosticsBegin() {
    const esp_reset_reason_t reason = esp_reset_reason();
    RLOG_WARN("HEALTH", "event=boot reset_reason=%s psram_total=%u",
              resetReasonName(reason),
              static_cast<unsigned>(ESP.getPsramSize()));
    sLastEmitMs = millis();
    // Force one health line shortly after boot so a baseline is captured.
    sLastEmitMs -= (DEBUG_HEALTH_INTERVAL_MS - 2000);
}

void serviceHealthDiagnostics() {
    const uint32_t now = millis();
    if (now - sLastEmitMs < DEBUG_HEALTH_INTERVAL_MS) return;
    sLastEmitMs = now;

    const uint32_t freeHeap     = ESP.getFreeHeap();
    const uint32_t minFreeHeap  = ESP.getMinFreeHeap();
    const uint32_t maxAlloc     = ESP.getMaxAllocHeap();
    const uint32_t free8        = heap_caps_get_free_size(MALLOC_CAP_8BIT);
    const uint32_t largest8     = heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
    const uint32_t internalFree = heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    const uint32_t internalLrg  = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);

    if (freeHeap < sMinFreeEver) sMinFreeEver = freeHeap;

    // Fragmentation ratio: 100 = no fragmentation (largest == free), lower = worse.
    const uint32_t fragPct = internalFree ? (internalLrg * 100U) / internalFree : 100U;

    // Stack high-water marks: smaller = closer to overflow. Reported in BYTES.
    const uint32_t loopHWM   = uxTaskGetStackHighWaterMark(nullptr) * sizeof(StackType_t);
    const uint32_t renderHWM = sRenderTask
        ? uxTaskGetStackHighWaterMark(sRenderTask) * sizeof(StackType_t) : 0;

    RLOG_WARN("HEALTH",
              "event=heap freeHeap=%u minFreeEver=%u minFreeHeap=%u maxAlloc=%u "
              "intFree=%u intLargest=%u fragPct=%u",
              static_cast<unsigned>(freeHeap),
              static_cast<unsigned>(sMinFreeEver),
              static_cast<unsigned>(minFreeHeap),
              static_cast<unsigned>(maxAlloc),
              static_cast<unsigned>(internalFree),
              static_cast<unsigned>(internalLrg),
              static_cast<unsigned>(fragPct));

    RLOG_WARN("HEALTH",
              "event=psram_stack psramFree=%u psramLargest=%u "
              "loopStackFreeB=%u renderStackFreeB=%u",
              static_cast<unsigned>(ESP.getFreePsram()),
              static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM)),
              static_cast<unsigned>(loopHWM),
              static_cast<unsigned>(renderHWM));

    // Cumulative-state / drop telemetry that hints at queue starvation or churn.
    RLOG_WARN("HEALTH",
              "event=runtime uptimeMs=%u scrollFrames=%u framesDropped=%u "
              "framesQueued=%u framesDequeued=%u",
              static_cast<unsigned>(now - runtimeState().bootMs),
              static_cast<unsigned>(runtimeState().scrollFrameCount),
              static_cast<unsigned>(runtimeState().framesDropped),
              static_cast<unsigned>(runtimeState().framesQueued),
              static_cast<unsigned>(runtimeState().framesDequeued));

    (void)free8; (void)largest8;  // exposed above via the 8BIT-cap variants
}

#endif  // DEBUG_HEALTH
