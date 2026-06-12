#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>


// 本文件挂载 LittleFS 并读写设置、保存表情和静态资源；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// 说明 LittleFS 文件系统、静态资源或 gzip 打包流程。
// LittleFS 辅助函数（LittleFS helpers） 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------

/**
 * 挂载 mountFilesystem 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool mountFilesystem();

// ---------------------------------------------------------------------------
// 说明 LittleFS 存储和资源读写 中当前代码块的职责和维护约束。
// 运行时设置（Runtime settings，mode、autoIntervalMs） 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------
/**
 * 加载、设置 loadRuntimeSettings 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool loadRuntimeSettings();

/**
 * 保存、设置 saveRuntimeSettings 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool saveRuntimeSettings();

/**
 * 写入 writeJsonFileAtomic 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param path 调用方传入或接收的参数，含义以函数签名为准。
 * @param document 调用方传入或接收的参数，含义以函数签名为准。
 * @param written 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error);

// ---------------------------------------------------------------------------
// 说明 JSON 字段、资源格式或序列化流程。
// 已保存表情文件（Saved faces file，原始 JSON 直通） 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------

/**
 * 加载、保存 loadSavedFaces 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param applyStartupFace 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool loadSavedFaces(bool applyStartupFace);

/**
 * 保存 validateSavedFaces 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param document 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool validateSavedFaces(JsonVariant document, String& error);

/**
 * 写入、保存 writeSavedFaces 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param document 调用方传入或接收的参数，含义以函数签名为准。
 * @param error 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
size_t writeSavedFaces(JsonVariant document, String& error);

/**
 * 确保、保存、加载 ensureSavedFacesLoaded 相关逻辑，供 storage 模块使用。
 * @brief 说明 LittleFS 存储和资源读写 中当前函数或声明的用途。
 * @param None 调用方传入或接收的参数，含义以函数签名为准。
 * @return 返回操作结果、状态值、数据引用或空值。
 */
bool ensureSavedFacesLoaded();
