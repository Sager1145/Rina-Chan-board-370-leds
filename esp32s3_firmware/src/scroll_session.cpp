/*
 * File Description: scroll_session.cpp
 * Implements logic for text scrolling sessions, including character glyph layout and frame generation.
 *
 * Responsibilities:
 * - Decodes scrolling text strings containing CJK characters and Mona12 emojis.
 * - Slices and packages text strings into separate upload chunks (via API).
 * - Rasterizes glyph bitmaps from the Ark12 JSON font table stored in LittleFS.
 * - Controls playback state transitions (play, pause, stop, step-forward, step-backward).
 *
 * Core Interactions:
 * - Locks access to the shared scroll frame buffers using FreeRTOS mutexes from sync.h.
 * - Decodes hex strings and draws layout frames utilizing structures defined in led_renderer.h.
 */
#include "scroll_session.h"
#include "state.h"
#include "sync.h"
#include "config.h"
#include "led_renderer.h"
#include "serial_log.h"
#include <string.h>
#include <Arduino.h>  // millis()

// P1-6: last time a scroll upload chunk was received (0 = no upload activity tracked).
// Used to reclaim a staged replacement timeline that an interrupted upload left behind.
static volatile uint32_t sScrollUploadActivityMs   = 0;
static volatile bool     sScrollUploadStaleCleared = false;

bool isScrollPlayback(const char* playback) {
    if (!playback) return false;
    return strcmp(playback, "scroll") == 0 ||
           strcmp(playback, "scroll_paused") == 0 ||
           strcmp(playback, "scroll_step") == 0;
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
    // Audit M1: a Stop/Clear or mode switch also aborts any in-progress staged replacement
    // upload, so late-arriving chunks can never swap a new timeline in after the user has
    // already stopped or switched away.
    runtimeState().scrollStagingInProgress    = false;
    runtimeState().scrollStagingFrameCount    = 0;
    if (clearTimelineMeta) {
        clearScrollTimelineMetaLocked();
        clearScrollTimelineMetaStagingLocked();
    } else {
        invalidateScrollUploadLocked();
        invalidateScrollStagingUploadLocked();
    }
    if (isScrollPlayback(runtimeState().playback)) {
        assignText(runtimeState().playback, DEFAULT_PLAYBACK);
    }
}

