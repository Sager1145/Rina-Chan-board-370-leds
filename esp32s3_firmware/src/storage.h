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

// Copy a parsed saved-faces document into the runtime table. Strings and
// frame bytes are copied, so the JSON document may die afterward.
// applyStartupFace selects the startup face and queues its frame; false keeps
// the current id and does not push a frame. Sort, MAX_AUTO_FACES, and the
// clear-then-fill order match loadSavedFaces.
bool installSavedFacesDocument(JsonVariant document, bool applyStartupFace);

bool validateSavedFaces(JsonVariant document, String& error);

size_t writeSavedFaces(JsonVariant document, String& error);

// Monotonic counter incremented on every successful writeSavedFaces() call.
uint32_t savedFacesGeneration();

bool ensureSavedFacesLoaded();
