#pragma once
#include <cstdint>

// Pure wire policy shared by host regressions and the hardware adapter.
namespace ap_address {
struct IPv4 {
    uint8_t octets[4];
    uint32_t networkOrderValue() const {
        return (uint32_t(octets[0]) << 24) | (uint32_t(octets[1]) << 16) |
               (uint32_t(octets[2]) << 8) | octets[3];
    }
};

inline IPv4 factoryAddress(uint32_t suffix) {
    suffix &= 0xFFFFFF;
    const uint8_t host = suffix & 0xFF;
    if (host > 0 && host < 255)
        return {{10, uint8_t(suffix >> 16), uint8_t(suffix >> 8), host}};
    const uint32_t index = (suffix >> 8) * 2 + (host == 255 ? 1 : 0);
    const uint32_t subnet = index / 254;
    return {{172, uint8_t(16 + subnet / 256), uint8_t(subnet % 256),
             uint8_t(index % 254 + 1)}};
}

inline IPv4 factoryAddressForBoardId(const char* id) {
    uint32_t suffix = 0;
    // boardId() supplies exactly twelve hexadecimal MAC digits.
    for (unsigned i = 6; i < 12; ++i) {
        const char ch = id[i];
        const unsigned digit = ch >= '0' && ch <= '9' ? unsigned(ch - '0') :
                               ch >= 'A' && ch <= 'F' ? unsigned(ch - 'A' + 10) :
                                                       unsigned(ch - 'a' + 10);
        suffix = (suffix << 4) | digit;
    }
    return factoryAddress(suffix);
}

inline bool parsePrivateHost(const char* text, IPv4& result) {
    if (!text)
        return false;
    IPv4 parsed{};
    for (unsigned i = 0; i < 4; ++i) {
        const char* start = text;
        unsigned value = 0, digits = 0;
        while (*text >= '0' && *text <= '9') {
            if (++digits > 3)
                return false;
            value = value * 10 + unsigned(*text++ - '0');
        }
        if (!digits || value > 255 || (digits > 1 && *start == '0'))
            return false;
        parsed.octets[i] = uint8_t(value);
        if (i < 3) {
            if (*text++ != '.')
                return false;
        } else if (*text != '\0') {
            return false;
        }
    }
    const bool privateRange = parsed.octets[0] == 10 ||
        (parsed.octets[0] == 172 && parsed.octets[1] >= 16 && parsed.octets[1] <= 31) ||
        (parsed.octets[0] == 192 && parsed.octets[1] == 168);
    if (!privateRange || parsed.octets[3] == 0 || parsed.octets[3] == 255)
        return false;
    result = parsed;
    return true;
}

struct LeaseRange { uint8_t first; uint8_t last; };
inline LeaseRange leaseRange(uint8_t gatewayHost) {
    return gatewayHost < 32 ? LeaseRange{32, 47} : LeaseRange{1, 16};
}
} // namespace ap_address
