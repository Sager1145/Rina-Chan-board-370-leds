#pragma once
#include <Arduino.h>

// Returns the numeric value of a single hex character, or -1 if invalid.
int hexNibble(char c);

// JSON document capacity heuristic: allocates at least 32 KB or 2× source size.
size_t jsonCapacityFor(size_t sourceBytes);

// Parse and validate a 6-digit hex color string ("#RRGGBB" or "RRGGBB").
// On success writes r/g/b components and returns true.
bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b);
