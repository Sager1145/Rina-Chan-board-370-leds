# ---------------------------------------------------------------------------
# app_state.py
# ---------------------------------------------------------------------------
# Import: Loads DEFAULT_FACE, DEFAULT_INTERVAL_S, DEFAULT_BRIGHTNESS, BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V from config so this module can use that dependency.
from config import (
    DEFAULT_FACE, DEFAULT_INTERVAL_S, DEFAULT_BRIGHTNESS,
    BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V,
)

# Class: Defines AppState as the state and behavior container for App State.
class AppState:
    # Variable: __slots__ stores the collection of values used later in this module.
    __slots__ = (
        "face_idx", "auto", "interval_s", "brightness",
        "manual_control_mode",
        "b3_consumed",
        "flash_active", "flash_expires_ms", "flash_kind", "flash_value",
        "b6_pending", "b6_press_started_ms", "b6_long_fired",
        "battery_display_active", "battery_next_refresh_ms",
        "battery_visual_next_refresh_ms",
        "battery_display_toggle_started_ms", "battery_display_phase_index",
        "battery_display_phase_count",
        "battery_display_next_phase_ms", "battery_display_expires_ms",
        "battery_display_single_shot", "battery_display_cached_voltage",
        "battery_display_cached_percent", "battery_display_cached_percent_float",
        "battery_display_cached_remaining_h", "battery_display_cached_charge_voltage",
        "battery_display_cached_charge_time_h", "battery_display_cached_is_charging",
        "edge_flash_active", "edge_flash_edge", "edge_flash_started_ms",
        "brightness_reset_ignore_until_ms", "brightness_reset_combo_latched",
        "battery_next_log_ms",
        "ip_display_active", "ip_display_octets", "ip_display_phase_index",
        "ip_display_next_phase_ms", "ip_display_expires_ms",
        "ip_scroll_text", "ip_scroll_offset", "ip_scroll_next_ms",
        "ip_combo_latched",
    )
    # Function: Defines __init__(self) to handle init behavior.
    def __init__(self):
        # Variable: self.face_idx stores the current DEFAULT_FACE value.
        self.face_idx = DEFAULT_FACE
        # Variable: self.auto stores the enabled/disabled flag value.
        self.auto = False
        # Variable: self.interval_s stores the current DEFAULT_INTERVAL_S value.
        self.interval_s = DEFAULT_INTERVAL_S
        # Variable: self.brightness stores the current DEFAULT_BRIGHTNESS value.
        self.brightness = DEFAULT_BRIGHTNESS
        # Runtime authority flag: physical buttons put the board in manual
        # control mode; network/WebUI control exits manual mode.
        # Variable: self.manual_control_mode stores the enabled/disabled flag value.
        self.manual_control_mode = False
        # Variable: self.b3_consumed stores the enabled/disabled flag value.
        self.b3_consumed = False
        # Variable: self.flash_active stores the enabled/disabled flag value.
        self.flash_active = False
        # Variable: self.flash_expires_ms stores the configured literal value.
        self.flash_expires_ms = 0
        # Variable: self.flash_kind stores the empty sentinel value.
        self.flash_kind = None
        # Variable: self.flash_value stores the empty sentinel value.
        self.flash_value = None
        # Variable: self.b6_pending stores the enabled/disabled flag value.
        self.b6_pending = False
        # Variable: self.b6_press_started_ms stores the configured literal value.
        self.b6_press_started_ms = 0
        # Variable: self.b6_long_fired stores the enabled/disabled flag value.
        self.b6_long_fired = False
        # Variable: self.battery_display_active stores the enabled/disabled flag value.
        self.battery_display_active = False
        # Variable: self.battery_next_refresh_ms stores the configured literal value.
        self.battery_next_refresh_ms = 0
        # Variable: self.battery_visual_next_refresh_ms stores the configured literal value.
        self.battery_visual_next_refresh_ms = 0
        # Variable: self.battery_display_toggle_started_ms stores the configured literal value.
        self.battery_display_toggle_started_ms = 0
        # Variable: self.battery_display_phase_index stores the configured literal value.
        self.battery_display_phase_index = 0
        # Variable: self.battery_display_phase_count stores the configured literal value.
        self.battery_display_phase_count = 3
        # Variable: self.battery_display_next_phase_ms stores the configured literal value.
        self.battery_display_next_phase_ms = 0
        # Variable: self.battery_display_expires_ms stores the configured literal value.
        self.battery_display_expires_ms = 0
        # Variable: self.battery_display_single_shot stores the enabled/disabled flag value.
        self.battery_display_single_shot = False
        # Variable: self.battery_display_cached_voltage stores the empty sentinel value.
        self.battery_display_cached_voltage = None
        # Variable: self.battery_display_cached_percent stores the empty sentinel value.
        self.battery_display_cached_percent = None
        # Variable: self.battery_display_cached_percent_float stores the empty sentinel value.
        self.battery_display_cached_percent_float = None
        # Variable: self.battery_display_cached_remaining_h stores the empty sentinel value.
        self.battery_display_cached_remaining_h = None
        # Variable: self.battery_display_cached_charge_voltage stores the empty sentinel value.
        self.battery_display_cached_charge_voltage = None
        # Variable: self.battery_display_cached_charge_time_h stores the empty sentinel value.
        self.battery_display_cached_charge_time_h = None
        # Variable: self.battery_display_cached_is_charging stores the enabled/disabled flag value.
        self.battery_display_cached_is_charging = False
        # Variable: self.edge_flash_active stores the enabled/disabled flag value.
        self.edge_flash_active = False
        # Variable: self.edge_flash_edge stores the empty sentinel value.
        self.edge_flash_edge = None
        # Variable: self.edge_flash_started_ms stores the configured literal value.
        self.edge_flash_started_ms = 0
        # Variable: self.brightness_reset_ignore_until_ms stores the configured literal value.
        self.brightness_reset_ignore_until_ms = 0
        # Variable: self.brightness_reset_combo_latched stores the enabled/disabled flag value.
        self.brightness_reset_combo_latched = False
        # Variable: self.battery_next_log_ms stores the configured literal value.
        self.battery_next_log_ms = 0
        # Variable: self.ip_display_active stores the enabled/disabled flag value.
        self.ip_display_active = False
        # Variable: self.ip_display_octets stores the empty sentinel value.
        self.ip_display_octets = None
        # Variable: self.ip_display_phase_index stores the configured literal value.
        self.ip_display_phase_index = 0
        # Variable: self.ip_display_next_phase_ms stores the configured literal value.
        self.ip_display_next_phase_ms = 0
        # Variable: self.ip_display_expires_ms stores the configured literal value.
        self.ip_display_expires_ms = 0
        # Variable: self.ip_scroll_text stores the configured text value.
        self.ip_scroll_text = ""
        # Variable: self.ip_scroll_offset stores the configured literal value.
        self.ip_scroll_offset = 0
        # Variable: self.ip_scroll_next_ms stores the configured literal value.
        self.ip_scroll_next_ms = 0
        # Variable: self.ip_combo_latched stores the enabled/disabled flag value.
        self.ip_combo_latched = False

