#include "state.h"
#include "utils.h"
#include <esp_heap_caps.h>
#include <string.h>

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

    if (scrollFrameBits_ != nullptr)
        return true;

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
            return false; // 说明文字滚动、帧缓存或播放状态处理。
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
    if (index >= MAX_SCROLL_FRAMES || scrollFrameBits_ == nullptr)
        return nullptr;
    return scrollFrameBits_ + (static_cast<size_t>(index) * FRAME_BYTES);
}

const uint8_t* RuntimeStore::scrollFrameBits(uint16_t index) const {
    if (index >= MAX_SCROLL_FRAMES || scrollFrameBits_ == nullptr)
        return nullptr;
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
    // EH-A：坏帧数据使播放缓存失效，但有意保留 sourceText / timelineId /
    // fontId / generatorVersion，恢复路径仍可从文本重建预览。
    ScrollTimelineMeta& meta = runtimeScrollMeta();
    meta.uploadComplete = false;
    meta.framesReceived = 0;
    meta.totalFramesExpected = 0;
    meta.nextChunkIndex = 0;
}

void clearScrollTimelineMetaLocked() {
    invalidateScrollUploadLocked();
    ScrollTimelineMeta& meta = runtimeScrollMeta();
    meta.timelineId[0] = '\0';
    meta.fontId[0] = '\0';
    meta.generatorVersion[0] = '\0';
    meta.sourceTextByteLength = 0;
    meta.hasSourceText = false;
    meta.uiFps = 0;
    char* text = runtimeScrollSourceText();
    if (text != nullptr)
        text[0] = '\0';
}

bool& runtimeFsMounted() {
    return RuntimeStore::instance().fsMounted();
}

uint32_t runtimeStateVersion() {
    return runtimeState().stateVersion;
}

void touchRuntimeState() {
    ++runtimeState().stateVersion;
    if (runtimeState().stateVersion == 0)
        runtimeState().stateVersion = 1;
}

void touchRuntimeStateSlow() {
    runtimeState().slowUiDirty = true;
}

void serviceRuntimeSlowStatePublish() {
    RuntimeState& state = runtimeState();
    if (!state.slowUiDirty)
        return;
    const uint32_t now = millis();
    if (!millisElapsed(now, state.lastSlowUiPublishMs, POWER_SLOW_PUBLISH_MS))
        return;
    state.slowUiDirty = false;
    state.lastSlowUiPublishMs = now;
    touchRuntimeState();
}

static bool outputReasonBase(const char* reason, size_t length, const char*& mode) {
    if (length == 7 && strncmp(reason, "lipsync", length) == 0) {
        mode = "lipSync";
        return true;
    }
    if (length == 11 && strncmp(reason, "live_preset", length) == 0) {
        mode = "performance";
        return true;
    }
    if (length == 5 && strncmp(reason, "video", length) == 0) {
        mode = "video";
        return true;
    }
    return false;
}

static bool canonicalOutputUuid(const char* value, size_t length) {
    if (!value || length != 36)
        return false;
    for (size_t i = 0; i < length; ++i) {
        const bool hyphen = i == 8 || i == 13 || i == 18 || i == 23;
        const char c = value[i];
        if (hyphen) {
            if (c != '-')
                return false;
        } else if (!((c >= '0' && c <= '9') ||
                     (c >= 'a' && c <= 'f') ||
                     (c >= 'A' && c <= 'F'))) {
            return false;
        }
    }
    return true;
}

static bool outputPosition(const char* value, uint32_t& positionMs) {
    if (!value || !value[0])
        return false;
    uint32_t parsed = 0;
    for (const char* p = value; *p; ++p) {
        if (*p < '0' || *p > '9')
            return false;
        const uint32_t digit = static_cast<uint32_t>(*p - '0');
        if (parsed > (UINT32_MAX - digit) / 10U)
            return false;
        parsed = parsed * 10U + digit;
    }
    positionMs = parsed;
    return true;
}

void parseOutputFrameReason(const char* reason, OutputFrameDescriptor& out) {
    out = OutputFrameDescriptor{};
    if (!reason || !reason[0])
        return;

    const char* firstColon = strchr(reason, ':');
    const size_t baseLength = firstColon ? static_cast<size_t>(firstColon - reason) : strlen(reason);
    const char* mode = nullptr;
    if (!outputReasonBase(reason, baseLength, mode))
        return;
    strlcpy(out.mode, mode, sizeof(out.mode));

    // Legacy exact reasons carry a mode but intentionally have no stream identity.
    if (!firstColon)
        return;
    const char* stream = firstColon + 1;
    const char* secondColon = strchr(stream, ':');
    if (!secondColon)
        return;
    const size_t streamLength = static_cast<size_t>(secondColon - stream);
    uint32_t positionMs = 0;
    if (!canonicalOutputUuid(stream, streamLength) ||
        !outputPosition(secondColon + 1, positionMs))
        return;

    memcpy(out.streamID, stream, streamLength);
    out.streamID[streamLength] = '\0';
    out.positionMs = positionMs;
}

void setRuntimeOutputMode(const char* mode, const char* streamID, uint32_t positionMs) {
    if (!mode || !mode[0])
        mode = "control";
    if (!streamID)
        streamID = "";
    RuntimeState& state = runtimeState();
    const bool changed = state.outputMode != mode ||
                         strcmp(state.outputStreamID, streamID) != 0 ||
                         state.outputPositionMs != positionMs;
    if (!changed)
        return;
    state.outputMode = mode;
    strlcpy(state.outputStreamID, streamID, sizeof(state.outputStreamID));
    state.outputPositionMs = positionMs;
    touchRuntimeState();
}

void setRuntimeOutputFromFrameReason(const char* reason) {
    OutputFrameDescriptor descriptor;
    parseOutputFrameReason(reason, descriptor);
    setRuntimeOutputMode(descriptor.mode, descriptor.streamID, descriptor.positionMs);
}
