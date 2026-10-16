#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

bool mountFilesystem();

// Call from setup/Core 0's serialized control path. Buffer reads and writes
// release Storage/HardwareBus between <=2048-byte payload operations, yielding
// between chunks; filesystem metadata operations retain the normal locks.
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

// Stages the complete runtime table before publishing it. On startup, invalid
// individual records are logged and skipped without rewriting the source file.
// false preserves the displayed pixels and current id when it still exists.
bool installSavedFacesDocument(JsonVariant document, bool applyStartupFace);

// Shared logical-frame decoder. Legacy parts+bitmap records retain their
// authoritative bitmap; ID-only parts require the exact supported catalog.
bool materializeSavedFace(JsonObject face, uint8_t* out, String& error);

// Losslessly compact matching parts+bitmap records; stale metadata becomes
// custom bitmap content. Both functions mutate only the supplied document.
bool canonicalizeSavedFaces(JsonVariant document, String& error);
bool expandSavedFacesDocument(JsonVariant document, String& error);

bool validateSavedFaces(JsonVariant document, String& error);

// Validate, canonicalize, prebuild the runtime table, atomically commit, and
// publish without further allocation. A successful save never applies a frame.
size_t writeSavedFaces(JsonVariant document, String& error);

// Monotonic counter incremented on every successful writeSavedFaces() call.
uint32_t savedFacesGeneration();

bool ensureSavedFacesLoaded();
