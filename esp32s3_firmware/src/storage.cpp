#include "storage.h"
#include "state.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "faces.h"
#include "sync.h"
#include "psram_json.h"
#include "expression_parts.h"
#include <algorithm>
#include <new>
#include <utility>
#include <LittleFS.h>

bool mountFilesystem() {
    runtimeFsMounted() = LittleFS.begin(false, LITTLEFS_BASE_PATH, 10, LITTLEFS_PARTITION_LABEL);
    if (!runtimeFsMounted())
        Serial.println("LittleFS mount failed. Upload data with: pio run -t uploadfs");
    return runtimeFsMounted();
}

static bool ensureResourcesDirectory() {
    if (!runtimeFsMounted())
        return false;
    bool ok = false;
    withStorageLock([&]() { ok = LittleFS.exists("/resources") || LittleFS.mkdir("/resources"); });
    return ok;
}

namespace {
constexpr size_t STORAGE_IO_CHUNK_BYTES = 2048;

// Filesystem consumers run serially in setup/Core 0's dispatcher. Retain the
// handle across chunks, but release Storage (and its HardwareBus lock) so the
// renderer can transmit between flash payload operations. Every filesystem
// operation, including the final flush/rename, still owns both locks.
bool writeBytesToFileAtomic(const char* path, const uint8_t* bytes, size_t size) {
    const String tempPath = String(path) + ".tmp";
    File file;
    withStorageLock([&]() {
        LittleFS.remove(tempPath);
        file = LittleFS.open(tempPath, "w");
    });
    if (!file) return false;
    size_t accepted = 0;
    while (accepted < size) {
        const size_t chunk = std::min(STORAGE_IO_CHUNK_BYTES, size - accepted);
        size_t written = 0;
        withStorageLock([&]() { written = file.write(bytes + accepted, chunk); });
        accepted += written;
        if (written != chunk) break;
        if (accepted < size) delay(1);
    }
    bool committed = false;
    withStorageLock([&]() {
        file.flush();
        file.close();
        committed = accepted == size && LittleFS.rename(tempPath, path);
        if (!committed) LittleFS.remove(tempPath);
    });
    return committed;
}
} // namespace

bool readStringFromFileLocked(const char* path, String& outContent) {
    bool ok = false;
    withStorageLock([&]() {
        if (!LittleFS.exists(path))
            return;
        File file = LittleFS.open(path, "r");
        if (!file)
            return;
        outContent = file.readString();
        file.close();
        ok = true;
    });
    return ok;
}

bool writeStringToFileLocked(const char* path, const String& content) {
    return writeBytesToFileAtomic(path, reinterpret_cast<const uint8_t*>(content.c_str()), content.length());
}

namespace {
constexpr uint32_t RUNTIME_SETTINGS_SAVE_DEBOUNCE_MS = 1000;
bool g_runtimeSettingsSavePending = false;
uint32_t g_runtimeSettingsSaveDueMs = 0;
}

void scheduleRuntimeSettingsSave() {
    g_runtimeSettingsSavePending = true;
    g_runtimeSettingsSaveDueMs = millis() + RUNTIME_SETTINGS_SAVE_DEBOUNCE_MS;
}

void serviceRuntimeSettingsSave() {
    if (!g_runtimeSettingsSavePending ||
        !millisReached(millis(), g_runtimeSettingsSaveDueMs))
        return;
    // Clear before writing so a failed filesystem does not cause a tight loop.
    // The setting remains live; a later user change schedules another attempt.
    g_runtimeSettingsSavePending = false;
    saveRuntimeSettings();
}

