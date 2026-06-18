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
// - colorR/colorG/colorB/brightness/lastM370 are updated with frameMutex when
//   they can affect rendering; Core 1 snapshots them before LED output.
// - firmwareScroll* and scrollFrame* fields are guarded by scrollMutex.
// - mode/playback/lastReason/auto* counters and persistence counters are
//   Core-0 cooperative-loop state. Do not write them from Core 1 or an ISR
//   without adding an explicit lock/ownership change.
// - stateVersion/slowUiDirty are publish cursors for the WebUI; preserve the
//   existing monotonic non-zero version behavior.
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

    // 前端在 6.4 页面轮询 sequence，不需要拉取完整帧数据。
    uint32_t scrollStopEventSeq       = 0;
    uint32_t scrollStopEventMs        = 0;
    String   scrollStopEventButton;
    String   scrollStopEventSource;
    String   scrollStopEventReason;

    // 但 LED render task 仍有时间物理锁存全黑帧。
    bool     deferredFaceRestoreActive  = false;
    uint8_t  deferredFaceRestoreKind    = 0;
    bool     deferredFaceRestoreAutoMode = false;
    uint32_t deferredFaceRestoreDueMs   = 0;
    String   deferredFaceRestoreReason;
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
// 让 WebUI 刷新/二台设备可以从固件恢复文字并本地重建预览帧。
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
// 默认标记和启动默认标记，供自动轮播和 WebUI 列表共用。
struct RuntimeFace {
    String   id;
    String   name;
    String   m370;
    int32_t  order           = 0;
    uint16_t jsonIndex       = 0;
    bool     isDefault       = false;
    bool     isStartupDefault = false;
};

// Runtime store
// 全局变量；具体加锁仍由调用方或 helper 按操作语义决定。
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

    bool scrollFrameBufferInPsram() const { return scrollFrameBitsInPsram_; }

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
    RuntimeFace  autoFaces_[MAX_AUTO_FACES] = {};
    uint16_t     autoFaceCount_ = 0;
    uint8_t      frameBits_[FRAME_BYTES] = {};
    // 内部 SRAM 的这块大内存。
    uint8_t*     scrollFrameBits_ = nullptr;
    bool         scrollFrameBitsInPsram_ = false;
    // 分配失败时文字附带上传返回 507，纯帧上传不受影响。
    ScrollTimelineMeta scrollMeta_;
    char*        scrollSourceText_ = nullptr;
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

ScrollTimelineMeta& runtimeScrollMeta();

char* runtimeScrollSourceText();

bool runtimeScrollSourceTextReady();

// 必须在 withScrollLock 内调用。EH-A：坏帧数据使播放缓存失效，
// 但有意保留 sourceText（恢复仍可从文本重建预览）。
// 调用点：append:false 重置、m370ToPackedBits 失败路径、E1 帧数超限拒绝、
// 任何未来的缓冲清空。
void invalidateScrollUploadLocked();

// 必须在 withScrollLock 内调用。完整清空（含源文本）；
// 每个 append:false 上传开始时执行。
void clearScrollTimelineMetaLocked();

bool& runtimeFsMounted();

uint32_t runtimeStateVersion();

void touchRuntimeState();

void touchRuntimeStateSlow();

void serviceRuntimeSlowStatePublish();
