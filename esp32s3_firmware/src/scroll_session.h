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
    uint32_t generation = 0;
    bool append = false;
    uint16_t baseIndex = 0;
    uint16_t framesReceivedBase = 0;
    uint16_t totalFramesExpected = 0;
    uint16_t nextChunkIndex = 0;
    char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
};

struct ScrollUploadResult {
    bool valid = false;
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
    bool loop = true;
    bool groupTimed = false;
};

struct ScrollSessionSnapshot {
    bool firmwareScrollActive = false;
    bool firmwareScrollPaused = false;
    bool firmwareScrollUserPaused = false;
    bool firmwareScrollSystemPaused = false;
    bool restoreAutoAfterScroll = false;
    bool scrollLoop = true;
    uint16_t scrollFrameCount = 0;
    uint16_t scrollFrameIndex = 0;
    uint16_t scrollIntervalMs = DEFAULT_SCROLL_INTERVAL_MS;
    uint8_t uiFps = 0;
    char scrollTimelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
    bool scrollUploadComplete = false;
    bool scrollHasSourceText = false;
    // Board group v1 (§1.5): true while the cursor is driven by group_start's
    // absolute-time schedule instead of legacy per-tick accumulation.
    bool groupTimed = false;

    bool scrolling() const {
        return firmwareScrollActive || firmwareScrollPaused;
    }
};

uint32_t scrollSessionGeneration();

bool isScrollPlayback(const String& playback);

ScrollStartResult scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode, uint8_t uiFps = 0);
ScrollStopResult scrollSessionStop(bool restoreAuto, bool clearDisplay,
                                   bool takeOutputControl = true);
bool scrollSessionSetUserPaused(bool paused);
bool scrollSessionSetSystemPaused(bool paused);
void scrollSessionSetLoop(bool loop);
// If the session is stopped-on-its-last-frame with loop disabled, seek back to frame 0.
// Returns true if it acted. Call before resuming a user-initiated firmware scroll.
bool scrollSessionRewindIfEnded();
bool scrollSessionStep(int8_t direction, uint8_t* outFrameBits);
// Jump to an absolute frame (clamped to the timeline). An active scroll keeps playing from
// there; an inactive one is latched paused on that frame, like a step. Presents the frame itself.
bool scrollSessionSeek(uint16_t frameIndex);
void scrollSessionSetInterval(uint16_t intervalMs, uint8_t uiFps = 0);
// Store the original source text into the current scroll session meta (RAM). Used when the
// the app sends the text in the start_scroll command (or in the scroll blob meta).
void scrollSessionSetSourceText(const char* text, uint16_t bytes);

bool scrollSessionGetRestoreAuto();
void scrollSessionSetRestoreAuto(bool value);

ScrollUploadTxn scrollSessionBeginUpload(const ScrollUploadMeta& meta);
ScrollUploadTxn scrollSessionBeginAppend();
// Copy `count` contiguous packed frames (count * FRAME_BYTES bytes) into the scroll
// buffer starting at startIndex. Takes the scroll lock once for the whole chunk.
bool scrollSessionWriteFrames(const ScrollUploadTxn& txn, uint16_t startIndex,
                              const uint8_t* packedFrames, uint16_t count);
ScrollUploadResult scrollSessionCommitUpload(const ScrollUploadTxn& txn, uint16_t count,
                                             bool hasExplicitTiming, uint16_t intervalMs, uint8_t uiFps = 0);
bool scrollSessionCopyMeta(ScrollMetaOut& out, char* textBuf, size_t textBufSize);
ScrollSessionSnapshot scrollSessionSnapshot();

bool scrollSessionTickCursorLocked(uint32_t now, uint8_t* outFrameBits);

// Board group v1 (§1.5): enter/re-anchor group-timed playback. Requires a
// loaded timeline (frameCount > 0); returns false (no-op) otherwise, so the
// caller can reply ERR 409 "no_timeline". Re-anchoring (already in
// group-timed mode on the same timeline) just replaces the schedule
// atomically, with no restart flash.
bool scrollSessionGroupStart(uint64_t atUs, uint16_t startFrame, uint16_t intervalMs, bool loop);

// Leaves group-timed mode, back to legacy local timing. Call on every command
// that already ends/changes a scroll today (start_scroll, pause_scroll,
// scroll_seek, scroll_step, set_scroll_interval, a new scroll upload, a
// button, stop_scroll, or any other output taking over). A no-op when not
// currently group-timed.
void scrollSessionExitGroupTimed();
// Same as scrollSessionExitGroupTimed(), but the caller must already hold
// the Scroll lock (used by scroll_session.cpp's own locked call sites).
void scrollSessionExitGroupTimedLocked();

// Core-0 service: promotes a pending end-of-timeline pause (latched by the Core-1 tick when
// loop is off) into the cooperative-loop runtimeState().paused/playback fields so EV_STATUS
// reports it. Call once per loop() iteration.
void serviceScrollSession();

// Fill a presentation context from the current scroll session state (acquires the scroll lock
// internally). Used by start/step paths so the presented sample carries the right frame identity.
// rateEligible is forced false unless the session is actively (non-paused) scrolling.
void scrollSessionFillPresentationContext(LedPresentationContext& ctx,
                                          LedPresentationSource source,
                                          const char* reason, bool rateEligible);

// Same as scrollSessionFillPresentationContext, but the caller must already hold the
// scroll lock (used by the Core-1 scroll tick, which fills the context inside its
// existing locked section).
void scrollSessionFillPresentationContextLocked(LedPresentationContext& ctx,
                                                LedPresentationSource source,
                                                const char* reason, bool rateEligible);
