# ---------------------------------------------------------------------------
# brightness_modes.py
#
# Mode-dependent brightness helpers.
#
# The user-facing brightness value is always stored as a percent in the range
# BRIGHTNESS_MIN..BRIGHTNESS_MAX (5..100) in 5% steps. That percent is mapped
# into a raw per-channel LED cap via BRIGHTNESS_MAX_CHANNEL (170), so at 100%
# the physical output of each channel is capped at 170 and the maximum color
# the board will ever drive is (170, 170, 170).
#
# Face mode uses the full mapped cap.
# Bad Apple is excluded; matrix demo is disabled in the integrated build.
#
# Example (UI 90%):
# - face mode applies    cap = round(90 * 170 / 100) = 153
# - Bad Apple applies    cap = 153 // 3              = 51
# - matrix demo applies  cap = 153 // 3              = 51
# ---------------------------------------------------------------------------

from config import (
    BRIGHTNESS_MIN, BRIGHTNESS_MAX, BRIGHTNESS_MAX_CHANNEL,
    BADAPPLE_BRIGHTNESS_DIVISOR, DEMO_BRIGHTNESS_DIVISOR,
)


def clamp_ui_brightness(value):
    # Clamp any requested brightness into the supported UI range.
    if value < BRIGHTNESS_MIN:
        return BRIGHTNESS_MIN
    if value > BRIGHTNESS_MAX:
        return BRIGHTNESS_MAX
    return int(value)


def effective_brightness(ui_brightness, badapple_mode=False, demo_mode=False):
    # -----------------------------------------------------------------------
    # Return the actual per-channel board brightness cap for the active mode.
    #
    # The saved / displayed brightness percent stays shared. Only the
    # effective physical cap is reduced during Bad Apple playback or while
    # the matrix demo mode is active.
    # -----------------------------------------------------------------------
    ui = clamp_ui_brightness(ui_brightness)
    # Map percent -> per-channel cap, rounding to nearest.
    cap = (ui * BRIGHTNESS_MAX_CHANNEL + 50) // 100

    if badapple_mode:
        cap = cap // BADAPPLE_BRIGHTNESS_DIVISOR
    elif demo_mode:
        # Matrix demo is disabled in this build; keep full brightness if a
        # stale caller accidentally passes demo_mode=True.
        cap = cap

    if cap < 1:
        cap = 1
    return cap
