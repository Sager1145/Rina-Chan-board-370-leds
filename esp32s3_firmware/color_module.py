# ---------------------------------------------------------------------------
# color_module.py
#
# Global color and brightness manager.
#
# This is the single source of truth for:
#   - Display color (R, G, B) used by all modes (faces, scroll, animations)
#   - Brightness percentage and its application to the physical LEDs
#
# All other modules call color_module via the app proxy:
#   self.apply_brightness()            -> color_module.apply_brightness()
#   self.get_color()                   -> color_module.get_color()
#   self.get_dimmed_color()            -> color_module.get_dimmed_color()
#   self.set_brightness(pct)           -> color_module.set_brightness()
#   self.sync_protocol_brightness_from_buttons() -> color_module (same)
#
# Protocol callbacks (called from rina_protocol via main.py facade):
#   on_protocol_color_updated(color)   - WebUI/API changed the color
#   on_protocol_brightness_updated(v)  - WebUI/API changed the brightness
# ---------------------------------------------------------------------------

import board
from config import BRIGHTNESS_MIN, BRIGHTNESS_MAX
from brightness_modes import effective_brightness
from settings_store import clamp_brightness

from app_module_base import AppModule


class ColorModule(AppModule):

    # ------------------------------------------------------------------
    # Color API  (read by every display module)
    # ------------------------------------------------------------------

    def get_color(self):
        """Current display color (R, G, B) – single source for all modes."""
        if self.proto is not None and hasattr(self.proto, "color"):
            try:
                return self.proto.color
            except Exception:
                pass
        return (66, 0, 36)

    def get_dimmed_color(self):
        """Return a dimmed (1/3 brightness) version of the current color."""
        color = self.get_color()
        try:
            return (max(0, int(color[0]) // 3),
                    max(0, int(color[1]) // 3),
                    max(0, int(color[2]) // 3))
        except Exception:
            return (24, 0, 14)

    # Backward-compat aliases kept so any existing caller still works.
    def _current_home_color(self):
        return self.get_color()

    def _dimmed_home_color(self, color):
        try:
            return (max(0, int(color[0]) // 3),
                    max(0, int(color[1]) // 3),
                    max(0, int(color[2]) // 3))
        except Exception:
            return (24, 0, 14)

    # ------------------------------------------------------------------
    # Brightness API  (single apply point for the whole firmware)
    # ------------------------------------------------------------------

    def apply_brightness(self):
        """Apply state.brightness to the board.  All modules call this."""
        board.set_max_brightness(effective_brightness(self.state.brightness))

    def sync_protocol_brightness_from_buttons(self):
        """Keep WebUI / protocol bright value in sync after hardware changes."""
        if self.proto is not None and hasattr(self.proto, "bright"):
            try:
                self.proto.bright = int(effective_brightness(self.state.brightness))
            except Exception as exc:
                print("brightness sync failed:", exc)

    def set_brightness(self, pct, save=True, sync_protocol=True):
        """Unified brightness setter used by buttons, protocol and WebUI.

        pct            – requested UI brightness percent (5..100)
        save           – persist to flash when changed
        sync_protocol  – push new value back to protocol object
        """
        pct = clamp_brightness(pct)
        changed = (self.state.brightness != pct)
        self.state.brightness = pct
        self.apply_brightness()
        if sync_protocol:
            self.sync_protocol_brightness_from_buttons()
        if save and changed:
            self.save_settings()

    # ------------------------------------------------------------------
    # Protocol callbacks
    # ------------------------------------------------------------------

    def on_protocol_color_updated(self, color):
        """WebUI / API changed the display color.
        Redraw the current face so button-mode and web-mode stay in sync."""
        if self.button_face_active and self.proto is not None:
            if getattr(self.proto, "display_mode", "legacy") == "physical":
                try:
                    self.draw_current_face()
                except Exception:
                    pass

    def on_protocol_brightness_updated(self, bright):
        """WebUI / API sent a raw protocol brightness value (10..128).
        Map it to a UI percent and apply via set_brightness()."""
        try:
            pct = int((int(bright) * 100 + 85) // 170)
        except Exception:
            return
        # sync_protocol=False: the protocol already has the value.
        self.set_brightness(pct, save=True, sync_protocol=False)
