# ---------------------------------------------------------------------------
# home_module.py
#
# Home mode, A/M ownership, interval, overlay flash module.
#
# Brightness and color are owned by color_module; calls to
# self.apply_brightness() and self.sync_protocol_brightness_from_buttons()
# are forwarded there automatically via the AppModule proxy.
# ---------------------------------------------------------------------------

# Import: Loads time so this module can use that dependency.
import time

# Import: Loads board so this module can use that dependency.
import board
# Import: Loads logical_to_led_index, np, scale_color, show, COLS, ROWS from board so this module can use that dependency.
from board import logical_to_led_index, np, scale_color, show, COLS, ROWS
# Import: Loads display_num so this module can use that dependency.
import display_num
# Import: Loads * from config so this module can use that dependency.
from config import *
# Import: Loads clamp_interval, clamp_brightness from settings_store so this module can use that dependency.
from settings_store import clamp_interval, clamp_brightness
# Import: Loads BTN_AUTO, BTN_BRIGHT_RST from buttons so this module can use that dependency.
from buttons import BTN_AUTO, BTN_BRIGHT_RST

# Import: Loads AppModule from app_module_base so this module can use that dependency.
from app_module_base import AppModule


# Class: Defines HomeModule as the state and behavior container for Home Module.
class HomeModule(AppModule):

    # ------------------------------------------------------------------
    # Edge flash overlay
    # ------------------------------------------------------------------

    # Function: Defines start_edge_flash(self, edge) to handle start edge flash behavior.
    def start_edge_flash(self, edge):
        # Variable: self.state.edge_flash_active stores the enabled/disabled flag value.
        self.state.edge_flash_active = True
        # Variable: self.state.edge_flash_edge stores the current edge value.
        self.state.edge_flash_edge = edge
        # Variable: self.state.edge_flash_started_ms stores the result returned by time.ticks_ms().
        self.state.edge_flash_started_ms = time.ticks_ms()

    # Function: Defines edge_flash_factor(self, elapsed_ms) to handle edge flash factor behavior.
    def edge_flash_factor(self, elapsed_ms):
        # Logic: Branches when elapsed_ms < 0 or elapsed_ms > EDGE_FLASH_TOTAL_MS so the correct firmware path runs.
        if elapsed_ms < 0 or elapsed_ms > EDGE_FLASH_TOTAL_MS:
            # Return: Sends the configured literal value back to the caller.
            return 0.0
        # Logic: Branches when elapsed_ms <= EDGE_FLASH_ATTACK_MS so the correct firmware path runs.
        if elapsed_ms <= EDGE_FLASH_ATTACK_MS:
            # Return: Sends the calculated expression elapsed_ms / float(EDGE_FLASH_ATTACK_MS) back to the caller.
            return elapsed_ms / float(EDGE_FLASH_ATTACK_MS)
        # Variable: t stores the calculated expression (elapsed_ms - EDGE_FLASH_ATTACK_MS) / float(EDGE_FLASH_DECAY_MS).
        t = (elapsed_ms - EDGE_FLASH_ATTACK_MS) / float(EDGE_FLASH_DECAY_MS)
        # Return: Sends the calculated expression 1.0 - t back to the caller.
        return 1.0 - t

    # Function: Defines overlay_edge_flash(self) to handle overlay edge flash behavior.
    def overlay_edge_flash(self):
        # Logic: Branches when not self.state.edge_flash_active so the correct firmware path runs.
        if not self.state.edge_flash_active:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False

        # Variable: elapsed stores the result returned by time.ticks_diff().
        elapsed = time.ticks_diff(time.ticks_ms(), self.state.edge_flash_started_ms)
        # Variable: factor stores the result returned by self.edge_flash_factor().
        factor = self.edge_flash_factor(elapsed)
        # Logic: Branches when factor <= 0.0 so the correct firmware path runs.
        if factor <= 0.0:
            # Variable: self.state.edge_flash_active stores the enabled/disabled flag value.
            self.state.edge_flash_active = False
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False

        # Variable: y stores the conditional expression 0 if self.state.edge_flash_edge == "top" else (ROWS - 1).
        y = 0 if self.state.edge_flash_edge == "top" else (ROWS - 1)
        # Variable: center stores the calculated expression (COLS - 1) / 2.0.
        center = (COLS - 1) / 2.0
        # Variable: max_dist stores the conditional expression center if center > 0 else 1.0.
        max_dist = center if center > 0 else 1.0

        # Loop: Iterates x over range(COLS) so each item can be processed.
        for x in range(COLS):
            # Variable: idx stores the result returned by logical_to_led_index().
            idx = logical_to_led_index(x, y)
            # Logic: Branches when idx is None so the correct firmware path runs.
            if idx is None:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Variable: dist stores the result returned by abs().
            dist = abs(x - center)
            # Variable: spatial stores the calculated expression 1.0 - (dist / max_dist).
            spatial = 1.0 - (dist / max_dist)
            # Logic: Branches when spatial < 0.20 so the correct firmware path runs.
            if spatial < 0.20:
                # Variable: spatial stores the configured literal value.
                spatial = 0.20
            # Variable: level stores the calculated expression factor * spatial.
            level = factor * spatial
            # Logic: Branches when level <= 0.0 so the correct firmware path runs.
            if level <= 0.0:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Variable: flash_color stores the current EDGE_FLASH_COLOR value.
            flash_color = EDGE_FLASH_COLOR
            # Logic: Branches when self.state.flash_kind == "interval" so the correct firmware path runs.
            if self.state.flash_kind == "interval":
                # Variable: flash_color stores the referenced display_num.MODE_COLOR value.
                flash_color = display_num.MODE_COLOR
            # Variable: np[...] stores the result returned by scale_color().
            np[idx] = scale_color((
                int(flash_color[0] * level),
                int(flash_color[1] * level),
                int(flash_color[2] * level),
            ))
        # Expression: Calls show() for its side effects.
        show()
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # ------------------------------------------------------------------
    # Flash overlay (brightness / interval / mode feedback)
    # ------------------------------------------------------------------

    # Function: Defines render_flash_overlay_base(self) to handle render flash overlay base behavior.
    def render_flash_overlay_base(self):
        # Logic: Branches when self.state.flash_kind == "interval" so the correct firmware path runs.
        if self.state.flash_kind == "interval":
            # Expression: Calls display_num.render_interval() for its side effects.
            display_num.render_interval(self.state.flash_value)
        # Logic: Branches when self.state.flash_kind == "brightness" so the correct firmware path runs.
        elif self.state.flash_kind == "brightness":
            # Expression: Calls display_num.render_brightness_percent() for its side effects.
            display_num.render_brightness_percent(self.state.flash_value)
        # Logic: Branches when self.state.flash_kind == "mode" so the correct firmware path runs.
        elif self.state.flash_kind == "mode":
            # Expression: Calls display_num.render_mode() for its side effects.
            display_num.render_mode(self.state.flash_value)

    # Function: Defines render_flash_overlay_with_edge(self) to handle render flash overlay with edge behavior.
    def render_flash_overlay_with_edge(self):
        # Logic: Branches when not self.state.flash_active so the correct firmware path runs.
        if not self.state.flash_active:
            # Return: Sends control back to the caller.
            return
        # Expression: Calls self.render_flash_overlay_base() for its side effects.
        self.render_flash_overlay_base()
        # Expression: Calls self.overlay_edge_flash() for its side effects.
        self.overlay_edge_flash()

    # Function: Defines start_or_extend_flash(self, kind, value) to handle start or extend flash behavior.
    def start_or_extend_flash(self, kind=None, value=None):
        # Variable: self.state.flash_active stores the enabled/disabled flag value.
        self.state.flash_active = True
        # Variable: self.state.flash_kind stores the current kind value.
        self.state.flash_kind = kind
        # Variable: self.state.flash_value stores the current value value.
        self.state.flash_value = value
        # Variable: self.state.flash_expires_ms stores the result returned by time.ticks_add().
        self.state.flash_expires_ms = time.ticks_add(time.ticks_ms(), FLASH_HOLD_MS)

    # Function: Defines end_flash_if_expired(self) to handle end flash if expired behavior.
    def end_flash_if_expired(self):
        # Logic: Branches when not self.state.flash_active so the correct firmware path runs.
        if not self.state.flash_active:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Logic: Branches when time.ticks_diff(time.ticks_ms(), self.state.flash_expires_ms) >= 0 so the correct firmware path runs.
        if time.ticks_diff(time.ticks_ms(), self.state.flash_expires_ms) >= 0:
            # Variable: self.state.flash_active stores the enabled/disabled flag value.
            self.state.flash_active = False
            # Variable: self.state.flash_kind stores the empty sentinel value.
            self.state.flash_kind = None
            # Variable: self.state.flash_value stores the empty sentinel value.
            self.state.flash_value = None
            # Expression: Calls self.render_current_visual() for its side effects.
            self.render_current_visual(force=True)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False

    # Function: Defines cancel_flash_and_redraw(self) to handle cancel flash and redraw behavior.
    def cancel_flash_and_redraw(self):
        # Variable: self.state.flash_active stores the enabled/disabled flag value.
        self.state.flash_active = False
        # Variable: self.state.flash_kind stores the empty sentinel value.
        self.state.flash_kind = None
        # Variable: self.state.flash_value stores the empty sentinel value.
        self.state.flash_value = None
        # Expression: Calls self.render_current_visual() for its side effects.
        self.render_current_visual(force=True)

    # ------------------------------------------------------------------
    # B3 + B6 combo guard
    #
    # Holding B3+B6 simultaneously is consumed here so it can never
    # accidentally fire the B6 battery display or the B3 A/M toggle.
    # No demo mode exists; this is purely a guard.
    # ------------------------------------------------------------------

    # Function: Defines check_special_demo_combo(self) to handle check special demo combo behavior.
    def check_special_demo_combo(self):
        # Variable: b3_down stores the result returned by self.buttons.is_down().
        b3_down = self.buttons.is_down(BTN_AUTO)
        # Variable: b6_down stores the result returned by self.buttons.is_down().
        b6_down = self.buttons.is_down(BTN_BRIGHT_RST)
        # Logic: Branches when b3_down and b6_down so the correct firmware path runs.
        if b3_down and b6_down:
            # Consume both buttons so neither fires its solo action.
            # Variable: self.state.b3_consumed stores the enabled/disabled flag value.
            self.state.b3_consumed = True
            # Variable: self.state.b6_pending stores the enabled/disabled flag value.
            self.state.b6_pending = False
            # Variable: self.state.b6_long_fired stores the enabled/disabled flag value.
            self.state.b6_long_fired = False
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False

    # ------------------------------------------------------------------
    # Brightness (delegates apply/sync to color_module via app proxy)
    # ------------------------------------------------------------------

    # Function: Defines adjust_brightness(self, delta) to handle adjust brightness behavior.
    def adjust_brightness(self, delta):
        # Variable: old_val stores the referenced self.state.brightness value.
        old_val = self.state.brightness
        # Variable: self.state.brightness stores the result returned by clamp_brightness().
        self.state.brightness = clamp_brightness(self.state.brightness + delta)
        # Expression: Calls self.apply_brightness() for its side effects.
        self.apply_brightness()
        # Expression: Calls self.sync_protocol_brightness_from_buttons() for its side effects.
        self.sync_protocol_brightness_from_buttons()
        # Logic: Branches when self.state.brightness != old_val so the correct firmware path runs.
        if self.state.brightness != old_val:
            # Expression: Calls self.save_settings() for its side effects.
            self.save_settings()
        # Logic: Branches when delta < 0 and self.state.brightness <= BRIGHTNESS_MIN so the correct firmware path runs.
        if delta < 0 and self.state.brightness <= BRIGHTNESS_MIN:
            # Expression: Calls self.start_edge_flash() for its side effects.
            self.start_edge_flash("bottom")
        # Logic: Branches when delta > 0 and self.state.brightness >= BRIGHTNESS_MAX so the correct firmware path runs.
        elif delta > 0 and self.state.brightness >= BRIGHTNESS_MAX:
            # Expression: Calls self.start_edge_flash() for its side effects.
            self.start_edge_flash("top")
        # Expression: Calls self.stop_battery_display() for its side effects.
        self.stop_battery_display()
        # Expression: Calls display_num.render_brightness_percent() for its side effects.
        display_num.render_brightness_percent(self.state.brightness)
        # Expression: Calls self.overlay_edge_flash() for its side effects.
        self.overlay_edge_flash()
        # Expression: Calls self.start_or_extend_flash() for its side effects.
        self.start_or_extend_flash("brightness", self.state.brightness)

    # Function: Defines reset_brightness(self) to handle reset brightness behavior.
    def reset_brightness(self):
        # Variable: old_val stores the referenced self.state.brightness value.
        old_val = self.state.brightness
        # Variable: self.state.brightness stores the current DEFAULT_BRIGHTNESS value.
        self.state.brightness = DEFAULT_BRIGHTNESS
        # Expression: Calls self.apply_brightness() for its side effects.
        self.apply_brightness()
        # Expression: Calls self.sync_protocol_brightness_from_buttons() for its side effects.
        self.sync_protocol_brightness_from_buttons()
        # Logic: Branches when self.state.brightness != old_val so the correct firmware path runs.
        if self.state.brightness != old_val:
            # Expression: Calls self.save_settings() for its side effects.
            self.save_settings()
        # Expression: Calls self.stop_battery_display() for its side effects.
        self.stop_battery_display()
        # Expression: Calls display_num.render_brightness_percent() for its side effects.
        display_num.render_brightness_percent(self.state.brightness)
        # Expression: Calls self.start_or_extend_flash() for its side effects.
        self.start_or_extend_flash("brightness", self.state.brightness)

    # ------------------------------------------------------------------
    # Interval
    # ------------------------------------------------------------------

    # Function: Defines adjust_interval(self, delta) to handle adjust interval behavior.
    def adjust_interval(self, delta):
        # Variable: old_val stores the referenced self.state.interval_s value.
        old_val = self.state.interval_s
        # Variable: self.state.interval_s stores the result returned by clamp_interval().
        self.state.interval_s = clamp_interval(self.state.interval_s + delta)
        # Logic: Branches when self.state.interval_s != old_val so the correct firmware path runs.
        if self.state.interval_s != old_val:
            # Expression: Calls self.save_settings() for its side effects.
            self.save_settings()
        # Logic: Branches when delta < 0 and self.state.interval_s <= INTERVAL_MIN_S so the correct firmware path runs.
        if delta < 0 and self.state.interval_s <= INTERVAL_MIN_S:
            # Expression: Calls self.start_edge_flash() for its side effects.
            self.start_edge_flash("bottom")
        # Logic: Branches when delta > 0 and self.state.interval_s >= INTERVAL_MAX_S so the correct firmware path runs.
        elif delta > 0 and self.state.interval_s >= INTERVAL_MAX_S:
            # Expression: Calls self.start_edge_flash() for its side effects.
            self.start_edge_flash("top")
        # Expression: Calls self.stop_battery_display() for its side effects.
        self.stop_battery_display()
        # Expression: Calls display_num.render_interval() for its side effects.
        display_num.render_interval(self.state.interval_s)
        # Expression: Calls self.start_or_extend_flash() for its side effects.
        self.start_or_extend_flash("interval", self.state.interval_s)
        # Expression: Calls self.overlay_edge_flash() for its side effects.
        self.overlay_edge_flash()

    # ------------------------------------------------------------------
    # A/M mode and manual control
    # ------------------------------------------------------------------

    # Function: Defines force_m_mode(self, source, persist) to handle force m mode behavior.
    def force_m_mode(self, source="network", persist=True):
        # Module: Documents the purpose of this scope.
        """Cancel auto cycling without showing the M overlay (used by WebUI)."""
        # Variable: was_auto stores the result returned by bool().
        was_auto = bool(self.state.auto)
        # Variable: self.state.auto stores the enabled/disabled flag value.
        self.state.auto = False
        # Logic: Branches when was_auto so the correct firmware path runs.
        if was_auto:
            # Expression: Calls print() for its side effects.
            print("auto = False (M mode)", source)
            # Logic: Branches when persist so the correct firmware path runs.
            if persist:
                # Expression: Calls self.save_settings() for its side effects.
                self.save_settings()
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False

    # Function: Defines set_manual_control_mode(self, enabled, redraw, source) to handle set manual control mode behavior.
    def set_manual_control_mode(self, enabled=True, redraw=False, source=""):
        # Variable: enabled stores the result returned by bool().
        enabled = bool(enabled)
        # Logic: Branches when enabled so the correct firmware path runs.
        if enabled:
            # Manual mode = physical/button authority.  Stop WebUI animations
            # and cancel auto cycling.
            # Expression: Calls self.stop_webui_runtime() for its side effects.
            self.stop_webui_runtime(redraw=False)
            # Expression: Calls self.force_m_mode() for its side effects.
            self.force_m_mode(source or "manual control", persist=False)
            # Variable: self.state.flash_active stores the enabled/disabled flag value.
            self.state.flash_active = False
            # Variable: self.state.edge_flash_active stores the enabled/disabled flag value.
            self.state.edge_flash_active = False
            # Variable: self.state.battery_display_active stores the enabled/disabled flag value.
            self.state.battery_display_active = False
            # Variable: self.state.battery_display_single_shot stores the enabled/disabled flag value.
            self.state.battery_display_single_shot = False
            # Variable: self.state.ip_display_active stores the enabled/disabled flag value.
            self.state.ip_display_active = False
            # Variable: self.state.b6_pending stores the enabled/disabled flag value.
            self.state.b6_pending = False
            # Variable: self.state.b6_long_fired stores the enabled/disabled flag value.
            self.state.b6_long_fired = False
        # Variable: self.state.manual_control_mode stores the current enabled value.
        self.state.manual_control_mode = enabled
        # Expression: Calls print() for its side effects.
        print("manual_control_mode =", enabled, source)
        # Logic: Branches when redraw so the correct firmware path runs.
        if redraw:
            # Expression: Calls self.draw_current_face() for its side effects.
            self.draw_current_face()
        # Return: Sends the referenced self.state.manual_control_mode value back to the caller.
        return self.state.manual_control_mode

    # Function: Defines enter_manual_control_from_button(self, gp) to handle enter manual control from button behavior.
    def enter_manual_control_from_button(self, gp=None):
        # Variable: src stores the conditional expression "button" if gp is None else "button GPIO{}".format(gp).
        src = "button" if gp is None else "button GPIO{}".format(gp)
        # Expression: Calls self.set_manual_control_mode() for its side effects.
        self.set_manual_control_mode(True, redraw=False, source=src)

    # Function: Defines exit_manual_control_from_network(self, source) to handle exit manual control from network behavior.
    def exit_manual_control_from_network(self, source="network"):
        # Logic: Branches when self.state.manual_control_mode so the correct firmware path runs.
        if self.state.manual_control_mode:
            # Expression: Calls print() for its side effects.
            print("manual_control_mode = False", source)
        # Variable: self.state.manual_control_mode stores the enabled/disabled flag value.
        self.state.manual_control_mode = False
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False

    # Function: Defines manual_control_status_json(self) to handle manual control status json behavior.
    def manual_control_status_json(self):
        # Return: Sends the calculated expression "{\"manual_control_mode\":" + ("true" if self.state.manual_control_mode else "false")... back to the caller.
        return (
            "{\"manual_control_mode\":"
            + ("true" if self.state.manual_control_mode else "false")
            + ",\"auto\":"
            + ("true" if self.state.auto else "false")
            + "}"
        )

    # Function: Defines toggle_auto(self) to handle toggle auto behavior.
    def toggle_auto(self):
        # Preserve the A/M state that existed before the B3 press so that
        # entering manual-control mode doesn't prevent B3 from toggling to A.
        # Variable: old_auto stores the result returned by bool().
        old_auto = bool(self.state.auto)
        # Expression: Calls self.set_manual_control_mode() for its side effects.
        self.set_manual_control_mode(True, redraw=False, source="button auto-toggle")
        # Expression: Calls self.stop_webui_runtime() for its side effects.
        self.stop_webui_runtime(redraw=False)
        # Variable: self.state.auto stores the calculated unary expression not old_auto.
        self.state.auto = not old_auto
        # Expression: Calls self.save_settings() for its side effects.
        self.save_settings()
        # Expression: Calls print() for its side effects.
        print("auto =", self.state.auto)
        # Expression: Calls self.stop_battery_display() for its side effects.
        self.stop_battery_display()
        # Expression: Calls display_num.render_mode() for its side effects.
        display_num.render_mode(self.state.auto)
        # Expression: Calls self.start_or_extend_flash() for its side effects.
        self.start_or_extend_flash("mode", self.state.auto)
