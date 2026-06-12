#include "sync.h"
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>


// 本文件封装 FreeRTOS mutex 和跨核心同步保护；注释保留必要 English identifier，便于和代码/API 对照。
static SemaphoreHandle_t sFrameMutex       = nullptr;
static SemaphoreHandle_t sScrollMutex      = nullptr;
static SemaphoreHandle_t sHardwareBusMutex = nullptr;

static void lockDomain(SyncDomain domain) {
    switch (domain) {
        case SyncDomain::Frame:
            lockFrame();
            break;
        case SyncDomain::Scroll:
            lockScroll();
            break;
        case SyncDomain::HardwareBus:
            lockHardwareBus();
            break;
    }
}

static void unlockDomain(SyncDomain domain) {
    switch (domain) {
        case SyncDomain::Frame:
            unlockFrame();
            break;
        case SyncDomain::Scroll:
            unlockScroll();
            break;
        case SyncDomain::HardwareBus:
            unlockHardwareBus();
            break;
    }
}

ScopedLock::ScopedLock(SyncDomain domain) : domain_(domain) {
    lockDomain(domain_);
    locked_ = true;
}

ScopedLock::~ScopedLock() {
    if (locked_) {
        unlockDomain(domain_);
    }
}

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
