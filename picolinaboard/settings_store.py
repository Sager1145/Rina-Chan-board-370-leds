# ---------------------------------------------------------------------------
# settings_store.py
#
# Load and save persistent settings to the Pico filesystem.
#
# This file keeps JSON and validation logic out of main.py.
# Saved values survive reboots.
# ---------------------------------------------------------------------------

# ujson is preferred on MicroPython because it is smaller / faster.
try:
    import ujson as json
except ImportError:
    import json

from config import (
    SETTINGS_FILE, DEFAULT_INTERVAL_S, DEMO_DEFAULT_INTERVAL_S,
    DEFAULT_BRIGHTNESS, BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V,
    INTERVAL_MIN_S, INTERVAL_MAX_S, BRIGHTNESS_MIN, BRIGHTNESS_MAX,
    BATTERY_RELEARN_HOLDOFF_MEASUREMENTS,
)
from battery_runtime import sanitize_history


def clamp_interval(value):
    # Clamp face/demo interval into supported range and keep 0.1 s resolution.
    if value < INTERVAL_MIN_S:
        value = INTERVAL_MIN_S
    elif value > INTERVAL_MAX_S:
        value = INTERVAL_MAX_S
    return round(value * 10) / 10.0


def clamp_brightness(value):
    # Clamp shared brightness into supported 10..100 range.
    if value < BRIGHTNESS_MIN:
        value = BRIGHTNESS_MIN
    elif value > BRIGHTNESS_MAX:
        value = BRIGHTNESS_MAX
    return value


def save_settings(app_state, battery_state):
    # -----------------------------------------------------------------------
    # Save all persistent state to the JSON file.
    # Only user-configurable or learned values go here.
    # -----------------------------------------------------------------------
    data = {
        "auto": app_state.auto,
        "interval_s": app_state.interval_s,
        "brightness": app_state.brightness,
        "demo_auto": app_state.demo_auto,
        "demo_interval_s": app_state.demo_interval_s,
        "battery_min_v": battery_state.min_v,
        "battery_max_v": battery_state.max_v,
        "battery_measure_count": battery_state.measure_count,
        "battery_relearn_holdoff_counts": battery_state.relearn_holdoff_counts,
        "battery_usage_history": battery_state.usage_history,
        "battery_history_last_percent": battery_state.history_last_percent,
    }
    try:
        with open(SETTINGS_FILE, "w") as f:
            json.dump(data, f)
    except Exception as e:
        print("save_settings failed:", e)


def load_settings(app_state, battery_state):
    # -----------------------------------------------------------------------
    # Load the JSON settings file if it exists.
    # Values are validated and clamped before being applied.
    # -----------------------------------------------------------------------
    try:
        with open(SETTINGS_FILE, "r") as f:
            data = json.load(f)
    except Exception:
        return

    try:
        app_state.auto = bool(data.get("auto", False))
        app_state.interval_s = clamp_interval(float(data.get("interval_s", DEFAULT_INTERVAL_S)))
        app_state.brightness = clamp_brightness(int(data.get("brightness", DEFAULT_BRIGHTNESS)))
        app_state.demo_auto = bool(data.get("demo_auto", True))
        app_state.demo_interval_s = clamp_interval(float(data.get("demo_interval_s", DEMO_DEFAULT_INTERVAL_S)))
        battery_min_v = float(data.get("battery_min_v", BATTERY_DEFAULT_MIN_V))
        battery_max_v = float(data.get("battery_max_v", BATTERY_DEFAULT_MAX_V))
        if battery_min_v < 0.0:
            battery_min_v = BATTERY_DEFAULT_MIN_V
        if battery_max_v <= battery_min_v:
            battery_max_v = BATTERY_DEFAULT_MAX_V
        battery_state.min_v = battery_min_v
        battery_state.max_v = battery_max_v

        measure_count = int(data.get("battery_measure_count", 0))
        if measure_count < 0:
            measure_count = 0
        battery_state.measure_count = measure_count

        holdoff = int(data.get("battery_relearn_holdoff_counts", 0))
        if holdoff < 0:
            holdoff = 0
        elif holdoff > BATTERY_RELEARN_HOLDOFF_MEASUREMENTS:
            holdoff = BATTERY_RELEARN_HOLDOFF_MEASUREMENTS
        battery_state.relearn_holdoff_counts = holdoff

        battery_state.usage_history = sanitize_history(data.get("battery_usage_history", []))

        history_last_percent = data.get("battery_history_last_percent", None)
        if history_last_percent is None:
            battery_state.history_last_percent = None
        else:
            history_last_percent = float(history_last_percent)
            if history_last_percent < 0.0:
                history_last_percent = 0.0
            elif history_last_percent > 100.0:
                history_last_percent = 100.0
            battery_state.history_last_percent = history_last_percent
    except Exception as e:
        print("load_settings parse failed:", e)
