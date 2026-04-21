# ---------------------------------------------------------------------------
# main.py
#
# Top-level application controller for the LinaBoard project.
#
# Features managed here:
# - normal face mode
# - special matrix demo mode
# - Bad Apple playback mode
# - shared brightness handling
# - battery display overlay
# - interval / mode / brightness overlay text
# - long-press combo handling
# - loading / saving persistent settings
#
# Mode rules:
# - face mode and demo mode share the same brightness value directly
# - Bad Apple uses half of that shared brightness internally
# - B6+B2 long press toggles Bad Apple on and off
# - while Bad Apple is active, brightness and battery still work
# - while Bad Apple is active, face/demo MA and interval controls are disabled
# ---------------------------------------------------------------------------


import gc
import time

import board
from board import clear, show, draw_bitmap, logical_to_led_index, np, scale_color, COLS, ROWS

import demo_faces
import display_num
import matrix_demos
import badapple_mode
from buttons import (
    ButtonBank,
    BTN_PREV, BTN_NEXT, BTN_AUTO,
    BTN_BRIGHT_DN, BTN_BRIGHT_UP, BTN_BRIGHT_RST,
)

from config import *
from app_state import AppState, BatteryState
from settings_store import load_settings, save_settings, clamp_interval, clamp_brightness
from battery_monitor import BatteryMonitor
from battery_runtime import estimate_remaining_hours, estimate_charge_hours
from brightness_modes import effective_brightness


