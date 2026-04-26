# ---------------------------------------------------------------------------
# color_module.py
#
# Protocol color and brightness synchronization callbacks.
# ---------------------------------------------------------------------------

from config import *
from brightness_modes import effective_brightness
from settings_store import clamp_brightness

from app_module_base import AppModule


class ColorModule(AppModule):

    def _current_home_color(self):
        if self.proto is not None and hasattr(self.proto, "color"):
            try:
                return self.proto.color
            except Exception:
                pass
        return (66, 0, 36)

    def _dimmed_home_color(self, color):
        try:
            return (max(0, int(color[0]) // 3),
                    max(0, int(color[1]) // 3),
                    max(0, int(color[2]) // 3))
        except Exception:
            return (24, 0, 14)

    def on_protocol_color_updated(self, color):
        # Home/Web color is authoritative.  Button-selected faces redraw with
        # this color, so web mode and button mode stay visually synchronized.
        if self.button_face_active and self.proto is not None and getattr(self.proto, "display_mode", "legacy") == "physical":
            try:
                self.draw_current_face()
            except Exception:
                pass

    def on_protocol_brightness_updated(self, bright):
        # Web brightness is a raw 10..128 protocol value.  Map it to the
        # board's percent brightness so later button-mode renders use the
        # same visible brightness range.
        try:
            pct = int((int(bright) * 100 + 85) // 170)
        except Exception:
            return
        if pct < BRIGHTNESS_MIN:
            pct = BRIGHTNESS_MIN
        if pct > BRIGHTNESS_MAX:
            pct = BRIGHTNESS_MAX
        if self.state.brightness != pct:
            self.state.brightness = pct
            self.apply_brightness()
            self.save_settings()
