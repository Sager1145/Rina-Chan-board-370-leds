# ---------------------------------------------------------------------------
# scroll_module.py
#
# Scrolling IP/SSID display module.
#
# Text is rendered using the global display color supplied by color_module
# so the scrolling IP/SSID share the same color as all other display modes.
# ---------------------------------------------------------------------------

# Import: Loads time so this module can use that dependency.
import time

# Import: Loads display_num so this module can use that dependency.
import display_num
# Import: Loads BTN_NEXT, BTN_BRIGHT_RST from buttons so this module can use that dependency.
from buttons import BTN_NEXT, BTN_BRIGHT_RST

# Import: Loads AppModule from app_module_base so this module can use that dependency.
from app_module_base import AppModule


# Class: Defines ScrollModule as the state and behavior container for Scroll Module.
class ScrollModule(AppModule):

    # Function: Defines start_ip_display(self) to handle start ip display behavior.
    def start_ip_display(self):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: ip stores the conditional expression self.link.get_ip() if self.link is not None else None.
            ip = self.link.get_ip() if self.link is not None else None
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: ip stores the empty sentinel value.
            ip = None
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: ssid stores the conditional expression self.link.get_ssid() if self.link is not None and hasattr(self.link, "get_ssid") else....
            ssid = self.link.get_ssid() if self.link is not None and hasattr(self.link, "get_ssid") else None
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: ssid stores the empty sentinel value.
            ssid = None
        # Logic: Branches when not ip so the correct firmware path runs.
        if not ip:
            # Expression: Calls print() for its side effects.
            print("ip display: no STA IP known yet")
            # Return: Sends control back to the caller.
            return
        # Variable: text stores the result returned by str().
        text = str(ip)
        # Logic: Branches when ssid so the correct firmware path runs.
        if ssid:
            # Variable: text stores the calculated expression str(ip) + " " + str(ssid).
            text = str(ip) + "  " + str(ssid)
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Variable: self.state.ip_scroll_text stores the current text value.
        self.state.ip_scroll_text = text
        # Variable: self.state.ip_scroll_offset stores the configured literal value.
        self.state.ip_scroll_offset = 0
        # Variable: self.state.ip_scroll_next_ms stores the result returned by time.ticks_add().
        self.state.ip_scroll_next_ms = time.ticks_add(now, 120)
        # Duration scales with text length; enough time for at least one pass.
        # Variable: self.state.ip_display_expires_ms stores the result returned by time.ticks_add().
        self.state.ip_display_expires_ms = time.ticks_add(now, max(9000, len(text) * 650))
        # Variable: self.state.ip_display_active stores the enabled/disabled flag value.
        self.state.ip_display_active = True
        # Variable: self.state.flash_active stores the enabled/disabled flag value.
        self.state.flash_active = False
        # Variable: self.state.edge_flash_active stores the enabled/disabled flag value.
        self.state.edge_flash_active = False
        # Variable: self.state.battery_display_active stores the enabled/disabled flag value.
        self.state.battery_display_active = False
        # Variable: self.state.battery_display_single_shot stores the enabled/disabled flag value.
        self.state.battery_display_single_shot = False
        # Use global display color so IP scroll matches the current mode color.
        # Variable: color stores the result returned by self.get_color().
        color = self.get_color()
        # Expression: Calls display_num.render_scrolling_text_window() for its side effects.
        display_num.render_scrolling_text_window(text, 0, color=color)
        # Expression: Calls print() for its side effects.
        print("ip display scroll:", text)

    # Function: Defines service_ip_display(self) to handle service ip display behavior.
    def service_ip_display(self):
        # Logic: Branches when not self.state.ip_display_active so the correct firmware path runs.
        if not self.state.ip_display_active:
            # Return: Sends control back to the caller.
            return
        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Logic: Branches when time.ticks_diff(now, self.state.ip_display_expires_ms) >= 0 so the correct firmware path runs.
        if time.ticks_diff(now, self.state.ip_display_expires_ms) >= 0:
            # Variable: self.state.ip_display_active stores the enabled/disabled flag value.
            self.state.ip_display_active = False
            # Expression: Calls self.draw_current_face() for its side effects.
            self.draw_current_face()
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when time.ticks_diff(now, self.state.ip_scroll_next_ms) >= 0 so the correct firmware path runs.
        if time.ticks_diff(now, self.state.ip_scroll_next_ms) >= 0:
            # Variable: text stores the combined condition self.state.ip_scroll_text or "".
            text = self.state.ip_scroll_text or ""
            # Variable: color stores the result returned by self.get_color().
            color = self.get_color()
            # Expression: Calls display_num.render_scrolling_text_window() for its side effects.
            display_num.render_scrolling_text_window(text, self.state.ip_scroll_offset, color=color)
            # Variable: self.state.ip_scroll_offset stores the calculated expression (self.state.ip_scroll_offset + 1) % max(1, len(text) * 6 + 22).
            self.state.ip_scroll_offset = (self.state.ip_scroll_offset + 1) % max(1, len(text) * 6 + 22)
            # Variable: self.state.ip_scroll_next_ms stores the result returned by time.ticks_add().
            self.state.ip_scroll_next_ms = time.ticks_add(now, 120)

    # Function: Defines check_ip_combo(self) to handle check ip combo behavior.
    def check_ip_combo(self):
        # Variable: b2_down stores the result returned by self.buttons.is_down().
        b2_down = self.buttons.is_down(BTN_NEXT)
        # Variable: b6_down stores the result returned by self.buttons.is_down().
        b6_down = self.buttons.is_down(BTN_BRIGHT_RST)
        # Logic: Branches when b2_down and b6_down so the correct firmware path runs.
        if b2_down and b6_down:
            # Logic: Branches when not self.state.ip_combo_latched so the correct firmware path runs.
            if not self.state.ip_combo_latched:
                # Variable: self.state.ip_combo_latched stores the enabled/disabled flag value.
                self.state.ip_combo_latched = True
                # Variable: self.state.b6_pending stores the enabled/disabled flag value.
                self.state.b6_pending = False
                # Variable: self.state.b6_long_fired stores the enabled/disabled flag value.
                self.state.b6_long_fired = False
                # Expression: Calls self.start_ip_display() for its side effects.
                self.start_ip_display()
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Variable: self.state.ip_combo_latched stores the enabled/disabled flag value.
        self.state.ip_combo_latched = False
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
