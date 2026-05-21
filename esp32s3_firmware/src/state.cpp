#include "state.h"
#include <esp_heap_caps.h>

static constexpr size_t SCROLL_FRAME_BUFFER_BYTES =
    static_cast<size_t>(MAX_SCROLL_FRAMES) * static_cast<size_t>(FRAME_BYTES);

RuntimeStore& RuntimeStore::instance() {
    static RuntimeStore store;
    return store;
}

bool RuntimeStore::initScrollFrameBuffer() {
    if (scrollFrameBits_ != nullptr) return true;

    if (ESP.getPsramSize() > 0) {
        scrollFrameBits_ = static_cast<uint8_t*>(
            heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        scrollFrameBitsInPsram_ = scrollFrameBits_ != nullptr;
    }

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

uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) {
    if (index >= MAX_SCROLL_FRAMES) return nullptr;
    uint8_t* buffer = scrollFrameBits_ != nullptr ? scrollFrameBits_ : &fallbackScrollFrameBits_[0][0];
    return buffer + (static_cast<size_t>(index) * FRAME_BYTES);
}

const uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) const {
    if (index >= MAX_SCROLL_FRAMES) return nullptr;
    const uint8_t* buffer = scrollFrameBits_ != nullptr ? scrollFrameBits_ : &fallbackScrollFrameBits_[0][0];
    return buffer + (static_cast<size_t>(index) * FRAME_BYTES);
}

RuntimeState& runtimeState() {
    return RuntimeStore::instance().state();
}

RuntimeFace* runtimeAutoFaces() {
    return RuntimeStore::instance().autoFaces();
}

uint16_t& runtimeAutoFaceCount() {
    return RuntimeStore::instance().autoFaceCount();
}

uint8_t* runtimeFrameBits() {
    return RuntimeStore::instance().frameBits();
}

bool initRuntimeScrollFrameBuffer() {
    return RuntimeStore::instance().initScrollFrameBuffer();
}

bool runtimeScrollFrameBufferReady() {
    return RuntimeStore::instance().scrollFrameBufferReady();
}

bool runtimeScrollFrameBufferInPsram() {
    return RuntimeStore::instance().scrollFrameBufferInPsram();
}

size_t runtimeScrollFrameBufferBytes() {
    return SCROLL_FRAME_BUFFER_BYTES;
}

uint8_t* runtimeScrollFrameBits(uint16_t index) {
    return RuntimeStore::instance().scrollFrameBits(index);
}

bool& runtimeFsMounted() {
    return RuntimeStore::instance().fsMounted();
}

uint32_t runtimeStateVersion() {
    return runtimeState().stateVersion;
}

void touchRuntimeState() {
    ++runtimeState().stateVersion;
    if (runtimeState().stateVersion == 0) runtimeState().stateVersion = 1;
}

void touchRuntimeStateSlow() {
    runtimeState().slowUiDirty = true;
}

void serviceRuntimeSlowStatePublish() {
    RuntimeState& state = runtimeState();
    if (!state.slowUiDirty) return;
    const uint32_t now = millis();
    if (now - state.lastSlowUiPublishMs < POWER_WEB_SLOW_PUBLISH_MS) return;
    state.slowUiDirty = false;
    state.lastSlowUiPublishMs = now;
    touchRuntimeState();
}
