#include "sync.h"
#include "state.h"

void lockFrame() {
    if (frameMutex) xSemaphoreTake(frameMutex, portMAX_DELAY);
}

void unlockFrame() {
    if (frameMutex) xSemaphoreGive(frameMutex);
}

void lockScroll() {
    if (scrollMutex) xSemaphoreTake(scrollMutex, portMAX_DELAY);
}

void unlockScroll() {
    if (scrollMutex) xSemaphoreGive(scrollMutex);
}
