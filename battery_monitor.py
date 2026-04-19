import time
from battery_runtime import record_discharge_sample, record_charge_sample
from config import (
    BATTERY_ADC_GPIO, BATTERY_ADC_REF_V, BATTERY_SAMPLES,
    BATTERY_DIVIDER_R1, BATTERY_DIVIDER_R2,
    BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V, BATTERY_DISPLAY_TOL_V,
    BATTERY_LOG_INTERVAL_MS, BATTERY_RELEARN_EVERY_MEASUREMENTS,
    BATTERY_RELEARN_MAX_STEP_V, BATTERY_RELEARN_MIN_STEP_V,
    BATTERY_RELEARN_HOLDOFF_MEASUREMENTS, BATTERY_MIN_SPAN_V,
    BATTERY_PERCENT_CURVE, BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S,
    BATTERY_CHARGE_ANIM_INTERVAL_NEAR_FULL_S, BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT,
    CHARGE_DETECT_ADC_GPIO, CHARGE_DETECT_ADC_REF_V, CHARGE_DETECT_SAMPLES,
    CHARGE_DETECT_DIVIDER_R1, CHARGE_DETECT_DIVIDER_R2,
    CHARGE_DETECT_CHARGING_MIN_V, CHARGE_DETECT_HYSTERESIS_LOW_V,
)
try:
    from machine import ADC
except ImportError:
    ADC = None

