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

import gc
import time

gc.collect()

import board
from board import clear, show
gc.collect()

from rina_protocol import RinaProtocol, VERSION
gc.collect()

import saved_faces_370
gc.collect()
from buttons import ButtonBank, BTN_BRIGHT_DN, BTN_BRIGHT_UP
gc.collect()

from config import *
from app_state import AppState, BatteryState
from settings_store import load_settings, save_settings
from battery_monitor import BatteryMonitor
from esp32s3_network import ESP32S3Network
from webui_runtime import WebUIRuntime
gc.collect()

from color_module import ColorModule
from face_module import FaceModule
from scroll_module import ScrollModule
from wifi_module import WiFiModule
from gpio_module import GPIOModule
from home_module import HomeModule
from battery_module import BatteryModule
from unity_module import UnityModule
gc.collect()

FIRMWARE_BANNER = (
    "RinaChanBoard ESP32-S3 370LED modular 1.8.0 "
    "color_module-authority brightness-sync AP+protocol+RNT2 battery"
)


class LinaBoardApp:
    __slots__ = (
        "state", "battery", "buttons", "battery_monitor", "network_poll",
        "proto", "link", "button_face_active", "web_runtime",
        "color_module", "face_module", "scroll_module", "wifi_module",
        "gpio_module", "home_module", "battery_module", "unity_module",
    )

    def __init__(self):
        self.state = AppState()
        self.battery = BatteryState()
        self.buttons = ButtonBank()
        self.battery_monitor = BatteryMonitor()
        self.network_poll = None
        self.proto = None
        self.link = None
        self.button_face_active = False
        self.web_runtime = WebUIRuntime(self)

        # Feature modules receive this facade and communicate via callbacks
        # rather than importing one another directly.
        self.color_module = ColorModule(self)
        self.face_module = FaceModule(self)
        self.scroll_module = ScrollModule(self)
        self.wifi_module = WiFiModule(self)
        self.gpio_module = GPIOModule(self)
        self.home_module = HomeModule(self)
        self.battery_module = BatteryModule(self)
        self.unity_module = UnityModule(self)

    # ------------------------------------------------------------------
    # Persistence shared by all modules
    # ------------------------------------------------------------------
    def save_settings(self):
        save_settings(self.state, self.battery)

    # ------------------------------------------------------------------
    # Color module facade  (global color + brightness authority)
    # ------------------------------------------------------------------
    def get_color(self):
        return self.color_module.get_color()

    def get_dimmed_color(self):
        return self.color_module.get_dimmed_color()

    # Backward-compat aliases used by webui_runtime and any legacy caller.
    def _current_home_color(self):
        return self.color_module.get_color()

    def _dimmed_home_color(self, color):
        return self.color_module.get_dimmed_color()

    def apply_brightness(self):
        return self.color_module.apply_brightness()

    def sync_protocol_brightness_from_buttons(self):
        return self.color_module.sync_protocol_brightness_from_buttons()

    def set_brightness(self, pct, save=True, sync_protocol=True):
        return self.color_module.set_brightness(pct, save=save, sync_protocol=sync_protocol)

    def on_protocol_color_updated(self, color):
        return self.color_module.on_protocol_color_updated(color)

    def on_protocol_brightness_updated(self, bright):
        return self.color_module.on_protocol_brightness_updated(bright)

    # ------------------------------------------------------------------
    # Face module facade
    # ------------------------------------------------------------------
    def draw_current_face(self):
        return self.face_module.draw_current_face()

    def render_current_visual(self, force=False):
        return self.face_module.render_current_visual(force=force)

    def cycle_face(self, delta):
        return self.face_module.cycle_face(delta)

    def select_saved_face(self, index, redraw=True):
        return self.face_module.select_saved_face(index, redraw=redraw)

    def on_saved_faces_changed(self, selected_index=None, redraw=False):
        return self.face_module.on_saved_faces_changed(selected_index=selected_index, redraw=redraw)

    # ------------------------------------------------------------------
    # Home / mode module facade
    # ------------------------------------------------------------------
    def start_edge_flash(self, edge):
        return self.home_module.start_edge_flash(edge)

    def edge_flash_factor(self, elapsed_ms):
        return self.home_module.edge_flash_factor(elapsed_ms)

    def overlay_edge_flash(self):
        return self.home_module.overlay_edge_flash()

    def render_flash_overlay_base(self):
        return self.home_module.render_flash_overlay_base()

    def render_flash_overlay_with_edge(self):
        return self.home_module.render_flash_overlay_with_edge()

    def start_or_extend_flash(self, kind=None, value=None):
        return self.home_module.start_or_extend_flash(kind=kind, value=value)

    def end_flash_if_expired(self):
        return self.home_module.end_flash_if_expired()

    def cancel_flash_and_redraw(self):
        return self.home_module.cancel_flash_and_redraw()

    def check_special_demo_combo(self):
        return self.home_module.check_special_demo_combo()

    def adjust_interval(self, delta):
        return self.home_module.adjust_interval(delta)

    def adjust_brightness(self, delta):
        return self.home_module.adjust_brightness(delta)

    def reset_brightness(self):
        return self.home_module.reset_brightness()

    def force_m_mode(self, source="network", persist=True):
        return self.home_module.force_m_mode(source=source, persist=persist)

    def set_manual_control_mode(self, enabled=True, redraw=False, source=""):
        return self.home_module.set_manual_control_mode(enabled=enabled, redraw=redraw, source=source)

    def enter_manual_control_from_button(self, gp=None):
        return self.home_module.enter_manual_control_from_button(gp=gp)

    def exit_manual_control_from_network(self, source="network"):
        return self.home_module.exit_manual_control_from_network(source=source)

    def manual_control_status_json(self):
        return self.home_module.manual_control_status_json()

    def toggle_auto(self):
        return self.home_module.toggle_auto()

    # ------------------------------------------------------------------
    # Battery module facade
    # ------------------------------------------------------------------
    def stop_battery_display(self):
        return self.battery_module.stop_battery_display()

    def service_battery_sampling(self, force_sample=False):
        return self.battery_module.service_battery_sampling(force_sample=force_sample)

    def is_charging(self, charge_v=None, previous=None):
        return self.battery_module.is_charging(charge_v=charge_v, previous=previous)

    def show_battery_percent_short(self):
        return self.battery_module.show_battery_percent_short()

    def refresh_battery_overlay_cache(self, force=False):
        return self.battery_module.refresh_battery_overlay_cache(force=force)

    def update_battery_display_phase(self):
        return self.battery_module.update_battery_display_phase()

    def service_battery_overlay(self):
        return self.battery_module.service_battery_overlay()

    def render_battery_overlay(self, refresh_phase=True, refresh_cache=True, log_status=True):
        return self.battery_module.render_battery_overlay(refresh_phase=refresh_phase, refresh_cache=refresh_cache, log_status=log_status)

    def start_b6_press(self):
        return self.battery_module.start_b6_press()

    def check_b6_hold(self):
        return self.battery_module.check_b6_hold()

    def check_b6_release(self, prev_b6_down):
        return self.battery_module.check_b6_release(prev_b6_down)

    def battery_status_json(self):
        return self.battery_module.battery_status_json()

    # ------------------------------------------------------------------
    # Scroll module facade
    # ------------------------------------------------------------------
    def start_ip_display(self):
        return self.scroll_module.start_ip_display()

    def service_ip_display(self):
        return self.scroll_module.service_ip_display()

    def check_ip_combo(self):
        return self.scroll_module.check_ip_combo()

    # ------------------------------------------------------------------
    # GPIO module facade
    # ------------------------------------------------------------------
    def handle_press(self, gp):
        return self.gpio_module.handle_press(gp)

    def check_b3_release(self, prev_b3_down):
        return self.gpio_module.check_b3_release(prev_b3_down)

    # ------------------------------------------------------------------
    # Unity / WebUI runtime facade
    # ------------------------------------------------------------------
    def handle_webui_runtime_command(self, command):
        return self.unity_module.handle_webui_runtime_command(command)

    def stop_webui_runtime(self, redraw=True):
        return self.unity_module.stop_webui_runtime(redraw=redraw)

    # ------------------------------------------------------------------
    # Wi-Fi / protocol facade
    # ------------------------------------------------------------------
    def attach_network(self, link, proto):
        return self.wifi_module.attach_network(link, proto)

    def service_network(self):
        return self.wifi_module.service_network()

    def on_network_control(self):
        return self.wifi_module.on_network_control()

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------
    def print_startup_info(self):
        print(FIRMWARE_BANNER)
        print("Firmware version:", VERSION)
        print("linaboard: starting")
        print("  module layout       = main + protocol router + feature modules")
        print("  color authority     = color_module (color + brightness for all modes)")
        print("  protocol layer      = rina_protocol.py with callback bridge")
        print("  battery display     = battery_module.py")
        print("  default face interval=", DEFAULT_INTERVAL_S, "s")
        print("  default brightness  =", DEFAULT_BRIGHTNESS, "%")
        print("  button GPIOs        =", self.buttons.gpios())
        print("  B3+B6 combo         = consumed (no action)")
        print("  B2+B6 scroll IP/SSID= enabled (uses global display color)")
        print("  saved custom faces  =", saved_faces_370.count(), "faces; B1/B2 and A/M cycle this list")
        print("  webui runtime       = firmware-side scroll text + Unity timeline playback")
        print("  face manager store  = ESP32-S3 firmware source of truth; WebUI pulls/syncs list")
        print("  manual control mode = buttons enter; network/WebUI exits")

    def initialize(self):
        self.print_startup_info()
        load_settings(self.state, self.battery)
        print("  network             = ESP32-S3 native Wi-Fi + HTTP + UDP")
        self.apply_brightness()
        self.draw_current_face()
        self.service_battery_sampling(force_sample=True)

    def run(self):
        self.initialize()

        now = time.ticks_ms()
        next_auto_ms = time.ticks_add(now, int(self.state.interval_s * 1000))
        self.state.battery_next_log_ms = now
        self.battery_monitor.update_calibration(self.battery, self.state, self.save_settings, force=True)

        prev_b3_down = False
        prev_b6_down = False

        while True:
            self.service_network()
            combo_active = self.check_special_demo_combo()
            combo_active = self.check_ip_combo() or combo_active

            for gp in self.buttons.poll():
                self.handle_press(gp)
                next_auto_ms = time.ticks_add(time.ticks_ms(), int(self.state.interval_s * 1000))

            combo_active = self.check_special_demo_combo() or combo_active
            combo_active = self.check_ip_combo() or combo_active

            self.check_b6_hold()
            self.service_battery_overlay()
            self.service_ip_display()
            self.web_runtime.service()

            if (self.state.brightness_reset_combo_latched and
                    not self.buttons.is_down(BTN_BRIGHT_DN) and
                    not self.buttons.is_down(BTN_BRIGHT_UP)):
                self.state.brightness_reset_combo_latched = False

            prev_b3_down = self.check_b3_release(prev_b3_down)
            prev_b6_down = self.check_b6_release(prev_b6_down)

            if not self.state.battery_display_active and not self.state.ip_display_active:
                self.end_flash_if_expired()

            if self.state.flash_active and self.state.edge_flash_active:
                self.render_flash_overlay_with_edge()
            elif self.state.edge_flash_active and not self.state.flash_active:
                self.state.edge_flash_active = False

            self.service_battery_sampling()
            self.battery_monitor.update_calibration(self.battery, self.state, self.save_settings)

            if (self.state.auto and not self.web_runtime.active() and
                    not self.state.flash_active and not self.state.battery_display_active and
                    not self.state.ip_display_active):
                now = time.ticks_ms()
                if time.ticks_diff(now, next_auto_ms) >= 0:
                    self.state.face_idx = (self.state.face_idx + 1) % max(1, saved_faces_370.count())
                    self.draw_current_face()
                    next_auto_ms = time.ticks_add(now, int(self.state.interval_s * 1000))

            if (self.web_runtime.active() or self.state.flash_active or
                    self.state.battery_display_active or self.state.ip_display_active or combo_active):
                next_auto_ms = time.ticks_add(time.ticks_ms(), int(self.state.interval_s * 1000))

            time.sleep(POLL_PERIOD_MS / 1000.0)


# ---------------------------------------------------------------------------
# Boot entry point.
# ---------------------------------------------------------------------------
def main():
    print("ESP32-S3 native: Wi-Fi + HTTP + UDP + LED in one firmware")
    print("LED:", board.hardware_summary())
    app = LinaBoardApp()
    link = ESP32S3Network(log_limit=160)
    link.start()
    proto = RinaProtocol(app=app)
    proto.set_sender(lambda ip, port, data, link_id=0: link.send_udp(data, ip, port, link_id))
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
    proto.log_provider = link.recent_log
    app.attach_network(link, proto)
    link.ping()
    app.run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        clear()
        show()
        print("stopped.")
