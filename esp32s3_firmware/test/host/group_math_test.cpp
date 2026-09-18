// Board group v1 (docs/BOARD_GROUP_SPEC.md §1.6): pure-function tests for
// group_math.h -- group-timed cursor math, viewport frame expansion, and
// identify digit placement. No Arduino dependency; compiles standalone.
//
// Run: c++ -std=c++17 -Wall -Wextra -Werror -Iesp32s3_firmware/src \
//   esp32s3_firmware/test/host/group_math_test.cpp -o /tmp/rina-group-math-test && /tmp/rina-group-math-test
#include "group_math.h"

#include <cassert>
#include <cstdio>

using namespace group_math;

// --- §1.5 group cursor -------------------------------------------------------

static void test_negative_elapsed_holds_start_frame() {
    // now < atUs: held on startFrame, no advance.
    GroupCursor c = groupCursorAt(/*nowUs=*/1000, /*atUs=*/5000, /*startFrame=*/3,
                                  /*intervalMs=*/100, /*frameCount=*/10, /*loop=*/true);
    assert(c.held);
    assert(!c.endedNoLoop);
    assert(c.frame == 3);
    printf("test_negative_elapsed_holds_start_frame: OK\n");
}

static void test_exact_boundary_advances_by_one_step() {
    // Exactly one interval elapsed: n = startFrame + 1.
    const uint64_t atUs = 1'000'000;
    const uint64_t intervalMs = 250;
    GroupCursor c = groupCursorAt(atUs + intervalMs * 1000, atUs, /*startFrame=*/0,
                                  static_cast<uint32_t>(intervalMs), /*frameCount=*/5, /*loop=*/true);
    assert(!c.held);
    assert(c.frame == 1);

    // One microsecond before the boundary: still on frame 0.
    GroupCursor c2 = groupCursorAt(atUs + intervalMs * 1000 - 1, atUs, 0,
                                   static_cast<uint32_t>(intervalMs), 5, true);
    assert(c2.frame == 0);
    printf("test_exact_boundary_advances_by_one_step: OK\n");
}

static void test_loop_wraps_modulo_frame_count() {
    const uint64_t atUs = 0;
    const uint32_t intervalMs = 100;
    const uint32_t frameCount = 4;
    // 10 intervals elapsed -> n = 10 -> 10 % 4 = 2.
    GroupCursor c = groupCursorAt(10ULL * intervalMs * 1000, atUs, 0, intervalMs, frameCount, true);
    assert(c.frame == 2);
    assert(!c.endedNoLoop);
    printf("test_loop_wraps_modulo_frame_count: OK\n");
}

static void test_no_loop_holds_on_last_frame() {
    const uint64_t atUs = 0;
    const uint32_t intervalMs = 100;
    const uint32_t frameCount = 4; // last index 3
    // Far past the end: must clamp to last frame, not keep counting.
    GroupCursor c = groupCursorAt(1'000'000ULL * intervalMs, atUs, 0, intervalMs, frameCount, false);
    assert(c.endedNoLoop);
    assert(c.frame == frameCount - 1);

    // Exactly landing on the last frame also reports ended.
    GroupCursor exact = groupCursorAt(3ULL * intervalMs * 1000, atUs, 0, intervalMs, frameCount, false);
    assert(exact.endedNoLoop);
    assert(exact.frame == 3);

    // One step before the end: not yet ended.
    GroupCursor before = groupCursorAt(2ULL * intervalMs * 1000, atUs, 0, intervalMs, frameCount, false);
    assert(!before.endedNoLoop);
    assert(before.frame == 2);
    printf("test_no_loop_holds_on_last_frame: OK\n");
}

static void test_late_tick_jumps_no_catchup_replay() {
    // A "late tick" (long gap between calls, e.g. the board was busy) must land
    // directly on the correct frame instead of replaying every intermediate one.
    const uint64_t atUs = 0;
    const uint32_t intervalMs = 50;
    const uint32_t frameCount = 1000;
    GroupCursor c = groupCursorAt(777ULL * intervalMs * 1000, atUs, 0, intervalMs, frameCount, true);
    assert(c.frame == 777 % frameCount);
    printf("test_late_tick_jumps_no_catchup_replay: OK\n");
}