bool readBufferFromFileLocked(const char* path, char*& outBuf, size_t& outSize) {
    outBuf = nullptr;
    outSize = 0;
    File file;
    withStorageLock([&]() {
        file = LittleFS.open(path, "r");
        if (file) outSize = file.size();
    });
    if (!file) return false;
    // Memory allocation does not need to keep the hardware bus unavailable.
    SpiRamAllocator allocator;
    outBuf = static_cast<char*>(allocator.allocate(outSize + 1));
    size_t got = 0;
    if (outBuf) {
        while (got < outSize) {
            const size_t chunk = std::min(STORAGE_IO_CHUNK_BYTES, outSize - got);
            size_t read = 0;
            withStorageLock([&]() { read = file.readBytes(outBuf + got, chunk); });
            got += read;
            if (read != chunk) break;
            if (got < outSize) delay(1);
        }
    }
    withStorageLock([&]() { file.close(); });
    if (!outBuf || got != outSize) {
        allocator.deallocate(outBuf);
        outBuf = nullptr;
        outSize = 0;
        return false;
    }
    outBuf[outSize] = '\0';
    return true;
}

bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error) {
    written = 0;
    if (!runtimeFsMounted()) {
        error = "LittleFS is not mounted";
        return false;
    }
    const size_t expected = measureJson(document);
    SpiRamAllocator allocator;
    char* serialized = static_cast<char*>(allocator.allocate(expected + 1));
    if (!serialized) {
        error = "failed to allocate JSON serialization buffer";
        return false;
    }
    const size_t serializedBytes = serializeJson(document, serialized, expected + 1);
    if (serializedBytes != expected) {
        allocator.deallocate(serialized);
        error = "failed to serialize JSON document";
        return false;
    }
    const bool committed = writeBytesToFileAtomic(path, reinterpret_cast<const uint8_t*>(serialized), expected);
    allocator.deallocate(serialized);
    if (!committed) {
        error = String("failed to write/commit file: ") + path;
        return false;
    }
    written = expected;
    return true;
}

bool saveRuntimeSettings() {
    if (!runtimeFsMounted())
        return false;
    if (!ensureResourcesDirectory()) {
        Serial.println("Failed to ensure /resources for runtime settings");
        return false;
    }
    DynamicJsonDocument doc(512);
    doc["format"] = "rina_runtime_settings_v1";
    doc["version"] = 1;
    doc["mode"] = runtimeState().mode;
    doc["autoIntervalMs"] = runtimeState().autoIntervalMs;
    doc["deviceName"] = runtimeState().deviceName;
    doc["updatedAtMs"] = millis();
    size_t written = 0;
    String error;
    if (!writeJsonFileAtomic(SETTINGS_PATH, doc.as<JsonVariant>(), written, error)) {
        Serial.printf("Failed to write runtime_settings.json: %s\n", error.c_str());
        return false;
    }
    ++runtimeState().settingsWrites;
    g_runtimeSettingsSavePending = false;
    touchRuntimeState();
    return true;
}

bool loadRuntimeSettings() {
    if (!runtimeFsMounted())
        return false;
    String fileContent;
    if (!readStringFromFileLocked(SETTINGS_PATH, fileContent)) {
        Serial.println("runtime_settings.json not found or open failed; writing defaults");
        saveRuntimeSettings();
        return false;
    }
    DynamicJsonDocument doc(1024);
    DeserializationError err = deserializeJson(doc, fileContent, DeserializationOption::NestingLimit(8));
    if (err) {
        Serial.printf("runtime_settings.json parse failed: %s\n", err.c_str());
        Serial.println("Rewriting runtime_settings.json with defaults");
        saveRuntimeSettings();
        return false;
    }
    const char* mode = doc["mode"] | DEFAULT_MODE;
    if (!setMode(mode, false))
        setMode(DEFAULT_MODE, false);
    if (doc["autoIntervalMs"].is<uint32_t>())
        setAutoInterval(doc["autoIntervalMs"].as<uint32_t>(), false);
    // Empty/absent means "fall back to the MAC-derived default" — no validation
    // needed here beyond the length cap the setter already enforced on write.
    runtimeState().deviceName = doc["deviceName"] | "";
    if (runtimeState().deviceName.length() > MAX_DEVICE_NAME_BYTES)
        runtimeState().deviceName = "";
    Serial.printf("Runtime settings loaded: mode=%s autoIntervalMs=%lu deviceName=%s\n",
                  runtimeState().mode.c_str(),
                  static_cast<unsigned long>(runtimeState().autoIntervalMs),
                  runtimeState().deviceName.length() ? runtimeState().deviceName.c_str() : "<default>");
    return true;
}

