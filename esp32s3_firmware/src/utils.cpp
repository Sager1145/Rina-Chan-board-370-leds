#include "utils.h"

int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

size_t jsonCapacityFor(size_t sourceBytes) {
    const size_t estimated = sourceBytes * 2 + 4096;
    return estimated < 32768 ? 32768 : estimated;
}

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
