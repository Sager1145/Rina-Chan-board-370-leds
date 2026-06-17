#include "sync.h"
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

static SemaphoreHandle_t sFrameMutex       = nullptr;
static SemaphoreHandle_t sScrollMutex      = nullptr;
static SemaphoreHandle_t sStorageMutex     = nullptr;
static SemaphoreHandle_t sHardwareBusMutex = nullptr;

static void lockDomain(SyncDomain domain) {
    switch (domain) {
        case SyncDomain::Frame:
            lockFrame();
            break;
        case SyncDomain::Scroll:
            lockScroll();
            break;
        case SyncDomain::Storage:
            lockStorage();
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
        case SyncDomain::Storage:
            unlockStorage();
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
    if (!sStorageMutex) sStorageMutex = xSemaphoreCreateMutex();
    if (!sHardwareBusMutex) sHardwareBusMutex = xSemaphoreCreateMutex();
    return sFrameMutex && sScrollMutex && sStorageMutex && sHardwareBusMutex;
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

void lockStorage() {
    if (sStorageMutex) xSemaphoreTake(sStorageMutex, portMAX_DELAY);
}

void unlockStorage() {
    if (sStorageMutex) xSemaphoreGive(sStorageMutex);
}

void lockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreTake(sHardwareBusMutex, portMAX_DELAY);
}

void unlockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreGive(sHardwareBusMutex);
}
