# Import: Loads BATTERY_HISTORY_MAX_SAMPLES, BATTERY_HISTORY_MIN_RATE_PCT_PER_H, BATTERY_HISTORY_SAME_MODE_WEIGHT, BATTERY_HISTORY_BRIGHTNESS_WINDOW from config so this module can use that dependency.
from config import (
    BATTERY_HISTORY_MAX_SAMPLES,
    BATTERY_HISTORY_MIN_RATE_PCT_PER_H,
    BATTERY_HISTORY_SAME_MODE_WEIGHT,
    BATTERY_HISTORY_BRIGHTNESS_WINDOW,
)

# Only one display mode exists now that matrix demo and Bad Apple are removed.
# Variable: MODE_FACE stores the configured literal value.
MODE_FACE = 0

# Function: Defines current_mode_code(app_state) to handle current mode code behavior.
def current_mode_code(app_state):
    # All modes are now MODE_FACE; kept as a function for history compatibility.
    # Return: Sends the current MODE_FACE value back to the caller.
    return MODE_FACE

# Function: Defines clamp_history_entry(entry) to handle clamp history entry behavior.
def clamp_history_entry(entry):
    # Logic: Branches when not isinstance(entry, (list, tuple)) or len(entry) != 3 so the correct firmware path runs.
    if not isinstance(entry, (list, tuple)) or len(entry) != 3:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: rate stores the result returned by float().
        rate = float(entry[0])
        # Variable: brightness stores the result returned by int().
        brightness = int(entry[1])
        # Variable: mode stores the result returned by int().
        mode = int(entry[2])
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Logic: Branches when rate <= 0.0 so the correct firmware path runs.
    if rate <= 0.0:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Variable: brightness stores the result returned by max().
    brightness = max(0, min(100, brightness))
    # Collapse any legacy mode codes (demo=1, badapple=2) to face mode.
    # Variable: mode stores the current MODE_FACE value.
    mode = MODE_FACE
    # Return: Sends the collection of values used later in this module back to the caller.
    return [rate, brightness, mode]

# Function: Defines sanitize_history(history) to handle sanitize history behavior.
def sanitize_history(history):
    # Logic: Branches when not isinstance(history, list) so the correct firmware path runs.
    if not isinstance(history, list):
        # Return: Sends the collection of values used later in this module back to the caller.
        return []
    # Variable: out stores the collection of values used later in this module.
    out = []
    # Loop: Iterates item over history so each item can be processed.
    for item in history:
        # Variable: clean stores the result returned by clamp_history_entry().
        clean = clamp_history_entry(item)
        # Logic: Branches when clean is not None so the correct firmware path runs.
        if clean is not None:
            # Expression: Calls out.append() for its side effects.
            out.append(clean)
    # Logic: Branches when len(out) > BATTERY_HISTORY_MAX_SAMPLES so the correct firmware path runs.
    if len(out) > BATTERY_HISTORY_MAX_SAMPLES:
        # Variable: out stores the selected item out[-BATTERY_HISTORY_MAX_SAMPLES:].
        out = out[-BATTERY_HISTORY_MAX_SAMPLES:]
    # Return: Sends the current out value back to the caller.
    return out

# Function: Defines _history_distance(entry, brightness, mode) to handle history distance behavior.
def _history_distance(entry, brightness, mode):
    # Variable: _, sample_brightness, sample_mode stores the current entry value.
    _, sample_brightness, sample_mode = entry
    # Variable: mode_penalty stores the conditional expression 2.0 if sample_mode != mode else 0.0.
    mode_penalty = 2.0 if sample_mode != mode else 0.0
    # Variable: bright_penalty stores the calculated expression abs(sample_brightness - brightness) / 100.0.
    bright_penalty = abs(sample_brightness - brightness) / 100.0
    # Return: Sends the calculated expression mode_penalty + bright_penalty back to the caller.
    return mode_penalty + bright_penalty

