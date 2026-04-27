# ---------------------------------------------------------------------------
# main.py
#
# Modular RinaChanBoard controller for ESP32-S3 + 370 LEDs.
#
# Application entry point, module composition root, and main loop scheduler.
# Feature logic lives in dedicated modules:
#
#   color_module.py    Global color + brightness authority (all modes read here)
#   face_module.py     Saved faces / physical 370 face drawing
#   scroll_module.py   IP/SSID scrolling overlay
#   wifi_module.py     Wi-Fi / UDP / HTTP polling glue
#   gpio_module.py     Hardware button routing
#   home_module.py     Home mode, A/M toggle, flash overlays, interval
#   battery_module.py  Battery percent/voltage/time/charging animation
#   unity_module.py    Firmware-side WebUI runtime bridge
#
# rina_protocol.py is kept as a separate protocol/router layer.
# It calls back into this facade; the facade delegates to feature modules.
# ---------------------------------------------------------------------------

# Import: Loads gc so this module can use that dependency.
import gc
# Import: Loads time so this module can use that dependency.
import time

# Expression: Calls gc.collect() for its side effects.
gc.collect()

# Import: Loads board so this module can use that dependency.
import board
# Import: Loads clear, show from board so this module can use that dependency.
from board import clear, show
# Expression: Calls gc.collect() for its side effects.
gc.collect()

# Import: Loads RinaProtocol, VERSION from rina_protocol so this module can use that dependency.
from rina_protocol import RinaProtocol, VERSION
# Expression: Calls gc.collect() for its side effects.
gc.collect()

# Import: Loads saved_faces_370 so this module can use that dependency.
import saved_faces_370
# Expression: Calls gc.collect() for its side effects.
gc.collect()
# Import: Loads ButtonBank, BTN_BRIGHT_DN, BTN_BRIGHT_UP from buttons so this module can use that dependency.
from buttons import ButtonBank, BTN_BRIGHT_DN, BTN_BRIGHT_UP
# Expression: Calls gc.collect() for its side effects.
gc.collect()

# Import: Loads * from config so this module can use that dependency.
from config import *
# Import: Loads AppState, BatteryState from app_state so this module can use that dependency.
from app_state import AppState, BatteryState
# Import: Loads load_settings, save_settings from settings_store so this module can use that dependency.
from settings_store import load_settings, save_settings
# Import: Loads BatteryMonitor from battery_monitor so this module can use that dependency.
from battery_monitor import BatteryMonitor
# Import: Loads ESP32S3Network from esp32s3_network so this module can use that dependency.
from esp32s3_network import ESP32S3Network
# Import: Loads WebUIRuntime from webui_runtime so this module can use that dependency.
from webui_runtime import WebUIRuntime
# Expression: Calls gc.collect() for its side effects.
gc.collect()

# Import: Loads ColorModule from color_module so this module can use that dependency.
from color_module import ColorModule
# Import: Loads FaceModule from face_module so this module can use that dependency.
from face_module import FaceModule
# Import: Loads ScrollModule from scroll_module so this module can use that dependency.
from scroll_module import ScrollModule
# Import: Loads WiFiModule from wifi_module so this module can use that dependency.
from wifi_module import WiFiModule
# Import: Loads GPIOModule from gpio_module so this module can use that dependency.
from gpio_module import GPIOModule
# Import: Loads HomeModule from home_module so this module can use that dependency.
from home_module import HomeModule
# Import: Loads BatteryModule from battery_module so this module can use that dependency.
from battery_module import BatteryModule
# Import: Loads UnityModule from unity_module so this module can use that dependency.
from unity_module import UnityModule
# Expression: Calls gc.collect() for its side effects.
gc.collect()

# Variable: FIRMWARE_BANNER stores the configured text value.
FIRMWARE_BANNER = (
    "RinaChanBoard ESP32-S3 370LED modular 1.8.0 "
    "color_module-authority brightness-sync AP+protocol+RNT2 battery"
)