static bool setFirmwareScrollPauseFlag(bool userFlag, bool paused) {
    bool changed = false;
    bool applyPlaybackOutside = false;
    const char* playbackOutside = "scroll";

    withScrollLock([&]() {
        const bool displayingScroll = runtimeState().firmwareScrollActive ||
                                      runtimeState().firmwareScrollPaused;
        // Pause/resume is only a state sync operation for a scroll session that is
        // currently displayed on the LEDs (running or paused).  A cached timeline
        // alone must never be resurrected by a pause/resume command after Stop/Clear
        // or after switching to Manual/Auto/Saved Face.
        if (!displayingScroll || runtimeState().scrollFrameCount == 0) {
            runtimeState().firmwareScrollActive = false;
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
            strcmp(runtimeState().playback, eff ? "scroll_paused" : "scroll") != 0;

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

    if (applyPlaybackOutside) assignText(runtimeState().playback, playbackOutside);
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
        const bool displayingScroll = runtimeState().firmwareScrollActive ||
                                      runtimeState().firmwareScrollPaused;
        if (displayingScroll && runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            const uint16_t frameCount = runtimeState().scrollFrameCount;
            runtimeState().scrollFrameIndex =
                direction < 0
                    ? static_cast<uint16_t>((runtimeState().scrollFrameIndex + frameCount - 1U) % frameCount)
                    : static_cast<uint16_t>((runtimeState().scrollFrameIndex + 1U) % frameCount);
            // A manual step latches an effective (user) pause so the Core-1 render task
            // (scrollSessionTickCursorLocked) holds on the stepped frame instead of
            // advancing past it on the next tick. Without this, stepping while the scroll
            // is running is overwritten within one frame interval (audit fix #2).
            runtimeState().firmwareScrollActive      = true;
            runtimeState().firmwareScrollUserPaused  = true;
            runtimeState().firmwareScrollPaused      = true;
            runtimeState().paused                    = true;
            memcpy(outFrameBits, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
            hasSteppedFrame = true;
        }
    });

    if (hasSteppedFrame) {
        assignText(runtimeState().playback, "scroll_step");  // Core-0 cooperative field; written outside the lock
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

    bool changed = false;
    bool wasDisplayingScroll = false;
    withScrollLock([&]() {
        // "Clear" is a display action only when the hardware is currently showing
        // text-scroll output. The cache clear still happens when clearDisplay is true,
        // so Stop/Clear is a real terminal point and stale sourceText cannot be
        // restored by a later WebUI refresh.
        wasDisplayingScroll = runtimeState().firmwareScrollActive ||
                               runtimeState().firmwareScrollPaused;
        changed = firmwareScrollHasRuntimeStateLocked();
        resetFirmwareScrollStateLocked(clearDisplay);
    });

    r.stopped = changed;
    r.cleared = clearDisplay && wasDisplayingScroll;
    if (changed || clearDisplay) touchRuntimeState();
    RLOG_INFO("SCROLL", "event=stop stopped=%d cleared=%d cacheCleared=%d restoreAuto=%d",
              changed ? 1 : 0, r.cleared ? 1 : 0, clearDisplay ? 1 : 0, restoreAuto ? 1 : 0);
    if (changed || clearDisplay) clearQueuedM370Frames();

    if (r.cleared) {
        applyBlankFrameImmediate("scroll_stop_clear");
        if (restoreAuto) r.shouldRestoreDefault = true;
    }
    return r;
}

ScrollStartResult scrollSessionStart(uint16_t intervalMs, bool callerIsAutoMode) {
    ScrollStartResult result;
    clearQueuedM370Frames();

    uint8_t firstFrame[FRAME_BYTES];
    bool    hasFirstFrame = false;

    withScrollLock([&]() {
        if (runtimeState().scrollFrameCount > 0 && runtimeScrollFrameBufferReady()) {
            runtimeState().restoreAutoAfterScroll =
                runtimeState().restoreAutoAfterScroll || callerIsAutoMode;
            result.engagedRestoreAuto = runtimeState().restoreAutoAfterScroll;
            runtimeState().scrollIntervalMs =
                constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
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
        assignText(runtimeState().playback, "scroll");
        result.started = true;
        RLOG_INFO("SCROLL", "event=start count=%u interval_ms=%u restoreAuto=%d",
                  static_cast<unsigned>(runtimeState().scrollFrameCount),
                  static_cast<unsigned>(runtimeState().scrollIntervalMs),
                  result.engagedRestoreAuto ? 1 : 0);
        applyPackedFrameImmediate(firstFrame, "firmware_text_scroll_start");
    }
    return result;
}

void scrollSessionSetInterval(uint16_t intervalMs) {
    withScrollLock([&]() {
        runtimeState().scrollIntervalMs =
            constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
        runtimeState().lastScrollFrameMs = millis();
    });
    touchRuntimeState();
}

// Stop-event fields (scrollStopEvent*) are Core-0-only telemetry: written here on the
// Core-0 button/HTTP path and read only by the Core-0 /api/status builder. They are NOT
// touched by the Core-1 render task, so this function intentionally does NOT take
// withScrollLock. Acquiring the lock here would also reintroduce a heap-String assignment
// under the scroll lock, which sec 4.6 of the refactor plan explicitly forbids. Keeping it
// lockless is correct and matches the pre-refactor behavior (audit fix #6).
void scrollSessionMarkStoppedByButton(const String& button, const String& source) {
    ++runtimeState().scrollStopEventSeq;
    runtimeState().scrollStopEventMs     = millis();
    assignText(runtimeState().scrollStopEventButton, button.c_str());
    assignText(runtimeState().scrollStopEventSource, source.c_str());
    assignText(runtimeState().scrollStopEventReason, runtimeState().lastReason);
    touchRuntimeState();
}

ScrollUploadTxn scrollSessionBeginUpload(const ScrollUploadMeta& upload) {
    ScrollUploadTxn txn;
    txn.append = false;

    withScrollLock([&]() {
        // Audit M1: when a staging buffer exists, assemble the replacement timeline off to
        // the side and leave the active (possibly playing) timeline completely untouched, so
        // an interrupted/failed upload never loses the running scroll. Without the second
        // buffer, fall back to the legacy in-place reset.
        const bool staged = runtimeScrollDoubleBuffered();
        txn.staged = staged;

        if (staged) {
            runtimeState().scrollStagingFrameCount = 0;
            runtimeState().scrollStagingInProgress = true;
            runtimeState().scrollStagingIntervalMs = runtimeState().scrollIntervalMs;
            clearScrollTimelineMetaStagingLocked();
        } else {
            runtimeState().scrollFrameCount = 0;
            runtimeState().scrollFrameIndex = 0;
            clearScrollTimelineMetaLocked();
        }

        ScrollTimelineMeta& meta = staged ? runtimeScrollStagingMeta() : runtimeScrollMeta();
        char* sourceTextBuf = staged ? runtimeScrollStagingSourceText() : runtimeScrollSourceText();
        const bool sourceTextReady = staged ? runtimeScrollStagingSourceTextReady()
                                            : runtimeScrollSourceTextReady();
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
        if (upload.sourceText && sourceTextReady) {
            memcpy(sourceTextBuf, upload.sourceText, static_cast<size_t>(upload.sourceTextBytes) + 1U);
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

    // P1-6: a fresh upload starts the inactivity clock and clears any prior stale flag.
    sScrollUploadActivityMs   = millis();
    sScrollUploadStaleCleared = false;
    return txn;
}

ScrollUploadTxn scrollSessionBeginAppend() {
    ScrollUploadTxn txn;
    txn.append = true;

    withScrollLock([&]() {
        // Audit M1: an append chunk belongs to the staged replacement upload when one is in
        // progress; otherwise it extends the active timeline in place (legacy behavior, also
        // the path taken on single-buffer boards).
        const bool staged = runtimeScrollDoubleBuffered() &&
                            runtimeState().scrollStagingInProgress;
        txn.staged = staged;
        const ScrollTimelineMeta& meta = staged ? runtimeScrollStagingMeta() : runtimeScrollMeta();
        txn.timelineBacked      = meta.timelineId[0] != '\0';
        txn.uploadComplete      = meta.uploadComplete;
        txn.nextChunkIndex      = meta.nextChunkIndex;
        txn.framesReceivedBase  = meta.framesReceived;
        txn.totalFramesExpected = meta.totalFramesExpected;
        txn.baseIndex           = staged ? runtimeState().scrollStagingFrameCount
                                         : runtimeState().scrollFrameCount;
        memcpy(txn.timelineId, meta.timelineId, sizeof(txn.timelineId));
    });

    return txn;
}

bool scrollSessionWriteFrame(const ScrollUploadTxn& txn, uint16_t index, const uint8_t* packedBits) {
    if (!packedBits || index >= MAX_SCROLL_FRAMES) return false;

    // Audit M1: a staged write lands in the off-screen staging buffer, which the render
    // task never reads, so it can never corrupt the running timeline. The legacy in-place
    // path still writes only indices at/after the current frame count, which the render
    // task never reads either -- hence the memcpy stays safely outside the scroll lock.
    bool writable = false;
    withScrollLock([&]() {
        const uint16_t cursorCount = txn.staged ? runtimeState().scrollStagingFrameCount
                                                : runtimeState().scrollFrameCount;
        writable = index >= cursorCount || (!txn.append && cursorCount == 0);
    });
    if (!writable) return false;

    uint8_t* target = txn.staged ? runtimeScrollStagingFrameBits(index)
                                 : runtimeScrollFrameBits(index);
    if (!target) return false;
    memcpy(target, packedBits, FRAME_BYTES);
    return true;
}

ScrollUploadResult scrollSessionCommitUpload(const ScrollUploadTxn& txn, uint16_t count,
                                             bool hasExplicitTiming, uint16_t intervalMs) {
    ScrollUploadResult result;

    withScrollLock([&]() {
        if (txn.staged) {
            // Audit M1: accumulate into the staging timeline only. The active (possibly
            // playing) timeline is left untouched here; the atomic swap that makes the new
            // timeline live happens later in scrollSessionPromoteStaging(), driven by
            // handleApiScroll's shouldStart decision (which correctly covers both
            // timeline-backed and legacy totalFrames==0 uploads). Interval is recorded now
            // but only applied to scrollIntervalMs at promotion, so the old timeline is
            // never re-timed mid-upload.
            const uint16_t stagedCount = static_cast<uint16_t>(txn.baseIndex + count);
            runtimeState().scrollStagingFrameCount = stagedCount;
            if (hasExplicitTiming) {
                runtimeState().scrollStagingIntervalMs =
                    constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
            }

            ScrollTimelineMeta& smeta = runtimeScrollStagingMeta();
            smeta.framesReceived = static_cast<uint16_t>(txn.framesReceivedBase + count);
            if (txn.append) smeta.nextChunkIndex = static_cast<uint16_t>(txn.nextChunkIndex + 1U);
            if (smeta.totalFramesExpected > 0 && smeta.framesReceived >= smeta.totalFramesExpected) {
                smeta.uploadComplete = true;
            }

            result.frameCount     = stagedCount;
            result.uploadComplete = smeta.uploadComplete;
            memcpy(result.timelineId, smeta.timelineId, sizeof(result.timelineId));
            return;
        }

        // Legacy in-place path (single-buffer boards, or appends extending the active
        // timeline). Unchanged behavior.
        runtimeState().scrollFrameCount = static_cast<uint16_t>(txn.baseIndex + count);
        if (!txn.append || (!runtimeState().firmwareScrollActive && !runtimeState().firmwareScrollPaused)) {
            runtimeState().scrollFrameIndex = 0;
        }
        if (hasExplicitTiming) {
            runtimeState().scrollIntervalMs =
                constrain(intervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
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

    // P1-6: each accepted chunk refreshes the inactivity clock.
    sScrollUploadActivityMs = millis();
    return result;
}

// P1-6: reclaim a staged replacement timeline left in progress by an interrupted upload
// (no chunk activity for timeoutMs). Only the off-screen staging buffer is touched, so
// the active/playing timeline is never disturbed. Single-buffer boards are intentionally
// left alone (an incomplete in-place upload is non-playable per D2 and is overwritten by
// the next upload). Returns true if a stale upload was cleared.
bool scrollSessionClearStaleUpload(uint32_t timeoutMs) {
    bool cleared = false;
    withScrollLock([&]() {
        if (!runtimeScrollDoubleBuffered()) return;
        if (!runtimeState().scrollStagingInProgress) return;
        if (runtimeScrollStagingMeta().uploadComplete) return;
        if (sScrollUploadActivityMs == 0) return;
        if (millis() - sScrollUploadActivityMs < timeoutMs) return;
        runtimeState().scrollStagingFrameCount = 0;
        runtimeState().scrollStagingInProgress = false;
        invalidateScrollStagingUploadLocked();
        cleared = true;
    });
    if (cleared) {
        sScrollUploadActivityMs   = 0;
        sScrollUploadStaleCleared = true;
        RLOG_WARN("SCROLL", "event=upload_stale_cleared timeout_ms=%u",
                  static_cast<unsigned>(timeoutMs));
    }
    return cleared;
}

// One-shot read of the "a stale upload was cleared" flag for status reporting.
bool scrollSessionConsumeUploadStaleCleared() {
    if (!sScrollUploadStaleCleared) return false;
    sScrollUploadStaleCleared = false;
    return true;
}

bool scrollSessionPromoteStaging() {
    bool promoted = false;
    withScrollLock([&]() {
        if (!runtimeScrollDoubleBuffered() || !runtimeState().scrollStagingInProgress) return;
        if (runtimeState().scrollStagingFrameCount == 0) return;
        // Audit M1: atomic swap of the just-uploaded staging timeline into the active slot,
        // under the same scroll lock the render task uses. The render task therefore only
        // ever sees the old buffer or the fully-written new buffer, never a partial write.
        runtimeCommitScrollStagingSwap();
        runtimeState().scrollFrameCount        = runtimeState().scrollStagingFrameCount;
        runtimeState().scrollFrameIndex        = 0;
        runtimeState().scrollIntervalMs        = runtimeState().scrollStagingIntervalMs;
        runtimeState().scrollStagingInProgress = false;
        runtimeState().scrollStagingFrameCount = 0;
        promoted = true;
    });
    if (promoted) {
        RLOG_INFO("SCROLL", "event=staging_swap frames=%u interval_ms=%u",
                  static_cast<unsigned>(runtimeState().scrollFrameCount),
                  static_cast<unsigned>(runtimeState().scrollIntervalMs));
    }
    return promoted;
}

void scrollSessionInvalidateCache() {
    withScrollLock([]() {
        if (runtimeScrollDoubleBuffered() && runtimeState().scrollStagingInProgress) {
            // Audit M1: a staged upload failed mid-stream (bad frame / overflow). Discard the
            // half-built staging timeline and leave the running active timeline untouched.
            runtimeState().scrollStagingFrameCount = 0;
            runtimeState().scrollStagingInProgress = false;
            invalidateScrollStagingUploadLocked();
            return;
        }
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

        // Hardware -> WebUI source-text recovery is only valid while the LED panel
        // is actually displaying text scrolling, including a user/system pause.
        // Cached uploads that are not currently displayed must not resurrect an old
        // string after Stop/Clear or a mode switch.
        const bool displayingScroll = runtimeState().firmwareScrollActive ||
                                      runtimeState().firmwareScrollPaused;
        if (!displayingScroll) {
            out.meta.timelineId[0]       = '\0';
            out.meta.fontId[0]           = '\0';
            out.meta.generatorVersion[0] = '\0';
            out.meta.sourceTextByteLength = 0;
            out.meta.totalFramesExpected  = 0;
            out.meta.framesReceived       = 0;
            out.meta.nextChunkIndex       = 0;
            out.meta.uiFps                = 0;
            out.meta.uploadComplete       = false;
            out.meta.hasSourceText        = false;
            out.frameCount                = 0;
            out.frameIndex                = 0;
        } else if (out.meta.hasSourceText && runtimeScrollSourceTextReady()) {
            // A null textBuf means the caller wants lightweight metadata only (e.g.
            // the polled /api/scroll/meta path): skip the text copy but keep
            // hasSourceText / sourceTextByteLength populated so the WebUI knows text
            // is available to fetch on demand. This is NOT a failure.
            if (textBuf == nullptr) {
                // intentionally no copy; copied stays true
            } else {
                const size_t bytesToCopy = static_cast<size_t>(out.meta.sourceTextByteLength) + 1U;
                if (textBufSize >= bytesToCopy) {
                    memcpy(textBuf, runtimeScrollSourceText(), bytesToCopy);
                } else {
                    copied = false;
                }
            }
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

    const uint16_t intervalMs = constrain(
        runtimeState().scrollIntervalMs, MIN_SCROLL_INTERVAL_MS, MAX_SCROLL_INTERVAL_MS);
    const uint32_t elapsedMs = now - runtimeState().lastScrollFrameMs;
    if (elapsedMs < intervalMs) return false;

    runtimeState().scrollFrameIndex =
        (runtimeState().scrollFrameIndex + 1) % runtimeState().scrollFrameCount;

    if (elapsedMs <= static_cast<uint32_t>(intervalMs) * SCROLL_DRIFT_RESET_INTERVALS) {
        runtimeState().lastScrollFrameMs += intervalMs;
    } else {
        runtimeState().lastScrollFrameMs = now;
    }

    memcpy(outFrameBits, runtimeScrollFrameBits(runtimeState().scrollFrameIndex), FRAME_BYTES);
    return true;
}
