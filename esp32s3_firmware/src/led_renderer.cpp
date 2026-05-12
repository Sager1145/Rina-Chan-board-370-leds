#include "led_renderer.h"
#include "state.h"
#include "utils.h"
#include <Adafruit_NeoPixel.h>

// Strip is owned by this module; other modules interact through the helpers.
static Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

static uint16_t logicalToPhysicalLedIndex(uint16_t logicalIndex) {
    if (logicalIndex >= LED_COUNT) return logicalIndex;
    for (uint8_t row = 0; row < MATRIX_ROWS; ++row) {
        const uint16_t rowStart  = ROW_OFFSETS[row];
        const uint8_t  rowLength = ROW_LENGTHS[row];
        if (logicalIndex < rowStart || logicalIndex >= rowStart + rowLength) continue;
        const uint16_t localX    = logicalIndex - rowStart;
        const bool     reverseRow = (row & 1U) != 0;
        return reverseRow ? rowStart + (rowLength - 1U - localX) : logicalIndex;
    }
    return logicalIndex;
}

// ---------------------------------------------------------------------------
// LED index map
// ---------------------------------------------------------------------------

void initLedIndexMap() {
    for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
        logicalToPhysicalMap[logical] = logicalToPhysicalLedIndex(logical);
    }
}

// ---------------------------------------------------------------------------
// Render request  (ISR-safe)
// ---------------------------------------------------------------------------

