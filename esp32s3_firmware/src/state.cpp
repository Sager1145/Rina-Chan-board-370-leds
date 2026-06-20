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
#if ALLOW_INTERNAL_SCROLL_CACHE
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
#else
        // Production policy: refuse to consume ~144 KB of scarce internal heap for the
        // scroll cache. Text scrolling is disabled (uploads return 507), but WiFi /
        // WebServer / JSON keep their internal-DRAM headroom and the board stays stable.
        scrollFrameBitsInPsram_ = false;
        Serial.printf("ERROR: PSRAM scroll cache allocation failed (need %u bytes); scroll cache disabled. "
                      "Build with -D ALLOW_INTERNAL_SCROLL_CACHE=1 to permit internal-SRAM fallback.\n",
                      static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES));
        return false;
#endif
    }

    memset(scrollFrameBits_, 0, SCROLL_FRAME_BUFFER_BYTES);
    Serial.printf("Scroll buffer ready: %u bytes in %s, psram total=%u free=%u\n",
                  static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES),
                  scrollFrameBitsInPsram_ ? "PSRAM" : "internal SRAM heap fallback",
                  static_cast<unsigned>(ESP.getPsramSize()),
                  static_cast<unsigned>(ESP.getFreePsram()));

    // Audit M1: bring up a second PSRAM cache + staging source-text buffer so a replacement
    // upload can be assembled off to the side and swapped in atomically (the running scroll
    // is never torn down before the new timeline fully commits). PSRAM-only -- double-
    // buffering scarce internal SRAM is never attempted. On any failure, free what we got
    // and stay single-buffered; uploads then use the legacy in-place path with no change.
    if (scrollFrameBitsInPsram_ && !scrollDoubleBuffered_ && ESP.getPsramSize() > 0) {
        const size_t stagingTextBytes = static_cast<size_t>(MAX_SCROLL_TEXT_BYTES) + 1U;
        uint8_t* bufB = static_cast<uint8_t*>(
            heap_caps_malloc(SCROLL_FRAME_BUFFER_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        char* stagingText = nullptr;
        if (bufB != nullptr) {
            stagingText = static_cast<char*>(
                heap_caps_malloc(stagingTextBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        }
        if (bufB != nullptr && stagingText != nullptr) {
            memset(bufB, 0, SCROLL_FRAME_BUFFER_BYTES);
            stagingText[0]           = '\0';
            scrollFrameBitsB_        = bufB;
            scrollStagingSourceText_ = stagingText;
            scrollRenderBuffer_      = 0;
            scrollDoubleBuffered_    = true;
            Serial.printf("Scroll double-buffer ready: atomic timeline replacement enabled (+%u bytes PSRAM)\n",
                          static_cast<unsigned>(SCROLL_FRAME_BUFFER_BYTES));
        } else {
            if (stagingText != nullptr) heap_caps_free(stagingText);
            if (bufB != nullptr) heap_caps_free(bufB);
            Serial.println("WARN: scroll staging buffer/text alloc failed; atomic timeline replacement disabled (in-place uploads)");
        }
    }
    return true;
}

uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) {
    uint8_t* base = activeScrollBuffer();
    if (index >= MAX_SCROLL_FRAMES || base == nullptr) return nullptr;
    return base + (static_cast<size_t>(index) * FRAME_BYTES);
}

const uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) const {
    const uint8_t* base = activeScrollBuffer();
    if (index >= MAX_SCROLL_FRAMES || base == nullptr) return nullptr;
    return base + (static_cast<size_t>(index) * FRAME_BYTES);
}

uint8_t* RuntimeStore::scrollStagingFrameBits(uint16_t index) {
    uint8_t* base = stagingScrollBuffer();
    if (index >= MAX_SCROLL_FRAMES || base == nullptr) return nullptr;
    return base + (static_cast<size_t>(index) * FRAME_BYTES);
}

bool RuntimeStore::commitScrollStagingSwap() {
    if (!scrollDoubleBuffered_) return false;
    // O(1) atomic promotion: toggle which physical buffer the render task reads, and swap
    // the meta struct + source-text pointer so the active side now describes the freshly
    // uploaded timeline while the old one becomes scratch staging. Caller holds scrollMutex.
    scrollRenderBuffer_ ^= 1U;
    ScrollTimelineMeta tmpMeta = scrollMeta_;
    scrollMeta_        = scrollStagingMeta_;
    scrollStagingMeta_ = tmpMeta;
    char* tmpText            = scrollSourceText_;
    scrollSourceText_        = scrollStagingSourceText_;
    scrollStagingSourceText_ = tmpText;
    return true;
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

bool runtimeScrollDoubleBuffered() {
    return RuntimeStore::instance().scrollDoubleBuffered();
}

uint8_t* runtimeScrollStagingFrameBits(uint16_t index) {
    return RuntimeStore::instance().scrollStagingFrameBits(index);
}

bool runtimeCommitScrollStagingSwap() {
    return RuntimeStore::instance().commitScrollStagingSwap();
}

ScrollTimelineMeta& runtimeScrollMeta() {
    return RuntimeStore::instance().scrollMeta();
}

ScrollTimelineMeta& runtimeScrollStagingMeta() {
    return RuntimeStore::instance().scrollStagingMeta();
}

char* runtimeScrollSourceText() {
    return RuntimeStore::instance().scrollSourceText();
}

bool runtimeScrollSourceTextReady() {
    return RuntimeStore::instance().scrollSourceTextReady();
}

char* runtimeScrollStagingSourceText() {
    return RuntimeStore::instance().scrollStagingSourceText();
}

bool runtimeScrollStagingSourceTextReady() {
    return RuntimeStore::instance().scrollStagingSourceTextReady();
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

// Audit M1 -- staging-side equivalents. On single-buffer boards the staging accessors
// alias the active meta/source-text, so these behave exactly like the active versions.
void invalidateScrollStagingUploadLocked() {
    ScrollTimelineMeta& meta = runtimeScrollStagingMeta();
    meta.uploadComplete      = false;
    meta.framesReceived      = 0;
    meta.totalFramesExpected = 0;
    meta.nextChunkIndex      = 0;
}

void clearScrollTimelineMetaStagingLocked() {
    invalidateScrollStagingUploadLocked();
    ScrollTimelineMeta& meta = runtimeScrollStagingMeta();
    meta.timelineId[0]        = '\0';
    meta.fontId[0]            = '\0';
    meta.generatorVersion[0]  = '\0';
    meta.sourceTextByteLength = 0;
    meta.hasSourceText        = false;
    meta.uiFps                = 0;
    char* text = runtimeScrollStagingSourceText();
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
