# Error handling: Attempts the protected operation so failures can be handled safely.
try:
    # Import: Loads json so this module can use that dependency.
    import ujson as json
# Error handling: Runs this recovery branch when the protected operation fails.
except ImportError:
    # Import: Loads json so this module can use that dependency.
    import json

# Import: Loads SETTINGS_FILE, DEFAULT_INTERVAL_S, DEFAULT_BRIGHTNESS, BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V, INTERVAL_MIN_S, INTERVAL_MAX_S, BRIGHTNESS_MIN, BRIGHTNESS_MAX, BATTERY_RELEARN_HOLDOFF_MEASUREMENTS, BATTERY_CAL_VERSION from config so this module can use that dependency.
from config import (
    SETTINGS_FILE, DEFAULT_INTERVAL_S,
    DEFAULT_BRIGHTNESS, BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V,
    INTERVAL_MIN_S, INTERVAL_MAX_S, BRIGHTNESS_MIN, BRIGHTNESS_MAX,
    BATTERY_RELEARN_HOLDOFF_MEASUREMENTS, BATTERY_CAL_VERSION,
)
# Import: Loads sanitize_history from battery_runtime so this module can use that dependency.
from battery_runtime import sanitize_history

# Function: Defines clamp_interval(value) to handle clamp interval behavior.
def clamp_interval(value):
    # Logic: Branches when value < INTERVAL_MIN_S so the correct firmware path runs.
    if value < INTERVAL_MIN_S:
        # Variable: value stores the current INTERVAL_MIN_S value.
        value = INTERVAL_MIN_S
    # Logic: Branches when value > INTERVAL_MAX_S so the correct firmware path runs.
    elif value > INTERVAL_MAX_S:
        # Variable: value stores the current INTERVAL_MAX_S value.
        value = INTERVAL_MAX_S
    # Return: Sends the calculated expression round(value * 10) / 10.0 back to the caller.
    return round(value * 10) / 10.0

# Function: Defines clamp_brightness(value) to handle clamp brightness behavior.
def clamp_brightness(value):
    # Logic: Branches when value < BRIGHTNESS_MIN so the correct firmware path runs.
    if value < BRIGHTNESS_MIN:
        # Variable: value stores the current BRIGHTNESS_MIN value.
        value = BRIGHTNESS_MIN
    # Logic: Branches when value > BRIGHTNESS_MAX so the correct firmware path runs.
    elif value > BRIGHTNESS_MAX:
        # Variable: value stores the current BRIGHTNESS_MAX value.
        value = BRIGHTNESS_MAX
    # Return: Sends the current value value back to the caller.
    return value

