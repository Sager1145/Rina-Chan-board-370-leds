#pragma once
#include <Arduino.h>

/**
 * @brief Convert a hex character into its numeric nibble value.
 * @param c Character to parse.
 * @return 0-15 for valid hex, or -1 for invalid input.
 */
int hexNibble(char c);

/**
 * @brief Estimate ArduinoJson capacity for a source JSON document.
 * @param sourceBytes Source file/body size.
 * @return Conservative capacity with a 32 KB floor.
 */
size_t jsonCapacityFor(size_t sourceBytes);

/**
 * @brief Parse #RRGGBB/RRGGBB text into RGB bytes.
 * @param input Raw color string.
 * @param r Receives red channel.
 * @param g Receives green channel.
 * @param b Receives blue channel.
 * @return true when input was valid six-digit hex.
 */
bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b);

/**
 * @brief Format RGB bytes as lowercase #rrggbb.
 * @param r Red channel.
 * @param g Green channel.
 * @param b Blue channel.
 * @return Canonical color string.
 */
String formatColorHex(uint8_t r, uint8_t g, uint8_t b);
