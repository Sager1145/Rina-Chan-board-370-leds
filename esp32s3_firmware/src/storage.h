#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

// ---------------------------------------------------------------------------
// LittleFS helpers
// ---------------------------------------------------------------------------

/**
 * @brief Mount LittleFS and update the runtime filesystem flag.
 * @param None.
 * @return true when the filesystem is available.
 */
bool mountFilesystem();

// ---------------------------------------------------------------------------
// Runtime settings  (mode, autoIntervalMs)
// ---------------------------------------------------------------------------
/**
 * @brief Load mode and auto interval from runtime_settings.json.
 * @param None.
 * @return true when the file existed, parsed, and was applied.
 */
bool loadRuntimeSettings();

/**
 * @brief Persist mode and auto interval to runtime_settings.json.
 * @param None.
 * @return true when settings were written.
 */
bool saveRuntimeSettings();

/**
 * @brief Write JSON through a temp file and rename it into place after serialization.
 * @param path Destination LittleFS path.
 * @param document JSON variant to serialize.
 * @param written Receives serialized byte count.
 * @param error Receives failure text.
 * @return true when the destination path was committed.
 */
bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error);

// ---------------------------------------------------------------------------
// Saved faces file  (raw JSON pass-through)
// ---------------------------------------------------------------------------

/**
 * @brief Parse and load saved_faces.json into runtimeAutoFaces().
 * @param applyStartupFace true to render the chosen startup/default face.
 * @return true when at least one valid face was loaded.
 */
bool loadSavedFaces(bool applyStartupFace);

/**
 * @brief Validate a parsed saved-faces document before writing it.
 * @param document Parsed candidate JSON document.
 * @param error Receives validation failure text.
 * @return true when required saved-face invariants are satisfied.
 */
bool validateSavedFaces(JsonVariant document, String& error);

/**
 * @brief Write raw JSON to saved_faces.json.
 * @param document Parsed JSON document to write.
 * @param error Receives failure text.
 * @return Number of bytes written, or 0 on failure.
 */
size_t writeSavedFaces(JsonVariant document, String& error);

/**
 * @brief Ensure runtimeAutoFaces() is populated, lazy-loading if needed.
 * @param None.
 * @return true when at least one valid face is available.
 */
bool ensureSavedFacesLoaded();
