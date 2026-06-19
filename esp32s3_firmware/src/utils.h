#pragma once
#include <Arduino.h>

int hexNibble(char c);

bool millisReached(uint32_t now, uint32_t dueMs);

bool millisElapsed(uint32_t now, uint32_t sinceMs, uint32_t intervalMs);

size_t jsonCapacityFor(size_t sourceBytes);

bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b);

String formatColorHex(uint8_t r, uint8_t g, uint8_t b);

// Scroll source-text validation: rejects invalid UTF-8, overlong encodings, surrogates, > U+10FFFF,
// U+0000, and C0 control characters except '\n'.
bool validateScrollSourceText(const char* s, size_t len);

// timelineId / fontId / generatorVersion validation: non-empty, allowed safe ASCII
// [A-Za-z0-9._:-] only, length not exceeding maxLen.
bool validateMetaIdString(const char* s, size_t maxLen);
