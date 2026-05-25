#pragma once
#include <Arduino.h>
#include "config.h"

// ---------------------------------------------------------------------------
// M370 frame codec
// ---------------------------------------------------------------------------

/**
 * @brief Parse and normalize an M370 hex string.
 * @param input Text that may include "M370:" and whitespace.
 * @param normalized Receives "M370:<93 uppercase hex chars>" on success.
 * @param error Receives a validation error on failure.
 * @return true when the payload contains exactly one 370-bit frame.
 */
bool normalizeM370(const String& input, String& normalized, String& error);

/**
 * @brief Decode an M370 string into packed logical LED bits.
 * @param input Raw or normalized M370 text.
 * @param outBits Destination buffer of FRAME_BYTES bytes.
 * @param error Receives a validation error on failure.
 * @return true when outBits was written.
 */
bool m370ToPackedBits(const String& input, uint8_t* outBits, String& error);

/**
 * @brief Build a canonical all-off M370 frame.
 * @param None.
 * @return M370 text containing all zero bits.
 */
String blankM370();

// ---------------------------------------------------------------------------
// Frame bit helpers  (operate on frameBits via state.h)
// ---------------------------------------------------------------------------
/**
 * @brief Set or clear one bit in the active runtime frame.
 * @param index Logical LED index.
 * @param on true to set the bit.
 * @return None.
 */
void setFrameBit(uint16_t index, bool on);

/**
 * @brief Read one bit from the active runtime frame.
 * @param index Logical LED index.
 * @return true when the bit is set.
 */
bool frameBit(uint16_t index);

/**
 * @brief Read one bit from an arbitrary packed frame.
 * @param bits FRAME_BYTES packed source buffer.
 * @param index Logical LED index.
 * @return true when the bit is set.
 */
bool packedFrameBit(const uint8_t* bits, uint16_t index);

/**
 * @brief Count lit LEDs in the active runtime frame.
 * @param None.
 * @return Number of set bits up to LED_COUNT.
 */
uint16_t countLitLeds();

// ---------------------------------------------------------------------------
// Frame apply helpers  (take frameMutex internally)
// ---------------------------------------------------------------------------

/**
 * @brief Apply an M370 string to frame state and schedule rendering.
 * @param input Raw or normalized M370 text.
 * @param reason Human-readable reason stored in runtime state.
 * @param error Receives validation failure text.
 * @return true when the frame was accepted.
 */
bool applyM370(const String& input, const String& reason, String& error);

/**
 * @brief Queue or publish predecoded packed bits.
 * @param packedBits FRAME_BYTES source buffer.
 * @param reason Human-readable reason stored in runtime state.
 * @return None.
 */
void applyPackedFrame(const uint8_t* packedBits, const String& reason);

/**
 * @brief Publish predecoded packed bits immediately.
 * @param packedBits FRAME_BYTES source buffer.
 * @param reason Human-readable reason stored in runtime state.
 * @return None.
 */
void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason);

/**
 * @brief Queue/publish an all-off frame.
 * @param reason Human-readable reason stored in runtime state.
 * @return None.
 */
void applyBlankFrame(const String& reason);

/**
 * @brief Drain one queued frame when the global rate limiter allows it.
 * @param None.
 * @return None.
 */
void serviceM370FrameQueue();

/**
 * @brief Drop pending queued frames.
 * @param None.
 * @return None.
 */
void clearQueuedM370Frames();

/**
 * @brief Report queued frame count.
 * @param None.
 * @return Number of frames waiting behind the rate limiter.
 */
uint8_t queuedM370FrameCount();

// ---------------------------------------------------------------------------
// Color / brightness  (take frameMutex internally where required)
// ---------------------------------------------------------------------------

/**
 * @brief Update color state without scheduling a render.
 * @param input Color string in #RRGGBB or RRGGBB form.
 * @return None.
 */
void setColorStateNoRender(const String& input);

/**
 * @brief Update color state and schedule a render.
 * @param input Color string in #RRGGBB or RRGGBB form.
 * @param error Receives validation failure text.
 * @return true when color was applied.
 */
bool setColor(const String& input, String& error);

/**
 * @brief Clamp and apply a new brightness value, then schedule a render.
 * @param raw Requested brightness.
 * @return None.
 */
void setBrightness(int raw);

// ---------------------------------------------------------------------------
// Render request / consume  (ISR-safe via portMUX)
// ---------------------------------------------------------------------------
/**
 * @brief Request a physical LED render from Core 0 or ISR context.
 * @param None.
 * @return None.
 */
void requestLedRender();

/**
 * @brief Consume the pending render-request flag.
 * @param None.
 * @return true when a render was requested.
 */
bool consumeLedRenderRequest();

/**
 * @brief Request render while the caller already owns frame state.
 * @param None.
 * @return None.
 */
void showCurrentFrameNoLock();

// ---------------------------------------------------------------------------
// Physical render  (called only from the render task on Core 1)
// ---------------------------------------------------------------------------
/**
 * @brief Render the active frame/overlay to the physical LED strip.
 * @param None.
 * @return None.
 */
void renderCurrentFrameToLedStrip();

// ---------------------------------------------------------------------------
// LED index map  (call once at boot before any render)
// ---------------------------------------------------------------------------
/**
 * @brief Precompute logical-to-physical LED index mapping.
 * @param None.
 * @return None.
 */
void initLedIndexMap();

// ---------------------------------------------------------------------------
// Strip initialization  (call once from setup())
// ---------------------------------------------------------------------------
/**
 * @brief Initialize NeoPixel strip hardware and latch a blank frame.
 * @param None.
 * @return None.
 */
void ledStripBegin();
