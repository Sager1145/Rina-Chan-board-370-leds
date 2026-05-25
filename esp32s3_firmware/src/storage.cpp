#include "storage.h"
#include "state.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "faces.h"
#include "sync.h"
#include "psram_json.h"
#include <LittleFS.h>

// ---------------------------------------------------------------------------
// Filesystem mount
// ---------------------------------------------------------------------------

/**
 * @brief Mount LittleFS and publish the filesystem availability flag.
 * @param None.
 * @return true when LittleFS mounted successfully.
 */
bool mountFilesystem() {
    runtimeFsMounted() = LittleFS.begin(false, LITTLEFS_BASE_PATH, 10, LITTLEFS_PARTITION_LABEL);
    if (!runtimeFsMounted()) {
        Serial.println("LittleFS mount failed. Upload data with: pio run -t uploadfs");
    }
    return runtimeFsMounted();
}

/**
 * @brief Ensure the resources directory exists before JSON writes.
 * @param None.
 * @return true when /resources already exists or was created.
 */
static bool ensureResourcesDirectory() {
    if (!runtimeFsMounted()) return false;
    bool ok = false;
    withHardwareBusLock([&]() {
        ok = LittleFS.exists("/resources") || LittleFS.mkdir("/resources");
    });
    return ok;
}

/**
 * @brief Write JSON through a temp file and atomically rename it into place.
 * @param path Destination LittleFS path.
 * @param document JSON variant to serialize.
 * @param written Receives serialized byte count.
 * @param error Receives failure text.
 * @return true when the temp file was serialized and renamed.
 */
bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error) {
    written = 0;
    if (!runtimeFsMounted()) {
        error = "LittleFS is not mounted";
        return false;
    }

    const String tempPath = String(path) + ".tmp";

    File file;
    withHardwareBusLock([&]() {
        // Remove stale temp output first so a failed previous write cannot be
        // mistaken for the current transaction.
        LittleFS.remove(tempPath);
        file = LittleFS.open(tempPath, "w");
    });

    if (!file) {
        error = String("failed to open temp file for write: ") + tempPath;
        return false;
    }

    bool renamed = false;
    withHardwareBusLock([&]() {
        // Serialization, flush, close, and rename share the hardware bus with
        // LED transmit.  Keeping the whole commit under one bus lock prevents
        // another file operation from seeing the temp file mid-write.
        written = serializeJson(document, file);
        file.flush();
        file.close();
        renamed = written > 0 && LittleFS.rename(tempPath, path);
        if (!renamed) LittleFS.remove(tempPath);
    });

    if (!renamed) {
        error = String("failed to commit temp file for: ") + path;
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Runtime settings
// ---------------------------------------------------------------------------

/**
 * @brief Persist runtime mode and auto interval to LittleFS.
 * @param None.
 * @return true when settings were written.
 */
bool saveRuntimeSettings() {
    if (!runtimeFsMounted()) return false;
    if (!ensureResourcesDirectory()) {
        Serial.println("Failed to ensure /resources for runtime settings");
        return false;
    }

    DynamicJsonDocument doc(384);
    doc["format"]         = "rina_runtime_settings_v1";
    doc["version"]        = 1;
    doc["mode"]           = runtimeState().mode;
    doc["autoIntervalMs"] = runtimeState().autoIntervalMs;
    doc["updatedAtMs"]    = millis();

    size_t written = 0;
    String error;
    if (!writeJsonFileAtomic(SETTINGS_PATH, doc.as<JsonVariant>(), written, error)) {
        Serial.printf("Failed to write runtime_settings.json: %s\n", error.c_str());
        return false;
    }
    ++runtimeState().settingsWrites;
    touchRuntimeState();
    return true;
}

/**
 * @brief Load runtime settings and apply them to playback state.
 * @param None.
 * @return true when settings existed, parsed, and were applied.
 */
bool loadRuntimeSettings() {
    if (!runtimeFsMounted()) return false;
    bool settingsExists = false;
    withHardwareBusLock([&]() {
        settingsExists = LittleFS.exists(SETTINGS_PATH);
    });
    if (!settingsExists) {
        Serial.println("runtime_settings.json not found; writing defaults");
        saveRuntimeSettings();
        return false;
    }

    File file;
    withHardwareBusLock([&]() {
        file = LittleFS.open(SETTINGS_PATH, "r");
    });
    if (!file) {
        Serial.println("Failed to open runtime_settings.json");
        return false;
    }

    DynamicJsonDocument doc(768);
    DeserializationError err;
    withHardwareBusLock([&]() {
        err = deserializeJson(doc, file, DeserializationOption::NestingLimit(8));
        file.close();
    });
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
                  runtimeState().mode.c_str(),
                  static_cast<unsigned long>(runtimeState().autoIntervalMs));
    return true;
}

// ---------------------------------------------------------------------------
// Saved faces -- validate
// ---------------------------------------------------------------------------

/**
 * @brief Detect legacy invalid default face IDs such as face_0.
 * @param id Saved-face ID string.
 * @return true when the ID uses a default face number below one.
 */
static bool defaultFaceIdNumberIsInvalid(const char* id) {
    if (id == nullptr || strncmp(id, "face_", 5) != 0) return false;
    const char* p = id + 5;
    if (*p < '0' || *p > '9') return false;
    uint32_t value = 0;
    while (*p >= '0' && *p <= '9') {
        value = value * 10 + static_cast<uint32_t>(*p - '0');
        ++p;
    }
    return value < 1;
}

/**
 * @brief Validate the saved-faces JSON contract before accepting a write.
 * @param document Parsed saved-faces document.
 * @param error Receives validation failure text.
 * @return true when the document preserves required face invariants.
 */
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
        // Validate each persisted face through the same M370 codec used by the
        // renderer.  Storage therefore cannot save a frame the renderer would
        // later reject during startup or face navigation.
        const char* type = face["type"] | "";
        const char* id   = face["id"] | "";
        const char* m370 = face["m370"] | "";
        if (!face["order"].is<int32_t>() || face["order"].as<int32_t>() < 1) {
            error = "face order must be 1-based and >= 1";
            return false;
        }
        if (strcmp(type, "default") == 0) {
            ++defaultCount;
            if (defaultFaceIdNumberIsInvalid(id)) {
                error = "default face id numbers must start at 1";
                return false;
            }
        }
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

/**
 * @brief Write a validated saved-faces document to LittleFS.
 * @param document Parsed JSON document or nested document field.
 * @param error Receives failure text.
 * @return Number of bytes written, or 0 on failure.
 */
size_t writeSavedFaces(JsonVariant document, String& error) {
    if (!runtimeFsMounted()) {
        error = "LittleFS is not mounted";
        return 0;
    }
    if (!ensureResourcesDirectory()) {
        error = "failed to ensure /resources for saved_faces.json";
        return 0;
    }

    size_t written = 0;
    if (!writeJsonFileAtomic(SAVED_FACES_PATH, document, written, error)) {
        return 0;
    }
    ++runtimeState().savedFacesWrites;
    touchRuntimeState();
    return written;
}

// ---------------------------------------------------------------------------
// Saved faces -- load into runtimeAutoFaces()[]
// ---------------------------------------------------------------------------

/**
 * @brief Lazily load saved faces when a playback path needs them.
 * @param None.
 * @return true when at least one valid face is available.
 */
bool ensureSavedFacesLoaded() {
    if (runtimeAutoFaceCount() > 0) return true;
    return loadSavedFaces(false) && runtimeAutoFaceCount() > 0;
}

/**
 * @brief Load saved_faces.json into the runtime face table.
 * @param applyStartupFace true to apply the selected startup/default face.
 * @return true when at least one valid face was loaded.
 */
bool loadSavedFaces(bool applyStartupFace) {
    if (!runtimeFsMounted()) {
        Serial.println("LittleFS not mounted; saved faces cannot be loaded");
        return false;
    }
    bool savedFacesExists = false;
    withHardwareBusLock([&]() {
        savedFacesExists = LittleFS.exists(SAVED_FACES_PATH);
    });
    if (!savedFacesExists) {
        Serial.println("No saved_faces.json; LED output starts blank");
        runtimeAutoFaceCount() = 0;
        touchRuntimeState();
        return false;
    }

    File file;
    withHardwareBusLock([&]() {
        file = LittleFS.open(SAVED_FACES_PATH, "r");
    });
    if (!file) {
        Serial.println("Failed to open saved_faces.json");
        return false;
    }

    size_t savedFacesSize = 0;
    withHardwareBusLock([&]() {
        savedFacesSize = file.size();
    });

    PsramJsonDocument doc(jsonCapacityFor(savedFacesSize));
    DeserializationError err;
    withHardwareBusLock([&]() {
        err = deserializeJson(doc, file, DeserializationOption::NestingLimit(32));
        file.close();
    });
    if (err) {
        Serial.printf("saved_faces.json parse failed: %s\n", err.c_str());
        runtimeAutoFaceCount() = 0;
        touchRuntimeState();
        return false;
    }

    const String   startupId        = doc["startupDefaultId"] | "";
    JsonArray      faces            = doc["faces"].as<JsonArray>();
    String         previousFaceId;
    const uint16_t previousFaceIndex = runtimeState().autoFaceIndex;
    if (runtimeAutoFaceCount() > 0 && runtimeState().autoFaceIndex < runtimeAutoFaceCount()) {
        previousFaceId = runtimeAutoFaces()[runtimeState().autoFaceIndex].id;
    }
    runtimeAutoFaceCount()   = 0;
    uint16_t jsonIndex = 0;

    for (JsonObject face : faces) {
        // Runtime playback keeps only normalized strings and small metadata.
        // The full JSON remains in LittleFS and is streamed by the WebUI route
        // when editing is needed.
        const char* m370 = face["m370"] | "";
        String normalized, error;
        if (!normalizeM370(m370, normalized, error)) {
            Serial.printf("Skipping invalid saved face: %s\n", error.c_str());
            ++jsonIndex;
            continue;
        }
        if (runtimeAutoFaceCount() >= MAX_AUTO_FACES) break;

        RuntimeFace& runtime     = runtimeAutoFaces()[runtimeAutoFaceCount()++];
        runtime.id               = String(face["id"] | "");
        runtime.name             = String(face["name"] | runtime.id.c_str());
        runtime.m370             = normalized;
        runtime.order            = face["order"].is<int32_t>()
                                       ? face["order"].as<int32_t>()
                                       : static_cast<int32_t>(jsonIndex) + 1;
        runtime.jsonIndex        = jsonIndex;
        runtime.isDefault        = strcmp(face["type"] | "", "default") == 0;
        runtime.isStartupDefault = face["is_startup_default"].as<bool>() ||
                                   (!startupId.isEmpty() && startupId == runtime.id);
        ++jsonIndex;
    }

    if (runtimeAutoFaceCount() == 0) {
        Serial.println("saved_faces.json has no valid faces");
        return false;
    }

    // Stable-sort by (order, jsonIndex) so the WebUI storage order and firmware
    // B1/B2 navigation agree even when two faces share the same order value.
    for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
        for (uint16_t j = i + 1; j < runtimeAutoFaceCount(); ++j) {
            const bool shouldSwap =
                runtimeAutoFaces()[j].order < runtimeAutoFaces()[i].order ||
                (runtimeAutoFaces()[j].order == runtimeAutoFaces()[i].order &&
                 runtimeAutoFaces()[j].jsonIndex < runtimeAutoFaces()[i].jsonIndex);
            if (shouldSwap) {
                RuntimeFace tmp = runtimeAutoFaces()[i];
                runtimeAutoFaces()[i]    = runtimeAutoFaces()[j];
                runtimeAutoFaces()[j]    = tmp;
            }
        }
    }

    // Preserve current face across reloads when possible; otherwise choose the
    // startup default for boot or the first default face as a safe fallback.
    int selectedIndex     = -1;
    int firstDefaultIndex = -1;
    for (uint16_t i = 0; i < runtimeAutoFaceCount(); ++i) {
        if (runtimeAutoFaces()[i].isDefault && firstDefaultIndex < 0) firstDefaultIndex = i;
        if (selectedIndex < 0) {
            if (!applyStartupFace && !previousFaceId.isEmpty() &&
                previousFaceId == runtimeAutoFaces()[i].id) {
                selectedIndex = i;
            } else if (applyStartupFace &&
                       ((!startupId.isEmpty() && startupId == runtimeAutoFaces()[i].id) ||
                        runtimeAutoFaces()[i].isStartupDefault)) {
                selectedIndex = i;
            }
        }
    }
    if (selectedIndex < 0) {
        selectedIndex = (!applyStartupFace && previousFaceIndex < runtimeAutoFaceCount())
                            ? previousFaceIndex
                            : (firstDefaultIndex >= 0 ? firstDefaultIndex : 0);
    }
    runtimeState().autoFaceIndex = static_cast<uint16_t>(selectedIndex);
    touchRuntimeState();
    Serial.printf("Loaded %u saved faces for firmware auto mode\n", runtimeAutoFaceCount());

    if (applyStartupFace) {
        String error;
        runtimeState().brightness = DEFAULT_BRIGHTNESS;
        runtimeState().playback   = DEFAULT_PLAYBACK;
        runtimeState().paused     = false;
        if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, STARTUP_FACE_REASON, error)) {
            Serial.printf("startup M370 failed: %s\n", error.c_str());
            return false;
        }
        Serial.printf("Loaded startup face index: %u\n", runtimeState().autoFaceIndex);
    }

    return true;
}
