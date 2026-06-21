#pragma once
#include <Arduino.h>
#include "config.h"
#include "state.h"
#include "led_presentation.h"

struct ScrollStartResult {
    bool started = false;
    bool engagedRestoreAuto = false;
};

struct ScrollStopResult {
    bool stopped = false;
    bool cleared = false;
    bool shouldRestoreDefault = false;
    bool restoreAuto = false;
};

struct ScrollUploadMeta {
    const char* timelineId = nullptr;
    const char* fontId = nullptr;
    const char* generatorVersion = nullptr;
    const char* sourceText = nullptr;
    uint16_t sourceTextBytes = 0;
    uint16_t totalFrames = 0;
    uint8_t uiFps = 0;
};

struct ScrollUploadTxn {
    bool append = false;
    bool timelineBacked = false;
    bool uploadComplete = false;
    uint16_t baseIndex = 0;
    uint16_t framesReceivedBase = 0;
    uint16_t totalFramesExpected = 0;
    uint16_t nextChunkIndex = 0;
    char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
};

struct ScrollUploadResult {
    uint16_t frameCount = 0;
    bool uploadComplete = false;
    char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
};

struct ScrollMetaOut {
    ScrollTimelineMeta meta;
    uint16_t frameCount = 0;
    uint16_t frameIndex = 0;
    uint16_t scrollIntervalMs = DEFAULT_SCROLL_INTERVAL_MS;
    bool active = false;
    bool paused = false;
    bool userPaused = false;
    bool systemPaused = false;
};

struct ScrollSessionSnapshot {
    bool firmwareScrollActive = false;
    bool firmwareScrollPaused = false;
    bool firmwareScrollUserPaused = false;
    bool firmwareScrollSystemPaused = false;
    bool restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount = 0;
    uint16_t scrollFrameIndex = 0;
    uint16_t scrollIntervalMs = DEFAULT_SCROLL_INTERVAL_MS;
    uint8_t uiFps = 0;
    char scrollTimelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
    bool scrollUploadComplete = false;
    bool scrollHasSourceText = false;

    bool scrolling() const {
        return firmwareScrollActive || firmwareScrollPaused;
    }
};

bool isScrollPlayback(const String& playback);

ScrollStartResult scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode, uint8_t uiFps = 0);
ScrollStopResult scrollSessionStop(bool restoreAuto, bool clearDisplay);
bool scrollSessionSetUserPaused(bool paused);
bool scrollSessionSetSystemPaused(bool paused);
bool scrollSessionStep(int8_t direction, uint8_t* outFrameBits);
void scrollSessionSetInterval(uint16_t intervalMs, uint8_t uiFps = 0);
// Store the original source text into the current scroll session meta (RAM). Used when the
// WebUI sends the text in the start_scroll command body instead of the upload query string.
void scrollSessionSetSourceText(const char* text, uint16_t bytes);
void scrollSessionMarkStoppedByButton(const String& button, const String& source);

bool scrollSessionGetRestoreAuto();
void scrollSessionSetRestoreAuto(bool value);

ScrollUploadTxn scrollSessionBeginUpload(const ScrollUploadMeta& meta);
ScrollUploadTxn scrollSessionBeginAppend();
bool scrollSessionWriteFrame(const ScrollUploadTxn& txn, uint16_t index, const uint8_t* packedBits);
ScrollUploadResult scrollSessionCommitUpload(const ScrollUploadTxn& txn, uint16_t count,
                                             bool hasExplicitTiming, uint16_t intervalMs, uint8_t uiFps = 0);
void scrollSessionInvalidateCache();
void scrollSessionClearTimeline();
bool scrollSessionCopyMeta(ScrollMetaOut& out, char* textBuf, size_t textBufSize);
ScrollSessionSnapshot scrollSessionSnapshot();

bool scrollSessionTickCursorLocked(uint32_t now, uint8_t* outFrameBits);

// Fill a presentation context from the current scroll session state (acquires the scroll lock
// internally). Used by start/step paths so the presented sample carries the right frame identity.
// rateEligible is forced false unless the session is actively (non-paused) scrolling.
void scrollSessionFillPresentationContext(LedPresentationContext& ctx,
                                          LedPresentationSource source,
                                          const char* reason, bool rateEligible);
