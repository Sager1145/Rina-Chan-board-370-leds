#pragma once
#include <Arduino.h>

int findJsonStringEnd(const String& body, size_t quotePos);
bool extractJsonStringAt(const String& body, size_t quotePos, String& value, int& endQuote);
bool jsonBoolField(const String& body, const char* key, bool defaultValue);
bool jsonUintField(const String& body, const char* key, uint32_t& value);
bool jsonFloatField(const String& body, const char* key, float& value);
bool jsonStringField(const String& body, const char* key, String& value);