# Function: Defines trim_history_for_current_context(history, app_state) to handle trim history for current context behavior.
def trim_history_for_current_context(history, app_state):
    # Logic: Branches when len(history) < BATTERY_HISTORY_MAX_SAMPLES so the correct firmware path runs.
    if len(history) < BATTERY_HISTORY_MAX_SAMPLES:
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
    # Variable: brightness stores the result returned by int().
    brightness = int(app_state.brightness)
    # Variable: mode stores the result returned by current_mode_code().
    mode = current_mode_code(app_state)
    # Variable: worst_i stores the configured literal value.
    worst_i = 0
    # Variable: worst_key stores the empty sentinel value.
    worst_key = None
    # Loop: Iterates i, entry over enumerate(history) so each item can be processed.
    for i, entry in enumerate(history):
        # Variable: key stores the collection of values used later in this module.
        key = (_history_distance(entry, brightness, mode), -i)
        # Logic: Branches when worst_key is None or key > worst_key so the correct firmware path runs.
        if worst_key is None or key > worst_key:
            # Variable: worst_key stores the current key value.
            worst_key = key
            # Variable: worst_i stores the current i value.
            worst_i = i
    # Cleanup: Deletes history[...] after it is no longer needed.
    del history[worst_i]
    # Return: Sends the enabled/disabled flag value back to the caller.
    return True

# Function: Defines _record_sample(history, last_percent_attr, battery_state, app_state, percent_float, dt_hours, sign) to handle record sample behavior.
def _record_sample(history, last_percent_attr, battery_state, app_state, percent_float, dt_hours, sign):
    # Variable: changed stores the enabled/disabled flag value.
    changed = False
    # Variable: last_percent stores the result returned by getattr().
    last_percent = getattr(battery_state, last_percent_attr)
    # Logic: Branches when last_percent is not None and dt_hours is not None and dt_hours > 0.0 and percent_floa... so the correct firmware path runs.
    if last_percent is not None and dt_hours is not None and dt_hours > 0.0 and percent_float is not None:
        # Variable: delta_pct stores the calculated expression (last_percent - percent_float) * sign.
        delta_pct = (last_percent - percent_float) * sign
        # Logic: Branches when delta_pct > 0.0 so the correct firmware path runs.
        if delta_pct > 0.0:
            # Variable: rate stores the calculated expression delta_pct / dt_hours.
            rate = delta_pct / dt_hours
            # Logic: Branches when rate >= BATTERY_HISTORY_MIN_RATE_PCT_PER_H so the correct firmware path runs.
            if rate >= BATTERY_HISTORY_MIN_RATE_PCT_PER_H:
                # Logic: Branches when trim_history_for_current_context(history, app_state) so the correct firmware path runs.
                if trim_history_for_current_context(history, app_state):
                    # Variable: changed stores the enabled/disabled flag value.
                    changed = True
                # Expression: Calls history.append() for its side effects.
                history.append([rate, int(app_state.brightness), current_mode_code(app_state)])
                # Variable: changed stores the enabled/disabled flag value.
                changed = True
    # Logic: Branches when last_percent != percent_float so the correct firmware path runs.
    if last_percent != percent_float:
        # Expression: Calls setattr() for its side effects.
        setattr(battery_state, last_percent_attr, percent_float)
        # Variable: changed stores the enabled/disabled flag value.
        changed = True
    # Return: Sends the current changed value back to the caller.
    return changed

# Function: Defines record_discharge_sample(battery_state, app_state, percent_float, dt_hours) to handle record discharge sample behavior.
def record_discharge_sample(battery_state, app_state, percent_float, dt_hours):
    # Return: Sends the result returned by _record_sample() back to the caller.
    return _record_sample(battery_state.usage_history, 'history_last_percent', battery_state, app_state, percent_float, dt_hours, +1.0)

# Function: Defines record_charge_sample(battery_state, app_state, percent_float, dt_hours) to handle record charge sample behavior.
def record_charge_sample(battery_state, app_state, percent_float, dt_hours):
    # Return: Sends the result returned by _record_sample() back to the caller.
    return _record_sample(battery_state.charge_history, 'charge_history_last_percent', battery_state, app_state, percent_float, dt_hours, -1.0)

