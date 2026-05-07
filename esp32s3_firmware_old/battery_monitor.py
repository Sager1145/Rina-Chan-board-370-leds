# Import: Loads time so this module can use that dependency.
import time
# Import: Loads record_discharge_sample, record_charge_sample from battery_runtime so this module can use that dependency.
from battery_runtime import record_discharge_sample, record_charge_sample
# Import: Loads BATTERY_ADC_GPIO, BATTERY_ADC_REF_V, BATTERY_SAMPLES, BATTERY_DIVIDER_R1, BATTERY_DIVIDER_R2, BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V, BATTERY_DISPLAY_TOL_V, BATTERY_LOG_INTERVAL_MS, BATTERY_RELEARN_EVERY_MEASUREMENTS, BATTERY_RELEARN_MAX_STEP_V, BATTERY_RELEARN_MIN_STEP_V, BATTERY_RELEARN_HOLDOFF_MEASUREMENTS, BATTERY_MIN_SPAN_V, BATTERY_PERCENT_CURVE, BATTERY_CHARGE_ANIM_FULL_CYCLE_S, BATTERY_MEAN_UPDATE_MS, BATTERY_MEAN_SAMPLE_INTERVAL_MS, CHARGE_DETECT_ADC_GPIO, CHARGE_DETECT_ADC_REF_V, CHARGE_DETECT_SAMPLES, CHARGE_DETECT_DIVIDER_R1, CHARGE_DETECT_DIVIDER_R2, CHARGE_DETECT_CHARGING_MIN_V, CHARGE_DETECT_HYSTERESIS_LOW_V from config so this module can use that dependency.
from config import (
    BATTERY_ADC_GPIO, BATTERY_ADC_REF_V, BATTERY_SAMPLES,
    BATTERY_DIVIDER_R1, BATTERY_DIVIDER_R2,
    BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V, BATTERY_DISPLAY_TOL_V,
    BATTERY_LOG_INTERVAL_MS, BATTERY_RELEARN_EVERY_MEASUREMENTS,
    BATTERY_RELEARN_MAX_STEP_V, BATTERY_RELEARN_MIN_STEP_V,
    BATTERY_RELEARN_HOLDOFF_MEASUREMENTS, BATTERY_MIN_SPAN_V,
    BATTERY_PERCENT_CURVE, BATTERY_CHARGE_ANIM_FULL_CYCLE_S,
    BATTERY_MEAN_UPDATE_MS, BATTERY_MEAN_SAMPLE_INTERVAL_MS,
    CHARGE_DETECT_ADC_GPIO, CHARGE_DETECT_ADC_REF_V, CHARGE_DETECT_SAMPLES,
    CHARGE_DETECT_DIVIDER_R1, CHARGE_DETECT_DIVIDER_R2,
    CHARGE_DETECT_CHARGING_MIN_V, CHARGE_DETECT_HYSTERESIS_LOW_V,
)
# Error handling: Attempts the protected operation so failures can be handled safely.
try:
    # Import: Loads ADC, Pin from machine so this module can use that dependency.
    from machine import ADC, Pin
# Error handling: Runs this recovery branch when the protected operation fails.
except ImportError:
    # Variable: ADC stores the empty sentinel value.
    ADC = None
    # Variable: Pin stores the empty sentinel value.
    Pin = None

# ESP32-S3 ADC compatibility helper.  MicroPython accepts ADC(Pin(gpio))
# on ESP32-class ports.  If attenuation APIs exist, use the widest 11 dB
# range so voltage-divider outputs up to the 3.3 V domain do not clip at
# the default low ADC range.
# Function: Defines _make_adc(gpio) to handle make adc behavior.
def _make_adc(gpio):
    # Logic: Branches when ADC is None so the correct firmware path runs.
    if ADC is None:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: adc stores the conditional expression ADC(Pin(int(gpio))) if Pin is not None else ADC(int(gpio)).
        adc = ADC(Pin(int(gpio))) if Pin is not None else ADC(int(gpio))
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: adc stores the result returned by ADC().
        adc = ADC(int(gpio))
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Expression: Calls adc.atten() for its side effects.
        adc.atten(ADC.ATTN_11DB)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Control: Leaves this branch intentionally empty.
        pass
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Expression: Calls adc.width() for its side effects.
        adc.width(ADC.WIDTH_12BIT)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Control: Leaves this branch intentionally empty.
        pass
    # Return: Sends the current adc value back to the caller.
    return adc