void requestLedRender() {
    portENTER_CRITICAL(&ledRenderRequestMux);
    ledRenderRequested = true;
    portEXIT_CRITICAL(&ledRenderRequestMux);
    if (scrollTaskHandle) xTaskNotifyGive(scrollTaskHandle);
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
void showCurrentFrame()       { requestLedRender(); }

// ---------------------------------------------------------------------------
// Frame bit helpers
// ---------------------------------------------------------------------------

void setFrameBit(uint16_t index, bool on) {
    const uint16_t byteIndex = index >> 3;
    const uint8_t  bitMask   = 1U << (index & 7U);
    if (on) frameBits[byteIndex] |=  bitMask;
    else    frameBits[byteIndex] &= ~bitMask;
}

bool frameBit(uint16_t index) {
    return (frameBits[index >> 3] & (1U << (index & 7U))) != 0;
}

bool packedFrameBit(const uint8_t* bits, uint16_t index) {
    return (bits[index >> 3] & (1U << (index & 7U))) != 0;
}

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

void renderCurrentFrameToLedStrip() {
    uint8_t localFrame[FRAME_BYTES];
    uint8_t brightness = DEFAULT_BRIGHTNESS;
    uint8_t colorR = 0, colorG = 0, colorB = 0;

    lockFrame();
    memcpy(localFrame, frameBits, FRAME_BYTES);
    brightness = state.brightness;
    colorR     = state.colorR;
    colorG     = state.colorG;
    colorB     = state.colorB;
    unlockFrame();

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
    const uint32_t rgb = strip.Color(colorR, colorG, colorB);
    for (uint16_t logical = 0; logical < LED_COUNT; ++logical) {
        strip.setPixelColor(
            logicalToPhysicalMap[logical],
            packedFrameBit(localFrame, logical) ? rgb : 0
        );
    }

    // Idle-low reset window before transmitting — deliberately longer than
    // the WS2812 protocol minimum because the BSS138 slow rising edge can
    // otherwise push the first LED's T0H/T1H decision into an ambiguous region
    // during rapid successive refreshes.
    delayMicroseconds(LED_SIGNAL_RESET_US);
    strip.show();
    lastLedShowUs = micros();
    // Post-show reset: begin the latch window immediately so that subsequent
    // render requests or the scroll task's wakeup do not accidentally clock a
    // spurious edge before the LEDs have finished latching.
    delayMicroseconds(LED_SIGNAL_RESET_US);
}

// ---------------------------------------------------------------------------
// Strip boot helpers  (called from setup() only)
// ---------------------------------------------------------------------------

void ledStripBegin() {
    strip.begin();
    strip.setBrightness(DEFAULT_BRIGHTNESS);
    strip.clear();
    delayMicroseconds(LED_SIGNAL_RESET_US);
    strip.show();
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

bool normalizeM370(const String& input, String& normalized, String& error) {
    String compact;
    compact.reserve(M370_HEX_CHARS);

    String payload = input;
    payload.trim();
    if (payload.length() >= 5 && payload.substring(0, 5).equalsIgnoreCase("M370:")) {
        payload = payload.substring(5);
    }

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

bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) return false;

    memset(outBits, 0, FRAME_BYTES);
    const String payload = normalized.substring(5);
    for (uint16_t bit = 0; bit < M370_BITS; ++bit) {
        const int  nibble = hexNibble(payload.charAt(bit / 4));
        const bool on     = (nibble & (1 << (3 - (bit % 4)))) != 0;
        if (on) outBits[bit >> 3] |= 1U << (bit & 7U);
    }
    return true;
}

String blankM370() {
    String out = "M370:";
    out.reserve(5 + M370_HEX_CHARS);
    for (uint16_t i = 0; i < M370_HEX_CHARS; ++i) out += '0';
    return out;
}

// ---------------------------------------------------------------------------
// Frame apply helpers
// ---------------------------------------------------------------------------

bool applyM370(const String& input, const String& reason, String& error) {
    String normalized;
    if (!normalizeM370(input, normalized, error)) {
        ++state.framesRejected;
        return false;
    }

    // Decode the M370 payload into a temporary packed-bit buffer OUTSIDE the
    // frame mutex.  This keeps the critical section as short as a memcpy so the
    // render task (Core 1) is never blocked for a full 370-iteration decode loop.
    uint8_t packed[FRAME_BYTES];
    const String payload = normalized.substring(5);
    memset(packed, 0, FRAME_BYTES);
    for (uint16_t bit = 0; bit < M370_BITS; ++bit) {
        const int  nibble = hexNibble(payload.charAt(bit / 4));
        const bool on     = (nibble & (1 << (3 - (bit % 4)))) != 0;
        if (on) packed[bit >> 3] |= 1U << (bit & 7U);
    }

    lockFrame();
    memcpy(frameBits, packed, FRAME_BYTES);
    state.lastM370   = normalized;
    state.lastReason = reason;
    ++state.framesAccepted;
    showCurrentFrameNoLock();
    unlockFrame();
    return true;
}

void applyPackedFrame(const uint8_t* packedBits, const String& reason) {
    lockFrame();
    memcpy(frameBits, packedBits, FRAME_BYTES);
    state.lastReason = reason;
    ++state.framesAccepted;
    showCurrentFrameNoLock();
    unlockFrame();
}

void applyBlankFrame(const String& reason) {
    lockFrame();
    memset(frameBits, 0, FRAME_BYTES);
    state.lastM370   = blankM370();
    state.lastReason = reason;
    ++state.framesAccepted;
    showCurrentFrameNoLock();
    unlockFrame();
}

// ---------------------------------------------------------------------------
// Color / brightness
// ---------------------------------------------------------------------------

void setColorStateNoRender(const String& input) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) return;
    char buf[8];
    snprintf(buf, sizeof(buf), "#%02x%02x%02x", r, g, b);
    state.colorHex = buf;
    state.colorR   = r;
    state.colorG   = g;
    state.colorB   = b;
}

bool setColor(const String& input, String& error) {
    uint8_t r, g, b;
    if (!parseColorHex(input, r, g, b)) {
        error = "color must be #RRGGBB or RRGGBB (hex)";
        return false;
    }
    char buf[8];
    snprintf(buf, sizeof(buf), "#%02x%02x%02x", r, g, b);
    lockFrame();
    state.colorHex = buf;
    state.colorR   = r;
    state.colorG   = g;
    state.colorB   = b;
    showCurrentFrameNoLock();
    unlockFrame();
    return true;
}

void setBrightness(int raw) {
    raw = constrain(raw, MIN_BRIGHTNESS, MAX_BRIGHTNESS);
    lockFrame();
    state.brightness = static_cast<uint8_t>(raw);
    showCurrentFrameNoLock();
    unlockFrame();
}