# Function: Defines _weighted_average_rate(entries, brightness, mode) to handle weighted average rate behavior.
def _weighted_average_rate(entries, brightness, mode):
    # Logic: Branches when not entries so the correct firmware path runs.
    if not entries:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Variable: total_w stores the configured literal value.
    total_w = 0.0
    # Variable: total_rate stores the configured literal value.
    total_rate = 0.0
    # Variable: n stores the result returned by len().
    n = len(entries)
    # Loop: Iterates i, rate, sample_brightness, sample_mode over enumerate(entries) so each item can be processed.
    for i, (rate, sample_brightness, sample_mode) in enumerate(entries):
        # Logic: Branches when rate < BATTERY_HISTORY_MIN_RATE_PCT_PER_H so the correct firmware path runs.
        if rate < BATTERY_HISTORY_MIN_RATE_PCT_PER_H:
            # Control: Skips to the next loop iteration after this case is handled.
            continue
        # Variable: recency_w stores the calculated expression 1.0 + (i / float(n)).
        recency_w = 1.0 + (i / float(n))
        # Variable: mode_w stores the conditional expression BATTERY_HISTORY_SAME_MODE_WEIGHT if sample_mode == mode else 1.0.
        mode_w = BATTERY_HISTORY_SAME_MODE_WEIGHT if sample_mode == mode else 1.0
        # Variable: bright_delta stores the result returned by abs().
        bright_delta = abs(sample_brightness - brightness)
        # Variable: bright_w stores the calculated expression 1.0 / (1.0 + (bright_delta / float(BATTERY_HISTORY_BRIGHTNESS_WINDOW))).
        bright_w = 1.0 / (1.0 + (bright_delta / float(BATTERY_HISTORY_BRIGHTNESS_WINDOW)))
        # Variable: w stores the calculated expression recency_w * mode_w * bright_w.
        w = recency_w * mode_w * bright_w
        # Variable: Updates total_w in place using the current w value.
        total_w += w
        # Variable: Updates total_rate in place using the calculated expression rate * w.
        total_rate += rate * w
    # Logic: Branches when total_w <= 0.0 so the correct firmware path runs.
    if total_w <= 0.0:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Return: Sends the calculated expression total_rate / total_w back to the caller.
    return total_rate / total_w

# Function: Defines _estimate_from_history(history, app_state, percent_float, inverse) to handle estimate from history behavior.
def _estimate_from_history(history, app_state, percent_float, inverse=False):
    # Logic: Branches when percent_float is None so the correct firmware path runs.
    if percent_float is None:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Variable: history stores the combined condition history or [].
    history = history or []
    # Logic: Branches when not history so the correct firmware path runs.
    if not history:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Variable: brightness stores the result returned by int().
    brightness = int(app_state.brightness)
    # Variable: mode stores the result returned by current_mode_code().
    mode = current_mode_code(app_state)
    # Variable: same_mode stores the expression [entry for entry in history if entry[2] == mode].
    same_mode = [entry for entry in history if entry[2] == mode]
    # Variable: avg_rate stores the result returned by _weighted_average_rate().
    avg_rate = _weighted_average_rate(same_mode if len(same_mode) >= 3 else history, brightness, mode)
    # Logic: Branches when avg_rate is None or avg_rate < BATTERY_HISTORY_MIN_RATE_PCT_PER_H so the correct firmware path runs.
    if avg_rate is None or avg_rate < BATTERY_HISTORY_MIN_RATE_PCT_PER_H:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Logic: Branches when inverse so the correct firmware path runs.
    if inverse:
        # Variable: remaining stores the calculated expression 100.0 - max(0.0, min(100.0, percent_float)).
        remaining = 100.0 - max(0.0, min(100.0, percent_float))
    # Logic: Runs this fallback branch when the earlier condition did not match.
    else:
        # Variable: remaining stores the result returned by max().
        remaining = max(0.0, min(100.0, percent_float))
    # Return: Sends the calculated expression remaining / avg_rate back to the caller.
    return remaining / avg_rate

# Function: Defines estimate_remaining_hours(battery_state, app_state, percent_float) to handle estimate remaining hours behavior.
def estimate_remaining_hours(battery_state, app_state, percent_float):
    # Logic: Branches when percent_float is None or percent_float <= 0.0 so the correct firmware path runs.
    if percent_float is None or percent_float <= 0.0:
        # Return: Sends the configured literal value back to the caller.
        return 0.0
    # Return: Sends the result returned by _estimate_from_history() back to the caller.
    return _estimate_from_history(battery_state.usage_history, app_state, percent_float, inverse=False)

# Function: Defines estimate_charge_hours(battery_state, app_state, percent_float) to handle estimate charge hours behavior.
def estimate_charge_hours(battery_state, app_state, percent_float):
    # Logic: Branches when percent_float is None so the correct firmware path runs.
    if percent_float is None:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Logic: Branches when percent_float >= 100.0 so the correct firmware path runs.
    if percent_float >= 100.0:
        # Return: Sends the configured literal value back to the caller.
        return 0.0
    # Return: Sends the result returned by _estimate_from_history() back to the caller.
    return _estimate_from_history(battery_state.charge_history, app_state, percent_float, inverse=True)
