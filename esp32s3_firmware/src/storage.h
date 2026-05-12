#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

// ---------------------------------------------------------------------------
// LittleFS helpers
// ---------------------------------------------------------------------------

// Mount LittleFS and update the global fsMounted flag.
// Returns true on success.
bool mountFilesystem();

// Ensure /resources directory exists.
bool ensureResourcesDirectory();

// ---------------------------------------------------------------------------
// Runtime settings  (mode, autoIntervalMs)
// ---------------------------------------------------------------------------
bool loadRuntimeSettings();
bool saveRuntimeSettings();

// ---------------------------------------------------------------------------
// Saved faces file  (raw JSON pass-through)
// ---------------------------------------------------------------------------

// Parse, validate, and load saved_faces.json into the autoFaces[] table.
// If applyStartupFace is true the startup-default face is rendered immediately.
bool loadSavedFaces(bool applyStartupFace);

// Validate a parsed saved_faces document before writing.
bool validateSavedFaces(JsonVariant document, String& error);

// Write raw JSON to saved_faces.json, then reload autoFaces[].
// Returns the number of bytes written, or 0 on failure.
size_t writeSavedFaces(JsonVariant document, String& error);

// Ensure autoFaces[] is populated (lazy-loads if needed).
bool ensureSavedFacesLoaded();
