#pragma once

#include <Arduino.h>

// FreeRTOS synchronization helpers.
// Global nesting order: Scroll -> Frame -> Storage -> HardwareBus.
// Storage lock intentionally also owns HardwareBus because LittleFS flash I/O
// can stall cache/bus access long enough to disturb WS2812 output if the LED
// transmit (leddrv::refresh()) overlaps static-file or JSON file reads/writes.

enum class SyncDomain : uint8_t {
    Frame,
    Scroll,
    Storage,
    HardwareBus,
};

class ScopedLock final {
  public:
    explicit ScopedLock(SyncDomain domain);
    ~ScopedLock();

    ScopedLock(const ScopedLock&) = delete;
    ScopedLock& operator=(const ScopedLock&) = delete;

  private:
    SyncDomain domain_;
    bool locked_ = false;
};

bool initSyncPrimitives();

void lockFrame();

void unlockFrame();

void lockScroll();

void unlockScroll();

void lockHardwareBus();

void unlockHardwareBus();

void lockStorage();

void unlockStorage();

template <typename Fn>
auto withFrameLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Frame);
    return fn();
}

template <typename Fn>
auto withScrollLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Scroll);
    return fn();
}

template <typename Fn>
auto withHardwareBusLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::HardwareBus);
    return fn();
}

template <typename Fn>
auto withStorageLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Storage);
    return fn();
}
