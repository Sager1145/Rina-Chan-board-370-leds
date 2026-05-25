#include "led_renderer.h"
#include "state.h"
#include "sync.h"
#include "scroll.h"
#include "utils.h"
#include "button_animations.h"
#include <Adafruit_NeoPixel.h>

// Strip is owned by this module; other modules interact through the helpers.
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

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * @brief Translate logical row-major LED index to the physical strip index.
 * @param logicalIndex Matrix index used by M370/frame buffers.
 * @return Physical NeoPixel index after applying row wiring configuration.
 */
static uint16_t logicalToPhysicalLedIndex(uint16_t logicalIndex) {
    if (logicalIndex >= LED_COUNT) return logicalIndex;
    if (!SERPENTINE_WIRING) return logicalIndex;

    // Walk the configured row map because this board has nonuniform row
    // lengths.  The renderer owns this hardware dependency so higher-level
    // modules can stay in logical M370 order.
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

/**
 * @brief Compute the queue insertion slot for the M370 rate limiter.
 * @param None.
 * @return Ring-buffer tail index.
 */
static uint8_t m370FrameQueueTail() {
    return static_cast<uint8_t>((m370FrameQueueHead + m370FrameQueueCount) % M370_FRAME_QUEUE_DEPTH);
}

/**
 * @brief Check whether another queued M370 frame may be published.
 * @param now Current millis() timestamp.
 * @return true when the configured minimum frame gap has elapsed.
 */
static bool m370FrameRateReady(uint32_t now) {
    return lastM370FrameApplyMs == 0 || now - lastM370FrameApplyMs >= M370_FRAME_MIN_INTERVAL_MS;
}

/**
 * @brief Copy a C string into a fixed queue field with guaranteed termination.
 * @param out Destination buffer.
 * @param outSize Destination buffer size in bytes.
 * @param input Source string, or nullptr for empty.
 * @return None.
 */
static void copyText(char* out, size_t outSize, const char* input) {
    if (outSize == 0) return;
    if (!input) input = "";
    size_t i = 0;
    for (; i + 1 < outSize && input[i] != '\0'; ++i) out[i] = input[i];
    out[i] = '\0';
}

/**
 * @brief Commit packed frame bits into runtime state and request physical render.
 * @param packedBits FRAME_BYTES source buffer in logical LED order.
 * @param normalizedM370 Optional normalized text copy for status responses.
 * @param reason Human-readable state-change reason for diagnostics/WebUI.
 * @return None.
 */
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

/**
 * @brief Publish immediately or enqueue a packed frame behind the rate limiter.
 * @param packedBits FRAME_BYTES source buffer.
 * @param normalizedM370 Optional M370 status string.
 * @param reason Reason attached to the eventual runtime state update.
 * @return None.
 */
static void enqueuePackedM370Frame(const uint8_t* packedBits, const char* normalizedM370, const String& reason) {
    if (!packedBits) return;

    const uint32_t now = millis();
    if (m370FrameQueueCount == 0 && m370FrameRateReady(now)) {
        publishPackedFrameNow(packedBits, normalizedM370, reason.c_str());
        return;
    }

    uint8_t target = m370FrameQueueTail();
    if (m370FrameQueueCount >= M370_FRAME_QUEUE_DEPTH) {
        // Drop the oldest queued frame rather than the newest command.  For
        // live controls, the most recent frame better represents user intent.
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

// ---------------------------------------------------------------------------
// LED index map
// ---------------------------------------------------------------------------

/**
 * @brief Precompute logical-to-physical LED lookup table.
 * @param None.
 * @return None.
 */
void initLedIndexMap() {
    for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
        logicalToPhysicalMap[logical] = logicalToPhysicalLedIndex(logical);
    }
}

// ---------------------------------------------------------------------------
// Render request  (ISR-safe)
// ---------------------------------------------------------------------------

/**
 * @brief Mark the current runtime frame as needing a physical LED render.
 * @param None.
 * @return None.
 */
void requestLedRender() {
    // The render request flag is the connection between Core-0 state writers
    // and the Core-1 scroll/render task.  Use the portMUX variant matching the
    // caller context so button/API code and possible ISR callers share one flag.
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

/**
 * @brief Atomically consume the pending render request flag.
 * @param None.
 * @return true when a writer requested a render since the last consume.
 */
bool consumeLedRenderRequest() {
    bool requested = false;
    portENTER_CRITICAL(&ledRenderRequestMux);
    requested = ledRenderRequested;
    ledRenderRequested = false;
    portEXIT_CRITICAL(&ledRenderRequestMux);
    return requested;
}

/**
 * @brief Request a render while the caller already owns frame state.
 * @param None.
 * @return None.
 */
void showCurrentFrameNoLock() { requestLedRender(); }

// ---------------------------------------------------------------------------
// Frame bit helpers
// ---------------------------------------------------------------------------

/**
 * @brief Set or clear one logical LED bit in the active runtime frame.
 * @param index Logical LED index.
 * @param on true to light the LED, false to clear it.
 * @return None.
 */
void setFrameBit(uint16_t index, bool on) {
    const uint16_t byteIndex = index >> 3;
    const uint8_t  bitMask   = 1U << (index & 7U);
    if (on) runtimeFrameBits()[byteIndex] |=  bitMask;
    else    runtimeFrameBits()[byteIndex] &= ~bitMask;
}

/**
 * @brief Read one logical LED bit from the active runtime frame.
 * @param index Logical LED index.
 * @return true when the bit is lit.
 */
bool frameBit(uint16_t index) {
    return (runtimeFrameBits()[index >> 3] & (1U << (index & 7U))) != 0;
}

/**
 * @brief Read one logical LED bit from an arbitrary packed frame buffer.
 * @param bits FRAME_BYTES packed source buffer.
 * @param index Logical LED index.
 * @return true when the bit is lit.
 */
bool packedFrameBit(const uint8_t* bits, uint16_t index) {
    return (bits[index >> 3] & (1U << (index & 7U))) != 0;
}

/**
 * @brief Count lit logical LEDs in the active runtime frame.
 * @param None.
 * @return Number of set bits up to LED_COUNT.
 */
uint16_t countLitLeds() {
    uint16_t lit = 0;
    for (uint16_t i = 0; i < LED_COUNT; ++i) {
        if (frameBit(i)) ++lit;
    }
    return lit;
}

// ---------------------------------------------------------------------------
// Physical render  (Core 1 render task only)
// ---------------------------------------------------------------------------

/**
 * @brief Copy current frame state and transmit it to the LED strip.
 * @param None.
 * @return None.
 */
void renderCurrentFrameToLedStrip() {
    uint8_t localFrame[FRAME_BYTES];
    static uint8_t overlayRgb[LED_COUNT * 3];
    uint8_t brightness;
    uint8_t colorR = 0, colorG = 0, colorB = 0;

    // Snapshot runtime state under frame lock, then render from local copies.
    // This keeps Core-0 writers blocked for a memcpy only, not for pixel-buffer
    // construction or the timing-critical NeoPixel transmit.
    withFrameLock([&]() {
        memcpy(localFrame, runtimeFrameBits(), FRAME_BYTES);
        brightness = runtimeState().brightness;
        colorR     = runtimeState().colorR;
        colorG     = runtimeState().colorG;
        colorB     = runtimeState().colorB;
    });

    // --- Timing: enforce minimum inter-frame gap FIRST ---
    // Wait before touching the pixel buffer so the WS2812 bus has been idle
    // long enough for the previous frame to fully latch.  The BSS138 level
    // shifter has slow pull-up-dependent rising edges; keeping DATA low for at
    // least LED_RENDER_MIN_GAP_US guarantees the reset pulse is seen as a
    // valid latch signal by the first LED in the chain.
    const uint32_t nowUs = micros();
    if (lastLedShowUs != 0) {
        const uint32_t elapsedUs = nowUs - lastLedShowUs;
        if (elapsedUs < LED_RENDER_MIN_GAP_US) {
            delayMicroseconds(LED_RENDER_MIN_GAP_US - elapsedUs);
        }
    }

    // Build the pixel buffer.
    // setBrightness is called only when the value actually changes to avoid
    // the per-call rescale pass Adafruit_NeoPixel applies to the internal buffer.
    // Initialise to DEFAULT_BRIGHTNESS because ledStripBegin() already called
    // strip.setBrightness(DEFAULT_BRIGHTNESS), so the first render skips a
    // redundant rescale of the freshly-populated pixel buffer.
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

    // Idle-low reset window before transmitting: deliberately longer than
    // the WS2812 protocol minimum because the BSS138 slow rising edge can
    // otherwise push the first LED's T0H/T1H decision into an ambiguous region
    // during rapid successive refreshes.
    delayMicroseconds(LED_SIGNAL_RESET_US);
    withHardwareBusLock([]() {
        strip.show();
    });
    lastLedShowUs = micros();
    // Post-show reset: begin the latch window immediately so that subsequent
    // render requests or the scroll task's wakeup do not accidentally clock a
    // spurious edge before the LEDs have finished latching.
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

// ---------------------------------------------------------------------------
// Strip boot helpers  (called from setup() only)
// ---------------------------------------------------------------------------

/**
 * @brief Initialize the NeoPixel strip and latch an all-off boot frame.
 * @param None.
 * @return None.
 */
void ledStripBegin() {
    strip.begin();
    strip.setBrightness(DEFAULT_BRIGHTNESS);
    strip.clear();
    delayMicroseconds(LED_SIGNAL_RESET_US);
    withHardwareBusLock([]() {
        strip.show();
    });
    lastLedShowUs = micros();
    // Post-show reset: mirror the same idle-low window used by
    // renderCurrentFrameToLedStrip() so that the first real frame rendered
    // after boot is guaranteed to see a clean reset pulse even if the
    // LED_BOOT_CLEAR_HOLD_MS delay fires on the same microsecond tick.
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

// ---------------------------------------------------------------------------
// M370 codec
// ---------------------------------------------------------------------------

/**
 * @brief Validate and canonicalize an M370 frame string.
 * @param input Raw M370 text, optionally prefixed and whitespace separated.
 * @param normalized Receives M370:<93 uppercase hex chars> on success.
 * @param error Receives a user-facing validation error on failure.
 * @return true when input describes exactly one 370-bit frame.
 */
bool normalizeM370(const String& input, String& normalized, String& error) {
    String compact;
    compact.reserve(M370_HEX_CHARS);

    String payload = input;
    payload.trim();
    if (payload.length() >= 5 && payload.substring(0, 5).equalsIgnoreCase("M370:")) {
        payload = payload.substring(5);
    }

    // Strip transport-friendly whitespace before validating hex.  The WebUI,
    // saved faces, and API all converge here so every module shares the same
    // M370 contract.
    for (size_t i = 0; i < payload.length(); ++i) {
        const char c = payload.charAt(i);
        if (c == ' ' || c == '\r' || c == '\n' || c == '\t') continue;
        if (hexNibble(c) < 0) {
            error = "M370 contains a non-hex character";
            return false;
        }
        compact += c;
    }

    if (compact.length() != M370_HEX_CHARS) {
        error = "M370 must be 93 hex chars, optionally prefixed with M370:";
        return false;
    }

    compact.toUpperCase();
    normalized = "M370:" + compact;
    return true;
}

/**
 * @brief Convert an M370 string to packed logical LED bits.
 * @param input Raw or normalized M370 string.
 * @param outBits Destination buffer of FRAME_BYTES bytes.
 * @param error Receives a validation error on failure.
 * @return true when outBits was filled successfully.
 */
bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) return false;

    decodeNormalizedM370ToPackedBits(normalized, outBits);
    return true;
}

/**
 * @brief Decode canonical M370 text into packed frame bits.
 * @param normalized M370:<93 uppercase hex chars>.
 * @param outBits Destination buffer of FRAME_BYTES bytes.
 * @return None.
 */
static void decodeNormalizedM370ToPackedBits(const String& normalized, uint8_t* outBits) {
    memset(outBits, 0, FRAME_BYTES);
    for (uint16_t bit = 0; bit < M370_BITS; ++bit) {
        const int  nibble = hexNibble(normalized.charAt(5 + bit / 4));
        const bool on     = (nibble & (1 << (3 - (bit % 4)))) != 0;
        if (on) outBits[bit >> 3] |= 1U << (bit & 7U);
    }
}

/**
 * @brief Build an all-off M370 string.
 * @param None.
 * @return Canonical blank M370 payload.
 */
String blankM370() {
    String out = "M370:";
    out.reserve(5 + M370_HEX_CHARS);
    for (uint16_t i = 0; i < M370_HEX_CHARS; ++i) out += '0';
    return out;
}

// ---------------------------------------------------------------------------
// Frame apply helpers
// ---------------------------------------------------------------------------

/**
 * @brief Validate, decode, queue/publish, and schedule render for an M370 frame.
 * @param input Raw or normalized M370 string.
 * @param reason Diagnostic reason stored in runtime state.
 * @param error Receives validation failure text.
 * @return true when the frame was accepted for rendering.
 */
bool applyM370(const String& input, const String& reason, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) {
        ++runtimeState().framesRejected;
        return false;
    }

    // Decode the M370 payload into a temporary packed-bit buffer OUTSIDE the
    // frame mutex.  This keeps the critical section as short as a memcpy so the
    // render task (Core 1) is never blocked for a full 370-iteration decode loop.
    uint8_t packed[FRAME_BYTES];
    decodeNormalizedM370ToPackedBits(normalized, packed);

    enqueuePackedM370Frame(packed, normalized.c_str(), reason);
    return true;
}

/**
 * @brief Queue or publish predecoded packed frame bits.
 * @param packedBits FRAME_BYTES source buffer.
 * @param reason Diagnostic reason for the frame.
 * @return None.
 */
void applyPackedFrame(const uint8_t* packedBits, const String& reason) {
    enqueuePackedM370Frame(packedBits, nullptr, reason);
}

/**
 * @brief Publish predecoded packed bits immediately, bypassing the queue.
 * @param packedBits FRAME_BYTES source buffer.
 * @param reason Diagnostic reason for the frame.
 * @return None.
 */
void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason) {
    if (!packedBits) return;
    publishPackedFrameNow(packedBits, nullptr, reason.c_str());
}

/**
 * @brief Queue a canonical all-off frame and mark runtime state as blank.
 * @param reason Diagnostic reason for the blanking frame.
 * @return None.
 */
void applyBlankFrame(const String& reason) {
    uint8_t blank[FRAME_BYTES] = {};
    char blankM370Text[5 + M370_HEX_CHARS + 1];
    memcpy(blankM370Text, "M370:", 5);
    memset(blankM370Text + 5, '0', M370_HEX_CHARS);
    blankM370Text[5 + M370_HEX_CHARS] = '\0';
    enqueuePackedM370Frame(blank, blankM370Text, reason);
}

/**
 * @brief Publish one queued frame when the global M370 rate limiter permits it.
 * @param None.
 * @return None.
 */
void serviceM370FrameQueue() {
    if (m370FrameQueueCount == 0) return;
    const uint32_t now = millis();
    if (!m370FrameRateReady(now)) return;

    QueuedM370Frame item;
    memcpy(&item, &m370FrameQueue[m370FrameQueueHead], sizeof(item));
    m370FrameQueueHead = static_cast<uint8_t>((m370FrameQueueHead + 1) % M370_FRAME_QUEUE_DEPTH);
    --m370FrameQueueCount;
    ++runtimeState().framesDequeued;

    publishPackedFrameNow(item.bits, item.hasM370 ? item.m370 : nullptr, item.reason);
}

/**
 * @brief Drop all queued frames and account them as dropped.
 * @param None.
 * @return None.
 */
void clearQueuedM370Frames() {
    if (m370FrameQueueCount == 0) return;
    runtimeState().framesDropped += m370FrameQueueCount;
    m370FrameQueueHead = 0;
    m370FrameQueueCount = 0;
}

/**
 * @brief Report how many frames are waiting behind the rate limiter.
 * @param None.
 * @return Queue item count.
 */
uint8_t queuedM370FrameCount() {
    return m370FrameQueueCount;
}

// ---------------------------------------------------------------------------
// Color / brightness
// ---------------------------------------------------------------------------

/**
 * @brief Update RGB runtime state without scheduling a render.
 * @param input Color string in #RRGGBB or RRGGBB form.
 * @return None.
 */
void setColorStateNoRender(const String& input) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) return;
    runtimeState().colorHex = formatColorHex(r, g, b);
    runtimeState().colorR   = r;
    runtimeState().colorG   = g;
    runtimeState().colorB   = b;
}

/**
 * @brief Update RGB runtime state and request an LED render.
 * @param input Color string in #RRGGBB or RRGGBB form.
 * @param error Receives validation failure text.
 * @return true when color was parsed and applied.
 */
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
    return true;
}

/**
 * @brief Clamp brightness, store it, and request an LED render.
 * @param raw Requested brightness value.
 * @return None.
 */
void setBrightness(int raw) {
    raw = constrain(raw, MIN_BRIGHTNESS, MAX_BRIGHTNESS);
    withFrameLock([&]() {
        runtimeState().brightness = static_cast<uint8_t>(raw);
        touchRuntimeStateSlow();
        showCurrentFrameNoLock();
    });
}
