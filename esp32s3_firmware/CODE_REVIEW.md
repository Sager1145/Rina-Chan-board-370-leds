# ESP32-S3 Firmware — Code Review & Architecture Analysis

**Project:** Rina-Chan Board V2 — 370-LED Matrix  
**Review Date:** 2026-05-25  
**Files Reviewed:** 14 source files across `src/`  
**Reviewer:** Senior C++ / Embedded Architect (AI-assisted review)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Module Architecture Map](#2-module-architecture-map)
3. [Lock-Ordering Policy & Concurrency Model](#3-lock-ordering-policy--concurrency-model)
4. [Structural Findings](#4-structural-findings)
   - 4.1 [Positives & Strong Patterns](#41-positives--strong-patterns)
   - 4.2 [Issues & Recommendations](#42-issues--recommendations)
5. [Module-by-Module Analysis](#5-module-by-module-analysis)
   - 5.1 [config.h / config.cpp](#51-configh--configcpp)
   - 5.2 [state.h / state.cpp](#52-stateh--statecpp)
   - 5.3 [sync.h / sync.cpp](#53-synch--synccpp)
   - 5.4 [led_renderer.h / led_renderer.cpp](#54-led_rendererh--led_renderercpp)
   - 5.5 [scroll.h / scroll.cpp](#55-scrollh--scrollcpp)
   - 5.6 [faces.h / faces.cpp](#56-facesh--facescpp)
   - 5.7 [buttons.h / buttons.cpp](#57-buttonsh--buttonscpp)
   - 5.8 [button_animations.h / button_animations.cpp](#58-button_animationsh--button_animationscpp)
   - 5.9 [storage.h / storage.cpp](#59-storageh--storagecpp)
   - 5.10 [power_monitor.h / power_monitor.cpp](#510-power_monitorh--power_monitorcpp)
   - 5.11 [web_api.h / web_api.cpp](#511-web_apih--web_apicpp)
   - 5.12 [web_json.h / web_json.cpp](#512-web_jsonh--web_jsoncpp)
   - 5.13 [utils.h / utils.cpp](#513-utilsh--utilscpp)
   - 5.14 [psram_json.h](#514-psram_jsonh)
6. [Specific Code Observations](#6-specific-code-observations)
7. [Prioritized Recommendations](#7-prioritized-recommendations)

---

## 1. Executive Summary

The Rina-Chan Board ESP32-S3 firmware is a well-engineered, dual-core embedded system
driving a 370-LED hexagonal matrix over WS2812/SK6812 protocol. The codebase
demonstrates thoughtful hardware-aware design: Core-0 exclusively services HTTP, buttons,
power ADC, and state management, while Core-1 is pinned to a single real-time render/scroll
task that meets WS2812 timing constraints even under Wi-Fi load.

**Overall Quality: High.** The code is production-quality for its target domain. Synchronization
is handled through well-placed FreeRTOS mutexes and an ISR-safe portMUX, the M370 codec
and frame queuing system are robust, and the LittleFS I/O paths include atomic commit
semantics (temp-file-then-rename). The commentary throughout is thorough.

**Key risks and improvement areas identified:**

| Severity | Count | Summary |
|----------|-------|---------|
| HIGH     |  1    | 144 KB static SRAM array in `RuntimeStore` on the BSS |
| MEDIUM   |  5    | Code duplication in `web_api.cpp`; `storage→faces` layering; `power_monitor` duplicating directory creation; O(n²) sort at startup; missing `nullptr` guard in `RuntimeStore::scrollFrameBits()` |
| LOW / STYLE | 8 | Various minor readability, const-correctness, and redundancy notes |

No memory-safety bugs, race conditions, or undefined behavior were found.

---

## 2. Module Architecture Map

The firmware is organized into clean functional layers. Arrows show direct compile-time
dependencies (i.e., which module `#include`s another's header).

```
┌─────────────────────────────────────────────────────────┐
│                      main.cpp                           │
│  setup() → boot sequence (ordered by hardware deps)     │
│  loop()  → Core-0 cooperative service round             │
└────┬─────┬──────┬──────┬──────┬──────┬──────┬──────────┘
     │     │      │      │      │      │      │
     ▼     ▼      ▼      ▼      ▼      ▼      ▼
 config  state  sync  led_   scroll  faces  buttons  web_api
   .h     .h    .h   renderer  .h     .h     .h       .h
              │      .h  │
              │      │   │ (Core-1 task)
              │      ▼   ▼
              │   [NeoPixel strip.show()]
              │
              ▼
         button_animations.h
              │
              ▼
         power_monitor.h ─────────────────────────────┐
                                                       │
         storage.h ←── (LittleFS R/W)                 │
              │                                        │
              └─────────────────────────────────────────┘
                         (both read powerStatus directly)

Utility layer (no state, pure functions):
  utils.h ← used by led_renderer, storage, faces, web_api
  web_json.h ← used by web_api only
  psram_json.h ← used by state, storage, web_api
```

### Data-flow summary

```
WebUI/API (Core-0, web_api.cpp)
    │  POST /api/frame  →  applyM370()  →  enqueuePackedM370Frame()
    │  POST /api/scroll →  write runtimeScrollFrameBits()  →  startFirmwareScroll()
    │  POST /api/command →  command handler table
    ▼
RuntimeStore (singleton, state.h/cpp)
  ├─ RuntimeState   ← mode, playback, color, brightness, scroll counters, deferred restore
  ├─ RuntimeFace[]  ← loaded saved faces (max 128)
  ├─ frameBits[]    ← currently displayed packed 370-bit frame (FRAME_BYTES = 47 bytes)
  └─ scrollFrameBits[] ← up to 3072 packed frames in PSRAM or static SRAM fallback

Core-0 loop() services (buttons.cpp, faces.cpp, power_monitor.cpp, led_renderer.cpp)
    │  applyM370 / applyPackedFrame → frameQueue → publishPackedFrameNow()
    │  requestLedRender() → sets ledRenderRequested flag + notifies Core-1 task
    ▼
Core-1 scrollRenderTask() (scroll.cpp)
    │  consumeLedRenderRequest()  → renderCurrentFrameToLedStrip()
    │  scroll timer advance       → memcpy nextFrame → renderCurrentFrameToLedStrip()
    ▼
renderCurrentFrameToLedStrip() (led_renderer.cpp)
    │  snapshot frameBits + color/brightness under frameMutex
    │  copyButtonAnimationOverlay() → may override with overlay RGB
    │  delayMicroseconds(LED_SIGNAL_RESET_US)
    │  withHardwareBusLock → strip.show()
    └  delayMicroseconds(LED_SIGNAL_RESET_US)
```

---

## 3. Lock-Ordering Policy & Concurrency Model

The firmware uses three FreeRTOS mutexes plus one portMUX, intentionally documented
with a strict acquire-order to prevent future deadlocks:

```
Acquire order (must always go left-to-right when nesting):
  HardwareBus → Frame → Scroll

portMUX (ledRenderRequestMux):
  ISR-safe flag for render-request; never held concurrently with any mutex.

portMUX (sAnimMux):
  Protects AnimationState snapshot in button_animations.cpp.
  Never held concurrently with any FreeRTOS mutex.
```

**Current paths respect this order.** No nested acquisitions of more than one
FreeRTOS mutex were found anywhere in the code. The scroll task acquires
`scrollMutex` then `frameMutex` in sequence (releases scroll before taking
frame), which is consistent with the declared ordering.

The `sAnimMux` portMUX sections are short (scalar copy only) and never call into
any module that could re-enter a FreeRTOS API, which is correct for a non-ISR
critical section on the ESP32.

---

## 4. Structural Findings

### 4.1 Positives & Strong Patterns

These design decisions are explicitly called out as correct and should be preserved.

#### Meyers Singleton for `RuntimeStore`
`RuntimeStore::instance()` uses a function-local static, which is thread-safe under C++11
and avoids global constructor ordering hazards that are common on Arduino-based platforms.

```cpp
// state.cpp — correct singleton pattern
RuntimeStore& RuntimeStore::instance() {
    static RuntimeStore store;
    return store;
}
```

#### RAII `ScopedLock` + template wrappers
The `withFrameLock` / `withScrollLock` / `withHardwareBusLock` template helpers guarantee
mutex release even when a lambda returns early, without requiring callers to manually call
`unlock`. This is idiomatic modern C++ and prevents unlock-on-all-paths bugs.

#### Pre-computed logical-to-physical LED index map
`initLedIndexMap()` computes the serpentine row remapping once at boot and stores it in
`logicalToPhysicalMap[LED_COUNT]`. This removes a per-pixel row-walk from every render
loop iteration. The render path is correctly O(LED_COUNT) not O(LED_COUNT × MATRIX_ROWS).

#### ISR-safe render request flag (`portMUX`)
`requestLedRender()` correctly switches between `portENTER_CRITICAL_ISR` and
`portENTER_CRITICAL` depending on `xPortInIsrContext()`. The flag variable is `volatile bool`,
which is appropriate for a value written in ISR context and read from task context under the
same portMUX.

#### Atomic JSON file commit (temp-file-then-rename)
`writeJsonFileAtomic()` writes to a `.tmp` sibling, then renames it into place. On LittleFS
this prevents a power-loss from leaving a half-written file at the canonical path. The temp
file is removed before opening (to clear a stale previous attempt) and again on failure.

#### PSRAM-preferring ArduinoJson allocator (`psram_json.h`)
`SpiRamAllocator` tries `MALLOC_CAP_SPIRAM` first and falls back to `MALLOC_CAP_8BIT`.
This keeps large JSON documents (status responses, saved-faces editor payloads) in PSRAM,
freeing SRAM for stack and FreeRTOS bookkeeping.

#### Battery ADC: trimmed-mean sampling + time-delta EMA
`readTrimmedAdcMilliVolts()` takes 16 samples, sorts them, and averages the center 8.
The battery EMA uses `alpha = 1 - exp(-dt / tau)` rather than a fixed alpha, so the
20-second effective smoothing window is correct regardless of actual call frequency.
This is significantly better than the typical embedded fixed-alpha filter.

#### Drop-oldest frame-queue policy
When the M370 ring buffer overflows, the *oldest* frame is dropped, not the newest command.
For live animation controls this is the correct choice: the most-recent user intent should
always win, and the display converges to the current state within one `M370_FRAME_QUEUE_DEPTH`
cycle rather than being stuck showing stale frames.

#### Gzip pre-compressed static asset serving
`serveStaticFile()` checks for a `.gz` sibling and negotiates based on the client's
`Accept-Encoding` header. Serving gzip-compressed WebUI assets from LittleFS is
essential at 80 MHz with only 4 MB flash and a synchronous WebServer; this design
is correct and well-implemented.

---

### 4.2 Issues & Recommendations

Issues are labeled **HIGH**, **MEDIUM**, or **LOW**.

---

#### [HIGH] 144 KB static fallback SRAM array in `RuntimeStore`

**File:** `state.h` line 218  
**Finding:**
```cpp
// state.h
uint8_t fallbackScrollFrameBits_[MAX_SCROLL_FRAMES][FRAME_BYTES] = {};
// MAX_SCROLL_FRAMES = 3072, FRAME_BYTES = 47 → 3072 * 47 = 144,384 bytes
```
This array is a member of the Meyers singleton `RuntimeStore`. It lives in BSS and is
therefore always allocated regardless of whether PSRAM is available. On an ESP32-S3 with
512 KB SRAM, consuming 144 KB for a rarely-used fallback leaves only ~368 KB for all
other allocations, FreeRTOS task stacks, the heap, and the Wi-Fi TCP/IP stack.

**Risk:** The Wi-Fi stack alone needs approximately 60–100 KB. With 144 KB pre-committed
to the fallback buffer, boards without PSRAM may not have enough memory to bring up the
AP and WebServer at the same time, causing silent allocation failures downstream.

**Recommendation:** Move the fallback allocation to `initScrollFrameBuffer()` using
`heap_caps_malloc(MALLOC_CAP_8BIT)` instead of embedding it as a fixed static member.
Only allocate it when PSRAM is unavailable and the PSRAM path actually fails.

```cpp
// Proposed change in RuntimeStore (state.h):
// Remove:    uint8_t fallbackScrollFrameBits_[MAX_SCROLL_FRAMES][FRAME_BYTES] = {};
// Replace member with:
//            uint8_t* sramFallbackBits_ = nullptr;

// In RuntimeStore::initScrollFrameBuffer() (state.cpp):
if (scrollFrameBits_ == nullptr) {
    // Only try heap SRAM as a last resort; print the real byte cost.
    sramFallbackBits_ = static_cast<uint8_t*>(
        heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_8BIT));
    if (sramFallbackBits_) {
        scrollFrameBits_ = sramFallbackBits_;
        scrollFrameBitsInPsram_ = false;
    }
    // If this also fails, scrollFrameBufferReady() returns false → scroll disabled.
}
```

This change converts a guaranteed SRAM cost into a conditional runtime allocation,
and allows `scrollFrameBufferReady()` to correctly return `false` instead of
silently committing 144 KB the firmware might not have.

---

#### [MEDIUM] Duplicated `/resources` directory-creation logic

**Files:** `storage.cpp` (line 33–40 `ensureResourcesDirectory()`) and
`power_monitor.cpp` (lines 187–190 inside `saveBatteryCalibration()`).

`power_monitor.cpp` duplicates the `LittleFS.exists("/resources") || LittleFS.mkdir("/resources")`
pattern inline rather than calling the `ensureResourcesDirectory()` helper that
already exists in `storage.cpp`. If the path changes or a different error-handling
strategy is needed, it must be updated in two places.

**Recommendation:** Move `ensureResourcesDirectory()` from a `static` function in
`storage.cpp` to a non-static function declared in `storage.h`, then call it from
`power_monitor.cpp`.

---

#### [MEDIUM] `storage → faces` layering violation

**File:** `storage.cpp` lines 163–167 in `loadRuntimeSettings()`  
**Finding:**
```cpp
// storage.cpp calls setMode() from faces.h — a higher-layer module
const char* mode = doc["mode"] | DEFAULT_MODE;
if (!setMode(mode, false)) setMode(DEFAULT_MODE, false);
```
`storage` should sit below `faces` in the dependency graph (storage loads raw data; faces
interprets it as playback state). This circular include is avoided at the header level
because `storage.h` does not include `faces.h`, but the runtime call goes upward.

**Recommendation:** Have `loadRuntimeSettings()` return a `RuntimeSettingsData` struct
containing the raw mode string, and let the call site (`main.cpp::setup()` → currently
`loadRuntimeSettings()` directly) call `setMode()` after `loadRuntimeSettings()` returns.
This removes the upward call and makes the data-flow explicit.

---

#### [MEDIUM] Missing initialized-state guard in `RuntimeStore::scrollFrameBits()`

**File:** `state.cpp` lines 58–73  
**Finding:**
```cpp
uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) {
    if (index >= MAX_SCROLL_FRAMES) return nullptr;
    // If scrollFrameBits_ is nullptr (initScrollFrameBuffer was never called),
    // the fallback pointer is used, which is fine IF the static array exists
    // but is silent about the uninitialized case.
    uint8_t* buffer = scrollFrameBits_ != nullptr
        ? scrollFrameBits_
        : &fallbackScrollFrameBits_[0][0];
    return buffer + (static_cast<size_t>(index) * FRAME_BYTES);
}
```
After the proposed [HIGH] fix above (removing the static fallback array),
`fallbackScrollFrameBits_` will no longer exist as a member. Callers that invoke
`runtimeScrollFrameBits()` before `initScrollFrameBuffer()` would then access a
null pointer. The fix is already implied by the proposed change: after making
`scrollFrameBits_` the only buffer pointer (set by `initScrollFrameBuffer()`), all
paths that pass through `scrollFrameBufferReady()` will be safe.

Even without the [HIGH] fix, adding a comment here explaining the two-path design
would help future maintainers.

---

#### [MEDIUM] O(n²) bubble sort in `loadSavedFaces()`

**File:** `storage.cpp` lines 385–397  
**Finding:**
```cpp
// O(n²) insertion-style sort over runtimeAutoFaces
for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
    for (uint16_t j = i + 1; j < runtimeAutoFaceCount(); ++j) {
        if (shouldSwap) { /* swap */ }
    }
}
```
With `MAX_AUTO_FACES = 128` the worst case is 8,128 iterations. This only runs
once per `loadSavedFaces()` call (boot + face editor save), so it is not a
performance concern at this scale. However, it is worth noting for future-proofing.

**Recommendation:** Replace with `std::sort` using a lambda comparator, which the
ESP32 Arduino core supports via `<algorithm>`. This shrinks the code and documents
the sort key explicitly:

```cpp
#include <algorithm>

std::sort(
    runtimeAutoFaces(),
    runtimeAutoFaces() + runtimeAutoFaceCount(),
    [](const RuntimeFace& a, const RuntimeFace& b) {
        // Primary: order field; secondary: original JSON index for stable tie-breaking.
        return a.order < b.order || (a.order == b.order && a.jsonIndex < b.jsonIndex);
    }
);
```

---

#### [MEDIUM] JSON reply assembly duplicated across three route handlers

**File:** `web_api.cpp`  
**Finding:** Three route handlers — `handleApiStatus()`, `handleApiFrame()`, and
`handleApiCommand()` — each independently assemble overlapping JSON response fields:
- `autoFaceId` / `autoFaceName` guard block (three copies)
- `scrollStopEvent` nested object (two copies in `handleApiStatus` and `handleApiCommand`)
- version fields (`v` and `version` — duplicated key for compatibility, appears five times)

**Recommendation:** Extract small inline helpers:
```cpp
// Add to web_api.cpp internal helpers:
static void addAutoFaceFields(JsonObject& obj) {
    if (runtimeAutoFaceCount() > 0 && runtimeState().autoFaceIndex < runtimeAutoFaceCount()) {
        obj["autoFaceId"]   = runtimeAutoFaces()[runtimeState().autoFaceIndex].id;
        obj["autoFaceName"] = runtimeAutoFaces()[runtimeState().autoFaceIndex].name;
    }
}

static void addScrollStopEvent(JsonObject& obj) {
    JsonObject ev = obj.createNestedObject("scrollStopEvent");
    ev["seq"]    = runtimeState().scrollStopEventSeq;
    ev["ms"]     = runtimeState().scrollStopEventMs;
    ev["button"] = runtimeState().scrollStopEventButton;
    ev["source"] = runtimeState().scrollStopEventSource;
    ev["reason"] = runtimeState().scrollStopEventReason;
}

static void addVersionFields(JsonObject& obj, uint32_t version) {
    obj["v"]       = version;       // short form for WebUI fast path
    obj["version"] = version;       // long form for debuggability
}
```

---

#### [LOW] `parseColorHex()` performs redundant hex validation

**File:** `utils.cpp` lines 33–45  
**Finding:**
```cpp
// First pass: validate all 6 chars are hex
for (size_t i = 0; i < 6; ++i) {
    if (hexNibble(value.charAt(i)) < 0) return false;
}
// Then toLowerCase() + strtoul() — parses the same chars a second time
value.toLowerCase();
r = static_cast<uint8_t>(strtoul(value.substring(0, 2).c_str(), nullptr, 16));
```
The validation loop confirms all characters are valid hex, then `toLowerCase()` +
`strtoul()` re-parses them. Additionally, `strtoul` on an Arduino `String::c_str()`
creates three temporary `String` objects via `substring()`.

**Recommendation:** Eliminate the intermediate `String` objects and parse directly
using the already-validated `hexNibble()` results:
```cpp
bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b) {
    String value = input;
    value.trim();
    if (value.startsWith("#")) value = value.substring(1);
    if (value.length() != 6) return false;

    int nibbles[6];
    for (size_t i = 0; i < 6; ++i) {
        nibbles[i] = hexNibble(value.charAt(i));
        if (nibbles[i] < 0) return false;
    }
    r = static_cast<uint8_t>((nibbles[0] << 4) | nibbles[1]);
    g = static_cast<uint8_t>((nibbles[2] << 4) | nibbles[3]);
    b = static_cast<uint8_t>((nibbles[4] << 4) | nibbles[5]);
    return true;
}
```

---

#### [LOW] `startOverlay()` manually copies each field instead of struct assignment

**File:** `button_animations.cpp` lines 514–536  
**Finding:**
```cpp
void startOverlay(const AnimationState& next) {
    portENTER_CRITICAL(&sAnimMux);
    sAnim.active = true;
    sAnim.kind = next.kind;
    sAnim.startedMs = next.startedMs;
    // ... 12 more individual assignments
    portEXIT_CRITICAL(&sAnimMux);
}
```
The portMUX section protects a copy of the entire `AnimationState` struct. A struct
assignment (`sAnim = next; sAnim.active = true;`) under the portMUX is functionally
identical and much shorter. There is no benefit to copying field-by-field here because
a struct assignment is not interruptible at the C++ level on Xtensa-LX7 (the compiler
emits a `memcpy`-style sequence that is protected by the portMUX just as well).

```cpp
void startOverlay(const AnimationState& next) {
    portENTER_CRITICAL(&sAnimMux);
    sAnim = next;       // single struct assignment under the critical section
    sAnim.active = true; // force active in case caller forgot to set it
    portEXIT_CRITICAL(&sAnimMux);
    pauseScrollForOverlay();
    requestLedRender();
}
```

---

#### [LOW] `serviceButtonAnimations()` expiry check uses magic constant for overflow guard

**File:** `button_animations.cpp` lines 674–675  
**Finding:**
```cpp
if ((sAnim.kind != OverlayKind::Battery &&
     now - sAnim.expiresMs < 0x80000000UL &&   // ← magic constant
     now >= sAnim.expiresMs) || ...)
```
`0x80000000UL` is half the `uint32_t` range, used to guard against the case where
`millis()` has wrapped past `expiresMs`. The logic is correct (it prevents interpreting
a post-wraparound `expiresMs` as "already expired"), but the magic number is opaque.

**Recommendation:** Replace with a named constant or a helper:
```cpp
// In the anonymous namespace at the top of button_animations.cpp:
// millis() wraps at ~49.7 days. If the elapsed time since expiresMs exceeds half
// the uint32_t range we assume the clock has not yet reached expiresMs.
constexpr uint32_t MILLIS_HALF_RANGE = 0x80000000UL;

inline bool millisPast(uint32_t now, uint32_t targetMs) {
    return (now - targetMs) < MILLIS_HALF_RANGE;
}
```

---

#### [LOW] `applyFirmwareScrollPauseIntentLocked()` unconditionally sets `firmwareScrollActive = true`

**File:** `faces.cpp` lines 389–391  
**Finding:**
```cpp
static void applyFirmwareScrollPauseIntentLocked() {
    // ... early return guard for truly idle state ...
    runtimeState().firmwareScrollActive = true;   // ← always set true
    runtimeState().firmwareScrollPaused = effectivePaused;
    ...
}
```
This function is only called from `setFirmwareScrollPauseFlag()`, which is itself
only called from `setFirmwareScrollUserPaused()` / `setFirmwareScrollSystemPaused()`.
Both callers check `runtimeState().firmwareScrollActive` before deciding whether
to call scroll-pause helpers in `button_animations.cpp`. The unconditional
`firmwareScrollActive = true` could activate scroll unexpectedly if the pause flags
are set when `scrollFrameCount == 0` but `firmwareScrollActive` was already `false`.
The early-return guard does protect this specific case, but the logic is fragile.

**Recommendation:** Add an explicit guard:
```cpp
// Only re-assert scroll active if there are frames to play.
if (runtimeState().scrollFrameCount > 0) {
    runtimeState().firmwareScrollActive = true;
}
```

---

#### [LOW] `handleApiStatus()` is 180+ lines — should be split

**File:** `web_api.cpp` lines 434–611  
The handler assembles six nested JSON objects (ap, power, renderer, memory, matrix, storage,
stats, endpoints) inline in one function. While the code is readable, a future change to any
sub-object requires modifying a single 180-line function.

**Recommendation:** Extract a `buildRendererStatus()`, `buildStorageStatus()`, and
`buildMatrixStatus()` helper to match the existing `addPowerStatus()` pattern. Each helper
receives a `JsonObject` by value and fills it from the appropriate module's state.

---

## 5. Module-by-Module Analysis

### 5.1 `config.h` / `config.cpp`

**Role:** Single source of truth for all hardware pin assignments, timing constants,
matrix geometry, and network/filesystem paths.

**Design notes:**
- `constexpr` is used correctly throughout. All numeric constants are typed (e.g.,
  `constexpr uint8_t BRIGHTNESS_BUTTON_STEP = 8`) rather than raw `#define` macros,
  which preserves type safety.
- The `static_assert` verifying that `ROW_OFFSETS[MATRIX_ROWS-1] + ROW_LENGTHS[MATRIX_ROWS-1] == LED_COUNT`
  is excellent defensive practice — it catches matrix layout misconfigurations at compile time.
- `IPAddress` objects are defined in `config.cpp` (not `config.h`) because `IPAddress` is
  not a literal type on all Arduino cores and cannot be constexpr. The inline reference
  accessors (`apIP()`, `apGateway()`, `apSubnet()`) expose them without requiring a
  `config.h`-to-Arduino-WiFi dependency in every translation unit.
- `BATTERY_CALIB_SHRINK_TIMEOUT_MS` (7 days in ms) is computed with `UL` suffixed
  multiplication which is correct — without the suffix, the intermediate products would
  overflow `int` on 32-bit systems before the expression is promoted.

**Connection to other modules:** This is a leaf node; no other module's header is included
here (except `<IPAddress.h>` for the IPAddress declarations, which is isolated to `config.cpp`).
Every other module includes `config.h`.

---

### 5.2 `state.h` / `state.cpp`

**Role:** Owns the singleton `RuntimeStore` containing `RuntimeState`, `RuntimeFace[]`,
`frameBits[]`, and the scroll-frame buffer. Provides free-function accessors so callers
do not need to know about the singleton directly.

**Design notes:**
- `RuntimeState` is a plain aggregate with default member initializers, making it safe
  under Arduino's static-init model.
- The `RuntimeFace` struct keeps only the fields needed for runtime navigation/playback.
  Raw JSON is never held in memory; it is re-read from LittleFS only when the editor
  needs it. This is the right memory budget strategy for a microcontroller.
- `touchRuntimeState()` / `touchRuntimeStateSlow()` / `serviceRuntimeSlowStatePublish()`
  implement a two-tier dirty-tracking scheme that rate-limits WebUI `stateVersion` bumps
  for slow-changing fields (power, brightness), while fast fields (frame changes, mode
  toggles) publish immediately. This reduces unnecessary HTTP long-poll responses.
- The `stateVersion` overflow guard (`if (stateVersion == 0) stateVersion = 1`) correctly
  skips zero, which the WebUI uses as the "no version yet" sentinel.

**Issue:** The 144 KB static fallback array (see §4.2 [HIGH]).

**Connections:**
- Written by: `led_renderer`, `faces`, `buttons`, `storage`, `power_monitor`, `web_api`
- Read by: every module
- Protected by: `frameMutex` (for `frameBits_`) and `scrollMutex` (for scroll counters),
  both managed through `sync.h`

---

### 5.3 `sync.h` / `sync.cpp`

**Role:** Centralizes all FreeRTOS synchronization. Provides three FreeRTOS mutexes
and one portMUX, wrapped in an RAII `ScopedLock` and template `withXxxLock()` helpers.

**Design notes:**
- `ScopedLock` is `final` and non-copyable, which prevents accidental lock duplication.
- The `locked_` flag in `ScopedLock` ensures the destructor is safe even if the constructor
  fails partway through (though mutex creation failure is handled at `initSyncPrimitives()`
  before any `ScopedLock` is used).
- `initSyncPrimitives()` is idempotent (null-checks before creating), which is good for
  potential future re-init paths.
- Lock-ordering policy is documented in the header comment. This is critical documentation
  that should never be removed.

**Connections:** `sync.h` is included by `led_renderer`, `faces`, `buttons`,
`button_animations`, `storage`, `power_monitor`, `web_api`, and `scroll`. All shared-state
access flows through this module.

---

### 5.4 `led_renderer.h` / `led_renderer.cpp`

**Role:** Owns the Adafruit NeoPixel `strip` object (the only module allowed to call
`strip.show()`), the M370 frame codec, the rate-limited frame queue, color/brightness
state, and the physical render path.

**Design notes:**
- The `Adafruit_NeoPixel strip` is `static` (module-local). No other module can call
  `strip.show()` directly. This is correct encapsulation: it enforces that every render
  goes through `renderCurrentFrameToLedStrip()`, which owns the required timing delays.
- The M370 codec (`normalizeM370` → `decodeNormalizedM370ToPackedBits`) is called OUTSIDE
  the frame mutex in `applyM370()`. Only `memcpy(runtimeFrameBits(), packed, FRAME_BYTES)`
  happens under the lock. This is the correct approach — decoding 370 bits is too slow to
  do inside a mutex that the Core-1 render task also needs.
- `copyText()` is a safe bounded string copy that guarantees null-termination. This replaces
  what would otherwise be `strncpy()` (which does not null-terminate when the source is too long).
- `lastAppliedBrightness` static in `renderCurrentFrameToLedStrip()` avoids calling
  `strip.setBrightness()` (which rescales the entire pixel buffer) on every frame.

**Connections:**
- Consumed by: `scroll` (render task), `faces`, `buttons`, `storage`, `web_api`
- Consumes: `state`, `sync`, `scroll` (for `notifyScrollRenderTask`), `utils`, `button_animations`

---

### 5.5 `scroll.h` / `scroll.cpp`

**Role:** Creates and manages the Core-1 `scrollRenderTask`, which arbitrates between
scroll-timeline advancement and on-demand renders triggered from Core-0.

**Design notes:**
- The double-lock pattern (acquire `scrollMutex`, advance frame index, release; then acquire
  `frameMutex`, write to `runtimeFrameBits`, release) is correct. This ensures the render
  task does not overwrite a frame that Core-0 just committed via `applyM370`.
- The `mainTaskRenderPending` re-check inside `frameMutex` handles the TOCTOU window
  between releasing `scrollMutex` and acquiring `frameMutex`. This is a subtle but necessary
  race-condition guard: without it, one stale scroll frame could flash on the display.
- `ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1))` gives the task a 1 ms sleep when there is
  nothing to render, which keeps Core-1 mostly idle while scrolling is paused but wakes it
  promptly when `notifyScrollRenderTask()` fires.
- Scroll drift is handled by advancing `lastScrollFrameMs` by exactly `intervalMs` (grid-lock)
  unless the backlog exceeds `SCROLL_DRIFT_RESET_INTERVALS * intervalMs`, in which case it
  resets to `now`. This prevents burst-rendering multiple frames after a scheduling stall.

**Connections:** Consumes `state`, `sync`, `config`, `led_renderer`.

---

### 5.6 `faces.h` / `faces.cpp`

**Role:** Manages saved-face navigation, auto-playback, mode switching, firmware scroll
lifecycle, and deferred face restore after blank frames.

**Design notes:**
- `normalizedMode()` accepts Chinese locale strings ("自动"/"手动") as aliases. This is
  intentional for the WebUI which uses locale-specific mode labels.
- The deferred-restore mechanism (blank frame → 90 ms hold → apply saved face) avoids
  `delay()` in HTTP handlers or button callbacks. The two-stage approach (set flag →
  service from `loop()`) is correct for cooperative multitasking on Core-0.
- `applyFirmwareScrollPauseIntentLocked()` is always called under `scrollMutex`, which
  is correct since it reads and writes multiple scroll-state fields atomically.
- `stopFirmwareScroll()` does a full state reset under `scrollMutex`, then conditionally
  applies a blank frame and schedules a deferred face restore. The lock is released before
  the blank-frame path to avoid holding `scrollMutex` across an I/O or render call.

**Connections:** Consumes `state`, `sync`, `config`, `led_renderer`, `storage`.
Called by: `buttons`, `button_animations`, `web_api`.

---

### 5.7 `buttons.h` / `buttons.cpp`

**Role:** GPIO polling and debounce, button combo detection (B3+B1, B3+B2), hold-repeat
for face navigation (B1/B2) and brightness (B4/B5), and the `runButtonAction()` dispatcher
shared with the WebUI API.

**Design notes:**
- `runButtonAction()` is exposed publicly so the WebUI (`api_button` command) can simulate
  button presses with the same logic path as GPIO. This eliminates a parallel implementation.
- Combo detection is handled on the *press* edge of B1/B2 when B3 is already held, and
  marks both buttons as `comboConsumed` so their releases do not also fire solo actions.
- The `isScrollInterruptButton()` / `markScrollStoppedByButton()` mechanism publishes a
  monotonic sequence number (`scrollStopEventSeq`) that the WebUI can poll to detect that
  a GPIO button stopped the scroll. This avoids a heavyweight event queue for this specific
  notification need.
- `serviceHardwareButtons()` feeds debounced B6/B2/B3 states to `serviceButtonAnimationButtonInputs()`
  *after* all edge processing, so the overlay module always sees the settled debounced state,
  not raw GPIO levels.

**Connections:** Consumes `state`, `config`, `led_renderer`, `faces`, `button_animations`.

---

### 5.8 `button_animations.h` / `button_animations.cpp`

**Role:** Manages the LED overlay system (Mode/Interval/Brightness/Battery overlays),
B6 short/long-press battery display logic, scroll pause-for-overlay, and the pixel renderer
for overlay frames.

**Design notes:**
- The anonymous `namespace { }` is used correctly to hide all internal state and helpers.
  Only the six public functions (`startButtonAnimationForGpioAction`, etc.) are exported.
- `xyToLogical()` maps the virtual 22×18 overlay canvas to the physical LED index
  accounting for the non-uniform row widths (via `ROW_LENGTHS[y]` and centering math).
  This is elegant: overlay designers can work in a uniform 22×18 grid without knowing
  the physical matrix shape.
- The `sAnimMux` portMUX (not a FreeRTOS mutex) is correct here because `copyButtonAnimationOverlay()`
  is called from the Core-1 render task, and a FreeRTOS mutex cannot be taken from a task
  at a higher priority than the task that took it on the other core. The portMUX approach
  is correct for cross-core atomic snapshot.
- Battery color interpolation uses linear RGB gradient across three threshold bands.
  Using `lroundf()` for the brightness percent conversion is correct to avoid truncation bias.
- The `drawBatteryIcon()` animate path uses `phaseMs / 200` column animation, producing
  a smooth fill-sweep during charging. The blink pattern for `< 10%` (`phaseMs / 300 % 2`)
  gives a 1.67 Hz blink without requiring a timer interrupt.

**Issue (LOW):** `startOverlay()` manual field-by-field copy (see §4.2).

**Connections:** Consumes `faces`, `led_renderer`, `power_monitor`, `state`, `sync`.
Called by: `buttons`, `led_renderer` (for overlay snapshot in render).

---

### 5.9 `storage.h` / `storage.cpp`

**Role:** LittleFS mount, atomic JSON file writes, runtime settings persistence, and
saved-faces loading/validation/writing.

**Design notes:**
- `loadSavedFaces()` re-validates each face's M370 string through `normalizeM370()` on load,
  so the runtime can never contain an invalid M370 that was written by a buggy previous
  version of the WebUI editor.
- Face index is preserved across reloads by `id`-matching the previous face; the fallback
  cascade is well-documented (startup default → first default → index 0).
- `validateSavedFaces()` enforces the `unified_saved_faces` category contract, 1-based order
  fields, and at least one `type: "default"` face before any write completes. This ensures
  the firmware can always recover to a known startup face after a power cycle.
- `PsramJsonDocument` is used for the large saved-faces parse. The capacity is computed
  from actual file size via `jsonCapacityFor()`, which returns `max(sourceBytes*2+4096, 32768)`.
  The 2× factor accounts for ArduinoJson's internal object tree overhead.

**Issue (MEDIUM):** Duplicated `/resources` directory creation (see §4.2).
**Issue (MEDIUM):** `storage→faces` layering (`setMode()` called from `loadRuntimeSettings()`).
**Issue (MEDIUM):** O(n²) sort (see §4.2).

**Connections:** Consumes `state`, `config`, `utils`, `led_renderer`, `faces`, `sync`, `psram_json`.
Called by: `main`, `web_api`, `faces` (ensureSavedFacesLoaded).

---

### 5.10 `power_monitor.h` / `power_monitor.cpp`

**Role:** ADC sampling for battery and charge lines, battery voltage EMA, disconnect
detection, piecewise-linear percent LUT, calibration persistence.

**Design notes:**
- `readTrimmedAdcMilliVolts()` uses `std::sort` from `<algorithm>`. This is correct
  for ESP32-S3 Arduino core which ships a full C++ standard library.
- Battery disconnect detection uses two criteria: a sudden large ADC drop (`>= BATTERY_DISCONNECT_ADC_DROP_MV`
  AND resulting value `<= BATTERY_DISCONNECT_ADC_LOW_MV`) OR a persistent low reading
  after a previous disconnect event. The hysteresis on reconnect (`>= BATTERY_RECONNECT_ADC_MV`)
  prevents oscillation at the threshold.
- The `vbat = NAN` reset on state transitions (disconnect recovery, low-voltage-unpowered
  recovery) forces the EMA to initialize from the live reading rather than ramping from
  the stale stored value. This is the correct behavior for state-change transitions.
- `updateBatteryCalibration()` is a stub (no-op with `(void)` suppression of unused params)
  with an extensive comment explaining that dynamic min/max learning was removed in favor
  of the fixed LUT. The code documents the *why* of a non-obvious design decision, which
  is excellent.
- `batteryPercentFromVoltage()` uses piecewise linear interpolation across the LUT. The
  `+/-1%` dead-band around `batteryPercent` prevents display jitter near segment boundaries.

**Issue (MEDIUM):** Duplicated `/resources` directory creation in `saveBatteryCalibration()`.

**Connections:** Consumes `state`, `config`, `sync`, `storage`. Exposes `powerStatus` global
read directly by `button_animations` and `web_api`.

---

### 5.11 `web_api.h` / `web_api.cpp`

**Role:** SoftAP/DNS startup, static file serving with gzip negotiation, and all HTTP
REST API routes (`/api/status`, `/api/frame`, `/api/scroll`, `/api/command`,
`/api/saved_faces`, `/api/power`).

**Design notes:**
- The `ApiCommandRoute` dispatch table (`API_COMMAND_ROUTES[]`) cleanly maps command name
  strings to handler function pointers. Adding a new command requires one table entry and
  one handler function, with no changes to the dispatch loop.
- `handleApiScroll()` manually parses the `frames` JSON array inline rather than using
  ArduinoJson. This is intentional: the frames array can contain thousands of M370 strings
  totaling hundreds of KB, which would exceed ArduinoJson's practical memory limits on the
  ESP32 for a full parse. The custom parser consumes the body in a streaming fashion,
  writing directly to `runtimeScrollFrameBits()` as it goes.
- `serveStaticFile()` correctly handles the path normalization (`"/" → "/index.html"`,
  path-with-trailing-slash → `+ "index.html"`), gzip preference, and the fallback to
  raw file when gzip is absent.
- `streamFileChunked()` allocates an 8 KB heap buffer for file streaming with a 512-byte
  stack fallback if `malloc()` fails. The watchdog yield (`vTaskDelay`) every 4 chunks
  prevents reset under large file transfers on a busy AP.
- The `FILESYSTEM_ERROR_HTML` literal is stored in `PROGMEM` to avoid consuming 800+ bytes
  of SRAM for a rarely-used error page.

**Issues:**
- [MEDIUM] JSON reply field duplication across route handlers.
- [LOW] `handleApiStatus()` length (180+ lines).

**Connections:** Consumes all modules. This is the top-level integration point.

---

### 5.12 `web_json.h` / `web_json.cpp`

**Role:** Lightweight raw-body JSON field extraction for the scroll upload path, which
cannot use ArduinoJson for the `frames` array due to memory constraints.

**Design notes:**
- `jsonFieldValuePosition()` does a simple string-search for `"key"` followed by `:`.
  This is intentionally a "good enough" parser for top-level fields in small command
  bodies. It does not handle fields inside nested objects, arrays, or escaped key names.
  This limitation is acceptable for its current use cases (booleans, integers, floats,
  and a single string field in the scroll body).
- `extractJsonStringAt()` correctly handles backslash escapes for the common JSON escape
  sequences. The `\uXXXX` (Unicode) case is left as its trailing character — this is noted
  in a comment and is acceptable because M370 frame strings contain only ASCII hex characters.

**Connections:** Consumed only by `web_api.cpp`.

---

### 5.13 `utils.h` / `utils.cpp`

**Role:** Pure stateless helpers: hex nibble parse, JSON capacity estimate, color hex
parse/format.

**Design notes:**
- `hexNibble()` is called in the hot path of `normalizeM370()` (370 times per M370 decode).
  Its lookup is a simple range check — no table, no branch misprediction concern.
- `jsonCapacityFor()` uses `max(sourceBytes * 2 + 4096, 32768)` as a conservative
  ArduinoJson capacity estimate. The 2× factor accounts for the JSON tree overhead;
  the 32 KB floor handles the case where a small file's 2× estimate is still too small.

**Issue (LOW):** Redundant hex validation in `parseColorHex()` (see §4.2).

---

### 5.14 `psram_json.h`

**Role:** PSRAM-preferring custom allocator for `BasicJsonDocument<SpiRamAllocator>`,
aliased as `PsramJsonDocument`.

**Design notes:**
- `allocate()` / `reallocate()` both try `MALLOC_CAP_SPIRAM` first, then fall back to
  `MALLOC_CAP_8BIT`. `heap_caps_free()` is used for deallocation (correct for both tiers).
- This header-only design is clean and composable. Using `BasicJsonDocument<SpiRamAllocator>`
  rather than overriding a global allocator keeps the custom allocation opt-in per document.

---

## 6. Specific Code Observations

Small-scale observations that do not rise to a structural finding but are worth noting
for future maintainers.

### 6.1 `constrain()` with Arduino macros

`constrain()` is used in `faces.cpp`, `web_api.cpp`, and `power_monitor.cpp`. On Arduino
the `constrain(x, lo, hi)` macro expands to `((x)<(lo)?(lo):((x)>(hi)?(hi):(x)))`. Because
`x` is evaluated up to three times, it is unsafe with expressions that have side effects.
In this codebase, only simple variables are passed to `constrain()`, so there is no bug.
However, the ESP32 Arduino core ships `<algorithm>`, so `std::clamp(x, lo, hi)` (C++17)
or `std::min(std::max(x, lo), hi)` is the preferred alternative.

### 6.2 `millis()` timestamp arithmetic and `int32_t` cast

`faces.cpp` line 346:
```cpp
if (static_cast<int32_t>(now - runtimeState().deferredFaceRestoreDueMs) < 0) return;
```
This correctly handles the case where `deferredFaceRestoreDueMs` is set in the future
by casting the unsigned difference to signed. This is the canonical Arduino pattern for
"is due time in the future?" The assumption is that the maximum due-time offset is less
than 2^31 ms (~24.9 days), which is always true here (`LED_STOP_CLEAR_BLANK_HOLD_MS = 90`).

### 6.3 `DynamicJsonDocument` vs `PsramJsonDocument`

Several places in `storage.cpp` and `power_monitor.cpp` use `DynamicJsonDocument` for
small documents (384–768 bytes capacity). Since these capacities are well within SRAM
headroom and the documents are short-lived, using `DynamicJsonDocument` rather than
`PsramJsonDocument` is fine. Consistency could be improved by using `StaticJsonDocument`
for truly compile-time-known small capacities.

### 6.4 String comparison in `playbackIsNonFaceActivity()`

```cpp
// faces.cpp
if (runtimeState().lastReason.startsWith("text_scroll_") ||
    runtimeState().lastReason.startsWith("custom_") || ...)
```
`String::startsWith()` is an O(n) case-insensitive scan. For the short reason strings
used here this is negligible, but it is worth noting that reason strings are not
validated/constrained, so a future module that sets a long reason string would make
these checks proportionally more expensive.

### 6.5 `showFilesystemErrorPattern()` in `web_api.cpp`

This function lights the first 12 LEDs red to signal a LittleFS mount failure before the
WebServer is up. It correctly calls `setFrameBit()` inside a `withFrameLock` lambda,
then requests a render. The function should arguably live in `led_renderer.cpp` (pure
renderer concern) rather than `web_api.cpp` (HTTP concern), but since it is only called
from `main.cpp::setup()` and `web_api.cpp::handleNotFound()`, its current location is
acceptable.

### 6.6 `normalizeM370()` String reservation

```cpp
String compact;
compact.reserve(M370_HEX_CHARS);  // pre-allocates 93 chars
```
Calling `reserve()` before the character-append loop prevents repeated heap reallocations
during the loop. This is correct performance practice for `String` on embedded targets.

---

## 7. Prioritized Recommendations

Listed in priority order. Items marked ✅ are already correct and should be preserved.

| # | Priority | File(s) | Action |
|---|----------|---------|--------|
| 1 | **HIGH** | `state.h` / `state.cpp` | Replace static `fallbackScrollFrameBits_[3072][47]` member with a runtime heap allocation in `initScrollFrameBuffer()`, freeing 144 KB of guaranteed SRAM. |
| 2 | **MEDIUM** | `storage.h/.cpp`, `power_monitor.cpp` | Move `ensureResourcesDirectory()` to `storage.h` (non-static), eliminating the duplicated mkdir logic in `saveBatteryCalibration()`. |
| 3 | **MEDIUM** | `storage.cpp`, `faces.h` | Decouple the `storage→faces` layering: have `loadRuntimeSettings()` return a settings struct; let `main.cpp` call `setMode()`. |
| 4 | **MEDIUM** | `web_api.cpp` | Extract `addAutoFaceFields()`, `addScrollStopEvent()`, and `addVersionFields()` helpers to eliminate JSON field duplication across route handlers. |
| 5 | **MEDIUM** | `storage.cpp` | Replace O(n²) bubble sort with `std::sort` + lambda. |
| 6 | **LOW** | `button_animations.cpp` | Replace manual field-by-field copy in `startOverlay()` with struct assignment under portMUX. |
| 7 | **LOW** | `button_animations.cpp` | Replace `0x80000000UL` magic constant with named `MILLIS_HALF_RANGE` and a `millisPast()` helper. |
| 8 | **LOW** | `utils.cpp` | Eliminate `parseColorHex()` double-parse by reusing `hexNibble()` results directly. |
| 9 | **LOW** | `faces.cpp` | Add `scrollFrameCount > 0` guard before `firmwareScrollActive = true` in `applyFirmwareScrollPauseIntentLocked()`. |
| 10 | **LOW** | `web_api.cpp` | Split `handleApiStatus()` into sub-helpers matching the existing `addPowerStatus()` pattern. |

**Items to preserve as-is (already optimal):**
- ✅ Meyers singleton in `RuntimeStore`
- ✅ RAII `ScopedLock` + `withXxxLock` template helpers
- ✅ Pre-computed `logicalToPhysicalMap` index table
- ✅ ISR-safe portMUX for render-request flag
- ✅ Atomic JSON write via temp-file-then-rename
- ✅ PSRAM-preferring `SpiRamAllocator` / `PsramJsonDocument`
- ✅ Time-delta EMA battery filter (`alpha = 1 - exp(-dt/tau)`)
- ✅ Trimmed-mean ADC sampling (`std::sort` + inner-subset average)
- ✅ Drop-oldest frame-queue overflow policy
- ✅ Gzip-negotiated static asset serving
- ✅ `scrollRenderTask` drift correction (grid-lock advance + burst-reset)
- ✅ Double-lock TOCTOU guard in `scrollRenderTask` (scroll unlock → frame lock re-check)
- ✅ `static_assert` verifying matrix row layout sums to `LED_COUNT`

---

*End of Review*
