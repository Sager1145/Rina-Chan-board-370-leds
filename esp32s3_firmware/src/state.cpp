#include "state.h"
#include <esp_heap_caps.h>

static constexpr size_t SCROLL_FRAME_BUFFER_BYTES =
    static_cast<size_t>(MAX_SCROLL_FRAMES) * static_cast<size_t>(FRAME_BYTES);

/**
 * @brief Access the singleton runtime store shared by all firmware modules.
 * @param None.
 * @return Mutable RuntimeStore instance.
 */
RuntimeStore& RuntimeStore::instance() {
    static RuntimeStore store;
    return store;
}

/**
 * @brief Allocate the scroll-frame cache, preferring PSRAM and falling back to SRAM.
 * @param None.
 * @return true after a backing buffer is selected and zeroed.
 */
bool RuntimeStore::initScrollFrameBuffer() {
    if (scrollFrameBits_ != nullptr) return true;

    // Prefer PSRAM because text-scroll uploads can cache thousands of frames.
    // The fallback keeps firmware functional on boards without external RAM,
    // but it consumes a large static SRAM block declared in RuntimeStore.
    if (ESP.getPsramSize() > 0) {
        scrollFrameBits_ = static_cast<uint8_t*>(
            heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        scrollFrameBitsInPsram_ = scrollFrameBits_ != nullptr;
    }

    // Keep scroll features available even when PSRAM allocation fails.  This
    // connection is intentionally local: callers only ask for runtime storage
    // through runtimeScrollFrameBits(), not by knowing which memory tier won.
    if (scrollFrameBits_ == nullptr) {
        Serial.printf("WARN: PSRAM scroll buffer unavailable; using original %u-byte internal SRAM fallback\n",
                      static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES));
        scrollFrameBits_ = &fallbackScrollFrameBits_[0][0];
        scrollFrameBitsInPsram_ = false;
    }

    memset(scrollFrameBits_, 0, SCROLL_FRAME_BUFFER_BYTES);
    Serial.printf("Scroll buffer ready: %u bytes in %s, psram total=%u free=%u\n",
                  static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES),
                  scrollFrameBitsInPsram_ ? "PSRAM" : "original internal SRAM fallback",
                  static_cast<unsigned>(ESP.getPsramSize()),
                  static_cast<unsigned>(ESP.getFreePsram()));
    return true;
}

/**
 * @brief Return a writable packed-frame slot from the scroll cache.
 * @param index Scroll-frame index in the firmware RAM timeline.
 * @return Pointer to FRAME_BYTES bytes, or nullptr when index is out of range.
 */
uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) {
    if (index >= MAX_SCROLL_FRAMES) return nullptr;
    uint8_t* buffer = scrollFrameBits_ != nullptr ? scrollFrameBits_ : &fallbackScrollFrameBits_[0][0];
    return buffer + (static_cast<size_t>(index) * FRAME_BYTES);
}

/**
 * @brief Return a read-only packed-frame slot from the scroll cache.
 * @param index Scroll-frame index in the firmware RAM timeline.
 * @return Pointer to FRAME_BYTES bytes, or nullptr when index is out of range.
 */
const uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) const {
    if (index >= MAX_SCROLL_FRAMES) return nullptr;
    const uint8_t* buffer = scrollFrameBits_ != nullptr ? scrollFrameBits_ : &fallbackScrollFrameBits_[0][0];
    return buffer + (static_cast<size_t>(index) * FRAME_BYTES);
}

/**
 * @brief Access mutable global runtime state.
 * @param None.
 * @return RuntimeState reference used by control, web, render, and storage modules.
 */
RuntimeState& runtimeState() {
    return RuntimeStore::instance().state();
}

/**
 * @brief Access loaded saved-face records.
 * @param None.
 * @return Pointer to the first RuntimeFace slot.
 */
RuntimeFace* runtimeAutoFaces() {
    return RuntimeStore::instance().autoFaces();
}

/**
 * @brief Access the active saved-face count.
 * @param None.
 * @return Mutable count shared by storage and playback modules.
 */
uint16_t& runtimeAutoFaceCount() {
    return RuntimeStore::instance().autoFaceCount();
}

/**
 * @brief Access the currently displayed packed LED frame.
 * @param None.
 * @return Pointer to FRAME_BYTES packed bits.
 */
uint8_t* runtimeFrameBits() {
    return RuntimeStore::instance().frameBits();
}

/**
 * @brief Initialize scroll-frame storage through the runtime singleton.
 * @param None.
 * @return true when scroll-frame storage is ready.
 */
bool initRuntimeScrollFrameBuffer() {
    return RuntimeStore::instance().initScrollFrameBuffer();
}

/**
 * @brief Report whether scroll-frame storage has been initialized.
 * @param None.
 * @return true when runtimeScrollFrameBits() can be used safely.
 */
bool runtimeScrollFrameBufferReady() {
    return RuntimeStore::instance().scrollFrameBufferReady();
}

/**
 * @brief Report which memory tier backs the scroll-frame cache.
 * @param None.
 * @return true when external PSRAM is being used.
 */
bool runtimeScrollFrameBufferInPsram() {
    return RuntimeStore::instance().scrollFrameBufferInPsram();
}

/**
 * @brief Return the configured scroll-frame cache size.
 * @param None.
 * @return Total bytes reserved for MAX_SCROLL_FRAMES packed frames.
 */
size_t runtimeScrollFrameBufferBytes() {
    return SCROLL_FRAME_BUFFER_BYTES;
}

/**
 * @brief Access one writable scroll-frame slot.
 * @param index Frame index in the firmware scroll timeline.
 * @return Pointer to FRAME_BYTES bytes, or nullptr if index is invalid.
 */
uint8_t* runtimeScrollFrameBits(uint16_t index) {
    return RuntimeStore::instance().scrollFrameBits(index);
}

/**
 * @brief Access the mounted-filesystem state flag.
 * @param None.
 * @return Mutable flag owned by storage and observed by web routes.
 */
bool& runtimeFsMounted() {
    return RuntimeStore::instance().fsMounted();
}

/**
 * @brief Read the monotonic runtime version used by WebUI polling.
 * @param None.
 * @return Current non-zero state version.
 */
uint32_t runtimeStateVersion() {
    return runtimeState().stateVersion;
}

/**
 * @brief Publish a fast runtime-state change to WebUI pollers.
 * @param None.
 * @return None.
 */
void touchRuntimeState() {
    ++runtimeState().stateVersion;
    if (runtimeState().stateVersion == 0) runtimeState().stateVersion = 1;
}

/**
 * @brief Mark low-priority UI fields dirty without bumping the version immediately.
 * @param None.
 * @return None.
 */
void touchRuntimeStateSlow() {
    runtimeState().slowUiDirty = true;
}

/**
 * @brief Coalesce slow UI updates into bounded WebUI version bumps.
 * @param None.
 * @return None.
 */
void serviceRuntimeSlowStatePublish() {
    RuntimeState& state = runtimeState();
    // Slow fields such as power and brightness can change frequently.  Delay
    // the visible version bump so HTTP polling stays light while the firmware
    // still guarantees eventual publication.
    if (!state.slowUiDirty) return;
    const uint32_t now = millis();
    if (now - state.lastSlowUiPublishMs < POWER_WEB_SLOW_PUBLISH_MS) return;
    state.slowUiDirty = false;
    state.lastSlowUiPublishMs = now;
    touchRuntimeState();
}
