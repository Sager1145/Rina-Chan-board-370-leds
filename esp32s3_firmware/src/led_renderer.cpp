#include "led_renderer.h"
#include "state.h"
#include "sync.h"
#include "scroll.h"
#include "utils.h"
#include "button_animations.h"
#include "serial_log.h"
#include <Adafruit_NeoPixel.h>

static Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);

static uint16_t logicalToPhysicalMap[LED_COUNT] = {};
static portMUX_TYPE ledRenderRequestMux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool ledRenderRequested = false;
static uint32_t lastLedShowUs = 0;

struct QueuedM370Frame {
    uint8_t bits[FRAME_BYTES] = {};
    char    m370[5 + M370_HEX_CHARS + 1] = "";
    char    reason[M370_FRAME_REASON_CHARS] = "";
    bool    hasM370 = false;
};

static QueuedM370Frame m370FrameQueue[M370_FRAME_QUEUE_DEPTH];
static uint8_t m370FrameQueueHead = 0;
static uint8_t m370FrameQueueCount = 0;
static uint32_t lastM370FrameApplyMs = 0;
// Frame-queue state is owned by the Core 0 cooperative loop and HTTP/button
// handlers. Keep service/enqueue/clear calls on Core 0 unless this queue is
// made atomic or guarded by a mutex.

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

static void decodeNormalizedM370ToPackedBits(const String& normalized, uint8_t* outBits);

static uint8_t m370FrameQueueTail() {
    return static_cast<uint8_t>((m370FrameQueueHead + m370FrameQueueCount) % M370_FRAME_QUEUE_DEPTH);
}

static bool m370FrameRateReady(uint32_t now) {
    return lastM370FrameApplyMs == 0 ||
           millisElapsed(now, lastM370FrameApplyMs, M370_FRAME_MIN_INTERVAL_MS);
}

static bool hasM370Prefix(const String& value) {
    return value.length() >= 5 &&
           (value.charAt(0) == 'M' || value.charAt(0) == 'm') &&
           value.charAt(1) == '3' &&
           value.charAt(2) == '7' &&
           value.charAt(3) == '0' &&
           value.charAt(4) == ':';
}

static char upperHexChar(char c) {
    return (c >= 'a' && c <= 'f') ? static_cast<char>(c - ('a' - 'A')) : c;
}

static const char* blankM370Text() {
    static char text[5 + M370_HEX_CHARS + 1] = {};
    if (text[0] == '\0') {
        memcpy(text, "M370:", 5);
        memset(text + 5, '0', M370_HEX_CHARS);
        text[5 + M370_HEX_CHARS] = '\0';
    }
    return text;
}

static void copyText(char* out, size_t outSize, const char* input) {
    if (outSize == 0) return;
    if (!input) input = "";
    size_t i = 0;
    for (; i + 1 < outSize && input[i] != '\0'; ++i) out[i] = input[i];
    out[i] = '\0';
}

static void publishPackedFrameNow(const uint8_t* packedBits, const char* normalizedM370, const char* reason) {
    withFrameLock([&]() {
        memcpy(runtimeFrameBits(), packedBits, FRAME_BYTES);
        if (normalizedM370 && normalizedM370[0] != '\0') {
            runtimeState().lastM370 = normalizedM370;
        }
        runtimeState().lastReason = reason ? reason : "";
        ++runtimeState().framesAccepted;
        touchRuntimeState();
        showCurrentFrameNoLock();
    });
    lastM370FrameApplyMs = millis();
}

static void enqueuePackedM370Frame(const uint8_t* packedBits, const char* normalizedM370, const String& reason) {
    if (!packedBits) return;

    const uint32_t now = millis();
    if (m370FrameQueueCount == 0 && m370FrameRateReady(now)) {
        publishPackedFrameNow(packedBits, normalizedM370, reason.c_str());
        return;
    }

    uint8_t target = m370FrameQueueTail();
    if (m370FrameQueueCount >= M370_FRAME_QUEUE_DEPTH) {
        target = m370FrameQueueHead;
        m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
        ++runtimeState().framesDropped;
    } else {
        ++m370FrameQueueCount;
    }

    memcpy(m370FrameQueue[target].bits, packedBits, FRAME_BYTES);
    if (normalizedM370 && normalizedM370[0] != '\0') {
        copyText(m370FrameQueue[target].m370, sizeof(m370FrameQueue[target].m370), normalizedM370);
        m370FrameQueue[target].hasM370 = true;
    } else {
        m370FrameQueue[target].m370[0] = '\0';
        m370FrameQueue[target].hasM370 = false;
    }
    copyText(m370FrameQueue[target].reason, sizeof(m370FrameQueue[target].reason), reason.c_str());
    ++runtimeState().framesQueued;
}

