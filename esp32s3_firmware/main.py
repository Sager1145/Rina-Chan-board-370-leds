# ---------------------------------------------------------------------------
# main.py
#
# Integrated RinaChanBoard controller for ESP32-S3 + 370 LEDs.
#
# Features managed here:
# - normal face mode
# - special matrix demo mode
# # - shared brightness handling
# - battery display overlay
# - interval / mode / brightness overlay text
# - long-press combo handling
# - loading / saving persistent settings
#
# Mode rules:
# - face mode and demo mode share the same brightness value directly
# - Bad Apple uses half of that shared brightness internally
# - B6+B2 long press toggles Bad Apple on and off
# # # ---------------------------------------------------------------------------


import gc
import time

# Memory-safe import order for RP2040 MicroPython:
# import/compile the protocol module before the large UI helper modules.
# MicroPython compiles .py modules into bytecode on import, so free heap and
# fragmentation at import time matter. Keep matrix demo and fallback demo faces
# out of RAM in this no-demo build.
gc.collect()

import board
from board import clear, show, draw_bitmap, logical_to_led_index, np, scale_color, COLS, ROWS
gc.collect()

from rina_protocol import RinaProtocol, REMOTE_UDP_PORT, VERSION
gc.collect()

import saved_faces_370
gc.collect()
import display_num
gc.collect()
from buttons import (
    ButtonBank,
    BTN_PREV, BTN_NEXT, BTN_AUTO,
    BTN_BRIGHT_DN, BTN_BRIGHT_UP, BTN_BRIGHT_RST,
)
gc.collect()

from config import *
from app_state import AppState, BatteryState
from settings_store import load_settings, save_settings, clamp_interval, clamp_brightness
from battery_monitor import BatteryMonitor
from battery_runtime import estimate_remaining_hours, estimate_charge_hours
from brightness_modes import effective_brightness
gc.collect()

from esp32s3_network import ESP32S3Network
from webui_runtime import WebUIRuntime
gc.collect()

FIRMWARE_BANNER = "RinaChanBoard ESP32-S3 370LED native WebUI 1.6.9 Unity empty key fix asset bundles no bridge no MatrixDemo no BadApple no boot animation"


