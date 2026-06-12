#pragma once
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>
#include "config.h"

// 本头文件定义固件共享运行时状态、保存表情缓存和 RuntimeStore
// 单例接口。跨模块读写这些字段时，调用方需要按 sync.h 的锁策略保护。

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------
// 中文块：RuntimeState 保存当前 WebUI/固件可见状态，包括颜色、亮度、播放模式、
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
    // 中文块：当前显示配置和最近一次操作原因；WebUI status 与渲染器都会读取。
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

    // 中文块：运行统计计数，用来在调试页面观察帧、命令、文件写入和 UI 发布情况。
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

    // 中文块：自动轮播的间隔、上次切换时间和当前表情 index。
    uint32_t autoIntervalMs      = DEFAULT_AUTO_INTERVAL_MS;
    uint32_t lastAutoSwitchMs    = 0;
    uint16_t autoFaceIndex       = 0;

    // 中文块：固件端文字滚动播放状态；WebUI 上传帧后由这些字段控制播放/暂停。
    bool     firmwareScrollActive  = false;
    bool     firmwareScrollPaused  = false;
    bool     firmwareScrollUserPaused = false;
    bool     firmwareScrollSystemPaused = false;
    bool     restoreAutoAfterScroll = false;
    uint16_t scrollFrameCount      = 0;
    uint16_t scrollFrameIndex      = 0;
    uint16_t scrollIntervalMs      = DEFAULT_SCROLL_INTERVAL_MS;
    uint32_t lastScrollFrameMs     = 0;

    // 中文块：GPIO B1/B2/B3 中断文字滚动时给 WebUI 的轻量事件标记。
    // 前端在 6.4 页面轮询 sequence，不需要拉取完整帧数据。
    uint32_t scrollStopEventSeq       = 0;
    uint32_t scrollStopEventMs        = 0;
    String   scrollStopEventButton;
    String   scrollStopEventSource;
    String   scrollStopEventReason;

    // 中文块：显式清屏后延迟恢复保存表情；这样 HTTP/button handler 不需要 delay()，
    // 但 LED render task 仍有时间物理锁存全黑帧。
    bool     deferredFaceRestoreActive  = false;
    uint8_t  deferredFaceRestoreKind    = 0;
    bool     deferredFaceRestoreAutoMode = false;
    uint32_t deferredFaceRestoreDueMs   = 0;
    String   deferredFaceRestoreReason;
};

// ---------------------------------------------------------------------------
// Saved face metadata
// ---------------------------------------------------------------------------
// 中文块：RuntimeFace 是 saved_faces.json 中单个表情的运行时副本，保留排序、
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

// ---------------------------------------------------------------------------
// Runtime store
// ---------------------------------------------------------------------------
// 中文块：RuntimeStore 集中持有所有可变运行时存储，避免各模块直接链接 extern
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
    // 中文块：文字滚动缓存约 140 KB，按需分配；常见 PSRAM 路径不会永久占用
    // 内部 SRAM 的这块大内存。
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
