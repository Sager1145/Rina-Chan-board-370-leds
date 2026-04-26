from config import (
    DEFAULT_FACE, DEFAULT_INTERVAL_S, DEFAULT_BRIGHTNESS,
    DEMO_DEFAULT_AUTO, DEMO_DEFAULT_INTERVAL_S,
    BATTERY_DEFAULT_MIN_V, BATTERY_DEFAULT_MAX_V,
)
class AppState:
    __slots__ = (
        "face_idx", "auto", "interval_s", "brightness",
        "manual_control_mode",
        "demo_auto", "demo_interval_s",
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
        "special_demo_mode",
        "combo_press_started_ms", "combo_long_fired",
        "badapple_mode",
        "badapple_combo_press_started_ms", "badapple_combo_long_fired",
        "brightness_reset_ignore_until_ms", "brightness_reset_combo_latched",
        "battery_next_log_ms",
        "ip_display_active", "ip_display_octets", "ip_display_phase_index",
        "ip_display_next_phase_ms", "ip_display_expires_ms",
        "ip_scroll_text", "ip_scroll_offset", "ip_scroll_next_ms",
        "ip_combo_latched",
    )
    def __init__(self):
        self.face_idx = DEFAULT_FACE
        self.auto = False
        self.interval_s = DEFAULT_INTERVAL_S
        self.brightness = DEFAULT_BRIGHTNESS
        self.manual_control_mode = False
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
        self.battery_visual_next_refresh_ms = 0
        self.battery_display_toggle_started_ms = 0
        self.battery_display_phase_index = 0
        self.battery_display_phase_count = 3
        self.battery_display_next_phase_ms = 0
        self.battery_display_expires_ms = 0
        self.battery_display_single_shot = False
        self.battery_display_cached_voltage = None
        self.battery_display_cached_percent = None
        self.battery_display_cached_percent_float = None
        self.battery_display_cached_remaining_h = None
        self.battery_display_cached_charge_voltage = None
        self.battery_display_cached_charge_time_h = None
        self.battery_display_cached_is_charging = False
        self.edge_flash_active = False
        self.edge_flash_edge = None
        self.edge_flash_started_ms = 0
        self.special_demo_mode = False
        self.combo_press_started_ms = None
        self.combo_long_fired = False
        self.badapple_mode = False
        self.badapple_combo_press_started_ms = None
        self.badapple_combo_long_fired = False
        self.brightness_reset_ignore_until_ms = 0
        self.brightness_reset_combo_latched = False
        self.battery_next_log_ms = 0
        self.ip_display_active = False
        self.ip_display_octets = None
        self.ip_display_phase_index = 0
        self.ip_display_next_phase_ms = 0
        self.ip_display_expires_ms = 0
        self.ip_scroll_text = ""
        self.ip_scroll_offset = 0
        self.ip_scroll_next_ms = 0
        self.ip_combo_latched = False
class BatteryState:
    __slots__ = (
        "last_voltage", "last_charge_voltage", "min_v", "max_v",
        "measure_count", "relearn_holdoff_counts",
        "inward_min_count", "inward_max_count",
        "usage_history", "history_last_percent",
        "charge_history", "charge_history_last_percent",
    )
    def __init__(self):
        self.last_voltage = None
        self.last_charge_voltage = None
        self.min_v = BATTERY_DEFAULT_MIN_V
        self.max_v = BATTERY_DEFAULT_MAX_V
        self.measure_count = 0
        self.relearn_holdoff_counts = 0
        self.inward_min_count = 0
        self.inward_max_count = 0
        self.usage_history = []
        self.history_last_percent = None
        self.charge_history = []
        self.charge_history_last_percent = None
