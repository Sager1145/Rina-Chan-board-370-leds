# ---------------------------------------------------------------------------
# scroll_module.py
#
# Scrolling text display module.
# Handles two independent scroll sources:
#   1) IP/SSID scroll (B2+B6 combo) — shows current STA IP and SSID
#   2) WebUI scroll text — remote text command from the browser UI
# Both share the same rendering engine in display_num.
# ---------------------------------------------------------------------------

import time
import display_num


class ScrollModule:
    """Manages IP/SSID scroll and WebUI scroll-text playback."""

    __slots__ = (
        "state", "color_module",
        # WebUI scroll state
        "webui_active", "webui_text", "webui_speed_ms",
        "webui_offset", "webui_next_ms",
        # Callbacks
        "_on_prepare", "_on_stop_done",
    )

    def __init__(self, state, color_module):
        self.state = state
        self.color_module = color_module
        # WebUI scroll
        self.webui_active = False
        self.webui_text = ""
        self.webui_speed_ms = 120
        self.webui_offset = 0
        self.webui_next_ms = 0
        # Callbacks
        self._on_prepare = None
        self._on_stop_done = None

    # ------------------------------------------------------------------
    # Query
    # ------------------------------------------------------------------
    def active(self):
        """True if any scroll mode is active."""
        return self.webui_active or self.state.ip_display_active

    # ------------------------------------------------------------------
    # IP/SSID scroll (B2+B6 combo)
    # ------------------------------------------------------------------
    def start_ip_display(self, ip, ssid=None):
        """Begin scrolling IP (+ optional SSID) on the full matrix."""
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
        self.state.ip_display_expires_ms = time.ticks_add(
            now, max(9000, len(text) * 650)
        )
        self.state.ip_display_active = True
        # Clear conflicting overlays
        self.state.flash_active = False
        self.state.edge_flash_active = False
        self.state.battery_display_active = False
        self.state.battery_display_single_shot = False
        display_num.render_scrolling_text_window(text, 0)
        print("ip display scroll:", text)

    def service_ip_display(self):
        """Called every tick; advances IP scroll or stops on expiry."""
        if not self.state.ip_display_active:
            return
        now = time.ticks_ms()
        if time.ticks_diff(now, self.state.ip_display_expires_ms) >= 0:
            self.state.ip_display_active = False
            if self._on_stop_done:
                self._on_stop_done()
            return
        if time.ticks_diff(now, self.state.ip_scroll_next_ms) >= 0:
            text = self.state.ip_scroll_text or ""
            display_num.render_scrolling_text_window(
                text, self.state.ip_scroll_offset
            )
            total = max(1, len(text) * 6 + 22)
            self.state.ip_scroll_offset = (
                (self.state.ip_scroll_offset + 1) % total
            )
            self.state.ip_scroll_next_ms = time.ticks_add(now, 120)

    # ------------------------------------------------------------------
    # WebUI scroll text (firmware-side)
    # ------------------------------------------------------------------
    def start_webui_scroll(self, text, speed_ms=120):
        """Start a WebUI scroll-text animation on the LED matrix."""
        try:
            speed_ms = int(speed_ms)
        except Exception:
            speed_ms = 120
        speed_ms = max(40, min(1000, speed_ms))

        self.stop(redraw=False)
        if self._on_prepare:
            self._on_prepare()
        self.webui_active = True
        self.webui_text = self._clean_text(text, 96)
        self.webui_speed_ms = speed_ms
        self.webui_offset = 0
        self.webui_next_ms = 0
        self._render_webui_scroll()
        print("scroll module: start speed={} text={}".format(
            speed_ms, self.webui_text))

    def _render_webui_scroll(self):
        color = self.color_module.get()
        display_num.render_scrolling_text_window(
            self.webui_text, self.webui_offset, color=color
        )

    def _service_webui_scroll(self, now):
        if not self.webui_next_ms or time.ticks_diff(now, self.webui_next_ms) >= 0:
            self._render_webui_scroll()
            total = max(1, len(self.webui_text) * 6 + 22)
            self.webui_offset = (self.webui_offset + 1) % total
            self.webui_next_ms = time.ticks_add(now, self.webui_speed_ms)

    # ------------------------------------------------------------------
    # Service (called every tick from main loop)
    # ------------------------------------------------------------------
    def service(self):
        """Advance any active scroll animation."""
        now = time.ticks_ms()
        if self.webui_active:
            self._service_webui_scroll(now)
        self.service_ip_display()

    # ------------------------------------------------------------------
    # Stop
    # ------------------------------------------------------------------
    def stop(self, redraw=True):
        """Stop all scroll animations."""
        was_active = self.webui_active
        self.webui_active = False
        self.webui_text = ""
        self.webui_offset = 0
        self.webui_next_ms = 0
        if was_active and redraw and self._on_stop_done:
            self._on_stop_done()
        return was_active

    def stop_ip(self):
        """Stop IP scroll only."""
        self.state.ip_display_active = False

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------
    def set_on_prepare(self, callback):
        """Called before a WebUI scroll starts (to clear overlays etc.)."""
        self._on_prepare = callback

    def set_on_stop_done(self, callback):
        """Called when scroll stops and face should be redrawn."""
        self._on_stop_done = callback

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    @staticmethod
    def _clean_text(value, limit=96):
        s = str(value or "")
        s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ").replace("|", " ")
        return s[:limit]