# Class: Defines LinaBoardApp as the state and behavior container for Lina Board App.
class LinaBoardApp:
    # Variable: __slots__ stores the collection of values used later in this module.
    __slots__ = (
        "state", "battery", "buttons", "battery_monitor", "network_poll",
        "proto", "link", "button_face_active", "web_runtime",
        "color_module", "face_module", "scroll_module", "wifi_module",
        "gpio_module", "home_module", "battery_module", "unity_module",
    )

    # Function: Defines __init__(self) to handle init behavior.
    def __init__(self):
        # Variable: self.state stores the result returned by AppState().
        self.state = AppState()
        # Variable: self.battery stores the result returned by BatteryState().
        self.battery = BatteryState()
        # Variable: self.buttons stores the result returned by ButtonBank().
        self.buttons = ButtonBank()
        # Variable: self.battery_monitor stores the result returned by BatteryMonitor().
        self.battery_monitor = BatteryMonitor()
        # Variable: self.network_poll stores the empty sentinel value.
        self.network_poll = None
        # Variable: self.proto stores the empty sentinel value.
        self.proto = None
        # Variable: self.link stores the empty sentinel value.
        self.link = None
        # Variable: self.button_face_active stores the enabled/disabled flag value.
        self.button_face_active = False
        # Variable: self.web_runtime stores the result returned by WebUIRuntime().
        self.web_runtime = WebUIRuntime(self)

        # Feature modules receive this facade and communicate via callbacks
        # rather than importing one another directly.
        # Variable: self.color_module stores the result returned by ColorModule().
        self.color_module = ColorModule(self)
        # Variable: self.face_module stores the result returned by FaceModule().
        self.face_module = FaceModule(self)
        # Variable: self.scroll_module stores the result returned by ScrollModule().
        self.scroll_module = ScrollModule(self)
        # Variable: self.wifi_module stores the result returned by WiFiModule().
        self.wifi_module = WiFiModule(self)
        # Variable: self.gpio_module stores the result returned by GPIOModule().
        self.gpio_module = GPIOModule(self)
        # Variable: self.home_module stores the result returned by HomeModule().
        self.home_module = HomeModule(self)
        # Variable: self.battery_module stores the result returned by BatteryModule().
        self.battery_module = BatteryModule(self)
        # Variable: self.unity_module stores the result returned by UnityModule().
        self.unity_module = UnityModule(self)

    # ------------------------------------------------------------------
    # Persistence shared by all modules
    # ------------------------------------------------------------------
    # Function: Defines save_settings(self) to handle save settings behavior.
    def save_settings(self):
        # Expression: Calls save_settings() for its side effects.
        save_settings(self.state, self.battery)

    # ------------------------------------------------------------------
    # Color module facade  (global color + brightness authority)
    # ------------------------------------------------------------------
    # Function: Defines get_color(self) to handle get color behavior.
    def get_color(self):
        # Return: Sends the result returned by self.color_module.get_color() back to the caller.
        return self.color_module.get_color()

    # Function: Defines get_dimmed_color(self) to handle get dimmed color behavior.
    def get_dimmed_color(self):
        # Return: Sends the result returned by self.color_module.get_dimmed_color() back to the caller.
        return self.color_module.get_dimmed_color()

    # Backward-compat aliases used by webui_runtime and any legacy caller.
    # Function: Defines _current_home_color(self) to handle current home color behavior.
    def _current_home_color(self):
        # Return: Sends the result returned by self.color_module.get_color() back to the caller.
        return self.color_module.get_color()

    # Function: Defines _dimmed_home_color(self, color) to handle dimmed home color behavior.
    def _dimmed_home_color(self, color):
        # Return: Sends the result returned by self.color_module.get_dimmed_color() back to the caller.
        return self.color_module.get_dimmed_color()

    # Function: Defines apply_brightness(self) to handle apply brightness behavior.
    def apply_brightness(self):
        # Return: Sends the result returned by self.color_module.apply_brightness() back to the caller.
        return self.color_module.apply_brightness()

    # Function: Defines sync_protocol_brightness_from_buttons(self) to handle sync protocol brightness from buttons behavior.
    def sync_protocol_brightness_from_buttons(self):
        # Return: Sends the result returned by self.color_module.sync_protocol_brightness_from_buttons() back to the caller.
        return self.color_module.sync_protocol_brightness_from_buttons()

    # Function: Defines set_brightness(self, pct, save, sync_protocol) to handle set brightness behavior.
    def set_brightness(self, pct, save=True, sync_protocol=True):
        # Return: Sends the result returned by self.color_module.set_brightness() back to the caller.
        return self.color_module.set_brightness(pct, save=save, sync_protocol=sync_protocol)

    # Function: Defines on_protocol_color_updated(self, color) to handle on protocol color updated behavior.
    def on_protocol_color_updated(self, color):
        # Return: Sends the result returned by self.color_module.on_protocol_color_updated() back to the caller.
        return self.color_module.on_protocol_color_updated(color)

    # Function: Defines on_protocol_brightness_updated(self, bright) to handle on protocol brightness updated behavior.
    def on_protocol_brightness_updated(self, bright):
        # Return: Sends the result returned by self.color_module.on_protocol_brightness_updated() back to the caller.
        return self.color_module.on_protocol_brightness_updated(bright)

    # ------------------------------------------------------------------
    # Face module facade
    # ------------------------------------------------------------------
    # Function: Defines draw_current_face(self) to handle draw current face behavior.
    def draw_current_face(self):
        # Return: Sends the result returned by self.face_module.draw_current_face() back to the caller.
        return self.face_module.draw_current_face()

    # Function: Defines render_current_visual(self, force) to handle render current visual behavior.
    def render_current_visual(self, force=False):
        # Return: Sends the result returned by self.face_module.render_current_visual() back to the caller.
        return self.face_module.render_current_visual(force=force)

    # Function: Defines cycle_face(self, delta) to handle cycle face behavior.
    def cycle_face(self, delta):
        # Return: Sends the result returned by self.face_module.cycle_face() back to the caller.
        return self.face_module.cycle_face(delta)

    # Function: Defines select_saved_face(self, index, redraw) to handle select saved face behavior.
    def select_saved_face(self, index, redraw=True):
        # Return: Sends the result returned by self.face_module.select_saved_face() back to the caller.
        return self.face_module.select_saved_face(index, redraw=redraw)

    # Function: Defines on_saved_faces_changed(self, selected_index, redraw) to handle on saved faces changed behavior.
    def on_saved_faces_changed(self, selected_index=None, redraw=False):
        # Return: Sends the result returned by self.face_module.on_saved_faces_changed() back to the caller.
        return self.face_module.on_saved_faces_changed(selected_index=selected_index, redraw=redraw)

    # ------------------------------------------------------------------
    # Home / mode module facade
    # ------------------------------------------------------------------
    # Function: Defines start_edge_flash(self, edge) to handle start edge flash behavior.
    def start_edge_flash(self, edge):
        # Return: Sends the result returned by self.home_module.start_edge_flash() back to the caller.
        return self.home_module.start_edge_flash(edge)

    # Function: Defines edge_flash_factor(self, elapsed_ms) to handle edge flash factor behavior.
    def edge_flash_factor(self, elapsed_ms):
        # Return: Sends the result returned by self.home_module.edge_flash_factor() back to the caller.
        return self.home_module.edge_flash_factor(elapsed_ms)

    # Function: Defines overlay_edge_flash(self) to handle overlay edge flash behavior.
    def overlay_edge_flash(self):
        # Return: Sends the result returned by self.home_module.overlay_edge_flash() back to the caller.
        return self.home_module.overlay_edge_flash()

    # Function: Defines render_flash_overlay_base(self) to handle render flash overlay base behavior.
    def render_flash_overlay_base(self):
        # Return: Sends the result returned by self.home_module.render_flash_overlay_base() back to the caller.
        return self.home_module.render_flash_overlay_base()

    # Function: Defines render_flash_overlay_with_edge(self) to handle render flash overlay with edge behavior.
    def render_flash_overlay_with_edge(self):
        # Return: Sends the result returned by self.home_module.render_flash_overlay_with_edge() back to the caller.
        return self.home_module.render_flash_overlay_with_edge()

    # Function: Defines start_or_extend_flash(self, kind, value) to handle start or extend flash behavior.
    def start_or_extend_flash(self, kind=None, value=None):
        # Return: Sends the result returned by self.home_module.start_or_extend_flash() back to the caller.
        return self.home_module.start_or_extend_flash(kind=kind, value=value)

    # Function: Defines end_flash_if_expired(self) to handle end flash if expired behavior.
    def end_flash_if_expired(self):
        # Return: Sends the result returned by self.home_module.end_flash_if_expired() back to the caller.
        return self.home_module.end_flash_if_expired()

    # Function: Defines cancel_flash_and_redraw(self) to handle cancel flash and redraw behavior.
    def cancel_flash_and_redraw(self):
        # Return: Sends the result returned by self.home_module.cancel_flash_and_redraw() back to the caller.
        return self.home_module.cancel_flash_and_redraw()

    # Function: Defines check_special_demo_combo(self) to handle check special demo combo behavior.
    def check_special_demo_combo(self):
        # Return: Sends the result returned by self.home_module.check_special_demo_combo() back to the caller.
        return self.home_module.check_special_demo_combo()

    # Function: Defines adjust_interval(self, delta) to handle adjust interval behavior.
    def adjust_interval(self, delta):
        # Return: Sends the result returned by self.home_module.adjust_interval() back to the caller.
        return self.home_module.adjust_interval(delta)

    # Function: Defines adjust_brightness(self, delta) to handle adjust brightness behavior.
    def adjust_brightness(self, delta):
        # Return: Sends the result returned by self.home_module.adjust_brightness() back to the caller.
        return self.home_module.adjust_brightness(delta)

    # Function: Defines reset_brightness(self) to handle reset brightness behavior.
    def reset_brightness(self):
        # Return: Sends the result returned by self.home_module.reset_brightness() back to the caller.
        return self.home_module.reset_brightness()

    # Function: Defines force_m_mode(self, source, persist) to handle force m mode behavior.
    def force_m_mode(self, source="network", persist=True):
        # Return: Sends the result returned by self.home_module.force_m_mode() back to the caller.
        return self.home_module.force_m_mode(source=source, persist=persist)

    # Function: Defines set_manual_control_mode(self, enabled, redraw, source) to handle set manual control mode behavior.
    def set_manual_control_mode(self, enabled=True, redraw=False, source=""):
        # Return: Sends the result returned by self.home_module.set_manual_control_mode() back to the caller.
        return self.home_module.set_manual_control_mode(enabled=enabled, redraw=redraw, source=source)

    # Function: Defines enter_manual_control_from_button(self, gp) to handle enter manual control from button behavior.
    def enter_manual_control_from_button(self, gp=None):
        # Return: Sends the result returned by self.home_module.enter_manual_control_from_button() back to the caller.
        return self.home_module.enter_manual_control_from_button(gp=gp)

    # Function: Defines exit_manual_control_from_network(self, source) to handle exit manual control from network behavior.
    def exit_manual_control_from_network(self, source="network"):
        # Return: Sends the result returned by self.home_module.exit_manual_control_from_network() back to the caller.
        return self.home_module.exit_manual_control_from_network(source=source)

    # Function: Defines manual_control_status_json(self) to handle manual control status json behavior.
    def manual_control_status_json(self):
        # Return: Sends the result returned by self.home_module.manual_control_status_json() back to the caller.
        return self.home_module.manual_control_status_json()

    # Function: Defines toggle_auto(self) to handle toggle auto behavior.
    def toggle_auto(self):
        # Return: Sends the result returned by self.home_module.toggle_auto() back to the caller.
        return self.home_module.toggle_auto()

    # ------------------------------------------------------------------
    # Battery module facade
    # ------------------------------------------------------------------
    # Function: Defines stop_battery_display(self) to handle stop battery display behavior.
    def stop_battery_display(self):
        # Return: Sends the result returned by self.battery_module.stop_battery_display() back to the caller.
        return self.battery_module.stop_battery_display()

    # Function: Defines service_battery_sampling(self, force_sample) to handle service battery sampling behavior.
    def service_battery_sampling(self, force_sample=False):
        # Return: Sends the result returned by self.battery_module.service_battery_sampling() back to the caller.
        return self.battery_module.service_battery_sampling(force_sample=force_sample)

    # Function: Defines is_charging(self, charge_v, previous) to handle is charging behavior.
    def is_charging(self, charge_v=None, previous=None):
        # Return: Sends the result returned by self.battery_module.is_charging() back to the caller.
        return self.battery_module.is_charging(charge_v=charge_v, previous=previous)

    # Function: Defines show_battery_percent_short(self) to handle show battery percent short behavior.
    def show_battery_percent_short(self):
        # Return: Sends the result returned by self.battery_module.show_battery_percent_short() back to the caller.
        return self.battery_module.show_battery_percent_short()

    # Function: Defines refresh_battery_overlay_cache(self, force) to handle refresh battery overlay cache behavior.
    def refresh_battery_overlay_cache(self, force=False):
        # Return: Sends the result returned by self.battery_module.refresh_battery_overlay_cache() back to the caller.
        return self.battery_module.refresh_battery_overlay_cache(force=force)

    # Function: Defines update_battery_display_phase(self) to handle update battery display phase behavior.
    def update_battery_display_phase(self):
        # Return: Sends the result returned by self.battery_module.update_battery_display_phase() back to the caller.
        return self.battery_module.update_battery_display_phase()

    # Function: Defines service_battery_overlay(self) to handle service battery overlay behavior.
    def service_battery_overlay(self):
        # Return: Sends the result returned by self.battery_module.service_battery_overlay() back to the caller.
        return self.battery_module.service_battery_overlay()

    # Function: Defines render_battery_overlay(self, refresh_phase, refresh_cache, log_status) to handle render battery overlay behavior.
    def render_battery_overlay(self, refresh_phase=True, refresh_cache=True, log_status=True):
        # Return: Sends the result returned by self.battery_module.render_battery_overlay() back to the caller.
        return self.battery_module.render_battery_overlay(refresh_phase=refresh_phase, refresh_cache=refresh_cache, log_status=log_status)

    # Function: Defines start_b6_press(self) to handle start b6 press behavior.
    def start_b6_press(self):
        # Return: Sends the result returned by self.battery_module.start_b6_press() back to the caller.
        return self.battery_module.start_b6_press()

    # Function: Defines check_b6_hold(self) to handle check b6 hold behavior.
    def check_b6_hold(self):
        # Return: Sends the result returned by self.battery_module.check_b6_hold() back to the caller.
        return self.battery_module.check_b6_hold()

    # Function: Defines check_b6_release(self, prev_b6_down) to handle check b6 release behavior.
    def check_b6_release(self, prev_b6_down):
        # Return: Sends the result returned by self.battery_module.check_b6_release() back to the caller.
        return self.battery_module.check_b6_release(prev_b6_down)

    # Function: Defines battery_status_json(self) to handle battery status json behavior.
    def battery_status_json(self):
        # Return: Sends the result returned by self.battery_module.battery_status_json() back to the caller.
        return self.battery_module.battery_status_json()

    # ------------------------------------------------------------------
    # Scroll module facade
    # ------------------------------------------------------------------
    # Function: Defines start_ip_display(self) to handle start ip display behavior.
    def start_ip_display(self):
        # Return: Sends the result returned by self.scroll_module.start_ip_display() back to the caller.
        return self.scroll_module.start_ip_display()

    # Function: Defines service_ip_display(self) to handle service ip display behavior.
    def service_ip_display(self):
        # Return: Sends the result returned by self.scroll_module.service_ip_display() back to the caller.
        return self.scroll_module.service_ip_display()

    # Function: Defines check_ip_combo(self) to handle check ip combo behavior.
    def check_ip_combo(self):
        # Return: Sends the result returned by self.scroll_module.check_ip_combo() back to the caller.
        return self.scroll_module.check_ip_combo()

    # ------------------------------------------------------------------
    # GPIO module facade
    # ------------------------------------------------------------------
    # Function: Defines handle_press(self, gp) to handle handle press behavior.
    def handle_press(self, gp):
        # Return: Sends the result returned by self.gpio_module.handle_press() back to the caller.
        return self.gpio_module.handle_press(gp)

    # Function: Defines check_b3_release(self, prev_b3_down) to handle check b3 release behavior.
    def check_b3_release(self, prev_b3_down):
        # Return: Sends the result returned by self.gpio_module.check_b3_release() back to the caller.
        return self.gpio_module.check_b3_release(prev_b3_down)

    # ------------------------------------------------------------------
    # Unity / WebUI runtime facade
    # ------------------------------------------------------------------
    # Function: Defines handle_webui_runtime_command(self, command) to handle handle webui runtime command behavior.
    def handle_webui_runtime_command(self, command):
        # Return: Sends the result returned by self.unity_module.handle_webui_runtime_command() back to the caller.
        return self.unity_module.handle_webui_runtime_command(command)

    # Function: Defines stop_webui_runtime(self, redraw) to handle stop webui runtime behavior.
    def stop_webui_runtime(self, redraw=True):
        # Return: Sends the result returned by self.unity_module.stop_webui_runtime() back to the caller.
        return self.unity_module.stop_webui_runtime(redraw=redraw)

    # ------------------------------------------------------------------
    # Wi-Fi / protocol facade
    # ------------------------------------------------------------------
    # Function: Defines attach_network(self, link, proto) to handle attach network behavior.
    def attach_network(self, link, proto):
        # Return: Sends the result returned by self.wifi_module.attach_network() back to the caller.
        return self.wifi_module.attach_network(link, proto)

    # Function: Defines service_network(self) to handle service network behavior.
    def service_network(self):
        # Return: Sends the result returned by self.wifi_module.service_network() back to the caller.
        return self.wifi_module.service_network()

    # Function: Defines on_network_control(self) to handle on network control behavior.
    def on_network_control(self):
        # Return: Sends the result returned by self.wifi_module.on_network_control() back to the caller.
        return self.wifi_module.on_network_control()

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------
    # Function: Defines print_startup_info(self) to handle print startup info behavior.
    def print_startup_info(self):
        # Expression: Calls print() for its side effects.
        print(FIRMWARE_BANNER)
        # Expression: Calls print() for its side effects.
        print("Firmware version:", VERSION)
        # Expression: Calls print() for its side effects.
        print("linaboard: starting")
        # Expression: Calls print() for its side effects.
        print("  module layout       = main + protocol router + feature modules")
        # Expression: Calls print() for its side effects.
        print("  color authority     = color_module (color + brightness for all modes)")
        # Expression: Calls print() for its side effects.
        print("  protocol layer      = rina_protocol.py with callback bridge")
        # Expression: Calls print() for its side effects.
        print("  battery display     = battery_module.py")
        # Expression: Calls print() for its side effects.
        print("  default face interval=", DEFAULT_INTERVAL_S, "s")
        # Expression: Calls print() for its side effects.
        print("  default brightness  =", DEFAULT_BRIGHTNESS, "%")
        # Expression: Calls print() for its side effects.
        print("  button GPIOs        =", self.buttons.gpios())
        # Expression: Calls print() for its side effects.
        print("  B3+B6 combo         = consumed (no action)")
        # Expression: Calls print() for its side effects.
        print("  B2+B6 scroll IP/SSID= enabled (uses global display color)")
        # Expression: Calls print() for its side effects.
        print("  saved custom faces  =", saved_faces_370.count(), "faces; B1/B2 and A/M cycle this list")
        # Expression: Calls print() for its side effects.
        print("  webui runtime       = firmware-side scroll text + Unity timeline playback")
        # Expression: Calls print() for its side effects.
        print("  face manager store  = ESP32-S3 firmware source of truth; WebUI pulls/syncs list")
        # Expression: Calls print() for its side effects.
        print("  manual control mode = buttons enter; network/WebUI exits")

    # Function: Defines initialize(self) to handle initialize behavior.
    def initialize(self):
        # Expression: Calls self.print_startup_info() for its side effects.
        self.print_startup_info()
        # Expression: Calls load_settings() for its side effects.
        load_settings(self.state, self.battery)
        # Expression: Calls print() for its side effects.
        print("  network             = ESP32-S3 native Wi-Fi + HTTP + UDP")
        # Expression: Calls self.apply_brightness() for its side effects.
        self.apply_brightness()
        # Expression: Calls self.draw_current_face() for its side effects.
        self.draw_current_face()
        # Expression: Calls self.service_battery_sampling() for its side effects.
        self.service_battery_sampling(force_sample=True)

    # Function: Defines run(self) to handle run behavior.
    def run(self):
        # Expression: Calls self.initialize() for its side effects.
        self.initialize()

        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Variable: next_auto_ms stores the result returned by time.ticks_add().
        next_auto_ms = time.ticks_add(now, int(self.state.interval_s * 1000))
        # Variable: self.state.battery_next_log_ms stores the current now value.
        self.state.battery_next_log_ms = now
        # Expression: Calls self.battery_monitor.update_calibration() for its side effects.
        self.battery_monitor.update_calibration(self.battery, self.state, self.save_settings, force=True)

        # Variable: prev_b3_down stores the enabled/disabled flag value.
        prev_b3_down = False
        # Variable: prev_b6_down stores the enabled/disabled flag value.
        prev_b6_down = False

        # Loop: Repeats while True remains true.
        while True:
            # Expression: Calls self.service_network() for its side effects.
            self.service_network()
            # Variable: combo_active stores the result returned by self.check_special_demo_combo().
            combo_active = self.check_special_demo_combo()
            # Variable: combo_active stores the combined condition self.check_ip_combo() or combo_active.
            combo_active = self.check_ip_combo() or combo_active

            # Loop: Iterates gp over self.buttons.poll() so each item can be processed.
            for gp in self.buttons.poll():
                # Expression: Calls self.handle_press() for its side effects.
                self.handle_press(gp)
                # Variable: next_auto_ms stores the result returned by time.ticks_add().
                next_auto_ms = time.ticks_add(time.ticks_ms(), int(self.state.interval_s * 1000))

            # Variable: combo_active stores the combined condition self.check_special_demo_combo() or combo_active.
            combo_active = self.check_special_demo_combo() or combo_active
            # Variable: combo_active stores the combined condition self.check_ip_combo() or combo_active.
            combo_active = self.check_ip_combo() or combo_active

            # Expression: Calls self.check_b6_hold() for its side effects.
            self.check_b6_hold()
            # Expression: Calls self.service_battery_overlay() for its side effects.
            self.service_battery_overlay()
            # Expression: Calls self.service_ip_display() for its side effects.
            self.service_ip_display()
            # Expression: Calls self.web_runtime.service() for its side effects.
            self.web_runtime.service()

            # Logic: Branches when self.state.brightness_reset_combo_latched and not self.buttons.is_down(BTN_BRIGHT_DN)... so the correct firmware path runs.
            if (self.state.brightness_reset_combo_latched and
                    not self.buttons.is_down(BTN_BRIGHT_DN) and
                    not self.buttons.is_down(BTN_BRIGHT_UP)):
                # Variable: self.state.brightness_reset_combo_latched stores the enabled/disabled flag value.
                self.state.brightness_reset_combo_latched = False

            # Variable: prev_b3_down stores the result returned by self.check_b3_release().
            prev_b3_down = self.check_b3_release(prev_b3_down)
            # Variable: prev_b6_down stores the result returned by self.check_b6_release().
            prev_b6_down = self.check_b6_release(prev_b6_down)

            # Logic: Branches when not self.state.battery_display_active and not self.state.ip_display_active so the correct firmware path runs.
            if not self.state.battery_display_active and not self.state.ip_display_active:
                # Expression: Calls self.end_flash_if_expired() for its side effects.
                self.end_flash_if_expired()

            # Logic: Branches when self.state.flash_active and self.state.edge_flash_active so the correct firmware path runs.
            if self.state.flash_active and self.state.edge_flash_active:
                # Expression: Calls self.render_flash_overlay_with_edge() for its side effects.
                self.render_flash_overlay_with_edge()
            # Logic: Branches when self.state.edge_flash_active and not self.state.flash_active so the correct firmware path runs.
            elif self.state.edge_flash_active and not self.state.flash_active:
                # Variable: self.state.edge_flash_active stores the enabled/disabled flag value.
                self.state.edge_flash_active = False

            # Expression: Calls self.service_battery_sampling() for its side effects.
            self.service_battery_sampling()
            # Expression: Calls self.battery_monitor.update_calibration() for its side effects.
            self.battery_monitor.update_calibration(self.battery, self.state, self.save_settings)

            # Logic: Branches when self.state.auto and not self.web_runtime.active() and not self.state.flash_active and... so the correct firmware path runs.
            if (self.state.auto and not self.web_runtime.active() and
                    not self.state.flash_active and not self.state.battery_display_active and
                    not self.state.ip_display_active):
                # Variable: now stores the result returned by time.ticks_ms().
                now = time.ticks_ms()
                # Logic: Branches when time.ticks_diff(now, next_auto_ms) >= 0 so the correct firmware path runs.
                if time.ticks_diff(now, next_auto_ms) >= 0:
                    # Variable: self.state.face_idx stores the calculated expression (self.state.face_idx + 1) % max(1, saved_faces_370.count()).
                    self.state.face_idx = (self.state.face_idx + 1) % max(1, saved_faces_370.count())
                    # Expression: Calls self.draw_current_face() for its side effects.
                    self.draw_current_face()
                    # Variable: next_auto_ms stores the result returned by time.ticks_add().
                    next_auto_ms = time.ticks_add(now, int(self.state.interval_s * 1000))

            # Logic: Branches when self.web_runtime.active() or self.state.flash_active or self.state.battery_display_ac... so the correct firmware path runs.
            if (self.web_runtime.active() or self.state.flash_active or
                    self.state.battery_display_active or self.state.ip_display_active or combo_active):
                # Variable: next_auto_ms stores the result returned by time.ticks_add().
                next_auto_ms = time.ticks_add(time.ticks_ms(), int(self.state.interval_s * 1000))

            # Expression: Calls time.sleep() for its side effects.
            time.sleep(POLL_PERIOD_MS / 1000.0)


