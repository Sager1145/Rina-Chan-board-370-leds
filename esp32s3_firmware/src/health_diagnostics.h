#pragma once
/*
 * health_diagnostics.h
 * Lightweight, opt-in long-runtime health probe for the Rina-Chan board.
 *
 * Logs heap / PSRAM fragmentation, per-task stack high-water marks, frame-drop
 * counters, and the boot reset reason. Designed to find slow leaks, heap
 * fragmentation, and stack-overflow margins that only manifest after hours/days.
 *
 * Enable by building with -D DEBUG_HEALTH=1 (or editing the default below).
 * When DEBUG_HEALTH=0 every call compiles to nothing.
 *
 * Wire-up (main.cpp):
 *   #include "health_diagnostics.h"
 *   // end of setup():            healthDiagnosticsBegin();
 *   // register the render task:  healthDiagnosticsSetRenderTask(<handle>);  // optional
 *   // once per loop():           serviceHealthDiagnostics();
 */
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#ifndef DEBUG_HEALTH
#define DEBUG_HEALTH 0
#endif

#ifndef DEBUG_HEALTH_INTERVAL_MS
#define DEBUG_HEALTH_INTERVAL_MS 30000  // emit one health line every 30 s
#endif

#if DEBUG_HEALTH

// Call once at the end of setup(). Logs the reset reason immediately.
void healthDiagnosticsBegin();

// Optional: hand the module the render-task handle so it can report that task's
// stack high-water mark. If never called, only the loop task is reported.
void healthDiagnosticsSetRenderTask(TaskHandle_t handle);

// Call once per loop(). Cheap: it only does work every DEBUG_HEALTH_INTERVAL_MS.
void serviceHealthDiagnostics();

#else  // DEBUG_HEALTH == 0  -> all no-ops

inline void healthDiagnosticsBegin() {}
inline void healthDiagnosticsSetRenderTask(TaskHandle_t) {}
inline void serviceHealthDiagnostics() {}

#endif
