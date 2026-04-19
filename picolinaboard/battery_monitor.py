# ---------------------------------------------------------------------------
# battery_monitor.py
#
# ADC-based battery helper logic.
#
# This module is intentionally isolated so main.py does not need to contain
# low-level ADC math, averaging, calibration drift handling, or color mapping.
#
# Features handled here:
# - read raw ADC voltage through the resistor divider
# - average multiple readings for a steadier displayed percentage / voltage
# - learn battery min / max values over time
# - periodically pull learned min/max inward to avoid stale extremes
# - map voltage -> percentage
# - map percentage -> display color
# ---------------------------------------------------------------------------

import time

from battery_runtime import record_discharge_sample
from config import (
    BATTERY_ADC_GPIO, BATTERY_ADC_REF_V, BATTERY_SAMPLES,
    BATTERY_DIVIDER_R1, BATTERY_DIVIDER_R2,
    BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V, BATTERY_DISPLAY_TOL_V,
    BATTERY_LOG_INTERVAL_MS,
    BATTERY_RELEARN_EVERY_MEASUREMENTS,
    BATTERY_RELEARN_MAX_STEP_V,
    BATTERY_RELEARN_MIN_STEP_V,
    BATTERY_RELEARN_HOLDOFF_MEASUREMENTS,
    BATTERY_MIN_SPAN_V,
    BATTERY_PERCENT_CURVE,
    BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S,
    BATTERY_CHARGE_ANIM_INTERVAL_NEAR_FULL_S,
    BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT,
)

# ---------------------------------------------------------------------------
# machine.ADC only exists on the Pico / MicroPython runtime.
# When running on desktop Python for editing or syntax checks, ADC is missing,
# so we fall back to None and return None from battery reads.
# ---------------------------------------------------------------------------
try:
    from machine import ADC
except ImportError:
    ADC = None


