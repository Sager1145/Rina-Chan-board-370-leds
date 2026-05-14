#include "sync.h"
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

static SemaphoreHandle_t sFrameMutex       = nullptr;
static SemaphoreHandle_t sScrollMutex      = nullptr;
static SemaphoreHandle_t sHardwareBusMutex = nullptr;

bool initSyncPrimitives() {
    if (!sFrameMutex) sFrameMutex = xSemaphoreCreateMutex();
    if (!sScrollMutex) sScrollMutex = xSemaphoreCreateMutex();
    if (!sHardwareBusMutex) sHardwareBusMutex = xSemaphoreCreateMutex();
    return sFrameMutex && sScrollMutex && sHardwareBusMutex;
}

void lockFrame() {
    if (sFrameMutex) xSemaphoreTake(sFrameMutex, portMAX_DELAY);
}

void unlockFrame() {
    if (sFrameMutex) xSemaphoreGive(sFrameMutex);
}

void lockScroll() {
    if (sScrollMutex) xSemaphoreTake(sScrollMutex, portMAX_DELAY);
}

void unlockScroll() {
    if (sScrollMutex) xSemaphoreGive(sScrollMutex);
}

void lockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreTake(sHardwareBusMutex, portMAX_DELAY);
}

void unlockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreGive(sHardwareBusMutex);
}