class BatteryMonitor:
    __slots__ = ("adc", "charge_adc")
    def __init__(self):
        self.adc = ADC(BATTERY_ADC_GPIO) if ADC is not None else None
        self.charge_adc = ADC(CHARGE_DETECT_ADC_GPIO) if ADC is not None else None
    def _read_adc_voltage(self, adc, ref_v, samples):
        if adc is None:
            return None
        total = 0
        for _ in range(samples):
            total += adc.read_u16()
        raw = total / samples
        return (raw / 65535.0) * ref_v
    def read_voltage(self):
        v_adc = self._read_adc_voltage(self.adc, BATTERY_ADC_REF_V, BATTERY_SAMPLES)
        if v_adc is None:
            return None
        return v_adc * (BATTERY_DIVIDER_R1 + BATTERY_DIVIDER_R2) / BATTERY_DIVIDER_R2
    def read_charge_voltage_adc(self):
        return self._read_adc_voltage(self.charge_adc, CHARGE_DETECT_ADC_REF_V, CHARGE_DETECT_SAMPLES)
    def read_charge_voltage(self):
        v_adc = self.read_charge_voltage_adc()
        if v_adc is None:
            return None
        return v_adc * (CHARGE_DETECT_DIVIDER_R1 + CHARGE_DETECT_DIVIDER_R2) / CHARGE_DETECT_DIVIDER_R2
    def read_voltage_mean(self, window_ms, sample_delay_ms):
        if self.adc is None:
            return None
        start = time.ticks_ms(); total = 0.0; count = 0
        while True:
            v = self.read_voltage()
            if v is not None:
                total += v; count += 1
            now = time.ticks_ms()
            if time.ticks_diff(now, start) >= window_ms:
                break
            if sample_delay_ms > 0:
                time.sleep_ms(sample_delay_ms)
        return None if count <= 0 else total / count
    def read_charge_voltage_mean(self, window_ms, sample_delay_ms):
        _, charge_v = self.read_voltage_pair_mean(window_ms, sample_delay_ms)
        return charge_v

    def read_voltage_pair_mean(self, window_ms, sample_delay_ms):
        if self.adc is None and self.charge_adc is None:
            return (None, None)
        start = time.ticks_ms()
        bat_total = 0.0
        bat_count = 0
        charge_total = 0.0
        charge_count = 0
        while True:
            v_bat = self.read_voltage()
            if v_bat is not None:
                bat_total += v_bat
                bat_count += 1
            v_charge = self.read_charge_voltage()
            if v_charge is not None:
                charge_total += v_charge
                charge_count += 1
            now = time.ticks_ms()
            if time.ticks_diff(now, start) >= window_ms:
                break
            if sample_delay_ms > 0:
                time.sleep_ms(sample_delay_ms)
        mean_bat = None if bat_count <= 0 else (bat_total / bat_count)
        mean_charge = None if charge_count <= 0 else (charge_total / charge_count)
        return (mean_bat, mean_charge)
    @staticmethod
    def inward_adjust_calibration(battery_state):
        min_v = battery_state.min_v + BATTERY_RELEARN_MIN_STEP_V
        max_v = battery_state.max_v - BATTERY_RELEARN_MAX_STEP_V
        if max_v - min_v < BATTERY_MIN_SPAN_V:
            center = (battery_state.min_v + battery_state.max_v) / 2.0
            half = BATTERY_MIN_SPAN_V / 2.0
            min_v = center - half
            max_v = center + half
        battery_state.min_v = min_v
        battery_state.max_v = max_v
        battery_state.relearn_holdoff_counts = BATTERY_RELEARN_HOLDOFF_MEASUREMENTS
    @staticmethod
    def percent_float_from_voltage(v_bat, battery_state):
        if v_bat is None:
            return None
        v_min = battery_state.min_v
        v_max = battery_state.max_v
        if (v_max - v_min) <= 0.01:
            v_min = BATTERY_DEFAULT_MIN_V
            v_max = BATTERY_DEFAULT_MAX_V
        display_min = v_min + BATTERY_DISPLAY_TOL_V
        display_max = v_max - BATTERY_DISPLAY_TOL_V
        if display_max <= display_min:
            display_min = v_min; display_max = v_max
        if v_bat <= display_min:
            return 0.0
        if v_bat >= display_max:
            return 100.0
        x = (v_bat - display_min) / (display_max - display_min)
        prev_x, prev_y = BATTERY_PERCENT_CURVE[0]
        for next_x, next_y in BATTERY_PERCENT_CURVE[1:]:
            if x <= next_x:
                span = next_x - prev_x
                if span <= 0.0:
                    return next_y
                t = (x - prev_x) / span
                return prev_y + ((next_y - prev_y) * t)
            prev_x, prev_y = next_x, next_y
        return BATTERY_PERCENT_CURVE[-1][1]
    def update_calibration(self, battery_state, app_state, save_cb, force=False):
        now = time.ticks_ms()
        if (not force and app_state.battery_next_log_ms and time.ticks_diff(now, app_state.battery_next_log_ms) < 0):
            return False
        v_bat = self.read_voltage()
        charge_v = self.read_charge_voltage()
        previous_charge_v = battery_state.last_charge_voltage
        app_state.battery_next_log_ms = time.ticks_add(now, BATTERY_LOG_INTERVAL_MS)
        if v_bat is None:
            return False
        battery_state.last_voltage = v_bat
        battery_state.last_charge_voltage = charge_v
        changed = False
        percent_float = self.percent_float_from_voltage(v_bat, battery_state)
        charging = self.is_charging_voltage(
            charge_v,
            previous=(previous_charge_v is not None and previous_charge_v >= CHARGE_DETECT_CHARGING_MIN_V),
        )
        dt_h = BATTERY_LOG_INTERVAL_MS / 3600000.0
        if charging:
            if record_charge_sample(battery_state, app_state, percent_float, dt_h):
                changed = True
            if battery_state.history_last_percent is not None:
                battery_state.history_last_percent = percent_float
                changed = True
        else:
            battery_state.measure_count += 1
            if record_discharge_sample(battery_state, app_state, percent_float, dt_h):
                changed = True
            if battery_state.charge_history_last_percent is not None:
                battery_state.charge_history_last_percent = percent_float
                changed = True
            if (battery_state.measure_count % BATTERY_RELEARN_EVERY_MEASUREMENTS) == 0:
                self.inward_adjust_calibration(battery_state)
                changed = True
            if battery_state.relearn_holdoff_counts > 0:
                battery_state.relearn_holdoff_counts -= 1
                changed = True
            else:
                if v_bat < battery_state.min_v:
                    battery_state.min_v = v_bat; changed = True
                if v_bat > battery_state.max_v:
                    battery_state.max_v = v_bat; changed = True
        if changed:
            save_cb()
        print("battery log: current={:.2f} V, charge_ext={:.2f} V, charge_adc={:.2f} V, charging={}, min={:.2f} V, max={:.2f} V, count={}, holdoff={}, use_hist={}, chg_hist={}".format(v_bat, charge_v if charge_v is not None else 0.0, self.read_charge_voltage_adc() if self.charge_adc is not None else 0.0, charging, battery_state.min_v, battery_state.max_v, battery_state.measure_count, battery_state.relearn_holdoff_counts, len(battery_state.usage_history), len(battery_state.charge_history)))
        return True
    @staticmethod
    def percent_from_voltage(v_bat, battery_state):
        pct = BatteryMonitor.percent_float_from_voltage(v_bat, battery_state)
        return None if pct is None else int(round(pct))
    @staticmethod
    def is_charging_voltage(charge_v, previous=False):
        if charge_v is None:
            return bool(previous)
        if charge_v >= CHARGE_DETECT_CHARGING_MIN_V:
            return True
        if charge_v <= CHARGE_DETECT_HYSTERESIS_LOW_V:
            return False
        return bool(previous)
    @staticmethod
    def charge_animation_step_interval_s(percent):
        p = max(0.0, min(float(percent if percent is not None else 0.0), float(BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT)))
        t = p / float(BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT)
        return BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S + ((BATTERY_CHARGE_ANIM_INTERVAL_NEAR_FULL_S - BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S) * t)
    @staticmethod
    def color(percent):
        p = max(0, min(100, int(percent)))
        if p <= 10:
            return (255, 0, 0)
        if p <= 30:
            t = (p - 10) / 20.0
            return (255, int(165 * t), 0)
        if p <= 50:
            t = (p - 30) / 20.0
            return (int(255 * (1.0 - t)), int(165 + (90 * t)), 0)
        return (0, 255, 0)
