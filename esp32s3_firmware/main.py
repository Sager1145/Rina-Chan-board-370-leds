# ---------------------------------------------------------------------------
# main.py
#
# Entry point for the modular RinaChanBoard ESP32-S3 370-LED controller.
#
# This file creates all modules, wires their callbacks, and runs the main
# polling loop.  All business logic lives in the individual modules:
#
#   color_module.py   — centralized color management
#   face_module.py    — expression / face display
#   scroll_module.py  — scrolling text (IP + WebUI)
#   battery_module.py — battery display overlay
#   unity_module.py   — Unity timeline playback
#   gpio_module.py    — button input & combos
#   home_module.py    — flash overlay, brightness, A/M mode
#   wifi_module.py    — WiFi network & packet routing
#
# Shared files used by multiple modules:
#   board.py, config.py, app_state.py, display_num.py,
#   settings_store.py, brightness_modes.py, buttons.py,
#   battery_monitor.py, battery_runtime.py, saved_faces_370.py,
#   emoji_db.py, rina_protocol.py
# ---------------------------------------------------------------------------

import gc
import time

gc.collect()
import board
gc.collect()

from rina_protocol import RinaProtocol, VERSION
gc.collect()

from config import POLL_PERIOD_MS
from app_state import AppState, BatteryState
from settings_store import load_settings, save_settings
gc.collect()

from color_module import ColorModule
gc.collect()
from face_module import FaceModule
gc.collect()
from scroll_module import ScrollModule
gc.collect()
from battery_module import BatteryModule
gc.collect()
from unity_module import UnityModule
gc.collect()
from gpio_module import GPIOModule
gc.collect()
from home_module import HomeModule
gc.collect()
from wifi_module import WiFiModule
gc.collect()

FIRMWARE_BANNER = "RinaChanBoard ESP32-S3 370LED modular v1.7.0"


# ---------------------------------------------------------------------------
# Module wiring — connects callbacks between modules
# ---------------------------------------------------------------------------
def wire_modules(state, battery_state, color, face, scroll, battery, unity, gpio, home, wifi, proto):
    """Connect all inter-module callbacks."""

    # -- Save settings helper --
    def _save():
        save_settings(state, battery_state)

    home.set_save_fn(_save)
    home.set_modules(face, scroll, battery, unity)

    # -- Face module --
    face.set_protocol(proto)
    face.set_on_stop_overlays(lambda: home.stop_all_overlays())

    # -- Scroll module --
    scroll.set_on_prepare(lambda: home.prepare_for_runtime())
    scroll.set_on_stop_done(lambda: face.draw_current())

    # -- Battery module --
    battery.set_on_redraw_face(lambda: face.render_current_visual(force=True))

    # -- Unity module --
    unity.set_protocol(proto)
    unity.set_on_prepare(lambda: home.prepare_for_runtime())
    unity.set_on_stop_done(lambda: face.draw_current())

    # -- Color module --
    color.on_change(lambda c: home.on_protocol_color_updated(c))

    # -- GPIO module callbacks --
    def _on_cycle_face(delta):
        scroll.stop(redraw=False)
        unity.stop(redraw=False)
        state.special_demo_mode = False
        face.cycle(delta)
        battery.stop()
        home.cancel_flash_and_redraw()

    def _on_adjust_interval(delta):
        home.adjust_interval(delta)

    def _on_adjust_brightness(delta):
        home.adjust_brightness(delta, proto)

    def _on_reset_brightness():
        home.reset_brightness(proto)

    def _on_toggle_auto():
        home.toggle_auto()

    def _on_show_battery_short():
        battery.show_short()

    def _on_show_battery_detail():
        battery.show_detail()

    def _on_stop_battery():
        battery.stop()

    def _on_show_ip():
        ip = wifi.get_ip()
        ssid = wifi.get_ssid()
        scroll.start_ip_display(ip, ssid)

    def _on_enter_manual(gp):
        src = "button" if gp is None else "button GPIO{}".format(gp)
        home.enter_manual_control(src)

    gpio.on_cycle_face = _on_cycle_face
    gpio.on_adjust_interval = _on_adjust_interval
    gpio.on_adjust_brightness = _on_adjust_brightness
    gpio.on_reset_brightness = _on_reset_brightness
    gpio.on_toggle_auto = _on_toggle_auto
    gpio.on_show_battery_short = _on_show_battery_short
    gpio.on_show_battery_detail = _on_show_battery_detail
    gpio.on_stop_battery = _on_stop_battery
    gpio.on_show_ip = _on_show_ip
    gpio.on_enter_manual = _on_enter_manual


