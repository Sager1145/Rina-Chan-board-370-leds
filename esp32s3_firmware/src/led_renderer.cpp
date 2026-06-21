#include "led_renderer.h"
#include "state.h"
#include "sync.h"
#include "scroll.h"
#include "utils.h"
#include "button_animations.h"
#include "serial_log.h"
#include "led_driver.h"

static uint16_t logicalToPhysicalMap[LED_COUNT] = {};
static portMUX_TYPE ledRenderRequestMux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool ledRenderRequested = false;
static uint32_t lastLedShowUs = 0;

// --- Presented-frame telemetry --------------------------------------------------------------
// pendingPresentationContext is set just before a frame is rendered (scroll tick / start / step);
// renderCurrentFrameToLedStrip() consumes it and, after the LED latch, stores latestPresentedSample.
static portMUX_TYPE ledPresentationMux = portMUX_INITIALIZER_UNLOCKED;
static LedPresentationContext pendingPresentationContext;
static LedPresentedSample latestPresentedSample;
static uint32_t presentedSeq = 0;

static const char* presentationSourceName(LedPresentationSource source) {
    switch (source) {
        case LedPresentationSource::ScrollTick:  return "scroll_tick";
        case LedPresentationSource::ScrollStart: return "scroll_start";
        case LedPresentationSource::ScrollStep:  return "scroll_step";
        case LedPresentationSource::ManualFrame: return "manual_frame";
        case LedPresentationSource::Clear:       return "clear";
        case LedPresentationSource::Overlay:     return "overlay";
        default:                                 return "unknown";
    }
}

void setPendingLedPresentationContext(const LedPresentationContext& ctx) {
    portENTER_CRITICAL(&ledPresentationMux);
    pendingPresentationContext = ctx;
    portEXIT_CRITICAL(&ledPresentationMux);
}

static LedPresentationContext consumePendingLedPresentationContext() {
    LedPresentationContext ctx;
    portENTER_CRITICAL(&ledPresentationMux);
    ctx = pendingPresentationContext;
    pendingPresentationContext = LedPresentationContext{};
    portEXIT_CRITICAL(&ledPresentationMux);
    return ctx;
}

// Publish a presented sample for a frame whose identity was known (ctx.valid). Plain renders
// without a context (brightness/color refreshes, queue flushes) are intentionally skipped so a
// stray refresh can never clobber the last good scroll sample the WebUI is tracking.
static void publishLedPresentedSample(const LedPresentationContext& ctx,
                                      uint32_t renderStartUs, uint32_t renderEndUs) {
    if (!ctx.valid) return;

    LedPresentedSample sample;
    sample.valid = true;
    sample.presentedSeq = ++presentedSeq;
    sample.source = ctx.source;
    strlcpy(sample.timelineId, ctx.timelineId, sizeof(sample.timelineId));
    sample.presentedFrameIndex = ctx.frameIndex;
    sample.presentedFrameCount = ctx.frameCount;
    sample.nominalIntervalMs   = ctx.nominalIntervalMs;
    sample.uiFps               = ctx.uiFps;
    sample.firmwareScrollActive = ctx.firmwareScrollActive;
    sample.firmwareScrollPaused = ctx.firmwareScrollPaused;
    sample.userPaused           = ctx.userPaused;
    sample.systemPaused         = ctx.systemPaused;
    sample.rateEligible         = ctx.rateEligible;
    sample.renderStartUs    = renderStartUs;
    sample.presentedAtUs    = renderEndUs;
    sample.renderDurationUs = renderEndUs - renderStartUs;
    strlcpy(sample.reason, ctx.reason, sizeof(sample.reason));

    portENTER_CRITICAL(&ledPresentationMux);
    latestPresentedSample = sample;
    portEXIT_CRITICAL(&ledPresentationMux);

    // No touchRuntimeState(): per-frame telemetry must not bump the UI state version.
    // TRACE-only, rate-limited to <=1/sec.
    static uint32_t sLastPresentLogMs = 0;
    if (rinaLogShouldEmit(RINA_LOG_TRACE) && rinaLogRateReady(sLastPresentLogMs, 1000)) {
        RLOG_TRACE("LED", "event=present seq=%lu source=%s idx=%u/%u dur_us=%lu eligible=%d",
                   static_cast<unsigned long>(sample.presentedSeq),
                   presentationSourceName(sample.source),
                   static_cast<unsigned>(sample.presentedFrameIndex),
                   static_cast<unsigned>(sample.presentedFrameCount),
                   static_cast<unsigned long>(sample.renderDurationUs),
                   sample.rateEligible ? 1 : 0);
    }
}

