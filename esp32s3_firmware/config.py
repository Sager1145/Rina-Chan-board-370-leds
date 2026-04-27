# ---------------------------------------------------------------------------
# config.py
#
# Central project constants.
# ---------------------------------------------------------------------------

# Variable: POLL_PERIOD_MS stores the configured literal value.
POLL_PERIOD_MS = 10
# Variable: SETTINGS_FILE stores the configured text value.
SETTINGS_FILE = "linaboard_settings.json"

# Variable: DEFAULT_FACE stores the configured literal value.
DEFAULT_FACE = 0
# Variable: NUM_FACES stores the configured literal value.
NUM_FACES = 11  # seeded saved_faces_370 list; kept for legacy callers

# Variable: DEFAULT_INTERVAL_S stores the configured literal value.
DEFAULT_INTERVAL_S = 1.0
# Variable: INTERVAL_STEP_S stores the configured literal value.
INTERVAL_STEP_S = 0.5
# Variable: INTERVAL_MIN_S stores the configured literal value.
INTERVAL_MIN_S = 0.5
# Variable: INTERVAL_MAX_S stores the configured literal value.
INTERVAL_MAX_S = 10.0

# UI-facing brightness is stored as a percent in 5% steps, 5..100.
# BRIGHTNESS_MAX_CHANNEL is the actual per-channel LED ceiling at 100%.
# At 100%, the board caps each of R/G/B to BRIGHTNESS_MAX_CHANNEL (170).
# At any other percent p, the effective cap is round(p * 170 / 100).
# Variable: DEFAULT_BRIGHTNESS stores the configured literal value.
DEFAULT_BRIGHTNESS = 30
# Variable: BRIGHTNESS_STEP stores the configured literal value.
BRIGHTNESS_STEP = 5
# Variable: BRIGHTNESS_MIN stores the configured literal value.
BRIGHTNESS_MIN = 5
# Variable: BRIGHTNESS_MAX stores the configured literal value.
BRIGHTNESS_MAX = 100
# Variable: BRIGHTNESS_MAX_CHANNEL stores the configured literal value.
BRIGHTNESS_MAX_CHANNEL = 170

# Variable: FLASH_HOLD_MS stores the configured literal value.
FLASH_HOLD_MS = 1000
# Variable: BATTERY_SHORT_SHOW_MS stores the configured literal value.
BATTERY_SHORT_SHOW_MS = 2000
# Variable: BRIGHTNESS_RESET_IGNORE_MS stores the configured literal value.
BRIGHTNESS_RESET_IGNORE_MS = 300
# Variable: B6_LONG_PRESS_MS stores the configured literal value.
B6_LONG_PRESS_MS = 700

# Variable: BATTERY_REFRESH_MS stores the configured literal value.
BATTERY_REFRESH_MS = 100
# Variable: BATTERY_ANIMATION_REFRESH_MS stores the configured literal value.
BATTERY_ANIMATION_REFRESH_MS = 50
# Variable: BATTERY_MEAN_UPDATE_MS stores the configured literal value.
BATTERY_MEAN_UPDATE_MS = 1000
# Variable: BATTERY_MEAN_SAMPLE_INTERVAL_MS stores the configured literal value.
BATTERY_MEAN_SAMPLE_INTERVAL_MS = 20
# Variable: BATTERY_DISPLAY_CYCLE_MS stores the configured literal value.
BATTERY_DISPLAY_CYCLE_MS = 2000
# Variable: BATTERY_LOG_INTERVAL_MS stores the configured literal value.
BATTERY_LOG_INTERVAL_MS = 30000
# Variable: BATTERY_RELEARN_EVERY_MEASUREMENTS stores the configured literal value.
BATTERY_RELEARN_EVERY_MEASUREMENTS = 2000
# Variable: BATTERY_RELEARN_MAX_STEP_V stores the configured literal value.
BATTERY_RELEARN_MAX_STEP_V = 0.05
# Variable: BATTERY_RELEARN_MIN_STEP_V stores the configured literal value.
BATTERY_RELEARN_MIN_STEP_V = 0.05
# Variable: BATTERY_RELEARN_HOLDOFF_MEASUREMENTS stores the configured literal value.
BATTERY_RELEARN_HOLDOFF_MEASUREMENTS = 20
# Maximum number of consecutive inward adjustments per side (min / max)
# without observing a new real extreme on that side. Once a side hits
# this cap it freezes in place until a genuine new min (or max) is
# recorded, which resets that side's counter.
# Variable: BATTERY_RELEARN_MAX_CONSECUTIVE stores the configured literal value.
BATTERY_RELEARN_MAX_CONSECUTIVE = 2
# Variable: BATTERY_MIN_SPAN_V stores the configured literal value.
BATTERY_MIN_SPAN_V = 0.20

# Variable: BATTERY_PERCENT_CURVE stores the collection of values used later in this module.
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

