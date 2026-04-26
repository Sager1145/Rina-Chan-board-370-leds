import ujson as json
from config import SETTINGS_FILE, DEFAULT_BRIGHTNESS, DEFAULT_INTERVAL_S
def load_settings():
    try:
        with open(SETTINGS_FILE, 'r') as f:
            data = json.load(f)
            if isinstance(data, dict):
                return data
    except Exception:
        pass
    return {}
def save_settings(data):
    try:
        with open(SETTINGS_FILE, 'w') as f:
            json.dump(data, f)
        return True
    except Exception as e:
        print('save_settings failed:', e)
        return False
def clamp_brightness(v):
    from config import BRIGHTNESS_MIN, BRIGHTNESS_MAX
    return max(BRIGHTNESS_MIN, min(BRIGHTNESS_MAX, int(v)))
def clamp_interval(v):
    from config import INTERVAL_MIN_S, INTERVAL_MAX_S
    return max(INTERVAL_MIN_S, min(INTERVAL_MAX_S, float(v)))
