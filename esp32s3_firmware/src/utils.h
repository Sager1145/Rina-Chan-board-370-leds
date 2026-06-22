#pragma once
#include <Arduino.h>

int hexNibble(char c);

bool millisReached(uint32_t now, uint32_t dueMs);

bool millisElapsed(uint32_t now, uint32_t sinceMs, uint32_t intervalMs);

size_t jsonCapacityFor(size_t sourceBytes);

bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b);

String formatColorHex(uint8_t r, uint8_t g, uint8_t b);
