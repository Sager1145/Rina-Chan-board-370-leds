#pragma once

#include <Arduino.h>

// FreeRTOS synchronization helpers
// Existing code intentionally avoids nested mutexes. If a future change must
// nest them, keep one global order: Scroll -> Frame -> Storage -> HardwareBus.

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
