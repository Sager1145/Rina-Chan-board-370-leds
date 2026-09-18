#!/usr/bin/env python3
"""Board group v1 identify overlay (docs/BOARD_GROUP_SPEC.md §1.2, §1.6):
source-pattern checks that the pure cursor/viewport/glyph math in
group_math.h cannot cover -- the overlay is drawn only inside
led_renderer.cpp's single render path, it marks the presented sample
rateEligible=false, and the CMD handler never touches frame/scroll/mode
state or bumps the state version.
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src"
RENDERER = (SRC / "led_renderer.cpp").read_text()
PROTOCOL = (SRC / "protocol.cpp").read_text()

OTHER_CPP = [
    p for p in SRC.glob("*.cpp")
    if p.name not in ("led_renderer.cpp",)
]


def function(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_identify_state_only_touched_in_led_renderer():
    # g_identifyNumber/g_identifyExpireAtUs are led_renderer.cpp-private statics;
    # no other translation unit may reference them (only the single render path
    # may ever call the LED driver / know the overlay is active).
    for path in OTHER_CPP:
        text = path.read_text()
        check("g_identifyNumber" not in text, f"{path.name} must not touch g_identifyNumber")
        check("g_identifyExpireAtUs" not in text, f"{path.name} must not touch g_identifyExpireAtUs")
    check("g_identifyNumber" in RENDERER, "led_renderer.cpp must own g_identifyNumber")
    print("test_identify_state_only_touched_in_led_renderer: OK")


def test_identify_drawn_only_in_render_pass():
    render_fn = function(RENDERER, "void renderCurrentFrameToLedStrip()")
    check("group_math::identifyDigitPixelLit" in render_fn,
          "renderCurrentFrameToLedStrip() must draw the identify glyph")
    # No other function in led_renderer.cpp (or any other file) calls the glyph
    # lookup -- only the one render pass draws it.
    other_renderer_text = RENDERER.replace(render_fn, "")
    check("identifyDigitPixelLit" not in other_renderer_text,
          "only renderCurrentFrameToLedStrip() may draw the identify glyph")
    for path in OTHER_CPP:
        check("identifyDigitPixelLit" not in path.read_text(),
              f"{path.name} must not draw the identify glyph directly")
    print("test_identify_drawn_only_in_render_pass: OK")


def test_identify_marks_rate_ineligible():
    render_fn = function(RENDERER, "void renderCurrentFrameToLedStrip()")
    # The identify branch (guarded by `if (identifyNumber >= 0) {`) must set
    # ctx.rateEligible = false before the branch closes, same as the other
    # overlays (button animation, hint LED) in this function.
    branch_start = render_fn.index("if (identifyNumber >= 0) {")
    branch_end = render_fn.index("} else if (overlayActive)", branch_start)
    branch = render_fn[branch_start:branch_end]
    check("ctx.rateEligible = false;" in branch,
          "identify overlay branch must force ctx.rateEligible = false")
    print("test_identify_marks_rate_ineligible: OK")


def test_identify_priority_over_hint_and_button_overlay():
    render_fn = function(RENDERER, "void renderCurrentFrameToLedStrip()")
    # Priority: identify > hint > button overlay > content. The identify branch
    # must be the first arm of the if/else-if/else chain that also covers
    # overlayActive (button animation) and the hint LED.
    identify_idx = render_fn.index("if (identifyNumber >= 0) {")
    overlay_idx = render_fn.index("overlayActive) {")
    hint_idx = render_fn.index("hint >= 0 && hint <")
    check(identify_idx < overlay_idx < hint_idx,
          "identify must be checked before the button overlay and the hint LED")
    print("test_identify_priority_over_hint_and_button_overlay: OK")


def test_cmd_identify_never_touches_scroll_frame_face_state():
    match = re.search(r'if \(strcmp\(cmd, "identify"\) == 0\) \{', PROTOCOL)
    check(match is not None, "protocol.cpp must have a CMD identify handler")
    start = match.start()
    brace = PROTOCOL.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (PROTOCOL[end] == "{") - (PROTOCOL[end] == "}")
        end += 1
    handler = PROTOCOL[start:end]
    for forbidden in (
        "touchRuntimeState()", "touchRuntimeStateSlow()",
        "scrollSession", "setMode(", "applySavedFaceIndex",
        "LittleFS", "saveRuntimeSettings",
    ):
        check(forbidden not in handler,
              f"CMD identify handler must not use {forbidden} (no frame/scroll/face state, no flash writes)")
    check("setIdentifyOverlay(" in handler, "CMD identify handler must call setIdentifyOverlay()")
    print("test_cmd_identify_never_touches_scroll_frame_face_state: OK")


def test_scroll_bitmap_rotation_skipped_for_viewport_uploads():
    SCROLL_TXT = PROTOCOL
    check("bitmapHasViewport" in SCROLL_TXT and "rotation" in SCROLL_TXT,
          "protocol.cpp must gate the rotation search on bitmapHasViewport")
    idx = SCROLL_TXT.index("if (!c.blob.bitmapHasViewport) {")
    check(idx > 0, "rotation search must be skipped when bitmapHasViewport is set (§1.4: no rotation)")
    print("test_scroll_bitmap_rotation_skipped_for_viewport_uploads: OK")


def main():
    test_identify_state_only_touched_in_led_renderer()
    test_identify_drawn_only_in_render_pass()
    test_identify_marks_rate_ineligible()
    test_identify_priority_over_hint_and_button_overlay()
    test_cmd_identify_never_touches_scroll_frame_face_state()
    test_scroll_bitmap_rotation_skipped_for_viewport_uploads()
    print("All group_identify pattern checks passed.")


if __name__ == "__main__":
    main()
