#include "scroll_session.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include "serial_log.h"
#include <string.h>

void scrollSessionFillPresentationContext(LedPresentationContext& ctx,
                                          LedPresentationSource source,
                                          const char* reason, bool rateEligible) {
    withScrollLock([&]() {
        const RuntimeState& rs = runtimeState();
        const ScrollTimelineMeta& meta = runtimeScrollMeta();
        ctx = LedPresentationContext{};
        ctx.valid = true;
        ctx.source = source;
        strlcpy(ctx.timelineId, meta.timelineId, sizeof(ctx.timelineId));
        ctx.frameIndex        = rs.scrollFrameIndex;
        ctx.frameCount        = rs.scrollFrameCount;
        ctx.nominalIntervalMs = rs.scrollIntervalMs;
        ctx.uiFps             = meta.uiFps;
        ctx.firmwareScrollActive = rs.firmwareScrollActive;
        ctx.firmwareScrollPaused = rs.firmwareScrollPaused;
        ctx.userPaused           = rs.firmwareScrollUserPaused;
        ctx.systemPaused         = rs.firmwareScrollSystemPaused;
        ctx.rateEligible = rateEligible && rs.firmwareScrollActive &&
                           !rs.firmwareScrollPaused && rs.scrollFrameCount > 0;
        strlcpy(ctx.reason, reason ? reason : "", sizeof(ctx.reason));
    });
}

bool isScrollPlayback(const String& playback) {
    return playback == "scroll" ||
           playback == "scroll_paused" ||
           playback == "scroll_step";
}

bool scrollSessionGetRestoreAuto() {
    bool value = false;
    withScrollLock([&]() { value = runtimeState().restoreAutoAfterScroll; });
    return value;
}

void scrollSessionSetRestoreAuto(bool value) {
    withScrollLock([&]() {
        runtimeState().restoreAutoAfterScroll = value;
    });
}

static uint8_t uiFpsFromScrollInterval(uint16_t intervalMs) {
    const uint16_t constrained = constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
    if (constrained == 0) return 0;
    const uint32_t rounded = (1000UL + (constrained / 2U)) / constrained;
    return static_cast<uint8_t>(constrain(rounded, 1UL, 255UL));
}

static bool firmwareScrollHasRuntimeStateLocked() {
    return runtimeState().firmwareScrollActive ||
           runtimeState().firmwareScrollPaused ||
           runtimeState().restoreAutoAfterScroll ||
           runtimeState().lastScrollFrameMs != 0 ||
           runtimeState().scrollFrameCount != 0 ||
           runtimeState().scrollFrameIndex != 0 ||
           runtimeState().paused ||
           isScrollPlayback(runtimeState().playback);
}

static void resetFirmwareScrollStateLocked(bool clearTimelineMeta = false) {
    runtimeState().firmwareScrollActive       = false;
    runtimeState().firmwareScrollPaused       = false;
    runtimeState().firmwareScrollUserPaused   = false;
    runtimeState().firmwareScrollSystemPaused = false;
    runtimeState().restoreAutoAfterScroll     = false;
    runtimeState().lastScrollFrameMs          = 0;
    runtimeState().scrollFrameCount           = 0;
    runtimeState().scrollFrameIndex           = 0;
    runtimeState().paused                     = false;
    if (clearTimelineMeta) clearScrollTimelineMetaLocked();
    else invalidateScrollUploadLocked();
    if (isScrollPlayback(runtimeState().playback)) {
        runtimeState().playback = DEFAULT_PLAYBACK;
    }
}

