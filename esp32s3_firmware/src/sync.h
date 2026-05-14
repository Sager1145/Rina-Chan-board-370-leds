#pragma once

// ---------------------------------------------------------------------------
// FreeRTOS synchronization helpers
// ---------------------------------------------------------------------------

void lockFrame();
void unlockFrame();
void lockScroll();
void unlockScroll();

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
