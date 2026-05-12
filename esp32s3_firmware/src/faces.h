#pragma once
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Mode helpers
// ---------------------------------------------------------------------------
bool isAutoMode();

// Normalize a mode string: accepts "auto"/"A"/"自动" → "auto",
// "manual"/"M"/"手动" → "manual".
String normalizedMode(const char* input);

// Set the playback mode.  persistSettings=true saves to LittleFS.
bool setMode(const char* input, bool persistSettings = true);

// Set the auto-advance interval.  persistSettings=true saves to LittleFS.
void setAutoInterval(uint32_t ms, bool persistSettings = true);

// ---------------------------------------------------------------------------
// Face apply helpers
// ---------------------------------------------------------------------------

// Apply the saved face at the given index and schedule a render.
bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback);

// Apply a face at (currentIndex + delta) with wrapping.
bool applyRelativeSavedFace(int8_t delta, const String& reason);

// Apply the face currently pointed to by state.autoFaceIndex for the given mode.
bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode);

// ---------------------------------------------------------------------------
// Scroll stop / startup face restore
// ---------------------------------------------------------------------------

// Find the index of the startup-default face (-1 if none available).
int16_t findStartupDefaultFaceIndex();

// After stopping scroll, restore the startup default face in the requested mode.
bool applyStartupDefaultFaceAfterScrollStop(bool restoreAutoMode);

// Cancel / schedule / service deferred restores that must happen after an
// all-off frame has had time to latch.  serviceDeferredFaceRestore() is called
// from loop(), so HTTP handlers never block for the blank-frame hold time.
void cancelDeferredFaceRestore();
void scheduleStartupDefaultFaceRestoreAfterBlank(bool autoMode);
void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason);
void serviceDeferredFaceRestore();

// ---------------------------------------------------------------------------
// Scroll lifecycle
// ---------------------------------------------------------------------------

// Immediately stop the firmware scroll engine.
// clearDisplay=true pushes a blank frame then restores the default face.
void stopFirmwareScroll(bool restoreAuto, bool clearDisplay = false);

// Arm and start the firmware scroll engine from scrollFrameBits[].
void startFirmwareScroll(uint16_t intervalMs);

// ---------------------------------------------------------------------------
// Playback state query
// ---------------------------------------------------------------------------

// Returns true when playback is some non-face activity (scroll, custom, etc.)
// that should be interrupted before switching faces.
bool playbackIsNonFaceActivity();

// ---------------------------------------------------------------------------
// Auto-playback  (called each loop() iteration)
// ---------------------------------------------------------------------------
void serviceAutoPlayback();