# ---------------------------------------------------------------------------
# Main application object.
# It owns runtime state, helpers, and the polling loop behavior.
# ---------------------------------------------------------------------------
class LinaBoardApp:
    __slots__ = ("state", "battery", "buttons", "battery_monitor", "network_poll", "proto", "link", "button_face_active", "web_runtime")

    def __init__(self):
        self.state = AppState()
        self.battery = BatteryState()
        self.buttons = ButtonBank()
        self.battery_monitor = BatteryMonitor()
        self.network_poll = None
        self.proto = None
        self.link = None
        self.button_face_active = False
        self.web_runtime = WebUIRuntime(self)

    # ------------------------------------------------------------------
    # Persistence / shared runtime helpers
    # ------------------------------------------------------------------
    def save_settings(self):
        save_settings(self.state, self.battery)

    def apply_brightness(self):
        board.set_max_brightness(effective_brightness(
            self.state.brightness,
            badapple_mode=False,
            demo_mode=False,
        ))

    def _current_home_color(self):
        if self.proto is not None and hasattr(self.proto, "color"):
            try:
                return self.proto.color
            except Exception:
                pass
        return (66, 0, 36)

    def _dimmed_home_color(self, color):
        try:
            return (max(0, int(color[0]) // 3),
                    max(0, int(color[1]) // 3),
                    max(0, int(color[2]) // 3))
        except Exception:
            return (24, 0, 14)

    def draw_current_face(self):
        # Button B1/B2 and A/M auto/manual now use the shared saved-custom-face
        # list.  The list is seeded with every face from the original Python
        # demo_faces.py file and can be extended by WebUI save operations.
        face = saved_faces_370.get(self.state.face_idx)
        face_hex = face.get("hex", "")
        if self.proto is not None and hasattr(self.proto, "update_physical_face_hex"):
            try:
                self.proto.update_physical_face_hex(face_hex, notify=False)
                self.button_face_active = True
                return
            except Exception as exc:
                print("saved face draw via protocol failed:", exc)

        # Fallback for very early boot if protocol is unavailable.
        # Do not load the old demo face module in the normal boot path; this firmware build
        # uses saved_faces_370 as the only face source to save RP2040 heap.
        clear()
        show()
        self.button_face_active = True

    def render_current_visual(self, force=False):
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

        # Battery overlay serial spam removed in v1.6.2; keep the UI display
        # active but do not print every display/cache refresh to the REPL.
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
    # IP/SSID display overlay: B2 + B6 scrolls the current ESP STA IP and SSID.
    # It uses the full 22x18 irregular 370-LED physical matrix.
    # Hidden/padded cells are not real LEDs and remain dark.
    # ------------------------------------------------------------------
    def start_ip_display(self):
        try:
            ip = self.link.get_ip() if self.link is not None else None
        except Exception:
            ip = None
        try:
            ssid = self.link.get_ssid() if self.link is not None and hasattr(self.link, "get_ssid") else None
        except Exception:
            ssid = None
        if not ip:
            print("ip display: no STA IP known yet")
            return
        text = str(ip)
        if ssid:
            text = str(ip) + "  " + str(ssid)
        now = time.ticks_ms()
        self.state.ip_scroll_text = text
        self.state.ip_scroll_offset = 0
        self.state.ip_scroll_next_ms = time.ticks_add(now, 120)
        # Duration scales with text length; enough time for at least one pass.
        self.state.ip_display_expires_ms = time.ticks_add(now, max(9000, len(text) * 650))
        self.state.ip_display_active = True
        self.state.flash_active = False
        self.state.edge_flash_active = False
        self.state.battery_display_active = False
        self.state.battery_display_single_shot = False
        display_num.render_scrolling_text_window(text, 0)
        print("ip display scroll:", text)

    def service_ip_display(self):
        if not self.state.ip_display_active:
            return
        now = time.ticks_ms()
        if time.ticks_diff(now, self.state.ip_display_expires_ms) >= 0:
            self.state.ip_display_active = False
            self.draw_current_face()
            return
        if time.ticks_diff(now, self.state.ip_scroll_next_ms) >= 0:
            text = self.state.ip_scroll_text or ""
            display_num.render_scrolling_text_window(text, self.state.ip_scroll_offset)
            self.state.ip_scroll_offset = (self.state.ip_scroll_offset + 1) % max(1, len(text) * 6 + 22)
            self.state.ip_scroll_next_ms = time.ticks_add(now, 120)

    def check_ip_combo(self):
        b2_down = self.buttons.is_down(BTN_NEXT)
        b6_down = self.buttons.is_down(BTN_BRIGHT_RST)
        if b2_down and b6_down:
            if not self.state.ip_combo_latched:
                self.state.ip_combo_latched = True
                self.state.b6_pending = False
                self.state.b6_long_fired = False
                self.start_ip_display()
            return True
        self.state.ip_combo_latched = False
        return False

    # ------------------------------------------------------------------
    # Mode management
    # ------------------------------------------------------------------
    def apply_demo_runtime_settings(self, refresh_timer=True):
        # Matrix demo is disabled in this build; keep this as a no-op so the
        # large matrix_demos module is not imported and compiled during boot.
        return

    def stop_special_demo_mode(self, redraw_face=True):
        if not self.state.special_demo_mode:
            return
        self.state.special_demo_mode = False
        self.apply_brightness()
        if redraw_face:
            self.draw_current_face()

    def start_special_demo_mode(self):
        # Matrix demo is intentionally unavailable.
        self.state.special_demo_mode = False
        return

    def toggle_special_demo_mode(self):
        self.stop_special_demo_mode(redraw_face=True)
        print("special demo mode = disabled")

    def check_special_demo_combo(self):
        # Matrix demo button control is completely disabled in this build.
        # B3+B6 is consumed so it never toggles auto mode or B6 battery mode,
        # but it does not enter any demo renderer.
        b3_down = self.buttons.is_down(BTN_AUTO)
        b6_down = self.buttons.is_down(BTN_BRIGHT_RST)
        if b3_down and b6_down:
            self.state.b3_consumed = True
            self.state.b6_pending = False
            self.state.b6_long_fired = False
            self.state.combo_press_started_ms = None
            self.state.combo_long_fired = False
            return True
        self.state.combo_press_started_ms = None
        self.state.combo_long_fired = False
        self.state.special_demo_mode = False
        return False

    def check_badapple_combo(self):
        # Bad Apple is intentionally excluded in this integrated build.
        self.state.badapple_combo_press_started_ms = None
        self.state.badapple_combo_long_fired = False
        return False

    # ------------------------------------------------------------------
    # User actions
    # ------------------------------------------------------------------
    def cycle_face(self, delta):
        self.stop_webui_runtime(redraw=False)
        self.state.special_demo_mode = False
        self.state.face_idx = (self.state.face_idx + delta) % max(1, saved_faces_370.count())
        self.stop_battery_display()
        self.cancel_flash_and_redraw()

    def adjust_interval(self, delta):
        self.state.special_demo_mode = False
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


    def sync_protocol_brightness_from_buttons(self):
        # Keep web/API brightness in sync after hardware button changes.
        if self.proto is not None and hasattr(self.proto, "bright"):
            try:
                self.proto.bright = int(effective_brightness(self.state.brightness, badapple_mode=False, demo_mode=False))
            except Exception as exc:
                print("brightness state sync failed:", exc)

    def adjust_brightness(self, delta):
        old_val = self.state.brightness
        self.state.brightness = clamp_brightness(self.state.brightness + delta)
        self.apply_brightness()
        self.sync_protocol_brightness_from_buttons()
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
        self.sync_protocol_brightness_from_buttons()
        if self.state.brightness != old_val:
            self.save_settings()
        self.stop_battery_display()
        display_num.render_brightness_percent(self.state.brightness)
        self.start_or_extend_flash("brightness", self.state.brightness)

    def set_manual_control_mode(self, enabled=True, redraw=False, source=""):
        enabled = bool(enabled)
        if enabled:
            # Manual mode means physical/button ownership.  Stop WebUI-owned
            # animations and force saved-face cycling into manual (M) mode.
            self.stop_webui_runtime(redraw=False)
            self.state.special_demo_mode = False
            self.state.auto = False
            self.state.flash_active = False
            self.state.edge_flash_active = False
            self.state.battery_display_active = False
            self.state.battery_display_single_shot = False
            self.state.ip_display_active = False
            self.state.b6_pending = False
            self.state.b6_long_fired = False
        self.state.manual_control_mode = enabled
        print("manual_control_mode =", enabled, source)
        if redraw:
            self.draw_current_face()
        return self.state.manual_control_mode

    def enter_manual_control_from_button(self, gp=None):
        # Every physical button press transfers authority back to local/manual
        # control.  The specific button action then continues as before.
        src = "button" if gp is None else "button GPIO{}".format(gp)
        self.set_manual_control_mode(True, redraw=False, source=src)

    def exit_manual_control_from_network(self, source="network"):
        # Any external/WebUI control cancels saved-face auto cycling.
        # This forces the A/M display logic back to M mode without writing
        # settings on every web packet.  Button B3 still owns persistent
        # A/M toggling through toggle_auto().
        if self.state.auto:
            print("auto = False", source)
        if self.state.manual_control_mode:
            print("manual_control_mode = False", source)
        self.state.manual_control_mode = False
        self.state.auto = False
        return False

    def manual_control_status_json(self):
        return "{\"manual_control_mode\":" + ("true" if self.state.manual_control_mode else "false") + ",\"auto\":" + ("true" if self.state.auto else "false") + "}"

    def toggle_auto(self):
        self.set_manual_control_mode(True, redraw=False, source="button auto-toggle")
        self.stop_webui_runtime(redraw=False)
        self.state.special_demo_mode = False
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
        combo_b2_b6 = self.buttons.is_down(BTN_NEXT) and self.buttons.is_down(BTN_BRIGHT_RST)  # B2+B6 shows STA IP
        combo_b4_b5 = self.buttons.is_down(BTN_BRIGHT_DN) and self.buttons.is_down(BTN_BRIGHT_UP)
        if combo_b3_b6 or combo_b2_b6:
            self.enter_manual_control_from_button(gp)
            return

        self.enter_manual_control_from_button(gp)
        now = time.ticks_ms()
        if gp in (BTN_BRIGHT_DN, BTN_BRIGHT_UP) and combo_b4_b5:
            if time.ticks_diff(now, self.state.brightness_reset_ignore_until_ms) < 0:
                return
            if not self.state.brightness_reset_combo_latched:
                self.state.brightness_reset_combo_latched = True
                self.reset_brightness()
                self.state.brightness_reset_ignore_until_ms = time.ticks_add(now, BRIGHTNESS_RESET_IGNORE_MS)
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
    # WebUI firmware-side runtime integration
    # ------------------------------------------------------------------
    def handle_webui_runtime_command(self, command):
        # Runtime status is a read-only query.  Every other WebUI runtime
        # command (scroll start/stop, timeline load/play/stop/clear/preview)
        # is an external control and must force A/M back to M mode.
        try:
            low = str(command or "").strip().lower()
        except Exception:
            low = ""
        if low != "runtimestatus":
            self.exit_manual_control_from_network("webui runtime command")
        return self.web_runtime.handle_command(command)

    def select_saved_face(self, index, redraw=True):
        self.exit_manual_control_from_network("selectFace370")
        self.stop_webui_runtime(redraw=False)
        self.state.special_demo_mode = False
        self.state.auto = False
        try:
            idx = int(index)
        except Exception:
            idx = 0
        count = max(1, saved_faces_370.count())
        self.state.face_idx = idx % count
        self.stop_battery_display()
        if redraw:
            self.draw_current_face()
        return saved_faces_370.get(self.state.face_idx)

    def on_saved_faces_changed(self, selected_index=None, redraw=False):
        count = max(1, saved_faces_370.count())
        if selected_index is not None:
            try:
                self.state.face_idx = int(selected_index) % count
            except Exception:
                self.state.face_idx = 0
        elif self.state.face_idx >= count:
            self.state.face_idx = count - 1
        if redraw:
            self.draw_current_face()
        return saved_faces_370.get(self.state.face_idx)

    def stop_webui_runtime(self, redraw=True):
        try:
            return self.web_runtime.stop(redraw=redraw)
        except Exception as exc:
            print("webui runtime stop failed:", exc)
            return False

    # ------------------------------------------------------------------
    # Network / protocol integration
    # ------------------------------------------------------------------
    def attach_network(self, link, proto):
        self.link = link
        self.proto = proto
        def _poll():
            # Service both HTTP API requests and UDP packets from the native
            # ESP32-S3 network layer. Limit the number of packets per loop so
            # LED animation timing still gets CPU time.
            for _ in range(4):
                pkt = link.get_packet()
                if pkt is None:
                    return
                link_id, remote_ip, remote_port, payload = pkt
                try:
                    proto.handle_packet(payload, remote_ip, remote_port, link_id)
                except Exception as exc:
                    print("packet error:", exc)
                    try:
                        proto.send(remote_ip, REMOTE_UDP_PORT, b"Command Error!", link_id)
                    except Exception as send_exc:
                        print("send error:", send_exc)
        self.network_poll = _poll

    def service_network(self):
        if self.network_poll is not None:
            self.network_poll()

    def on_network_control(self):
        self.exit_manual_control_from_network("network control")
        self.stop_webui_runtime(redraw=False)
        self.button_face_active = False
        self.state.special_demo_mode = False
        self.state.auto = False
        self.state.flash_active = False
        self.state.edge_flash_active = False
        self.state.battery_display_active = False
        self.state.battery_display_single_shot = False
        self.state.ip_display_active = False
        self.state.b6_pending = False
        self.state.b6_long_fired = False

    def on_protocol_color_updated(self, color):
        # Home/Web color is authoritative.  Button-selected faces redraw with
        # this color, so web mode and button mode stay visually synchronized.
        if self.button_face_active and self.proto is not None and getattr(self.proto, "display_mode", "legacy") == "physical":
            try:
                self.draw_current_face()
            except Exception:
                pass

    def on_protocol_brightness_updated(self, bright):
        # Web brightness is a raw 10..128 protocol value.  Map it to the
        # board's percent brightness so later button-mode renders use the
        # same visible brightness range.
        try:
            pct = int((int(bright) * 100 + 85) // 170)
        except Exception:
            return
        if pct < BRIGHTNESS_MIN:
            pct = BRIGHTNESS_MIN
        if pct > BRIGHTNESS_MAX:
            pct = BRIGHTNESS_MAX
        if self.state.brightness != pct:
            self.state.brightness = pct
            self.apply_brightness()
            self.save_settings()

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
    def print_startup_info(self):
        print(FIRMWARE_BANNER)
        print("Firmware version:", VERSION)
        print("linaboard: starting")
        print("  default face interval=", DEFAULT_INTERVAL_S, "s")
        print("  matrix demo        = disabled")
        print("  default brightness   =", DEFAULT_BRIGHTNESS, "%")
        print("  button GPIOs         =", self.buttons.gpios())
        print("  battery adc gpio     =", BATTERY_ADC_GPIO)
        print("  divider              = 100k top, 57k bottom")
        print("  B3+B6 matrix demo = disabled/consumed")
        print("  B2+B6 scroll IP/SSID = enabled")
        print("  saved custom faces  =", saved_faces_370.count(), "faces; B1/B2 and A/M cycle this list")
        print("  webui runtime       = firmware-side scroll text + Unity timeline playback")
        print("  face manager store  = ESP32-S3 firmware source of truth; WebUI pulls/syncs list")
        print("  A/M behavior        = button toggles A/M; any WebUI/network control forces M")
        print("  bad apple           = excluded in this build")

    def initialize(self):
        self.print_startup_info()
        load_settings(self.state, self.battery)
        print("  learned min/max      = {:.2f} / {:.2f} V".format(self.battery.min_v, self.battery.max_v))
        print("  display mean update  =", BATTERY_MEAN_UPDATE_MS, "ms")
        print("  mean sample interval =", BATTERY_MEAN_SAMPLE_INTERVAL_MS, "ms")
        print("  display toggle cycle =", BATTERY_DISPLAY_CYCLE_MS, "ms")
        print("  display tolerance    = {:.2f} V".format(BATTERY_DISPLAY_TOL_V))
        print("  charge detect adc    =", CHARGE_DETECT_ADC_GPIO)
        print("  network             = ESP32-S3 native Wi-Fi + HTTP + UDP, no ESP8258 bridge")
        self.apply_brightness()
        print("  startup LED animation = disabled")
        # Draw the current saved face immediately.  No initLED/WIFI/UDP/READY
        # boot/status animation is shown on the LED matrix.
        self.draw_current_face()
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
            self.service_network()
            combo_active = self.check_special_demo_combo()
            combo_active = self.check_badapple_combo() or combo_active
            combo_active = self.check_ip_combo() or combo_active

            for gp in self.buttons.poll():
                self.handle_press(gp)
                next_auto_ms = time.ticks_add(time.ticks_ms(), int(self.state.interval_s * 1000))

            combo_active = self.check_special_demo_combo() or combo_active
            combo_active = self.check_badapple_combo() or combo_active
            combo_active = self.check_ip_combo() or combo_active

            self.check_b6_hold()
            self.service_battery_overlay()
            self.service_ip_display()
            self.web_runtime.service()

            if (self.state.brightness_reset_combo_latched and
                    not self.buttons.is_down(BTN_BRIGHT_DN) and
                    not self.buttons.is_down(BTN_BRIGHT_UP)):
                self.state.brightness_reset_combo_latched = False

            prev_b3_down = self.check_b3_release(prev_b3_down)
            prev_b6_down = self.check_b6_release(prev_b6_down)

            if not self.state.battery_display_active and not self.state.ip_display_active:
                self.end_flash_if_expired()

            if self.state.flash_active and self.state.edge_flash_active:
                self.render_flash_overlay_with_edge()
            elif self.state.edge_flash_active and not self.state.flash_active:
                self.state.edge_flash_active = False

            self.service_battery_sampling()
            self.battery_monitor.update_calibration(self.battery, self.state, self.save_settings)


            if self.state.auto and not self.web_runtime.active() and not self.state.flash_active and not self.state.battery_display_active and not self.state.ip_display_active:
                now = time.ticks_ms()
                if time.ticks_diff(now, next_auto_ms) >= 0:
                    self.state.face_idx = (self.state.face_idx + 1) % max(1, saved_faces_370.count())
                    self.draw_current_face()
                    next_auto_ms = time.ticks_add(now, int(self.state.interval_s * 1000))

            if self.web_runtime.active() or self.state.flash_active or self.state.battery_display_active or self.state.ip_display_active or combo_active:
                next_auto_ms = time.ticks_add(time.ticks_ms(), int(self.state.interval_s * 1000))

            time.sleep(POLL_PERIOD_MS / 1000.0)


# ---------------------------------------------------------------------------
# Boot entry point. Load saved settings, apply brightness, draw the saved
# face immediately, then enter the main polling loop forever.
# ---------------------------------------------------------------------------
def main():
    print("ESP32-S3 native: Wi-Fi + HTTP + UDP + LED in one firmware")
    print("LED:", board.hardware_summary())
    app = LinaBoardApp()
    link = ESP32S3Network(log_limit=160)
    link.start()
    proto = RinaProtocol(app=app)
    proto.set_sender(lambda ip, port, data, link_id=0: link.send_udp(data, ip, port, link_id))
    proto.log_provider = link.recent_log
    app.attach_network(link, proto)
    link.ping()
    app.run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        clear()
        show()
        print("stopped.")