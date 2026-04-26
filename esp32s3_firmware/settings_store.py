try:
    import ujson as json
except ImportError:
    import json

from config import (
    SETTINGS_FILE, DEFAULT_INTERVAL_S, DEMO_DEFAULT_INTERVAL_S,
    DEFAULT_BRIGHTNESS, BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V,
    INTERVAL_MIN_S, INTERVAL_MAX_S, BRIGHTNESS_MIN, BRIGHTNESS_MAX,
    BATTERY_RELEARN_HOLDOFF_MEASUREMENTS, BATTERY_CAL_VERSION,
)
from battery_runtime import sanitize_history

def clamp_interval(value):
    if value < INTERVAL_MIN_S:
        value = INTERVAL_MIN_S
    elif value > INTERVAL_MAX_S:
        value = INTERVAL_MAX_S
    return round(value * 10) / 10.0

def clamp_brightness(value):
    if value < BRIGHTNESS_MIN:
        value = BRIGHTNESS_MIN
    elif value > BRIGHTNESS_MAX:
        value = BRIGHTNESS_MAX
    return value

def save_settings(app_state, battery_state):
    data = {
        "auto": app_state.auto,
        "interval_s": app_state.interval_s,
        "brightness": app_state.brightness,
        "demo_auto": app_state.demo_auto,
        "demo_interval_s": app_state.demo_interval_s,
        "battery_cal_version": BATTERY_CAL_VERSION,
        "battery_min_v": battery_state.min_v,
        "battery_max_v": battery_state.max_v,
        "battery_measure_count": battery_state.measure_count,
        "battery_relearn_holdoff_counts": battery_state.relearn_holdoff_counts,
        "battery_inward_min_count": battery_state.inward_min_count,
        "battery_inward_max_count": battery_state.inward_max_count,
        "battery_usage_history": battery_state.usage_history,
        "battery_history_last_percent": battery_state.history_last_percent,
        "battery_charge_history": battery_state.charge_history,
        "battery_charge_history_last_percent": battery_state.charge_history_last_percent,
    }
    try:
        with open(SETTINGS_FILE, "w") as f:
            json.dump(data, f)
    except Exception as e:
        print("save_settings failed:", e)

def load_settings(app_state, battery_state):
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
        # If the stored calibration version doesn't match the current one
        # (e.g. after a firmware update that changed the voltage range or
        # the percent curve), reset all battery calibration fields to
        # defaults so stale learned values don't poison the new curve.
        stored_cal_version = data.get("battery_cal_version", 0)
        if stored_cal_version != BATTERY_CAL_VERSION:
            # Battery calibration reset is intentionally silent on serial.
            battery_state.min_v = BATTERY_DEFAULT_MIN_V
            battery_state.max_v = BATTERY_DEFAULT_MAX_V
            battery_state.measure_count = 0
            battery_state.relearn_holdoff_counts = BATTERY_RELEARN_HOLDOFF_MEASUREMENTS
            battery_state.inward_min_count = 0
            battery_state.inward_max_count = 0
            battery_state.usage_history = []
            battery_state.charge_history = []
            battery_state.history_last_percent = None
            battery_state.charge_history_last_percent = None
        else:
            battery_min_v = float(data.get("battery_min_v", BATTERY_DEFAULT_MIN_V))
            battery_max_v = float(data.get("battery_max_v", BATTERY_DEFAULT_MAX_V))
            if battery_min_v < 0.0:
                battery_min_v = BATTERY_DEFAULT_MIN_V
            if battery_max_v <= battery_min_v:
                battery_max_v = BATTERY_DEFAULT_MAX_V
            battery_state.min_v = battery_min_v
            battery_state.max_v = battery_max_v
            measure_count = int(data.get("battery_measure_count", 0))
            battery_state.measure_count = max(0, measure_count)
            holdoff = int(data.get("battery_relearn_holdoff_counts", 0))
            battery_state.relearn_holdoff_counts = max(0, min(BATTERY_RELEARN_HOLDOFF_MEASUREMENTS, holdoff))
            inward_min = int(data.get("battery_inward_min_count", 0))
            battery_state.inward_min_count = max(0, inward_min)
            inward_max = int(data.get("battery_inward_max_count", 0))
            battery_state.inward_max_count = max(0, inward_max)
            battery_state.usage_history = sanitize_history(data.get("battery_usage_history", []))
            battery_state.charge_history = sanitize_history(data.get("battery_charge_history", []))
            history_last_percent = data.get("battery_history_last_percent", None)
            battery_state.history_last_percent = None if history_last_percent is None else max(0.0, min(100.0, float(history_last_percent)))
            charge_last_percent = data.get("battery_charge_history_last_percent", None)
            battery_state.charge_history_last_percent = None if charge_last_percent is None else max(0.0, min(100.0, float(charge_last_percent)))
    except Exception as e:
        print("load_settings parse failed:", e)