static bool defaultFaceIdNumberIsInvalid(const char* id) {
    if (id == nullptr || strncmp(id, "face_", 5) != 0)
        return false;
    const char* p = id + 5;
    if (*p < '0' || *p > '9')
        return false;
    uint32_t value = 0;
    uint8_t digits = 0;
    while (*p >= '0' && *p <= '9') {
        if (++digits > 9)
            return true;
        value = value * 10 + static_cast<uint32_t>(*p - '0');
        ++p;
    }
    return value < 1;
}

static bool readPackedFrameBytes(JsonObject face, uint8_t* out, String& error) {
    if (!out) {
        error = "frame output buffer is null";
        return false;
    }
    JsonArray bytes = face["frameBytes"].as<JsonArray>();
    if (bytes.isNull()) {
        error = "face.frameBytes must be an array";
        return false;
    }
    if (bytes.size() != FRAME_BYTES) {
        error = String("face.frameBytes must contain ") + FRAME_BYTES + " bytes";
        return false;
    }
    uint16_t i = 0;
    for (JsonVariant value : bytes) {
        if (!value.is<uint8_t>()) {
            error = "face.frameBytes entries must be 0..255";
            return false;
        }
        out[i++] = value.as<uint8_t>();
    }
    return validatePackedFrame(out, error);
}

static bool composeSavedFaceParts(JsonObject face, uint8_t* out, bool allowUnversioned, String& error) {
    static_assert(FRAME_BYTES == expression_parts::FRAME_SIZE, "parts catalog frame size mismatch");
    const bool unversioned = face["partsCatalog"].isNull() && face["partsVersion"].isNull();
    if (!(allowUnversioned && unversioned) &&
        (strcmp(face["partsCatalog"] | "", expression_parts::CATALOG) != 0 ||
         !face["partsVersion"].is<uint16_t>() ||
         face["partsVersion"].as<uint16_t>() != expression_parts::VERSION)) {
        error = "unsupported parts catalog/version";
        return false;
    }
    JsonObject call = face["call"].as<JsonObject>();
    const char* fields[4] = {"leye", "reye", "mouth", "cheek"};
    uint16_t ids[4];
    for (uint8_t i = 0; i < 4; ++i) {
        JsonVariant value = call[fields[i]];
        if (value.is<const char*>()) {
            if (!expression_parts::parseId(value.as<const char*>(), ids[i])) {
                error = String("invalid part ID: ") + fields[i];
                return false;
            }
        } else if (value.is<uint16_t>()) {
            ids[i] = value.as<uint16_t>();
        } else {
            error = String("missing or invalid part ID: ") + fields[i];
            return false;
        }
    }
    if (!expression_parts::compose(ids, out)) {
        error = "unknown part ID or incorrect part group";
        return false;
    }
    return true;
}

bool materializeSavedFace(JsonObject face, uint8_t* out, String& error) {
    if (!out) {
        error = "frame output buffer is null";
        return false;
    }
    const char* type = face["type"] | "";
    if (strcmp(type, "parts") == 0 && face["frameBytes"].isNull())
        return composeSavedFaceParts(face, out, false, error);
    if (strcmp(type, "parts") != 0 && strcmp(type, "custom") != 0 && strcmp(type, "default") != 0) {
        error = "face.type must be default, custom, or parts";
        return false;
    }
    // Old full-frame parts documents may carry stale/unknown metadata. Never
    // change their visible pixels based solely on that metadata.
    return readPackedFrameBytes(face, out, error);
}

