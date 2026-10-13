#pragma once
#include <cstdint>
#include "Arduino.h"
struct IPAddress {
    uint8_t b[4];
    IPAddress(uint8_t a, uint8_t c, uint8_t d, uint8_t e) : b{a, c, d, e} {}
    String toString() const {
        return String(b[0]) + "." + String(b[1]) + "." + String(b[2]) + "." + String(b[3]);
    }
};
