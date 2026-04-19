# ---------------------------------------------------------------------------
# config.py
#
# Central project constants.
#
# This keeps timing, thresholds, filenames, battery math, and mode-specific
# constants in one place so the rest of the code can stay focused on logic.
# ---------------------------------------------------------------------------

import demo_faces

# Main loop polling period in milliseconds.
POLL_PERIOD_MS = 10

# JSON settings file stored on the Pico.
SETTINGS_FILE = "linaboard_settings.json"

# Default face and face count, derived from demo_faces.py.
DEFAULT_FACE = demo_faces.DEFAULT_FACE_INDEX
NUM_FACES = len(demo_faces.FRAMES)

# Face-mode auto-switch timing limits.
DEFAULT_INTERVAL_S = 1.0
INTERVAL_STEP_S = 0.5
INTERVAL_MIN_S = 0.5
INTERVAL_MAX_S = 10.0

# Demo-mode timing defaults.
DEMO_DEFAULT_INTERVAL_S = 5.0
DEMO_DEFAULT_AUTO = True

# Shared user-facing brightness range.
DEFAULT_BRIGHTNESS = 50
BRIGHTNESS_STEP = 10
BRIGHTNESS_MIN = 10
BRIGHTNESS_MAX = 100

# Overlay / hold timing.
FLASH_HOLD_MS = 1000
B6_LONG_PRESS_MS = 700
SPECIAL_COMBO_LONG_PRESS_MS = 2000
BADAPPLE_COMBO_LONG_PRESS_MS = 2000

# Battery display / calibration timing.
BATTERY_REFRESH_MS = 150
BATTERY_DISPLAY_MEAN_WINDOW_MS = 450
BATTERY_DISPLAY_MEAN_SAMPLE_DELAY_MS = 15
BATTERY_DISPLAY_CYCLE_MS = 2000
BATTERY_LOG_INTERVAL_MS = 30000
BATTERY_RELEARN_EVERY_MEASUREMENTS = 1000
BATTERY_RELEARN_MAX_STEP_V = 0.05
BATTERY_RELEARN_MIN_STEP_V = 0.05
BATTERY_RELEARN_HOLDOFF_MEASUREMENTS = 20
BATTERY_MIN_SPAN_V = 0.20

# Nonlinear voltage->percent curve.
#
# The project only measures pack voltage, so percentage is still approximate.
# Instead of a purely linear mapping between learned empty/full voltages, this
# curve shapes the response to better match the flatter middle plateau that Li-
# ion packs typically show. The x values are normalized 0..1 voltage position
# between the learned endpoints and the y values are output percent 0..100.
BATTERY_PERCENT_CURVE = (
    (0.00, 0.0),
    (0.08, 4.0),
    (0.18, 12.0),
    (0.30, 26.0),
    (0.45, 45.0),
    (0.60, 63.0),
    (0.74, 79.0),
    (0.86, 91.0),
    (0.94, 97.0),
    (1.00, 100.0),
)

# Battery runtime estimation / history.
BATTERY_HISTORY_MAX_SAMPLES = 96
BATTERY_HISTORY_MIN_RATE_PCT_PER_H = 0.25
BATTERY_HISTORY_SAME_MODE_WEIGHT = 2.5
BATTERY_HISTORY_BRIGHTNESS_WINDOW = 20

# Battery ADC and divider configuration.
BATTERY_ADC_GPIO = 26
BATTERY_ADC_REF_V = 3.3
BATTERY_SAMPLES = 16
BATTERY_DIVIDER_R1 = 100000
BATTERY_DIVIDER_R2 = 57000
BATTERY_DEFAULT_MIN_V = 6.6
BATTERY_DEFAULT_MAX_V = 8.0
BATTERY_DISPLAY_TOL_V = 0.12

# Optional charge-status input.
# Set CHARGE_STATUS_GPIO to a Pico GPIO wired to the charger status signal.
# Leave as None if no dedicated charge-detect signal is wired.
CHARGE_STATUS_GPIO = None
CHARGE_STATUS_ACTIVE_LOW = True

# Charging animation timing for the battery icon.
# The interval is the time between advancing two adjacent columns.
BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S = 0.50
BATTERY_CHARGE_ANIM_INTERVAL_NEAR_FULL_S = 0.07
BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT = 90
BATTERY_CHARGE_LAST_COLUMN_FLASH_MS = 300

# Edge flash timing and color when a min/max limit is hit.
EDGE_FLASH_ATTACK_MS = 45
EDGE_FLASH_DECAY_MS = 260
EDGE_FLASH_TOTAL_MS = EDGE_FLASH_ATTACK_MS + EDGE_FLASH_DECAY_MS
EDGE_FLASH_COLOR = (0, 120, 255)

# Auto-generated Bad Apple segment module names.
BADAPPLE_PART_MODULES = (
    'badapple_part0', 'badapple_part1', 'badapple_part2', 'badapple_part3',
    'badapple_part4', 'badapple_part5', 'badapple_part6', 'badapple_part7',
    'badapple_part8', 'badapple_part9', 'badapple_part10', 'badapple_part11',
    'badapple_part12', 'badapple_part13', 'badapple_part14', 'badapple_part15',
    'badapple_part16',
)

# Bad Apple palette. White pixels are on, black pixels are off.
BADAPPLE_ON_COLOR = (255, 255, 255)
BADAPPLE_OFF_COLOR = (0, 0, 0)

# Bad Apple brightness is this divisor of the shared UI brightness.
BADAPPLE_BRIGHTNESS_DIVISOR = 2
