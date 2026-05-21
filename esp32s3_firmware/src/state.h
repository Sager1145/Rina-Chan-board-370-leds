#pragma once
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "config.h"

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------
struct RuntimeState {
    String   colorHex            = DEFAULT_COLOR;
    uint8_t  colorR              = 0xf9;
    uint8_t  colorG              = 0x71;
    uint8_t  colorB              = 0xd4;
    uint8_t  brightness          = DEFAULT_BRIGHTNESS;
    String   mode                = DEFAULT_MODE;
    String   playback            = DEFAULT_PLAYBACK;
    String   lastM370;
    String   lastReason          = "boot";
    bool     paused              = false;

    // Stats
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

    // Auto-playback
    uint32_t autoIntervalMs      = DEFAULT_AUTO_INTERVAL_MS;
    uint32_t lastAutoSwitchMs    = 0;
    uint16_t autoFaceIndex       = 0;

    // Scroll
    bool     firmwareScrollActive  = false;
    bool     firmwareScrollPaused  = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount      = 0;
    uint16_t scrollFrameIndex      = 0;
    uint16_t scrollIntervalMs      = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t lastScrollFrameMs     = 0;

    // WebUI notification marker for GPIO B1/B2/B3 interrupting firmware scroll.
    // The frontend polls this lightweight sequence while the 6.4 scroll page is active.
    uint32_t scrollStopEventSeq       = 0;
    uint32_t scrollStopEventMs        = 0;
    String   scrollStopEventButton;
    String   scrollStopEventSource;
    String   scrollStopEventReason;

    // Deferred face restore after an explicit all-off clear frame.
    // Used to avoid delay() inside HTTP / button handlers while still
    // giving the LED render task enough time to physically latch blank.
    bool     deferredFaceRestoreActive  = false;
    uint8_t  deferredFaceRestoreKind    = 0;
    bool     deferredFaceRestoreAutoMode = false;
    uint32_t deferredFaceRestoreDueMs   = 0;
    String   deferredFaceRestoreReason;
};

// ---------------------------------------------------------------------------
// Saved face record (runtime copy of one face from saved_faces.json)
// ---------------------------------------------------------------------------
struct RuntimeFace {
    String   id;
    String   name;
    String   m370;
    int32_t  order           = 0;
    uint16_t jsonIndex       = 0;
    bool     isDefault       = false;
    bool     isStartupDefault = false;
};

// ---------------------------------------------------------------------------
// RuntimeStore
// ---------------------------------------------------------------------------
// Centralizes mutable runtime storage so modules no longer link directly
// against exposed extern globals.  Access is still intentionally lightweight:
// locking policy stays in the caller/helper that owns the operation.
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
    bool scrollFrameBufferReady() const { return true; }
    bool scrollFrameBufferInPsram() const { return scrollFrameBitsInPsram_; }
    uint8_t* scrollFrameBits(uint16_t index);
    const uint8_t* scrollFrameBits(uint16_t index) const;

    bool& fsMounted() { return fsMounted_; }
    const bool& fsMounted() const { return fsMounted_; }

private:
    RuntimeStore() = default;
    RuntimeStore(const RuntimeStore&) = delete;
    RuntimeStore& operator=(const RuntimeStore&) = delete;

    RuntimeState state_;
    RuntimeFace  autoFaces_[MAX_AUTO_FACES] = {};
    uint16_t     autoFaceCount_ = 0;
    uint8_t      frameBits_[FRAME_BYTES] = {};
    uint8_t      fallbackScrollFrameBits_[MAX_SCROLL_FRAMES][FRAME_BYTES] = {};
    uint8_t*     scrollFrameBits_ = nullptr;
    bool         scrollFrameBitsInPsram_ = false;
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
bool& runtimeFsMounted();
uint32_t runtimeStateVersion();
void touchRuntimeState();
void touchRuntimeStateSlow();
void serviceRuntimeSlowStatePublish();
