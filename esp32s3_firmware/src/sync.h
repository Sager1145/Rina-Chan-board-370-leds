#pragma once

#include <Arduino.h>


// 本文件封装 FreeRTOS mutex 和跨核心同步保护；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// FreeRTOS 同步辅助函数（FreeRTOS synchronization helpers）
// ---------------------------------------------------------------------------
// Existing code intentionally avoids nested mutexes. If a future change must
// nest them, keep one global order: Scroll -> Frame -> HardwareBus.

enum class SyncDomain : uint8_t {
    Frame,
    Scroll,
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
