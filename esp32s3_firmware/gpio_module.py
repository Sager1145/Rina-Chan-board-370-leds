# ---------------------------------------------------------------------------
# gpio_module.py
#
# Hardware GPIO button routing module.
# ---------------------------------------------------------------------------

import time

from buttons import (
    BTN_PREV, BTN_NEXT, BTN_AUTO,
    BTN_BRIGHT_DN, BTN_BRIGHT_UP, BTN_BRIGHT_RST,
)
from config import *

from app_module_base import AppModule


class GPIOModule(AppModule):

    def handle_press(self, gp):
        combo_b3_b6 = self.buttons.is_down(BTN_AUTO) and self.buttons.is_down(BTN_BRIGHT_RST)
        combo_b2_b6 = self.buttons.is_down(BTN_NEXT) and self.buttons.is_down(BTN_BRIGHT_RST)  # B2+B6 shows STA IP
        combo_b4_b5 = self.buttons.is_down(BTN_BRIGHT_DN) and self.buttons.is_down(BTN_BRIGHT_UP)
        if combo_b3_b6 or combo_b2_b6:
            self.enter_manual_control_from_button(gp)
            return

        # Do not force M on the initial B3 down event.  The A/M state must be
        # toggled on B3 release using the state that existed before the press.
        # Other GPIO actions still immediately take local/manual ownership.
        if gp == BTN_AUTO:
            self.state.b3_consumed = False
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
