#include "storage.h"
#include "state.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "faces.h"
#include <LittleFS.h>

// ---------------------------------------------------------------------------
// Filesystem mount
// ---------------------------------------------------------------------------

bool mountFilesystem() {
    fsMounted = LittleFS.begin(false, LITTLEFS_BASE_PATH, 10, LITTLEFS_PARTITION_LABEL);
    if (!fsMounted) {
        Serial.println("LittleFS mount failed. Upload data with: pio run -t uploadfs");
    }
    return fsMounted;
}

bool ensureResourcesDirectory() {
    if (!fsMounted) return false;
    if (LittleFS.exists("/resources")) return true;
    return LittleFS.mkdir("/resources");
}

// ---------------------------------------------------------------------------
// Runtime settings
// ---------------------------------------------------------------------------

bool saveRuntimeSettings() {
    if (!fsMounted) return false;
    if (!ensureResourcesDirectory()) {
        Serial.println("Failed to ensure /resources for runtime settings");
        return false;
    }

    DynamicJsonDocument doc(384);
    doc["format"]         = "rina_runtime_settings_v1";
    doc["version"]        = 1;
    doc["mode"]           = state.mode;
    doc["autoIntervalMs"] = state.autoIntervalMs;
    doc["updatedAtMs"]    = millis();

    File file = LittleFS.open(SETTINGS_PATH, "w");
    if (!file) {
        Serial.println("Failed to open runtime_settings.json for write");
        return false;
    }
    serializeJson(doc, file);
    file.close();
    ++state.settingsWrites;
    return true;
}

bool loadRuntimeSettings() {
    if (!fsMounted) return false;
    if (!LittleFS.exists(SETTINGS_PATH)) {
        Serial.println("runtime_settings.json not found; writing defaults");
        saveRuntimeSettings();
        return false;
    }

    File file = LittleFS.open(SETTINGS_PATH, "r");
    if (!file) {
        Serial.println("Failed to open runtime_settings.json");
        return false;
    }

    DynamicJsonDocument doc(768);
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(8));
    file.close();
    if (err) {
        Serial.printf("runtime_settings.json parse failed: %s\n", err.c_str());
        return false;
    }

    const char* mode = doc["mode"] | DEFAULT_MODE;
    if (!setMode(mode, false)) setMode(DEFAULT_MODE, false);

    if (doc["autoIntervalMs"].is<uint32_t>()) {
        setAutoInterval(doc["autoIntervalMs"].as<uint32_t>(), false);
    } else if (doc["auto_interval_ms"].is<uint32_t>()) {
        setAutoInterval(doc["auto_interval_ms"].as<uint32_t>(), false);
    }

    Serial.printf("Runtime settings loaded: mode=%s autoIntervalMs=%lu\n",
                  state.mode.c_str(),
                  static_cast<unsigned long>(state.autoIntervalMs));
    return true;
}

// ---------------------------------------------------------------------------
// Saved faces -- validate
// ---------------------------------------------------------------------------