# ---------------------------------------------------------------------------
# Boot entry point.
# ---------------------------------------------------------------------------
# Function: Defines main() to handle main behavior.
def main():
    # Expression: Calls print() for its side effects.
    print("ESP32-S3 native: Wi-Fi + HTTP + UDP + LED in one firmware")
    # Expression: Calls print() for its side effects.
    print("LED:", board.hardware_summary())
    # Variable: app stores the result returned by LinaBoardApp().
    app = LinaBoardApp()
    # Variable: link stores the result returned by ESP32S3Network().
    link = ESP32S3Network(log_limit=160)
    # Expression: Calls link.start() for its side effects.
    link.start()
    # Variable: proto stores the result returned by RinaProtocol().
    proto = RinaProtocol(app=app)
    # Expression: Calls proto.set_sender() for its side effects.
    proto.set_sender(lambda ip, port, data, link_id=0: link.send_udp(data, ip, port, link_id))
    # Expression: Calls proto.set_callbacks() for its side effects.
    proto.set_callbacks(
        network_control=app.on_network_control,
        manual_control_status_json=app.manual_control_status_json,
        set_manual_control_mode=app.set_manual_control_mode,
        exit_manual_control_from_network=app.exit_manual_control_from_network,
        stop_webui_runtime=app.stop_webui_runtime,
        force_m_mode=app.force_m_mode,
        handle_webui_runtime_command=app.handle_webui_runtime_command,
        select_saved_face=app.select_saved_face,
        on_saved_faces_changed=app.on_saved_faces_changed,
        battery_status_json=app.battery_status_json,
        on_protocol_color_updated=app.on_protocol_color_updated,
        on_protocol_brightness_updated=app.on_protocol_brightness_updated,
    )
    # Variable: proto.log_provider stores the referenced link.recent_log value.
    proto.log_provider = link.recent_log
    # Expression: Calls app.attach_network() for its side effects.
    app.attach_network(link, proto)
    # Expression: Calls link.ping() for its side effects.
    link.ping()
    # Expression: Calls app.run() for its side effects.
    app.run()


# Logic: Branches when __name__ == "__main__" so the correct firmware path runs.
if __name__ == "__main__":
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Expression: Calls main() for its side effects.
        main()
    # Error handling: Runs this recovery branch when the protected operation fails.
    except KeyboardInterrupt:
        # Expression: Calls clear() for its side effects.
        clear()
        # Expression: Calls show() for its side effects.
        show()
        # Expression: Calls print() for its side effects.
        print("stopped.")