LedPresentedSample readLedPresentedSample() {
    LedPresentedSample sample;
    portENTER_CRITICAL(&ledPresentationMux);
    sample = latestPresentedSample;
    portEXIT_CRITICAL(&ledPresentationMux);
    return sample;
}

struct QueuedPackedFrame {
    uint8_t bits[FRAME_BYTES] = {};
    char    reason[PACKED_FRAME_REASON_CHARS] = "";
};

static QueuedPackedFrame packedFrameQueue[PACKED_FRAME_QUEUE_DEPTH];
static uint8_t packedFrameQueueHead = 0;
static uint8_t packedFrameQueueCount = 0;
static uint32_t lastPackedFrameApplyMs = 0;

static uint16_t logicalToPhysicalLedIndex(uint16_t logicalIndex) {
    if (logicalIndex >= LED_COUNT) return logicalIndex;
    if (!SERPENTINE_WIRING) return logicalIndex;

    for (uint8_t row = 0; row < MATRIX_ROWS; ++row) {
        const uint16_t rowStart  = ROW_OFFSETS[row];
        const uint8_t  rowLength = ROW_LENGTHS[row];
        if (logicalIndex < rowStart || logicalIndex >= rowStart + rowLength) continue;
        const uint16_t localX    = logicalIndex - rowStart;
        const bool     reverseRow = SERPENTINE_ODD_ROWS_REVERSED && ((row & 1U) != 0);
        return reverseRow ? rowStart + (rowLength - 1U - localX) : logicalIndex;
    }
    return logicalIndex;
}

static uint8_t packedFrameQueueTail() {
    return static_cast<uint8_t>((packedFrameQueueHead + packedFrameQueueCount) % PACKED_FRAME_QUEUE_DEPTH);
}

static bool packedFrameRateReady(uint32_t now) {
    return lastPackedFrameApplyMs == 0 || millisElapsed(now, lastPackedFrameApplyMs, PACKED_FRAME_MIN_INTERVAL_MS);
}

static void copyText(char* out, size_t outSize, const char* input) {
    if (outSize == 0) return;
    if (!input) input = "";
    size_t i = 0;
    for (; i + 1 < outSize && input[i] != '\0'; ++i) out[i] = input[i];
    out[i] = '\0';
}

bool validatePackedFrame(const uint8_t* packedBits, String& error) {
    if (!packedBits) {
        error = "packed frame is null";
        return false;
    }
    const uint16_t usedBitsInLastByte = LED_COUNT & 7U;
    if (usedBitsInLastByte != 0) {
        const uint8_t validMask = static_cast<uint8_t>((1U << usedBitsInLastByte) - 1U);
        if ((packedBits[FRAME_BYTES - 1] & static_cast<uint8_t>(~validMask)) != 0) {
            error = "packed frame has non-zero unused bits";
            return false;
        }
    }
    return true;
}

static void publishPackedFrameNow(const uint8_t* packedBits, const char* reason) {
    withFrameLock([&]() {
        memcpy(runtimeFrameBits(), packedBits, FRAME_BYTES);
        runtimeState().lastReason = reason ? reason : "";
        ++runtimeState().framesAccepted;
        touchRuntimeState();
        showCurrentFrameNoLock();
    });
    lastPackedFrameApplyMs = millis();
}

static void enqueuePackedFrame(const uint8_t* packedBits, const String& reason) {
    if (!packedBits) return;
    const uint32_t now = millis();
    if (packedFrameQueueCount == 0 && packedFrameRateReady(now)) {
        publishPackedFrameNow(packedBits, reason.c_str());
        return;
    }
    uint8_t target = packedFrameQueueTail();
    if (packedFrameQueueCount >= PACKED_FRAME_QUEUE_DEPTH) {
        target = packedFrameQueueHead;
        packedFrameQueueHead = static_cast<uint8_t>((packedFrameQueueHead + 1) % PACKED_FRAME_QUEUE_DEPTH);
        ++runtimeState().framesDropped;
    } else {
        ++packedFrameQueueCount;
    }
    memcpy(packedFrameQueue[target].bits, packedBits, FRAME_BYTES);
    copyText(packedFrameQueue[target].reason, sizeof(packedFrameQueue[target].reason), reason.c_str());
    ++runtimeState().framesQueued;
}

void initLedIndexMap() {
    for (uint16_t logical = 0; logical < LED_COUNT; ++logical) logicalToPhysicalMap[logical] = logicalToPhysicalLedIndex(logical);
}

void requestLedRender() {
    if (xPortInIsrContext()) {
        portENTER_CRITICAL_ISR(&ledRenderRequestMux);
        ledRenderRequested = true;
        portEXIT_CRITICAL_ISR(&ledRenderRequestMux);
    } else {
        portENTER_CRITICAL(&ledRenderRequestMux);
        ledRenderRequested = true;
        portEXIT_CRITICAL(&ledRenderRequestMux);
    }
    notifyScrollRenderTask();
}

