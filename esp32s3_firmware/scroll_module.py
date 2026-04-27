# ---------------------------------------------------------------------------
# scroll_module.py
#
# Scrolling IP/SSID display module.
#
# Text is rendered using the global display color supplied by color_module
# so the scrolling IP/SSID share the same color as all other display modes.
# ---------------------------------------------------------------------------

import time

import display_num
from buttons import BTN_NEXT, BTN_BRIGHT_RST

from app_module_base import AppModule


class ScrollModule(AppModule):

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
        # Use global display color so IP scroll matches the current mode color.
        color = self.get_color()
        display_num.render_scrolling_text_window(text, 0, color=color)
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
            color = self.get_color()
            display_num.render_scrolling_text_window(text, self.state.ip_scroll_offset, color=color)
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