class BatteryMonitor:
    # -----------------------------------------------------------------------
    # Store only the ADC object. __slots__ helps reduce memory use.
    # -----------------------------------------------------------------------
    __slots__ = ("adc",)

    def __init__(self):
        # Create the ADC object if hardware support exists.
        self.adc = ADC(BATTERY_ADC_GPIO) if ADC is not None else None

    def read_voltage(self):
        # -------------------------------------------------------------------
        # Read the battery voltage once.
        #
        # The ADC reads the divided voltage, not the pack voltage directly, so
        # the result must be scaled back up by the resistor divider ratio.
        # Multiple raw samples are averaged first to reduce noise.
        # -------------------------------------------------------------------
        if self.adc is None:
            return None
        total = 0
        for _ in range(BATTERY_SAMPLES):
            total += self.adc.read_u16()
        raw = total / BATTERY_SAMPLES
        v_adc = (raw / 65535.0) * BATTERY_ADC_REF_V
        return v_adc * (BATTERY_DIVIDER_R1 + BATTERY_DIVIDER_R2) / BATTERY_DIVIDER_R2

    def read_voltage_mean(self, window_ms, sample_delay_ms):
        # -------------------------------------------------------------------
        # Read repeatedly over a time window and return the mean voltage.
        # Used for the battery overlay so the displayed percentage is calmer.
        # -------------------------------------------------------------------
        if self.adc is None:
            return None
        start = time.ticks_ms()
        total = 0.0
        count = 0
        while True:
            v_bat = self.read_voltage()
            if v_bat is not None:
                total += v_bat
                count += 1
            now = time.ticks_ms()
            if time.ticks_diff(now, start) >= window_ms:
                break
            if sample_delay_ms > 0:
                time.sleep_ms(sample_delay_ms)
        if count <= 0:
            return None
        return total / count

    @staticmethod
    def inward_adjust_calibration(battery_state):
        # -------------------------------------------------------------------
        # Every N measurements, pull the learned endpoints inward slightly.
        # This helps old extreme values expire over time.
        # -------------------------------------------------------------------
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
            display_min = v_min
            display_max = v_max

        if v_bat <= display_min:
            return 0.0
        if v_bat >= display_max:
            return 100.0

        x = (v_bat - display_min) / (display_max - display_min)
        if x <= 0.0:
            return 0.0
        if x >= 1.0:
            return 100.0

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
        # -------------------------------------------------------------------
        # Periodically update the learned battery min/max values.
        #
        # This makes the displayed percentage adapt to the real pack over time.
        # The callback is only invoked if persistent state actually changed.
        # -------------------------------------------------------------------
        now = time.ticks_ms()
        if (not force and app_state.battery_next_log_ms and
                time.ticks_diff(now, app_state.battery_next_log_ms) < 0):
            return False
        v_bat = self.read_voltage()
        app_state.battery_next_log_ms = time.ticks_add(now, BATTERY_LOG_INTERVAL_MS)
        if v_bat is None:
            return False

        battery_state.last_voltage = v_bat
        battery_state.measure_count += 1
        changed = False

        percent_float = self.percent_float_from_voltage(v_bat, battery_state)
        history_changed = record_discharge_sample(
            battery_state,
            app_state,
            percent_float,
            BATTERY_LOG_INTERVAL_MS / 3600000.0,
        )
        if history_changed:
            changed = True

        if (battery_state.measure_count % BATTERY_RELEARN_EVERY_MEASUREMENTS) == 0:
            self.inward_adjust_calibration(battery_state)
            changed = True
            print(
                "battery relearn drift: count={}, min={:.2f} V, max={:.2f} V, holdoff={}".format(
                    battery_state.measure_count,
                    battery_state.min_v,
                    battery_state.max_v,
                    battery_state.relearn_holdoff_counts,
                )
            )

        if battery_state.relearn_holdoff_counts > 0:
            battery_state.relearn_holdoff_counts -= 1
            changed = True
        else:
            if v_bat < battery_state.min_v:
                battery_state.min_v = v_bat
                changed = True
            if v_bat > battery_state.max_v:
                battery_state.max_v = v_bat
                changed = True

        if changed:
            save_cb()

        print(
            "battery log: current={:.2f} V, min={:.2f} V, max={:.2f} V, count={}, holdoff={}, history={}".format(
                v_bat,
                battery_state.min_v,
                battery_state.max_v,
                battery_state.measure_count,
                battery_state.relearn_holdoff_counts,
                len(battery_state.usage_history),
            )
        )
        return True

    @staticmethod
    def percent_from_voltage(v_bat, battery_state):
        # -------------------------------------------------------------------
        # Convert voltage to an integer 0..100 percentage.
        #
        # A tolerance band is applied near the learned min/max values so the UI
        # reaches 0 and 100 more cleanly instead of hovering near the ends.
        # -------------------------------------------------------------------
        if v_bat is None:
            return None

        pct = BatteryMonitor.percent_float_from_voltage(v_bat, battery_state)
        if pct is None:
            return None
        return int(round(pct))

    @staticmethod
    @staticmethod
    def charge_animation_step_interval_s(percent):
        # -------------------------------------------------------------------
        # Charging animation speed.
        # The interval is between lighting adjacent columns, not the whole run.
        # 0%  -> 0.50 s
        # 90% -> 0.07 s
        # >=90% stays at the near-full interval.
        # -------------------------------------------------------------------
        p = max(0.0, min(float(percent if percent is not None else 0.0), float(BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT)))
        t = p / float(BATTERY_CHARGE_ANIM_NEAR_FULL_PERCENT)
        return (BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S +
                ((BATTERY_CHARGE_ANIM_INTERVAL_NEAR_FULL_S - BATTERY_CHARGE_ANIM_INTERVAL_EMPTY_S) * t))

    @staticmethod
    def color(percent):
        # -------------------------------------------------------------------
        # Battery color gradient with more time spent in green:
        # -   0..10%: solid red
        # -  10..30%: red -> orange
        # -  30..50%: orange -> green
        # -  50..100%: solid green
        # -------------------------------------------------------------------
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