bool consumeLedRenderRequest() {
    bool requested = false;
    portENTER_CRITICAL(&ledRenderRequestMux);
    requested = ledRenderRequested;
    ledRenderRequested = false;
    portEXIT_CRITICAL(&ledRenderRequestMux);
    return requested;
}

void showCurrentFrameNoLock() { requestLedRender(); }

void setFrameBit(uint16_t index, bool on) {
    if (index >= LED_COUNT) return;
    const uint16_t byteIndex = index >> 3;
    const uint8_t  bitMask   = 1U << (index & 7U);
    if (on) runtimeFrameBits()[byteIndex] |=  bitMask;
    else    runtimeFrameBits()[byteIndex] &= ~bitMask;
}

bool frameBit(uint16_t index) {
    if (index >= LED_COUNT) return false;
    return (runtimeFrameBits()[index >> 3] & (1U << (index & 7U))) != 0;
}

bool packedFrameBit(const uint8_t* bits, uint16_t index) {
    if (!bits || index >= LED_COUNT) return false;
    return (bits[index >> 3] & (1U << (index & 7U))) != 0;
}

uint16_t countLitLedsLocked(const uint8_t* bits) {
    uint16_t lit = 0;
    for (uint16_t byteIndex = 0; byteIndex < FRAME_BYTES; ++byteIndex) {
        uint8_t value = bits[byteIndex];
        const uint16_t firstBit = static_cast<uint16_t>(byteIndex) << 3;
        if (firstBit + 8U > LED_COUNT) {
            const uint8_t validBits = static_cast<uint8_t>(LED_COUNT - firstBit);
            value &= static_cast<uint8_t>((1U << validBits) - 1U);
        }
        lit += static_cast<uint16_t>(__builtin_popcount(value));
    }
    return lit;
}

uint16_t countLitLeds() { return countLitLedsLocked(runtimeFrameBits()); }

FrameStateSnapshot readFrameStateSnapshot() {
    FrameStateSnapshot s;
    withFrameLock([&]() {
        strlcpy(s.colorHex, runtimeState().colorHex.c_str(), sizeof(s.colorHex));
        s.brightness = runtimeState().brightness;
        strlcpy(s.lastReason, runtimeState().lastReason.c_str(), sizeof(s.lastReason));
        s.litLeds = countLitLedsLocked(runtimeFrameBits());
        s.framesAccepted = runtimeState().framesAccepted;
    });
    return s;
}

void renderCurrentFrameToLedStrip() {
    LedPresentationContext ctx = consumePendingLedPresentationContext();
    uint8_t localFrame[FRAME_BYTES];
    static uint8_t overlayRgb[LED_COUNT * 3];
    uint8_t brightness = DEFAULT_BRIGHTNESS;
    uint8_t colorR = 0, colorG = 0, colorB = 0;
    withFrameLock([&]() {
        memcpy(localFrame, runtimeFrameBits(), FRAME_BYTES);
        brightness = runtimeState().brightness;
        colorR = runtimeState().colorR;
        colorG = runtimeState().colorG;
        colorB = runtimeState().colorB;
    });
    const uint32_t nowUs = micros();
    if (lastLedShowUs != 0) {
        const uint32_t elapsedUs = nowUs - lastLedShowUs;
        if (elapsedUs < LED_RENDER_MIN_GAP_US) delayMicroseconds(LED_RENDER_MIN_GAP_US - elapsedUs);
    }
    static uint8_t lastAppliedBrightness = DEFAULT_BRIGHTNESS;
    if (brightness != lastAppliedBrightness) {
        leddrv::setBrightness(brightness);
        lastAppliedBrightness = brightness;
    }
    const bool overlayActive = copyButtonAnimationOverlay(overlayRgb, LED_COUNT);
    if (overlayActive) {
        for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
            const uint16_t offset = logical * 3U;
            leddrv::setPixel(logicalToPhysicalMap[logical], overlayRgb[offset], overlayRgb[offset + 1], overlayRgb[offset + 2]);
        }
        // An overlay (e.g. button animation) is covering the scroll frame, so this latch does
        // not represent a clean scroll frame — never let it drive fps estimation.
        ctx.rateEligible = false;
    } else {
        for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
            if (packedFrameBit(localFrame, logical)) leddrv::setPixel(logicalToPhysicalMap[logical], colorR, colorG, colorB);
            else                                     leddrv::setPixel(logicalToPhysicalMap[logical], 0, 0, 0);
        }
    }
    delayMicroseconds(LED_SIGNAL_RESET_US);
    const uint32_t renderStartUs = micros();
    withHardwareBusLock([]() { leddrv::refresh(); });
    const uint32_t renderEndUs = micros();
    lastLedShowUs = renderEndUs;
    // The LED has now actually latched this frame: record it as the presented sample.
    publishLedPresentedSample(ctx, renderStartUs, renderEndUs);
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