bool validateSavedFaces(JsonVariant document, String& error) {
    const char* category = document["category"] | "";
    if (strcmp(category, "unified_saved_faces") != 0) {
        error = "document.category must be unified_saved_faces";
        return false;
    }

    JsonArray faces = document["faces"].as<JsonArray>();
    if (faces.isNull()) {
        error = "document.faces must be an array";
        return false;
    }

    uint16_t defaultCount = 0;
    for (JsonObject face : faces) {
        const char* type = face["type"] | "";
        const char* m370 = face["m370"] | "";
        if (strcmp(type, "default") == 0) ++defaultCount;
        if (strlen(m370) > 0) {
            String normalized, faceError;
            if (!normalizeM370(m370, normalized, faceError)) {
                error = String("invalid face m370: ") + faceError;
                return false;
            }
        }
    }

    if (defaultCount == 0) {
        error = "saved_faces.json must keep at least one type:\"default\" face";
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Saved faces -- write
// ---------------------------------------------------------------------------

size_t writeSavedFaces(JsonVariant document, String& error) {
    if (!fsMounted) {
        error = "LittleFS is not mounted";
        return 0;
    }
    ensureResourcesDirectory();

    File file = LittleFS.open(SAVED_FACES_PATH, "w");
    if (!file) {
        error = "failed to write saved_faces.json";
        return 0;
    }
    const size_t written = serializeJson(document, file);
    file.close();
    ++state.savedFacesWrites;
    return written;
}

// ---------------------------------------------------------------------------
// Saved faces -- load into autoFaces[]
// ---------------------------------------------------------------------------

bool ensureSavedFacesLoaded() {
    if (autoFaceCount > 0) return true;
    return loadSavedFaces(false) && autoFaceCount > 0;
}

bool loadSavedFaces(bool applyStartupFace) {
    if (!fsMounted) {
        Serial.println("LittleFS not mounted; saved faces cannot be loaded");
        return false;
    }
    if (!LittleFS.exists(SAVED_FACES_PATH)) {
        Serial.println("No saved_faces.json; LED output starts blank");
        autoFaceCount = 0;
        return false;
    }

    File file = LittleFS.open(SAVED_FACES_PATH, "r");
    if (!file) {
        Serial.println("Failed to open saved_faces.json");
        return false;
    }

    DynamicJsonDocument doc(jsonCapacityFor(file.size()));
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(32));
    file.close();
    if (err) {
        Serial.printf("saved_faces.json parse failed: %s\n", err.c_str());
        autoFaceCount = 0;
        return false;
    }

    const String   startupId        = doc["startupDefaultId"] | "";
    JsonArray      faces            = doc["faces"].as<JsonArray>();
    String         previousFaceId;
    const uint16_t previousFaceIndex = state.autoFaceIndex;
    if (autoFaceCount > 0 && state.autoFaceIndex < autoFaceCount) {
        previousFaceId = autoFaces[state.autoFaceIndex].id;
    }
    autoFaceCount   = 0;
    uint16_t jsonIndex = 0;

    for (JsonObject face : faces) {
        const char* m370 = face["m370"] | "";
        String normalized, error;
        if (!normalizeM370(m370, normalized, error)) {
            Serial.printf("Skipping invalid saved face: %s\n", error.c_str());
            ++jsonIndex;
            continue;
        }
        if (autoFaceCount >= MAX_AUTO_FACES) break;

        RuntimeFace& runtime     = autoFaces[autoFaceCount++];
        runtime.id               = String(face["id"] | "");
        runtime.name             = String(face["name"] | runtime.id.c_str());
        runtime.m370             = normalized;
        runtime.order            = face["order"].is<int32_t>()
                                       ? face["order"].as<int32_t>()
                                       : static_cast<int32_t>(jsonIndex);
        runtime.jsonIndex        = jsonIndex;
        runtime.isDefault        = strcmp(face["type"] | "", "default") == 0;
        runtime.isStartupDefault = face["is_startup_default"].as<bool>() ||
                                   (!startupId.isEmpty() && startupId == runtime.id);
        ++jsonIndex;
    }

    if (autoFaceCount == 0) {
        Serial.println("saved_faces.json has no valid faces");
        return false;
    }

    // Stable-sort by (order, jsonIndex)
    for (uint16_t i = 0; i < autoFaceCount; ++i) {
        for (uint16_t j = i + 1; j < autoFaceCount; ++j) {
            const bool shouldSwap =
                autoFaces[j].order < autoFaces[i].order ||
                (autoFaces[j].order == autoFaces[i].order &&
                 autoFaces[j].jsonIndex < autoFaces[i].jsonIndex);
            if (shouldSwap) {
                RuntimeFace tmp = autoFaces[i];
                autoFaces[i]    = autoFaces[j];
                autoFaces[j]    = tmp;
            }
        }
    }

    // Select which face index to use
    int selectedIndex     = -1;
    int firstDefaultIndex = -1;
    int firstFaceIndex    = autoFaceCount > 0 ? 0 : -1;
    for (uint16_t i = 0; i < autoFaceCount; ++i) {
        if (autoFaces[i].isDefault && firstDefaultIndex < 0) firstDefaultIndex = i;
        if (selectedIndex < 0) {
            if (!applyStartupFace && !previousFaceId.isEmpty() &&
                previousFaceId == autoFaces[i].id) {
                selectedIndex = i;
            } else if (applyStartupFace &&
                       ((!startupId.isEmpty() && startupId == autoFaces[i].id) ||
                        autoFaces[i].isStartupDefault)) {
                selectedIndex = i;
            }
        }
    }
    if (selectedIndex < 0) {
        selectedIndex = (!applyStartupFace && previousFaceIndex < autoFaceCount)
                            ? previousFaceIndex
                            : (firstDefaultIndex >= 0 ? firstDefaultIndex : firstFaceIndex);
    }
    state.autoFaceIndex = static_cast<uint16_t>(selectedIndex);
    Serial.printf("Loaded %u saved faces for firmware auto mode\n", autoFaceCount);

    if (applyStartupFace) {
        String error;
        const String   bootMode       = state.mode;
        const uint32_t bootIntervalMs = state.autoIntervalMs;
        state.defaultBrightness = DEFAULT_BRIGHTNESS;
        state.brightness        = state.defaultBrightness;
        state.playback          = DEFAULT_PLAYBACK;
        state.paused            = false;
        if (!applyM370(autoFaces[state.autoFaceIndex].m370, STARTUP_FACE_REASON, error)) {
            Serial.printf("startup M370 failed: %s\n", error.c_str());
            return false;
        }
        state.autoIntervalMs = bootIntervalMs;
        setMode(bootMode.c_str(), false);
        Serial.printf("Loaded startup face index: %u\n", state.autoFaceIndex);
    }

    return true;
}
