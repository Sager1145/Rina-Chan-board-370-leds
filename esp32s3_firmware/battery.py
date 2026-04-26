import time
try:
    from machine import ADC, Pin
except Exception:
    ADC = None
    Pin = None

from config import *


def _ticks_ms():
    return time.ticks_ms() if hasattr(time, 'ticks_ms') else int(time.time() * 1000)


def _ticks_diff(a, b):
    return time.ticks_diff(a, b) if hasattr(time, 'ticks_diff') else (a - b)


def _interp_percent(x):
    prev_x, prev_y = BATTERY_PERCENT_CURVE[0]
    for nx, ny in BATTERY_PERCENT_CURVE[1:]:
        if x <= nx:
            span = nx - prev_x
            if span <= 0:
                return ny
            t = (x - prev_x) / span
            return prev_y + (ny - prev_y) * t
        prev_x, prev_y = nx, ny
    return BATTERY_PERCENT_CURVE[-1][1]


def percent_from_voltage(v, min_v, max_v):
    if v is None:
        return None
    if max_v - min_v <= 0.01:
        min_v = BATTERY_DEFAULT_MIN_V
        max_v = BATTERY_DEFAULT_MAX_V
    dmin = min_v + BATTERY_DISPLAY_TOL_V
    dmax = max_v - BATTERY_DISPLAY_TOL_V
    if dmax <= dmin:
        dmin = min_v
        dmax = max_v
    if v <= dmin:
        return 0.0
    if v >= dmax:
        return 100.0
    return _interp_percent((v - dmin) / (dmax - dmin))


def battery_color(percent):
    if percent is None:
        return BLUE
    p = float(percent)
    # Full red at 10%, full orange at 30%, still green at 50%.
    if p <= 10:
        return RED
    if p < 30:
        t = (p - 10.0) / 20.0
        return (int(RED[0] + (ORANGE[0] - RED[0]) * t), int(RED[1] + (ORANGE[1] - RED[1]) * t), 0)
    if p < 50:
        t = (p - 30.0) / 20.0
        return (int(ORANGE[0] + (GREEN[0] - ORANGE[0]) * t), int(ORANGE[1] + (GREEN[1] - ORANGE[1]) * t), int(ORANGE[2] + (GREEN[2] - ORANGE[2]) * t))
    return GREEN