# ---------------------------------------------------------------------------
# Application wrapper — holds all modules and the main loop
# ---------------------------------------------------------------------------
class LinaBoardApp:
    """Thin wrapper that holds module references for protocol compatibility."""

    __slots__ = (
        "state", "battery_state",
        "color", "face", "scroll", "battery", "unity", "gpio", "home", "wifi",
        "proto",
    )

    def __init__(self):
        self.state = AppState()
        self.battery_state = BatteryState()
        self.color = ColorModule()
        self.face = FaceModule(self.state)
        self.scroll = ScrollModule(self.state, self.color)
        self.battery = BatteryModule(self.state, self.battery_state)
        self.unity = UnityModule()
        self.gpio = GPIOModule(self.state)
        self.home = HomeModule(self.state, self.battery_state, self.color)
        self.wifi = WiFiModule(log_limit=160)
        self.proto = None

    # ------------------------------------------------------------------
    # Protocol-facing compatibility API
    # These methods are called by rina_protocol.py and must exist on `app`.
    # They delegate to the appropriate module.
    # ------------------------------------------------------------------
    @property
    def button_face_active(self):
        return self.face.button_face_active

    @button_face_active.setter
    def button_face_active(self, v):
        self.face.button_face_active = v

    def on_network_control(self):
        self.home.on_network_control()

    def exit_manual_control_from_network(self, source="network"):
        self.home.exit_manual_control(source)

    def force_m_mode(self, source="network", persist=True):
        self.home.force_m_mode(source, persist)

    def stop_webui_runtime(self, redraw=True):
        stopped_scroll = self.scroll.stop(redraw=False)
        stopped_unity = self.unity.stop(redraw=False)
        if (stopped_scroll or stopped_unity) and redraw:
            self.face.draw_current()
        return stopped_scroll or stopped_unity

    def handle_webui_runtime_command(self, command):
        return self._dispatch_runtime_command(command)

    def select_saved_face(self, index, redraw=True):
        self.exit_manual_control_from_network("selectFace370")
        self.stop_webui_runtime(redraw=False)
        self.state.special_demo_mode = False
        self.force_m_mode("selectFace370", persist=True)
        self.battery.stop()
        return self.face.select(index, redraw=redraw)

    def on_saved_faces_changed(self, selected_index=None, redraw=False):
        return self.face.on_faces_changed(selected_index, redraw)

    def on_protocol_color_updated(self, color_tuple):
        self.color.set(color_tuple[0], color_tuple[1], color_tuple[2])

    def on_protocol_brightness_updated(self, bright):
        self.home.on_protocol_brightness_updated(bright)

    def battery_status_json(self):
        return self.battery.status_json()

    def manual_control_status_json(self):
        return self.home.manual_control_status_json()

    def set_manual_control_mode(self, enabled, redraw=False, source=""):
        result = self.home.set_manual_control_mode(enabled, redraw, source)
        if not enabled:
            self.on_network_control()
        return result

    def draw_current_face(self):
        self.face.draw_current()

    def cancel_flash_and_redraw(self):
        self.home.cancel_flash_and_redraw()

    def stop_battery_display(self):
        self.battery.stop()

    def show_battery_percent_short(self):
        self.battery.show_short()

    def refresh_battery_overlay_cache(self, force=False):
        return self.battery._refresh_cache(force=force)

    def render_battery_overlay(self, refresh_phase=True, refresh_cache=True):
        self.battery._render(refresh_phase=refresh_phase, refresh_cache=refresh_cache)

    def start_or_extend_flash(self, kind=None, value=None):
        self.home.start_or_extend_flash(kind, value)

    def adjust_interval(self, delta):
        self.home.adjust_interval(delta)

    def adjust_brightness(self, delta):
        self.home.adjust_brightness(delta, self.proto)

    def reset_brightness(self):
        self.home.reset_brightness(self.proto)

    def start_ip_display(self):
        ip = self.wifi.get_ip()
        ssid = self.wifi.get_ssid()
        self.scroll.start_ip_display(ip, ssid)

    def save_settings(self):
        save_settings(self.state, self.battery_state)

    # ------------------------------------------------------------------
    # WebUI runtime command dispatcher
    # ------------------------------------------------------------------
    def _dispatch_runtime_command(self, command):
        s = str(command or "").strip()
        preview = s if len(s) <= 160 else (s[:160] + "...({} chars)".format(len(s)))
        print(">>> [API Command] 收到前端指令: {}".format(preview))

        try:
            return self._dispatch_impl(s)
        except Exception as exc:
            print("!!! [API Crash] 处理前端指令时发生严重错误: {}".format(exc))
            return "ERR:runtime crash {}".format(exc)

    def _dispatch_impl(self, s):
        low = s.lower()

        # --- Status ---
        if low == "runtimestatus":
            return self._runtime_status_json()

        # --- Stop all ---
        if low == "runtimestop" or low.startswith("runtimestop|"):
            self.scroll.stop(redraw=True)
            self.unity.stop(redraw=True)
            return "OK"

        # --- Scroll text ---
        if low == "scrolltextstop370" or low.startswith("scrolltextstop370|"):
            self.scroll.stop(redraw=True)
            return "OK"
        if low.startswith("scrolltext370|"):
            parts = s.split("|", 2)
            if len(parts) < 3:
                return "ERR:scrollText370 needs speed and text"
            self.unity.stop(redraw=False)
            self.scroll.start_webui_scroll(parts[2], parts[1])
            return "OK"

        # --- Timeline ---
        if low.startswith("timeline370begin|"):
            parts = s.split("|", 5)
            if len(parts) < 5:
                return "ERR:timeline370Begin needs fps,last,loop,count"
            self.scroll.stop(redraw=False)
            name = parts[5] if len(parts) >= 6 else ""
            self.unity.begin(
                parts[1], parts[2],
                str(parts[3]).strip() in ("1", "true", "on", "yes"),
                parts[4], name
            )
            return "OK"
        if low.startswith("timeline370chunk|"):
            chunk = s.split("|", 1)[1] if "|" in s else ""
            added = self.unity.add_chunk(chunk)
            return "OK:{}".format(added)
        if low == "timeline370play" or low.startswith("timeline370play|"):
            self.scroll.stop(redraw=False)
            return "OK" if self.unity.play() else "ERR:no timeline"
        if low.startswith("timeline370preview|"):
            frame = s.split("|", 1)[1] if "|" in s else "0"
            return "OK" if self.unity.preview(frame) else "ERR:no timeline"
        if low == "timeline370stop" or low.startswith("timeline370stop|"):
            self.unity.stop(redraw=True)
            return "OK"
        if low == "timeline370clear" or low.startswith("timeline370clear|"):
            self.unity.clear()
            return "OK"

        return "ERR:unknown runtime command"

    def _runtime_status_json(self):
        """Combined status of scroll + unity modules."""
        scroll_active = self.scroll.webui_active
        unity_active = self.unity.active()
        active = scroll_active or unity_active
        if scroll_active:
            mode = "scroll"
        elif unity_active:
            mode = "timeline"
        else:
            mode = "idle"
        # Unity status fields
        uj = self.unity.status_json()
        # Merge scroll info
        scroll_text = self.scroll.webui_text or ""
        scroll_text = scroll_text.replace('\\', '\\\\').replace('"', '\\"')
        return ("{"
                "\"active\":" + ("true" if active else "false") + ","
                "\"mode\":\"" + mode + "\","
                "\"scroll_text\":\"" + scroll_text + "\","
                "\"timeline_name\":\"" + (self.unity.timeline_name or "").replace('"', '\\"') + "\","
                "\"timeline_frames\":" + str(len(self.unity.timeline)) + ","
                "\"timeline_expected\":" + str(int(self.unity.timeline_expected)) + ","
                "\"timeline_last_frame\":" + str(int(self.unity.timeline_last_frame)) + ","
                "\"timeline_fps\":" + str(int(self.unity.timeline_fps)) + ","
                "\"timeline_loop\":" + ("true" if self.unity.timeline_loop else "false") + ","
                "\"timeline_playing\":" + ("true" if self.unity.timeline_playing else "false") +
                "}")

    # ------------------------------------------------------------------
    # Initialization & main loop
    # ------------------------------------------------------------------
    def print_startup_info(self):
        import saved_faces_370
        print(FIRMWARE_BANNER)
        print("Firmware version:", VERSION)
        print("linaboard: starting")
        print("  button GPIOs         =", self.gpio.gpios())
        print("  saved custom faces  =", saved_faces_370.count(), "faces")
        print("  modules: color, face, scroll, battery, unity, gpio, home, wifi")
        print("  protocol layer: rina_protocol.py (unified dispatch)")

    def initialize(self):
        self.print_startup_info()
        load_settings(self.state, self.battery_state)
        print("  network             = ESP32-S3 native Wi-Fi + HTTP + UDP")
        self.home.apply_brightness()
        self.face.draw_current()
        self.battery.service_sampling(force=True)

    def run(self):
        self.initialize()

        now = time.ticks_ms()
        next_auto_ms = time.ticks_add(now, int(self.state.interval_s * 1000))
        self.state.battery_next_log_ms = now
        self.battery.update_calibration(self.save_settings, force=True)

        while True:
            # 1. Network
            self.wifi.service()

            # 2. GPIO (buttons + combos)
            combo_active, pressed_any = self.gpio.service()
            if pressed_any:
                next_auto_ms = time.ticks_add(
                    time.ticks_ms(), int(self.state.interval_s * 1000)
                )

            # 3. Battery overlay
            self.battery.service_overlay()

            # 4. Scroll (IP + WebUI)
            self.scroll.service()

            # 5. Unity timeline
            self.unity.service()

            # 6. Home (flash expiry + edge flash)
            self.home.service()

            # 7. Battery sampling + calibration
            self.battery.service_sampling()
            self.battery.update_calibration(self.save_settings)

            # 8. Auto-cycle faces
            any_overlay = (
                self.scroll.active() or self.unity.active() or
                self.state.flash_active or self.state.battery_display_active or
                self.state.ip_display_active
            )
            if not any_overlay:
                new_auto = self.face.service_auto_cycle(next_auto_ms)
                if new_auto is not None:
                    next_auto_ms = new_auto

            if any_overlay or combo_active:
                next_auto_ms = time.ticks_add(
                    time.ticks_ms(), int(self.state.interval_s * 1000)
                )

            time.sleep(POLL_PERIOD_MS / 1000.0)


# ---------------------------------------------------------------------------
# Boot entry point
# ---------------------------------------------------------------------------
def main():
    print("ESP32-S3 native: Wi-Fi + HTTP + UDP + LED modular firmware")
    print("LED:", board.hardware_summary())

    app = LinaBoardApp()

    # Create and attach protocol
    proto = RinaProtocol(app=app)
    app.proto = proto

    # WiFi + protocol
    app.wifi.start()
    app.wifi.attach_protocol(proto)

    # Wire all module callbacks
    wire_modules(
        app.state, app.battery_state,
        app.color, app.face, app.scroll, app.battery,
        app.unity, app.gpio, app.home, app.wifi, proto,
    )

    app.wifi.ping()
    app.run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        board.clear()
        board.show()
        print("stopped.")
