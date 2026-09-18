#pragma once
#include <Arduino.h>

bool isAutoMode();

bool setMode(const char* input, bool persistSettings = true, bool takeOutputControl = true);

void setAutoInterval(uint32_t ms, bool persistSettings = true);

bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback);

bool applyRelativeSavedFace(int8_t delta, const String& reason);

bool toggleModeFromButtonAction(const String& source);

void serviceDeferredFaceRestore();

// Board group v1 (§1.5): scrollSessionGroupStart() calls this directly (like
// startFirmwareScroll() does for scrollSessionStart()) so a group_start that
// interrupts a pending deferred face restore does not race it.
void cancelDeferredFaceRestore();

void stopFirmwareScroll(bool restoreAuto, bool clearDisplay = false, bool restoreDefaultAfterClear = false);

// Transfer display ownership to an external frame without inserting a blank.
void takeOverExternalFrame();

bool startFirmwareScroll(uint16_t intervalMs, uint8_t uiFps = 0);

void serviceAutoPlayback();
