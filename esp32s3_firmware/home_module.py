# ---------------------------------------------------------------------------
# home_module.py
#
# Home mode, brightness, interval, overlay flash, and A/M ownership module.
# ---------------------------------------------------------------------------

import time

import board
from board import logical_to_led_index, np, scale_color, show, COLS, ROWS
import display_num
from config import *
from settings_store import clamp_interval, clamp_brightness
from brightness_modes import effective_brightness
from buttons import BTN_AUTO, BTN_BRIGHT_RST

from app_module_base import AppModule


class HomeModule(AppModule):

    def apply_brightness(self):
        board.set_max_brightness(effective_brightness(
            self.state.brightness,
            badapple_mode=False,
            demo_mode=False,
        ))

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

    def force_m_mode(self, source="network", persist=True):
        # M/A fix: any actual external/WebUI control owns the LEDs and must
        # cancel saved-face auto cycling.  This is the same user-visible M
        # state as the B3 A/M toggle, but it does not draw the big "M"
        # overlay because that would overwrite the WebUI command output.
        was_auto = bool(self.state.auto)
        self.state.auto = False
        if was_auto:
            print("auto = False (M mode)", source)
            if persist:
                self.save_settings()
        return False

    def set_manual_control_mode(self, enabled=True, redraw=False, source=""):
        enabled = bool(enabled)
        if enabled:
            # Manual mode means physical/button ownership.  Stop WebUI-owned
            # animations and force saved-face cycling into manual (M) mode.
            self.stop_webui_runtime(redraw=False)
            self.state.special_demo_mode = False
            self.force_m_mode(source or "manual control", persist=False)
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
        if self.state.manual_control_mode:
            print("manual_control_mode = False", source)
        self.state.manual_control_mode = False
        return False

    def manual_control_status_json(self):
        return "{\"manual_control_mode\":" + ("true" if self.state.manual_control_mode else "false") + ",\"auto\":" + ("true" if self.state.auto else "false") + "}"

    def toggle_auto(self):
        # Preserve the A/M state that existed before the B3 press.  Entering
        # manual-control mode intentionally forces M for ordinary GPIO actions,
        # but B3 itself is the A/M toggle; if we force M before computing the
        # toggle, B3 can only ever switch to A.
        old_auto = bool(self.state.auto)
        self.set_manual_control_mode(True, redraw=False, source="button auto-toggle")
        self.stop_webui_runtime(redraw=False)
        self.state.special_demo_mode = False
        self.state.auto = not old_auto
        self.save_settings()
        print("auto =", self.state.auto)
        self.stop_battery_display()
        display_num.render_mode(self.state.auto)
        self.start_or_extend_flash("mode", self.state.auto)

    # ------------------------------------------------------------------
    # Button routing
    # ------------------------------------------------------------------
