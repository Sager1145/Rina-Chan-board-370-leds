# ---------------------------------------------------------------------------
# gpio_module.py
#
# Hardware GPIO button routing module.
# ---------------------------------------------------------------------------

# Import: Loads time so this module can use that dependency.
import time

# Import: Loads BTN_PREV, BTN_NEXT, BTN_AUTO, BTN_BRIGHT_DN, BTN_BRIGHT_UP, BTN_BRIGHT_RST from buttons so this module can use that dependency.
from buttons import (
    BTN_PREV, BTN_NEXT, BTN_AUTO,
    BTN_BRIGHT_DN, BTN_BRIGHT_UP, BTN_BRIGHT_RST,
)
# Import: Loads * from config so this module can use that dependency.
from config import *

# Import: Loads AppModule from app_module_base so this module can use that dependency.
from app_module_base import AppModule


# Class: Defines GPIOModule as the state and behavior container for GPIOModule.
class GPIOModule(AppModule):

    # Function: Defines handle_press(self, gp) to handle handle press behavior.
    def handle_press(self, gp):
        # Variable: combo_b3_b6 stores the combined condition self.buttons.is_down(BTN_AUTO) and self.buttons.is_down(BTN_BRIGHT_RST).
        combo_b3_b6 = self.buttons.is_down(BTN_AUTO) and self.buttons.is_down(BTN_BRIGHT_RST)
        # Variable: combo_b2_b6 stores the combined condition self.buttons.is_down(BTN_NEXT) and self.buttons.is_down(BTN_BRIGHT_RST).
        combo_b2_b6 = self.buttons.is_down(BTN_NEXT) and self.buttons.is_down(BTN_BRIGHT_RST)
        # Variable: combo_b4_b5 stores the combined condition self.buttons.is_down(BTN_BRIGHT_DN) and self.buttons.is_down(BTN_BRIGHT_UP).
        combo_b4_b5 = self.buttons.is_down(BTN_BRIGHT_DN) and self.buttons.is_down(BTN_BRIGHT_UP)
        # Logic: Branches when combo_b3_b6 or combo_b2_b6 so the correct firmware path runs.
        if combo_b3_b6 or combo_b2_b6:
            # Expression: Calls self.enter_manual_control_from_button() for its side effects.
            self.enter_manual_control_from_button(gp)
            # Return: Sends control back to the caller.
            return

        # Do not force M on the initial B3 down event.  The A/M state must be
        # toggled on B3 release using the state that existed before the press.
        # Other GPIO actions immediately take local/manual ownership.
        # Logic: Branches when gp == BTN_AUTO so the correct firmware path runs.
        if gp == BTN_AUTO:
            # Variable: self.state.b3_consumed stores the enabled/disabled flag value.
            self.state.b3_consumed = False
            # Return: Sends control back to the caller.
            return

        # Expression: Calls self.enter_manual_control_from_button() for its side effects.
        self.enter_manual_control_from_button(gp)
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Logic: Branches when gp in (BTN_BRIGHT_DN, BTN_BRIGHT_UP) and combo_b4_b5 so the correct firmware path runs.
        if gp in (BTN_BRIGHT_DN, BTN_BRIGHT_UP) and combo_b4_b5:
            # Logic: Branches when time.ticks_diff(now, self.state.brightness_reset_ignore_until_ms) < 0 so the correct firmware path runs.
            if time.ticks_diff(now, self.state.brightness_reset_ignore_until_ms) < 0:
                # Return: Sends control back to the caller.
                return
            # Logic: Branches when not self.state.brightness_reset_combo_latched so the correct firmware path runs.
            if not self.state.brightness_reset_combo_latched:
                # Variable: self.state.brightness_reset_combo_latched stores the enabled/disabled flag value.
                self.state.brightness_reset_combo_latched = True
                # Expression: Calls self.reset_brightness() for its side effects.
                self.reset_brightness()
                # Variable: self.state.brightness_reset_ignore_until_ms stores the result returned by time.ticks_add().
                self.state.brightness_reset_ignore_until_ms = time.ticks_add(now, BRIGHTNESS_RESET_IGNORE_MS)
            # Return: Sends control back to the caller.
            return

        # Variable: b3_held stores the result returned by self.buttons.is_down().
        b3_held = self.buttons.is_down(BTN_AUTO)
        # Logic: Branches when gp == BTN_PREV so the correct firmware path runs.
        if gp == BTN_PREV:
            # Logic: Branches when b3_held so the correct firmware path runs.
            if b3_held:
                # Variable: self.state.b3_consumed stores the enabled/disabled flag value.
                self.state.b3_consumed = True
                # Expression: Calls self.adjust_interval() for its side effects.
                self.adjust_interval(+INTERVAL_STEP_S)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.cycle_face() for its side effects.
                self.cycle_face(-1)
        # Logic: Branches when gp == BTN_NEXT so the correct firmware path runs.
        elif gp == BTN_NEXT:
            # Logic: Branches when b3_held so the correct firmware path runs.
            if b3_held:
                # Variable: self.state.b3_consumed stores the enabled/disabled flag value.
                self.state.b3_consumed = True
                # Expression: Calls self.adjust_interval() for its side effects.
                self.adjust_interval(-INTERVAL_STEP_S)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.cycle_face() for its side effects.
                self.cycle_face(+1)
        # Logic: Branches when gp == BTN_BRIGHT_DN so the correct firmware path runs.
        elif gp == BTN_BRIGHT_DN:
            # Expression: Calls self.adjust_brightness() for its side effects.
            self.adjust_brightness(+BRIGHTNESS_STEP)
        # Logic: Branches when gp == BTN_BRIGHT_UP so the correct firmware path runs.
        elif gp == BTN_BRIGHT_UP:
            # Expression: Calls self.adjust_brightness() for its side effects.
            self.adjust_brightness(-BRIGHTNESS_STEP)
        # Logic: Branches when gp == BTN_BRIGHT_RST so the correct firmware path runs.
        elif gp == BTN_BRIGHT_RST:
            # Expression: Calls self.start_b6_press() for its side effects.
            self.start_b6_press()

    # Function: Defines check_b3_release(self, prev_b3_down) to handle check b3 release behavior.
    def check_b3_release(self, prev_b3_down):
        # Module: Documents the purpose of this scope.
        """Toggle A/M on B3 release, unless B3 was consumed by a combo."""
        # Variable: b3_now stores the result returned by self.buttons.is_down().
        b3_now = self.buttons.is_down(BTN_AUTO)
        # Logic: Branches when prev_b3_down and not b3_now so the correct firmware path runs.
        if prev_b3_down and not b3_now:
            # Logic: Branches when not self.state.b3_consumed so the correct firmware path runs.
            if not self.state.b3_consumed:
                # Expression: Calls self.toggle_auto() for its side effects.
                self.toggle_auto()
            # Variable: self.state.b3_consumed stores the enabled/disabled flag value.
            self.state.b3_consumed = False
        # Return: Sends the current b3_now value back to the caller.
        return b3_now
