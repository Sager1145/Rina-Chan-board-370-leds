#include "sync.h"
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

static SemaphoreHandle_t sFrameMutex       = nullptr;
static SemaphoreHandle_t sScrollMutex      = nullptr;
static SemaphoreHandle_t sHardwareBusMutex = nullptr;

// Map the public domain enum to the legacy lock functions.  Keeping the switch
// local avoids leaking FreeRTOS semaphore details into modules that only need a
// scoped ownership comment and a predictable release point.
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

// Mirror lockDomain() so ScopedLock destructors always release the same
// resource they acquired, even when a helper grows new early returns later.
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
    // Create each mutex once during setup(), but keep this idempotent so a
    // future recovery path can call it safely after partial initialization.
    if (!sFrameMutex) sFrameMutex = xSemaphoreCreateMutex();
    if (!sScrollMutex) sScrollMutex = xSemaphoreCreateMutex();
    if (!sHardwareBusMutex) sHardwareBusMutex = xSemaphoreCreateMutex();
    return sFrameMutex && sScrollMutex && sHardwareBusMutex;
}

void lockFrame() {
    // Frame state connects API/button writers to the Core-1 renderer; blocking
    // here is intentional because partially-written packed bits would display
    // visibly corrupted LED frames.
    if (sFrameMutex) xSemaphoreTake(sFrameMutex, portMAX_DELAY);
}

void unlockFrame() {
    if (sFrameMutex) xSemaphoreGive(sFrameMutex);
}

void lockScroll() {
    // Scroll state is advanced by the render task and mutated by HTTP/buttons.
    // Serialize the timeline counters so frame index and frame count stay paired.
    if (sScrollMutex) xSemaphoreTake(sScrollMutex, portMAX_DELAY);
}

void unlockScroll() {
    if (sScrollMutex) xSemaphoreGive(sScrollMutex);
}

void lockHardwareBus() {
    // NeoPixel show() and LittleFS operations are both timing/bus-sensitive in
    // this firmware.  The shared mutex prevents long flash/file operations from
    // interleaving with the LED transmit critical path.
    if (sHardwareBusMutex) xSemaphoreTake(sHardwareBusMutex, portMAX_DELAY);
}

void unlockHardwareBus() {
    if (sHardwareBusMutex) xSemaphoreGive(sHardwareBusMutex);
}
