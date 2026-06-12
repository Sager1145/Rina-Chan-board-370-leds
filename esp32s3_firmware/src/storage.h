#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>


// 本文件挂载 LittleFS 并读写设置、保存表情和静态资源；注释保留必要 English identifier，便于和代码/API 对照。
// ---------------------------------------------------------------------------
// LittleFS 辅助函数（LittleFS helpers） 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------

bool mountFilesystem();

// ---------------------------------------------------------------------------
// 运行时设置（Runtime settings，mode、autoIntervalMs） 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------
bool loadRuntimeSettings();

bool saveRuntimeSettings();

bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error);

// ---------------------------------------------------------------------------
// 已保存表情文件（Saved faces file，原始 JSON 直通） 相关代码，维护 挂载 LittleFS 并读写设置、保存表情和静态资源。
// ---------------------------------------------------------------------------

bool loadSavedFaces(bool applyStartupFace);

bool validateSavedFaces(JsonVariant document, String& error);

size_t writeSavedFaces(JsonVariant document, String& error);

bool ensureSavedFacesLoaded();
