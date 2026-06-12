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

bool validateScrollSourceText(const char* s, size_t len) {
    if (s == nullptr) return false;
    size_t i = 0;
    while (i < len) {
        const uint8_t b0 = static_cast<uint8_t>(s[i]);
        uint32_t cp = 0;
        size_t continuationBytes = 0;
        if (b0 < 0x80) {
            cp = b0;
        } else if ((b0 & 0xE0) == 0xC0) {
            cp = b0 & 0x1F;
            continuationBytes = 1;
        } else if ((b0 & 0xF0) == 0xE0) {
            cp = b0 & 0x0F;
            continuationBytes = 2;
        } else if ((b0 & 0xF8) == 0xF0) {
            cp = b0 & 0x07;
            continuationBytes = 3;
        } else {
            return false;  // 非法首字节（含孤立 continuation byte）
        }
        if (i + continuationBytes >= len) return false;  // 截断序列
        for (size_t k = 1; k <= continuationBytes; ++k) {
            const uint8_t bc = static_cast<uint8_t>(s[i + k]);
            if ((bc & 0xC0) != 0x80) return false;
            cp = (cp << 6) | static_cast<uint32_t>(bc & 0x3F);
        }
        // overlong 编码拒绝
        if (continuationBytes == 1 && cp < 0x80) return false;
        if (continuationBytes == 2 && cp < 0x800) return false;
        if (continuationBytes == 3 && cp < 0x10000) return false;
        if (cp > 0x10FFFF) return false;
        if (cp >= 0xD800 && cp <= 0xDFFF) return false;  // surrogate
        if (cp == 0) return false;                       // U+0000
        if (cp < 0x20 && cp != static_cast<uint32_t>('\n')) return false;  // C0 控制字符（保留换行）
        i += continuationBytes + 1;
    }
    return true;
}

bool validateMetaIdString(const char* s, size_t maxLen) {
    if (s == nullptr || s[0] == '\0') return false;
    for (size_t i = 0; s[i] != '\0'; ++i) {
        if (i >= maxLen) return false;  // 超长
        const char c = s[i];
        const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                        (c >= '0' && c <= '9') || c == '.' || c == '_' ||
                        c == ':' || c == '-';
        if (!ok) return false;
    }
    return true;
}
