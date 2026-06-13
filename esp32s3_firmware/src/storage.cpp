#include "storage.h"
#include "state.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "faces.h"
#include "sync.h"
#include "psram_json.h"
#include <algorithm>
#include <LittleFS.h>

bool mountFilesystem() {
    runtimeFsMounted() = LittleFS.begin(false, LITTLEFS_BASE_PATH, 10, LITTLEFS_PARTITION_LABEL);
    if (!runtimeFsMounted()) {
        Serial.println("LittleFS mount failed. Upload data with: pio run -t uploadfs");
    }
    return runtimeFsMounted();
}

static bool ensureResourcesDirectory() {
    if (!runtimeFsMounted()) return false;
    bool ok = false;
    withStorageLock([&]() {
        ok = LittleFS.exists("/resources") || LittleFS.mkdir("/resources");
    });
    return ok;
}

bool readStringFromFileLocked(const char* path, String& outContent) {
    bool exists = false;
    withStorageLock([&]() { exists = LittleFS.exists(path); });
    if (!exists) return false;

    File file;
    withStorageLock([&]() { file = LittleFS.open(path, "r"); });
    if (!file) return false;

    withStorageLock([&]() {
        outContent = file.readString();
        file.close();
    });
    return true;
}

bool writeStringToFileLocked(const char* path, const String& content) {
    const String tempPath = String(path) + ".tmp";
    File file;
    withStorageLock([&]() {
        LittleFS.remove(tempPath);
        file = LittleFS.open(tempPath, "w");
    });
    if (!file) return false;

    bool renamed = false;
    withStorageLock([&]() {
        size_t written = file.print(content);
        file.flush();
        file.close();
        renamed = (written > 0) && LittleFS.rename(tempPath, path);
        if (!renamed) LittleFS.remove(tempPath);
    });
    return renamed;
}

bool readBufferFromFileLocked(const char* path, char*& outBuf, size_t& outSize) {
    outBuf = nullptr;
    outSize = 0;
    bool exists = false;
    withStorageLock([&]() { exists = LittleFS.exists(path); });
    if (!exists) return false;

    File file;
    withStorageLock([&]() { file = LittleFS.open(path, "r"); });
    if (!file) return false;

    withStorageLock([&]() {
        outSize = file.size();
        outBuf = (char*)heap_caps_malloc(outSize + 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!outBuf) outBuf = (char*)malloc(outSize + 1);
        if (outBuf) {
            file.readBytes(outBuf, outSize);
            outBuf[outSize] = '\0';
        }
        file.close();
    });
    return outBuf != nullptr;
}

bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error) {
    written = 0;
    if (!runtimeFsMounted()) {
        error = "LittleFS is not mounted";
        return false;
    }

    String serialized;
    serializeJson(document, serialized);
    if (serialized.length() == 0 && !document.isNull()) {
        error = "failed to serialize JSON document";
        return false;
    }

    if (!writeStringToFileLocked(path, serialized)) {
        error = String("failed to write/commit file: ") + path;
        return false;
    }
    written = serialized.length();
    return true;
}

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

bool loadRuntimeSettings() {
    if (!runtimeFsMounted()) return false;
    String fileContent;
    if (!readStringFromFileLocked(SETTINGS_PATH, fileContent)) {
        Serial.println("runtime_settings.json not found or open failed; writing defaults");
        saveRuntimeSettings();
        return false;
    }

    DynamicJsonDocument doc(768);
    DeserializationError err = deserializeJson(doc, fileContent, DeserializationOption::NestingLimit(8));
    if (err) {
        Serial.printf("runtime_settings.json parse failed: %s\n", err.c_str());
        Serial.println("Rewriting runtime_settings.json with defaults");
        saveRuntimeSettings();
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

static bool defaultFaceIdNumberIsInvalid(const char* id) {
    if (id == nullptr || strncmp(id, "face_", 5) != 0) return false;
    const char* p = id + 5;
    if (*p < '0' || *p > '9') return false;
    uint32_t value = 0;
    uint8_t digits = 0;
    while (*p >= '0' && *p <= '9') {
        if (++digits > 9) return true;
        value = value * 10 + static_cast<uint32_t>(*p - '0');
        ++p;
    }
    return value < 1;
}

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

bool ensureSavedFacesLoaded() {
    if (runtimeAutoFaceCount() > 0) return true;
    return loadSavedFaces(false) && runtimeAutoFaceCount() > 0;
}

bool loadSavedFaces(bool applyStartupFace) {
    if (!runtimeFsMounted()) {
        Serial.println("LittleFS not mounted; saved faces cannot be loaded");
        return false;
    }
    size_t savedFacesSize = 0;
    char* contentBuf = nullptr;
    if (!readBufferFromFileLocked(SAVED_FACES_PATH, contentBuf, savedFacesSize)) {
        Serial.println("No saved_faces.json or failed to read; LED output starts blank");
        runtimeAutoFaceCount() = 0;
        touchRuntimeState();
        return false;
    }

    PsramJsonDocument doc(jsonCapacityFor(savedFacesSize));
    DeserializationError err = deserializeJson(doc, contentBuf, DeserializationOption::NestingLimit(32));
    free(contentBuf);
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
        const char* m370 = face["m370"] | "";
        String normalized, error;
        if (!normalizeM370(m370, normalized, error)) {
            Serial.printf("Skipping invalid saved face: %s\n", error.c_str());
            ++jsonIndex;
            continue;
        }

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

    std::sort(runtimeAutoFaces(), runtimeAutoFaces() + runtimeAutoFaceCount(),
              [](const RuntimeFace& a, const RuntimeFace& b) {
                  if (a.order != b.order) return a.order < b.order;
                  return a.jsonIndex < b.jsonIndex;
              });

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
        runtimeState().playback   = isAutoMode() ? "auto_saved_face" : DEFAULT_PLAYBACK;
        if (isAutoMode()) runtimeState().lastAutoSwitchMs = millis();
        runtimeState().paused     = false;
        if (!applyM370(runtimeAutoFaces()[runtimeState().autoFaceIndex].m370, STARTUP_FACE_REASON, error)) {
            Serial.printf("startup M370 failed: %s\n", error.c_str());
            return false;
        }
        Serial.printf("Loaded startup face index: %u\n", runtimeState().autoFaceIndex);
    }

    return true;
}