void initLedIndexMap() {
    for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
        logicalToPhysicalMap[logical] = logicalToPhysicalLedIndex(logical);
    }
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

uint16_t countLitLeds() {
    return countLitLedsLocked(runtimeFrameBits());
}

FrameStateSnapshot readFrameStateSnapshot() {
    FrameStateSnapshot s;
    withFrameLock([&]() {
        strlcpy(s.colorHex, runtimeState().colorHex.c_str(), sizeof(s.colorHex));
        s.brightness = runtimeState().brightness;
        strlcpy(s.lastM370, runtimeState().lastM370.c_str(), sizeof(s.lastM370));
        strlcpy(s.lastReason, runtimeState().lastReason.c_str(), sizeof(s.lastReason));
        s.litLeds = countLitLedsLocked(runtimeFrameBits());
        s.framesAccepted = runtimeState().framesAccepted;
    });
    return s;
}

void renderCurrentFrameToLedStrip() {
    // After setup(), this function is expected to run only on the Core 1
    // render task. The static buffers below rely on that single-caller
    // invariant.
    uint8_t localFrame[FRAME_BYTES];
    static uint8_t overlayRgb[LED_COUNT * 3];
    uint8_t brightness = DEFAULT_BRIGHTNESS;
    uint8_t colorR = 0, colorG = 0, colorB = 0;

    withFrameLock([&]() {
        memcpy(localFrame, runtimeFrameBits(), FRAME_BYTES);
        brightness = runtimeState().brightness;
        colorR     = runtimeState().colorR;
        colorG     = runtimeState().colorG;
        colorB     = runtimeState().colorB;
    });

    const uint32_t nowUs = micros();
    if (lastLedShowUs != 0) {
        const uint32_t elapsedUs = nowUs - lastLedShowUs;
        if (elapsedUs < LED_RENDER_MIN_GAP_US) {
            delayMicroseconds(LED_RENDER_MIN_GAP_US - elapsedUs);
        }
    }

    static uint8_t lastAppliedBrightness = DEFAULT_BRIGHTNESS;
    if (brightness != lastAppliedBrightness) {
        strip.setBrightness(brightness);
        lastAppliedBrightness = brightness;
    }
    const bool overlayActive = copyButtonAnimationOverlay(overlayRgb, LED_COUNT);
    if (overlayActive) {
        for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
            const uint16_t offset = logical * 3U;
            strip.setPixelColor(
                logicalToPhysicalMap[logical],
                strip.Color(overlayRgb[offset], overlayRgb[offset + 1], overlayRgb[offset + 2])
            );
        }
    } else {
        const uint32_t rgb = strip.Color(colorR, colorG, colorB);
        for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
            strip.setPixelColor(
                logicalToPhysicalMap[logical],
                packedFrameBit(localFrame, logical) ? rgb : 0
            );
        }
    }

    delayMicroseconds(LED_SIGNAL_RESET_US);
    withHardwareBusLock([]() {
        strip.show();
    });
    lastLedShowUs = micros();
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

void ledStripBegin() {
    strip.begin();
    strip.setBrightness(DEFAULT_BRIGHTNESS);
    strip.clear();
    delayMicroseconds(LED_SIGNAL_RESET_US);
    withHardwareBusLock([]() {
        strip.show();
    });
    lastLedShowUs = micros();
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

bool normalizeM370(const String& input, String& normalized, String& error) {
    String payload = input;
    payload.trim();

    const size_t start = hasM370Prefix(payload) ? 5U : 0U;
    char compact[M370_HEX_CHARS + 1];
    size_t compactLen = 0;

    for (size_t i = start; i < payload.length(); ++i) {
        const char c = payload.charAt(i);
        if (c == ' ' || c == '\r' || c == '\n' || c == '\t') continue;
        if (hexNibble(c) < 0) {
            error = "M370 contains a non-hex character";
            return false;
        }
        if (compactLen < M370_HEX_CHARS) compact[compactLen] = upperHexChar(c);
        ++compactLen;
    }

    if (compactLen != M370_HEX_CHARS) {
        error = "M370 must be 93 hex chars, optionally prefixed with M370:";
        return false;
    }

    compact[M370_HEX_CHARS] = '\0';
    normalized = "M370:";
    normalized += compact;
    return true;
}

bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error) {
    if (!outBits) {
        error = "output buffer is null";
        return false;
    }

    String normalized;
    if (!normalizeM370(input, normalized, error)) return false;

    decodeNormalizedM370ToPackedBits(normalized, outBits);
    return true;
}