void ledStripBegin() {
    leddrv::begin();
    leddrv::setBrightness(DEFAULT_BRIGHTNESS);
    leddrv::clear();
    delayMicroseconds(LED_SIGNAL_RESET_US);
    withHardwareBusLock([]() { leddrv::refresh(); });
    lastLedShowUs = micros();
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

bool applyPackedFrameQueued(const uint8_t* packedBits, const String& reason, String& error) {
    if (!validatePackedFrame(packedBits, error)) {
        ++runtimeState().framesRejected;
        touchRuntimeStateSlow();
        return false;
    }
    enqueuePackedFrame(packedBits, reason);
    const uint16_t lit = countLitLedsLocked(packedBits);
    RLOG_INFO("LED", "event=apply_packed reason=%s lit=%u bytes=%u brightness=%u", reason.c_str(), lit, static_cast<unsigned>(FRAME_BYTES), runtimeState().brightness);
    rinaLogRecordLedCommand(reason.c_str(), lit, "packed");
    return true;
}

void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason,
                               const LedPresentationContext* ctx) {
    if (!packedBits) return;
    String error;
    if (!validatePackedFrame(packedBits, error)) return;
    // Hand the renderer the precise identity of this frame (scroll start/step) before the
    // render request is raised, so the resulting presented sample carries the right frame index.
    if (ctx) setPendingLedPresentationContext(*ctx);
    publishPackedFrameNow(packedBits, reason.c_str());
    const uint16_t lit = countLitLedsLocked(packedBits);
    RLOG_INFO("LED", "event=apply_immediate_packed reason=%s lit=%u bytes=%u brightness=%u", reason.c_str(), lit, static_cast<unsigned>(FRAME_BYTES), runtimeState().brightness);
    rinaLogRecordLedCommand(reason.c_str(), lit, "immediate");
}

void applyBlankFrame(const String& reason) {
    uint8_t blank[FRAME_BYTES] = {};
    enqueuePackedFrame(blank, reason);
    RLOG_INFO("LED", "event=clear reason=%s lit=0 bytes=%u", reason.c_str(), static_cast<unsigned>(FRAME_BYTES));
    rinaLogRecordLedCommand(reason.c_str(), 0, "clear");
}

void servicePackedFrameQueue() {
    if (packedFrameQueueCount == 0) return;
    const uint32_t now = millis();
    if (!packedFrameRateReady(now)) return;
    QueuedPackedFrame& item = packedFrameQueue[packedFrameQueueHead];
    packedFrameQueueHead = static_cast<uint8_t>((packedFrameQueueHead + 1) % PACKED_FRAME_QUEUE_DEPTH);
    --packedFrameQueueCount;
    ++runtimeState().framesDequeued;
    publishPackedFrameNow(item.bits, item.reason);
}

void clearQueuedPackedFrames() {
    if (packedFrameQueueCount == 0) return;
    runtimeState().framesDropped += packedFrameQueueCount;
    packedFrameQueueHead = 0;
    packedFrameQueueCount = 0;
}

uint8_t queuedPackedFrameCount() { return packedFrameQueueCount; }

void setColorStateNoRender(const String& input) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) return;
    runtimeState().colorHex = formatColorHex(r, g, b);
    runtimeState().colorR = r;
    runtimeState().colorG = g;
    runtimeState().colorB = b;
}

bool setColor(const String& input, String& error) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) {
        error = "color must be #RRGGBB or RRGGBB (hex)";
        return false;
    }
    withFrameLock([&]() {
        runtimeState().colorHex = formatColorHex(r, g, b);
        runtimeState().colorR = r;
        runtimeState().colorG = g;
        runtimeState().colorB = b;
        touchRuntimeStateSlow();
        showCurrentFrameNoLock();
    });
    RLOG_INFO("LED", "event=color value=%s", formatColorHex(r, g, b).c_str());
    return true;
}

void setBrightness(int raw) {
    raw = constrain(raw, MIN_BRIGHTNESS, MAX_BRIGHTNESS);
    withFrameLock([&]() {
        runtimeState().brightness = static_cast<uint8_t>(raw);
        touchRuntimeStateSlow();
        showCurrentFrameNoLock();
    });
    RLOG_INFO("LED", "event=brightness value=%d", raw);
}
