#pragma once

// ---------------------------------------------------------------------------
// FreeRTOS synchronization helpers
// ---------------------------------------------------------------------------

bool initSyncPrimitives();

void lockFrame();
void unlockFrame();
void lockScroll();
void unlockScroll();
void lockHardwareBus();
void unlockHardwareBus();

template <typename Fn>
void withFrameLock(Fn fn) {
    lockFrame();
    fn();
    unlockFrame();
}

template <typename Fn>
void withScrollLock(Fn fn) {
    lockScroll();
    fn();
    unlockScroll();
}

template <typename Fn>
void withHardwareBusLock(Fn fn) {
    lockHardwareBus();
    fn();
    unlockHardwareBus();
}
