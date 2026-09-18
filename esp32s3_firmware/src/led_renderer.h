#pragma once
#include <Arduino.h>
#include "config.h"
#include "state.h"
#include "led_presentation.h"

bool validatePackedFrame(const uint8_t* packedBits, String& error);

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

// Read the most recently presented (LED-latched) frame sample. Used by GET_PREVIEW_SYNC / EV_PREVIEW_SYNC.
LedPresentedSample readLedPresentedSample();

void applyBlankFrame(const String& reason);

void servicePackedFrameQueue();

void clearQueuedPackedFrames();

uint8_t queuedPackedFrameCount();

void setColorStateNoRender(const String& input);

bool setColor(const String& input, String& error);

void setBrightness(int raw);

// Hint LED: one logical LED drawn at half the board colour on top of the
// current frame, whether that LED is lit in the frame or not. The app uses it
// to mirror where an Apple Pencil hovers over the face editor. `led` = -1
// clears it. `mirror` (-1 = none) draws a second LED the same way, for the
// left/right-eye mirror mode; it is ignored (treated as none) whenever `led`
// is -1 or equal to `mirror`. Owned by the client slot that set it, so that
// client's disconnect can clear it (see clearHintLedOwnedBy).
bool setHintLed(int led, int mirror, uint8_t ownerSlot, String& error);
void clearHintLedOwnedBy(uint8_t ownerSlot);

// Unconditional clear (any owner), used when output leaves the control mode.
// Loop-task only.
void clearHintLed();

// Current hint LED index (-1 if none), for status/diagnostics.
int16_t hintLedForDiagnostics();

// Current hint mirror LED index (-1 if none), for status/diagnostics.
int16_t hintMirrorLedForDiagnostics();

// Board group v1 identify overlay (docs/BOARD_GROUP_SPEC.md §1.2): replaces the
// whole presented frame with a black background and a large digit (board
// colour) while shown. `number` 1..9, `ttlMs` 0..30000 (0 cancels). Self-expires
// by wall clock (esp_timer_get_time()) inside the render path -- independent of
// any client connection; a new call re-arms it. Highest overlay priority
// (identify > hint > button overlay > content): while shown, the hint LED and
// button-animation overlay are not drawn. Caller (protocol.cpp) validates the
// number/ttlMs ranges before calling.
void setIdentifyOverlay(int number, int ttlMs);

// True when the identify overlay is currently armed and its ttl has elapsed
// as of `nowUs` (esp_timer_get_time()). Read-only: does NOT clear the
// overlay itself (that still happens inside renderCurrentFrameToLedStrip()
// the next time it runs). Callers that only render on state changes (the
// scroll render task) use this to force a render pass so a static screen
// still clears the overlay promptly instead of waiting for unrelated
// scroll/content activity. Takes the Frame lock internally.
bool identifyOverlayExpiryDue(uint64_t nowUs);

void requestLedRender();

bool consumeLedRenderRequest();

void showCurrentFrameNoLock();

void renderCurrentFrameToLedStrip();

void initLedIndexMap();

void ledStripBegin();

// Diagnostic pattern shown at boot when LittleFS fails to mount.
void showFilesystemErrorPattern();