# Class: Defines BatteryMonitor as the state and behavior container for Battery Monitor.
class BatteryMonitor:
    # Variable: __slots__ stores the collection of values used later in this module.
    __slots__ = (
        "adc", "charge_adc",
        "mean_window_started_ms", "mean_next_sample_ms",
        "mean_battery_total", "mean_battery_count",
        "mean_charge_total", "mean_charge_count",
        "last_mean_battery_voltage", "last_mean_charge_voltage",
        "last_mean_completed_ms",
    )
    # Function: Defines __init__(self) to handle init behavior.
    def __init__(self):
        # Variable: self.adc stores the result returned by _make_adc().
        self.adc = _make_adc(BATTERY_ADC_GPIO)
        # Variable: self.charge_adc stores the result returned by _make_adc().
        self.charge_adc = _make_adc(CHARGE_DETECT_ADC_GPIO)
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Variable: self.mean_window_started_ms stores the current now value.
        self.mean_window_started_ms = now
        # Variable: self.mean_next_sample_ms stores the current now value.
        self.mean_next_sample_ms = now
        # Variable: self.mean_battery_total stores the configured literal value.
        self.mean_battery_total = 0.0
        # Variable: self.mean_battery_count stores the configured literal value.
        self.mean_battery_count = 0
        # Variable: self.mean_charge_total stores the configured literal value.
        self.mean_charge_total = 0.0
        # Variable: self.mean_charge_count stores the configured literal value.
        self.mean_charge_count = 0
        # Variable: self.last_mean_battery_voltage stores the empty sentinel value.
        self.last_mean_battery_voltage = None
        # Variable: self.last_mean_charge_voltage stores the empty sentinel value.
        self.last_mean_charge_voltage = None
        # Variable: self.last_mean_completed_ms stores the configured literal value.
        self.last_mean_completed_ms = 0
    # Function: Defines _read_adc_voltage(self, adc, ref_v, samples) to handle read adc voltage behavior.
    def _read_adc_voltage(self, adc, ref_v, samples):
        # Logic: Branches when adc is None so the correct firmware path runs.
        if adc is None:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Variable: total stores the configured literal value.
        total = 0
        # Loop: Iterates _ over range(samples) so each item can be processed.
        for _ in range(samples):
            # Variable: Updates total in place using the result returned by adc.read_u16().
            total += adc.read_u16()
        # Variable: raw stores the calculated expression total / samples.
        raw = total / samples
        # Return: Sends the calculated expression (raw / 65535.0) * ref_v back to the caller.
        return (raw / 65535.0) * ref_v
    # Function: Defines read_voltage(self) to handle read voltage behavior.
    def read_voltage(self):
        # Variable: v_adc stores the result returned by self._read_adc_voltage().
        v_adc = self._read_adc_voltage(self.adc, BATTERY_ADC_REF_V, BATTERY_SAMPLES)
        # Logic: Branches when v_adc is None so the correct firmware path runs.
        if v_adc is None:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Return: Sends the calculated expression v_adc * (BATTERY_DIVIDER_R1 + BATTERY_DIVIDER_R2) / BATTERY_DIVIDER_R2 back to the caller.
        return v_adc * (BATTERY_DIVIDER_R1 + BATTERY_DIVIDER_R2) / BATTERY_DIVIDER_R2
    # Function: Defines read_charge_voltage_adc(self) to handle read charge voltage adc behavior.
    def read_charge_voltage_adc(self):
        # Return: Sends the result returned by self._read_adc_voltage() back to the caller.
        return self._read_adc_voltage(self.charge_adc, CHARGE_DETECT_ADC_REF_V, CHARGE_DETECT_SAMPLES)
    # Function: Defines read_charge_voltage(self) to handle read charge voltage behavior.
    def read_charge_voltage(self):
        # Variable: v_adc stores the result returned by self.read_charge_voltage_adc().
        v_adc = self.read_charge_voltage_adc()
        # Logic: Branches when v_adc is None so the correct firmware path runs.
        if v_adc is None:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Return: Sends the calculated expression v_adc * (CHARGE_DETECT_DIVIDER_R1 + CHARGE_DETECT_DIVIDER_R2) / CHARGE_DETECT_DIVIDER_R2 back to the caller.
        return v_adc * (CHARGE_DETECT_DIVIDER_R1 + CHARGE_DETECT_DIVIDER_R2) / CHARGE_DETECT_DIVIDER_R2
    # Function: Defines reset_mean_sampler(self, preserve_last) to handle reset mean sampler behavior.
    def reset_mean_sampler(self, preserve_last=True):
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Variable: self.mean_window_started_ms stores the current now value.
        self.mean_window_started_ms = now
        # Variable: self.mean_next_sample_ms stores the current now value.
        self.mean_next_sample_ms = now
        # Variable: self.mean_battery_total stores the configured literal value.
        self.mean_battery_total = 0.0
        # Variable: self.mean_battery_count stores the configured literal value.
        self.mean_battery_count = 0
        # Variable: self.mean_charge_total stores the configured literal value.
        self.mean_charge_total = 0.0
        # Variable: self.mean_charge_count stores the configured literal value.
        self.mean_charge_count = 0
        # Logic: Branches when not preserve_last so the correct firmware path runs.
        if not preserve_last:
            # Variable: self.last_mean_battery_voltage stores the empty sentinel value.
            self.last_mean_battery_voltage = None
            # Variable: self.last_mean_charge_voltage stores the empty sentinel value.
            self.last_mean_charge_voltage = None
            # Variable: self.last_mean_completed_ms stores the configured literal value.
            self.last_mean_completed_ms = 0

    # Function: Defines _finalize_mean_window(self, now) to handle finalize mean window behavior.
    def _finalize_mean_window(self, now=None):
        # Logic: Branches when now is None so the correct firmware path runs.
        if now is None:
            # Variable: now stores the result returned by time.ticks_ms().
            now = time.ticks_ms()
        # Variable: self.last_mean_battery_voltage stores the conditional expression None if self.mean_battery_count <= 0 else (self.mean_battery_total / self.mean_batter....
        self.last_mean_battery_voltage = None if self.mean_battery_count <= 0 else (self.mean_battery_total / self.mean_battery_count)
        # Variable: self.last_mean_charge_voltage stores the conditional expression None if self.mean_charge_count <= 0 else (self.mean_charge_total / self.mean_charge_c....
        self.last_mean_charge_voltage = None if self.mean_charge_count <= 0 else (self.mean_charge_total / self.mean_charge_count)
        # Variable: self.last_mean_completed_ms stores the current now value.
        self.last_mean_completed_ms = now
        # Variable: self.mean_window_started_ms stores the current now value.
        self.mean_window_started_ms = now
        # Variable: self.mean_next_sample_ms stores the current now value.
        self.mean_next_sample_ms = now
        # Variable: self.mean_battery_total stores the configured literal value.
        self.mean_battery_total = 0.0
        # Variable: self.mean_battery_count stores the configured literal value.
        self.mean_battery_count = 0
        # Variable: self.mean_charge_total stores the configured literal value.
        self.mean_charge_total = 0.0
        # Variable: self.mean_charge_count stores the configured literal value.
        self.mean_charge_count = 0

    # Function: Defines service_mean_sampler(self, force_sample) to handle service mean sampler behavior.
    def service_mean_sampler(self, force_sample=False):
        # Logic: Branches when self.adc is None and self.charge_adc is None so the correct firmware path runs.
        if self.adc is None and self.charge_adc is None:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Variable: mean_updated stores the enabled/disabled flag value.
        mean_updated = False
        # Logic: Branches when time.ticks_diff(now, self.mean_window_started_ms) >= BATTERY_MEAN_UPDATE_MS so the correct firmware path runs.
        if time.ticks_diff(now, self.mean_window_started_ms) >= BATTERY_MEAN_UPDATE_MS:
            # Expression: Calls self._finalize_mean_window() for its side effects.
            self._finalize_mean_window(now=now)
            # Variable: mean_updated stores the enabled/disabled flag value.
            mean_updated = True
            # Variable: now stores the result returned by time.ticks_ms().
            now = time.ticks_ms()

        # Logic: Branches when (not force_sample) and time.ticks_diff(now, self.mean_next_sample_ms) < 0 so the correct firmware path runs.
        if (not force_sample) and time.ticks_diff(now, self.mean_next_sample_ms) < 0:
            # Return: Sends the current mean_updated value back to the caller.
            return mean_updated

        # Variable: v_bat stores the result returned by self.read_voltage().
        v_bat = self.read_voltage()
        # Logic: Branches when v_bat is not None so the correct firmware path runs.
        if v_bat is not None:
            # Variable: Updates self.mean_battery_total in place using the current v_bat value.
            self.mean_battery_total += v_bat
            # Variable: Updates self.mean_battery_count in place using the configured literal value.
            self.mean_battery_count += 1
        # Variable: v_charge stores the result returned by self.read_charge_voltage().
        v_charge = self.read_charge_voltage()
        # Logic: Branches when v_charge is not None so the correct firmware path runs.
        if v_charge is not None:
            # Variable: Updates self.mean_charge_total in place using the current v_charge value.
            self.mean_charge_total += v_charge
            # Variable: Updates self.mean_charge_count in place using the configured literal value.
            self.mean_charge_count += 1

        # Variable: self.mean_next_sample_ms stores the result returned by time.ticks_add().
        self.mean_next_sample_ms = time.ticks_add(now, BATTERY_MEAN_SAMPLE_INTERVAL_MS)
        # Return: Sends the current mean_updated value back to the caller.
        return mean_updated

    # Function: Defines get_mean_voltage_pair(self, allow_partial) to handle get mean voltage pair behavior.
    def get_mean_voltage_pair(self, allow_partial=True):
        # Variable: v_bat stores the referenced self.last_mean_battery_voltage value.
        v_bat = self.last_mean_battery_voltage
        # Variable: charge_v stores the referenced self.last_mean_charge_voltage value.
        charge_v = self.last_mean_charge_voltage
        # Logic: Branches when allow_partial so the correct firmware path runs.
        if allow_partial:
            # Logic: Branches when v_bat is None and self.mean_battery_count > 0 so the correct firmware path runs.
            if v_bat is None and self.mean_battery_count > 0:
                # Variable: v_bat stores the calculated expression self.mean_battery_total / self.mean_battery_count.
                v_bat = self.mean_battery_total / self.mean_battery_count
            # Logic: Branches when charge_v is None and self.mean_charge_count > 0 so the correct firmware path runs.
            if charge_v is None and self.mean_charge_count > 0:
                # Variable: charge_v stores the calculated expression self.mean_charge_total / self.mean_charge_count.
                charge_v = self.mean_charge_total / self.mean_charge_count
        # Return: Sends the collection of values used later in this module back to the caller.
        return (v_bat, charge_v)

    # Function: Defines read_voltage_mean(self, window_ms, sample_delay_ms) to handle read voltage mean behavior.
    def read_voltage_mean(self, window_ms, sample_delay_ms):
        # Logic: Branches when self.adc is None so the correct firmware path runs.
        if self.adc is None:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Variable: count stores the configured literal value.
        # Variable: total stores the configured literal value.
        # Variable: start stores the result returned by time.ticks_ms().
        start = time.ticks_ms(); total = 0.0; count = 0
        # Loop: Repeats while True remains true.
        while True:
            # Variable: v stores the result returned by self.read_voltage().
            v = self.read_voltage()
            # Logic: Branches when v is not None so the correct firmware path runs.
            if v is not None:
                # Variable: Updates count in place using the configured literal value.
                # Variable: Updates total in place using the current v value.
                total += v; count += 1
            # Variable: now stores the result returned by time.ticks_ms().
            now = time.ticks_ms()
            # Logic: Branches when time.ticks_diff(now, start) >= window_ms so the correct firmware path runs.
            if time.ticks_diff(now, start) >= window_ms:
                # Control: Stops the loop once the required condition has been met.
                break
            # Logic: Branches when sample_delay_ms > 0 so the correct firmware path runs.
            if sample_delay_ms > 0:
                # Expression: Calls time.sleep_ms() for its side effects.
                time.sleep_ms(sample_delay_ms)
        # Return: Sends the conditional expression None if count <= 0 else total / count back to the caller.
        return None if count <= 0 else total / count
    # Function: Defines read_charge_voltage_mean(self, window_ms, sample_delay_ms) to handle read charge voltage mean behavior.
    def read_charge_voltage_mean(self, window_ms, sample_delay_ms):
        # Variable: _, charge_v stores the result returned by self.read_voltage_pair_mean().
        _, charge_v = self.read_voltage_pair_mean(window_ms, sample_delay_ms)
        # Return: Sends the current charge_v value back to the caller.
        return charge_v

    # Function: Defines read_voltage_pair_mean(self, window_ms, sample_delay_ms) to handle read voltage pair mean behavior.
    def read_voltage_pair_mean(self, window_ms, sample_delay_ms):
        # Logic: Branches when self.adc is None and self.charge_adc is None so the correct firmware path runs.
        if self.adc is None and self.charge_adc is None:
            # Return: Sends the collection of values used later in this module back to the caller.
            return (None, None)
        # Variable: start stores the result returned by time.ticks_ms().
        start = time.ticks_ms()
        # Variable: bat_total stores the configured literal value.
        bat_total = 0.0
        # Variable: bat_count stores the configured literal value.
        bat_count = 0
        # Variable: charge_total stores the configured literal value.
        charge_total = 0.0
        # Variable: charge_count stores the configured literal value.
        charge_count = 0
        # Loop: Repeats while True remains true.
        while True:
            # Variable: v_bat stores the result returned by self.read_voltage().
            v_bat = self.read_voltage()
            # Logic: Branches when v_bat is not None so the correct firmware path runs.
            if v_bat is not None:
                # Variable: Updates bat_total in place using the current v_bat value.
                bat_total += v_bat
                # Variable: Updates bat_count in place using the configured literal value.
                bat_count += 1
            # Variable: v_charge stores the result returned by self.read_charge_voltage().
            v_charge = self.read_charge_voltage()
            # Logic: Branches when v_charge is not None so the correct firmware path runs.
            if v_charge is not None:
                # Variable: Updates charge_total in place using the current v_charge value.
                charge_total += v_charge
                # Variable: Updates charge_count in place using the configured literal value.
                charge_count += 1
            # Variable: now stores the result returned by time.ticks_ms().
            now = time.ticks_ms()
            # Logic: Branches when time.ticks_diff(now, start) >= window_ms so the correct firmware path runs.
            if time.ticks_diff(now, start) >= window_ms:
                # Control: Stops the loop once the required condition has been met.
                break
            # Logic: Branches when sample_delay_ms > 0 so the correct firmware path runs.
            if sample_delay_ms > 0:
                # Expression: Calls time.sleep_ms() for its side effects.
                time.sleep_ms(sample_delay_ms)
        # Variable: mean_bat stores the conditional expression None if bat_count <= 0 else (bat_total / bat_count).
        mean_bat = None if bat_count <= 0 else (bat_total / bat_count)
        # Variable: mean_charge stores the conditional expression None if charge_count <= 0 else (charge_total / charge_count).
        mean_charge = None if charge_count <= 0 else (charge_total / charge_count)
        # Return: Sends the collection of values used later in this module back to the caller.
        return (mean_bat, mean_charge)
    # Function: Defines inward_adjust_calibration(battery_state) to handle inward adjust calibration behavior.
    @staticmethod
    def inward_adjust_calibration(battery_state):
        # Variable: min_v stores the calculated expression battery_state.min_v + BATTERY_RELEARN_MIN_STEP_V.
        min_v = battery_state.min_v + BATTERY_RELEARN_MIN_STEP_V
        # Variable: max_v stores the calculated expression battery_state.max_v - BATTERY_RELEARN_MAX_STEP_V.
        max_v = battery_state.max_v - BATTERY_RELEARN_MAX_STEP_V
        # Logic: Branches when max_v - min_v < BATTERY_MIN_SPAN_V so the correct firmware path runs.
        if max_v - min_v < BATTERY_MIN_SPAN_V:
            # Variable: center stores the calculated expression (battery_state.min_v + battery_state.max_v) / 2.0.
            center = (battery_state.min_v + battery_state.max_v) / 2.0
            # Variable: half stores the calculated expression BATTERY_MIN_SPAN_V / 2.0.
            half = BATTERY_MIN_SPAN_V / 2.0
            # Variable: min_v stores the calculated expression center - half.
            min_v = center - half
            # Variable: max_v stores the calculated expression center + half.
            max_v = center + half
        # Variable: battery_state.min_v stores the current min_v value.
        battery_state.min_v = min_v
        # Variable: battery_state.max_v stores the current max_v value.
        battery_state.max_v = max_v
        # Variable: battery_state.relearn_holdoff_counts stores the current BATTERY_RELEARN_HOLDOFF_MEASUREMENTS value.
        battery_state.relearn_holdoff_counts = BATTERY_RELEARN_HOLDOFF_MEASUREMENTS
    # Function: Defines percent_float_from_voltage(v_bat, battery_state) to handle percent float from voltage behavior.
    @staticmethod
    def percent_float_from_voltage(v_bat, battery_state):
        # Logic: Branches when v_bat is None so the correct firmware path runs.
        if v_bat is None:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Variable: v_min stores the referenced battery_state.min_v value.
        v_min = battery_state.min_v
        # Variable: v_max stores the referenced battery_state.max_v value.
        v_max = battery_state.max_v
        # Logic: Branches when (v_max - v_min) <= 0.01 so the correct firmware path runs.
        if (v_max - v_min) <= 0.01:
            # Variable: v_min stores the current BATTERY_DEFAULT_MIN_V value.
            v_min = BATTERY_DEFAULT_MIN_V
            # Variable: v_max stores the current BATTERY_DEFAULT_MAX_V value.
            v_max = BATTERY_DEFAULT_MAX_V
        # Variable: display_min stores the calculated expression v_min + BATTERY_DISPLAY_TOL_V.
        display_min = v_min + BATTERY_DISPLAY_TOL_V
        # Variable: display_max stores the calculated expression v_max - BATTERY_DISPLAY_TOL_V.
        display_max = v_max - BATTERY_DISPLAY_TOL_V
        # Logic: Branches when display_max <= display_min so the correct firmware path runs.
        if display_max <= display_min:
            # Variable: display_max stores the current v_max value.
            # Variable: display_min stores the current v_min value.
            display_min = v_min; display_max = v_max
        # Logic: Branches when v_bat <= display_min so the correct firmware path runs.
        if v_bat <= display_min:
            # Return: Sends the configured literal value back to the caller.
            return 0.0
        # Logic: Branches when v_bat >= display_max so the correct firmware path runs.
        if v_bat >= display_max:
            # Return: Sends the configured literal value back to the caller.
            return 100.0
        # Variable: x stores the calculated expression (v_bat - display_min) / (display_max - display_min).
        x = (v_bat - display_min) / (display_max - display_min)
        # Variable: prev_x, prev_y stores the selected item BATTERY_PERCENT_CURVE[0].
        prev_x, prev_y = BATTERY_PERCENT_CURVE[0]
        # Loop: Iterates next_x, next_y over BATTERY_PERCENT_CURVE[1:] so each item can be processed.
        for next_x, next_y in BATTERY_PERCENT_CURVE[1:]:
            # Logic: Branches when x <= next_x so the correct firmware path runs.
            if x <= next_x:
                # Variable: span stores the calculated expression next_x - prev_x.
                span = next_x - prev_x
                # Logic: Branches when span <= 0.0 so the correct firmware path runs.
                if span <= 0.0:
                    # Return: Sends the current next_y value back to the caller.
                    return next_y
                # Variable: t stores the calculated expression (x - prev_x) / span.
                t = (x - prev_x) / span
                # Return: Sends the calculated expression prev_y + ((next_y - prev_y) * t) back to the caller.
                return prev_y + ((next_y - prev_y) * t)
            # Variable: prev_x, prev_y stores the collection of values used later in this module.
            prev_x, prev_y = next_x, next_y
        # Return: Sends the selected item BATTERY_PERCENT_CURVE[-1][1] back to the caller.
        return BATTERY_PERCENT_CURVE[-1][1]
    # Function: Defines update_calibration(self, battery_state, app_state, save_cb, force) to handle update calibration behavior.
    def update_calibration(self, battery_state, app_state, save_cb, force=False):
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Logic: Branches when not force and app_state.battery_next_log_ms and time.ticks_diff(now, app_state.batter... so the correct firmware path runs.
        if (not force and app_state.battery_next_log_ms and time.ticks_diff(now, app_state.battery_next_log_ms) < 0):
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Expression: Calls self.service_mean_sampler() for its side effects.
        self.service_mean_sampler()
        # Variable: v_bat, charge_v stores the result returned by self.get_mean_voltage_pair().
        v_bat, charge_v = self.get_mean_voltage_pair(allow_partial=True)
        # Logic: Branches when v_bat is None so the correct firmware path runs.
        if v_bat is None:
            # Variable: v_bat stores the result returned by self.read_voltage().
            v_bat = self.read_voltage()
        # Logic: Branches when charge_v is None so the correct firmware path runs.
        if charge_v is None:
            # Variable: charge_v stores the result returned by self.read_charge_voltage().
            charge_v = self.read_charge_voltage()
        # Variable: previous_charge_v stores the referenced battery_state.last_charge_voltage value.
        previous_charge_v = battery_state.last_charge_voltage
        # Variable: app_state.battery_next_log_ms stores the result returned by time.ticks_add().
        app_state.battery_next_log_ms = time.ticks_add(now, BATTERY_LOG_INTERVAL_MS)
        # Logic: Branches when v_bat is None so the correct firmware path runs.
        if v_bat is None:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Variable: battery_state.last_voltage stores the current v_bat value.
        battery_state.last_voltage = v_bat
        # Variable: battery_state.last_charge_voltage stores the current charge_v value.
        battery_state.last_charge_voltage = charge_v
        # Variable: changed stores the enabled/disabled flag value.
        changed = False
        # Variable: percent_float stores the result returned by self.percent_float_from_voltage().
        percent_float = self.percent_float_from_voltage(v_bat, battery_state)
        # Variable: charging stores the result returned by self.is_charging_voltage().
        charging = self.is_charging_voltage(
            charge_v,
            previous=(previous_charge_v is not None and previous_charge_v > CHARGE_DETECT_CHARGING_MIN_V),
        )
        # Variable: dt_h stores the calculated expression BATTERY_LOG_INTERVAL_MS / 3600000.0.
        dt_h = BATTERY_LOG_INTERVAL_MS / 3600000.0
        # Logic: Branches when charging so the correct firmware path runs.
        if charging:
            # Logic: Branches when record_charge_sample(battery_state, app_state, percent_float, dt_h) so the correct firmware path runs.
            if record_charge_sample(battery_state, app_state, percent_float, dt_h):
                # Variable: changed stores the enabled/disabled flag value.
                changed = True
            # Logic: Branches when battery_state.history_last_percent is not None so the correct firmware path runs.
            if battery_state.history_last_percent is not None:
                # Variable: battery_state.history_last_percent stores the current percent_float value.
                battery_state.history_last_percent = percent_float
                # Variable: changed stores the enabled/disabled flag value.
                changed = True
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: Updates battery_state.measure_count in place using the configured literal value.
            battery_state.measure_count += 1
            # Logic: Branches when record_discharge_sample(battery_state, app_state, percent_float, dt_h) so the correct firmware path runs.
            if record_discharge_sample(battery_state, app_state, percent_float, dt_h):
                # Variable: changed stores the enabled/disabled flag value.
                changed = True
            # Logic: Branches when battery_state.charge_history_last_percent is not None so the correct firmware path runs.
            if battery_state.charge_history_last_percent is not None:
                # Variable: battery_state.charge_history_last_percent stores the current percent_float value.
                battery_state.charge_history_last_percent = percent_float
                # Variable: changed stores the enabled/disabled flag value.
                changed = True
            # Logic: Branches when (battery_state.measure_count % BATTERY_RELEARN_EVERY_MEASUREMENTS) == 0 so the correct firmware path runs.
            if (battery_state.measure_count % BATTERY_RELEARN_EVERY_MEASUREMENTS) == 0:
                # Expression: Calls self.inward_adjust_calibration() for its side effects.
                self.inward_adjust_calibration(battery_state)
                # Variable: changed stores the enabled/disabled flag value.
                changed = True
            # Logic: Branches when battery_state.relearn_holdoff_counts > 0 so the correct firmware path runs.
            if battery_state.relearn_holdoff_counts > 0:
                # Variable: Updates battery_state.relearn_holdoff_counts in place using the configured literal value.
                battery_state.relearn_holdoff_counts -= 1
                # Variable: changed stores the enabled/disabled flag value.
                changed = True
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Logic: Branches when v_bat < battery_state.min_v so the correct firmware path runs.
                if v_bat < battery_state.min_v:
                    # Variable: changed stores the enabled/disabled flag value.
                    # Variable: battery_state.min_v stores the current v_bat value.
                    battery_state.min_v = v_bat; changed = True
                # Logic: Branches when v_bat > battery_state.max_v so the correct firmware path runs.
                if v_bat > battery_state.max_v:
                    # Variable: changed stores the enabled/disabled flag value.
                    # Variable: battery_state.max_v stores the current v_bat value.
                    battery_state.max_v = v_bat; changed = True
        # Logic: Branches when changed so the correct firmware path runs.
        if changed:
            # Expression: Calls save_cb() for its side effects.
            save_cb()
        # Battery serial log disabled; keep UART output focused on WebUI/network diagnostics.
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True
    # Function: Defines percent_from_voltage(v_bat, battery_state) to handle percent from voltage behavior.
    @staticmethod
    def percent_from_voltage(v_bat, battery_state):
        # Variable: pct stores the result returned by BatteryMonitor.percent_float_from_voltage().
        pct = BatteryMonitor.percent_float_from_voltage(v_bat, battery_state)
        # Return: Sends the conditional expression None if pct is None else int(round(pct)) back to the caller.
        return None if pct is None else int(round(pct))
    # Function: Defines is_charging_voltage(charge_v, previous) to handle is charging voltage behavior.
    @staticmethod
    def is_charging_voltage(charge_v, previous=False):
        # Logic: Branches when charge_v is None so the correct firmware path runs.
        if charge_v is None:
            # Return: Sends the result returned by bool() back to the caller.
            return bool(previous)
        # Strictly above CHARGE_DETECT_CHARGING_MIN_V -> charging.
        # At or below CHARGE_DETECT_HYSTERESIS_LOW_V -> not charging.
        # In between: hold the previous state to prevent flicker near the edge.
        # Logic: Branches when charge_v > CHARGE_DETECT_CHARGING_MIN_V so the correct firmware path runs.
        if charge_v > CHARGE_DETECT_CHARGING_MIN_V:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when charge_v <= CHARGE_DETECT_HYSTERESIS_LOW_V so the correct firmware path runs.
        if charge_v <= CHARGE_DETECT_HYSTERESIS_LOW_V:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Return: Sends the result returned by bool() back to the caller.
        return bool(previous)
    # Function: Defines charge_animation_step_interval_s(percent) to handle charge animation step interval s behavior.
    @staticmethod
    def charge_animation_step_interval_s(percent):
        # Return: Sends the current BATTERY_CHARGE_ANIM_FULL_CYCLE_S value back to the caller.
        return BATTERY_CHARGE_ANIM_FULL_CYCLE_S
    # Function: Defines color(percent) to handle color behavior.
    @staticmethod
    def color(percent):
        # Variable: p stores the result returned by max().
        p = max(0, min(100, int(percent)))
        # Logic: Branches when p <= 10 so the correct firmware path runs.
        if p <= 10:
            # Return: Sends the collection of values used later in this module back to the caller.
            return (255, 0, 0)
        # Logic: Branches when p <= 30 so the correct firmware path runs.
        if p <= 30:
            # Variable: t stores the calculated expression (p - 10) / 20.0.
            t = (p - 10) / 20.0
            # Return: Sends the collection of values used later in this module back to the caller.
            return (255, int(165 * t), 0)
        # Logic: Branches when p <= 50 so the correct firmware path runs.
        if p <= 50:
            # Variable: t stores the calculated expression (p - 30) / 20.0.
            t = (p - 30) / 20.0
            # Return: Sends the collection of values used later in this module back to the caller.
            return (int(255 * (1.0 - t)), int(165 + (90 * t)), 0)
        # Return: Sends the collection of values used later in this module back to the caller.
        return (0, 255, 0)