#pragma once

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

void startScrollRenderTask();

void notifyScrollRenderTask();

// Render-task handle for diagnostics (stack high-water mark). Null until the
// task has been started by startScrollRenderTask().
TaskHandle_t scrollRenderTaskHandle();
