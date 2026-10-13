#pragma once

bool startScrollRenderTask();

// One render/scroll iteration, used by the task or the cooperative fallback.
void serviceScrollRender();

void notifyScrollRenderTask();
