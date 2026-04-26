# Lightweight serial logger for RinaChanBoard ESP32-S3 MicroPython.
# Levels: 0=off, 1=error, 2=warn, 3=info, 4=debug, 5=trace.
import time
try:
    import gc
except Exception:
    gc = None

try:
    from config import LOG_LEVEL, LOG_INCLUDE_FREE_MEM, LOG_RATE_LIMIT_DEFAULT_MS
except Exception:
    LOG_LEVEL = 4
    LOG_INCLUDE_FREE_MEM = True
    LOG_RATE_LIMIT_DEFAULT_MS = 0

_LEVEL_NAMES = {1: 'ERR', 2: 'WARN', 3: 'INFO', 4: 'DBG', 5: 'TRACE'}
_last_by_key = {}


def ticks_ms():
    try:
        return time.ticks_ms()
    except Exception:
        try:
            return int(time.time() * 1000)
        except Exception:
            return 0


def ticks_diff(a, b):
    try:
        return time.ticks_diff(a, b)
    except Exception:
        return a - b


def _fmt_value(v):
    try:
        if isinstance(v, float):
            return '{:.3f}'.format(v)
    except Exception:
        pass
    try:
        s = str(v)
    except Exception:
        s = '<unprintable>'
    if len(s) > 120:
        return s[:117] + '...'
    return s


def enabled(level):
    return int(LOG_LEVEL) >= int(level)


def log(level, comp, event, **kv):
    if not enabled(level):
        return
    ms = ticks_ms()
    parts = ['[{:>8} ms]'.format(ms), '[{}]'.format(_LEVEL_NAMES.get(level, str(level))), '[{}]'.format(comp), str(event)]
    for k in sorted(kv.keys()):
        parts.append('{}={}'.format(k, _fmt_value(kv[k])))
    if LOG_INCLUDE_FREE_MEM and gc is not None:
        try:
            parts.append('free={}'.format(gc.mem_free()))
        except Exception:
            pass
    try:
        print(' '.join(parts))
    except Exception:
        pass


def error(comp, event, **kv):
    log(1, comp, event, **kv)


def warn(comp, event, **kv):
    log(2, comp, event, **kv)


def info(comp, event, **kv):
    log(3, comp, event, **kv)


def debug(comp, event, **kv):
    log(4, comp, event, **kv)


def trace(comp, event, **kv):
    log(5, comp, event, **kv)


def every(key, period_ms=None):
    if period_ms is None:
        period_ms = LOG_RATE_LIMIT_DEFAULT_MS
    period_ms = int(period_ms or 0)
    if period_ms <= 0:
        return True
    now = ticks_ms()
    last = _last_by_key.get(key)
    if last is None or ticks_diff(now, last) >= period_ms:
        _last_by_key[key] = now
        return True
    return False


def exception(comp, event, exc):
    error(comp, event, err=exc)
    try:
        import sys
        sys.print_exception(exc)
    except Exception:
        pass
