#pragma once
#include <Arduino.h>
#include <string.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "config.h"

// Bounded assignment into a fixed-size runtime text field. Truncates instead of
// growing, never allocates, and always null-terminates. This replaces long-lived
// Arduino String members in RuntimeState/RuntimeFace, whose repeated reassignment
// from varying WebUI / saved-face / command input was a source of internal-heap
// fragmentation over long uptime (audit P1 #2/#3). Compare these fields with
// strcmp(), NOT ==, since == on a decayed char* is a pointer comparison.
template <size_t N>
inline void assignText(char (&dst)[N], const char* src) {
    strlcpy(dst, src ? src : "", N);
}

// This header file defines the firmware shared runtime state, saved face cache, and RuntimeStore
// singleton interface. When reading/writing these fields across modules, the caller must protect them according to the lock strategy in sync.h.

// Runtime state
// Statistical counters, text scrolling state, and deferred recovery flags.
//
// Lock/owner contract:
// - colorR/colorG/colorB/brightness/lastM370 are updated with frameMutex when
//   they can affect rendering; Core 1 snapshots them before LED output.
// - firmwareScroll* and scrollFrame* fields are guarded by scrollMutex.
// - mode/playback/lastReason/auto* counters and persistence counters are
//   Core-0 cooperative-loop state. Do not write them from Core 1 or an ISR
//   without adding an explicit lock/ownership change.
// - stateVersion/slowUiDirty are publish cursors for the WebUI; preserve the
//   existing monotonic non-zero version behavior.
struct RuntimeState {
    // Fixed char buffers instead of Arduino String (audit P1 #2): no heap, no
    // fragmentation. Defaults are set in the constructor below. Always assign with
    // assignText() and compare with strcmp().
    char     colorHex[8]         = {0};   // "#RRGGBB"
    uint8_t  colorR              = 0xf9;
    uint8_t  colorG              = 0x71;
    uint8_t  colorB              = 0xd4;
    uint8_t  brightness          = DEFAULT_BRIGHTNESS;
    char     mode[12]            = {0};   // "manual" / "auto"
    char     playback[24]        = {0};   // "idle" / "auto_saved_face" / "scroll" ...
    char     lastM370[5 + M370_HEX_CHARS + 1] = {0};  // holds "M370:" + 93 hex
    char     lastReason[M370_FRAME_REASON_CHARS] = {0};
    bool     paused              = false;

    uint32_t framesAccepted      = 0;
    uint32_t framesRejected      = 0;
    uint32_t framesQueued        = 0;
    uint32_t framesDequeued      = 0;
    uint32_t framesDropped       = 0;
    uint32_t commandsAccepted    = 0;
    uint32_t commandsRejected    = 0;
    uint32_t savedFacesWrites    = 0;
    uint32_t settingsWrites      = 0;
    uint32_t bootMs              = 0;
    uint32_t stateVersion        = 1;
    bool     slowUiDirty         = false;
    uint32_t lastSlowUiPublishMs = 0;

    uint32_t autoIntervalMs      = DEFAULT_AUTO_INTERVAL_MS;
    uint32_t lastAutoSwitchMs    = 0;
    uint16_t autoFaceIndex       = 0;

    bool     firmwareScrollActive  = false;
    bool     firmwareScrollPaused  = false;
    bool     firmwareScrollUserPaused = false;
    bool     firmwareScrollSystemPaused = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount      = 0;
    uint16_t scrollFrameIndex      = 0;
    uint16_t scrollIntervalMs      = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t lastScrollFrameMs     = 0;

    // Atomic timeline replacement (audit M1). When a PSRAM staging buffer is available,
    // a replacement upload (append:false ... commit) is written OFF to the side while the
    // current timeline keeps playing; only on uploadComplete is the staging buffer swapped
    // in atomically (under scrollMutex). These two fields track the in-progress staged
    // upload; they are scrollMutex-guarded like the other scroll* fields. On boards without
    // the second buffer they stay 0/false and uploads fall back to the legacy in-place path.
    uint16_t scrollStagingFrameCount  = 0;
    bool     scrollStagingInProgress  = false;
    // Interval the new (staged) timeline should play at; applied to scrollIntervalMs only
    // at the atomic swap, so the still-running old timeline is not re-timed mid-upload.
    uint16_t scrollStagingIntervalMs  = DEFAULT_SCROLL_INTERVAL_MS;

    // Front-end polls sequence on page 6.4, no need to pull full frame data.
    uint32_t scrollStopEventSeq       = 0;
    uint32_t scrollStopEventMs        = 0;
    char     scrollStopEventButton[16] = {0};
    char     scrollStopEventSource[24] = {0};
    char     scrollStopEventReason[M370_FRAME_REASON_CHARS] = {0};

    // But the LED render task still has time to physically latch all-black frames.
    bool     deferredFaceRestoreActive  = false;
    uint8_t  deferredFaceRestoreKind    = 0;
    bool     deferredFaceRestoreAutoMode = false;
    uint32_t deferredFaceRestoreDueMs   = 0;
    char     deferredFaceRestoreReason[M370_FRAME_REASON_CHARS] = {0};

