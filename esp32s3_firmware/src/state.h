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
    bool     firmwareScrollUserPaused = false;
    bool     firmwareScrollSystemPaused = false;
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
    /**
     * @brief Access the singleton runtime store.
     * @param None.
     * @return Mutable RuntimeStore instance.
     */
    static RuntimeStore& instance();

    /**
     * @brief Access mutable runtime state.
     * @param None.
     * @return RuntimeState reference.
     */
    RuntimeState& state() { return state_; }

    /**
     * @brief Access read-only runtime state.
     * @param None.
     * @return Const RuntimeState reference.
     */
    const RuntimeState& state() const { return state_; }

    /**
     * @brief Access runtime saved-face slots.
     * @param None.
     * @return Pointer to first RuntimeFace slot.
     */
    RuntimeFace* autoFaces() { return autoFaces_; }

    /**
     * @brief Access read-only runtime saved-face slots.
     * @param None.
     * @return Const pointer to first RuntimeFace slot.
     */
    const RuntimeFace* autoFaces() const { return autoFaces_; }

    /**
     * @brief Access mutable saved-face count.
     * @param None.
     * @return Saved-face count reference.
     */
    uint16_t& autoFaceCount() { return autoFaceCount_; }

    /**
     * @brief Access read-only saved-face count.
     * @param None.
     * @return Const saved-face count reference.
     */
    const uint16_t& autoFaceCount() const { return autoFaceCount_; }

    /**
     * @brief Access mutable active packed frame bits.
     * @param None.
     * @return Pointer to FRAME_BYTES bytes.
     */
    uint8_t* frameBits() { return frameBits_; }

    /**
     * @brief Access read-only active packed frame bits.
     * @param None.
     * @return Const pointer to FRAME_BYTES bytes.
     */
    const uint8_t* frameBits() const { return frameBits_; }

    /**
     * @brief Allocate or select the storage backing firmware text-scroll frames.
     * @param None.
     * @return true when a usable scroll-frame buffer is available.
     */
    bool initScrollFrameBuffer();

    /**
     * @brief Report whether scrollFrameBits() points at initialized storage.
     * @param None.
     * @return true after initScrollFrameBuffer() has chosen PSRAM or fallback SRAM.
     */
    bool scrollFrameBufferReady() const { return scrollFrameBits_ != nullptr; }

    /**
     * @brief Report whether scroll-frame storage is in PSRAM.
     * @param None.
     * @return true when PSRAM backs the scroll cache.
     */
    bool scrollFrameBufferInPsram() const { return scrollFrameBitsInPsram_; }

    /**
     * @brief Access mutable scroll-frame bits by index.
     * @param index Scroll-frame index.
     * @return Pointer to FRAME_BYTES bytes, or nullptr.
     */
    uint8_t* scrollFrameBits(uint16_t index);

    /**
     * @brief Access read-only scroll-frame bits by index.
     * @param index Scroll-frame index.
     * @return Const pointer to FRAME_BYTES bytes, or nullptr.
     */
    const uint8_t* scrollFrameBits(uint16_t index) const;

    /**
     * @brief Access mutable filesystem-mounted flag.
     * @param None.
     * @return Filesystem-mounted flag reference.
     */
    bool& fsMounted() { return fsMounted_; }

    /**
     * @brief Access read-only filesystem-mounted flag.
     * @param None.
     * @return Const filesystem-mounted flag reference.
     */
    const bool& fsMounted() const { return fsMounted_; }

private:
    /**
     * @brief Construct singleton runtime storage with default-initialized state.
     * @param None.
     * @return RuntimeStore object.
     */
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

/**
 * @brief Access mutable global runtime state.
 * @param None.
 * @return RuntimeState reference.
 */
RuntimeState& runtimeState();

/**
 * @brief Access loaded saved-face records.
 * @param None.
 * @return Pointer to first RuntimeFace slot.
 */
RuntimeFace* runtimeAutoFaces();

/**
 * @brief Access mutable saved-face count.
 * @param None.
 * @return Saved-face count reference.
 */
uint16_t& runtimeAutoFaceCount();

/**
 * @brief Access active packed frame bits.
 * @param None.
 * @return Pointer to FRAME_BYTES bytes.
 */
uint8_t* runtimeFrameBits();

/**
 * @brief Initialize scroll-frame storage.
 * @param None.
 * @return true when storage is ready.
 */
bool initRuntimeScrollFrameBuffer();

/**
 * @brief Check whether scroll-frame storage is ready.
 * @param None.
 * @return true when runtimeScrollFrameBits() can be used.
 */
bool runtimeScrollFrameBufferReady();

/**
 * @brief Check whether scroll-frame storage is backed by PSRAM.
 * @param None.
 * @return true when PSRAM backs the scroll cache.
 */
bool runtimeScrollFrameBufferInPsram();

/**
 * @brief Return total configured scroll-frame cache bytes.
 * @param None.
 * @return Cache size in bytes.
 */
size_t runtimeScrollFrameBufferBytes();

/**
 * @brief Access a writable scroll-frame slot.
 * @param index Scroll-frame index.
 * @return Pointer to FRAME_BYTES bytes, or nullptr.
 */
uint8_t* runtimeScrollFrameBits(uint16_t index);

/**
 * @brief Access the mutable filesystem-mounted flag.
 * @param None.
 * @return Filesystem-mounted flag reference.
 */
bool& runtimeFsMounted();

/**
 * @brief Read current WebUI/runtime state version.
 * @param None.
 * @return Non-zero version counter.
 */
uint32_t runtimeStateVersion();

/**
 * @brief Bump runtime state version for fast WebUI publication.
 * @param None.
 * @return None.
 */
void touchRuntimeState();

/**
 * @brief Mark slow-changing UI state dirty.
 * @param None.
 * @return None.
 */
void touchRuntimeStateSlow();

/**
 * @brief Publish coalesced slow UI state changes.
 * @param None.
 * @return None.
 */
void serviceRuntimeSlowStatePublish();
