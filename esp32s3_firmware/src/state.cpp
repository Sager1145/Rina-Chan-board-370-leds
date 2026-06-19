#include "state.h"
#include "utils.h"
#include <esp_heap_caps.h>

static constexpr size_t SCROLL_FRAME_BUFFER_BYTES =
    static_cast<size_t>(MAX_SCROLL_FRAMES) * static_cast<size_t>(FRAME_BYTES);

RuntimeStore& RuntimeStore::instance() {
    static RuntimeStore store;
    return store;
}

bool RuntimeStore::initScrollFrameBuffer() {
    if (scrollSourceText_ == nullptr) {
        const size_t textBytes = static_cast<size_t>(MAX_SCROLL_TEXT_BYTES) + 1U;
        if (ESP.getPsramSize() > 0) {
            scrollSourceText_ = static_cast<char*>(
                heap_caps_malloc(textBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        }
        if (scrollSourceText_ == nullptr) {
            scrollSourceText_ = static_cast<char*>(
                heap_caps_malloc(textBytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
        }
        if (scrollSourceText_ != nullptr) {
            scrollSourceText_[0] = '\0';
        } else {
            Serial.println("WARN: scroll source-text buffer unavailable; text-backed uploads will return 507");
        }
    }

    if (scrollFrameBits_ != nullptr) return true;

    if (ESP.getPsramSize() > 0) {
        scrollFrameBits_ = static_cast<uint8_t*>(
            heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        scrollFrameBitsInPsram_ = scrollFrameBits_ != nullptr;
    }

    if (scrollFrameBits_ == nullptr) {
        scrollFrameBits_ = static_cast<uint8_t*>(
            heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
        scrollFrameBitsInPsram_ = false;
        if (scrollFrameBits_ == nullptr) {
            Serial.printf("WARN: scroll buffer unavailable; need %u bytes of PSRAM or internal SRAM\n",
                          static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES));
            return false;  // Explains text scrolling, frame buffer, or playback state handling.
        }
        Serial.printf("WARN: PSRAM scroll buffer unavailable; using %u-byte internal SRAM heap fallback\n",
                      static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES));
    }

    memset(scrollFrameBits_, 0, SCROLL_FRAME_BUFFER_BYTES);
    Serial.printf("Scroll buffer ready: %u bytes in %s, psram total=%u free=%u\n",
                  static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES),
                  scrollFrameBitsInPsram_ ? "PSRAM" : "internal SRAM heap fallback",
                  static_cast<unsigned>(ESP.getPsramSize()),
                  static_cast<unsigned>(ESP.getFreePsram()));
    return true;
}

uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) {
    if (index >= MAX_SCROLL_FRAMES || scrollFrameBits_ == nullptr) return nullptr;
    return scrollFrameBits_ + (static_cast<size_t>(index) * FRAME_BYTES);
}

const uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) const {
    if (index >= MAX_SCROLL_FRAMES || scrollFrameBits_ == nullptr) return nullptr;
    return scrollFrameBits_ + (static_cast<size_t>(index) * FRAME_BYTES);
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

ScrollTimelineMeta& runtimeScrollMeta() {
    return RuntimeStore::instance().scrollMeta();
}

char* runtimeScrollSourceText() {
    return RuntimeStore::instance().scrollSourceText();
}

bool runtimeScrollSourceTextReady() {
    return RuntimeStore::instance().scrollSourceTextReady();
}

void invalidateScrollUploadLocked() {
    // EH-A: Bad frame data invalidates the playback cache, but sourceText / timelineId /
    // fontId / generatorVersion are intentionally preserved, so the recovery path can still reconstruct the preview from the text.
    ScrollTimelineMeta& meta = runtimeScrollMeta();
    meta.uploadComplete      = false;
    meta.framesReceived      = 0;
    meta.totalFramesExpected = 0;
    meta.nextChunkIndex      = 0;
}

void clearScrollTimelineMetaLocked() {
    invalidateScrollUploadLocked();
    ScrollTimelineMeta& meta = runtimeScrollMeta();
    meta.timelineId[0]        = '\0';
    meta.fontId[0]            = '\0';
    meta.generatorVersion[0]  = '\0';
    meta.sourceTextByteLength = 0;
    meta.hasSourceText        = false;
    meta.uiFps                = 0;
    char* text = runtimeScrollSourceText();
    if (text != nullptr) text[0] = '\0';
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
    if (!millisElapsed(now, state.lastSlowUiPublishMs, POWER_WEB_SLOW_PUBLISH_MS)) return;
    state.slowUiDirty = false;
    state.lastSlowUiPublishMs = now;
    touchRuntimeState();
}
