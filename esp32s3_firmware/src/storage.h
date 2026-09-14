#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

bool mountFilesystem();

bool readStringFromFileLocked(const char* path, String& outContent);
bool writeStringToFileLocked(const char* path, const String& content);
bool readBufferFromFileLocked(const char* path, char*& outBuf, size_t& outSize);

bool loadRuntimeSettings();

bool saveRuntimeSettings();

// Coalesce rapid mode changes into one flash write. Call the service once per
// loop; explicit settings writes still use saveRuntimeSettings() immediately.
void scheduleRuntimeSettingsSave();
void serviceRuntimeSettingsSave();

bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error);

bool loadSavedFaces(bool applyStartupFace);

bool validateSavedFaces(JsonVariant document, String& error);

size_t writeSavedFaces(JsonVariant document, String& error);

// Monotonic counter incremented on every successful writeSavedFaces() call.
uint32_t savedFacesGeneration();

bool ensureSavedFacesLoaded();
