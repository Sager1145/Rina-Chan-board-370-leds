#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

bool mountFilesystem();

bool readStringFromFileLocked(const char* path, String& outContent);
bool writeStringToFileLocked(const char* path, const String& content);
// maxBytes == 0 means "no cap". When non-zero, a file larger than maxBytes is
// rejected BEFORE any buffer is allocated, so a corrupt/oversized file cannot
// trigger a huge allocation (or boot-loop) at load time.
bool readBufferFromFileLocked(const char* path, char*& outBuf, size_t& outSize, size_t maxBytes = 0);

bool loadRuntimeSettings();

bool saveRuntimeSettings();

bool writeJsonFileAtomic(const char* path, JsonVariant document, size_t& written, String& error);

bool loadSavedFaces(bool applyStartupFace);

bool validateSavedFaces(JsonVariant document, String& error);

size_t writeSavedFaces(JsonVariant document, String& error);

bool ensureSavedFacesLoaded();
