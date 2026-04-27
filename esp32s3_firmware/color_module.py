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

# Import: Loads board so this module can use that dependency.
import board
# Import: Loads BRIGHTNESS_MIN, BRIGHTNESS_MAX from config so this module can use that dependency.
from config import BRIGHTNESS_MIN, BRIGHTNESS_MAX
# Import: Loads effective_brightness from brightness_modes so this module can use that dependency.
from brightness_modes import effective_brightness
# Import: Loads clamp_brightness from settings_store so this module can use that dependency.
from settings_store import clamp_brightness

# Import: Loads AppModule from app_module_base so this module can use that dependency.
from app_module_base import AppModule


# Class: Defines ColorModule as the state and behavior container for Color Module.
class ColorModule(AppModule):

    # ------------------------------------------------------------------
    # Color API  (read by every display module)
    # ------------------------------------------------------------------

    # Function: Defines get_color(self) to handle get color behavior.
    def get_color(self):
        # Module: Documents the purpose of this scope.
        """Current display color (R, G, B) – single source for all modes."""
        # Logic: Branches when self.proto is not None and hasattr(self.proto, "color") so the correct firmware path runs.
        if self.proto is not None and hasattr(self.proto, "color"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Return: Sends the referenced self.proto.color value back to the caller.
                return self.proto.color
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
        # Return: Sends the collection of values used later in this module back to the caller.
        return (66, 0, 36)

    # Function: Defines get_dimmed_color(self) to handle get dimmed color behavior.
    def get_dimmed_color(self):
        # Module: Documents the purpose of this scope.
        """Return a dimmed (1/3 brightness) version of the current color."""
        # Variable: color stores the result returned by self.get_color().
        color = self.get_color()
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Return: Sends the collection of values used later in this module back to the caller.
            return (max(0, int(color[0]) // 3),
                    max(0, int(color[1]) // 3),
                    max(0, int(color[2]) // 3))
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Return: Sends the collection of values used later in this module back to the caller.
            return (24, 0, 14)

    # Backward-compat aliases kept so any existing caller still works.
    # Function: Defines _current_home_color(self) to handle current home color behavior.
    def _current_home_color(self):
        # Return: Sends the result returned by self.get_color() back to the caller.
        return self.get_color()

    # Function: Defines _dimmed_home_color(self, color) to handle dimmed home color behavior.
    def _dimmed_home_color(self, color):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Return: Sends the collection of values used later in this module back to the caller.
            return (max(0, int(color[0]) // 3),
                    max(0, int(color[1]) // 3),
                    max(0, int(color[2]) // 3))
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Return: Sends the collection of values used later in this module back to the caller.
            return (24, 0, 14)

    # ------------------------------------------------------------------
    # Brightness API  (single apply point for the whole firmware)
    # ------------------------------------------------------------------

    # Function: Defines apply_brightness(self) to handle apply brightness behavior.
    def apply_brightness(self):
        # Module: Documents the purpose of this scope.
        """Apply state.brightness to the board.  All modules call this."""
        # Expression: Calls board.set_max_brightness() for its side effects.
        board.set_max_brightness(effective_brightness(self.state.brightness))

    # Function: Defines sync_protocol_brightness_from_buttons(self) to handle sync protocol brightness from buttons behavior.
    def sync_protocol_brightness_from_buttons(self):
        # Module: Documents the purpose of this scope.
        """Keep WebUI / protocol bright value in sync after hardware changes."""
        # Logic: Branches when self.proto is not None and hasattr(self.proto, "bright") so the correct firmware path runs.
        if self.proto is not None and hasattr(self.proto, "bright"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: self.proto.bright stores the result returned by int().
                self.proto.bright = int(effective_brightness(self.state.brightness))
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("brightness sync failed:", exc)

    # Function: Defines set_brightness(self, pct, save, sync_protocol) to handle set brightness behavior.
    def set_brightness(self, pct, save=True, sync_protocol=True):
        # Module: Documents the purpose of this scope.
        """Unified brightness setter used by buttons, protocol and WebUI.

        pct            – requested UI brightness percent (5..100)
        save           – persist to flash when changed
        sync_protocol  – push new value back to protocol object
        """
        # Variable: pct stores the result returned by clamp_brightness().
        pct = clamp_brightness(pct)
        # Variable: changed stores the comparison result self.state.brightness != pct.
        changed = (self.state.brightness != pct)
        # Variable: self.state.brightness stores the current pct value.
        self.state.brightness = pct
        # Expression: Calls self.apply_brightness() for its side effects.
        self.apply_brightness()
        # Logic: Branches when sync_protocol so the correct firmware path runs.
        if sync_protocol:
            # Expression: Calls self.sync_protocol_brightness_from_buttons() for its side effects.
            self.sync_protocol_brightness_from_buttons()
        # Logic: Branches when save and changed so the correct firmware path runs.
        if save and changed:
            # Expression: Calls self.save_settings() for its side effects.
            self.save_settings()

    # ------------------------------------------------------------------
    # Protocol callbacks
    # ------------------------------------------------------------------

    # Function: Defines on_protocol_color_updated(self, color) to handle on protocol color updated behavior.
    def on_protocol_color_updated(self, color):
        # Module: Documents the purpose of this scope.
        """WebUI / API changed the display color.
        Redraw the current face so button-mode and web-mode stay in sync."""
        # Logic: Branches when self.button_face_active and self.proto is not None so the correct firmware path runs.
        if self.button_face_active and self.proto is not None:
            # Logic: Branches when getattr(self.proto, "display_mode", "legacy") == "physical" so the correct firmware path runs.
            if getattr(self.proto, "display_mode", "legacy") == "physical":
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Expression: Calls self.draw_current_face() for its side effects.
                    self.draw_current_face()
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception:
                    # Control: Leaves this branch intentionally empty.
                    pass

    # Function: Defines on_protocol_brightness_updated(self, bright) to handle on protocol brightness updated behavior.
    def on_protocol_brightness_updated(self, bright):
        # Module: Documents the purpose of this scope.
        """WebUI / API sent a raw protocol brightness value (10..128).
        Map it to a UI percent and apply via set_brightness()."""
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: pct stores the result returned by int().
            pct = int((int(bright) * 100 + 85) // 170)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Return: Sends control back to the caller.
            return
        # sync_protocol=False: the protocol already has the value.
        # Expression: Calls self.set_brightness() for its side effects.
        self.set_brightness(pct, save=True, sync_protocol=False)
