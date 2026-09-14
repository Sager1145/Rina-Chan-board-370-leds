#pragma once
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "config.h"

// 本头文件定义固件共享运行时状态、保存表情缓存和 RuntimeStore
// 单例接口。跨模块读写这些字段时，调用方需要按 sync.h 的锁策略保护。

// Runtime state
// 统计计数、文字滚动状态和延迟恢复标记。
//
// Lock/owner contract:
// - colorR/colorG/colorB/brightness/current frame bits are updated with frameMutex
//   when they can affect rendering; Core 1 snapshots them before LED output.
// - firmwareScroll* and scrollFrame* fields are guarded by scrollMutex.
// - mode/playback/lastReason/auto* counters and persistence counters are
//   Core-0 cooperative-loop state. Do not write them from Core 1 or an ISR
//   without adding an explicit lock/ownership change.
// - stateVersion/slowUiDirty are publish cursors for RinaLink EV_STATUS; preserve the
//   existing monotonic non-zero version behavior.
struct RuntimeState {
    String colorHex = DEFAULT_COLOR;
    uint8_t colorR = 0xf9;
    uint8_t colorG = 0x71;
    uint8_t colorB = 0xd4;
    uint8_t brightness = DEFAULT_BRIGHTNESS;
    String mode = DEFAULT_MODE;
    String playback = DEFAULT_PLAYBACK;
    // Stable owner of the pixels currently driven by the board. Unlike lastReason,
    // this is not changed by color/brightness refreshes or temporary overlays.
    String outputMode = "control";
    char outputStreamID[37] = {0};
    uint32_t outputPositionMs = 0;
    // User-visible board name. Empty means "use the MAC-derived default"
    // (RinaBoard-AABBCCDDEEFF); see bleTransportDeviceName(). Core-0 cooperative state,
    // persisted in runtime_settings.json.
    String deviceName;
    char lastReason[PACKED_FRAME_REASON_CHARS] = "boot";
    bool paused = false;

    uint32_t framesAccepted = 0;
    uint32_t framesRejected = 0;
    uint32_t framesQueued = 0;
    uint32_t framesDequeued = 0;
    uint32_t framesDropped = 0;
    uint32_t commandsAccepted = 0;
    uint32_t commandsRejected = 0;
    uint32_t savedFacesWrites = 0;
    uint32_t settingsWrites = 0;
    uint32_t bootMs = 0;
    uint32_t stateVersion = 1;
    bool slowUiDirty = false;
    uint32_t lastSlowUiPublishMs = 0;

    uint32_t autoIntervalMs = DEFAULT_AUTO_INTERVAL_MS;
    uint32_t lastAutoSwitchMs = 0;
    uint16_t autoFaceIndex = 0;

    bool firmwareScrollActive = false;
    bool firmwareScrollPaused = false;
    bool firmwareScrollUserPaused = false;
    bool firmwareScrollSystemPaused = false;
    bool restoreAutoAfterScroll = false;
    bool scrollLoop = true;
    uint16_t scrollFrameCount = 0;
    uint16_t scrollFrameIndex = 0;
    uint16_t scrollIntervalMs = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t lastScrollFrameMs = 0;

    bool deferredFaceRestoreActive = false;
    uint8_t deferredFaceRestoreKind = 0;
    bool deferredFaceRestoreAutoMode = false;
    uint32_t deferredFaceRestoreDueMs = 0;
    String deferredFaceRestoreReason;
};

struct OutputFrameDescriptor {
    char mode[12] = "control";
    char streamID[37] = {0};
    uint32_t positionMs = 0;
};

struct FrameStateSnapshot {
    char colorHex[8] = {0};
    uint8_t brightness = 0;
    char lastReason[PACKED_FRAME_REASON_CHARS] = {0};
    uint16_t litLeds = 0;
    uint32_t framesAccepted = 0;
};

struct ScrollTimelineMeta {
    char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};
    char fontId[MAX_SCROLL_FONT_ID_CHARS + 1] = {0};
    char generatorVersion[MAX_SCROLL_GENERATOR_CHARS + 1] = {0};
    uint16_t sourceTextByteLength = 0;
    uint16_t totalFramesExpected = 0;
    uint16_t framesReceived = 0;
    uint16_t nextChunkIndex = 0;
    uint8_t uiFps = 0;
    bool uploadComplete = false;
    bool hasSourceText = false;
};

struct RuntimeFace {
    String id;
    String name;
    uint8_t frameBits[FRAME_BYTES] = {};
    int32_t order = 0;
    uint16_t jsonIndex = 0;
    bool isDefault = false;
    bool isStartupDefault = false;
};

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
    bool scrollFrameBufferReady() const { return scrollFrameBits_ != nullptr; }
    uint8_t* scrollFrameBits(uint16_t index);
    const uint8_t* scrollFrameBits(uint16_t index) const;
    ScrollTimelineMeta& scrollMeta() { return scrollMeta_; }
    const ScrollTimelineMeta& scrollMeta() const { return scrollMeta_; }
    char* scrollSourceText() { return scrollSourceText_; }
    const char* scrollSourceText() const { return scrollSourceText_; }
    bool scrollSourceTextReady() const { return scrollSourceText_ != nullptr; }
    bool& fsMounted() { return fsMounted_; }
    const bool& fsMounted() const { return fsMounted_; }

  private:
    RuntimeStore() = default;
    RuntimeStore(const RuntimeStore&) = delete;
    RuntimeStore& operator=(const RuntimeStore&) = delete;

    RuntimeState state_;
    RuntimeFace autoFaces_[MAX_AUTO_FACES] = {};
    uint16_t autoFaceCount_ = 0;
    uint8_t frameBits_[FRAME_BYTES] = {};
    uint8_t* scrollFrameBits_ = nullptr;
    bool scrollFrameBitsInPsram_ = false;
    ScrollTimelineMeta scrollMeta_;
    char* scrollSourceText_ = nullptr;
    bool fsMounted_ = false;
};

RuntimeState& runtimeState();
RuntimeFace* runtimeAutoFaces();
uint16_t& runtimeAutoFaceCount();
uint8_t* runtimeFrameBits();
bool initRuntimeScrollFrameBuffer();
bool runtimeScrollFrameBufferReady();
uint8_t* runtimeScrollFrameBits(uint16_t index);
ScrollTimelineMeta& runtimeScrollMeta();
char* runtimeScrollSourceText();
bool runtimeScrollSourceTextReady();
void invalidateScrollUploadLocked();
void clearScrollTimelineMetaLocked();
bool& runtimeFsMounted();
uint32_t runtimeStateVersion();
void touchRuntimeState();
void touchRuntimeStateSlow();
void serviceRuntimeSlowStatePublish();

// SET_FRAME reasons may be either a legacy exact mode name or
// <mode>:<canonical UUID>:<uint32 positionMs>. Malformed stream metadata does
// not prevent recognizing the mode, but is never exposed as a resumable stream.
void parseOutputFrameReason(const char* reason, OutputFrameDescriptor& out);
void setRuntimeOutputMode(const char* mode, const char* streamID = nullptr,
                          uint32_t positionMs = 0);
void setRuntimeOutputFromFrameReason(const char* reason);
