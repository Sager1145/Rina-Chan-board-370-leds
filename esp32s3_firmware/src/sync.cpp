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

// Storage (SPI flash / LittleFS) access is coupled with the HardwareBus (WS2812
// transmit) lock. Every flash transaction -- read, write, exists, open, size,
// close, usedBytes scan -- transiently disables the flash cache on BOTH cores. If
// that disable window overlaps an in-flight strip.show() on the Core-1 render task,
// the WS2812 bit timing is corrupted and the LED panel garbles ("乱码") while the
// WebUI is refreshed during a text scroll. Holding the HardwareBus mutex for the
// whole flash section makes flash access and strip.show() strictly mutually
// exclusive, so a cache disable can never coincide with an LED transmit.
//
// Lock order is preserved: the documented global order is
// Scroll -> Frame -> Storage -> HardwareBus, and HardwareBus is acquired here
// AFTER Storage (innermost), so this introduces no new ordering and cannot
// deadlock. strip.show() takes HardwareBus alone and never touches flash, so the
// only interaction is: a flash op waits for an in-progress show() to finish (and
// vice versa). Storage critical sections are never nested, so HardwareBus is never
// re-taken by the same task. Callers must therefore NOT take HardwareBus again
// inside a Storage-locked section.
void lockStorage() {
    if (sStorageMutex) xSemaphoreTake(sStorageMutex, portMAX_DELAY);
    if (sHardwareBusMutex) xSemaphoreTake(sHardwareBusMutex, portMAX_DELAY);
}

void unlockStorage() {
    if (sHardwareBusMutex) xSemaphoreGive(sHardwareBusMutex);
    if (sStorageMutex) xSemaphoreGive(sStorageMutex);
}

void lockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreTake(sHardwareBusMutex, portMAX_DELAY);
}

void unlockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreGive(sHardwareBusMutex);
}