    RuntimeState() {
        strlcpy(colorHex,   DEFAULT_COLOR,    sizeof(colorHex));
        strlcpy(mode,       DEFAULT_MODE,     sizeof(mode));
        strlcpy(playback,   DEFAULT_PLAYBACK, sizeof(playback));
        strlcpy(lastReason, "boot",           sizeof(lastReason));
    }
};

struct FrameStateSnapshot {
    char     colorHex[8] = {0};
    uint8_t  brightness  = 0;
    char     lastM370[5 + M370_HEX_CHARS + 1] = {0};
    // Sized to hold the longest runtime reason strings (e.g.
    // "firmware_text_scroll_stop_default_saved_face"); a shorter buffer silently
    // truncated /api/status reason fields and diverged from /api/command.
    char     lastReason[M370_FRAME_REASON_CHARS] = {0};
    uint16_t litLeds        = 0;
    uint32_t framesAccepted = 0;
};

// Scroll timeline metadata (text-backed scroll uploads)
// Allows WebUI refresh / second device to recover text from firmware and reconstruct preview frames locally.
//
// Invariant (EH-C):
// meta.timelineId[0] != '\0' means this is a timeline-backed cache:
//   - totalFramesExpected must be > 0 (enforced at upload),
//   - uploadComplete is authoritative,
//   - start_scroll must reject while uploadComplete == false.
// framesTimelineId on the WebUI side mirrors EXACT local preview identity only,
// never an approximate match.
//
// Lock contract: meta and the source-text buffer are guarded by scrollMutex
// (sync.h withScrollLock). Copy under lock, serialize outside; no heap String
// writes inside the lock.
struct ScrollTimelineMeta {
    char     timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1]     = {0};
    char     fontId[MAX_SCROLL_FONT_ID_CHARS + 1]             = {0};
    char     generatorVersion[MAX_SCROLL_GENERATOR_CHARS + 1] = {0};
    uint16_t sourceTextByteLength = 0;
    uint16_t totalFramesExpected  = 0;
    uint16_t framesReceived       = 0;
    uint16_t nextChunkIndex       = 0;
    uint8_t  uiFps                = 0;
    bool     uploadComplete       = false;
    bool     hasSourceText        = false;
};

// Saved face metadata
// Default flag and startup default flag, shared by auto carousel and WebUI lists.
struct RuntimeFace {
    // Fixed buffers instead of String (audit P1 #2/#3): inline storage means stale
    // entries beyond autoFaceCount() never retain heap capacity across reloads.
    // m370 must hold "M370:" + 93 hex (98 chars) -- a smaller buffer would silently
    // corrupt face data. Assign with assignText(), compare id/name with strcmp().
    char     id[32]          = {0};
    char     name[64]        = {0};
    char     m370[5 + M370_HEX_CHARS + 1] = {0};
    int32_t  order           = 0;
    uint16_t jsonIndex       = 0;
    bool     isDefault       = false;
    bool     isStartupDefault = false;
};

// Runtime store
// Global variables; specific locking is still determined by the caller or helper based on operational semantics.
class RuntimeStore final {
public:
    static RuntimeStore& instance();

    RuntimeState& state() { return state_; }

    const RuntimeState& state() const { return state_; }

    RuntimeFace* autoFaces() { return autoFaces_; }

    const RuntimeFace* autoFaces() const { return autoFaces_; }

    uint16_t& autoFaceCount() { return autoFaceCount_; }

    const uint16_t& autoFaceCount() const { return autoFaceCount_; }

    uint8_t* frameBits() { return frameBits_; }

    const uint8_t* frameBits() const { return frameBits_; }

    bool initScrollFrameBuffer();

    bool scrollFrameBufferReady() const { return activeScrollBuffer() != nullptr; }

    bool scrollFrameBufferInPsram() const { return scrollFrameBitsInPsram_; }

    uint8_t* scrollFrameBits(uint16_t index);

    const uint8_t* scrollFrameBits(uint16_t index) const;

    // Audit M1 -- atomic timeline replacement support.
    // active buffer  = the timeline currently displayed / advanced by the render task.
    // staging buffer = where a replacement upload is assembled; swapped in on commit.
    // When the second buffer is unavailable the staging accessor aliases the active
    // buffer, so callers transparently fall back to the legacy in-place upload.
    bool scrollDoubleBuffered() const { return scrollDoubleBuffered_; }

    uint8_t* scrollStagingFrameBits(uint16_t index);

    ScrollTimelineMeta& scrollMeta() { return scrollMeta_; }

    const ScrollTimelineMeta& scrollMeta() const { return scrollMeta_; }

    ScrollTimelineMeta& scrollStagingMeta() { return scrollDoubleBuffered_ ? scrollStagingMeta_ : scrollMeta_; }

    char* scrollSourceText() { return scrollSourceText_; }

