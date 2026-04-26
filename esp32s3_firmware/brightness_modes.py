from config import (
    BRIGHTNESS_MIN, BRIGHTNESS_MAX, BRIGHTNESS_MAX_CHANNEL,
    BADAPPLE_BRIGHTNESS_DIVISOR, DEMO_BRIGHTNESS_DIVISOR,
)
def clamp_ui_brightness(value):
    if value < BRIGHTNESS_MIN:
        return BRIGHTNESS_MIN
    if value > BRIGHTNESS_MAX:
        return BRIGHTNESS_MAX
    return int(value)
def effective_brightness(ui_brightness, badapple_mode=False, demo_mode=False):
    ui = clamp_ui_brightness(ui_brightness)
    cap = (ui * BRIGHTNESS_MAX_CHANNEL + 50) // 100
    if badapple_mode:
        cap = cap // BADAPPLE_BRIGHTNESS_DIVISOR
    elif demo_mode:
        cap = cap
    if cap < 1:
        cap = 1
    return cap
