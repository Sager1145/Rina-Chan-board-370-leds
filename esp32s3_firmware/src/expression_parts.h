#pragma once
#include "expression_parts_generated.h"
#include <string.h>

namespace expression_parts {
// Bounded decimal parsing keeps IDs semantic; array offsets never become IDs.
inline bool parseId(const char* input, uint16_t& value) {
    if (!input || !*input) return false;
    uint32_t parsed = 0;
    uint8_t digits = 0;
    for (const char* p = input; *p; ++p) {
        if (*p < '0' || *p > '9' || ++digits > 5) return false;
        parsed = parsed * 10 + static_cast<uint32_t>(*p - '0');
        if (parsed > UINT16_MAX) return false;
    }
    value = static_cast<uint16_t>(parsed);
    return true;
}

inline const uint8_t* resolve(uint8_t group, uint16_t id) {
    for (const Call& call : CALLS)
        if (call.group == group && call.id == id)
            return PARTS[call.partIndex].mask;
    return nullptr;
}

// Masks are in logical row-major LED order already. Only led_renderer maps
// them onto physical serpentine wiring, exactly as for hand-drawn frames.
inline bool compose(const uint16_t (&ids)[4], uint8_t* out) {
    if (!out) return false;
    const uint8_t* masks[4];
    for (uint8_t group = 0; group < 4; ++group) {
        masks[group] = resolve(group, ids[group]);
        if (!masks[group]) return false;
    }
    memset(out, 0, FRAME_SIZE);
    for (const uint8_t* mask : masks)
        for (size_t byte = 0; byte < FRAME_SIZE; ++byte)
            out[byte] |= mask[byte];
    return true;
}
} // namespace expression_parts
