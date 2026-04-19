# ---------------------------------------------------------------------------
# app_state.py
#
# Small state containers used by main.py.
#
# Why this file exists:
# - keeps the big runtime state definition out of main.py
# - makes it obvious which values are "live app state" and which are config
# - uses __slots__ to reduce RAM usage on the Pico
#
# AppState contains mode / UI / timer flags.
# BatteryState contains measured battery information and learned min/max.
# ---------------------------------------------------------------------------

from config import (
    DEFAULT_FACE, DEFAULT_INTERVAL_S, DEFAULT_BRIGHTNESS,
    DEMO_DEFAULT_AUTO, DEMO_DEFAULT_INTERVAL_S,
    BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V,
)


class AppState:
    # -----------------------------------------------------------------------
    # __slots__ keeps the object lightweight.
    # These fields are the full mutable runtime state of the UI controller.
    # -----------------------------------------------------------------------
    __slots__ = (
        # Face / auto-face state.
        "face_idx", "auto", "interval_s", "brightness",
        # Demo-mode settings; brightness stays shared with face mode.
        "demo_auto", "demo_interval_s",
        # Flag used so B3 release does not also toggle auto after an interval
        # adjustment combo already consumed the press.
        "b3_consumed",
        # Overlay / flash state for interval, brightness, and mode text.
        "flash_active", "flash_expires_ms", "flash_kind", "flash_value",
        # B6 tracking for short-press reset vs long-press battery display.
        "b6_pending", "b6_press_started_ms", "b6_long_fired",
        # Battery overlay state.
        "battery_display_active", "battery_next_refresh_ms",
        "battery_display_toggle_started_ms",
        # Top / bottom edge limit flash state.
        "edge_flash_active", "edge_flash_edge", "edge_flash_started_ms",
        # Demo-mode enable flag.
        "special_demo_mode",
        # B3+B6 special demo combo tracking.
        "combo_press_started_ms", "combo_long_fired",
        # Bad Apple enable flag.
        "badapple_mode",
        # B2+B6 Bad Apple combo tracking.
        "badapple_combo_press_started_ms", "badapple_combo_long_fired",
        # Next time battery auto-calibration log is allowed.
        "battery_next_log_ms",
    )

    def __init__(self):
        # -------------------------------------------------------------------
        # Boot defaults. These may later be overridden by saved settings.
        # -------------------------------------------------------------------
        self.face_idx = DEFAULT_FACE
        self.auto = False
        self.interval_s = DEFAULT_INTERVAL_S
        self.brightness = DEFAULT_BRIGHTNESS
        self.demo_auto = DEMO_DEFAULT_AUTO
        self.demo_interval_s = DEMO_DEFAULT_INTERVAL_S
        self.b3_consumed = False
        self.flash_active = False
        self.flash_expires_ms = 0
        self.flash_kind = None
        self.flash_value = None
        self.b6_pending = False
        self.b6_press_started_ms = 0
        self.b6_long_fired = False
        self.battery_display_active = False
        self.battery_next_refresh_ms = 0
        self.battery_display_toggle_started_ms = 0
        self.edge_flash_active = False
        self.edge_flash_edge = None
        self.edge_flash_started_ms = 0
        self.special_demo_mode = False
        self.combo_press_started_ms = None
        self.combo_long_fired = False
        self.badapple_mode = False
        self.badapple_combo_press_started_ms = None
        self.badapple_combo_long_fired = False
        self.battery_next_log_ms = 0


class BatteryState:
    # -----------------------------------------------------------------------
    # Learned battery state.
    # last_voltage is the most recent measured voltage.
    # min_v / max_v are learned over time and persisted to settings.
    # measure_count tracks how many calibration measurements have happened.
    # relearn_holdoff_counts blocks min/max learning for N measurements after
    # the periodic inward shrink is applied.
    # usage_history stores learned discharge-rate samples for runtime estimate.
    # history_last_percent stores the most recent percent-float sample used to
    # derive the next discharge-rate history point.
    # -----------------------------------------------------------------------
    __slots__ = (
        "last_voltage", "min_v", "max_v",
        "measure_count", "relearn_holdoff_counts",
        "usage_history", "history_last_percent",
    )

    def __init__(self):
        self.last_voltage = None
        self.min_v = BATTERY_DEFAULT_MIN_V
        self.max_v = BATTERY_DEFAULT_MAX_V
        self.measure_count = 0
        self.relearn_holdoff_counts = 0
        self.usage_history = []
        self.history_last_percent = None
