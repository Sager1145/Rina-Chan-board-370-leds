#include "storage.h"
#include "state.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "faces.h"
#include "sync.h"
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

static bool ensureResourcesDirectory() {
    if (!fsMounted) return false;
    bool ok = false;
    lockHardwareBus();
    ok = LittleFS.exists("/resources") || LittleFS.mkdir("/resources");
    unlockHardwareBus();
    return ok;
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

    lockHardwareBus();
    File file = LittleFS.open(SETTINGS_PATH, "w");
    unlockHardwareBus();
    if (!file) {
        Serial.println("Failed to open runtime_settings.json for write");
        return false;
    }
    lockHardwareBus();
    serializeJson(doc, file);
    file.close();
    unlockHardwareBus();
    ++state.settingsWrites;
    return true;
}

bool loadRuntimeSettings() {
    if (!fsMounted) return false;
    bool settingsExists = false;
    lockHardwareBus();
    settingsExists = LittleFS.exists(SETTINGS_PATH);
    unlockHardwareBus();
    if (!settingsExists) {
        Serial.println("runtime_settings.json not found; writing defaults");
        saveRuntimeSettings();
        return false;
    }

    lockHardwareBus();
    File file = LittleFS.open(SETTINGS_PATH, "r");
    unlockHardwareBus();
    if (!file) {
        Serial.println("Failed to open runtime_settings.json");
        return false;
    }

    DynamicJsonDocument doc(768);
    lockHardwareBus();
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(8));
    file.close();
    unlockHardwareBus();
    if (err) {
        Serial.printf("runtime_settings.json parse failed: %s\n", err.c_str());
        return false;
    }

    const char* mode = doc["mode"] | DEFAULT_MODE;
    if (!setMode(mode, false)) setMode(DEFAULT_MODE, false);

    if (doc["autoIntervalMs"].is<uint32_t>()) {
        setAutoInterval(doc["autoIntervalMs"].as<uint32_t>(), false);
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
    if (!ensureResourcesDirectory()) {
        error = "failed to ensure /resources for saved_faces.json";
        return 0;
    }

    lockHardwareBus();
    File file = LittleFS.open(SAVED_FACES_PATH, "w");
    unlockHardwareBus();
    if (!file) {
        error = "failed to write saved_faces.json";
        return 0;
    }
    lockHardwareBus();
    const size_t written = serializeJson(document, file);
    file.close();
    unlockHardwareBus();
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
    bool savedFacesExists = false;
    lockHardwareBus();
    savedFacesExists = LittleFS.exists(SAVED_FACES_PATH);
    unlockHardwareBus();
    if (!savedFacesExists) {
        Serial.println("No saved_faces.json; LED output starts blank");
        autoFaceCount = 0;
        return false;
    }

    lockHardwareBus();
    File file = LittleFS.open(SAVED_FACES_PATH, "r");
    unlockHardwareBus();
    if (!file) {
        Serial.println("Failed to open saved_faces.json");
        return false;
    }

    lockHardwareBus();
    const size_t savedFacesSize = file.size();
    unlockHardwareBus();

    DynamicJsonDocument doc(jsonCapacityFor(savedFacesSize));
    lockHardwareBus();
    DeserializationError err = deserializeJson(doc, file, DeserializationOption::NestingLimit(32));
    file.close();
    unlockHardwareBus();
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
                            : (firstDefaultIndex >= 0 ? firstDefaultIndex : 0);
    }
    state.autoFaceIndex = static_cast<uint16_t>(selectedIndex);
    Serial.printf("Loaded %u saved faces for firmware auto mode\n", autoFaceCount);

    if (applyStartupFace) {
        String error;
        state.brightness = DEFAULT_BRIGHTNESS;
        state.playback   = DEFAULT_PLAYBACK;
        state.paused     = false;
        if (!applyM370(autoFaces[state.autoFaceIndex].m370, STARTUP_FACE_REASON, error)) {
            Serial.printf("startup M370 failed: %s\n", error.c_str());
            return false;
        }
        Serial.printf("Loaded startup face index: %u\n", state.autoFaceIndex);
    }

    return true;
}
