#pragma once
#include <cstdint>
struct IPAddress {
    uint8_t b[4];
    IPAddress(uint8_t a, uint8_t c, uint8_t d, uint8_t e) : b{a, c, d, e} {}
};