static void decodeNormalizedM370ToPackedBits(const String& normalized, uint8_t* outBits) {
    memset(outBits, 0, FRAME_BYTES);

    const char* hex = normalized.c_str() + 5;
    for (uint16_t nib = 0; nib < M370_HEX_CHARS; ++nib) {
        const int value = hexNibble(hex[nib]);
        if (value <= 0) continue;  // 说明 M370 帧解析和 LED 渲染 中当前代码块的职责和维护约束。
        const uint16_t baseBit = static_cast<uint16_t>(nib) * 4U;
        for (uint8_t k = 0; k < 4U; ++k) {
            if ((value & (1 << (3 - k))) == 0) continue;
            const uint16_t bit = baseBit + k;
            if (bit < M370_BITS) outBits[bit >> 3] |= 1U << (bit & 7U);
        }
    }
}

String blankM370() {
    return String(blankM370Text());
}

bool applyM370(const String& input, const String& reason, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) {
        ++runtimeState().framesRejected;
        return false;
    }

    uint8_t packed[FRAME_BYTES];
    decodeNormalizedM370ToPackedBits(normalized, packed);

    enqueuePackedM370Frame(packed, normalized.c_str(), reason);
    // Output-only diagnostics, emitted after the (possibly synchronous) publish
    // returns so no Serial I/O ever happens while the frame lock is held.
    const uint16_t lit = countLitLedsLocked(packed);
    RLOG_INFO("LED", "event=apply reason=%s lit=%u bytes=%u brightness=%u",
              reason.c_str(), lit, static_cast<unsigned>(FRAME_BYTES),
              runtimeState().brightness);
    rinaLogRecordLedCommand(reason.c_str(), lit, "frame");
    return true;
}

void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason) {
    if (!packedBits) return;
    publishPackedFrameNow(packedBits, nullptr, reason.c_str());
    const uint16_t lit = countLitLedsLocked(packedBits);
    RLOG_INFO("LED", "event=apply reason=%s lit=%u bytes=%u brightness=%u",
              reason.c_str(), lit, static_cast<unsigned>(FRAME_BYTES),
              runtimeState().brightness);
    rinaLogRecordLedCommand(reason.c_str(), lit, "immediate");
}

void applyBlankFrame(const String& reason) {
    uint8_t blank[FRAME_BYTES] = {};
    enqueuePackedM370Frame(blank, blankM370Text(), reason);
    RLOG_INFO("LED", "event=clear reason=%s lit=0 bytes=%u",
              reason.c_str(), static_cast<unsigned>(FRAME_BYTES));
    rinaLogRecordLedCommand(reason.c_str(), 0, "clear");
}

void serviceM370FrameQueue() {
    if (m370FrameQueueCount == 0) return;
    const uint32_t now = millis();
    if (!m370FrameRateReady(now)) return;

    QueuedM370Frame& item = m370FrameQueue[m370FrameQueueHead];
    m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
    --m370FrameQueueCount;
    ++runtimeState().framesDequeued;

    publishPackedFrameNow(item.bits, item.hasM370 ? item.m370 : nullptr, item.reason);
}

void clearQueuedM370Frames() {
    if (m370FrameQueueCount == 0) return;
    runtimeState().framesDropped += m370FrameQueueCount;
    m370FrameQueueHead = 0;
    m370FrameQueueCount = 0;
}

uint8_t queuedM370FrameCount() {
    return m370FrameQueueCount;
}

void setColorStateNoRender(const String& input) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) return;
    runtimeState().colorHex = formatColorHex(r, g, b);
    runtimeState().colorR   = r;
    runtimeState().colorG   = g;
    runtimeState().colorB   = b;
}

bool setColor(const String& input, String& error) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) {
        error = "color must be #RRGGBB or RRGGBB (hex)";
        return false;
    }
    withFrameLock([&]() {
        runtimeState().colorHex = formatColorHex(r, g, b);
        runtimeState().colorR   = r;
        runtimeState().colorG   = g;
        runtimeState().colorB   = b;
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
