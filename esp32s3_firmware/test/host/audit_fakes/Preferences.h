#pragma once
#include <Arduino.h>
#include <map>
struct Preferences {
    static std::map<std::string, String> values;
    static unsigned writes;
    static inline unsigned failedPuts = 0;
    bool begin(const char*, bool) { return true; }
    bool isKey(const char* key) { return values.count(key) != 0; }
    String getString(const char* key, const String& fallback) { return isKey(key) ? values[key] : fallback; }
    size_t putString(const char* key, const String& value) {
        if (failedPuts) { --failedPuts; return 0; }
        ++writes; values[key] = value; return value.length();
    }
    bool remove(const char* key) { ++writes; return values.erase(key) != 0; }
    bool clear() { ++writes; values.clear(); return true; }
};
