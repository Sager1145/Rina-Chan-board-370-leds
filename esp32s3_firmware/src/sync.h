#pragma once

#include <Arduino.h>

// ---------------------------------------------------------------------------
// FreeRTOS synchronization helpers
// ---------------------------------------------------------------------------
//
// This module is the shared concurrency boundary between the Core-0 control
// loop (HTTP, buttons, storage and power polling) and the Core-1 LED render
// task.  Keep all mutex ownership routed through this file so future module
// connections can be audited from one place.
//
// Lock ordering policy for future nested critical sections:
//   HardwareBus -> Frame -> Scroll
//
// Current render paths intentionally avoid holding more than one of these
// mutexes at a time.  If a future change must nest them, always acquire in the
// order above and release in reverse order.

enum class SyncDomain : uint8_t {
    Frame,
    Scroll,
    HardwareBus,
};

/**
 * @brief RAII guard for one firmware mutex.
 * @param domain Shared resource guarded for the lifetime of this object.
 * @return Constructs a guard that releases the selected mutex in its destructor.
 */
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

/**
 * @brief Create all FreeRTOS mutexes used by firmware modules.
 * @param None.
 * @return true when every mutex was created or already existed.
 */
bool initSyncPrimitives();

/**
 * @brief Acquire the packed-frame/runtime-render mutex.
 * @param None.
 * @return None.
 */
void lockFrame();

/**
 * @brief Release the packed-frame/runtime-render mutex.
 * @param None.
 * @return None.
 */
void unlockFrame();

/**
 * @brief Acquire the firmware-scroll timeline mutex.
 * @param None.
 * @return None.
 */
void lockScroll();

/**
 * @brief Release the firmware-scroll timeline mutex.
 * @param None.
 * @return None.
 */
void unlockScroll();

/**
 * @brief Acquire the shared hardware bus mutex used for LED and LittleFS calls.
 * @param None.
 * @return None.
 */
void lockHardwareBus();

/**
 * @brief Release the shared hardware bus mutex.
 * @param None.
 * @return None.
 */
void unlockHardwareBus();

/**
 * @brief Run a callable while holding the frame mutex.
 * @param fn Work that reads or writes runtime frame/color state.
 * @return Whatever fn returns.
 */
template <typename Fn>
auto withFrameLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Frame);
    return fn();
}

/**
 * @brief Run a callable while holding the scroll mutex.
 * @param fn Work that reads or writes firmware scroll state.
 * @return Whatever fn returns.
 */
template <typename Fn>
auto withScrollLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::Scroll);
    return fn();
}

/**
 * @brief Run a callable while holding the shared hardware bus mutex.
 * @param fn Work that touches LittleFS, NeoPixel show, or another shared bus.
 * @return Whatever fn returns.
 */
template <typename Fn>
auto withHardwareBusLock(Fn fn) -> decltype(fn()) {
    ScopedLock lock(SyncDomain::HardwareBus);
    return fn();
}
