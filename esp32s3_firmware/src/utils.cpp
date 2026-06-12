#include "utils.h"


// 本文件提供小型字符串、数值和颜色辅助函数；注释保留必要 English identifier，便于和代码/API 对照。
int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
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

bool parseColorHex(const String& input, uint8_t& r, uint8_t& g, uint8_t& b) {
    String value = input;
    value.trim();

    const size_t offset = (value.length() > 0 && value.charAt(0) == '#') ? 1 : 0;
    if (value.length() - offset != 6) return false;

    int nibbles[6];
    for (size_t i = 0; i < 6; ++i) {
        nibbles[i] = hexNibble(value.charAt(offset + i));
        if (nibbles[i] < 0) return false;
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
