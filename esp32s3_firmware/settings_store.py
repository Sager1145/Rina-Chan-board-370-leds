import ujson as json
from config import SETTINGS_FILE, DEFAULT_BRIGHTNESS, DEFAULT_INTERVAL_S
import logger as log


def load_settings():
    try:
        with open(SETTINGS_FILE, 'r') as f:
            data = json.load(f)
            if isinstance(data, dict):
                log.info('SETTINGS', 'load ok', file=SETTINGS_FILE, keys=len(data))
                return data
            log.warn('SETTINGS', 'load ignored non-dict', file=SETTINGS_FILE)
    except Exception as e:
        log.warn('SETTINGS', 'load default', file=SETTINGS_FILE, err=e)
    return {}


def save_settings(data):
    try:
        with open(SETTINGS_FILE, 'w') as f:
            json.dump(data, f)
        log.info('SETTINGS', 'save ok', file=SETTINGS_FILE, keys=len(data) if isinstance(data, dict) else -1)
        return True
    except Exception as e:
        log.exception('SETTINGS', 'save failed', e)
        return False


def clamp_brightness(v):
    from config import BRIGHTNESS_MIN, BRIGHTNESS_MAX
    out = max(BRIGHTNESS_MIN, min(BRIGHTNESS_MAX, int(v)))
    if out != int(v):
        log.debug('SETTINGS', 'brightness clamped', in_value=v, out_value=out)
    return out


def clamp_interval(v):
    from config import INTERVAL_MIN_S, INTERVAL_MAX_S
    out = max(INTERVAL_MIN_S, min(INTERVAL_MAX_S, float(v)))
    if out != float(v):
        log.debug('SETTINGS', 'interval clamped', in_value=v, out_value=out)
    return out
