#pragma once
#include <stdint.h>
#include <stddef.h>

// Pure, dependency-free math for board-group v1 (docs/BOARD_GROUP_SPEC.md §1).
// No Arduino/ESP-IDF headers on purpose so this compiles standalone with
// `c++ -std=c++17` for host tests (esp32s3_firmware/test/host/). Callers in
// the firmware (protocol.cpp, led_renderer.cpp, scroll_session.cpp) pass in
// whatever board-specific data (row layout, clock values) they already have.

namespace group_math {

// --- §1.5 group-timed cursor -------------------------------------------------

struct GroupCursor {
    uint32_t frame = 0;
    // True when `now < atUs`: the board holds on `startFrame` and does not
    // advance yet (no negative elapsed / no catch-up replay).
    bool held = false;
    // True when looping is disabled and the computed step has reached (or
    // passed) the last frame: caller should latch the "paused on last frame"
    // behaviour, same as the legacy end-of-timeline hold.
    bool endedNoLoop = false;
};

// nowUs/atUs are absolute microsecond timestamps from the same monotonic
// clock (esp_timer_get_time() on-device). intervalMs is clamped to >=1 and
// frameCount to >=1 defensively; real callers already validate ranges before
// reaching here. No per-tick accumulation, no drift rebase: a late call with
// a far-future `nowUs` jumps straight to the correct frame.
inline GroupCursor groupCursorAt(uint64_t nowUs, uint64_t atUs, uint32_t startFrame,
                                  uint32_t intervalMs, uint32_t frameCount, bool loop) {
    GroupCursor c;
    if (frameCount == 0)
        frameCount = 1;
    if (intervalMs == 0)
        intervalMs = 1;

    if (nowUs < atUs) {
        c.frame = startFrame % frameCount;
        c.held = true;
        return c;
    }

    const uint64_t elapsedUs = nowUs - atUs;
    const uint64_t steps = elapsedUs / (static_cast<uint64_t>(intervalMs) * 1000ULL);
    const uint64_t n = static_cast<uint64_t>(startFrame) + steps;

    if (loop) {
        c.frame = static_cast<uint32_t>(n % frameCount);
        return c;
    }

    const uint64_t last = frameCount - 1U;
    if (n >= last) {
        c.frame = static_cast<uint32_t>(last);
        c.endedNoLoop = true;
    } else {
        c.frame = static_cast<uint32_t>(n);
    }
    return c;
}

// True when a group-timed `cursor` that has ended (loop disabled, past the
// last frame) still needs to latch/present the last frame this tick: only
// when the caller's currently-shown frame index differs from cursor.frame.
// Once the caller has latched cursor.frame once, subsequent ticks (time keeps
// advancing while `endedNoLoop` stays true) must not re-latch/re-pause every
// tick -- same "present once, then hold" shape as the legacy end-of-timeline
// path. A late tick that jumps straight from well before the end (e.g.
// last-2) to at-or-past the last frame must still present the last frame
// exactly once, never skipping the final still frame.
inline bool groupCursorEndLatchDue(const GroupCursor& cursor, uint16_t currentFrameIndex) {
    return cursor.endedNoLoop && currentFrameIndex != static_cast<uint16_t>(cursor.frame);
}

// --- §1.4 scroll_bitmap viewport extension ------------------------------------

// frameCount = max(1, W - V) + 1 (caller applies the >3072 -> 413 limit).
// V == 22 (the legacy single-board width) reproduces the existing
// scroll_bitmap frame-count formula exactly.
inline uint32_t viewportFrameCount(uint32_t width, uint32_t virtualWidth) {
    const uint32_t base = width > virtualWidth ? (width - virtualWidth) : 1U;
    return base + 1U;
}

// Frame `frameIndex` at this board's viewport offset `viewportX`, board cell
// column `boardX`, shows virtual-bitmap column `frameIndex + viewportX +
// boardX`. Returns false (pixel is off) when that column is >= width, matching
// "pixels with column >= W are off". No rotation is applied in viewport mode.
inline bool viewportColumnFor(uint32_t frameIndex, uint32_t viewportX, uint16_t boardX,
                              uint32_t width, uint32_t& outColumn) {
    const uint64_t col = static_cast<uint64_t>(frameIndex) + viewportX + boardX;
    if (col >= width)
        return false;
    outColumn = static_cast<uint32_t>(col);
    return true;
}

// --- §1.2 identify overlay: digit glyph + placement ---------------------------

// 5x7 pixel digits 0-9, MSB-first per row (bit 4 = leftmost column).
inline const uint8_t* identifyDigitFont(uint8_t digit) {
    static constexpr uint8_t kFont[10][7] = {
        {0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110}, // 0
        {0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110}, // 1
        {0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111}, // 2
        {0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110}, // 3
        {0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010}, // 4
        {0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110}, // 5
        {0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110}, // 6
        {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000}, // 7
        {0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110}, // 8
        {0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100}, // 9
    };
    if (digit > 9)
        return nullptr;
    return kFont[digit];
}

// Top-left of the scaled glyph, logical (x,y) in the 22x18 grid (§1.2).
constexpr uint16_t kIdentifyOriginX = 6;
constexpr uint16_t kIdentifyOriginY = 2;
constexpr uint8_t kIdentifyGlyphW = 5;
constexpr uint8_t kIdentifyGlyphH = 7;
constexpr uint8_t kIdentifyScale = 2; // 10x14 on-grid footprint.

// True when grid cell (gx, gy) is lit for the x2-scaled digit glyph placed at
// (kIdentifyOriginX, kIdentifyOriginY). Cells outside the glyph box are unlit;
// the caller separately skips cells outside the board's valid LED range.
inline bool identifyDigitPixelLit(uint8_t digit, uint16_t gx, uint16_t gy) {
    const uint8_t* font = identifyDigitFont(digit);
    if (!font)
        return false;
    if (gx < kIdentifyOriginX || gy < kIdentifyOriginY)
        return false;
    const uint16_t lx = gx - kIdentifyOriginX;
    const uint16_t ly = gy - kIdentifyOriginY;
    if (lx >= static_cast<uint16_t>(kIdentifyGlyphW) * kIdentifyScale ||
        ly >= static_cast<uint16_t>(kIdentifyGlyphH) * kIdentifyScale)
        return false;
    const uint8_t srcX = static_cast<uint8_t>(lx / kIdentifyScale);
    const uint8_t srcY = static_cast<uint8_t>(ly / kIdentifyScale);
    return ((font[srcY] >> (kIdentifyGlyphW - 1U - srcX)) & 1U) != 0;
}

// --- shared: logical-grid -> logical LED index --------------------------------

// Mirrors config.h's ROW_LENGTHS/ROW_OFFSETS centred-row mapping (and
// MatrixGeometry.swift / protocol.cpp's scrollBitmapBuildFrame): row `y` of a
// `gridWidth`-wide grid is centred over the board's (possibly narrower)
// physical row, xStart = (gridWidth - rowLength) / 2. Rows/columns outside the
// valid range return false ("cells outside the board's valid range are
// skipped"). Callers pass config.h's ROW_LENGTHS/ROW_OFFSETS so this header
// stays dependency-free.
inline bool gridCellToLogicalIndex(uint16_t x, uint16_t y, uint16_t gridWidth,
                                   const uint8_t* rowLengths, const uint16_t* rowOffsets,
                                   uint8_t rowCount, uint16_t& outIndex) {
    if (y >= rowCount)
        return false;
    const uint8_t rowLength = rowLengths[y];
    if (rowLength == 0 || rowLength > gridWidth)
        return false;
    const uint8_t xStart = static_cast<uint8_t>((gridWidth - rowLength) / 2);
    if (x < xStart || x >= static_cast<uint16_t>(xStart + rowLength))
        return false;
    outIndex = static_cast<uint16_t>(rowOffsets[y] + (x - xStart));
    return true;
}

} // namespace group_math