class BatteryMonitor:
    def __init__(self, state=None):
        self.state = state if state is not None else {}
        self.adc = self._make_adc(BATT_ADC_PIN)
        self.chg_adc = self._make_adc(CHG_ADC_PIN)
        self.min_v = float(self.state.get('battery_min_v', BATTERY_DEFAULT_MIN_V))
        self.max_v = float(self.state.get('battery_max_v', BATTERY_DEFAULT_MAX_V))
        if int(self.state.get('battery_cal_version', 0)) != BATTERY_CAL_VERSION:
            self.min_v = BATTERY_DEFAULT_MIN_V
            self.max_v = BATTERY_DEFAULT_MAX_V
        self.measure_count = int(self.state.get('battery_measure_count', 0))
        self.inward_min_count = int(self.state.get('battery_inward_min_count', 0))
        self.inward_max_count = int(self.state.get('battery_inward_max_count', 0))
        self.usage_history = self.state.get('battery_usage_history', []) or []
        self.charge_history = self.state.get('battery_charge_history', []) or []
        self.history_last_percent = self.state.get('battery_history_last_percent', None)
        self.charge_history_last_percent = self.state.get('battery_charge_history_last_percent', None)
        now = _ticks_ms()
        self.mean_window_started_ms = now
        self.mean_next_sample_ms = now
        self.mean_battery_total = 0.0
        self.mean_battery_count = 0
        self.mean_charge_total = 0.0
        self.mean_charge_count = 0
        self.last_mean_battery_voltage = None
        self.last_mean_charge_voltage = None
        self.last_charging = False
        self.last_log_ms = now

    def _make_adc(self, gpio):
        if ADC is None:
            return None
        try:
            adc = ADC(Pin(gpio))
        except Exception:
            try:
                adc = ADC(gpio)
            except Exception as e:
                print('ADC init failed on GPIO', gpio, e)
                return None
        try:
            adc.atten(ADC.ATTN_11DB)
        except Exception:
            pass
        try:
            adc.width(ADC.WIDTH_12BIT)
        except Exception:
            pass
        return adc

    def _read_adc_voltage(self, adc, ref_v, samples):
        if adc is None:
            return None
        count = int(samples)
        try:
            read_uv = adc.read_uv
        except AttributeError:
            read_uv = None
        if read_uv is not None:
            total_uv = 0
            ok = 0
            for _ in range(count):
                try:
                    total_uv += read_uv()
                    ok += 1
                except Exception:
                    ok = 0
                    break
            if ok:
                return (total_uv / ok) / 1000000.0
        total = 0
        for _ in range(count):
            try:
                total += adc.read_u16()
            except AttributeError:
                total += adc.read() * 16
        raw = total / count
        return (raw / 65535.0) * ref_v

    def read_battery_voltage(self):
        v = self._read_adc_voltage(self.adc, BATTERY_ADC_REF_V, BATTERY_SAMPLES)
        if v is None:
            return None
        return v * (BATTERY_DIVIDER_R1 + BATTERY_DIVIDER_R2) / BATTERY_DIVIDER_R2

    def read_charge_voltage(self):
        v = self._read_adc_voltage(self.chg_adc, CHARGE_DETECT_ADC_REF_V, CHARGE_DETECT_SAMPLES)
        if v is None:
            return None
        return v * (CHARGE_DETECT_DIVIDER_R1 + CHARGE_DETECT_DIVIDER_R2) / CHARGE_DETECT_DIVIDER_R2

    def service_mean_sampler(self, force=False):
        now = _ticks_ms()
        updated = False
        if _ticks_diff(now, self.mean_window_started_ms) >= BATTERY_MEAN_UPDATE_MS:
            self.last_mean_battery_voltage = None if self.mean_battery_count <= 0 else self.mean_battery_total / self.mean_battery_count
            self.last_mean_charge_voltage = None if self.mean_charge_count <= 0 else self.mean_charge_total / self.mean_charge_count
            self.mean_battery_total = 0.0
            self.mean_charge_total = 0.0
            self.mean_battery_count = 0
            self.mean_charge_count = 0
            self.mean_window_started_ms = now
            updated = True
        if (not force) and _ticks_diff(now, self.mean_next_sample_ms) < 0:
            return updated
        vb = self.read_battery_voltage()
        vc = self.read_charge_voltage()
        if vb is not None:
            self.mean_battery_total += vb
            self.mean_battery_count += 1
        if vc is not None:
            self.mean_charge_total += vc
            self.mean_charge_count += 1
        self.mean_next_sample_ms = time.ticks_add(now, BATTERY_MEAN_SAMPLE_INTERVAL_MS) if hasattr(time, 'ticks_add') else now + BATTERY_MEAN_SAMPLE_INTERVAL_MS
        return updated

    def get_mean_pair(self, allow_partial=True):
        vb = self.last_mean_battery_voltage
        vc = self.last_mean_charge_voltage
        if allow_partial:
            if vb is None and self.mean_battery_count:
                vb = self.mean_battery_total / self.mean_battery_count
            if vc is None and self.mean_charge_count:
                vc = self.mean_charge_total / self.mean_charge_count
        return vb, vc

    def is_charging_voltage(self, charge_v=None, previous=None):
        if charge_v is None:
            _, charge_v = self.get_mean_pair(True)
        if charge_v is None:
            return False
        if previous is None:
            previous = self.last_charging
        if previous:
            return charge_v >= CHARGE_DETECT_HYSTERESIS_LOW_V
        return charge_v >= CHARGE_DETECT_CHARGING_MIN_V

    def percent(self):
        vb, _ = self.get_mean_pair(True)
        return percent_from_voltage(vb, self.min_v, self.max_v)

    def update_learning_and_history(self):
        vb, vc = self.get_mean_pair(True)
        if vb is None:
            return False
        pct = percent_from_voltage(vb, self.min_v, self.max_v)
        charging = self.is_charging_voltage(vc)
        self.last_charging = charging
        self.measure_count += 1
        changed = False
        if vb > self.max_v:
            self.max_v = vb
            self.inward_max_count = 0
            changed = True
        if vb < self.min_v:
            self.min_v = vb
            self.inward_min_count = 0
            changed = True
        if self.measure_count % BATTERY_RELEARN_EVERY_MEASUREMENTS == 0:
            if (not charging) and self.inward_max_count < BATTERY_RELEARN_MAX_CONSECUTIVE:
                new_max = max(vb, self.max_v - BATTERY_RELEARN_MAX_STEP_V)
                if new_max > self.min_v + BATTERY_MIN_SPAN_V and new_max < self.max_v:
                    self.max_v = new_max
                    self.inward_max_count += 1
                    changed = True
            if charging and self.inward_min_count < BATTERY_RELEARN_MAX_CONSECUTIVE:
                new_min = min(vb, self.min_v + BATTERY_RELEARN_MIN_STEP_V)
                if new_min < self.max_v - BATTERY_MIN_SPAN_V and new_min > self.min_v:
                    self.min_v = new_min
                    self.inward_min_count += 1
                    changed = True
        now = _ticks_ms()
        if pct is not None and _ticks_diff(now, self.last_log_ms) >= 30000:
            hist = self.charge_history if charging else self.usage_history
            hist.append([now, round(float(pct), 2)])
            while len(hist) > BATTERY_HISTORY_MAX_SAMPLES:
                hist.pop(0)
            if charging:
                self.charge_history_last_percent = pct
            else:
                self.history_last_percent = pct
            self.last_log_ms = now
            changed = True
        return changed

    def estimate_hours(self, charging=False):
        hist = self.charge_history if charging else self.usage_history
        if len(hist) >= 2:
            t0, p0 = hist[0]
            t1, p1 = hist[-1]
            dt_h = max(0.001, (t1 - t0) / 3600000.0)
            dp = (p1 - p0) if charging else (p0 - p1)
            rate = dp / dt_h
            if rate >= BATTERY_HISTORY_MIN_RATE_PCT_PER_H:
                pct = self.percent()
                if pct is not None:
                    target = 100.0 - pct if charging else pct
                    return max(0.0, target / rate)
        return BATTERY_DEFAULT_CHARGE_HOURS if charging else BATTERY_DEFAULT_USAGE_HOURS

    def snapshot(self):
        self.service_mean_sampler()
        vb, vc = self.get_mean_pair(True)
        charging = self.is_charging_voltage(vc)
        pct = percent_from_voltage(vb, self.min_v, self.max_v)
        return {
            'battery_voltage': vb,
            'charge_voltage': vc,
            'charging': charging,
            'percent': None if pct is None else round(pct, 1),
            'min_v': self.min_v,
            'max_v': self.max_v,
            'measure_count': self.measure_count,
            'estimated_hours': self.estimate_hours(charging),
        }

    def export_state(self):
        return {
            'battery_cal_version': BATTERY_CAL_VERSION,
            'battery_min_v': self.min_v,
            'battery_max_v': self.max_v,
            'battery_measure_count': self.measure_count,
            'battery_inward_min_count': self.inward_min_count,
            'battery_inward_max_count': self.inward_max_count,
            'battery_usage_history': self.usage_history,
            'battery_history_last_percent': self.history_last_percent,
            'battery_charge_history': self.charge_history,
            'battery_charge_history_last_percent': self.charge_history_last_percent,
        }
