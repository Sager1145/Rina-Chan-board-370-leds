#include "storage.h"
#include "state.h"
#include "config.h"
#include "utils.h"
#include "led_renderer.h"
#include "faces.h"
#include "sync.h"
#include "psram_json.h"
#include <LittleFS.h>


// 本文件挂载 LittleFS 并读写设置、保存表情和静态资源；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 说明 LittleFS 文件系统、静态资源或 gzip 打包流程。
// 文件系统挂载（Filesystem mount） 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------

/**
 * 挂载 mountFilesystem 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool mountFilesystem() {
    runtimeFsMounted() = LittleFS.begin(false, LITTLEFS_BASE_PATH, 10, LITTLEFS_PARTITION_LABEL);
    if (!runtimeFsMounted()) {
        Serial.println("LittleFS mount failed. Upload data with: pio run -t uploadfs");
    }
    return runtimeFsMounted();
}

/**
 * 确保 ensureResourcesDirectory 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 写入 writeJsonFileAtomic 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param path 调用方传入或接收的参数，含义以函数签名为准。
 * @param document 调用方传入或接收的参数，含义以函数签名为准。
 * @param written 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
        // 处理 LED 矩阵、灯带刷新或硬件时序约束。
        // 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
        LittleFS.remove(tempPath);
        file = LittleFS.open(tempPath, "w");
    });

    if (!file) {
        error = String("failed to open temp file for write: ") + tempPath;
        return false;
    }

    bool renamed = false;
    withHardwareBusLock([&]() {
        // 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
        // 处理 LED 矩阵、灯带刷新或硬件时序约束。
        // 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
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
// 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
// 运行时设置（Runtime settings） 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------

/**
 * 保存、设置 saveRuntimeSettings 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 加载、设置 loadRuntimeSettings 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
// 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
// 已保存表情（Saved faces）—— 校验 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------

/**
 * 围绕 defaultFaceIdNumberIsInvalid 处理本模块的核心流程，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param id 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
 * 保存 validateSavedFaces 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param document 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
        // 处理 M370 帧、队列、校验或状态同步。
        // 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
        // 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
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
// 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
// 已保存表情（Saved faces）—— 写入 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------

/**
 * 写入、保存 writeSavedFaces 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param document 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
// 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
// 已保存表情（Saved faces）—— 载入到 runtimeAutoFaces()[] 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------

/**
 * 确保、保存、加载 ensureSavedFacesLoaded 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool ensureSavedFacesLoaded() {
    if (runtimeAutoFaceCount() > 0) return true;
    return loadSavedFaces(false) && runtimeAutoFaceCount() > 0;
}

/**
 * 加载、保存 loadSavedFaces 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param applyStartupFace 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
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
        // 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
        // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
        // 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
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

    // 说明 WebUI、HTTP/API 或浏览器状态的连接关系。
    // 说明 GPIO 按钮、组合键或本地 overlay 反馈。
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

    // 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
    // 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
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