# Function: Defines save_settings(app_state, battery_state) to handle save settings behavior.
def save_settings(app_state, battery_state):
    # Variable: data stores the lookup table used by this module.
    data = {
        "auto": app_state.auto,
        "interval_s": app_state.interval_s,
        "brightness": app_state.brightness,
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
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Resource: Opens managed resources for this block and releases them automatically.
        with open(SETTINGS_FILE, "w") as f:
            # Expression: Calls json.dump() for its side effects.
            json.dump(data, f)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception as e:
        # Expression: Calls print() for its side effects.
        print("save_settings failed:", e)

# Function: Defines load_settings(app_state, battery_state) to handle load settings behavior.
def load_settings(app_state, battery_state):
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Resource: Opens managed resources for this block and releases them automatically.
        with open(SETTINGS_FILE, "r") as f:
            # Variable: data stores the result returned by json.load().
            data = json.load(f)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Return: Sends control back to the caller.
        return
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: app_state.auto stores the result returned by bool().
        app_state.auto = bool(data.get("auto", False))
        # Variable: app_state.interval_s stores the result returned by clamp_interval().
        app_state.interval_s = clamp_interval(float(data.get("interval_s", DEFAULT_INTERVAL_S)))
        # Variable: app_state.brightness stores the result returned by clamp_brightness().
        app_state.brightness = clamp_brightness(int(data.get("brightness", DEFAULT_BRIGHTNESS)))
        # If the stored calibration version doesn't match the current one
        # (e.g. after a firmware update that changed the voltage range or
        # the percent curve), reset all battery calibration fields to
        # defaults so stale learned values don't poison the new curve.
        # Variable: stored_cal_version stores the result returned by data.get().
        stored_cal_version = data.get("battery_cal_version", 0)
        # Logic: Branches when stored_cal_version != BATTERY_CAL_VERSION so the correct firmware path runs.
        if stored_cal_version != BATTERY_CAL_VERSION:
            # Variable: battery_state.min_v stores the current BATTERY_DEFAULT_MIN_V value.
            battery_state.min_v = BATTERY_DEFAULT_MIN_V
            # Variable: battery_state.max_v stores the current BATTERY_DEFAULT_MAX_V value.
            battery_state.max_v = BATTERY_DEFAULT_MAX_V
            # Variable: battery_state.measure_count stores the configured literal value.
            battery_state.measure_count = 0
            # Variable: battery_state.relearn_holdoff_counts stores the current BATTERY_RELEARN_HOLDOFF_MEASUREMENTS value.
            battery_state.relearn_holdoff_counts = BATTERY_RELEARN_HOLDOFF_MEASUREMENTS
            # Variable: battery_state.inward_min_count stores the configured literal value.
            battery_state.inward_min_count = 0
            # Variable: battery_state.inward_max_count stores the configured literal value.
            battery_state.inward_max_count = 0
            # Variable: battery_state.usage_history stores the collection of values used later in this module.
            battery_state.usage_history = []
            # Variable: battery_state.charge_history stores the collection of values used later in this module.
            battery_state.charge_history = []
            # Variable: battery_state.history_last_percent stores the empty sentinel value.
            battery_state.history_last_percent = None
            # Variable: battery_state.charge_history_last_percent stores the empty sentinel value.
            battery_state.charge_history_last_percent = None
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: battery_min_v stores the result returned by float().
            battery_min_v = float(data.get("battery_min_v", BATTERY_DEFAULT_MIN_V))
            # Variable: battery_max_v stores the result returned by float().
            battery_max_v = float(data.get("battery_max_v", BATTERY_DEFAULT_MAX_V))
            # Logic: Branches when battery_min_v < 0.0 so the correct firmware path runs.
            if battery_min_v < 0.0:
                # Variable: battery_min_v stores the current BATTERY_DEFAULT_MIN_V value.
                battery_min_v = BATTERY_DEFAULT_MIN_V
            # Logic: Branches when battery_max_v <= battery_min_v so the correct firmware path runs.
            if battery_max_v <= battery_min_v:
                # Variable: battery_max_v stores the current BATTERY_DEFAULT_MAX_V value.
                battery_max_v = BATTERY_DEFAULT_MAX_V
            # Variable: battery_state.min_v stores the current battery_min_v value.
            battery_state.min_v = battery_min_v
            # Variable: battery_state.max_v stores the current battery_max_v value.
            battery_state.max_v = battery_max_v
            # Variable: measure_count stores the result returned by int().
            measure_count = int(data.get("battery_measure_count", 0))
            # Variable: battery_state.measure_count stores the result returned by max().
            battery_state.measure_count = max(0, measure_count)
            # Variable: holdoff stores the result returned by int().
            holdoff = int(data.get("battery_relearn_holdoff_counts", 0))
            # Variable: battery_state.relearn_holdoff_counts stores the result returned by max().
            battery_state.relearn_holdoff_counts = max(0, min(BATTERY_RELEARN_HOLDOFF_MEASUREMENTS, holdoff))
            # Variable: inward_min stores the result returned by int().
            inward_min = int(data.get("battery_inward_min_count", 0))
            # Variable: battery_state.inward_min_count stores the result returned by max().
            battery_state.inward_min_count = max(0, inward_min)
            # Variable: inward_max stores the result returned by int().
            inward_max = int(data.get("battery_inward_max_count", 0))
            # Variable: battery_state.inward_max_count stores the result returned by max().
            battery_state.inward_max_count = max(0, inward_max)
            # Variable: battery_state.usage_history stores the result returned by sanitize_history().
            battery_state.usage_history = sanitize_history(data.get("battery_usage_history", []))
            # Variable: battery_state.charge_history stores the result returned by sanitize_history().
            battery_state.charge_history = sanitize_history(data.get("battery_charge_history", []))
            # Variable: history_last_percent stores the result returned by data.get().
            history_last_percent = data.get("battery_history_last_percent", None)
            # Variable: battery_state.history_last_percent stores the conditional expression None if history_last_percent is None else max(0.0, min(100.0, float(history_last_perc....
            battery_state.history_last_percent = None if history_last_percent is None else max(0.0, min(100.0, float(history_last_percent)))
            # Variable: charge_last_percent stores the result returned by data.get().
            charge_last_percent = data.get("battery_charge_history_last_percent", None)
            # Variable: battery_state.charge_history_last_percent stores the conditional expression None if charge_last_percent is None else max(0.0, min(100.0, float(charge_last_percen....
            battery_state.charge_history_last_percent = None if charge_last_percent is None else max(0.0, min(100.0, float(charge_last_percent)))
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception as e:
        # Expression: Calls print() for its side effects.
        print("load_settings parse failed:", e)