static bool setFirmwareScrollPauseFlag(bool userFlag, bool paused) {
    bool changed = false;
    bool applyPlaybackOutside = false;
    const char* playbackOutside = "scroll";

    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount == 0 && !runtimeState().firmwareScrollActive &&
            !runtimeState().firmwareScrollPaused) {
            runtimeState().firmwareScrollUserPaused = false;
            runtimeState().firmwareScrollSystemPaused = false;
            runtimeState().firmwareScrollPaused = false;
            return;
        }

        const bool oldUser      = runtimeState().firmwareScrollUserPaused;
        const bool oldSystem    = runtimeState().firmwareScrollSystemPaused;
        const bool oldEffective = runtimeState().firmwareScrollPaused;
        const bool oldPaused    = runtimeState().paused;

        if (userFlag) runtimeState().firmwareScrollUserPaused = paused;
        else          runtimeState().firmwareScrollSystemPaused = paused;
        runtimeState().firmwareScrollActive = true;

        const bool eff = runtimeState().firmwareScrollUserPaused ||
                         runtimeState().firmwareScrollSystemPaused;
        const bool playbackChanges =
            runtimeState().playback != (eff ? "scroll_paused" : "scroll");

        runtimeState().firmwareScrollPaused = eff;
        runtimeState().paused               = eff;
        if (!eff) runtimeState().lastScrollFrameMs = millis();

        applyPlaybackOutside = true;
        playbackOutside      = eff ? "scroll_paused" : "scroll";

        changed = oldUser != runtimeState().firmwareScrollUserPaused ||
                  oldSystem != runtimeState().firmwareScrollSystemPaused ||
                  oldEffective != eff ||
                  playbackChanges ||
                  oldPaused != runtimeState().paused;
    });

    if (applyPlaybackOutside) runtimeState().playback = playbackOutside;
    if (changed) touchRuntimeState();
    if (changed) {
        RLOG_INFO("SCROLL", "event=pause user=%d system=%d effective=%d",
                  runtimeState().firmwareScrollUserPaused ? 1 : 0,
                  runtimeState().firmwareScrollSystemPaused ? 1 : 0,
                  runtimeState().firmwareScrollPaused ? 1 : 0);
    }
    return changed;
}

bool scrollSessionSetUserPaused(bool paused) {
    return setFirmwareScrollPauseFlag(true, paused);
}

bool scrollSessionSetSystemPaused(bool paused) {
    return setFirmwareScrollPauseFlag(false, paused);
}

bool scrollSessionStep(int8_t direction, uint8_t* outFrameBits) {
    if (!outFrameBits) return false;

    bool hasSteppedFrame = false;
    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            const uint16_t frameCount = runtimeState().scrollFrameCount;
            runtimeState().scrollFrameIndex =
                direction < 0
                    ? static_cast<uint16_t>((runtimeState().scrollFrameIndex + frameCount - 1U) % frameCount)
                    : static_cast<uint16_t>((runtimeState().scrollFrameIndex + 1U) % frameCount);
            runtimeState().firmwareScrollActive      = true;
            runtimeState().firmwareScrollUserPaused  = true;
            runtimeState().firmwareScrollPaused      = true;
            runtimeState().paused                    = true;
            memcpy(outFrameBits, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
            hasSteppedFrame = true;
        }
    });

    if (hasSteppedFrame) {
        runtimeState().playback = "scroll_step";
        touchRuntimeState();
        RLOG_INFO("SCROLL", "event=step dir=%d idx=%u/%u",
                  direction < 0 ? -1 : 1,
                  static_cast<unsigned>(runtimeState().scrollFrameIndex),
                  static_cast<unsigned>(runtimeState().scrollFrameCount));
    }
    return hasSteppedFrame;
}

ScrollStopResult scrollSessionStop(bool restoreAuto, bool clearDisplay) {
    ScrollStopResult r;
    r.restoreAuto = restoreAuto;
    r.cleared     = clearDisplay;

    bool changed = false;
    withScrollLock([&]() {
        changed = firmwareScrollHasRuntimeStateLocked();
        resetFirmwareScrollStateLocked(clearDisplay);
    });

    r.stopped = changed;
    if (changed) touchRuntimeState();
    RLOG_INFO("SCROLL", "event=stop stopped=%d cleared=%d restoreAuto=%d",
              changed ? 1 : 0, clearDisplay ? 1 : 0, restoreAuto ? 1 : 0);
    if (changed || clearDisplay) clearQueuedPackedFrames();

    if (clearDisplay) {
        applyBlankFrame("firmware_text_scroll_stop_clear");
        if (restoreAuto) r.shouldRestoreDefault = true;
    }
    return r;
}

