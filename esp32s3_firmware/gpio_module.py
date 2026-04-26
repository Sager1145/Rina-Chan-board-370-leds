# ---------------------------------------------------------------------------
# gpio_module.py
#
# GPIO button input module.
# Handles button polling, combo detection, B6 long press, and B3 release.
# Dispatches user actions to other modules via registered callbacks.
# ---------------------------------------------------------------------------

import time
from buttons import (
    ButtonBank,
    BTN_PREV, BTN_NEXT, BTN_AUTO,
    BTN_BRIGHT_DN, BTN_BRIGHT_UP, BTN_BRIGHT_RST,
)
from config import (
    B6_LONG_PRESS_MS, BRIGHTNESS_RESET_IGNORE_MS,
    INTERVAL_STEP_S, BRIGHTNESS_STEP,
)


class GPIOModule:
    """Button input, combo detection, and action dispatch via callbacks."""

    __slots__ = (
        "state", "buttons",
        "prev_b3_down", "prev_b6_down",
        # Callbacks for actions
        "on_cycle_face",          # (delta)
        "on_adjust_interval",     # (delta)
        "on_adjust_brightness",   # (delta)
        "on_reset_brightness",    # ()
        "on_toggle_auto",         # ()
        "on_show_battery_short",  # ()
        "on_show_battery_detail", # ()
        "on_stop_battery",        # ()
        "on_show_ip",             # ()
        "on_enter_manual",        # (gpio_num)
    )

    def __init__(self, state):
        self.state = state
        self.buttons = ButtonBank()
        self.prev_b3_down = False
        self.prev_b6_down = False
        # Action callbacks (set by main.py during wiring)
        self.on_cycle_face = None
        self.on_adjust_interval = None
        self.on_adjust_brightness = None
        self.on_reset_brightness = None
        self.on_toggle_auto = None
        self.on_show_battery_short = None
        self.on_show_battery_detail = None
        self.on_stop_battery = None
        self.on_show_ip = None
        self.on_enter_manual = None

    def gpios(self):
        return self.buttons.gpios()

    # ------------------------------------------------------------------
    # Combo detection
    # ------------------------------------------------------------------
    def check_ip_combo(self):
        """B2+B6 combo -> show IP/SSID scroll."""
        b2_down = self.buttons.is_down(BTN_NEXT)
        b6_down = self.buttons.is_down(BTN_BRIGHT_RST)
        if b2_down and b6_down:
            if not self.state.ip_combo_latched:
                self.state.ip_combo_latched = True
                self.state.b6_pending = False
                self.state.b6_long_fired = False
                if self.on_enter_manual:
                    self.on_enter_manual(None)
                if self.on_show_ip:
                    self.on_show_ip()
            return True
        self.state.ip_combo_latched = False
        return False

    def check_special_demo_combo(self):
        """B3+B6 combo -> consumed (demo disabled in this build)."""
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
        """Bad Apple combo -> disabled in this build."""
        self.state.badapple_combo_press_started_ms = None
        self.state.badapple_combo_long_fired = False
        return False

    # ------------------------------------------------------------------
    # B6 long press / release
    # ------------------------------------------------------------------
    def _start_b6_press(self):
        self.state.b6_pending = True
        self.state.b6_press_started_ms = time.ticks_ms()
        self.state.b6_long_fired = False

    def check_b6_hold(self):
        """Check if B6 is held long enough for battery detail display."""
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
            if self.on_show_battery_detail:
                self.on_show_battery_detail()

    def _check_b6_release(self):
        b6_now = self.buttons.is_down(BTN_BRIGHT_RST)
        if self.prev_b6_down and not b6_now:
            if self.state.ip_combo_latched:
                self.state.b6_pending = False
                self.state.b6_long_fired = False
                self.prev_b6_down = b6_now
                return
            if self.state.badapple_combo_long_fired:
                self.state.b6_pending = False
                self.state.b6_long_fired = False
                self.state.badapple_combo_long_fired = False
                self.prev_b6_down = b6_now
                return
            if self.state.b6_pending:
                if self.state.battery_display_active or self.state.b6_long_fired:
                    if self.on_stop_battery:
                        self.on_stop_battery()
                else:
                    if (not self.buttons.is_down(BTN_AUTO) and
                            not self.buttons.is_down(BTN_NEXT)):
                        if self.on_show_battery_short:
                            self.on_show_battery_short()
                self.state.b6_pending = False
                self.state.b6_long_fired = False
        self.prev_b6_down = b6_now

    # ------------------------------------------------------------------
    # B3 release (A/M toggle)
    # ------------------------------------------------------------------
    def _check_b3_release(self):
        b3_now = self.buttons.is_down(BTN_AUTO)
        if self.prev_b3_down and not b3_now:
            if self.state.combo_long_fired:
                self.state.b3_consumed = False
                self.prev_b3_down = b3_now
                return
            if not self.state.b3_consumed:
                if self.on_toggle_auto:
                    self.on_toggle_auto()
            self.state.b3_consumed = False
        self.prev_b3_down = b3_now

    # ------------------------------------------------------------------
    # Brightness reset combo (B4+B5)
    # ------------------------------------------------------------------
    def _check_brightness_reset_unlatch(self):
        if (self.state.brightness_reset_combo_latched and
                not self.buttons.is_down(BTN_BRIGHT_DN) and
                not self.buttons.is_down(BTN_BRIGHT_UP)):
            self.state.brightness_reset_combo_latched = False

    # ------------------------------------------------------------------
    # Single button press handler
    # ------------------------------------------------------------------
    def _handle_press(self, gp):
        combo_b3_b6 = (self.buttons.is_down(BTN_AUTO) and
                        self.buttons.is_down(BTN_BRIGHT_RST))
        combo_b2_b6 = (self.buttons.is_down(BTN_NEXT) and
                        self.buttons.is_down(BTN_BRIGHT_RST))
        combo_b4_b5 = (self.buttons.is_down(BTN_BRIGHT_DN) and
                        self.buttons.is_down(BTN_BRIGHT_UP))

        if combo_b3_b6 or combo_b2_b6:
            if self.on_enter_manual:
                self.on_enter_manual(gp)
            return

        if gp == BTN_AUTO:
            self.state.b3_consumed = False
            return

        if self.on_enter_manual:
            self.on_enter_manual(gp)

        now = time.ticks_ms()
        if gp in (BTN_BRIGHT_DN, BTN_BRIGHT_UP) and combo_b4_b5:
            if time.ticks_diff(now, self.state.brightness_reset_ignore_until_ms) < 0:
                return
            if not self.state.brightness_reset_combo_latched:
                self.state.brightness_reset_combo_latched = True
                if self.on_reset_brightness:
                    self.on_reset_brightness()
                self.state.brightness_reset_ignore_until_ms = time.ticks_add(
                    now, BRIGHTNESS_RESET_IGNORE_MS
                )
            return

        b3_held = self.buttons.is_down(BTN_AUTO)
        if gp == BTN_PREV:
            if b3_held:
                self.state.b3_consumed = True
                if self.on_adjust_interval:
                    self.on_adjust_interval(+INTERVAL_STEP_S)
            else:
                if self.on_cycle_face:
                    self.on_cycle_face(-1)
        elif gp == BTN_NEXT:
            if b3_held:
                self.state.b3_consumed = True
                if self.on_adjust_interval:
                    self.on_adjust_interval(-INTERVAL_STEP_S)
            else:
                if self.on_cycle_face:
                    self.on_cycle_face(+1)
        elif gp == BTN_BRIGHT_DN:
            if self.on_adjust_brightness:
                self.on_adjust_brightness(+BRIGHTNESS_STEP)
        elif gp == BTN_BRIGHT_UP:
            if self.on_adjust_brightness:
                self.on_adjust_brightness(-BRIGHTNESS_STEP)
        elif gp == BTN_BRIGHT_RST:
            self._start_b6_press()

    # ------------------------------------------------------------------
    # Main service (called every tick from main loop)
    # Returns (combo_active, auto_timer_reset)
    # ------------------------------------------------------------------
    def service(self):
        """Poll buttons, check combos, handle presses. Returns combo_active flag."""
        combo_active = self.check_special_demo_combo()
        combo_active = self.check_badapple_combo() or combo_active
        combo_active = self.check_ip_combo() or combo_active

        pressed_any = False
        for gp in self.buttons.poll():
            self._handle_press(gp)
            pressed_any = True

        combo_active = self.check_special_demo_combo() or combo_active
        combo_active = self.check_badapple_combo() or combo_active
        combo_active = self.check_ip_combo() or combo_active

        self.check_b6_hold()
        self._check_brightness_reset_unlatch()
        self._check_b3_release()
        self._check_b6_release()

        return combo_active, pressed_any
