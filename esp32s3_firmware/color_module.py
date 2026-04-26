# ---------------------------------------------------------------------------
# color_module.py
#
# Centralized color management for all display modes.
# Every module that needs colors (face, scroll, battery, home flash, etc.)
# reads from this module so a single color change propagates everywhere.
# ---------------------------------------------------------------------------


class ColorModule:
    """Owns the current home/display color and notifies listeners on change."""

    __slots__ = ("home_color", "_callbacks")

    # Protocol default color (#f971d4 pink)
    DEFAULT_HOME_COLOR = (249, 113, 212)

    # Display-overlay colors used by various modules
    DEFAULT_COLOR = (0, 120, 255)       # battery, numbers
    BRIGHTNESS_COLOR = (0, 120, 255)    # brightness overlay
    MODE_COLOR = (180, 0, 255)          # A/M mode, interval
    EDGE_FLASH_COLOR = (0, 120, 255)    # edge flash default

    def __init__(self):
        self.home_color = self.DEFAULT_HOME_COLOR
        self._callbacks = []

    # ------------------------------------------------------------------
    # Read
    # ------------------------------------------------------------------
    def get(self):
        """Return the current home color as (R, G, B)."""
        return self.home_color

    def dimmed(self, color=None):
        """Return a 1/3 dimmed version of a color (default: home_color)."""
        c = color if color is not None else self.home_color
        return (max(0, int(c[0]) // 3),
                max(0, int(c[1]) // 3),
                max(0, int(c[2]) // 3))

    # ------------------------------------------------------------------
    # Write
    # ------------------------------------------------------------------
    def set(self, r, g, b):
        """Update the home color and notify all listeners."""
        self.home_color = (int(r) & 0xFF, int(g) & 0xFF, int(b) & 0xFF)
        for cb in self._callbacks:
            try:
                cb(self.home_color)
            except Exception as exc:
                print("color callback failed:", exc)

    def set_from_bytes(self, data):
        """Set color from a 3-byte sequence [R, G, B]."""
        self.set(data[0], data[1], data[2])

    # ------------------------------------------------------------------
    # Callback registration
    # ------------------------------------------------------------------
    def on_change(self, callback):
        """Register a callback: callback(color_tuple) called on every set()."""
        self._callbacks.append(callback)