# Variable: BATTERY_HISTORY_MAX_SAMPLES stores the configured literal value.
BATTERY_HISTORY_MAX_SAMPLES = 96
# Variable: BATTERY_HISTORY_MIN_RATE_PCT_PER_H stores the configured literal value.
BATTERY_HISTORY_MIN_RATE_PCT_PER_H = 0.25
# Variable: BATTERY_HISTORY_SAME_MODE_WEIGHT stores the configured literal value.
BATTERY_HISTORY_SAME_MODE_WEIGHT = 2.5
# Variable: BATTERY_HISTORY_BRIGHTNESS_WINDOW stores the configured literal value.
BATTERY_HISTORY_BRIGHTNESS_WINDOW = 20
# Variable: BATTERY_DEFAULT_USAGE_HOURS stores the configured literal value.
BATTERY_DEFAULT_USAGE_HOURS = 1.0
# Variable: BATTERY_DEFAULT_CHARGE_HOURS stores the configured literal value.
BATTERY_DEFAULT_CHARGE_HOURS = 0.5

# Variable: BATTERY_ADC_GPIO stores the configured literal value.
BATTERY_ADC_GPIO = 10
# Variable: BATTERY_ADC_REF_V stores the configured literal value.
BATTERY_ADC_REF_V = 3.3
# Variable: BATTERY_SAMPLES stores the configured literal value.
BATTERY_SAMPLES = 16
# Variable: BATTERY_DIVIDER_R1 stores the configured literal value.
BATTERY_DIVIDER_R1 = 100000
# Variable: BATTERY_DIVIDER_R2 stores the configured literal value.
BATTERY_DIVIDER_R2 = 57000
# Variable: BATTERY_DEFAULT_MIN_V stores the configured literal value.
BATTERY_DEFAULT_MIN_V = 6.2
# Variable: BATTERY_DEFAULT_MAX_V stores the configured literal value.
BATTERY_DEFAULT_MAX_V = 8.0
# Variable: BATTERY_DISPLAY_TOL_V stores the configured literal value.
BATTERY_DISPLAY_TOL_V = 0.12
# Bump this whenever BATTERY_DEFAULT_MIN_V / BATTERY_DEFAULT_MAX_V or
# BATTERY_PERCENT_CURVE change in a way that makes previously learned
# min_v / max_v (and the stored usage/charge history based on them)
# incompatible. On boot, if the stored version differs from this one,
# the calibration will be reset to defaults.
# Variable: BATTERY_CAL_VERSION stores the configured literal value.
BATTERY_CAL_VERSION = 4

# Variable: CHARGE_DETECT_ADC_GPIO stores the configured literal value.
CHARGE_DETECT_ADC_GPIO = 1
# Variable: CHARGE_DETECT_ADC_REF_V stores the configured literal value.
CHARGE_DETECT_ADC_REF_V = 3.3
# Variable: CHARGE_DETECT_SAMPLES stores the configured literal value.
CHARGE_DETECT_SAMPLES = 16
# Variable: CHARGE_DETECT_DIVIDER_R1 stores the configured literal value.
CHARGE_DETECT_DIVIDER_R1 = 270000
# Variable: CHARGE_DETECT_DIVIDER_R2 stores the configured literal value.
CHARGE_DETECT_DIVIDER_R2 = 47000
# Variable: CHARGE_DETECT_NON_CHARGING_V stores the configured literal value.
CHARGE_DETECT_NON_CHARGING_V = 3.0
# Variable: CHARGE_DETECT_CHARGING_MIN_V stores the configured literal value.
CHARGE_DETECT_CHARGING_MIN_V = 4.0
# Variable: CHARGE_DISPLAY_THRESHOLD_V stores the configured literal value.
CHARGE_DISPLAY_THRESHOLD_V = 4.5
# Variable: CHARGE_DETECT_HYSTERESIS_LOW_V stores the configured literal value.
CHARGE_DETECT_HYSTERESIS_LOW_V = 3.0

# Variable: BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S stores the configured literal value.
BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S = 0.2
# Variable: BATTERY_CHARGE_ANIM_INTERVAL_NEAR_FULL_S stores the configured literal value.
BATTERY_CHARGE_ANIM_INTERVAL_NEAR_FULL_S = 0.2
# Variable: BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT stores the configured literal value.
BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT = 90
# Variable: BATTERY_CHARGE_ANIM_FULL_CYCLE_S stores the configured literal value.
BATTERY_CHARGE_ANIM_FULL_CYCLE_S = 0.2
# Variable: BATTERY_CHARGE_LAST_COLUMN_FLASH_MS stores the configured literal value.
BATTERY_CHARGE_LAST_COLUMN_FLASH_MS = 300

# Variable: EDGE_FLASH_ATTACK_MS stores the configured literal value.
EDGE_FLASH_ATTACK_MS = 45
# Variable: EDGE_FLASH_DECAY_MS stores the configured literal value.
EDGE_FLASH_DECAY_MS = 260
# Variable: EDGE_FLASH_TOTAL_MS stores the calculated expression EDGE_FLASH_ATTACK_MS + EDGE_FLASH_DECAY_MS.
EDGE_FLASH_TOTAL_MS = EDGE_FLASH_ATTACK_MS + EDGE_FLASH_DECAY_MS
# Variable: EDGE_FLASH_COLOR stores the collection of values used later in this module.
EDGE_FLASH_COLOR = (0, 120, 255)
