# ---------------------------------------------------------------------------
# battery_module.py
#
# Independent battery display module: ADC cache, percent/voltage/time overlays, charging animation, and JSON status.
# ---------------------------------------------------------------------------

# Import: Loads time so this module can use that dependency.
import time

# Import: Loads display_num so this module can use that dependency.
import display_num
# Import: Loads * from config so this module can use that dependency.
from config import *
# Import: Loads estimate_remaining_hours, estimate_charge_hours from battery_runtime so this module can use that dependency.
from battery_runtime import estimate_remaining_hours, estimate_charge_hours
# Import: Loads BTN_AUTO, BTN_NEXT, BTN_BRIGHT_RST from buttons so this module can use that dependency.
from buttons import BTN_AUTO, BTN_NEXT, BTN_BRIGHT_RST

# Import: Loads AppModule from app_module_base so this module can use that dependency.
from app_module_base import AppModule


# Class: Defines BatteryModule as the state and behavior container for Battery Module.
class BatteryModule(AppModule):

    # Function: Defines stop_battery_display(self) to handle stop battery display behavior.
    def stop_battery_display(self):
        # Logic: Branches when not self.state.battery_display_active so the correct firmware path runs.
        if not self.state.battery_display_active:
            # Return: Sends control back to the caller.
            return
        # Variable: self.state.battery_display_active stores the enabled/disabled flag value.
        self.state.battery_display_active = False
        # Variable: self.state.battery_display_single_shot stores the enabled/disabled flag value.
        self.state.battery_display_single_shot = False
        # Variable: self.state.battery_display_expires_ms stores the configured literal value.
        self.state.battery_display_expires_ms = 0
        # Variable: self.state.battery_visual_next_refresh_ms stores the configured literal value.
        self.state.battery_visual_next_refresh_ms = 0
        # Expression: Calls self.render_current_visual() for its side effects.
        self.render_current_visual(force=True)

    # Function: Defines service_battery_sampling(self, force_sample) to handle service battery sampling behavior.
    def service_battery_sampling(self, force_sample=False):
        # Return: Sends the result returned by self.battery_monitor.service_mean_sampler() back to the caller.
        return self.battery_monitor.service_mean_sampler(force_sample=force_sample)

    # ------------------------------------------------------------------
    # Battery display helpers
    # ------------------------------------------------------------------

    # Function: Defines is_charging(self, charge_v, previous) to handle is charging behavior.
    def is_charging(self, charge_v=None, previous=None):
        # Logic: Branches when charge_v is None so the correct firmware path runs.
        if charge_v is None:
            # Variable: _, charge_v stores the result returned by self.battery_monitor.get_mean_voltage_pair().
            _, charge_v = self.battery_monitor.get_mean_voltage_pair(allow_partial=True)
        # Logic: Branches when previous is None so the correct firmware path runs.
        if previous is None:
            # Variable: previous stores the referenced self.state.battery_display_cached_is_charging value.
            previous = self.state.battery_display_cached_is_charging
        # Return: Sends the result returned by self.battery_monitor.is_charging_voltage() back to the caller.
        return self.battery_monitor.is_charging_voltage(charge_v, previous=previous)

    # Function: Defines show_battery_percent_short(self) to handle show battery percent short behavior.
    def show_battery_percent_short(self):
        # Variable: self.state.battery_display_active stores the enabled/disabled flag value.
        self.state.battery_display_active = True
        # Variable: self.state.battery_display_single_shot stores the enabled/disabled flag value.
        self.state.battery_display_single_shot = True
        # Variable: self.state.flash_active stores the enabled/disabled flag value.
        self.state.flash_active = False
        # Variable: self.state.flash_kind stores the empty sentinel value.
        self.state.flash_kind = None
        # Variable: self.state.flash_value stores the empty sentinel value.
        self.state.flash_value = None
        # Variable: self.state.battery_next_refresh_ms stores the configured literal value.
        self.state.battery_next_refresh_ms = 0
        # Variable: self.state.battery_visual_next_refresh_ms stores the configured literal value.
        self.state.battery_visual_next_refresh_ms = 0
        # Expression: Calls self.refresh_battery_overlay_cache() for its side effects.
        self.refresh_battery_overlay_cache(force=True)
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Variable: self.state.battery_display_toggle_started_ms stores the current now value.
        self.state.battery_display_toggle_started_ms = now
        # Variable: self.state.battery_display_phase_index stores the configured literal value.
        self.state.battery_display_phase_index = 0
        # Variable: self.state.battery_display_phase_count stores the configured literal value.
        self.state.battery_display_phase_count = 1
        # Variable: self.state.battery_display_next_phase_ms stores the configured literal value.
        self.state.battery_display_next_phase_ms = 0
        # Variable: self.state.battery_display_expires_ms stores the result returned by time.ticks_add().
        self.state.battery_display_expires_ms = time.ticks_add(now, BATTERY_SHORT_SHOW_MS)
        # Expression: Calls self.render_battery_overlay() for its side effects.
        self.render_battery_overlay(refresh_phase=False, refresh_cache=False)

    # Function: Defines refresh_battery_overlay_cache(self, force) to handle refresh battery overlay cache behavior.
    def refresh_battery_overlay_cache(self, force=False):
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Logic: Branches when not force and self.state.battery_next_refresh_ms and time.ticks_diff(now, self.state.... so the correct firmware path runs.
        if (not force and self.state.battery_next_refresh_ms and
                time.ticks_diff(now, self.state.battery_next_refresh_ms) < 0):
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False

        # Expression: Calls self.service_battery_sampling() for its side effects.
        self.service_battery_sampling(force_sample=force)
        # Variable: v_bat, charge_v stores the result returned by self.battery_monitor.get_mean_voltage_pair().
        v_bat, charge_v = self.battery_monitor.get_mean_voltage_pair(allow_partial=True)

        # Logic: Branches when v_bat is None so the correct firmware path runs.
        if v_bat is None:
            # Variable: v_bat stores the referenced self.state.battery_display_cached_voltage value.
            v_bat = self.state.battery_display_cached_voltage
        # Logic: Branches when charge_v is None so the correct firmware path runs.
        if charge_v is None:
            # Variable: charge_v stores the referenced self.state.battery_display_cached_charge_voltage value.
            charge_v = self.state.battery_display_cached_charge_voltage

        # For the charging/not-charging decision, read the charge ADC
        # instantaneously instead of relying on the 1-second mean. The mean
        # lags by up to a full window; on an unplug event we need to flip
        # within one poll tick so the display stops showing the charging
        # animation and the charger-voltage phase. A single fresh sample is
        # good enough here because the charge detect pin has a hard pull
        # (either 5 V from VBUS or 0 V via R2), not a noisy analog signal.
        # Variable: instant_charge_v stores the result returned by self.battery_monitor.read_charge_voltage().
        instant_charge_v = self.battery_monitor.read_charge_voltage()
        # Variable: charging_sample stores the conditional expression instant_charge_v if instant_charge_v is not None else charge_v.
        charging_sample = instant_charge_v if instant_charge_v is not None else charge_v
        # Variable: charging stores the result returned by self.is_charging().
        charging = self.is_charging(charging_sample, previous=self.state.battery_display_cached_is_charging)
        # Logic: Branches when v_bat is not None so the correct firmware path runs.
        if v_bat is not None:
            # Variable: self.battery.last_voltage stores the current v_bat value.
            self.battery.last_voltage = v_bat
        # Logic: Branches when charge_v is not None so the correct firmware path runs.
        if charge_v is not None:
            # Variable: self.battery.last_charge_voltage stores the current charge_v value.
            self.battery.last_charge_voltage = charge_v
        # Variable: pct stores the result returned by self.battery_monitor.percent_from_voltage().
        pct = self.battery_monitor.percent_from_voltage(v_bat, self.battery)
        # Variable: pct_float stores the result returned by self.battery_monitor.percent_float_from_voltage().
        pct_float = self.battery_monitor.percent_float_from_voltage(v_bat, self.battery)
        # Variable: remaining_h stores the result returned by estimate_remaining_hours().
        remaining_h = estimate_remaining_hours(self.battery, self.state, pct_float)
        # Variable: charge_time_h stores the result returned by estimate_charge_hours().
        charge_time_h = estimate_charge_hours(self.battery, self.state, pct_float)

        # Logic: Branches when not self.state.battery_display_single_shot so the correct firmware path runs.
        if not self.state.battery_display_single_shot:
            # Variable: target_phase_count stores the conditional expression 4 if charging else 3.
            target_phase_count = 4 if charging else 3
            # Logic: Branches when self.state.battery_display_phase_count != target_phase_count so the correct firmware path runs.
            if self.state.battery_display_phase_count != target_phase_count:
                # Variable: self.state.battery_display_phase_count stores the current target_phase_count value.
                self.state.battery_display_phase_count = target_phase_count
                # If we just stopped charging and the user was on phase 3
                # (the charger-voltage screen, which only exists while
                # charging), jump back to phase 0 so we stop displaying a
                # stale charger voltage for a disconnected charger. For the
                # reverse direction (discharge -> charging), also reset so
                # the cycle starts cleanly from the percent phase.
                # Variable: self.state.battery_display_phase_index stores the configured literal value.
                self.state.battery_display_phase_index = 0
                # Variable: self.state.battery_display_toggle_started_ms stores the current now value.
                self.state.battery_display_toggle_started_ms = now
                # Variable: self.state.battery_display_next_phase_ms stores the result returned by time.ticks_add().
                self.state.battery_display_next_phase_ms = time.ticks_add(now, BATTERY_DISPLAY_CYCLE_MS)

        # Variable: old_cache stores the collection of values used later in this module.
        old_cache = (
            self.state.battery_display_cached_voltage,
            self.state.battery_display_cached_charge_voltage,
            self.state.battery_display_cached_percent,
            self.state.battery_display_cached_percent_float,
            self.state.battery_display_cached_remaining_h,
            self.state.battery_display_cached_charge_time_h,
            self.state.battery_display_cached_is_charging,
        )

        # Variable: self.state.battery_display_cached_voltage stores the current v_bat value.
        self.state.battery_display_cached_voltage = v_bat
        # Variable: self.state.battery_display_cached_charge_voltage stores the current charge_v value.
        self.state.battery_display_cached_charge_voltage = charge_v
        # Variable: self.state.battery_display_cached_percent stores the current pct value.
        self.state.battery_display_cached_percent = pct
        # Variable: self.state.battery_display_cached_percent_float stores the current pct_float value.
        self.state.battery_display_cached_percent_float = pct_float
        # Variable: self.state.battery_display_cached_remaining_h stores the current remaining_h value.
        self.state.battery_display_cached_remaining_h = remaining_h
        # Variable: self.state.battery_display_cached_charge_time_h stores the current charge_time_h value.
        self.state.battery_display_cached_charge_time_h = charge_time_h
        # Variable: self.state.battery_display_cached_is_charging stores the current charging value.
        self.state.battery_display_cached_is_charging = charging
        # Variable: self.state.battery_next_refresh_ms stores the result returned by time.ticks_add().
        self.state.battery_next_refresh_ms = time.ticks_add(now, BATTERY_REFRESH_MS)

        # Variable: new_cache stores the collection of values used later in this module.
        new_cache = (
            v_bat,
            charge_v,
            pct,
            pct_float,
            remaining_h,
            charge_time_h,
            charging,
        )
        # Return: Sends the combined condition force or (new_cache != old_cache) back to the caller.
        return force or (new_cache != old_cache)

    # Function: Defines update_battery_display_phase(self) to handle update battery display phase behavior.
    def update_battery_display_phase(self):
        # Logic: Branches when not self.state.battery_display_active so the correct firmware path runs.
        if not self.state.battery_display_active:
            # Return: Sends control back to the caller.
            return
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Logic: Branches when self.state.battery_display_single_shot so the correct firmware path runs.
        if self.state.battery_display_single_shot:
            # Return: Sends control back to the caller.
            return
        # Loop: Repeats while self.state.battery_display_next_phase_ms and time.ticks_diff(now, self.state.battery_... remains true.
        while (self.state.battery_display_next_phase_ms and
               time.ticks_diff(now, self.state.battery_display_next_phase_ms) >= 0):
            # Variable: phase_count stores the referenced self.state.battery_display_phase_count value.
            phase_count = self.state.battery_display_phase_count
            # Variable: self.state.battery_display_phase_index stores the calculated expression (self.state.battery_display_phase_index + 1) % phase_count.
            self.state.battery_display_phase_index = (self.state.battery_display_phase_index + 1) % phase_count
            # Variable: self.state.battery_display_next_phase_ms stores the result returned by time.ticks_add().
            self.state.battery_display_next_phase_ms = time.ticks_add(
                self.state.battery_display_next_phase_ms,
                BATTERY_DISPLAY_CYCLE_MS,
            )

    # Function: Defines service_battery_overlay(self) to handle service battery overlay behavior.
    def service_battery_overlay(self):
        # Logic: Branches when not self.state.battery_display_active so the correct firmware path runs.
        if not self.state.battery_display_active:
            # Return: Sends control back to the caller.
            return

        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()

        # Logic: Branches when self.state.battery_display_single_shot so the correct firmware path runs.
        if self.state.battery_display_single_shot:
            # Check for expiry first
            # Logic: Branches when time.ticks_diff(now, self.state.battery_display_expires_ms) >= 0 so the correct firmware path runs.
            if time.ticks_diff(now, self.state.battery_display_expires_ms) >= 0:
                # Expression: Calls self.stop_battery_display() for its side effects.
                self.stop_battery_display()
                # Return: Sends control back to the caller.
                return
            # Fast-path charging-state check on every poll tick so an
            # unplug / replug during the 2 s single-shot window flips the
            # display immediately, without waiting for the 100 ms cache
            # cadence.
            # Variable: instant_charge_v stores the result returned by self.battery_monitor.read_charge_voltage().
            instant_charge_v = self.battery_monitor.read_charge_voltage()
            # Variable: charging_instant stores the result returned by self.battery_monitor.is_charging_voltage().
            charging_instant = self.battery_monitor.is_charging_voltage(
                instant_charge_v,
                previous=self.state.battery_display_cached_is_charging,
            )
            # Variable: charge_state_flipped stores the comparison result charging_instant != self.state.battery_display_cached_is_charging.
            charge_state_flipped = (charging_instant != self.state.battery_display_cached_is_charging)
            # Variable: cache_due stores the combined condition not self.state.battery_next_refresh_ms or time.ticks_diff(now, self.state.battery_nex....
            cache_due = (not self.state.battery_next_refresh_ms or
                         time.ticks_diff(now, self.state.battery_next_refresh_ms) >= 0)
            # Logic: Branches when charge_state_flipped so the correct firmware path runs.
            if charge_state_flipped:
                # Variable: cache_due stores the enabled/disabled flag value.
                cache_due = True
            # Logic: Branches when cache_due and self.refresh_battery_overlay_cache(force=charge_state_flipped) so the correct firmware path runs.
            if cache_due and self.refresh_battery_overlay_cache(force=charge_state_flipped):
                # Expression: Calls self.render_battery_overlay() for its side effects.
                self.render_battery_overlay(refresh_phase=False, refresh_cache=False, log_status=True)
            # Return: Sends control back to the caller.
            return

        # Variable: cache_due stores the combined condition not self.state.battery_next_refresh_ms or time.ticks_diff(now, self.state.battery_nex....
        cache_due = (not self.state.battery_next_refresh_ms or
                     time.ticks_diff(now, self.state.battery_next_refresh_ms) >= 0)
        # Variable: visual_due stores the combined condition not self.state.battery_visual_next_refresh_ms or time.ticks_diff(now, self.state.batt....
        visual_due = (not self.state.battery_visual_next_refresh_ms or
                      time.ticks_diff(now, self.state.battery_visual_next_refresh_ms) >= 0)
        # Variable: phase_due stores the combined condition self.state.battery_display_next_phase_ms and time.ticks_diff(now, self.state.battery_....
        phase_due = (self.state.battery_display_next_phase_ms and
                     time.ticks_diff(now, self.state.battery_display_next_phase_ms) >= 0)

        # Fast-path charging-state check: read the charge ADC on every poll
        # tick (not just on the 100 ms cache cadence) so the icon animation
        # stops the instant the charger is unplugged. When the state flips
        # we force a cache refresh on this same tick so the new charging
        # flag is picked up by the renderer immediately.
        # Variable: instant_charge_v stores the result returned by self.battery_monitor.read_charge_voltage().
        instant_charge_v = self.battery_monitor.read_charge_voltage()
        # Variable: charging_instant stores the result returned by self.battery_monitor.is_charging_voltage().
        charging_instant = self.battery_monitor.is_charging_voltage(
            instant_charge_v,
            previous=self.state.battery_display_cached_is_charging,
        )
        # Variable: charge_state_flipped stores the comparison result charging_instant != self.state.battery_display_cached_is_charging.
        charge_state_flipped = (charging_instant != self.state.battery_display_cached_is_charging)
        # Logic: Branches when charge_state_flipped so the correct firmware path runs.
        if charge_state_flipped:
            # Variable: cache_due stores the enabled/disabled flag value.
            cache_due = True

        # Variable: cache_changed stores the enabled/disabled flag value.
        cache_changed = False
        # Logic: Branches when cache_due so the correct firmware path runs.
        if cache_due:
            # Variable: cache_changed stores the result returned by self.refresh_battery_overlay_cache().
            cache_changed = self.refresh_battery_overlay_cache(force=charge_state_flipped)
            # Variable: now stores the result returned by time.ticks_ms().
            now = time.ticks_ms()

        # Variable: phase_changed stores the enabled/disabled flag value.
        phase_changed = False
        # Logic: Branches when phase_due so the correct firmware path runs.
        if phase_due:
            # Variable: old_phase stores the referenced self.state.battery_display_phase_index value.
            old_phase = self.state.battery_display_phase_index
            # Expression: Calls self.update_battery_display_phase() for its side effects.
            self.update_battery_display_phase()
            # Variable: phase_changed stores the comparison result self.state.battery_display_phase_index != old_phase.
            phase_changed = (self.state.battery_display_phase_index != old_phase)
            # Variable: now stores the result returned by time.ticks_ms().
            now = time.ticks_ms()

        # Variable: animate_due stores the combined condition self.state.battery_display_cached_is_charging and visual_due.
        animate_due = self.state.battery_display_cached_is_charging and visual_due
        # Logic: Branches when cache_changed or phase_changed or animate_due so the correct firmware path runs.
        if cache_changed or phase_changed or animate_due:
            # Expression: Calls self.render_battery_overlay() for its side effects.
            self.render_battery_overlay(refresh_phase=False, refresh_cache=False, log_status=(cache_changed or phase_changed))
            # Variable: self.state.battery_visual_next_refresh_ms stores the result returned by time.ticks_add().
            self.state.battery_visual_next_refresh_ms = time.ticks_add(now, BATTERY_ANIMATION_REFRESH_MS)

    # Function: Defines render_battery_overlay(self, refresh_phase, refresh_cache, log_status) to handle render battery overlay behavior.
    def render_battery_overlay(self, refresh_phase=True, refresh_cache=True, log_status=True):
        # Logic: Branches when refresh_phase so the correct firmware path runs.
        if refresh_phase:
            # Expression: Calls self.update_battery_display_phase() for its side effects.
            self.update_battery_display_phase()
        # Logic: Branches when refresh_cache so the correct firmware path runs.
        if refresh_cache:
            # Expression: Calls self.refresh_battery_overlay_cache() for its side effects.
            self.refresh_battery_overlay_cache(force=False)

        # Variable: v_bat stores the referenced self.state.battery_display_cached_voltage value.
        v_bat = self.state.battery_display_cached_voltage
        # Variable: charge_v stores the referenced self.state.battery_display_cached_charge_voltage value.
        charge_v = self.state.battery_display_cached_charge_voltage
        # Variable: pct stores the referenced self.state.battery_display_cached_percent value.
        pct = self.state.battery_display_cached_percent
        # Variable: pct_float stores the referenced self.state.battery_display_cached_percent_float value.
        pct_float = self.state.battery_display_cached_percent_float
        # Variable: remaining_h stores the referenced self.state.battery_display_cached_remaining_h value.
        remaining_h = self.state.battery_display_cached_remaining_h
        # Variable: charge_time_h stores the referenced self.state.battery_display_cached_charge_time_h value.
        charge_time_h = self.state.battery_display_cached_charge_time_h
        # Variable: charging stores the referenced self.state.battery_display_cached_is_charging value.
        charging = self.state.battery_display_cached_is_charging

        # Logic: Branches when pct is None so the correct firmware path runs.
        if pct is None:
            # Battery serial log disabled.
            # Expression: Calls display_num.render_battery_percent() for its side effects.
            display_num.render_battery_percent(0, color=(255, 0, 0))
            # Return: Sends control back to the caller.
            return

        # Variable: color stores the result returned by self.battery_monitor.color().
        color = self.battery_monitor.color(pct)
        # Variable: charging_phase_ms stores the result returned by time.ticks_diff().
        charging_phase_ms = time.ticks_diff(time.ticks_ms(), self.state.battery_display_toggle_started_ms)
        # Variable: charge_step_interval_s stores the result returned by self.battery_monitor.charge_animation_step_interval_s().
        charge_step_interval_s = self.battery_monitor.charge_animation_step_interval_s(pct)
        # Variable: flash_last_column stores the enabled/disabled flag value.
        flash_last_column = False

        # Variable: display_count stores the referenced self.state.battery_display_phase_count value.
        display_count = self.state.battery_display_phase_count
        # Variable: cycle_index stores the calculated expression self.state.battery_display_phase_index % display_count.
        cycle_index = self.state.battery_display_phase_index % display_count
        # Logic: Branches when self.state.battery_display_single_shot so the correct firmware path runs.
        if self.state.battery_display_single_shot:
            # Variable: phase_name stores the configured text value.
            phase_name = "percent_short"
            # Variable: cycle_index stores the configured literal value.
            cycle_index = 0
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: phase_name stores the selected item ("percent", "voltage", "time", "charge_v")[cycle_index].
            phase_name = ("percent", "voltage", "time", "charge_v")[cycle_index]

        # Variable: display_remaining_h stores the conditional expression remaining_h if remaining_h is not None else BATTERY_DEFAULT_USAGE_HOURS.
        display_remaining_h = remaining_h if remaining_h is not None else BATTERY_DEFAULT_USAGE_HOURS
        # Variable: display_charge_h stores the conditional expression charge_time_h if charge_time_h is not None else BATTERY_DEFAULT_CHARGE_HOURS.
        display_charge_h = charge_time_h if charge_time_h is not None else BATTERY_DEFAULT_CHARGE_HOURS
        # Variable: active_time_h stores the conditional expression display_charge_h if charging else display_remaining_h.
        active_time_h = display_charge_h if charging else display_remaining_h

        # Logic: Branches when active_time_h < 1.0 so the correct firmware path runs.
        if active_time_h < 1.0:
            # Variable: remain_text stores the result returned by format().
            remain_text = "{} min".format(int(round(active_time_h * 60.0)))
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: remain_text stores the result returned by format().
            remain_text = "{:.1f} h".format(active_time_h)

        # Logic: Branches when log_status so the correct firmware path runs.
        if log_status:
            # Battery serial log disabled; overlay still refreshes normally.
            # Control: Leaves this branch intentionally empty.
            pass

        # Variable: animate_icon stores the combined condition (not self.state.battery_display_single_shot) and charging.
        animate_icon = (not self.state.battery_display_single_shot) and charging

        # Logic: Branches when cycle_index == 0 so the correct firmware path runs.
        if cycle_index == 0:
            # Expression: Calls display_num.render_battery_percent() for its side effects.
            display_num.render_battery_percent(
                pct, color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
                animate=animate_icon,
            )
        # Logic: Branches when cycle_index == 1 so the correct firmware path runs.
        elif cycle_index == 1:
            # Expression: Calls display_num.render_battery_voltage() for its side effects.
            display_num.render_battery_voltage(
                v_bat, pct, color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
                animate=animate_icon,
            )
        # Logic: Branches when cycle_index == 2 so the correct firmware path runs.
        elif cycle_index == 2:
            # Expression: Calls display_num.render_battery_time() for its side effects.
            display_num.render_battery_time(
                active_time_h, pct, color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
                animate=animate_icon,
            )
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Expression: Calls display_num.render_charge_voltage() for its side effects.
            display_num.render_charge_voltage(
                charge_v, pct, icon_color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
                animate=animate_icon,
            )

    # Function: Defines start_b6_press(self) to handle start b6 press behavior.
    def start_b6_press(self):
        # Variable: self.state.b6_pending stores the enabled/disabled flag value.
        self.state.b6_pending = True
        # Variable: self.state.b6_press_started_ms stores the result returned by time.ticks_ms().
        self.state.b6_press_started_ms = time.ticks_ms()
        # Variable: self.state.b6_long_fired stores the enabled/disabled flag value.
        self.state.b6_long_fired = False

    # Function: Defines check_b6_hold(self) to handle check b6 hold behavior.
    def check_b6_hold(self):
        # Logic: Branches when not self.state.b6_pending so the correct firmware path runs.
        if not self.state.b6_pending:
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when self.buttons.is_down(BTN_AUTO) so the correct firmware path runs.
        if self.buttons.is_down(BTN_AUTO):
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when self.buttons.is_down(BTN_NEXT) so the correct firmware path runs.
        if self.buttons.is_down(BTN_NEXT):
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when not self.buttons.is_down(BTN_BRIGHT_RST) so the correct firmware path runs.
        if not self.buttons.is_down(BTN_BRIGHT_RST):
            # Return: Sends control back to the caller.
            return

        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Logic: Branches when not self.state.b6_long_fired and time.ticks_diff(now, self.state.b6_press_started_ms)... so the correct firmware path runs.
        if (not self.state.b6_long_fired and
                time.ticks_diff(now, self.state.b6_press_started_ms) >= B6_LONG_PRESS_MS):
            # Variable: self.state.b6_long_fired stores the enabled/disabled flag value.
            self.state.b6_long_fired = True
            # Variable: self.state.battery_display_active stores the enabled/disabled flag value.
            self.state.battery_display_active = True
            # Variable: self.state.flash_active stores the enabled/disabled flag value.
            self.state.flash_active = False
            # Variable: self.state.flash_kind stores the empty sentinel value.
            self.state.flash_kind = None
            # Variable: self.state.flash_value stores the empty sentinel value.
            self.state.flash_value = None
            # Variable: self.state.battery_next_refresh_ms stores the configured literal value.
            self.state.battery_next_refresh_ms = 0
            # Variable: self.state.battery_visual_next_refresh_ms stores the configured literal value.
            self.state.battery_visual_next_refresh_ms = 0
            # Expression: Calls self.refresh_battery_overlay_cache() for its side effects.
            self.refresh_battery_overlay_cache(force=True)
            # Variable: now stores the result returned by time.ticks_ms().
            now = time.ticks_ms()
            # Variable: self.state.battery_display_toggle_started_ms stores the current now value.
            self.state.battery_display_toggle_started_ms = now
            # Variable: self.state.battery_display_phase_index stores the configured literal value.
            self.state.battery_display_phase_index = 0
            # Variable: self.state.battery_display_phase_count stores the conditional expression 4 if self.state.battery_display_cached_is_charging else 3.
            self.state.battery_display_phase_count = 4 if self.state.battery_display_cached_is_charging else 3
            # Variable: self.state.battery_display_next_phase_ms stores the result returned by time.ticks_add().
            self.state.battery_display_next_phase_ms = time.ticks_add(now, BATTERY_DISPLAY_CYCLE_MS)
            # Expression: Calls self.render_battery_overlay() for its side effects.
            self.render_battery_overlay(refresh_phase=False, refresh_cache=False)

    # Function: Defines check_b6_release(self, prev_b6_down) to handle check b6 release behavior.
    def check_b6_release(self, prev_b6_down):
        # Variable: b6_now stores the result returned by self.buttons.is_down().
        b6_now = self.buttons.is_down(BTN_BRIGHT_RST)
        # Logic: Branches when prev_b6_down and not b6_now so the correct firmware path runs.
        if prev_b6_down and not b6_now:
            # Logic: Branches when self.state.ip_combo_latched so the correct firmware path runs.
            if self.state.ip_combo_latched:
                # Variable: self.state.b6_pending stores the enabled/disabled flag value.
                self.state.b6_pending = False
                # Variable: self.state.b6_long_fired stores the enabled/disabled flag value.
                self.state.b6_long_fired = False
                # Return: Sends the current b6_now value back to the caller.
                return b6_now
            # Logic: Branches when self.state.b6_pending so the correct firmware path runs.
            if self.state.b6_pending:
                # Logic: Branches when self.state.battery_display_active or self.state.b6_long_fired so the correct firmware path runs.
                if self.state.battery_display_active or self.state.b6_long_fired:
                    # Expression: Calls self.stop_battery_display() for its side effects.
                    self.stop_battery_display()
                # Logic: Runs this fallback branch when the earlier condition did not match.
                else:
                    # Logic: Branches when not self.buttons.is_down(BTN_AUTO) and not self.buttons.is_down(BTN_NEXT) so the correct firmware path runs.
                    if not self.buttons.is_down(BTN_AUTO) and not self.buttons.is_down(BTN_NEXT):
                        # Expression: Calls self.show_battery_percent_short() for its side effects.
                        self.show_battery_percent_short()
                # Variable: self.state.b6_pending stores the enabled/disabled flag value.
                self.state.b6_pending = False
                # Variable: self.state.b6_long_fired stores the enabled/disabled flag value.
                self.state.b6_long_fired = False
        # Return: Sends the current b6_now value back to the caller.
        return b6_now

    # ------------------------------------------------------------------
    # IP/SSID display overlay: B2 + B6 scrolls the current ESP STA IP and SSID.
    # It uses the full 22x18 irregular 370-LED physical matrix.
    # Hidden/padded cells are not real LEDs and remain dark.
    # ------------------------------------------------------------------

    # Function: Defines battery_status_json(self) to handle battery status json behavior.
    def battery_status_json(self):
        # Expression: Calls self.service_battery_sampling() for its side effects.
        self.service_battery_sampling(force_sample=True)
        # Variable: v_bat, charge_v stores the result returned by self.battery_monitor.get_mean_voltage_pair().
        v_bat, charge_v = self.battery_monitor.get_mean_voltage_pair(allow_partial=True)
        # Logic: Branches when v_bat is None so the correct firmware path runs.
        if v_bat is None:
            # Variable: v_bat stores the referenced self.battery.last_voltage value.
            v_bat = self.battery.last_voltage
        # Logic: Branches when charge_v is None so the correct firmware path runs.
        if charge_v is None:
            # Variable: charge_v stores the referenced self.battery.last_charge_voltage value.
            charge_v = self.battery.last_charge_voltage
        # Variable: pct stores the result returned by self.battery_monitor.percent_from_voltage().
        pct = self.battery_monitor.percent_from_voltage(v_bat, self.battery)
        # Variable: pct_float stores the result returned by self.battery_monitor.percent_float_from_voltage().
        pct_float = self.battery_monitor.percent_float_from_voltage(v_bat, self.battery)
        # Variable: charging stores the result returned by self.battery_monitor.is_charging_voltage().
        charging = self.battery_monitor.is_charging_voltage(charge_v, previous=self.state.battery_display_cached_is_charging)
        # Variable: rem stores the result returned by estimate_remaining_hours().
        rem = estimate_remaining_hours(self.battery, self.state, pct_float)
        # Variable: chg stores the result returned by estimate_charge_hours().
        chg = estimate_charge_hours(self.battery, self.state, pct_float)
        # Function: Defines jnum(x, digits) to handle jnum behavior.
        def jnum(x, digits=3):
            # Logic: Branches when x is None so the correct firmware path runs.
            if x is None:
                # Return: Sends the configured text value back to the caller.
                return "null"
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Return: Sends the calculated expression "%0.*f" % (digits, float(x)) back to the caller.
                return ("%0.*f" % (digits, float(x)))
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Return: Sends the configured text value back to the caller.
                return "null"
        # Return: Sends the calculated expression "{" "\"battery_v\":" + jnum(v_bat, 3) + "," "\"charge_v\":" + jnum(charge_v, 3) + ","... back to the caller.
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
