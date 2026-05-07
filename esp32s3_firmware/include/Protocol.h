#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "Config.h"

namespace rina {
namespace protocol {

enum class ParseResult : uint8_t {
    Ok,
    NullInput,
    BadLength,
    BadPrefix,
    BadHex,
};

enum class CommandType : uint8_t {
    M370Frame,
    RntStart,
    RntStop,
};

struct M370Frame {
    std::array<uint8_t, config::LED_FRAME_BYTES> rgb{};
};

struct Command {
    CommandType type = CommandType::M370Frame;
    M370Frame m370{};
    char rntPath[96]{};
    bool rntLoop = false;
    uint32_t receivedMs = 0;
    uint32_t remoteIp = 0;
    uint16_t remotePort = 0;
};

inline bool isAsciiLineEnd(uint8_t c) {
    return c == '\r' || c == '\n';
}

inline void trimTrailingLineEnd(const uint8_t*& data, size_t& len) {
    while (len > 0 && isAsciiLineEnd(data[len - 1U])) {
        --len;
    }
}

inline bool hasM370Prefix(const uint8_t* data, size_t len) {
    return data != nullptr &&
           len >= 5U &&
           data[0] == 'M' &&
           data[1] == '3' &&
           data[2] == '7' &&
           data[3] == '0' &&
           data[4] == ':';
}

inline int8_t hexNibble(uint8_t c) {
    if (c >= '0' && c <= '9') {
        return static_cast<int8_t>(c - '0');
    }
    if (c >= 'a' && c <= 'f') {
        return static_cast<int8_t>(c - 'a' + 10);
    }
    if (c >= 'A' && c <= 'F') {
        return static_cast<int8_t>(c - 'A' + 10);
    }
    return -1;
}

inline ParseResult parseM370Hex(const uint8_t* hex, size_t len, M370Frame& out) {
    if (hex == nullptr) {
        return ParseResult::NullInput;
    }
    if (len != config::M370_HEX_CHARS) {
        return ParseResult::BadLength;
    }
    for (size_t i = 0; i < config::M370_HEX_CHARS; ++i) {
        if (hexNibble(hex[i]) < 0) {
            return ParseResult::BadHex;
        }
    }

    out.rgb.fill(0);

    for (size_t led = 0; led < config::NUM_LEDS; ++led) {
        const size_t bitIndex = led;
        const size_t hexIndex = bitIndex >> 2U;
        const uint8_t bitMask = static_cast<uint8_t>(1U << (3U - (bitIndex & 0x03U)));
        const bool on = (static_cast<uint8_t>(hexNibble(hex[hexIndex])) & bitMask) != 0;

        if (on) {
            const size_t base = led * 3U;
            out.rgb[base] = config::M370_ON_R;
            out.rgb[base + 1U] = config::M370_ON_G;
            out.rgb[base + 2U] = config::M370_ON_B;
        }
    }

    return ParseResult::Ok;
}

inline ParseResult parseM370(const uint8_t* data, size_t len, M370Frame& out) {
    if (data == nullptr) {
        return ParseResult::NullInput;
    }

    trimTrailingLineEnd(data, len);

    if (len != config::M370_TEXT_CHARS) {
        return ParseResult::BadLength;
    }
    if (!hasM370Prefix(data, len)) {
        return ParseResult::BadPrefix;
    }

    return parseM370Hex(data + 5U, config::M370_HEX_CHARS, out);
}

inline const char* parseResultName(ParseResult result) {
    switch (result) {
        case ParseResult::Ok:
            return "ok";
        case ParseResult::NullInput:
            return "null";
        case ParseResult::BadLength:
            return "length";
        case ParseResult::BadPrefix:
            return "prefix";
        case ParseResult::BadHex:
            return "hex";
        default:
            return "unknown";
    }
}

}  // namespace protocol
}  // namespace rina