# ---------------------------------------------------------------------------
# Main application object.
# It owns runtime state, helpers, and the polling loop behavior.
# ---------------------------------------------------------------------------
class LinaBoardApp:
    __slots__ = ("state", "battery", "buttons", "battery_monitor")

    def __init__(self):
        self.state = AppState()
        self.battery = BatteryState()
        self.buttons = ButtonBank()
        self.battery_monitor = BatteryMonitor()

    # ------------------------------------------------------------------
    # Persistence / shared runtime helpers
    # ------------------------------------------------------------------
    def save_settings(self):
        save_settings(self.state, self.battery)

    def apply_brightness(self):
        board.set_max_brightness(effective_brightness(
            self.state.brightness,
            badapple_mode=self.state.badapple_mode,
            demo_mode=self.state.special_demo_mode,
        ))

    def draw_current_face(self):
        draw_bitmap(
            demo_faces.FRAMES[self.state.face_idx],
            on_color=demo_faces.PINK,
            dim_color=demo_faces.DIM,
        )

    def render_current_visual(self, force=False):
        if self.state.badapple_mode:
            badapple_mode.PLAYER.resync(time.ticks_ms())
            badapple_mode.PLAYER.redraw_current()
            return
        if self.state.special_demo_mode:
            now = time.ticks_ms()
            if force:
                matrix_demos.DEMOS.force_render(now)
            else:
                matrix_demos.DEMOS.render(now)
            return
        self.draw_current_face()

    # ------------------------------------------------------------------
    # Flash / overlay rendering
    # ------------------------------------------------------------------
    def start_edge_flash(self, edge):
        self.state.edge_flash_active = True
        self.state.edge_flash_edge = edge
        self.state.edge_flash_started_ms = time.ticks_ms()

    def edge_flash_factor(self, elapsed_ms):
        if elapsed_ms < 0 or elapsed_ms > EDGE_FLASH_TOTAL_MS:
            return 0.0
        if elapsed_ms <= EDGE_FLASH_ATTACK_MS:
            return elapsed_ms / float(EDGE_FLASH_ATTACK_MS)
        t = (elapsed_ms - EDGE_FLASH_ATTACK_MS) / float(EDGE_FLASH_DECAY_MS)
        return 1.0 - t

    def overlay_edge_flash(self):
        if not self.state.edge_flash_active:
            return False

        elapsed = time.ticks_diff(time.ticks_ms(), self.state.edge_flash_started_ms)
        factor = self.edge_flash_factor(elapsed)
        if factor <= 0.0:
            self.state.edge_flash_active = False
            return False

        y = 0 if self.state.edge_flash_edge == "top" else (ROWS - 1)
        center = (COLS - 1) / 2.0
        max_dist = center if center > 0 else 1.0

        for x in range(COLS):
            idx = logical_to_led_index(x, y)
            if idx is None:
                continue
            dist = abs(x - center)
            spatial = 1.0 - (dist / max_dist)
            if spatial < 0.20:
                spatial = 0.20
            level = factor * spatial
            if level <= 0.0:
                continue
            flash_color = EDGE_FLASH_COLOR
            if self.state.flash_kind == "interval":
                flash_color = display_num.MODE_COLOR
            np[idx] = scale_color((
                int(flash_color[0] * level),
                int(flash_color[1] * level),
                int(flash_color[2] * level),
            ))
        show()
        return True

    def render_flash_overlay_base(self):
        if self.state.flash_kind == "interval":
            display_num.render_interval(self.state.flash_value)
        elif self.state.flash_kind == "brightness":
            display_num.render_brightness_percent(self.state.flash_value)
        elif self.state.flash_kind == "mode":
            display_num.render_mode(self.state.flash_value)

    def render_flash_overlay_with_edge(self):
        if not self.state.flash_active:
            return
        self.render_flash_overlay_base()
        self.overlay_edge_flash()

    def start_or_extend_flash(self, kind=None, value=None):
        self.state.flash_active = True
        self.state.flash_kind = kind
        self.state.flash_value = value
        self.state.flash_expires_ms = time.ticks_add(time.ticks_ms(), FLASH_HOLD_MS)

    def end_flash_if_expired(self):
        if not self.state.flash_active:
            return False
        if time.ticks_diff(time.ticks_ms(), self.state.flash_expires_ms) >= 0:
            self.state.flash_active = False
            self.state.flash_kind = None
            self.state.flash_value = None
            self.render_current_visual(force=True)
            return True
        return False

    def cancel_flash_and_redraw(self):
        self.state.flash_active = False
        self.state.flash_kind = None
        self.state.flash_value = None
        self.render_current_visual(force=True)

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
            print("battery monitor unavailable")
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
            print("battery display: mean={:.2f} V, charge={:.2f} V, pct={}, learned min={:.2f} V, learned max={:.2f} V, time={}, phase={}, charging={}".format(
                v_bat if v_bat is not None else 0.0,
                charge_v if charge_v is not None else 0.0,
                pct,
                self.battery.min_v,
                self.battery.max_v,
                remain_text,
                phase_name,
                charging))

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
            if self.state.badapple_combo_long_fired:
                self.state.b6_pending = False
                self.state.b6_long_fired = False
                self.state.badapple_combo_long_fired = False
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
    # Mode management
    # ------------------------------------------------------------------
    def apply_demo_runtime_settings(self, refresh_timer=True):
        matrix_demos.DEMOS.set_auto(self.state.demo_auto)
        matrix_demos.DEMOS.set_interval_ms(int(self.state.demo_interval_s * 1000))
        if refresh_timer:
            matrix_demos.DEMOS.refresh_timer(time.ticks_ms())

    def stop_special_demo_mode(self, redraw_face=True):
        if not self.state.special_demo_mode:
            return
        self.state.special_demo_mode = False
        matrix_demos.DEMOS.exit()
        self.apply_brightness()
        if redraw_face:
            self.draw_current_face()

    def start_special_demo_mode(self):
        self.state.special_demo_mode = True
        self.state.flash_active = False
        self.state.flash_kind = None
        self.state.flash_value = None
        self.state.battery_display_active = False
        self.state.b6_pending = False
        self.state.b6_long_fired = False
        self.state.edge_flash_active = False
        self.apply_brightness()
        matrix_demos.DEMOS.enter()
        self.apply_demo_runtime_settings(refresh_timer=True)

    def toggle_special_demo_mode(self):
        if self.state.special_demo_mode:
            self.stop_special_demo_mode(redraw_face=True)
            print("special demo mode = False")
        else:
            self.start_special_demo_mode()
            print("special demo mode = True")

    def check_special_demo_combo(self):
        b3_down = self.buttons.is_down(BTN_AUTO)
        b6_down = self.buttons.is_down(BTN_BRIGHT_RST)
        if b3_down and b6_down:
            now = time.ticks_ms()
            if self.state.combo_press_started_ms is None:
                self.state.combo_press_started_ms = now
                self.state.combo_long_fired = False
                self.state.b3_consumed = True
                self.state.b6_pending = False
                self.state.b6_long_fired = False
                return True
            if (not self.state.combo_long_fired and
                    time.ticks_diff(now, self.state.combo_press_started_ms) >= SPECIAL_COMBO_LONG_PRESS_MS):
                self.state.combo_long_fired = True
                self.toggle_special_demo_mode()
            return True

        self.state.combo_press_started_ms = None
        self.state.combo_long_fired = False
        return False

    def stop_badapple_mode(self, redraw_face=True):
        if not self.state.badapple_mode:
            return
        self.state.badapple_mode = False
        badapple_mode.PLAYER.exit()
        self.apply_brightness()
        if redraw_face:
            self.draw_current_face()

    def start_badapple_mode(self):
        if self.state.special_demo_mode:
            self.stop_special_demo_mode(redraw_face=False)

        self.state.badapple_mode = True
        self.state.flash_active = False
        self.state.flash_kind = None
        self.state.flash_value = None
        self.state.battery_display_active = False
        self.state.b6_pending = False
        self.state.b6_long_fired = False
        self.state.edge_flash_active = False
        self.apply_brightness()
        gc.collect()

        if not badapple_mode.PLAYER.enter():
            self.state.badapple_mode = False
            self.apply_brightness()
            self.draw_current_face()
            err = badapple_mode.PLAYER.last_error()
            if err:
                print(err)
            return False
        return True

    def toggle_badapple_mode(self):
        if self.state.badapple_mode:
            self.stop_badapple_mode(redraw_face=True)
            print("badapple mode = False")
        else:
            if self.start_badapple_mode():
                print("badapple mode = True")
            else:
                print("badapple mode = False (start failed)")

    def check_badapple_combo(self):
        b2_down = self.buttons.is_down(BTN_NEXT)
        b6_down = self.buttons.is_down(BTN_BRIGHT_RST)
        if b2_down and b6_down:
            now = time.ticks_ms()
            if self.state.badapple_combo_press_started_ms is None:
                self.state.badapple_combo_press_started_ms = now
                self.state.badapple_combo_long_fired = False
                self.state.b6_pending = False
                self.state.b6_long_fired = False
                return True
            if (not self.state.badapple_combo_long_fired and
                    time.ticks_diff(now, self.state.badapple_combo_press_started_ms) >= BADAPPLE_COMBO_LONG_PRESS_MS):
                self.state.badapple_combo_long_fired = True
                self.toggle_badapple_mode()
            return True

        self.state.badapple_combo_press_started_ms = None
        self.state.badapple_combo_long_fired = False
        return False

    # ------------------------------------------------------------------
    # User actions
    # ------------------------------------------------------------------
    def cycle_face(self, delta):
        if self.state.special_demo_mode:
            if delta < 0:
                matrix_demos.DEMOS.prev_demo(time.ticks_ms())
            else:
                matrix_demos.DEMOS.next_demo(time.ticks_ms())
            self.stop_battery_display()
            self.cancel_flash_and_redraw()
            return
        self.state.face_idx = (self.state.face_idx + delta) % NUM_FACES
        self.stop_battery_display()
        self.cancel_flash_and_redraw()

    def adjust_interval(self, delta):
        if self.state.special_demo_mode:
            old_val = self.state.demo_interval_s
            self.state.demo_interval_s = clamp_interval(self.state.demo_interval_s + delta)
            if self.state.demo_interval_s != old_val:
                self.save_settings()
                self.apply_demo_runtime_settings(refresh_timer=True)
            if delta < 0 and self.state.demo_interval_s <= INTERVAL_MIN_S:
                self.start_edge_flash("bottom")
            elif delta > 0 and self.state.demo_interval_s >= INTERVAL_MAX_S:
                self.start_edge_flash("top")
            self.stop_battery_display()
            display_num.render_interval(self.state.demo_interval_s)
            # flash_kind must be set before overlay_edge_flash() so the first
            # rendered frame of the edge flash gets the interval tint
            # (MODE_COLOR / purple) instead of the default blue.
            self.start_or_extend_flash("interval", self.state.demo_interval_s)
            self.overlay_edge_flash()
            return

        old_val = self.state.interval_s
        self.state.interval_s = clamp_interval(self.state.interval_s + delta)
        if self.state.interval_s != old_val:
            self.save_settings()
        if delta < 0 and self.state.interval_s <= INTERVAL_MIN_S:
            self.start_edge_flash("bottom")
        elif delta > 0 and self.state.interval_s >= INTERVAL_MAX_S:
            self.start_edge_flash("top")
        self.stop_battery_display()
        display_num.render_interval(self.state.interval_s)
        # flash_kind must be set before overlay_edge_flash() so the first
        # rendered frame of the edge flash gets the interval tint
        # (MODE_COLOR / purple) instead of the default blue.
        self.start_or_extend_flash("interval", self.state.interval_s)
        self.overlay_edge_flash()

    def adjust_brightness(self, delta):
        old_val = self.state.brightness
        self.state.brightness = clamp_brightness(self.state.brightness + delta)
        self.apply_brightness()
        if self.state.brightness != old_val:
            self.save_settings()
        if delta < 0 and self.state.brightness <= BRIGHTNESS_MIN:
            self.start_edge_flash("bottom")
        elif delta > 0 and self.state.brightness >= BRIGHTNESS_MAX:
            self.start_edge_flash("top")
        self.stop_battery_display()
        display_num.render_brightness_percent(self.state.brightness)
        self.overlay_edge_flash()
        self.start_or_extend_flash("brightness", self.state.brightness)

    def reset_brightness(self):
        old_val = self.state.brightness
        self.state.brightness = DEFAULT_BRIGHTNESS
        self.apply_brightness()
        if self.state.brightness != old_val:
            self.save_settings()
        self.stop_battery_display()
        display_num.render_brightness_percent(self.state.brightness)
        self.start_or_extend_flash("brightness", self.state.brightness)

    def toggle_auto(self):
        if self.state.special_demo_mode:
            self.state.demo_auto = not self.state.demo_auto
            self.save_settings()
            self.apply_demo_runtime_settings(refresh_timer=True)
            print("demo auto =", self.state.demo_auto)
            self.stop_battery_display()
            display_num.render_mode(self.state.demo_auto)
            self.start_or_extend_flash("mode", self.state.demo_auto)
            return

        self.state.auto = not self.state.auto
        self.save_settings()
        print("auto =", self.state.auto)
        self.stop_battery_display()
        display_num.render_mode(self.state.auto)
        self.start_or_extend_flash("mode", self.state.auto)

    # ------------------------------------------------------------------
    # Button routing
    # ------------------------------------------------------------------
    def handle_press(self, gp):
        combo_b3_b6 = self.buttons.is_down(BTN_AUTO) and self.buttons.is_down(BTN_BRIGHT_RST)
        combo_b2_b6 = self.buttons.is_down(BTN_NEXT) and self.buttons.is_down(BTN_BRIGHT_RST)
        combo_b4_b5 = self.buttons.is_down(BTN_BRIGHT_DN) and self.buttons.is_down(BTN_BRIGHT_UP)
        if combo_b3_b6 or combo_b2_b6:
            return

        now = time.ticks_ms()
        if gp in (BTN_BRIGHT_DN, BTN_BRIGHT_UP) and combo_b4_b5:
            if time.ticks_diff(now, self.state.brightness_reset_ignore_until_ms) < 0:
                return
            if not self.state.brightness_reset_combo_latched:
                self.state.brightness_reset_combo_latched = True
                self.reset_brightness()
                self.state.brightness_reset_ignore_until_ms = time.ticks_add(now, BRIGHTNESS_RESET_IGNORE_MS)
            return

        if self.state.badapple_mode:
            if gp == BTN_BRIGHT_DN:
                self.adjust_brightness(+BRIGHTNESS_STEP)
            elif gp == BTN_BRIGHT_UP:
                self.adjust_brightness(-BRIGHTNESS_STEP)
            elif gp == BTN_BRIGHT_RST:
                self.start_b6_press()
            return

        b3_held = self.buttons.is_down(BTN_AUTO)
        if gp == BTN_PREV:
            if b3_held:
                self.state.b3_consumed = True
                self.adjust_interval(+INTERVAL_STEP_S)
            else:
                self.cycle_face(-1)
        elif gp == BTN_NEXT:
            if b3_held:
                self.state.b3_consumed = True
                self.adjust_interval(-INTERVAL_STEP_S)
            else:
                self.cycle_face(+1)
        elif gp == BTN_AUTO:
            self.state.b3_consumed = False
        elif gp == BTN_BRIGHT_DN:
            self.adjust_brightness(+BRIGHTNESS_STEP)
        elif gp == BTN_BRIGHT_UP:
            self.adjust_brightness(-BRIGHTNESS_STEP)
        elif gp == BTN_BRIGHT_RST:
            self.start_b6_press()

    def check_b3_release(self, prev_b3_down):
        b3_now = self.buttons.is_down(BTN_AUTO)
        if prev_b3_down and not b3_now:
            if self.state.combo_long_fired:
                self.state.b3_consumed = False
                return b3_now
            if not self.state.b3_consumed:
                self.toggle_auto()
            self.state.b3_consumed = False
        return b3_now

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------
    def print_startup_info(self):
        print("linaboard: starting")
        print("  default face interval=", DEFAULT_INTERVAL_S, "s")
        print("  default demo interval=", DEMO_DEFAULT_INTERVAL_S, "s")
        print("  default brightness   =", DEFAULT_BRIGHTNESS, "%")
        print("  button GPIOs         =", self.buttons.gpios())
        print("  battery adc gpio     =", BATTERY_ADC_GPIO)
        print("  divider              = 100k top, 57k bottom")
        print("  special demo combo   = hold B6 + B3 for 2 s")
        print("  bad apple combo      = hold B6 + B2 for 2 s")

    def initialize(self):
        self.print_startup_info()
        load_settings(self.state, self.battery)
        print("  learned min/max      = {:.2f} / {:.2f} V".format(self.battery.min_v, self.battery.max_v))
        print("  display mean update  =", BATTERY_MEAN_UPDATE_MS, "ms")
        print("  mean sample interval =", BATTERY_MEAN_SAMPLE_INTERVAL_MS, "ms")
        print("  display toggle cycle =", BATTERY_DISPLAY_CYCLE_MS, "ms")
        print("  display tolerance    = {:.2f} V".format(BATTERY_DISPLAY_TOL_V))
        print("  charge detect adc    =", CHARGE_DETECT_ADC_GPIO)
        self.apply_brightness()
        self.draw_current_face()
        self.apply_demo_runtime_settings(refresh_timer=False)
        self.service_battery_sampling(force_sample=True)

    def run(self):
        self.initialize()

        now = time.ticks_ms()
        next_auto_ms = time.ticks_add(now, int(self.state.interval_s * 1000))
        self.state.battery_next_log_ms = now
        self.battery_monitor.update_calibration(self.battery, self.state, self.save_settings, force=True)

        prev_b3_down = False
        prev_b6_down = False

        while True:
            combo_active = self.check_special_demo_combo()
            combo_active = self.check_badapple_combo() or combo_active

            for gp in self.buttons.poll():
                self.handle_press(gp)
                next_auto_ms = time.ticks_add(time.ticks_ms(), int(self.state.interval_s * 1000))

            combo_active = self.check_special_demo_combo() or combo_active
            combo_active = self.check_badapple_combo() or combo_active

            self.check_b6_hold()
            self.service_battery_overlay()

            if (self.state.brightness_reset_combo_latched and
                    not self.buttons.is_down(BTN_BRIGHT_DN) and
                    not self.buttons.is_down(BTN_BRIGHT_UP)):
                self.state.brightness_reset_combo_latched = False

            prev_b3_down = self.check_b3_release(prev_b3_down)
            prev_b6_down = self.check_b6_release(prev_b6_down)

            if not self.state.battery_display_active:
                self.end_flash_if_expired()

            if self.state.flash_active and self.state.edge_flash_active:
                self.render_flash_overlay_with_edge()
            elif self.state.edge_flash_active and not self.state.flash_active:
                self.state.edge_flash_active = False

            allow_background_sampling = (not self.state.badapple_mode) or self.state.battery_display_active
            if allow_background_sampling:
                self.service_battery_sampling()
                self.battery_monitor.update_calibration(self.battery, self.state, self.save_settings)

            if self.state.badapple_mode:
                if not self.state.flash_active and not self.state.battery_display_active:
                    still_running = badapple_mode.PLAYER.play_step()
                    if not still_running:
                        # Automatically leave Bad Apple mode after one full
                        # playthrough and return to the normal face display.
                        self.stop_badapple_mode(redraw_face=True)
                time.sleep(POLL_PERIOD_MS / 1000.0)
                continue

            if self.state.special_demo_mode:
                if not self.state.flash_active and not self.state.battery_display_active:
                    matrix_demos.DEMOS.render(time.ticks_ms())
                time.sleep(POLL_PERIOD_MS / 1000.0)
                continue

            if self.state.auto and not self.state.flash_active and not self.state.battery_display_active:
                now = time.ticks_ms()
                if time.ticks_diff(now, next_auto_ms) >= 0:
                    self.state.face_idx = (self.state.face_idx + 1) % NUM_FACES
                    self.draw_current_face()
                    next_auto_ms = time.ticks_add(now, int(self.state.interval_s * 1000))

            if self.state.flash_active or self.state.battery_display_active or combo_active:
                next_auto_ms = time.ticks_add(time.ticks_ms(), int(self.state.interval_s * 1000))

            time.sleep(POLL_PERIOD_MS / 1000.0)


# ---------------------------------------------------------------------------
# Boot entry point. Load saved settings, apply brightness, draw the initial
# frame, then enter the main polling loop forever.
# ---------------------------------------------------------------------------
def main():
    app = LinaBoardApp()
    app.run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        clear()
        show()
        print("stopped.")