# ---------------------------------------------------------------------------
# brightness_modes.py
#
# Mode-dependent brightness helpers.
#
# The user-facing brightness value is always shared and stored as 10..100.
# Face mode and demo mode use that value directly.
# Bad Apple mode intentionally uses half of that brightness internally.
#
# Example:
# - UI shows 80%
# - face mode / demo mode apply 80
# - Bad Apple applies 40
# ---------------------------------------------------------------------------

from config import BRIGHTNESS_MIN, BRIGHTNESS_MAX, BADAPPLE_BRIGHTNESS_DIVISOR


def clamp_ui_brightness(value):
    # Clamp any requested brightness into the supported UI range.
    if value < BRIGHTNESS_MIN:
        return BRIGHTNESS_MIN
    if value > BRIGHTNESS_MAX:
        return BRIGHTNESS_MAX
    return int(value)


def effective_brightness(ui_brightness, badapple_mode=False):
    # -----------------------------------------------------------------------
    # Return the actual board brightness cap for the active mode.
    #
    # The saved / displayed brightness stays shared. Only the effective cap is
    # reduced during Bad Apple playback.
    # -----------------------------------------------------------------------
    ui = clamp_ui_brightness(ui_brightness)
    if not badapple_mode:
        return ui

    value = ui // BADAPPLE_BRIGHTNESS_DIVISOR
    if value < 1:
        value = 1
    return value
