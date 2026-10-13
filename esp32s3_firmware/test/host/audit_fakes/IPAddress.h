#pragma once
#include <Arduino.h>
struct IPAddress {
    uint8_t b[4] = {};
    IPAddress() = default;
    IPAddress(uint8_t a, uint8_t c, uint8_t d, uint8_t e) : b{a,c,d,e} {}
    explicit IPAddress(uint32_t address) : b{uint8_t(address), uint8_t(address >> 8), uint8_t(address >> 16), uint8_t(address >> 24)} {}
    uint8_t operator[](unsigned i) const { return b[i]; }
    explicit operator uint32_t() const { return uint32_t(b[0]) | (uint32_t(b[1]) << 8) | (uint32_t(b[2]) << 16) | (uint32_t(b[3]) << 24); }
    bool operator!=(const IPAddress& o) const { return memcmp(b, o.b, 4) != 0; }
    String toString() const { return String(b[0]) + "." + String(b[1]) + "." + String(b[2]) + "." + String(b[3]); }
};