# Class: Defines BatteryState as the state and behavior container for Battery State.
class BatteryState:
    # Variable: __slots__ stores the collection of values used later in this module.
    __slots__ = (
        "last_voltage", "last_charge_voltage", "min_v", "max_v",
        "measure_count", "relearn_holdoff_counts",
        "inward_min_count", "inward_max_count",
        "usage_history", "history_last_percent",
        "charge_history", "charge_history_last_percent",
    )
    # Function: Defines __init__(self) to handle init behavior.
    def __init__(self):
        # Variable: self.last_voltage stores the empty sentinel value.
        self.last_voltage = None
        # Variable: self.last_charge_voltage stores the empty sentinel value.
        self.last_charge_voltage = None
        # Variable: self.min_v stores the current BATTERY_DEFAULT_MIN_V value.
        self.min_v = BATTERY_DEFAULT_MIN_V
        # Variable: self.max_v stores the current BATTERY_DEFAULT_MAX_V value.
        self.max_v = BATTERY_DEFAULT_MAX_V
        # Variable: self.measure_count stores the configured literal value.
        self.measure_count = 0
        # Variable: self.relearn_holdoff_counts stores the configured literal value.
        self.relearn_holdoff_counts = 0
        # Per-side consecutive-inward-adjust counters. Each starts at 0,
        # increments every time its side is pulled inward without a new
        # real extreme, and resets to 0 when a new real extreme on that
        # side is recorded. When a counter reaches
        # BATTERY_RELEARN_MAX_CONSECUTIVE, that side is frozen until the
        # next new real extreme.
        # Variable: self.inward_min_count stores the configured literal value.
        self.inward_min_count = 0
        # Variable: self.inward_max_count stores the configured literal value.
        self.inward_max_count = 0
        # Variable: self.usage_history stores the collection of values used later in this module.
        self.usage_history = []
        # Variable: self.history_last_percent stores the empty sentinel value.
        self.history_last_percent = None
        # Variable: self.charge_history stores the collection of values used later in this module.
        self.charge_history = []
        # Variable: self.charge_history_last_percent stores the empty sentinel value.
        self.charge_history_last_percent = None
