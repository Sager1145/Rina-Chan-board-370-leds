#pragma once
#include <Arduino.h>
#include "config.h"

// 中文说明：LED “实际已显示帧” telemetry 类型。
// renderCurrentFrameToLedStrip() 在 leddrv::refresh() 完成（LED 真正点亮）后，
// 把当前帧的身份与时间戳封存为 LedPresentedSample，供 /api/preview_sync 上报给 WebUI。
// 关键原则：固件只“报告”实际显示帧，绝不改 FPS slider，也不回传完整帧数据。
//
// English: telemetry describing the frame the LED panel has ACTUALLY presented.
// The renderer publishes one LedPresentedSample right after leddrv::refresh()
// (i.e. once the WS2812 latch/transmit has completed) so the WebUI can estimate
// the real scroll fps from (presentedFrameIndex, presentedAtUs) pairs and gently
// steer its internal preview speed — never the user's fps controls.

enum class LedPresentationSource : uint8_t {
    Unknown = 0,
    ScrollTick,   // Core-1 自动滚动推进的一帧（可用于估速）
    ScrollStart,  // start_scroll 的第一帧（对齐用，不估速）
    ScrollStep,   // 手动单步（对齐用，不估速）
    ManualFrame,  // 其它即时帧（不估速）
    Clear,        // 清屏
    Overlay,      // 按钮动画等叠加层（不估速）
};

// Identity + state captured BEFORE a frame is rendered. The caller fills this in
// and hands it to the renderer via setPendingLedPresentationContext(); the renderer
// timestamps it and turns it into a LedPresentedSample after the actual LED latch.
struct LedPresentationContext {
    bool valid = false;
    LedPresentationSource source = LedPresentationSource::Unknown;

    char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};

    uint16_t frameIndex        = 0;
    uint16_t frameCount        = 0;
    uint16_t nominalIntervalMs = DEFAULT_SCROLL_INTERVAL_MS;
    uint8_t  uiFps             = 0;

    bool firmwareScrollActive = false;
    bool firmwareScrollPaused = false;
    bool userPaused           = false;
    bool systemPaused         = false;

    // True only for continuous scroll ticks. False for start/step/manual/clear/overlay
    // and pause boundaries — those samples may be used to align position but never to
    // estimate fps.
    bool rateEligible = false;

    char reason[PACKED_FRAME_REASON_CHARS] = {0};
};

// The latest frame the LED panel has actually presented. Snapshotted under a
// critical section and returned by readLedPresentedSample().
struct LedPresentedSample {
    bool valid = false;
    uint32_t presentedSeq = 0;
    LedPresentationSource source = LedPresentationSource::Unknown;

    char timelineId[MAX_SCROLL_TIMELINE_ID_CHARS + 1] = {0};

    uint16_t presentedFrameIndex = 0;
    uint16_t presentedFrameCount = 0;
    uint16_t nominalIntervalMs   = DEFAULT_SCROLL_INTERVAL_MS;
    uint8_t  uiFps               = 0;

    bool firmwareScrollActive = false;
    bool firmwareScrollPaused = false;
    bool userPaused           = false;
    bool systemPaused         = false;
    bool rateEligible         = false;

    // Device monotonic microseconds. micros() wraps (~71 min); the WebUI handles
    // monotonic deltas using presentedSeq ordering and a bounded time window.
    uint32_t renderStartUs    = 0;
    uint32_t presentedAtUs    = 0;
    uint32_t renderDurationUs = 0;

    char reason[PACKED_FRAME_REASON_CHARS] = {0};
};
