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


import time

try:
    from machine import Pin
except ImportError:
    Pin = None

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
from battery_runtime import estimate_remaining_hours
from brightness_modes import effective_brightness


# ---------------------------------------------------------------------------
# Main application object.
# It owns runtime state, helpers, and the polling loop behavior.
# ---------------------------------------------------------------------------
class LinaBoardApp:
    __slots__ = ("state", "battery", "buttons", "battery_monitor", "charge_pin")

    def __init__(self):
        # Create all shared runtime objects used by the app loop.
        self.state = AppState()
        self.battery = BatteryState()
        self.buttons = ButtonBank()
        self.battery_monitor = BatteryMonitor()
        self.charge_pin = None
        if CHARGE_STATUS_GPIO is not None and Pin is not None:
            try:
                if CHARGE_STATUS_ACTIVE_LOW:
                    self.charge_pin = Pin(CHARGE_STATUS_GPIO, Pin.IN, Pin.PULL_UP)
                else:
                    self.charge_pin = Pin(CHARGE_STATUS_GPIO, Pin.IN)
            except Exception as e:
                print("charge detect init failed:", e)
                self.charge_pin = None

    # ------------------------------------------------------------------
    # Persistence / shared runtime helpers
    # ------------------------------------------------------------------
    def save_settings(self):
        save_settings(self.state, self.battery)

    def apply_brightness(self):
        board.set_max_brightness(effective_brightness(
            self.state.brightness,
            badapple_mode=self.state.badapple_mode,
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
            np[idx] = scale_color((
                int(EDGE_FLASH_COLOR[0] * level),
                int(EDGE_FLASH_COLOR[1] * level),
                int(EDGE_FLASH_COLOR[2] * level),
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
        self.render_current_visual(force=True)

    # ------------------------------------------------------------------
    # Battery display helpers
    # ------------------------------------------------------------------
    def is_charging(self):
        if self.charge_pin is None:
            return False
        try:
            value = self.charge_pin.value()
        except Exception:
            return False
        return (value == 0) if CHARGE_STATUS_ACTIVE_LOW else (value == 1)

    def refresh_battery_overlay_cache(self, force=False):
        now = time.ticks_ms()
        if (not force and self.state.battery_next_refresh_ms and
                time.ticks_diff(now, self.state.battery_next_refresh_ms) < 0):
            return False

        v_bat = self.battery_monitor.read_voltage_mean(
            BATTERY_DISPLAY_MEAN_WINDOW_MS,
            BATTERY_DISPLAY_MEAN_SAMPLE_DELAY_MS,
        )
        pct = self.battery_monitor.percent_from_voltage(v_bat, self.battery)
        pct_float = self.battery_monitor.percent_float_from_voltage(v_bat, self.battery)
        if v_bat is not None:
            self.battery.last_voltage = v_bat
        remaining_h = estimate_remaining_hours(self.battery, self.state, pct_float)

        self.state.battery_display_cached_voltage = v_bat
        self.state.battery_display_cached_percent = pct
        self.state.battery_display_cached_percent_float = pct_float
        self.state.battery_display_cached_remaining_h = remaining_h
        self.state.battery_next_refresh_ms = time.ticks_add(now, BATTERY_REFRESH_MS)
        return True

    def update_battery_display_phase(self):
        if not self.state.battery_display_active:
            return
        now = time.ticks_ms()
        while (self.state.battery_display_next_phase_ms and
               time.ticks_diff(now, self.state.battery_display_next_phase_ms) >= 0):
            self.state.battery_display_phase_index = (self.state.battery_display_phase_index + 1) % 3
            self.state.battery_display_next_phase_ms = time.ticks_add(
                self.state.battery_display_next_phase_ms,
                BATTERY_DISPLAY_CYCLE_MS,
            )

    def render_battery_overlay(self):
        self.update_battery_display_phase()
        self.refresh_battery_overlay_cache(force=False)

        v_bat = self.state.battery_display_cached_voltage
        pct = self.state.battery_display_cached_percent
        pct_float = self.state.battery_display_cached_percent_float
        remaining_h = self.state.battery_display_cached_remaining_h

        if pct is None:
            print("battery monitor unavailable")
            display_num.render_battery_percent(0, color=(255, 0, 0))
            return

        color = self.battery_monitor.color(pct)
        cycle_index = self.state.battery_display_phase_index
        phase_name = ("percent", "voltage", "time")[cycle_index]
        charging = self.is_charging()
        charging_phase_ms = time.ticks_diff(time.ticks_ms(), self.state.battery_display_toggle_started_ms)
        charge_step_interval_s = self.battery_monitor.charge_animation_step_interval_s(pct)
        flash_last_column = pct >= 90

        if remaining_h is None:
            remain_text = "unknown"
        elif remaining_h < 1.0:
            remain_text = "{} min".format(int(round(remaining_h * 60.0)))
        else:
            remain_text = "{:.1f} h".format(remaining_h)

        print("battery display: mean={:.2f} V over {} ms ({}%), learned min={:.2f} V, learned max={:.2f} V, remaining={}, phase={}, charging={}".format(
            v_bat if v_bat is not None else 0.0,
            BATTERY_DISPLAY_MEAN_WINDOW_MS,
            pct,
            self.battery.min_v,
            self.battery.max_v,
            remain_text,
            phase_name,
            charging))

        if cycle_index == 0:
            display_num.render_battery_percent(
                pct, color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
            )
        elif cycle_index == 1:
            display_num.render_battery_voltage(
                v_bat, pct, color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
            )
        else:
            display_num.render_battery_time(
                remaining_h, pct, color=color, charging=charging,
                charging_phase_ms=charging_phase_ms,
                charge_step_interval_s=charge_step_interval_s,
                flash_last_column=flash_last_column,
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
            self.state.battery_display_toggle_started_ms = now
            self.state.battery_display_phase_index = 0
            self.state.battery_display_next_phase_ms = time.ticks_add(now, BATTERY_DISPLAY_CYCLE_MS)
            self.state.battery_next_refresh_ms = 0
            self.refresh_battery_overlay_cache(force=True)
            self.render_battery_overlay()
            return

        if (self.state.battery_display_active and
                time.ticks_diff(now, self.state.battery_next_refresh_ms) >= 0):
            self.render_battery_overlay()
            self.state.battery_next_refresh_ms = time.ticks_add(now, BATTERY_REFRESH_MS)

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
                        self.reset_brightness()
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
            self.overlay_edge_flash()
            self.start_or_extend_flash("interval", self.state.demo_interval_s)
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
        self.overlay_edge_flash()
        self.start_or_extend_flash("interval", self.state.interval_s)

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
        if combo_b3_b6 or combo_b2_b6:
            return

        if self.state.badapple_mode:
            if gp == BTN_BRIGHT_DN:
                self.adjust_brightness(-BRIGHTNESS_STEP)
            elif gp == BTN_BRIGHT_UP:
                self.adjust_brightness(+BRIGHTNESS_STEP)
            elif gp == BTN_BRIGHT_RST:
                self.start_b6_press()
            return

        b3_held = self.buttons.is_down(BTN_AUTO)
        if gp == BTN_PREV:
            if b3_held:
                self.state.b3_consumed = True
                self.adjust_interval(-INTERVAL_STEP_S)
            else:
                self.cycle_face(-1)
        elif gp == BTN_NEXT:
            if b3_held:
                self.state.b3_consumed = True
                self.adjust_interval(+INTERVAL_STEP_S)
            else:
                self.cycle_face(+1)
        elif gp == BTN_AUTO:
            self.state.b3_consumed = False
        elif gp == BTN_BRIGHT_DN:
            self.adjust_brightness(-BRIGHTNESS_STEP)
        elif gp == BTN_BRIGHT_UP:
            self.adjust_brightness(+BRIGHTNESS_STEP)
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
        print("  default brightness   =", DEFAULT_BRIGHTNESS, "/255")
        print("  button GPIOs         =", self.buttons.gpios())
        print("  battery adc gpio     =", BATTERY_ADC_GPIO)
        print("  divider              = 100k top, 57k bottom")
        print("  special demo combo   = hold B6 + B3 for 2 s")
        print("  bad apple combo      = hold B6 + B2 for 2 s")

    def initialize(self):
        self.print_startup_info()
        load_settings(self.state, self.battery)
        print("  learned min/max      = {:.2f} / {:.2f} V".format(self.battery.min_v, self.battery.max_v))
        print("  display mean window  =", BATTERY_DISPLAY_MEAN_WINDOW_MS, "ms")
        print("  display toggle cycle =", BATTERY_DISPLAY_CYCLE_MS, "ms")
        print("  display tolerance    = {:.2f} V".format(BATTERY_DISPLAY_TOL_V))
        print("  charge detect gpio   =", CHARGE_STATUS_GPIO)
        self.apply_brightness()
        self.draw_current_face()
        self.apply_demo_runtime_settings(refresh_timer=False)

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

            self.battery_monitor.update_calibration(self.battery, self.state, self.save_settings)
            self.check_b6_hold()

            prev_b3_down = self.check_b3_release(prev_b3_down)
            prev_b6_down = self.check_b6_release(prev_b6_down)

            if not self.state.battery_display_active:
                self.end_flash_if_expired()

            if self.state.flash_active and self.state.edge_flash_active:
                self.render_flash_overlay_with_edge()
            elif self.state.edge_flash_active and not self.state.flash_active:
                self.state.edge_flash_active = False

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