ScrollStartResult scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode) {
    ScrollStartResult result;
    clearQueuedPackedFrames();

    uint8_t firstFrame[FRAME_BYTES];
    bool    hasFirstFrame = false;

    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            runtimeState().restoreAutoAfterScroll =
                runtimeState().restoreAutoAfterScroll || callerIsAutoMode;
            result.engagedRestoreAuto = runtimeState().restoreAutoAfterScroll;
            runtimeState().scrollIntervalMs =
                constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            runtimeScrollMeta().uiFps = uiFpsFromScrollInterval(runtimeState().scrollIntervalMs);
            runtimeState().scrollFrameIndex           = 0;
            runtimeState().lastScrollFrameMs          = millis();
            runtimeState().firmwareScrollActive       = true;
            runtimeState().firmwareScrollPaused       = false;
            runtimeState().firmwareScrollUserPaused   = false;
            runtimeState().firmwareScrollSystemPaused = false;
            runtimeState().paused                     = false;
            memcpy(firstFrame, runtimeScrollFrameBits(0), FRAME_BYTES);
            hasFirstFrame = true;
        }
    });

    if (hasFirstFrame) {
        runtimeState().playback = "scroll";
        result.started = true;
        // Report the start frame (index 0) for position alignment, but never for fps estimation.
        LedPresentationContext ctx;
        scrollSessionFillPresentationContext(ctx, LedPresentationSource::ScrollStart,
                                             "firmware_text_scroll_start", false);
        RLOG_INFO("SCROLL", "event=start count=%u interval_ms=%u restoreAuto=%d",
                  static_cast<unsigned>(runtimeState().scrollFrameCount),
                  static_cast<unsigned>(runtimeState().scrollIntervalMs),
                  result.engagedRestoreAuto ? 1 : 0);
        applyPackedFrameImmediate(firstFrame, "firmware_text_scroll_start", &ctx);
    }
    return result;
}

void scrollSessionSetInterval(uint16_t intervalMs) {
    withScrollLock([&]() {
        runtimeState().scrollIntervalMs =
            constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        runtimeScrollMeta().uiFps = uiFpsFromScrollInterval(runtimeState().scrollIntervalMs);
        runtimeState().lastScrollFrameMs = millis();
    });
    touchRuntimeState();
}

void scrollSessionSetSourceText(const char* text, uint16_t bytes) {
    withScrollLock([&]() {
        ScrollTimelineMeta& meta = runtimeScrollMeta();
        if (text && bytes > 0 && runtimeScrollSourceTextReady()) {
            uint16_t n = bytes > MAX_SCROLL_TEXT_BYTES ? MAX_SCROLL_TEXT_BYTES : bytes;
            memcpy(runtimeScrollSourceText(), text, n);
            runtimeScrollSourceText()[n] = '\0';
            meta.sourceTextByteLength = n;
            meta.hasSourceText        = true;
        } else {
            meta.sourceTextByteLength = 0;
            meta.hasSourceText        = false;
        }
    });
    touchRuntimeState();
}

void scrollSessionMarkStoppedByButton(const String& button, const String& source) {
    ++runtimeState().scrollStopEventSeq;
    runtimeState().scrollStopEventMs     = millis();
    runtimeState().scrollStopEventButton = button;
    runtimeState().scrollStopEventSource = source;
    runtimeState().scrollStopEventReason = runtimeState().lastReason;
    touchRuntimeState();
}

