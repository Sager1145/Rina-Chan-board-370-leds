#pragma once
#include <Arduino.h>
#include "config.h"
#include "state.h"
#include "led_presentation.h"

bool validatePackedFrame(const uint8_t* packedBits, String& error);

void setFrameBit(uint16_t index, bool on);

bool packedFrameBit(const uint8_t* bits, uint16_t index);

FrameStateSnapshot readFrameStateSnapshot();

bool applyPackedFrameQueued(const uint8_t* packedBits, const String& reason, String& error);

// `ctx` (optional) lets a caller (scroll start/step) attach the precise timeline/frame
// identity that the renderer should report as the next presented sample. Pass nullptr for
// plain immediate frames (those are reported as non-rate-eligible if at all).
void applyPackedFrameImmediate(const uint8_t* packedBits, const String& reason,
                               const LedPresentationContext* ctx = nullptr);

// Stash the identity/state of the frame about to be rendered. The next
// renderCurrentFrameToLedStrip() consumes it and, after the LED latch completes,
// publishes a LedPresentedSample. Safe to call from Core 1 (uses a critical section).
void setPendingLedPresentationContext(const LedPresentationContext& ctx);

// Read the most recently presented (LED-latched) frame sample. Used by /api/preview_sync.
LedPresentedSample readLedPresentedSample();

void applyBlankFrame(const String& reason);

void servicePackedFrameQueue();

void clearQueuedPackedFrames();

uint8_t queuedPackedFrameCount();

void setColorStateNoRender(const String& input);

bool setColor(const String& input, String& error);

void setBrightness(int raw);

void requestLedRender();

bool consumeLedRenderRequest();

void showCurrentFrameNoLock();

void renderCurrentFrameToLedStrip();

void initLedIndexMap();

void ledStripBegin();
