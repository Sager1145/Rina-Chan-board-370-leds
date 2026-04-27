# ---------------------------------------------------------------------------
# battery_module.py
#
# Independent battery display module: ADC cache, percent/voltage/time overlays, charging animation, and JSON status.
# ---------------------------------------------------------------------------

import time

import display_num
from config import *
from battery_runtime import estimate_remaining_hours, estimate_charge_hours
from buttons import BTN_AUTO, BTN_NEXT, BTN_BRIGHT_RST

from app_module_base import AppModule


class BatteryModule(AppModule):

    def stop_battery_display(self):
        if not self.state.battery_display_active:
            return
        self.state.battery_display_active = False
        self.state.battery_display_single_shot = False
        self.state.battery_display_expires_ms = 0
        self.state.battery_visual_next_refresh_ms = 0
        self.render_current_visual(force=True)

    def service_battery_sampling(self, force_sample=False):
        return self.battery_monitor.service_mean_sampler(force_sample=force_sample)

    # ------------------------------------------------------------------
    # Battery display helpers
    # ------------------------------------------------------------------

    def is_charging(self, charge_v=None, previous=None):
        if charge_v is None:
            _, charge_v = self.battery_monitor.get_mean_voltage_pair(allow_partial=True)
        if previous is None:
            previous = self.state.battery_display_cached_is_charging
        return self.battery_monitor.is_charging_voltage(charge_v, previous=previous)

    def show_battery_percent_short(self):
        self.state.battery_display_active = True
        self.state.battery_display_single_shot = True
        self.state.flash_active = False
        self.state.flash_kind = None
        self.state.flash_value = None
        self.state.battery_next_refresh_ms = 0
        self.state.battery_visual_next_refresh_ms = 0
        self.refresh_battery_overlay_cache(force=True)
        now = time.ticks_ms()
        self.state.battery_display_toggle_started_ms = now
        self.state.battery_display_phase_index = 0
        self.state.battery_display_phase_count = 1
        self.state.battery_display_next_phase_ms = 0
        self.state.battery_display_expires_ms = time.ticks_add(now, BATTERY_SHORT_SHOW_MS)
        self.render_battery_overlay(refresh_phase=False, refresh_cache=False)

    def refresh_battery_overlay_cache(self, force=False):
        now = time.ticks_ms()
        if (not force and self.state.battery_next_refresh_ms and
                time.ticks_diff(now, self.state.battery_next_refresh_ms) < 0):
            return False

        self.service_battery_sampling(force_sample=force)
        v_bat, charge_v = self.battery_monitor.get_mean_voltage_pair(allow_partial=True)

        if v_bat is None:
            v_bat = self.state.battery_display_cached_voltage
        if charge_v is None:
            charge_v = self.state.battery_display_cached_charge_voltage

        # For the charging/not-charging decision, read the charge ADC
        # instantaneously instead of relying on the 1-second mean. The mean
        # lags by up to a full window; on an unplug event we need to flip
        # within one poll tick so the display stops showing the charging
        # animation and the charger-voltage phase. A single fresh sample is
        # good enough here because the charge detect pin has a hard pull
        # (either 5 V from VBUS or 0 V via R2), not a noisy analog signal.
        instant_charge_v = self.battery_monitor.read_charge_voltage()
        charging_sample = instant_charge_v if instant_charge_v is not None else charge_v
        charging = self.is_charging(charging_sample, previous=self.state.battery_display_cached_is_charging)
        if v_bat is not None:
            self.battery.last_voltage = v_bat
        if charge_v is not None:
            self.battery.last_charge_voltage = charge_v
        pct = self.battery_monitor.percent_from_voltage(v_bat, self.battery)
        pct_float = self.battery_monitor.percent_float_from_voltage(v_bat, self.battery)
        remaining_h = estimate_remaining_hours(self.battery, self.state, pct_float)
        charge_time_h = estimate_charge_hours(self.battery, self.state, pct_float)

        if not self.state.battery_display_single_shot:
            target_phase_count = 4 if charging else 3
            if self.state.battery_display_phase_count != target_phase_count:
                self.state.battery_display_phase_count = target_phase_count
                # If we just stopped charging and the user was on phase 3
                # (the charger-voltage screen, which only exists while
                # charging), jump back to phase 0 so we stop displaying a
                # stale charger voltage for a disconnected charger. For the
                # reverse direction (discharge -> charging), also reset so
                # the cycle starts cleanly from the percent phase.
                self.state.battery_display_phase_index = 0
                self.state.battery_display_toggle_started_ms = now
                self.state.battery_display_next_phase_ms = time.ticks_add(now, BATTERY_DISPLAY_CYCLE_MS)

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

        new_cache = (
            v_bat,
            charge_v,
            pct,
            pct_float,
            remaining_h,
            charge_time_h,
            charging,
        )
        return force or (new_cache != old_cache)

    def update_battery_display_phase(self):
        if not self.state.battery_display_active:
            return
        now = time.ticks_ms()
        if self.state.battery_display_single_shot:
            return
        while (self.state.battery_display_next_phase_ms and
               time.ticks_diff(now, self.state.battery_display_next_phase_ms) >= 0):
            phase_count = self.state.battery_display_phase_count
            self.state.battery_display_phase_index = (self.state.battery_display_phase_index + 1) % phase_count
            self.state.battery_display_next_phase_ms = time.ticks_add(
                self.state.battery_display_next_phase_ms,
                BATTERY_DISPLAY_CYCLE_MS,
            )

    def service_battery_overlay(self):
        if not self.state.battery_display_active:
            return

        now = time.ticks_ms()

        if self.state.battery_display_single_shot:
            # Check for expiry first
            if time.ticks_diff(now, self.state.battery_display_expires_ms) >= 0:
                self.stop_battery_display()
                return
            # Fast-path charging-state check on every poll tick so an
            # unplug / replug during the 2 s single-shot window flips the
            # display immediately, without waiting for the 100 ms cache
            # cadence.
            instant_charge_v = self.battery_monitor.read_charge_voltage()
            charging_instant = self.battery_monitor.is_charging_voltage(
                instant_charge_v,
                previous=self.state.battery_display_cached_is_charging,
            )
            charge_state_flipped = (charging_instant != self.state.battery_display_cached_is_charging)
            cache_due = (not self.state.battery_next_refresh_ms or
                         time.ticks_diff(now, self.state.battery_next_refresh_ms) >= 0)
            if charge_state_flipped:
                cache_due = True
            if cache_due and self.refresh_battery_overlay_cache(force=charge_state_flipped):
                self.render_battery_overlay(refresh_phase=False, refresh_cache=False, log_status=True)
            return

        cache_due = (not self.state.battery_next_refresh_ms or
                     time.ticks_diff(now, self.state.battery_next_refresh_ms) >= 0)
        visual_due = (not self.state.battery_visual_next_refresh_ms or
                      time.ticks_diff(now, self.state.battery_visual_next_refresh_ms) >= 0)
        phase_due = (self.state.battery_display_next_phase_ms and
                     time.ticks_diff(now, self.state.battery_display_next_phase_ms) >= 0)

        # Fast-path charging-state check: read the charge ADC on every poll
        # tick (not just on the 100 ms cache cadence) so the icon animation
        # stops the instant the charger is unplugged. When the state flips
        # we force a cache refresh on this same tick so the new charging
        # flag is picked up by the renderer immediately.
        instant_charge_v = self.battery_monitor.read_charge_voltage()
        charging_instant = self.battery_monitor.is_charging_voltage(
            instant_charge_v,
            previous=self.state.battery_display_cached_is_charging,
        )
        charge_state_flipped = (charging_instant != self.state.battery_display_cached_is_charging)
        if charge_state_flipped:
            cache_due = True

        cache_changed = False
        if cache_due:
            cache_changed = self.refresh_battery_overlay_cache(force=charge_state_flipped)
            now = time.ticks_ms()

        phase_changed = False
        if phase_due:
            old_phase = self.state.battery_display_phase_index
            self.update_battery_display_phase()
            phase_changed = (self.state.battery_display_phase_index != old_phase)
            now = time.ticks_ms()

        animate_due = self.state.battery_display_cached_is_charging and visual_due
        if cache_changed or phase_changed or animate_due:
            self.render_battery_overlay(refresh_phase=False, refresh_cache=False, log_status=(cache_changed or phase_changed))
            self.state.battery_visual_next_refresh_ms = time.ticks_add(now, BATTERY_ANIMATION_REFRESH_MS)

    def render_battery_overlay(self, refresh_phase=True, refresh_cache=True, log_status=True):
        if refresh_phase:
            self.update_battery_display_phase()
        if refresh_cache:
            self.refresh_battery_overlay_cache(force=False)

        v_bat = self.state.battery_display_cached_voltage
        charge_v = self.state.battery_display_cached_charge_voltage
        pct = self.state.battery_display_cached_percent
        pct_float = self.state.battery_display_cached_percent_float
        remaining_h = self.state.battery_display_cached_remaining_h
        charge_time_h = self.state.battery_display_cached_charge_time_h
        charging = self.state.battery_display_cached_is_charging

        if pct is None:
            # Battery serial log disabled.
            display_num.render_battery_percent(0, color=(255, 0, 0))
            return

        color = self.battery_monitor.color(pct)
        charging_phase_ms = time.ticks_diff(time.ticks_ms(), self.state.battery_display_toggle_started_ms)
        charge_step_interval_s = self.battery_monitor.charge_animation_step_interval_s(pct)
        flash_last_column = False

        display_count = self.state.battery_display_phase_count
        cycle_index = self.state.battery_display_phase_index % display_count
        if self.state.battery_display_single_shot:
            phase_name = "percent_short"
            cycle_index = 0
        else:
            phase_name = ("percent", "voltage", "time", "charge_v")[cycle_index]

        display_remaining_h = remaining_h if remaining_h is not None else BATTERY_DEFAULT_USAGE_HOURS
        display_charge_h = charge_time_h if charge_time_h is not None else BATTERY_DEFAULT_CHARGE_HOURS
        active_time_h = display_charge_h if charging else display_remaining_h

        if active_time_h < 1.0:
            remain_text = "{} min".format(int(round(active_time_h * 60.0)))
        else:
            remain_text = "{:.1f} h".format(active_time_h)

        if log_status:
            # Battery serial log disabled; overlay still refreshes normally.
            pass

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

    def start_b6_press(self):
        self.state.b6_pending = True
        self.state.b6_press_started_ms = time.ticks_ms()
        self.state.b6_long_fired = False

    def check_b6_hold(self):
        if not self.state.b6_pending:
            return
        if self.buttons.is_down(BTN_AUTO):
            return
        if self.buttons.is_down(BTN_NEXT):
            return
        if not self.buttons.is_down(BTN_BRIGHT_RST):
            return

        now = time.ticks_ms()
        if (not self.state.b6_long_fired and
                time.ticks_diff(now, self.state.b6_press_started_ms) >= B6_LONG_PRESS_MS):
            self.state.b6_long_fired = True
            self.state.battery_display_active = True
            self.state.flash_active = False
            self.state.flash_kind = None
            self.state.flash_value = None
            self.state.battery_next_refresh_ms = 0
            self.state.battery_visual_next_refresh_ms = 0
            self.refresh_battery_overlay_cache(force=True)
            now = time.ticks_ms()
            self.state.battery_display_toggle_started_ms = now
            self.state.battery_display_phase_index = 0
            self.state.battery_display_phase_count = 4 if self.state.battery_display_cached_is_charging else 3
            self.state.battery_display_next_phase_ms = time.ticks_add(now, BATTERY_DISPLAY_CYCLE_MS)
            self.render_battery_overlay(refresh_phase=False, refresh_cache=False)

    def check_b6_release(self, prev_b6_down):
        b6_now = self.buttons.is_down(BTN_BRIGHT_RST)
        if prev_b6_down and not b6_now:
            if self.state.ip_combo_latched:
                self.state.b6_pending = False
                self.state.b6_long_fired = False
                return b6_now
            if self.state.b6_pending:
                if self.state.battery_display_active or self.state.b6_long_fired:
                    self.stop_battery_display()
                else:
                    if not self.buttons.is_down(BTN_AUTO) and not self.buttons.is_down(BTN_NEXT):
                        self.show_battery_percent_short()
                self.state.b6_pending = False
                self.state.b6_long_fired = False
        return b6_now

    # ------------------------------------------------------------------
    # IP/SSID display overlay: B2 + B6 scrolls the current ESP STA IP and SSID.
    # It uses the full 22x18 irregular 370-LED physical matrix.
    # Hidden/padded cells are not real LEDs and remain dark.
    # ------------------------------------------------------------------

    def battery_status_json(self):
        self.service_battery_sampling(force_sample=True)
        v_bat, charge_v = self.battery_monitor.get_mean_voltage_pair(allow_partial=True)
        if v_bat is None:
            v_bat = self.battery.last_voltage
        if charge_v is None:
            charge_v = self.battery.last_charge_voltage
        pct = self.battery_monitor.percent_from_voltage(v_bat, self.battery)
        pct_float = self.battery_monitor.percent_float_from_voltage(v_bat, self.battery)
        charging = self.battery_monitor.is_charging_voltage(charge_v, previous=self.state.battery_display_cached_is_charging)
        rem = estimate_remaining_hours(self.battery, self.state, pct_float)
        chg = estimate_charge_hours(self.battery, self.state, pct_float)
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
                "\"min_v\":" + jnum(self.battery.min_v, 3) + ","
                "\"max_v\":" + jnum(self.battery.max_v, 3) + "}")

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------