bool canonicalizeSavedFaces(JsonVariant document, String& error) {
    if (!validateSavedFaces(document, error)) return false;
    for (JsonObject face : document["faces"].as<JsonArray>()) {
        if (strcmp(face["type"] | "", "parts") != 0) continue;
        if (face["frameBytes"].isNull()) continue;
        uint8_t bitmap[FRAME_BYTES], parts[FRAME_BYTES];
        String partsError;
        if (!readPackedFrameBytes(face, bitmap, error)) return false;
        if (composeSavedFaceParts(face, parts, true, partsError) && memcmp(parts, bitmap, FRAME_BYTES) == 0) {
            // Allocate any missing metadata before removing the authoritative
            // bitmap so JSON pool exhaustion also leaves an intact record.
            if (!face["partsCatalog"].set(expression_parts::CATALOG) ||
                !face["partsVersion"].set(expression_parts::VERSION)) {
                error = "insufficient JSON capacity for parts metadata";
                return false;
            }
            face.remove("frameBytes");
        } else {
            face["type"] = "custom";
            face.remove("call");
            face.remove("partsCatalog");
            face.remove("partsVersion");
        }
    }
    return validateSavedFaces(document, error);
}

bool expandSavedFacesDocument(JsonVariant document, String& error) {
    if (!validateSavedFaces(document, error)) return false;
    for (JsonObject face : document["faces"].as<JsonArray>()) {
        if (!face["frameBytes"].isNull()) continue;
        uint8_t frame[FRAME_BYTES];
        if (!materializeSavedFace(face, frame, error)) return false;
        JsonArray bytes = face.createNestedArray("frameBytes");
        if (bytes.isNull()) {
            error = "insufficient JSON capacity for expanded frameBytes";
            return false;
        }
        for (uint8_t byte : frame) {
            if (!bytes.add(byte)) {
                error = "insufficient JSON capacity for expanded frameBytes";
                return false;
            }
        }
    }
    return true;
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
    if (faces.size() > MAX_AUTO_FACES) {
        error = String("too many faces; firmware max is ") + MAX_AUTO_FACES;
        return false;
    }

    uint16_t defaultCount = 0;
    const char* seenIds[MAX_AUTO_FACES] = {};
    uint16_t seenCount = 0;
    uint8_t frame[FRAME_BYTES];
    size_t expandedBytes = measureJson(document);
    for (JsonObject face : faces) {
        const char* type = face["type"] | "";
        const char* id = face["id"] | "";
        if (id[0] == '\0') {
            error = "face id must be non-empty";
            return false;
        }
        for (uint16_t i = 0; i < seenCount; ++i) {
            if (strcmp(seenIds[i], id) == 0) {
                error = "face ids must be unique";
                return false;
            }
        }
        seenIds[seenCount++] = id;
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
        if (!materializeSavedFace(face, frame, error)) {
            error = String("invalid face packed frame: ") + error;
            return false;
        }
        if (face["frameBytes"].isNull()) {
            // A comma plus "frameBytes":[...]. Budget the actual decimal
            // projection as well as canonical disk bytes before any commit.
            expandedBytes += strlen(",\"frameBytes\":[]") + FRAME_BYTES - 1;
            for (uint8_t byte : frame)
                expandedBytes += byte >= 100 ? 3 : (byte >= 10 ? 2 : 1);
        }
    }
    if (defaultCount == 0) {
        error = "saved_faces.json must keep at least one type:\"default\" face";
        return false;
    }
    if (expandedBytes > MAX_FACES_DOCUMENT_BYTES) {
        error = "expanded saved_faces.json exceeds firmware size limit";
        return false;
    }
    return true;
}

// Incremented on every successful saved_faces.json write (item 12); GET_FACES
// clients can pass back the gen they last saw and get a 409 if it has since
// changed underneath a multi-chunk download.
static uint32_t g_savedFacesGeneration = 0;

uint32_t savedFacesGeneration() { return g_savedFacesGeneration; }

