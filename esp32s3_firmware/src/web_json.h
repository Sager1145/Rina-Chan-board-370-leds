#pragma once
#include <Arduino.h>


// 本文件把运行时状态序列化成 Web API JSON 响应；注释保留必要 English identifier，便于和代码/API 对照。
int findJsonStringEnd(const String& body, size_t quotePos);

bool extractJsonStringAt(const String& body, size_t quotePos, String& value, int& endQuote);

bool jsonFieldValueOffset(const String& body, const char* key, size_t& offset);

bool jsonHasField(const String& body, const char* key);

bool jsonBoolField(const String& body, const char* key, bool defaultValue);

bool jsonUintField(const String& body, const char* key, uint32_t& value);

bool jsonFloatField(const String& body, const char* key, float& value);

bool jsonStringField(const String& body, const char* key, String& value);