    const char* scrollSourceText() const { return scrollSourceText_; }

    bool scrollSourceTextReady() const { return scrollSourceText_ != nullptr; }

    char* scrollStagingSourceText() { return scrollDoubleBuffered_ ? scrollStagingSourceText_ : scrollSourceText_; }

    bool scrollStagingSourceTextReady() const {
        return (scrollDoubleBuffered_ ? scrollStagingSourceText_ : scrollSourceText_) != nullptr;
    }

    // Atomically promote the staging timeline to active: toggles the render buffer and
    // swaps the meta struct + source-text pointer. Must be called under scrollMutex.
    // No-op (returns false) when not double-buffered -- the in-place path needs no swap.
    bool commitScrollStagingSwap();

    bool& fsMounted() { return fsMounted_; }

    const bool& fsMounted() const { return fsMounted_; }

private:
    RuntimeStore() = default;
    RuntimeStore(const RuntimeStore&) = delete;
    RuntimeStore& operator=(const RuntimeStore&) = delete;

    // Active-buffer helpers for the double-buffered scroll cache (audit M1). When
    // scrollDoubleBuffered_ is false, scrollFrameBitsB_ is null, scrollRenderBuffer_
    // stays 0, and both helpers return scrollFrameBits_ (legacy single-buffer layout).
    uint8_t* activeScrollBuffer() {
        return scrollRenderBuffer_ == 0 ? scrollFrameBits_ : scrollFrameBitsB_;
    }
    const uint8_t* activeScrollBuffer() const {
        return scrollRenderBuffer_ == 0 ? scrollFrameBits_ : scrollFrameBitsB_;
    }
    uint8_t* stagingScrollBuffer() {
        if (!scrollDoubleBuffered_) return scrollFrameBits_;
        return scrollRenderBuffer_ == 0 ? scrollFrameBitsB_ : scrollFrameBits_;
    }

    RuntimeState state_;
    RuntimeFace  autoFaces_[MAX_AUTO_FACES] = {};
    uint16_t     autoFaceCount_ = 0;
    uint8_t      frameBits_[FRAME_BYTES] = {};
    // Large buffer in internal SRAM.
    uint8_t*     scrollFrameBits_ = nullptr;
    bool         scrollFrameBitsInPsram_ = false;
    // Second scroll cache for atomic timeline replacement (audit M1). Allocated only on
    // PSRAM boards; null => single-buffer in-place uploads (legacy behavior).
    uint8_t*     scrollFrameBitsB_ = nullptr;
    bool         scrollDoubleBuffered_ = false;
    uint8_t      scrollRenderBuffer_ = 0;   // 0 => A is active, 1 => B is active
    // On allocation failure, text uploads with metadata return 507, while pure frame uploads are unaffected.
    ScrollTimelineMeta scrollMeta_;
    ScrollTimelineMeta scrollStagingMeta_;
    char*        scrollSourceText_ = nullptr;
    char*        scrollStagingSourceText_ = nullptr;
    bool         fsMounted_ = false;
};

RuntimeState& runtimeState();

RuntimeFace* runtimeAutoFaces();

uint16_t& runtimeAutoFaceCount();

uint8_t* runtimeFrameBits();

bool initRuntimeScrollFrameBuffer();

bool runtimeScrollFrameBufferReady();

bool runtimeScrollFrameBufferInPsram();

size_t runtimeScrollFrameBufferBytes();

uint8_t* runtimeScrollFrameBits(uint16_t index);

// Audit M1 -- staging-side accessors for atomic timeline replacement. These alias the
// active-side accessors on boards without the second PSRAM buffer.
bool runtimeScrollDoubleBuffered();

uint8_t* runtimeScrollStagingFrameBits(uint16_t index);

bool runtimeCommitScrollStagingSwap();

ScrollTimelineMeta& runtimeScrollMeta();

ScrollTimelineMeta& runtimeScrollStagingMeta();

char* runtimeScrollSourceText();

bool runtimeScrollSourceTextReady();

char* runtimeScrollStagingSourceText();

bool runtimeScrollStagingSourceTextReady();

// Must be called within withScrollLock. EH-A: Bad frame data invalidates the playback cache,
// but sourceText is intentionally preserved (recovery can still reconstruct the preview from text).
// Call points: append:false reset, m370ToPackedBits failure path, E1 frame count limit rejection,
// any future buffer clears.
void invalidateScrollUploadLocked();

// Must be called within withScrollLock. Full clear (including source text);
// executed at the start of each append:false upload.
void clearScrollTimelineMetaLocked();

// Audit M1 -- staging-side equivalents, operating on the staging meta/source-text when
// double-buffered (alias the active-side versions otherwise). Call under withScrollLock.
void invalidateScrollStagingUploadLocked();

void clearScrollTimelineMetaStagingLocked();

bool& runtimeFsMounted();

uint32_t runtimeStateVersion();

void touchRuntimeState();

void touchRuntimeStateSlow();

void serviceRuntimeSlowStatePublish();