namespace {
// Only Core 0 publishes this table. Core 1 renders the separately queued packed
// frame, so exchanging these owning strings requires no cross-core allocation.
class PreparedSavedFaces {
public:
    ~PreparedSavedFaces() {
        for (uint16_t i = 0; i < capacity_; ++i) faces_[i].~RuntimeFace();
        allocator_.deallocate(faces_);
    }

    bool prepare(JsonVariant document, bool skipInvalid, String& error) {
        JsonArray source = document["faces"].as<JsonArray>();
        if (source.isNull() || source.size() > MAX_AUTO_FACES) {
            error = "missing faces array or too many faces";
            return false;
        }
        capacity_ = static_cast<uint16_t>(source.size());
        if (!capacity_) {
            error = "no usable saved faces";
            return false;
        }
        faces_ = static_cast<RuntimeFace*>(allocator_.allocate(sizeof(RuntimeFace) * capacity_));
        if (!faces_) {
            capacity_ = 0;
            error = "failed to allocate prepared saved-face table";
            return false;
        }
        for (uint16_t i = 0; i < capacity_; ++i) new (&faces_[i]) RuntimeFace();
        const char* startupId = document["startupDefaultId"] | "";
        uint16_t jsonIndex = 0;
        for (JsonVariant entry : source) {
            JsonObject face = entry.as<JsonObject>();
            uint8_t packed[FRAME_BYTES];
            String faceError;
            const char* id = face["id"] | "";
            bool duplicate = false;
            for (uint16_t i = 0; i < count_; ++i) duplicate |= faces_[i].id == id;
            const bool metadataValid = id[0] && !duplicate && face["order"].is<int32_t>() &&
                face["order"].as<int32_t>() >= 1 &&
                !(strcmp(face["type"] | "", "default") == 0 && defaultFaceIdNumberIsInvalid(id));
            if (!metadataValid || !materializeSavedFace(face, packed, faceError)) {
                if (faceError.isEmpty()) faceError = "invalid face identity/order";
                if (!skipInvalid) { error = faceError; return false; }
                Serial.printf("Skipping invalid saved face %u: %s\n", jsonIndex, faceError.c_str());
                ++jsonIndex;
                continue;
            }
            RuntimeFace& runtime = faces_[count_];
            const char* name = face["name"] | id;
            runtime.id = id;
            runtime.name = name;
            // Arduino String reports allocation failure by yielding an empty
            // or unchanged string. Detect that while the old table is intact.
            if (runtime.id.length() != strlen(id) || runtime.name.length() != strlen(name)) {
                error = "failed to allocate saved-face identity strings";
                return false;
            }
            memcpy(runtime.frameBits, packed, FRAME_BYTES);
            runtime.order = face["order"].as<int32_t>();
            runtime.jsonIndex = jsonIndex++;
            runtime.isDefault = strcmp(face["type"] | "", "default") == 0;
            runtime.isStartupDefault = face["is_startup_default"].as<bool>() ||
                (startupId[0] && strcmp(startupId, id) == 0);
            ++count_;
        }
        if (!count_) {
            error = "no usable saved faces";
            return false;
        }
        std::sort(faces_, faces_ + count_, [](const RuntimeFace& a, const RuntimeFace& b) {
            if (a.order != b.order) return a.order < b.order;
            return a.jsonIndex < b.jsonIndex;
        });
        return true;
    }

