#pragma once
#include <Arduino.h>

bool isAutoMode();

String normalizedMode(const char* input);

bool setMode(const char* input, bool persistSettings = true);

void setAutoInterval(uint32_t ms, bool persistSettings = true);

bool applySavedFaceIndex(uint16_t index, const String& reason, const char* playback);

bool applyRelativeSavedFace(int8_t delta, const String& reason);

bool applyCurrentSavedFaceForMode(const String& reason, bool autoMode);

bool toggleModeFromButtonAction(const String& source);

void cancelDeferredFaceRestore();

void scheduleCurrentSavedFaceRestoreAfterBlank(bool autoMode, const String& reason);

void serviceDeferredFaceRestore();

void stopFirmwareScroll(bool restoreAuto, bool clearDisplay = false);

void startFirmwareScroll(uint16_t intervalMs);

bool playbackIsNonFaceActivity();

void serviceAutoPlayback();