ScrollUploadTxn scrollSessionBeginUpload(const ScrollUploadMeta& upload) {
    ScrollUploadTxn txn;
    txn.append = false;

    withScrollLock([&]() {
        runtimeState().scrollFrameCount = 0;
        runtimeState().scrollFrameIndex = 0;
        clearScrollTimelineMetaLocked();

        ScrollTimelineMeta& meta = runtimeScrollMeta();
        if (upload.timelineId && upload.timelineId[0] != '\0') {
            strncpy(meta.timelineId, upload.timelineId, MAX_SCROLL_TIMELINE_ID_CHARS);
            meta.timelineId[MAX_SCROLL_TIMELINE_ID_CHARS] = '\0';
        }
        if (upload.fontId && upload.fontId[0] != '\0') {
            strncpy(meta.fontId, upload.fontId, MAX_SCROLL_FONT_ID_CHARS);
            meta.fontId[MAX_SCROLL_FONT_ID_CHARS] = '\0';
        }
        if (upload.generatorVersion && upload.generatorVersion[0] != '\0') {
            strncpy(meta.generatorVersion, upload.generatorVersion, MAX_SCROLL_GENERATOR_CHARS);
            meta.generatorVersion[MAX_SCROLL_GENERATOR_CHARS] = '\0';
        }
        if (upload.sourceText && runtimeScrollSourceTextReady()) {
            memcpy(runtimeScrollSourceText(), upload.sourceText, static_cast<size_t>(upload.sourceTextBytes) + 1U);
            meta.sourceTextByteLength = upload.sourceTextBytes;
            meta.hasSourceText        = true;
        }
        meta.uiFps                = upload.uiFps;
        meta.totalFramesExpected  = upload.totalFrames;
        meta.nextChunkIndex       = 1;

        txn.timelineBacked      = meta.timelineId[0] != '\0';
        txn.totalFramesExpected = meta.totalFramesExpected;
        txn.nextChunkIndex      = meta.nextChunkIndex;
        memcpy(txn.timelineId, meta.timelineId, sizeof(txn.timelineId));
    });

    return txn;
}

ScrollUploadTxn scrollSessionBeginAppend() {
    ScrollUploadTxn txn;
    txn.append = true;

    withScrollLock([&]() {
        const ScrollTimelineMeta& meta = runtimeScrollMeta();
        txn.timelineBacked      = meta.timelineId[0] != '\0';
        txn.uploadComplete      = meta.uploadComplete;
        txn.nextChunkIndex      = meta.nextChunkIndex;
        txn.framesReceivedBase  = meta.framesReceived;
        txn.totalFramesExpected = meta.totalFramesExpected;
        txn.baseIndex           = runtimeState().scrollFrameCount;
        memcpy(txn.timelineId, meta.timelineId, sizeof(txn.timelineId));
    });

    return txn;
}

bool scrollSessionWriteFrame(const ScrollUploadTxn& txn, uint16_t index, const uint8_t* packedBits) {
    if (!packedBits || index >= MAX_SCROLL_FRAMES || !runtimeScrollFrameBufferReady()) return false;

    bool writable = false;
    withScrollLock([&]() {
        writable = index >= runtimeState().scrollFrameCount ||
                   (!txn.append && runtimeState().scrollFrameCount == 0);
    });
    if (!writable) return false;

    uint8_t* target = runtimeScrollFrameBits(index);
    if (!target) return false;
    memcpy(target, packedBits, FRAME_BYTES);
    return true;
}

ScrollUploadResult scrollSessionCommitUpload(const ScrollUploadTxn& txn, uint16_t count,
                                             bool hasExplicitTiming, uint16_t intervalMs) {
    ScrollUploadResult result;

    withScrollLock([&]() {
        runtimeState().scrollFrameCount = static_cast<uint16_t>(txn.baseIndex + count);
        if (!txn.append || (!runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused)) {
            runtimeState().scrollFrameIndex = 0;
        }
        if (hasExplicitTiming) {
            runtimeState().scrollIntervalMs =
                constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            runtimeScrollMeta().uiFps = uiFpsFromScrollInterval(runtimeState().scrollIntervalMs);
        }

        ScrollTimelineMeta& meta = runtimeScrollMeta();
        meta.framesReceived = static_cast<uint16_t>(txn.framesReceivedBase + count);
        if (txn.append) meta.nextChunkIndex = static_cast<uint16_t>(txn.nextChunkIndex + 1U);
        if (meta.totalFramesExpected > 0 && meta.framesReceived >= meta.totalFramesExpected) {
            meta.uploadComplete = true;
        }

        result.frameCount     = runtimeState().scrollFrameCount;
        result.uploadComplete = meta.uploadComplete;
        memcpy(result.timelineId, meta.timelineId, sizeof(result.timelineId));
    });

    return result;
}

