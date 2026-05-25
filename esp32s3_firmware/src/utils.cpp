#include "utils.h"

/**
 * @brief Convert a hex character into its numeric nibble value.
 * @param c Character to parse.
 * @return 0-15 for valid hex, or -1 for invalid input.
 */
int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/**
 * @brief Estimate ArduinoJson capacity for a source JSON document.
 * @param sourceBytes Source file/body size.
 * @return Conservative capacity with a 32 KB floor.
 */
size_t jsonCapacityFor(size_t sourceBytes) {
    const size_t estimated = sourceBytes * 2 + 4096;
    return estimated < 32768 ? 32768 : estimated;
}

/**
 * @brief Parse #RRGGBB/RRGGBB text into RGB bytes.
 * @param input Raw color string.
 * @param r Receives red channel.
 * @param g Receives green channel.
 * @param b Receives blue channel.
 * @return true when input was valid six-digit hex.
 */
bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b) {
    String value = input;
    value.trim();
    if (value.startsWith("#")) value = value.substring(1);
    if (value.length() != 6) return false;
    for (size_t i = 0; i < 6; ++i) {
        if (hexNibble(value.charAt(i)) < 0) return false;
    }
    value.toLowerCase();
    r = static_cast<uint8_t>(strtoul(value.substring(0, 2).c_str(), nullptr, 16));
    g = static_cast<uint8_t>(strtoul(value.substring(2, 4).c_str(), nullptr, 16));
    b = static_cast<uint8_t>(strtoul(value.substring(4, 6).c_str(), nullptr, 16));
    return true;
}

/**
 * @brief Format RGB bytes as lowercase #rrggbb.
 * @param r Red channel.
 * @param g Green channel.
 * @param b Blue channel.
 * @return Canonical color string.
 */
String formatColorHex(uint8_t r, uint8_t g, uint8_t b) {
    char buf[8];
    snprintf(buf, sizeof(buf), "#%02x%02x%02x", r, g, b);
    return String(buf);
}
