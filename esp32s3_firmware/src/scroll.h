#pragma once

// ---------------------------------------------------------------------------
// Firmware scroll render task
// ---------------------------------------------------------------------------

// Create and pin the scroll render task to LED_RENDER_TASK_CORE.
// Safe to call multiple times; only the first call has effect.
void startScrollRenderTask();
