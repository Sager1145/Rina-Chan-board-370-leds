#include "utils.h"
#include "config.h"
#include <ArduinoJson.h>

int hexNibble(char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

bool millisReached(uint32_t now, uint32_t dueMs) {
    return static_cast<int32_t>(now - dueMs) >= 0;
}

bool millisElapsed(uint32_t now, uint32_t sinceMs, uint32_t intervalMs) {
    return now - sinceMs >= intervalMs;
}

size_t jsonCapacityFor(size_t sourceBytes) {
    const size_t estimated = sourceBytes * 2 + 4096;
    return estimated < 32768 ? 32768 : estimated;
}

size_t savedFacesJsonCapacityFor(size_t sourceBytes) {
    // Capacity follows the supported schema instead of compressed input bytes:
    // a frame full of one-digit values is small on wire but still consumes 47
    // VariantSlots. JSON_*_SIZE uses the target's real slot size, so this also
    // stays correct in 64-bit host tests.
    constexpr size_t rootMembers = 8;
    constexpr size_t faceMembers = 14;
    const size_t schemaSlots = JSON_OBJECT_SIZE(rootMembers) +
        JSON_ARRAY_SIZE(MAX_AUTO_FACES) +
        static_cast<size_t>(MAX_AUTO_FACES) *
            (JSON_OBJECT_SIZE(faceMembers) + JSON_ARRAY_SIZE(FRAME_BYTES));
    // In copy mode all unique strings together cannot exceed sourceBytes.
    return schemaSlots + sourceBytes + 8192;
}

bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b) {
    String value = input;
    value.trim();

    const size_t offset = (value.length() > 0 && value.charAt(0) == '#') ? 1 : 0;
    if (value.length() - offset != 6)
        return false;

    int nibbles[6];
    for (size_t i = 0; i < 6; ++i) {
        nibbles[i] = hexNibble(value.charAt(offset + i));
        if (nibbles[i] < 0)
            return false;
    }

    r = static_cast<uint8_t>((nibbles[0] << 4) | nibbles[1]);
    g = static_cast<uint8_t>((nibbles[2] << 4) | nibbles[3]);
    b = static_cast<uint8_t>((nibbles[4] << 4) | nibbles[5]);
    return true;
}

String formatColorHex(uint8_t r, uint8_t g, uint8_t b) {
    char buf[8];
    snprintf(buf, sizeof(buf), "#%02x%02x%02x", r, g, b);
    return String(buf);
}
