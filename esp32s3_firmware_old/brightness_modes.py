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

# Import: Loads BRIGHTNESS_MIN, BRIGHTNESS_MAX, BRIGHTNESS_MAX_CHANNEL from config so this module can use that dependency.
from config import BRIGHTNESS_MIN, BRIGHTNESS_MAX, BRIGHTNESS_MAX_CHANNEL


# Function: Defines clamp_ui_brightness(value) to handle clamp ui brightness behavior.
def clamp_ui_brightness(value):
    # Module: Documents the purpose of this scope.
    """Clamp any requested brightness into the supported UI range."""
    # Logic: Branches when value < BRIGHTNESS_MIN so the correct firmware path runs.
    if value < BRIGHTNESS_MIN:
        # Return: Sends the current BRIGHTNESS_MIN value back to the caller.
        return BRIGHTNESS_MIN
    # Logic: Branches when value > BRIGHTNESS_MAX so the correct firmware path runs.
    if value > BRIGHTNESS_MAX:
        # Return: Sends the current BRIGHTNESS_MAX value back to the caller.
        return BRIGHTNESS_MAX
    # Return: Sends the result returned by int() back to the caller.
    return int(value)


# Function: Defines effective_brightness(ui_brightness) to handle effective brightness behavior.
def effective_brightness(ui_brightness):
    # Module: Documents the purpose of this scope.
    """Return the per-channel board brightness cap for the given UI percent.

    Maps the UI percent (5..100) to a physical LED channel cap (1..170).
    All display modes share one brightness level; the old badapple/demo
    divisors have been removed along with those features.
    """
    # Variable: ui stores the result returned by clamp_ui_brightness().
    ui = clamp_ui_brightness(ui_brightness)
    # Variable: cap stores the calculated expression (ui * BRIGHTNESS_MAX_CHANNEL + 50) // 100.
    cap = (ui * BRIGHTNESS_MAX_CHANNEL + 50) // 100
    # Logic: Branches when cap < 1 so the correct firmware path runs.
    if cap < 1:
        # Variable: cap stores the configured literal value.
        cap = 1
    # Return: Sends the current cap value back to the caller.
    return cap
