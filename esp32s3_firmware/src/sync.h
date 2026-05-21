#pragma once

// ---------------------------------------------------------------------------
// FreeRTOS synchronization helpers
// ---------------------------------------------------------------------------
//
// Lock ordering policy for future nested critical sections:
//   HardwareBus -> Frame -> Scroll
//
// Current render paths intentionally avoid holding more than one of these
// mutexes at a time.  If a future change must nest them, always acquire in the
// order above and release in reverse order.

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