    void publish(JsonVariant document, bool applyStartupFace) {
        const char* startupId = document["startupDefaultId"] | "";
        const uint16_t previousIndex = runtimeState().autoFaceIndex;
        const String* previousId = previousIndex < runtimeAutoFaceCount()
            ? &runtimeAutoFaces()[previousIndex].id : nullptr;
        int selectedIndex = -1;
        int firstDefault = -1;
        for (uint16_t i = 0; i < count_; ++i) {
            if (faces_[i].isDefault && firstDefault < 0) firstDefault = i;
            if (selectedIndex < 0 &&
                ((!applyStartupFace && previousId && *previousId == faces_[i].id) ||
                 (applyStartupFace && ((startupId[0] && faces_[i].id == startupId) || faces_[i].isStartupDefault))))
                selectedIndex = i;
        }
        if (selectedIndex < 0)
            selectedIndex = !applyStartupFace && previousIndex < count_ ? previousIndex :
                (firstDefault >= 0 ? firstDefault : 0);
        // String moves exchange owned buffers; every potentially failing
        // allocation happened before the filesystem rename.
        for (uint16_t i = 0; i < count_; ++i) std::swap(runtimeAutoFaces()[i], faces_[i]);
        for (uint16_t i = count_; i < runtimeAutoFaceCount(); ++i) runtimeAutoFaces()[i] = RuntimeFace();
        runtimeAutoFaceCount() = count_;
        runtimeState().autoFaceIndex = static_cast<uint16_t>(selectedIndex);
        touchRuntimeState();
    }

private:
    SpiRamAllocator allocator_;
    RuntimeFace* faces_ = nullptr;
    uint16_t capacity_ = 0;
    uint16_t count_ = 0;
};
} // namespace

size_t writeSavedFaces(JsonVariant document, String& error) {
    if (!runtimeFsMounted()) {
        error = "LittleFS is not mounted";
        return 0;
    }
    if (!canonicalizeSavedFaces(document, error)) return 0;
    PreparedSavedFaces prepared;
    if (!prepared.prepare(document, false, error)) return 0;
    if (!ensureResourcesDirectory()) {
        error = "failed to ensure /resources for saved_faces.json";
        return 0;
    }
    if (measureJson(document) > MAX_FACES_DOCUMENT_BYTES) {
        error = "saved_faces.json exceeds firmware size limit";
        return 0;
    }
    size_t written = 0;
    if (!writeJsonFileAtomic(SAVED_FACES_PATH, document, written, error)) return 0;
    prepared.publish(document, false);
    ++runtimeState().savedFacesWrites;
    ++g_savedFacesGeneration;
    touchRuntimeState();
    return written;
}

bool ensureSavedFacesLoaded() {
    if (runtimeAutoFaceCount() > 0) return true;
    return loadSavedFaces(false) && runtimeAutoFaceCount() > 0;
}

bool installSavedFacesDocument(JsonVariant document, bool applyStartupFace) {
    PreparedSavedFaces prepared;
    String error;
    if (!prepared.prepare(document, true, error)) {
        Serial.printf("Failed to prepare saved faces: %s\n", error.c_str());
        return false;
    }
    prepared.publish(document, applyStartupFace);
    Serial.printf("Loaded %u saved faces for firmware auto mode\n", runtimeAutoFaceCount());
    if (applyStartupFace) {
        runtimeState().brightness = DEFAULT_BRIGHTNESS;
        runtimeState().playback = isAutoMode() ? "auto_saved_face" : DEFAULT_PLAYBACK;
        if (isAutoMode()) runtimeState().lastAutoSwitchMs = millis();
        runtimeState().paused = false;
        if (!applyPackedFrameQueued(runtimeAutoFaces()[runtimeState().autoFaceIndex].frameBits, STARTUP_FACE_REASON, error)) {
            Serial.printf("startup packed frame failed: %s\n", error.c_str());
            return false;
        }
    }
    return true;
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
        return false;
    }

    PsramJsonDocument doc(savedFacesJsonCapacityFor(savedFacesSize));
    // Deserialize from a const pointer so ArduinoJson COPIES strings into the
    // document; a non-const char* selects zero-copy mode and the free() below
    // would leave every string in `doc` dangling.
    DeserializationError err = deserializeJson(doc, static_cast<const char*>(contentBuf), DeserializationOption::NestingLimit(32));
    free(contentBuf);
    if (err) {
        Serial.printf("saved_faces.json parse failed: %s\n", err.c_str());
        return false;
    }

    return installSavedFacesDocument(doc.as<JsonVariant>(), applyStartupFace);
}
