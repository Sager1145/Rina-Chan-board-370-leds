# ---------------------------------------------------------------------------
# battery_module.py
#
# Battery display module.
# Manages battery sampling, overlay rendering (percent, voltage, time,
# charger voltage), charging animation, and short/detail display modes.
# Uses battery_monitor.py for ADC and battery_runtime.py for estimation.
# ---------------------------------------------------------------------------

import time
import display_num
from config import (
    BATTERY_SHORT_SHOW_MS, BATTERY_REFRESH_MS, BATTERY_ANIMATION_REFRESH_MS,
    BATTERY_DISPLAY_CYCLE_MS, BATTERY_DEFAULT_USAGE_HOURS,
    BATTERY_DEFAULT_CHARGE_HOURS,
)
from battery_monitor import BatteryMonitor
from battery_runtime import estimate_remaining_hours, estimate_charge_hours


class BatteryModule:
    """Battery sampling, display overlay, and charging animation."""

    __slots__ = (
        "state", "battery_state", "monitor",
        "_on_redraw_face",
    )

    def __init__(self, state, battery_state):
        self.state = state
        self.battery_state = battery_state
        self.monitor = BatteryMonitor()
        self._on_redraw_face = None

    # ------------------------------------------------------------------
    # Sampling
    # ------------------------------------------------------------------
    def service_sampling(self, force=False):
        return self.monitor.service_mean_sampler(force_sample=force)

    def update_calibration(self, save_cb, force=False):
        self.monitor.update_calibration(
            self.battery_state, self.state, save_cb, force=force
        )

    # ------------------------------------------------------------------
    # Charging detection
    # ------------------------------------------------------------------
    def is_charging(self, charge_v=None, previous=None):
        if charge_v is None:
            _, charge_v = self.monitor.get_mean_voltage_pair(allow_partial=True)
        if previous is None:
            previous = self.state.battery_display_cached_is_charging
        return self.monitor.is_charging_voltage(charge_v, previous=previous)

    # ------------------------------------------------------------------
    # Display modes
    # ------------------------------------------------------------------
    def show_short(self):
        """Show battery percent for 2 seconds (B6 short press)."""
        self.state.battery_display_active = True
        self.state.battery_display_single_shot = True
        self.state.flash_active = False
        self.state.flash_kind = None
        self.state.flash_value = None
        self.state.battery_next_refresh_ms = 0
        self.state.battery_visual_next_refresh_ms = 0
        self._refresh_cache(force=True)
        now = time.ticks_ms()
        self.state.battery_display_toggle_started_ms = now
        self.state.battery_display_phase_index = 0
        self.state.battery_display_phase_count = 1
        self.state.battery_display_next_phase_ms = 0
        self.state.battery_display_expires_ms = time.ticks_add(
            now, BATTERY_SHORT_SHOW_MS
        )
        self._render(refresh_phase=False, refresh_cache=False)

    def show_detail(self):
        """Enter detail battery display (B6 long press)."""
        self.state.battery_display_active = True
        self.state.battery_display_single_shot = False
        self.state.flash_active = False
        self.state.flash_kind = None
        self.state.flash_value = None
        self.state.battery_next_refresh_ms = 0
        self.state.battery_visual_next_refresh_ms = 0
        self._refresh_cache(force=True)
        now = time.ticks_ms()
        self.state.battery_display_toggle_started_ms = now
        self.state.battery_display_phase_index = 0
        charging = self.state.battery_display_cached_is_charging
        self.state.battery_display_phase_count = 4 if charging else 3
        self.state.battery_display_next_phase_ms = time.ticks_add(
            now, BATTERY_DISPLAY_CYCLE_MS
        )
        self._render(refresh_phase=False, refresh_cache=False)

    def stop(self):
        """Stop battery display and return to face."""
        if not self.state.battery_display_active:
            return
        self.state.battery_display_active = False
        self.state.battery_display_single_shot = False
        self.state.battery_display_expires_ms = 0
        self.state.battery_visual_next_refresh_ms = 0
        if self._on_redraw_face:
            self._on_redraw_face()

    # ------------------------------------------------------------------
    # Cache refresh
    # ------------------------------------------------------------------
    def _refresh_cache(self, force=False):
        now = time.ticks_ms()
        if (not force and self.state.battery_next_refresh_ms and
                time.ticks_diff(now, self.state.battery_next_refresh_ms) < 0):
            return False

        self.service_sampling(force=force)
        v_bat, charge_v = self.monitor.get_mean_voltage_pair(allow_partial=True)

        if v_bat is None:
            v_bat = self.state.battery_display_cached_voltage
        if charge_v is None:
            charge_v = self.state.battery_display_cached_charge_voltage

        instant_charge_v = self.monitor.read_charge_voltage()
        charging_sample = instant_charge_v if instant_charge_v is not None else charge_v
        charging = self.is_charging(
            charging_sample,
            previous=self.state.battery_display_cached_is_charging
        )

        if v_bat is not None:
            self.battery_state.last_voltage = v_bat
        if charge_v is not None:
            self.battery_state.last_charge_voltage = charge_v

        pct = self.monitor.percent_from_voltage(v_bat, self.battery_state)
        pct_float = self.monitor.percent_float_from_voltage(v_bat, self.battery_state)
        remaining_h = estimate_remaining_hours(
            self.battery_state, self.state, pct_float
        )
        charge_time_h = estimate_charge_hours(
            self.battery_state, self.state, pct_float
        )

        if not self.state.battery_display_single_shot:
            target_phase_count = 4 if charging else 3
            if self.state.battery_display_phase_count != target_phase_count:
                self.state.battery_display_phase_count = target_phase_count
                self.state.battery_display_phase_index = 0
                self.state.battery_display_toggle_started_ms = now
                self.state.battery_display_next_phase_ms = time.ticks_add(
                    now, BATTERY_DISPLAY_CYCLE_MS
                )

        old_cache = (
            self.state.battery_display_cached_voltage,
            self.state.battery_display_cached_charge_voltage,
            self.state.battery_display_cached_percent,
            self.state.battery_display_cached_percent_float,
            self.state.battery_display_cached_remaining_h,
            self.state.battery_display_cached_charge_time_h,
            self.state.battery_display_cached_is_charging,
        )

        self.state.battery_display_cached_voltage = v_bat
        self.state.battery_display_cached_charge_voltage = charge_v
        self.state.battery_display_cached_percent = pct
        self.state.battery_display_cached_percent_float = pct_float
        self.state.battery_display_cached_remaining_h = remaining_h
        self.state.battery_display_cached_charge_time_h = charge_time_h
        self.state.battery_display_cached_is_charging = charging
        self.state.battery_next_refresh_ms = time.ticks_add(now, BATTERY_REFRESH_MS)

        new_cache = (v_bat, charge_v, pct, pct_float, remaining_h, charge_time_h, charging)
        return force or (new_cache != old_cache)

    # ------------------------------------------------------------------
    # Phase cycling
    # ------------------------------------------------------------------
    def _update_phase(self):
        if not self.state.battery_display_active:
            return
        if self.state.battery_display_single_shot:
            return
        now = time.ticks_ms()
        while (self.state.battery_display_next_phase_ms and
               time.ticks_diff(now, self.state.battery_display_next_phase_ms) >= 0):
            pc = self.state.battery_display_phase_count
            self.state.battery_display_phase_index = (
                (self.state.battery_display_phase_index + 1) % pc
            )
            self.state.battery_display_next_phase_ms = time.ticks_add(
                self.state.battery_display_next_phase_ms, BATTERY_DISPLAY_CYCLE_MS
            )

    # ------------------------------------------------------------------
    # Rendering
    # ------------------------------------------------------------------
    def _render(self, refresh_phase=True, refresh_cache=True, log_status=True):
        if refresh_phase:
            self._update_phase()
        if refresh_cache:
            self._refresh_cache(force=False)

        v_bat = self.state.battery_display_cached_voltage
        charge_v = self.state.battery_display_cached_charge_voltage
        pct = self.state.battery_display_cached_percent
        pct_float = self.state.battery_display_cached_percent_float
        remaining_h = self.state.battery_display_cached_remaining_h
        charge_time_h = self.state.battery_display_cached_charge_time_h
        charging = self.state.battery_display_cached_is_charging

        if pct is None:
            display_num.render_battery_percent(0, color=(255, 0, 0))
            return

        color = self.monitor.color(pct)
        charging_phase_ms = time.ticks_diff(
            time.ticks_ms(), self.state.battery_display_toggle_started_ms
        )
        charge_step_interval_s = self.monitor.charge_animation_step_interval_s(pct)
        flash_last_column = False

        display_count = self.state.battery_display_phase_count
        cycle_index = self.state.battery_display_phase_index % display_count
        if self.state.battery_display_single_shot:
            cycle_index = 0

        display_remaining_h = (remaining_h if remaining_h is not None
                               else BATTERY_DEFAULT_USAGE_HOURS)
        display_charge_h = (charge_time_h if charge_time_h is not None
                            else BATTERY_DEFAULT_CHARGE_HOURS)
        active_time_h = display_charge_h if charging else display_remaining_h

        animate_icon = (not self.state.battery_display_single_shot) and charging

        if cycle_index == 0:
            display_num.render_battery_percent(
                pct, color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
                animate=animate_icon,
            )
        elif cycle_index == 1:
            display_num.render_battery_voltage(
                v_bat, pct, color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
                animate=animate_icon,
            )
        elif cycle_index == 2:
            display_num.render_battery_time(
                active_time_h, pct, color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
                animate=animate_icon,
            )
        else:
            display_num.render_charge_voltage(
                charge_v, pct, icon_color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
                animate=animate_icon,
            )

    # ------------------------------------------------------------------
    # Main service (called every tick from main loop)
    # ------------------------------------------------------------------
    def service_overlay(self):
        """Service the battery display overlay (sampling + rendering)."""
        if not self.state.battery_display_active:
            return

        now = time.ticks_ms()

        if self.state.battery_display_single_shot:
            if time.ticks_diff(now, self.state.battery_display_expires_ms) >= 0:
                self.stop()
                return
            instant_charge_v = self.monitor.read_charge_voltage()
            charging_instant = self.monitor.is_charging_voltage(
                instant_charge_v,
                previous=self.state.battery_display_cached_is_charging,
            )
            charge_state_flipped = (
                charging_instant != self.state.battery_display_cached_is_charging
            )
            cache_due = (
                not self.state.battery_next_refresh_ms or
                time.ticks_diff(now, self.state.battery_next_refresh_ms) >= 0
            )
            if charge_state_flipped:
                cache_due = True
            if cache_due and self._refresh_cache(force=charge_state_flipped):
                self._render(refresh_phase=False, refresh_cache=False, log_status=True)
            return

        cache_due = (
            not self.state.battery_next_refresh_ms or
            time.ticks_diff(now, self.state.battery_next_refresh_ms) >= 0
        )
        visual_due = (
            not self.state.battery_visual_next_refresh_ms or
            time.ticks_diff(now, self.state.battery_visual_next_refresh_ms) >= 0
        )
        phase_due = (
            self.state.battery_display_next_phase_ms and
            time.ticks_diff(now, self.state.battery_display_next_phase_ms) >= 0
        )

        instant_charge_v = self.monitor.read_charge_voltage()
        charging_instant = self.monitor.is_charging_voltage(
            instant_charge_v,
            previous=self.state.battery_display_cached_is_charging,
        )
        charge_state_flipped = (
            charging_instant != self.state.battery_display_cached_is_charging
        )
        if charge_state_flipped:
            cache_due = True

        cache_changed = False
        if cache_due:
            cache_changed = self._refresh_cache(force=charge_state_flipped)
            now = time.ticks_ms()

        phase_changed = False
        if phase_due:
            old_phase = self.state.battery_display_phase_index
            self._update_phase()
            phase_changed = (self.state.battery_display_phase_index != old_phase)
            now = time.ticks_ms()

        animate_due = self.state.battery_display_cached_is_charging and visual_due
        if cache_changed or phase_changed or animate_due:
            self._render(
                refresh_phase=False, refresh_cache=False,
                log_status=(cache_changed or phase_changed)
            )
            self.state.battery_visual_next_refresh_ms = time.ticks_add(
                now, BATTERY_ANIMATION_REFRESH_MS
            )

    # ------------------------------------------------------------------
    # Status JSON (for protocol requestBattery / requestState)
    # ------------------------------------------------------------------
    def status_json(self):
        self.service_sampling(force=True)
        v_bat, charge_v = self.monitor.get_mean_voltage_pair(allow_partial=True)
        if v_bat is None:
            v_bat = self.battery_state.last_voltage
        if charge_v is None:
            charge_v = self.battery_state.last_charge_voltage
        pct = self.monitor.percent_from_voltage(v_bat, self.battery_state)
        pct_float = self.monitor.percent_float_from_voltage(v_bat, self.battery_state)
        charging = self.monitor.is_charging_voltage(
            charge_v, previous=self.state.battery_display_cached_is_charging
        )
        rem = estimate_remaining_hours(self.battery_state, self.state, pct_float)
        chg = estimate_charge_hours(self.battery_state, self.state, pct_float)

        def jnum(x, digits=3):
            if x is None:
                return "null"
            try:
                return ("%0.*f" % (digits, float(x)))
            except Exception:
                return "null"

        return ("{"
                "\"battery_v\":" + jnum(v_bat, 3) + ","
                "\"charge_v\":" + jnum(charge_v, 3) + ","
                "\"percent\":" + str(int(pct)) + ","
                "\"percent_float\":" + jnum(pct_float, 2) + ","
                "\"charging\":" + ("true" if charging else "false") + ","
                "\"remaining_h\":" + jnum(rem, 2) + ","
                "\"charge_time_h\":" + jnum(chg, 2) + ","
                "\"min_v\":" + jnum(self.battery_state.min_v, 3) + ","
                "\"max_v\":" + jnum(self.battery_state.max_v, 3) + "}")

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------
    def set_on_redraw_face(self, callback):
        """Called when battery display stops and the face should be redrawn."""
        self._on_redraw_face = callback
