# ---------------------------------------------------------------------------
# config.py
#
# Central project constants.
# ---------------------------------------------------------------------------

import demo_faces

POLL_PERIOD_MS = 10
SETTINGS_FILE = "linaboard_settings.json"

DEFAULT_FACE = demo_faces.DEFAULT_FACE_INDEX
NUM_FACES = len(demo_faces.FRAMES)

DEFAULT_INTERVAL_S = 1.0
INTERVAL_STEP_S = 0.5
INTERVAL_MIN_S = 0.5
INTERVAL_MAX_S = 10.0

DEMO_DEFAULT_INTERVAL_S = 5.0
DEMO_DEFAULT_AUTO = True

# UI-facing brightness is stored as a percent in 5% steps, 5..100.
# BRIGHTNESS_MAX_CHANNEL is the actual per-channel LED ceiling at 100%.
# At 100%, the board caps each of R/G/B to BRIGHTNESS_MAX_CHANNEL (170).
# At any other percent p, the effective cap is round(p * 170 / 100).
DEFAULT_BRIGHTNESS = 30
BRIGHTNESS_STEP = 5
BRIGHTNESS_MIN = 5
BRIGHTNESS_MAX = 100
BRIGHTNESS_MAX_CHANNEL = 170

FLASH_HOLD_MS = 1000
BATTERY_SHORT_SHOW_MS = 2000
BRIGHTNESS_RESET_IGNORE_MS = 300
B6_LONG_PRESS_MS = 700
SPECIAL_COMBO_LONG_PRESS_MS = 2000
BADAPPLE_COMBO_LONG_PRESS_MS = 2000

BATTERY_REFRESH_MS = 100
BATTERY_ANIMATION_REFRESH_MS = 50
BATTERY_MEAN_UPDATE_MS = 1000
BATTERY_MEAN_SAMPLE_INTERVAL_MS = 20
BATTERY_DISPLAY_CYCLE_MS = 2000
BATTERY_LOG_INTERVAL_MS = 30000
BATTERY_RELEARN_EVERY_MEASUREMENTS = 2000
BATTERY_RELEARN_MAX_STEP_V = 0.05
BATTERY_RELEARN_MIN_STEP_V = 0.05
BATTERY_RELEARN_HOLDOFF_MEASUREMENTS = 20
# Maximum number of consecutive inward adjustments per side (min / max)
# without observing a new real extreme on that side. Once a side hits
# this cap it freezes in place until a genuine new min (or max) is
# recorded, which resets that side's counter.
BATTERY_RELEARN_MAX_CONSECUTIVE = 2
BATTERY_MIN_SPAN_V = 0.20

BATTERY_PERCENT_CURVE = (
    # Maps normalized voltage x in [0.0, 1.0] (where 0 = v_min, 1 = v_max)
    # to battery percent. Shape is tuned against published 2S LiPo open-
    # circuit voltage (OCV) vs. state-of-charge tables: steep voltage cliff
    # near empty, steep rise through the middle plateau (where real SoC
    # moves fast with small voltage changes), mild taper at the top.
    #
    # The voltage comments assume the intended range v_min=6.2 V, v_max=8.0 V
    # (the learned/recorded endpoints). The clamp band BATTERY_DISPLAY_TOL_V
    # snaps readings within 0.12 V of each endpoint to 0% / 100%, so the
    # recorded min/max always correspond to 0% / 100% respectively.
    (0.000,   0.0),
    (0.222,   3.0),
    (0.389,   7.0),
    (0.444,  10.0),
    (0.500,  14.0),
    (0.556,  18.0),
    (0.611,  26.0),
    (0.667,  35.0),
    (0.722,  45.0),
    (0.778,  58.0),
    (0.833,  70.0),
    (0.889,  82.0),
    (0.944,  92.0),
    (1.000, 100.0),
)

BATTERY_HISTORY_MAX_SAMPLES = 96
BATTERY_HISTORY_MIN_RATE_PCT_PER_H = 0.25
BATTERY_HISTORY_SAME_MODE_WEIGHT = 2.5
BATTERY_HISTORY_BRIGHTNESS_WINDOW = 20
BATTERY_DEFAULT_USAGE_HOURS = 1.0
BATTERY_DEFAULT_CHARGE_HOURS = 0.5

BATTERY_ADC_GPIO = 26
BATTERY_ADC_REF_V = 3.3
BATTERY_SAMPLES = 16
BATTERY_DIVIDER_R1 = 100000
BATTERY_DIVIDER_R2 = 57000
BATTERY_DEFAULT_MIN_V = 6.2
BATTERY_DEFAULT_MAX_V = 8.0
BATTERY_DISPLAY_TOL_V = 0.12
# Bump this whenever BATTERY_DEFAULT_MIN_V / BATTERY_DEFAULT_MAX_V or
# BATTERY_PERCENT_CURVE change in a way that makes previously learned
# min_v / max_v (and the stored usage/charge history based on them)
# incompatible. On boot, if the stored version differs from this one,
# the calibration will be reset to defaults.
BATTERY_CAL_VERSION = 4

CHARGE_DETECT_ADC_GPIO = 27
CHARGE_DETECT_ADC_REF_V = 3.3
CHARGE_DETECT_SAMPLES = 16
CHARGE_DETECT_DIVIDER_R1 = 270000
CHARGE_DETECT_DIVIDER_R2 = 47000
CHARGE_DETECT_NON_CHARGING_V = 3.0
CHARGE_DETECT_CHARGING_MIN_V = 4.0
CHARGE_DISPLAY_THRESHOLD_V = 4.5
CHARGE_DETECT_HYSTERESIS_LOW_V = 3.0


BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S = 0.2
BATTERY_CHARGE_ANIM_INTERVAL_NEAR_FULL_S = 0.2
BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT = 90
BATTERY_CHARGE_ANIM_FULL_CYCLE_S = 0.2
BATTERY_CHARGE_LAST_COLUMN_FLASH_MS = 300

EDGE_FLASH_ATTACK_MS = 45
EDGE_FLASH_DECAY_MS = 260
EDGE_FLASH_TOTAL_MS = EDGE_FLASH_ATTACK_MS + EDGE_FLASH_DECAY_MS
EDGE_FLASH_COLOR = (0, 120, 255)

BADAPPLE_PART_MODULES = (
    'badapple_part0', 'badapple_part1', 'badapple_part2', 'badapple_part3',
    'badapple_part4', 'badapple_part5', 'badapple_part6', 'badapple_part7',
    'badapple_part8', 'badapple_part9', 'badapple_part10', 'badapple_part11',
    'badapple_part12', 'badapple_part13', 'badapple_part14', 'badapple_part15',
    'badapple_part16',
)
BADAPPLE_ON_COLOR = (255, 255, 255)
BADAPPLE_OFF_COLOR = (0, 0, 0)
# Bad Apple and the matrix demo mode both run at 1/3 of the effective
# face-mode brightness cap. The UI-facing brightness percent stays the
# same; only the physical channel cap is reduced while these modes are
# active.
BADAPPLE_BRIGHTNESS_DIVISOR = 3
DEMO_BRIGHTNESS_DIVISOR = 3