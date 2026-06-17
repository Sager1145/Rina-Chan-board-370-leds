#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

bool mountFilesystem();

bool readStringFromFileLocked(const char* path, String& outContent);
bool writeStringToFileLocked(const char* path, const String& content);
bool readBufferFromFileLocked(const char* path, char*& outBuf, size_t& outSize);

bool loadRuntimeSettings();

bool saveRuntimeSettings();

bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error);

bool loadSavedFaces(bool applyStartupFace);

bool validateSavedFaces(JsonVariant document, String& error);

size_t writeSavedFaces(JsonVariant document, String& error);

bool ensureSavedFacesLoaded();