void scrollSessionInvalidateCache() {
    withScrollLock([]() {
        runtimeState().scrollFrameCount = 0;
        invalidateScrollUploadLocked();
    });
}

void scrollSessionClearTimeline() {
    withScrollLock([]() {
        runtimeState().scrollFrameCount = 0;
        runtimeState().scrollFrameIndex = 0;
        clearScrollTimelineMetaLocked();
    });
}

bool scrollSessionCopyMeta(ScrollMetaOut& out, char* textBuf, size_t textBufSize) {
    if (textBuf && textBufSize > 0) textBuf[0] = '\0';

    bool copied = true;
    withScrollLock([&]() {
        out.meta             = runtimeScrollMeta();
        out.frameCount       = runtimeState().scrollFrameCount;
        out.frameIndex       = runtimeState().scrollFrameIndex;
        out.scrollIntervalMs = runtimeState().scrollIntervalMs;
        out.active           = runtimeState().firmwareScrollActive;
        out.paused           = runtimeState().firmwareScrollPaused;
        out.userPaused       = runtimeState().firmwareScrollUserPaused;
        out.systemPaused     = runtimeState().firmwareScrollSystemPaused;

        if (out.meta.hasSourceText && runtimeScrollSourceTextReady()) {
            const size_t bytesToCopy = static_cast<size_t>(out.meta.sourceTextByteLength) + 1U;
            if (textBuf && textBufSize >= bytesToCopy) memcpy(textBuf, runtimeScrollSourceText(), bytesToCopy);
            else copied = false;
        }
    });

    return copied;
}

ScrollSessionSnapshot scrollSessionSnapshot() {
    ScrollSessionSnapshot snapshot;
    withScrollLock([&]() {
        snapshot.firmwareScrollActive       = runtimeState().firmwareScrollActive;
        snapshot.firmwareScrollPaused       = runtimeState().firmwareScrollPaused;
        snapshot.firmwareScrollUserPaused   = runtimeState().firmwareScrollUserPaused;
        snapshot.firmwareScrollSystemPaused = runtimeState().firmwareScrollSystemPaused;
        snapshot.restoreAutoAfterScroll     = runtimeState().restoreAutoAfterScroll;
        snapshot.scrollFrameCount           = runtimeState().scrollFrameCount;
        snapshot.scrollFrameIndex           = runtimeState().scrollFrameIndex;
        snapshot.scrollIntervalMs           = runtimeState().scrollIntervalMs;
        const ScrollTimelineMeta& meta = runtimeScrollMeta();
        memcpy(snapshot.scrollTimelineId, meta.timelineId, sizeof(snapshot.scrollTimelineId));
        snapshot.scrollUploadComplete       = meta.uploadComplete;
        snapshot.scrollHasSourceText        = meta.hasSourceText;
    });
    return snapshot;
}

bool scrollSessionTickCursorLocked(uint32_t now, uint8_t* outFrameBits) {
    if (!outFrameBits) return false;
    if (!runtimeState().firmwareScrollActive || runtimeState().firmwareScrollPaused ||
        runtimeState().scrollFrameCount == 0 || !runtimeScrollFrameBufferReady()) {
        return false;
    }

    if (runtimeState().lastScrollFrameMs == 0) runtimeState().lastScrollFrameMs = now;

    const uint16_t intervalMs = constrain(runtimeState().scrollIntervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
    const uint32_t elapsedMs = now - runtimeState().lastScrollFrameMs;
    if (elapsedMs < intervalMs) return false;

    runtimeState().scrollFrameIndex = (runtimeState().scrollFrameIndex + 1) % runtimeState().scrollFrameCount;

    if (elapsedMs <= static_cast<uint32_t>(intervalMs) * SCROLL_DRIFT_RESET_INTERVALS) runtimeState().lastScrollFrameMs += intervalMs;
    else runtimeState().lastScrollFrameMs = now;

    memcpy(outFrameBits, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
    return true;
}