static void test_large_u64_values_near_wrap_are_irrelevant() {
    // atUs/nowUs use large absolute microsecond values; the function must not
    // assume small numbers. Use values far from either 32-bit or 64-bit wrap.
    const uint64_t atUs = 18'000'000'000'000ULL; // ~208 days of uptime, still << 2^64
    const uint32_t intervalMs = 100;
    const uint32_t frameCount = 7;
    GroupCursor c = groupCursorAt(atUs + 23ULL * intervalMs * 1000, atUs, 0, intervalMs, frameCount, true);
    assert(c.frame == 23 % frameCount);
    printf("test_large_u64_values_near_wrap_are_irrelevant: OK\n");
}

static void test_end_latch_due_only_once_on_late_jump_past_last() {
    // F3: a late tick can jump straight from well before the end (e.g.
    // last-2) to at-or-past the last frame in one call (no catch-up replay).
    // The caller must still latch/present the last frame exactly once.
    const uint64_t atUs = 0;
    const uint32_t intervalMs = 100;
    const uint32_t frameCount = 5; // last index 4
    uint16_t currentFrameIndex = frameCount - 3; // "last - 2" == 2

    // Jump far past the end in one tick.
    GroupCursor c = groupCursorAt(1'000ULL * intervalMs * 1000, atUs, 0, intervalMs, frameCount, false);
    assert(c.endedNoLoop);
    assert(c.frame == frameCount - 1);
    assert(group_math::groupCursorEndLatchDue(c, currentFrameIndex));

    // Caller latches: scrollFrameIndex now equals the last frame.
    currentFrameIndex = static_cast<uint16_t>(c.frame);

    // A subsequent tick with the same ended cursor must not re-latch.
    GroupCursor c2 = groupCursorAt(1'001ULL * intervalMs * 1000, atUs, 0, intervalMs, frameCount, false);
    assert(c2.endedNoLoop);
    assert(c2.frame == frameCount - 1);
    assert(!group_math::groupCursorEndLatchDue(c2, currentFrameIndex));
    printf("test_end_latch_due_only_once_on_late_jump_past_last: OK\n");
}

static void test_start_frame_offset_and_reanchor_replaces_atomically() {
    // startFrame != 0 shifts the whole schedule; re-anchoring is just calling
    // groupCursorAt again with new (atUs, startFrame) -- no separate API needed
    // since the caller (scrollSessionGroupStart) just replaces the stored fields.
    GroupCursor c = groupCursorAt(1'500'000, 1'000'000, /*startFrame=*/2, 100, 10, true);
    // elapsed = 500ms -> 5 steps -> n = 2+5=7
    assert(c.frame == 7);
    printf("test_start_frame_offset_and_reanchor_replaces_atomically: OK\n");
}

// --- §1.4 viewport frame expansion -------------------------------------------

static void test_viewport_frame_count_matches_legacy_formula_at_v22() {
    // V=22 must reproduce the pre-existing scroll_bitmap frameCount formula
    // exactly: (W > 22 ? W-22 : 1) + 1.
    assert(viewportFrameCount(22, 22) == 2);
    assert(viewportFrameCount(30, 22) == 9);
    assert(viewportFrameCount(3093, 22) == 3072);
    printf("test_viewport_frame_count_matches_legacy_formula_at_v22: OK\n");
}

static void test_viewport_frame_count_general_v() {
    // W == V -> max(1,0)+1 = 2.
    assert(viewportFrameCount(100, 100) == 2);
    // W > V.
    assert(viewportFrameCount(150, 100) == 51);
    printf("test_viewport_frame_count_general_v: OK\n");
}

static void test_viewport_column_frame_f_shows_f_plus_x_plus_boardx() {
    uint32_t col = 0;
    // frame 0, viewportX 5, boardX 3 -> column 8.
    assert(viewportColumnFor(0, 5, 3, 200, col));
    assert(col == 8);
    // frame 10, viewportX 5, boardX 3 -> column 18.
    assert(viewportColumnFor(10, 5, 3, 200, col));
    assert(col == 18);
    printf("test_viewport_column_frame_f_shows_f_plus_x_plus_boardx: OK\n");
}

static void test_viewport_column_off_when_ge_width() {
    uint32_t col = 0;
    // width 20: column 20 is off, column 19 is on.
    assert(!viewportColumnFor(15, 5, 0, 20, col)); // col = 20
    assert(viewportColumnFor(14, 5, 0, 20, col));  // col = 19
    assert(col == 19);
    printf("test_viewport_column_off_when_ge_width: OK\n");
}

static void test_viewport_frame_count_identical_for_all_viewport_x() {
    // frameCount only depends on (width, virtualWidth), never viewportX -- every
    // board in a group gets the same frameCount regardless of its slot.
    const uint32_t width = 340;
    const uint32_t virtualWidth = 66; // 3 boards, no gaps
    const uint32_t fc = viewportFrameCount(width, virtualWidth);
    for (uint32_t vx = 0; vx <= virtualWidth - 22; vx += 11) {
        assert(viewportFrameCount(width, virtualWidth) == fc);
        (void)vx;
    }
    printf("test_viewport_frame_count_identical_for_all_viewport_x: OK\n");
}

// --- §1.2 identify digit placement --------------------------------------------

static void test_identify_digit_stays_within_glyph_box() {
    // 5x7 scaled x2 = 10x14, top-left (6,2): valid lit cells only within
    // x in [6,16), y in [2,16).
    for (uint8_t digit = 1; digit <= 9; ++digit) {
        for (uint16_t gy = 0; gy < 18; ++gy) {
            for (uint16_t gx = 0; gx < 22; ++gx) {
                if (identifyDigitPixelLit(digit, gx, gy)) {
                    assert(gx >= 6 && gx < 16);
                    assert(gy >= 2 && gy < 16);
                }
            }
        }
    }
    printf("test_identify_digit_stays_within_glyph_box: OK\n");
}

static void test_identify_digit_out_of_range_never_lit() {
    for (uint16_t gy = 0; gy < 18; ++gy) {
        for (uint16_t gx = 0; gx < 22; ++gx) {
            assert(!identifyDigitPixelLit(0xFF, gx, gy));
            assert(!identifyDigitPixelLit(10, gx, gy));
        }
    }
    printf("test_identify_digit_out_of_range_never_lit: OK\n");
}

static void test_identify_placement_stays_within_valid_led_cells() {
    // config.h's real row layout (mirrored here as data, not a dependency):
    // gridCellToLogicalIndex must skip any (gx,gy) the board's diamond-shaped
    // matrix does not cover, for every digit and every lit glyph cell.
    static const uint8_t rowLengths[18] = {
        18, 20, 20, 20, 22, 22, 22, 22, 22,
        22, 22, 22, 22, 20, 20, 20, 18, 16};
    static const uint16_t rowOffsets[18] = {
        0, 18, 38, 58, 78, 100, 122, 144, 166,
        188, 210, 232, 254, 276, 296, 316, 336, 354};
    constexpr uint16_t ledCount = 370;

    int litSkippedCount = 0;
    int litMappedCount = 0;
    for (uint8_t digit = 1; digit <= 9; ++digit) {
        for (uint16_t gy = 0; gy < 18; ++gy) {
            for (uint16_t gx = 0; gx < 22; ++gx) {
                if (!identifyDigitPixelLit(digit, gx, gy))
                    continue;
                uint16_t idx = 0;
                if (gridCellToLogicalIndex(gx, gy, 22, rowLengths, rowOffsets, 18, idx)) {
                    assert(idx < ledCount);
                    ++litMappedCount;
                } else {
                    ++litSkippedCount;
                }
            }
        }
    }
    // On this board's actual row layout the glyph box (x in [6,16)) happens to
    // fit inside every row's valid range (narrowest row is 16 wide, xStart=3,
    // valid x in [3,19)), so nothing is skipped here; gridCellToLogicalIndex's
    // skip path is covered separately below (row 0, x=1).
    assert(litMappedCount > 0);
    assert(litSkippedCount == 0);
    printf("test_identify_placement_stays_within_valid_led_cells: OK (mapped=%d skipped=%d)\n",
           litMappedCount, litSkippedCount);
}

// F6: mirrors GroupScrollBitmapTests.swift's
// testGoldenFrameAtKnownViewportAndFrameIndex() -- same W=60 bitmap (one lit
// pixel per row at column 27 + xStart(row)), same (V=46, X=24, f=3), same
// hand-computed expected lit logical LED index list, but built here from
// viewportColumnFor() + gridCellToLogicalIndex() instead of the Swift-side
// GroupScrollBitmap.frame().
static void test_golden_frame_at_known_viewport_and_frame_index() {
    static const uint8_t rowLengths[18] = {
        18, 20, 20, 20, 22, 22, 22, 22, 22,
        22, 22, 22, 22, 20, 20, 20, 18, 16};
    static const uint16_t rowOffsets[18] = {
        0, 18, 38, 58, 78, 100, 122, 144, 166,
        188, 210, 232, 254, 276, 296, 316, 336, 354};
    const uint32_t width = 60;
    const uint32_t viewportX = 24;
    const uint32_t frameIndex = 3;

    // xStart(row) = (22 - rowLength) / 2 (same centring rule as
    // gridCellToLogicalIndex()/MatrixGeometry.validXRange). One lit bitmap
    // column per row, at 27 + xStart(row).
    uint8_t litColumn[18];
    for (uint8_t row = 0; row < 18; ++row)
        litColumn[row] = static_cast<uint8_t>(27 + (22 - rowLengths[row]) / 2);

    const uint16_t expectedLitIndices[18] = {
        0, 18, 38, 58, 78, 100, 122, 144, 166, 188, 210, 232, 254, 276, 296, 316, 336, 354};

    int litCount = 0;
    for (uint8_t row = 0; row < 18; ++row) {
        const uint8_t xStart = static_cast<uint8_t>((22 - rowLengths[row]) / 2);
        bool foundLit = false;
        for (uint16_t gx = xStart; gx < xStart + rowLengths[row]; ++gx) {
            uint32_t col = 0;
            const bool onScreen = viewportColumnFor(frameIndex, viewportX, gx, width, col);
            const bool lit = onScreen && col == litColumn[row];
            if (!lit)
                continue;
            foundLit = true;
            uint16_t idx = 0;
            assert(gridCellToLogicalIndex(gx, row, 22, rowLengths, rowOffsets, 18, idx));
            assert(idx == expectedLitIndices[row]);
            assert(idx == rowOffsets[row]); // the row's first (leftmost) LED, i.e. gx == xStart
            ++litCount;
        }
        assert(foundLit);
    }
    assert(litCount == 18);
    printf("test_golden_frame_at_known_viewport_and_frame_index: OK\n");
}

static void test_grid_cell_to_logical_index_matches_known_points() {
    static const uint8_t rowLengths[18] = {
        18, 20, 20, 20, 22, 22, 22, 22, 22,
        22, 22, 22, 22, 20, 20, 20, 18, 16};
    static const uint16_t rowOffsets[18] = {
        0, 18, 38, 58, 78, 100, 122, 144, 166,
        188, 210, 232, 254, 276, 296, 316, 336, 354};
    uint16_t idx = 0;
    // Row 0 (length 18) is centred: xStart = (22-18)/2 = 2. x=2 -> idx 0.
    assert(gridCellToLogicalIndex(2, 0, 22, rowLengths, rowOffsets, 18, idx));
    assert(idx == 0);
    // x=1 (before xStart) is out of the board's valid range.
    assert(!gridCellToLogicalIndex(1, 0, 22, rowLengths, rowOffsets, 18, idx));
    // Row 4 (length 22, full width): xStart = 0, x=21 -> idx = 78+21 = 99.
    assert(gridCellToLogicalIndex(21, 4, 22, rowLengths, rowOffsets, 18, idx));
    assert(idx == 99);
    printf("test_grid_cell_to_logical_index_matches_known_points: OK\n");
}

int main() {
    test_negative_elapsed_holds_start_frame();
    test_exact_boundary_advances_by_one_step();
    test_loop_wraps_modulo_frame_count();
    test_no_loop_holds_on_last_frame();
    test_end_latch_due_only_once_on_late_jump_past_last();
    test_late_tick_jumps_no_catchup_replay();
    test_large_u64_values_near_wrap_are_irrelevant();
    test_start_frame_offset_and_reanchor_replaces_atomically();
    test_viewport_frame_count_matches_legacy_formula_at_v22();
    test_viewport_frame_count_general_v();
    test_viewport_column_frame_f_shows_f_plus_x_plus_boardx();
    test_viewport_column_off_when_ge_width();
    test_viewport_frame_count_identical_for_all_viewport_x();
    test_identify_digit_stays_within_glyph_box();
    test_identify_digit_out_of_range_never_lit();
    test_identify_placement_stays_within_valid_led_cells();
    test_golden_frame_at_known_viewport_and_frame_index();
    test_grid_cell_to_logical_index_matches_known_points();
    printf("All group_math tests passed.\n");
    return 0;
}
