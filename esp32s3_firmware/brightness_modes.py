# ---------------------------------------------------------------------------
# brightness_modes.py
#
# Brightness helpers.
#
# The user-facing brightness value is always stored as a percent in the range
# BRIGHTNESS_MIN..BRIGHTNESS_MAX (5..100) in 5% steps. That percent is mapped
# into a raw per-channel LED cap via BRIGHTNESS_MAX_CHANNEL (170), so at 100%
# the physical output of each channel is capped at 170.
# ---------------------------------------------------------------------------

from config import BRIGHTNESS_MIN, BRIGHTNESS_MAX, BRIGHTNESS_MAX_CHANNEL


def clamp_ui_brightness(value):
    """Clamp any requested brightness into the supported UI range."""
    if value < BRIGHTNESS_MIN:
        return BRIGHTNESS_MIN
    if value > BRIGHTNESS_MAX:
        return BRIGHTNESS_MAX
    return int(value)


def effective_brightness(ui_brightness):
    """Return the per-channel board brightness cap for the given UI percent.

    Maps the UI percent (5..100) to a physical LED channel cap (1..170).
    All display modes share one brightness level; the old badapple/demo
    divisors have been removed along with those features.
    """
    ui = clamp_ui_brightness(ui_brightness)
    cap = (ui * BRIGHTNESS_MAX_CHANNEL + 50) // 100
    if cap < 1:
        cap = 1
    return cap
