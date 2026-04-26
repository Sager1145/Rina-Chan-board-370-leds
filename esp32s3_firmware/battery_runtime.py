from config import (
    BATTERY_HISTORY_MAX_SAMPLES,
    BATTERY_HISTORY_MIN_RATE_PCT_PER_H,
    BATTERY_HISTORY_SAME_MODE_WEIGHT,
    BATTERY_HISTORY_BRIGHTNESS_WINDOW,
)
MODE_FACE = 0
MODE_DEMO = 1
MODE_BADAPPLE = 2
def current_mode_code(app_state):
    if app_state.badapple_mode:
        return MODE_BADAPPLE
    if app_state.special_demo_mode:
        return MODE_DEMO
    return MODE_FACE
def clamp_history_entry(entry):
    if not isinstance(entry, (list, tuple)) or len(entry) != 3:
        return None
    try:
        rate = float(entry[0])
        brightness = int(entry[1])
        mode = int(entry[2])
    except Exception:
        return None
    if rate <= 0.0:
        return None
    brightness = max(0, min(100, brightness))
    if mode not in (MODE_FACE, MODE_DEMO, MODE_BADAPPLE):
        mode = MODE_FACE
    return [rate, brightness, mode]
def sanitize_history(history):
    if not isinstance(history, list):
        return []
    out = []
    for item in history:
        clean = clamp_history_entry(item)
        if clean is not None:
            out.append(clean)
    if len(out) > BATTERY_HISTORY_MAX_SAMPLES:
        out = out[-BATTERY_HISTORY_MAX_SAMPLES:]
    return out
def _history_distance(entry, brightness, mode):
    _, sample_brightness, sample_mode = entry
    mode_penalty = 2.0 if sample_mode != mode else 0.0
    bright_penalty = abs(sample_brightness - brightness) / 100.0
    return mode_penalty + bright_penalty
def trim_history_for_current_context(history, app_state):
    if len(history) < BATTERY_HISTORY_MAX_SAMPLES:
        return False
    brightness = int(app_state.brightness)
    mode = current_mode_code(app_state)
    worst_i = 0
    worst_key = None
    for i, entry in enumerate(history):
        key = (_history_distance(entry, brightness, mode), -i)
        if worst_key is None or key > worst_key:
            worst_key = key
            worst_i = i
    del history[worst_i]
    return True
def _record_sample(history, last_percent_attr, battery_state, app_state, percent_float, dt_hours, sign):
    changed = False
    last_percent = getattr(battery_state, last_percent_attr)
    if last_percent is not None and dt_hours is not None and dt_hours > 0.0 and percent_float is not None:
        delta_pct = (last_percent - percent_float) * sign
        if delta_pct > 0.0:
            rate = delta_pct / dt_hours
            if rate >= BATTERY_HISTORY_MIN_RATE_PCT_PER_H:
                if trim_history_for_current_context(history, app_state):
                    changed = True
                history.append([rate, int(app_state.brightness), current_mode_code(app_state)])
                changed = True
    if last_percent != percent_float:
        setattr(battery_state, last_percent_attr, percent_float)
        changed = True
    return changed
def record_discharge_sample(battery_state, app_state, percent_float, dt_hours):
    return _record_sample(battery_state.usage_history, 'history_last_percent', battery_state, app_state, percent_float, dt_hours, +1.0)
def record_charge_sample(battery_state, app_state, percent_float, dt_hours):
    return _record_sample(battery_state.charge_history, 'charge_history_last_percent', battery_state, app_state, percent_float, dt_hours, -1.0)
def _weighted_average_rate(entries, brightness, mode):
    if not entries:
        return None
    total_w = 0.0
    total_rate = 0.0
    n = len(entries)
    for i, (rate, sample_brightness, sample_mode) in enumerate(entries):
        if rate < BATTERY_HISTORY_MIN_RATE_PCT_PER_H:
            continue
        recency_w = 1.0 + (i / float(n))
        mode_w = BATTERY_HISTORY_SAME_MODE_WEIGHT if sample_mode == mode else 1.0
        bright_delta = abs(sample_brightness - brightness)
        bright_w = 1.0 / (1.0 + (bright_delta / float(BATTERY_HISTORY_BRIGHTNESS_WINDOW)))
        w = recency_w * mode_w * bright_w
        total_w += w
        total_rate += rate * w
    if total_w <= 0.0:
        return None
    return total_rate / total_w
def _estimate_from_history(history, app_state, percent_float, inverse=False):
    if percent_float is None:
        return None
    history = history or []
    if not history:
        return None
    brightness = int(app_state.brightness)
    mode = current_mode_code(app_state)
    same_mode = [entry for entry in history if entry[2] == mode]
    avg_rate = _weighted_average_rate(same_mode if len(same_mode) >= 3 else history, brightness, mode)
    if avg_rate is None or avg_rate < BATTERY_HISTORY_MIN_RATE_PCT_PER_H:
        return None
    if inverse:
        remaining = 100.0 - max(0.0, min(100.0, percent_float))
    else:
        remaining = max(0.0, min(100.0, percent_float))
    return remaining / avg_rate
def estimate_remaining_hours(battery_state, app_state, percent_float):
    if percent_float is None or percent_float <= 0.0:
        return 0.0
    return _estimate_from_history(battery_state.usage_history, app_state, percent_float, inverse=False)
def estimate_charge_hours(battery_state, app_state, percent_float):
    if percent_float is None:
        return None
    if percent_float >= 100.0:
        return 0.0
    return _estimate_from_history(battery_state.charge_history, app_state, percent_float, inverse=True)
