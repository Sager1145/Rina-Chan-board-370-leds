#pragma once
#include <Arduino.h>
#include "config.h"

// ---------------------------------------------------------------------------
// M370 frame codec
// ---------------------------------------------------------------------------

// Parse and normalize an M370 hex string.
// Input may optionally be prefixed with "M370:" and may contain whitespace.
// On success, `normalized` is set to "M370:<93 uppercase hex chars>" and
// returns true.  On failure, `error` is populated and returns false.
bool normalizeM370(const String& input, String& normalized, String& error);

// Decode an M370 string into a packed bit array (FRAME_BYTES bytes).
bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error);

// Return a blank M370 string (all zeros).
String blankM370();

// ---------------------------------------------------------------------------
// Frame bit helpers  (operate on frameBits via state.h)
// ---------------------------------------------------------------------------
void setFrameBit(uint16_t index, bool on);
bool frameBit(uint16_t index);
bool packedFrameBit(const uint8_t* bits, uint16_t index);

// Count how many logical LEDs are currently lit in frameBits.
uint16_t countLitLeds();

// ---------------------------------------------------------------------------
// Frame apply helpers  (take frameMutex internally)
// ---------------------------------------------------------------------------

// Apply an M370 string to frameBits and schedule a render.
// Increments framesAccepted / framesRejected on state.
bool applyM370(const String& input, const String& reason, String& error);

// Copy pre-decoded packed bits into frameBits and schedule a render.
void applyPackedFrame(const uint8_t* packedBits, const String& reason);

// Copy pre-decoded packed bits immediately, bypassing the M370 rate-limit queue.
void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason);

// Clear frameBits to all-off and schedule a render.
void applyBlankFrame(const String& reason);

// Drain one queued M370/pumped frame when the global frame rate limiter allows it.
void serviceM370FrameQueue();

// Drop any pending queued frames that should no longer be allowed to surface.
void clearQueuedM370Frames();

// Current number of queued frames waiting for the global frame rate limiter.
uint8_t queuedM370FrameCount();

// ---------------------------------------------------------------------------
// Color / brightness  (take frameMutex internally where required)
// ---------------------------------------------------------------------------

// Update color state without scheduling a render (for use during boot).
void setColorStateNoRender(const String& input);

// Update color state and schedule a render.
bool setColor(const String& input, String& error);

// Clamp and apply a new brightness value, then schedule a render.
void setBrightness(int raw);

// ---------------------------------------------------------------------------
// Render request / consume  (ISR-safe via portMUX)
// ---------------------------------------------------------------------------
void requestLedRender();
bool consumeLedRenderRequest();

// Convenience wrapper used inside frameMutex-held sections.
void showCurrentFrameNoLock();

// ---------------------------------------------------------------------------
// Physical render  (called only from the render task on Core 1)
// ---------------------------------------------------------------------------
void renderCurrentFrameToLedStrip();

// ---------------------------------------------------------------------------
// LED index map  (call once at boot before any render)
// ---------------------------------------------------------------------------
void initLedIndexMap();

// ---------------------------------------------------------------------------
// Strip initialization  (call once from setup())
// ---------------------------------------------------------------------------
void ledStripBegin();
