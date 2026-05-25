#pragma once

// ---------------------------------------------------------------------------
// Firmware scroll render task
// ---------------------------------------------------------------------------

/**
 * @brief Create and pin the scroll render task to LED_RENDER_TASK_CORE.
 * @param None.
 * @return None.
 */
void startScrollRenderTask();

/**
 * @brief Wake the render task after a frame request.
 * @param None.
 * @return None.
 */
void notifyScrollRenderTask();
