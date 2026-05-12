#pragma once

// ---------------------------------------------------------------------------
// Firmware scroll render task
// ---------------------------------------------------------------------------

// FreeRTOS task body — do not call directly.
void scrollRenderTask(void* parameter);

// Create and pin the scroll render task to LED_RENDER_TASK_CORE.
// Safe to call multiple times; only the first call has effect.
void startScrollRenderTask();
