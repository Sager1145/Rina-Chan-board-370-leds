# ---------------------------------------------------------------------------
# rina_protocol.py
#
# Full RinaChanBoard-main protocol compatibility layer for ESP32-S3 native firmware.
#
# Supports both protocols that exist in RinaChanBoard-main:
#   1) Documented binary UDP protocol used by the firmware design notes.
#   2) Textual UDP protocol used by the WeChat mini-program pages.
#
# Rendering target: Rina-Chan-board-370-leds 22x18 physical matrix, using the
# original RinaChanBoard-main 16x18 logical face centered on the 370-LED board.
# ---------------------------------------------------------------------------

# Import: Loads time so this module can use that dependency.
import time

# Import: Loads board so this module can use that dependency.
import board
# Import: Loads saved_faces_370 so this module can use that dependency.
import saved_faces_370
# Import: Loads emoji_db so this module can use that dependency.
import emoji_db
# Import: Loads display_num so this module can use that dependency.
import display_num
# Import: Loads INTERVAL_STEP_S, BRIGHTNESS_STEP, BATTERY_DISPLAY_CYCLE_MS from config so this module can use that dependency.
from config import INTERVAL_STEP_S, BRIGHTNESS_STEP, BATTERY_DISPLAY_CYCLE_MS
# Variable: VERSION stores the configured text value.
VERSION = "1.7.4-rnt-command-only"

# Variable: LOCAL_UDP_PORT stores the configured literal value.
LOCAL_UDP_PORT = 1234
# Variable: REMOTE_UDP_PORT stores the configured literal value.
REMOTE_UDP_PORT = 4321
# Variable: HTTP_PSEUDO_IP stores the configured text value.
HTTP_PSEUDO_IP = "127.0.0.1"
# Variable: HTTP_PSEUDO_PORT stores the configured literal value.
HTTP_PSEUDO_PORT = 0xF0F0

# Packet lengths from RinaChanBoard-main/include/udpsocket.h
# Variable: FACE_FULL_LEN stores the configured literal value.
FACE_FULL_LEN = 36
# Variable: FACE_TEXT_LITE_LEN stores the configured literal value.
FACE_TEXT_LITE_LEN = 16
# Variable: FACE_LITE_LEN stores the configured literal value.
FACE_LITE_LEN = 4
# Variable: COLOR_LEN stores the configured literal value.
COLOR_LEN = 3
# Variable: REQUEST_LEN stores the configured literal value.
REQUEST_LEN = 2
# Variable: BRIGHT_LEN stores the configured literal value.
BRIGHT_LEN = 1
# Variable: TEXT_CENTER_ALIGN_OFFSET_ROWS stores the configured literal value.
TEXT_CENTER_ALIGN_OFFSET_ROWS = 4

# Request IDs from RinaChanBoard-main/include/udpsocket.h
# Variable: REQUEST_FACE stores the configured literal value.
REQUEST_FACE = 0x1001
# Variable: REQUEST_COLOR stores the configured literal value.
REQUEST_COLOR = 0x1002
# Variable: REQUEST_BRIGHT stores the configured literal value.
REQUEST_BRIGHT = 0x1003
# Variable: REQUEST_VERSION stores the configured literal value.
REQUEST_VERSION = 0x1004
# Variable: REQUEST_BATTERY stores the configured literal value.
REQUEST_BATTERY = 0x1005

# Extension: not part of upstream RinaChanBoard-main.  It is useful because in
# older refactors used a separate no-AT ESP bridge; ESP32-S3 native keeps this request as a network-log/debug hook.
# Variable: REQUEST_ESP_LOG stores the configured literal value.
REQUEST_ESP_LOG = 0x10FE

# Variable: DEFAULT_COLOR stores the collection of values used later in this module.
DEFAULT_COLOR = (249, 113, 212)  # upstream default #f971d4
# Variable: DEFAULT_BRIGHT stores the configured literal value.
DEFAULT_BRIGHT = 16              # upstream default FastLED brightness

# LED startup status faces are not used in this build.

# Variable: _HEX_CHARS stores the configured text value.
_HEX_CHARS = "0123456789abcdefABCDEF"

# Upstream code accidentally rejects the highest valid generated part index
# because it checks `index >= MAX_*_COUNT`.  For a "full functions" build we
# use the generated database completely.  Set this True only when bug-for-bug
# reproduction of the old guard is required.
# Variable: STRICT_ORIGINAL_LITE_INDEX_GUARD stores the enabled/disabled flag value.
STRICT_ORIGINAL_LITE_INDEX_GUARD = False


# Function: Defines _empty_face() to handle empty face behavior.
def _empty_face():
    # Return: Sends the expression [[0 for _ in range(board.SRC_COLS)] for _ in range(board.SRC_ROWS)] back to the caller.
    return [[0 for _ in range(board.SRC_COLS)] for _ in range(board.SRC_ROWS)]


# Variable: PHYSICAL_BITS stores the result returned by sum().
PHYSICAL_BITS = sum(board.ROW_LENGTHS)
# Variable: PHYSICAL_HEX_LEN stores the calculated expression (PHYSICAL_BITS + 3) // 4.
PHYSICAL_HEX_LEN = (PHYSICAL_BITS + 3) // 4

# Variable: _NIBBLE_BITS stores the collection of values used later in this module.
_NIBBLE_BITS = (
    "0000", "0001", "0010", "0011",
    "0100", "0101", "0110", "0111",
    "1000", "1001", "1010", "1011",
    "1100", "1101", "1110", "1111",
)


# Function: Defines _empty_physical() to handle empty physical behavior.
def _empty_physical():
    # Return: Sends the expression [[0 for _ in range(board.COLS)] for _ in range(board.ROWS)] back to the caller.
    return [[0 for _ in range(board.COLS)] for _ in range(board.ROWS)]


# Function: Defines _legacy_to_physical(face) to handle legacy to physical behavior.
def _legacy_to_physical(face):
    # Variable: physical stores the result returned by _empty_physical().
    physical = _empty_physical()
    # Loop: Iterates row over range(board.SRC_ROWS) so each item can be processed.
    for row in range(board.SRC_ROWS):
        # Loop: Iterates col over range(board.SRC_COLS) so each item can be processed.
        for col in range(board.SRC_COLS):
            # Logic: Branches when face[row][col] so the correct firmware path runs.
            if face[row][col]:
                # Variable: y stores the calculated expression row + board.SRC_TO_DST_ROW_OFFSET.
                y = row + board.SRC_TO_DST_ROW_OFFSET
                # Variable: x stores the calculated expression col + board.SRC_TO_DST_COL_OFFSET.
                x = col + board.SRC_TO_DST_COL_OFFSET
                # Logic: Branches when 0 <= y < board.ROWS and 0 <= x < board.COLS so the correct firmware path runs.
                if 0 <= y < board.ROWS and 0 <= x < board.COLS:
                    # Logic: Branches when board.logical_to_led_index(x, y) is not None so the correct firmware path runs.
                    if board.logical_to_led_index(x, y) is not None:
                        # Variable: physical[...][...] stores the configured literal value.
                        physical[y][x] = 1
    # Return: Sends the current physical value back to the caller.
    return physical


# Function: Defines _is_hex_string(s, length) to handle is hex string behavior.
def _is_hex_string(s, length=None):
    # Logic: Branches when length is not None and len(s) != length so the correct firmware path runs.
    if length is not None and len(s) != length:
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
    # Logic: Branches when not s so the correct firmware path runs.
    if not s:
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
    # Loop: Iterates c over s so each item can be processed.
    for c in s:
        # Logic: Branches when c not in _HEX_CHARS so the correct firmware path runs.
        if c not in _HEX_CHARS:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
    # Return: Sends the enabled/disabled flag value back to the caller.
    return True


# Function: Defines _hex_to_bytes(s) to handle hex to bytes behavior.
def _hex_to_bytes(s):
    # Return: Sends the result returned by bytes() back to the caller.
    return bytes(int(s[i:i + 2], 16) for i in range(0, len(s), 2))


# Function: Defines _json_escape(value) to handle json escape behavior.
def _json_escape(value):
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: text stores the result returned by str().
        text = str(value)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: text stores the result returned by repr().
        text = repr(value)
    # Variable: text stores the result returned by text.replace.replace().
    text = text.replace('\\', '\\\\').replace('"', '\\"')
    # Variable: text stores the result returned by text.replace.replace.replace().
    text = text.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
    # Return: Sends the current text value back to the caller.
    return text


# Function: Defines _sleep_ms(ms) to handle sleep ms behavior.
def _sleep_ms(ms):
    # Module: Documents the purpose of this scope.
    """Boot-animation sleep helper with board/time fallback."""
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Logic: Branches when hasattr(board, "sleep_ms") so the correct firmware path runs.
        if hasattr(board, "sleep_ms"):
            # Expression: Calls board.sleep_ms() for its side effects.
            board.sleep_ms(ms)
            # Return: Sends control back to the caller.
            return
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception as exc:
        # Expression: Calls print() for its side effects.
        print("board.sleep_ms failed:", exc)
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Import: Loads _time so this module can use that dependency.
        import time as _time
        # Logic: Branches when hasattr(_time, "sleep_ms") so the correct firmware path runs.
        if hasattr(_time, "sleep_ms"):
            # Expression: Calls _time.sleep_ms() for its side effects.
            _time.sleep_ms(int(ms))
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Expression: Calls _time.sleep() for its side effects.
            _time.sleep(int(ms) / 1000.0)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception as exc:
        # Expression: Calls print() for its side effects.
        print("sleep_ms failed:", exc)


# Class: Defines RinaProtocol as the state and behavior container for Rina Protocol.
class RinaProtocol:
    # Function: Defines __init__(self, sender, log_provider, app) to handle init behavior.
    def __init__(self, sender=None, log_provider=None, app=None):
        # Variable: self.face stores the result returned by _empty_face().
        self.face = _empty_face()
        # Variable: self.physical stores the result returned by _legacy_to_physical().
        self.physical = _legacy_to_physical(self.face)
        # Variable: self.display_mode stores the configured text value.
        self.display_mode = "legacy"
        # Variable: self.color stores the current DEFAULT_COLOR value.
        self.color = DEFAULT_COLOR
        # Variable: self.bright stores the current DEFAULT_BRIGHT value.
        self.bright = DEFAULT_BRIGHT
        # Variable: self.sender stores the current sender value.
        self.sender = sender
        # Variable: self.log_provider stores the current log_provider value.
        self.log_provider = log_provider
        # Variable: self.app stores the current app value.
        self.app = app
        # Variable: self.callbacks stores the lookup table used by this module.
        self.callbacks = {}

    # ------------------------------------------------------------------
    # Reply helpers
    # ------------------------------------------------------------------
    # Function: Defines _reply_port(self, remote_ip, remote_port) to handle reply port behavior.
    def _reply_port(self, remote_ip, remote_port):
        # Normal RinaChanBoard UDP callbacks always go to port 4321.
        # ESP HTTP proxy uses a private loopback pseudo endpoint; reply to that
        # pseudo port so ESP can capture the response and return it to browser.
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: rport stores the result returned by int().
            rport = int(remote_port or 0)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: rport stores the configured literal value.
            rport = 0
        # Logic: Branches when remote_ip == HTTP_PSEUDO_IP and rport == HTTP_PSEUDO_PORT so the correct firmware path runs.
        if remote_ip == HTTP_PSEUDO_IP and rport == HTTP_PSEUDO_PORT:
            # Return: Sends the current HTTP_PSEUDO_PORT value back to the caller.
            return HTTP_PSEUDO_PORT
        # Return: Sends the current REMOTE_UDP_PORT value back to the caller.
        return REMOTE_UDP_PORT

    # Function: Defines reply(self, remote_ip, remote_port, data, link_id) to handle reply behavior.
    def reply(self, remote_ip, remote_port, data, link_id=0):
        # Expression: Calls self.send() for its side effects.
        self.send(remote_ip, self._reply_port(remote_ip, remote_port), data, link_id)

    # ------------------------------------------------------------------
    # Rendering / state helpers
    # ------------------------------------------------------------------
    # Function: Defines _notify_external_control(self) to handle notify external control behavior.
    def _notify_external_control(self):
        # Variable: cb stores the result returned by self._get_callback().
        cb = self._get_callback("network_control")
        # Logic: Branches when cb is not None so the correct firmware path runs.
        if cb is not None:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls cb() for its side effects.
                cb()
                # Return: Sends control back to the caller.
                return
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("callback network-control hook failed:", exc)
        # Logic: Branches when self.app is not None and hasattr(self.app, "on_network_control") so the correct firmware path runs.
        if self.app is not None and hasattr(self.app, "on_network_control"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.app.on_network_control() for its side effects.
                self.app.on_network_control()
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("app network-control hook failed:", exc)

    # Function: Defines _button_sim_network_takeover(self, source, stop_runtime, force_m) to handle button sim network takeover behavior.
    def _button_sim_network_takeover(self, source="webui button sim", stop_runtime=True, force_m=True):
        # Variable: app stores the referenced self.app value.
        app = self.app
        # Logic: Branches when app is None so the correct firmware path runs.
        if app is None:
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when hasattr(app, "exit_manual_control_from_network") so the correct firmware path runs.
        if hasattr(app, "exit_manual_control_from_network"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls app.exit_manual_control_from_network() for its side effects.
                app.exit_manual_control_from_network(source)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("buttonSim manual-exit failed:", exc)
        # Logic: Branches when stop_runtime and hasattr(app, "stop_webui_runtime") so the correct firmware path runs.
        if stop_runtime and hasattr(app, "stop_webui_runtime"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls app.stop_webui_runtime() for its side effects.
                app.stop_webui_runtime(redraw=False)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("buttonSim runtime-stop failed:", exc)
        # Logic: Branches when force_m and hasattr(app, "force_m_mode") so the correct firmware path runs.
        if force_m and hasattr(app, "force_m_mode"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls app.force_m_mode() for its side effects.
                app.force_m_mode(source, persist=True)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("buttonSim M mode failed:", exc)

    # Function: Defines _handle_button_sim(self, action) to handle handle button sim behavior.
    def _handle_button_sim(self, action):
        # Virtual GPIO button actions for the WebUI.  These intentionally use
        # network ownership (exit_manual_control_from_network) instead of the
        # physical-button ownership path, so a WebUI button press remains a WebUI
        # control action while matching the visible GPIO button effect.
        # Variable: app stores the referenced self.app value.
        app = self.app
        # Logic: Branches when app is None so the correct firmware path runs.
        if app is None:
            # Error handling: Raises this exception so invalid state is reported immediately.
            raise ValueError("no app")
        # Variable: action stores the result returned by str.strip.lower().
        action = str(action or "").strip().lower()

        # Logic: Branches when action == "prevface" so the correct firmware path runs.
        if action == "prevface":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim prevface")
            # Variable: app.state.face_idx stores the calculated expression (app.state.face_idx - 1) % max(1, saved_faces_370.count()).
            app.state.face_idx = (app.state.face_idx - 1) % max(1, saved_faces_370.count())
            # Expression: Calls app.stop_battery_display() for its side effects.
            app.stop_battery_display()
            # Expression: Calls app.cancel_flash_and_redraw() for its side effects.
            app.cancel_flash_and_redraw()
            # Return: Sends the calculated expression "face=" + str(app.state.face_idx) back to the caller.
            return "face=" + str(app.state.face_idx)

        # Logic: Branches when action == "nextface" so the correct firmware path runs.
        if action == "nextface":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim nextface")
            # Variable: app.state.face_idx stores the calculated expression (app.state.face_idx + 1) % max(1, saved_faces_370.count()).
            app.state.face_idx = (app.state.face_idx + 1) % max(1, saved_faces_370.count())
            # Expression: Calls app.stop_battery_display() for its side effects.
            app.stop_battery_display()
            # Expression: Calls app.cancel_flash_and_redraw() for its side effects.
            app.cancel_flash_and_redraw()
            # Return: Sends the calculated expression "face=" + str(app.state.face_idx) back to the caller.
            return "face=" + str(app.state.face_idx)

        # Logic: Branches when action == "toggleauto" so the correct firmware path runs.
        if action == "toggleauto":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim toggleauto", force_m=False)
            # Variable: app.state.auto stores the calculated unary expression not app.state.auto.
            app.state.auto = not app.state.auto
            # Expression: Calls app.save_settings() for its side effects.
            app.save_settings()
            # Expression: Calls app.stop_battery_display() for its side effects.
            app.stop_battery_display()
            # Expression: Calls display_num.render_mode() for its side effects.
            display_num.render_mode(app.state.auto)
            # Expression: Calls app.start_or_extend_flash() for its side effects.
            app.start_or_extend_flash("mode", app.state.auto)
            # Return: Sends the calculated expression "auto=" + ("A" if app.state.auto else "M") back to the caller.
            return "auto=" + ("A" if app.state.auto else "M")

        # Logic: Branches when action == "intervalup" so the correct firmware path runs.
        if action == "intervalup":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim intervalup")
            # Expression: Calls app.adjust_interval() for its side effects.
            app.adjust_interval(+INTERVAL_STEP_S)
            # Return: Sends the calculated expression "interval=" + str(app.state.interval_s) back to the caller.
            return "interval=" + str(app.state.interval_s)

        # Logic: Branches when action == "intervaldown" so the correct firmware path runs.
        if action == "intervaldown":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim intervaldown")
            # Expression: Calls app.adjust_interval() for its side effects.
            app.adjust_interval(-INTERVAL_STEP_S)
            # Return: Sends the calculated expression "interval=" + str(app.state.interval_s) back to the caller.
            return "interval=" + str(app.state.interval_s)

        # Logic: Branches when action == "brightup" so the correct firmware path runs.
        if action == "brightup":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim brightup")
            # Expression: Calls app.adjust_brightness() for its side effects.
            app.adjust_brightness(+BRIGHTNESS_STEP)
            # Return: Sends the calculated expression "brightness=" + str(app.state.brightness) back to the caller.
            return "brightness=" + str(app.state.brightness)

        # Logic: Branches when action == "brightdown" so the correct firmware path runs.
        if action == "brightdown":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim brightdown")
            # Expression: Calls app.adjust_brightness() for its side effects.
            app.adjust_brightness(-BRIGHTNESS_STEP)
            # Return: Sends the calculated expression "brightness=" + str(app.state.brightness) back to the caller.
            return "brightness=" + str(app.state.brightness)

        # Logic: Branches when action == "brightreset" so the correct firmware path runs.
        if action == "brightreset":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim brightreset")
            # Expression: Calls app.reset_brightness() for its side effects.
            app.reset_brightness()
            # Return: Sends the calculated expression "brightness=" + str(app.state.brightness) back to the caller.
            return "brightness=" + str(app.state.brightness)

        # Logic: Branches when action == "batteryshort" so the correct firmware path runs.
        if action == "batteryshort":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim batteryshort")
            # Expression: Calls app.show_battery_percent_short() for its side effects.
            app.show_battery_percent_short()
            # Return: Sends the configured text value back to the caller.
            return "battery_short"

        # Logic: Branches when action == "batterydetail" so the correct firmware path runs.
        if action == "batterydetail":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim batterydetail")
            # Logic: Branches when app.state.battery_display_active so the correct firmware path runs.
            if app.state.battery_display_active:
                # Expression: Calls app.stop_battery_display() for its side effects.
                app.stop_battery_display()
                # Return: Sends the configured text value back to the caller.
                return "battery_off"
            # Variable: app.state.battery_display_active stores the enabled/disabled flag value.
            app.state.battery_display_active = True
            # Variable: app.state.battery_display_single_shot stores the enabled/disabled flag value.
            app.state.battery_display_single_shot = False
            # Variable: app.state.flash_active stores the enabled/disabled flag value.
            app.state.flash_active = False
            # Variable: app.state.edge_flash_active stores the enabled/disabled flag value.
            app.state.edge_flash_active = False
            # Variable: app.state.battery_next_refresh_ms stores the configured literal value.
            app.state.battery_next_refresh_ms = 0
            # Variable: app.state.battery_visual_next_refresh_ms stores the configured literal value.
            app.state.battery_visual_next_refresh_ms = 0
            # Expression: Calls app.refresh_battery_overlay_cache() for its side effects.
            app.refresh_battery_overlay_cache(force=True)
            # Variable: now stores the result returned by time.ticks_ms().
            now = time.ticks_ms()
            # Variable: app.state.battery_display_toggle_started_ms stores the current now value.
            app.state.battery_display_toggle_started_ms = now
            # Variable: app.state.battery_display_phase_index stores the configured literal value.
            app.state.battery_display_phase_index = 0
            # Variable: charging stores the referenced app.state.battery_display_cached_is_charging value.
            charging = app.state.battery_display_cached_is_charging
            # Variable: app.state.battery_display_phase_count stores the conditional expression 4 if charging else 3.
            app.state.battery_display_phase_count = 4 if charging else 3
            # Variable: app.state.battery_display_next_phase_ms stores the result returned by time.ticks_add().
            app.state.battery_display_next_phase_ms = time.ticks_add(now, BATTERY_DISPLAY_CYCLE_MS)
            # Expression: Calls app.render_battery_overlay() for its side effects.
            app.render_battery_overlay(refresh_phase=False, refresh_cache=False)
            # Return: Sends the configured text value back to the caller.
            return "battery_on"

        # Logic: Branches when action == "showip" so the correct firmware path runs.
        if action == "showip":
            # Expression: Calls self._button_sim_network_takeover() for its side effects.
            self._button_sim_network_takeover("buttonSim showip")
            # Logic: Branches when app.state.ip_display_active so the correct firmware path runs.
            if app.state.ip_display_active:
                # Variable: app.state.ip_display_active stores the enabled/disabled flag value.
                app.state.ip_display_active = False
                # Expression: Calls app.draw_current_face() for its side effects.
                app.draw_current_face()
                # Return: Sends the configured text value back to the caller.
                return "ip_off"
            # Expression: Calls app.start_ip_display() for its side effects.
            app.start_ip_display()
            # Return: Sends the configured text value back to the caller.
            return "ip_on"

        # Error handling: Raises this exception so invalid state is reported immediately.
        raise ValueError("unknown action: " + action)

    # Function: Defines _bright_color(self) to handle bright color behavior.
    def _bright_color(self):
        # Variable: r, g, b stores the referenced self.color value.
        r, g, b = self.color
        # Variable: bright stores the result returned by max().
        bright = max(0, min(255, int(self.bright)))
        # Return: Sends the collection of values used later in this module back to the caller.
        return ((int(r) * bright) // 255,
                (int(g) * bright) // 255,
                (int(b) * bright) // 255)

    # Function: Defines _draw_physical_matrix(self, write) to handle draw physical matrix behavior.
    def _draw_physical_matrix(self, write=True):
        # Expression: Calls board.draw_pixel_grid() for its side effects.
        board.draw_pixel_grid(self.physical, {1: self._bright_color(), 0: (0, 0, 0)}, write)

    # Function: Defines redraw(self, notify) to handle redraw behavior.
    def redraw(self, notify=True):
        # Logic: Branches when notify so the correct firmware path runs.
        if notify:
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
        # Logic: Branches when self.display_mode == "physical" so the correct firmware path runs.
        if self.display_mode == "physical":
            # Expression: Calls self._draw_physical_matrix() for its side effects.
            self._draw_physical_matrix(True)
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: self.physical stores the result returned by _legacy_to_physical().
            self.physical = _legacy_to_physical(self.face)
            # Expression: Calls board.draw_face_matrix() for its side effects.
            board.draw_face_matrix(self.face, self.color, self.bright, True)

    # Function: Defines set_sender(self, sender) to handle set sender behavior.
    def set_sender(self, sender):
        # Variable: self.sender stores the current sender value.
        self.sender = sender

    # Function: Defines set_callbacks(self, **callbacks) to handle set callbacks behavior.
    def set_callbacks(self, **callbacks):
        # Optional callback bridge used by the modular main loop.  rina_protocol
        # remains the packet router; feature ownership stays in the app modules.
        # Variable: self.callbacks stores the combined condition callbacks or {}.
        self.callbacks = callbacks or {}
        # Return: Sends the current self value back to the caller.
        return self

    # Function: Defines _get_callback(self, name) to handle get callback behavior.
    def _get_callback(self, name):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Return: Sends the result returned by self.callbacks.get() back to the caller.
            return self.callbacks.get(name, None)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Return: Sends the empty sentinel value back to the caller.
            return None

    # Function: Defines _call_callback(self, name, *args, **kwargs) to handle call callback behavior.
    def _call_callback(self, name, *args, **kwargs):
        # Variable: cb stores the result returned by self._get_callback().
        cb = self._get_callback(name)
        # Logic: Branches when cb is None so the correct firmware path runs.
        if cb is None:
            # Return: Sends the empty sentinel value back to the caller.
            return None
        # Return: Sends the result returned by cb() back to the caller.
        return cb(*args, **kwargs)

    # Function: Defines show_hex_face(self, hex_string, delay_ms) to handle show hex face behavior.
    def show_hex_face(self, hex_string, delay_ms=0):
        # Variable: self.face stores the result returned by self.decode_hex_string().
        self.face = self.decode_hex_string(hex_string)
        # Variable: self.display_mode stores the configured text value.
        self.display_mode = "legacy"
        # Expression: Calls self.redraw() for its side effects.
        self.redraw()
        # Logic: Branches when delay_ms so the correct firmware path runs.
        if delay_ms:
            # Expression: Calls _sleep_ms() for its side effects.
            _sleep_ms(delay_ms)

    # Function: Defines boot_animation(self) to handle boot animation behavior.
    def boot_animation(self):
        # LED startup animation is intentionally disabled in v1.4.4.
        # Keep this method as a no-op for compatibility with older callers.
        # Return: Sends control back to the caller.
        return

    # Function: Defines decode_hex_string(hex_string) to handle decode hex string behavior.
    @staticmethod
    def decode_hex_string(hex_string):
        # Return: Sends the result returned by RinaProtocol.decode_face_bytes() back to the caller.
        return RinaProtocol.decode_face_bytes(_hex_to_bytes(hex_string), 0)

    # Function: Defines decode_face_bytes(data, offset_rows) to handle decode face bytes behavior.
    @staticmethod
    def decode_face_bytes(data, offset_rows=0):
        # Matches original decodeFaceHex(): MSB-first, row-major, 18 columns.
        # Variable: face stores the result returned by _empty_face().
        face = _empty_face()
        # Variable: bit_index stores the configured literal value.
        bit_index = 0
        # Loop: Iterates byte over data so each item can be processed.
        for byte in data:
            # Loop: Iterates bit over range(7, -1, -1) so each item can be processed.
            for bit in range(7, -1, -1):
                # Variable: row stores the calculated expression offset_rows + (bit_index // board.SRC_COLS).
                row = offset_rows + (bit_index // board.SRC_COLS)
                # Variable: col stores the calculated expression bit_index % board.SRC_COLS.
                col = bit_index % board.SRC_COLS
                # Logic: Branches when row >= board.SRC_ROWS so the correct firmware path runs.
                if row >= board.SRC_ROWS:
                    # Return: Sends the current face value back to the caller.
                    return face
                # Variable: face[...][...] stores the conditional expression 1 if (byte & (1 << bit)) else 0.
                face[row][col] = 1 if (byte & (1 << bit)) else 0
                # Variable: Updates bit_index in place using the configured literal value.
                bit_index += 1
        # Return: Sends the current face value back to the caller.
        return face

    # Function: Defines encode_face_bytes(self) to handle encode face bytes behavior.
    def encode_face_bytes(self):
        # Line-equivalent to original getFaceHex(): MSB-first, row-major.
        # Important parity detail: the original 16x18 board has invalid padding
        # columns at col 0 and col 17. getFaceHex() increments bitIndex for those
        # cells but never sets the bit because led_map[row][col] == -1.  Therefore
        # requestFace must always return 0 in those padding columns even if a prior
        # Face_Full packet contained 1 bits there.
        # Variable: out stores the result returned by bytearray().
        out = bytearray(FACE_FULL_LEN)
        # Variable: bit_index stores the configured literal value.
        bit_index = 0
        # Variable: invalid_cols stores the result returned by getattr().
        invalid_cols = getattr(board, "SRC_INVALID_COLS", ())
        # Loop: Iterates row over range(board.SRC_ROWS) so each item can be processed.
        for row in range(board.SRC_ROWS):
            # Loop: Iterates col over range(board.SRC_COLS) so each item can be processed.
            for col in range(board.SRC_COLS):
                # Logic: Branches when col not in invalid_cols and self.face[row][col] so the correct firmware path runs.
                if col not in invalid_cols and self.face[row][col]:
                    # Variable: Updates out[...] in place using the calculated expression 1 << (7 - (bit_index % 8)).
                    out[bit_index // 8] |= 1 << (7 - (bit_index % 8))
                # Variable: Updates bit_index in place using the configured literal value.
                bit_index += 1
        # Return: Sends the result returned by bytes() back to the caller.
        return bytes(out)

    # Function: Defines encode_face_hex_text(self) to handle encode face hex text behavior.
    def encode_face_hex_text(self):
        # Return: Sends the result returned by self.encode_face_bytes.hex() back to the caller.
        return self.encode_face_bytes().hex()

    # Function: Defines encode_physical_hex_text(self) to handle encode physical hex text behavior.
    def encode_physical_hex_text(self):
        # Variable: binary stores the configured text value.
        binary = ""
        # Loop: Iterates y over range(board.ROWS) so each item can be processed.
        for y in range(board.ROWS):
            # Loop: Iterates x over range(board.COLS) so each item can be processed.
            for x in range(board.COLS):
                # Logic: Branches when board.logical_to_led_index(x, y) is not None so the correct firmware path runs.
                if board.logical_to_led_index(x, y) is not None:
                    # Variable: Updates binary in place using the conditional expression "1" if self.physical[y][x] else "0".
                    binary += "1" if self.physical[y][x] else "0"
        # Loop: Repeats while len(binary) % 4 remains true.
        while len(binary) % 4:
            # Variable: Updates binary in place using the configured text value.
            binary += "0"
        # Variable: out stores the configured text value.
        out = ""
        # Loop: Iterates i over range(0, len(binary), 4) so each item can be processed.
        for i in range(0, len(binary), 4):
            # Variable: Updates out in place using the result returned by format().
            out += "{:x}".format(int(binary[i:i + 4], 2))
        # Return: Sends the current out value back to the caller.
        return out

    # Function: Defines update_physical_face_hex(self, hex_text, notify) to handle update physical face hex behavior.
    def update_physical_face_hex(self, hex_text, notify=True):
        # Variable: hex_text stores the result returned by hex_text.strip().
        hex_text = hex_text.strip()
        # Logic: Branches when len(hex_text) != PHYSICAL_HEX_LEN or not _is_hex_string(hex_text) so the correct firmware path runs.
        if len(hex_text) != PHYSICAL_HEX_LEN or not _is_hex_string(hex_text):
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Variable: binary stores the configured text value.
        binary = ""
        # Loop: Iterates h over hex_text so each item can be processed.
        for h in hex_text:
            # Some MicroPython builds omit CPython zero-fill string helpers.
            # Use a lookup table so M370 / timeline frames work on-device.
            # Variable: Updates binary in place using the selected item _NIBBLE_BITS[int(h, 16)].
            binary += _NIBBLE_BITS[int(h, 16)]
        # Variable: physical stores the result returned by _empty_physical().
        physical = _empty_physical()
        # Variable: k stores the configured literal value.
        k = 0
        # Loop: Iterates y over range(board.ROWS) so each item can be processed.
        for y in range(board.ROWS):
            # Loop: Iterates x over range(board.COLS) so each item can be processed.
            for x in range(board.COLS):
                # Logic: Branches when board.logical_to_led_index(x, y) is None so the correct firmware path runs.
                if board.logical_to_led_index(x, y) is None:
                    # Control: Skips to the next loop iteration after this case is handled.
                    continue
                # Variable: physical[...][...] stores the conditional expression 1 if binary[k] == "1" else 0.
                physical[y][x] = 1 if binary[k] == "1" else 0
                # Variable: Updates k in place using the configured literal value.
                k += 1
        # Variable: self.physical stores the current physical value.
        self.physical = physical
        # Variable: self.display_mode stores the configured text value.
        self.display_mode = "physical"
        # Expression: Calls self.redraw() for its side effects.
        self.redraw(notify=notify)
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # Function: Defines update_full_face(self, data, offset_rows) to handle update full face behavior.
    def update_full_face(self, data, offset_rows=0):
        # Variable: self.face stores the result returned by self.decode_face_bytes().
        self.face = self.decode_face_bytes(data, offset_rows)
        # Variable: self.display_mode stores the configured text value.
        self.display_mode = "legacy"
        # Expression: Calls self.redraw() for its side effects.
        self.redraw()

    # Function: Defines update_text_lite(self, data) to handle update text lite behavior.
    def update_text_lite(self, data):
        # Expression: Calls self.update_full_face() for its side effects.
        self.update_full_face(data, TEXT_CENTER_ALIGN_OFFSET_ROWS)

    # Function: Defines _bitpacked_get(rows, y, x, width) to handle bitpacked get behavior.
    @staticmethod
    def _bitpacked_get(rows, y, x, width):
        # Return: Sends the conditional expression 1 if (rows[y] & (1 << (width - 1 - x))) else 0 back to the caller.
        return 1 if (rows[y] & (1 << (width - 1 - x))) else 0

    # Function: Defines _draw_part(face, bitmap, start_row, start_col, height, width, xflip) to handle draw part behavior.
    @staticmethod
    def _draw_part(face, bitmap, start_row, start_col, height, width, xflip=False):
        # Loop: Iterates y over range(height) so each item can be processed.
        for y in range(height):
            # Loop: Iterates x over range(width) so each item can be processed.
            for x in range(width):
                # Variable: sx stores the conditional expression width - 1 - x if xflip else x.
                sx = width - 1 - x if xflip else x
                # Variable: row stores the calculated expression start_row + y.
                row = start_row + y
                # Variable: col stores the calculated expression start_col + x.
                col = start_col + x
                # Logic: Branches when 0 <= row < board.SRC_ROWS and 0 <= col < board.SRC_COLS so the correct firmware path runs.
                if 0 <= row < board.SRC_ROWS and 0 <= col < board.SRC_COLS:
                    # Variable: face[...][...] stores the result returned by RinaProtocol._bitpacked_get().
                    face[row][col] = RinaProtocol._bitpacked_get(bitmap, y, sx, width)

    # Function: Defines _valid_lite_index(index, max_index) to handle valid lite index behavior.
    @staticmethod
    def _valid_lite_index(index, max_index):
        # Logic: Branches when STRICT_ORIGINAL_LITE_INDEX_GUARD so the correct firmware path runs.
        if STRICT_ORIGINAL_LITE_INDEX_GUARD:
            # Return: Sends the comparison result 0 <= index < max_index back to the caller.
            return 0 <= index < max_index
        # Return: Sends the comparison result 0 <= index <= max_index back to the caller.
        return 0 <= index <= max_index

    # Function: Defines update_lite_face(self, leye, reye, mouth, cheek) to handle update lite face behavior.
    def update_lite_face(self, leye, reye, mouth, cheek):
        # FACE_LITE payload contains 4 one-byte database indices:
        # left eye, right eye, mouth, cheek.
        # Logic: Branches when not self._valid_lite_index(leye, emoji_db.MAX_LEYE_COUNT) or not self._valid_lite_ind... so the correct firmware path runs.
        if (not self._valid_lite_index(leye, emoji_db.MAX_LEYE_COUNT) or
                not self._valid_lite_index(reye, emoji_db.MAX_REYE_COUNT) or
                not self._valid_lite_index(mouth, emoji_db.MAX_MOUTH_COUNT) or
                not self._valid_lite_index(cheek, emoji_db.MAX_CHEEK_COUNT)):
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False

        # Variable: face stores the result returned by _empty_face().
        face = _empty_face()
        # Expression: Calls self._draw_part() for its side effects.
        self._draw_part(face, emoji_db.LEYE[leye], emoji_db.L_EYE_START_ROW,
                        emoji_db.L_EYE_START_COL, emoji_db.EYE_SIZE, emoji_db.EYE_SIZE)
        # Expression: Calls self._draw_part() for its side effects.
        self._draw_part(face, emoji_db.REYE[reye], emoji_db.R_EYE_START_ROW,
                        emoji_db.R_EYE_START_COL, emoji_db.EYE_SIZE, emoji_db.EYE_SIZE)
        # Expression: Calls self._draw_part() for its side effects.
        self._draw_part(face, emoji_db.MOUTH[mouth], emoji_db.MOUTH_START_ROW,
                        emoji_db.MOUTH_START_COL, emoji_db.MOUTH_SIZE, emoji_db.MOUTH_SIZE)
        # Expression: Calls self._draw_part() for its side effects.
        self._draw_part(face, emoji_db.CHEEK[cheek], emoji_db.R_CHEEK_START_ROW,
                        emoji_db.R_CHEEK_START_COL, emoji_db.CHEEK_SIZE, emoji_db.CHEEK_SIZE)
        # Expression: Calls self._draw_part() for its side effects.
        self._draw_part(face, emoji_db.CHEEK[cheek], emoji_db.L_CHEEK_START_ROW,
                        emoji_db.L_CHEEK_START_COL, emoji_db.CHEEK_SIZE, emoji_db.CHEEK_SIZE,
                        xflip=True)
        # Variable: self.face stores the current face value.
        self.face = face
        # Variable: self.display_mode stores the configured text value.
        self.display_mode = "legacy"
        # Expression: Calls self.redraw() for its side effects.
        self.redraw()
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # Function: Defines update_color(self, data) to handle update color behavior.
    def update_color(self, data):
        # Variable: self.color stores the collection of values used later in this module.
        self.color = (data[0] & 0xFF, data[1] & 0xFF, data[2] & 0xFF)
        # Variable: cb stores the result returned by self._get_callback().
        cb = self._get_callback("on_protocol_color_updated")
        # Logic: Branches when cb is not None so the correct firmware path runs.
        if cb is not None:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls cb() for its side effects.
                cb(self.color)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("callback color-sync hook failed:", exc)
        # Logic: Branches when self.app is not None and hasattr(self.app, "on_protocol_color_updated") so the correct firmware path runs.
        elif self.app is not None and hasattr(self.app, "on_protocol_color_updated"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.app.on_protocol_color_updated() for its side effects.
                self.app.on_protocol_color_updated(self.color)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("app color-sync hook failed:", exc)
        # Expression: Calls self.redraw() for its side effects.
        self.redraw()

    # Function: Defines update_brightness(self, bright) to handle update brightness behavior.
    def update_brightness(self, bright):
        # Variable: self.bright stores the calculated expression bright & 0xFF.
        self.bright = bright & 0xFF
        # Variable: cb stores the result returned by self._get_callback().
        cb = self._get_callback("on_protocol_brightness_updated")
        # Logic: Branches when cb is not None so the correct firmware path runs.
        if cb is not None:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls cb() for its side effects.
                cb(self.bright)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("callback brightness-sync hook failed:", exc)
        # Logic: Branches when self.app is not None and hasattr(self.app, "on_protocol_brightness_updated") so the correct firmware path runs.
        elif self.app is not None and hasattr(self.app, "on_protocol_brightness_updated"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.app.on_protocol_brightness_updated() for its side effects.
                self.app.on_protocol_brightness_updated(self.bright)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("app brightness-sync hook failed:", exc)
        # Expression: Calls self.redraw() for its side effects.
        self.redraw()

    # Function: Defines set_physical_from_ascii_bitmap(self, bitmap) to handle set physical from ascii bitmap behavior.
    def set_physical_from_ascii_bitmap(self, bitmap):
        # Mirror the current button/default face into protocol state so
        # requestState/requestFace370 reflect what is actually on the 370 LEDs.
        # Variable: physical stores the collection of values used later in this module.
        physical = []
        # Loop: Iterates y over range(board.ROWS) so each item can be processed.
        for y in range(board.ROWS):
            # Variable: row_bits stores the collection of values used later in this module.
            row_bits = []
            # Variable: src stores the conditional expression bitmap[y] if y < len(bitmap) else "".
            src = bitmap[y] if y < len(bitmap) else ""
            # Loop: Iterates x over range(board.COLS) so each item can be processed.
            for x in range(board.COLS):
                # Logic: Branches when board.logical_to_led_index(x, y) is None so the correct firmware path runs.
                if board.logical_to_led_index(x, y) is None:
                    # Expression: Calls row_bits.append() for its side effects.
                    row_bits.append(0)
                # Logic: Runs this fallback branch when the earlier condition did not match.
                else:
                    # Variable: ch stores the conditional expression src[x] if x < len(src) else " ".
                    ch = src[x] if x < len(src) else " "
                    # Expression: Calls row_bits.append() for its side effects.
                    row_bits.append(1 if ch in ("#", "+") else 0)
            # Expression: Calls physical.append() for its side effects.
            physical.append(row_bits)
        # Variable: self.physical stores the current physical value.
        self.physical = physical
        # Variable: self.display_mode stores the configured text value.
        self.display_mode = "physical"

    # ------------------------------------------------------------------
    # Packet handler
    # ------------------------------------------------------------------
    # Function: Defines handle_packet(self, data, remote_ip, remote_port, link_id) to handle handle packet behavior.
    def handle_packet(self, data, remote_ip=None, remote_port=None, link_id=0):
        # Logic: Branches when not data so the correct firmware path runs.
        if not data:
            # Return: Sends control back to the caller.
            return

        # The WeChat mini-program in RinaChanBoard-main sends text such as
        # 72-char face hex, #rrggbb, B016, requestFace/requestColor/requestBright.
        # Logic: Branches when self._handle_text_packet(data, remote_ip, remote_port, link_id) so the correct firmware path runs.
        if self._handle_text_packet(data, remote_ip, remote_port, link_id):
            # Return: Sends control back to the caller.
            return

        # Variable: n stores the result returned by len().
        n = len(data)
        # Logic: Branches when n == FACE_FULL_LEN so the correct firmware path runs.
        if n == FACE_FULL_LEN:
            # Expression: Calls self.update_full_face() for its side effects.
            self.update_full_face(data, 0)
        # Logic: Branches when n == FACE_TEXT_LITE_LEN so the correct firmware path runs.
        elif n == FACE_TEXT_LITE_LEN:
            # Expression: Calls self.update_text_lite() for its side effects.
            self.update_text_lite(data)
        # Logic: Branches when n == FACE_LITE_LEN so the correct firmware path runs.
        elif n == FACE_LITE_LEN:
            # Variable: ok stores the result returned by self.update_lite_face().
            ok = self.update_lite_face(data[0], data[1], data[2], data[3])
            # Logic: Branches when not ok so the correct firmware path runs.
            if not ok:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"Command Error!", link_id)
        # Logic: Branches when n == COLOR_LEN so the correct firmware path runs.
        elif n == COLOR_LEN:
            # Expression: Calls self.update_color() for its side effects.
            self.update_color(data)
        # Logic: Branches when n == REQUEST_LEN so the correct firmware path runs.
        elif n == REQUEST_LEN:
            # Expression: Calls self.handle_request() for its side effects.
            self.handle_request((data[0] << 8) | data[1], remote_ip, remote_port, link_id)
        # Logic: Branches when n == BRIGHT_LEN so the correct firmware path runs.
        elif n == BRIGHT_LEN:
            # Expression: Calls self.update_brightness() for its side effects.
            self.update_brightness(data[0])
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, b"Command Error!", link_id)

    # Function: Defines handle_request(self, request, remote_ip, remote_port, link_id) to handle handle request behavior.
    def handle_request(self, request, remote_ip, remote_port, link_id):
        # Binary documented callbacks.  Replies always use REMOTE_UDP_PORT=4321,
        # matching upstream sendCallBack(... remoteUDPPort).
        # Logic: Branches when request == REQUEST_FACE so the correct firmware path runs.
        if request == REQUEST_FACE:
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, self.encode_face_bytes(), link_id)
        # Logic: Branches when request == REQUEST_COLOR so the correct firmware path runs.
        elif request == REQUEST_COLOR:
            # Upstream writes a 3-byte little-endian integer constructed as
            # (B << 16 | G << 8 | R), resulting in bytes [R, G, B].
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, bytes(self.color), link_id)
        # Logic: Branches when request == REQUEST_BRIGHT so the correct firmware path runs.
        elif request == REQUEST_BRIGHT:
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, bytes((self.bright,)), link_id)
        # Logic: Branches when request == REQUEST_VERSION so the correct firmware path runs.
        elif request == REQUEST_VERSION:
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, VERSION.encode(), link_id)
        # Logic: Branches when request == REQUEST_BATTERY so the correct firmware path runs.
        elif request == REQUEST_BATTERY:
            # Original RinaChanBoardHardware defines requestBattery as TODO and
            # does not send a callback. Keep binary 0x1005 bug-for-bug parity.
            # The browser/WeChat text command requestBattery still returns JSON
            # for the 370-LED battery/charging extension.
            # Return: Sends control back to the caller.
            return
        # Logic: Branches when request == REQUEST_ESP_LOG so the correct firmware path runs.
        elif request == REQUEST_ESP_LOG:
            # Logic: Branches when self.log_provider so the correct firmware path runs.
            if self.log_provider:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, self.log_provider().encode(), link_id)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"No ESP log", link_id)
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, b"Command Error!", link_id)

    # Function: Defines send(self, remote_ip, remote_port, data, link_id) to handle send behavior.
    def send(self, remote_ip, remote_port, data, link_id=0):
        # Logic: Branches when self.sender so the correct firmware path runs.
        if self.sender:
            # Expression: Calls self.sender() for its side effects.
            self.sender(remote_ip, remote_port, data, link_id)

    # ------------------------------------------------------------------
    # RinaChanBoardOperationCenter.wechatapp text compatibility
    # ------------------------------------------------------------------
    # Function: Defines _handle_text_packet(self, data, remote_ip, remote_port, link_id) to handle handle text packet behavior.
    def _handle_text_packet(self, data, remote_ip, remote_port, link_id):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: s stores the result returned by data.decode.strip().
            s = data.decode().strip()
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Logic: Branches when not s so the correct firmware path runs.
        if not s:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False

        # Variable: low stores the result returned by s.lower().
        low = s.lower()

        # Manual control authority commands.  Physical buttons enter manual
        # mode; normal network/WebUI drawing commands exit it.
        # Web button simulation: virtual GPIO button actions.
        # buttonSim|<action> triggers the same visible action as the physical
        # buttons while keeping ownership on the WebUI/network side.
        # Logic: Branches when low.startswith("buttonsim|") so the correct firmware path runs.
        if low.startswith("buttonsim|"):
            # Variable: action stores the conditional expression low.split("|", 1)[1].strip() if "|" in low else "".
            action = low.split("|", 1)[1].strip() if "|" in low else ""
            # Logic: Branches when self.app is None so the correct firmware path runs.
            if self.app is None:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"ERR:no app", link_id)
                # Return: Sends the enabled/disabled flag value back to the caller.
                return True
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: result stores the result returned by self._handle_button_sim().
                result = self._handle_button_sim(action)
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, ("OK:" + str(result)).encode(), link_id)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, ("ERR:" + str(exc)).encode(), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Logic: Branches when low == "requestmanualmode" or low == "requestcontrolmode" so the correct firmware path runs.
        if low == "requestmanualmode" or low == "requestcontrolmode":
            # Logic: Branches when self.app is not None and hasattr(self.app, "manual_control_status_json") so the correct firmware path runs.
            if self.app is not None and hasattr(self.app, "manual_control_status_json"):
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, self.app.manual_control_status_json().encode(), link_id)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"{\"manual_control_mode\":false}", link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("manualmode") or low.startswith("manualcontrolmode") so the correct firmware path runs.
        if low.startswith("manualmode") or low.startswith("manualcontrolmode"):
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 1)
            # Variable: val stores the conditional expression parts[1].strip().lower() if len(parts) == 2 else "1".
            val = parts[1].strip().lower() if len(parts) == 2 else "1"
            # Logic: Branches when self.app is None or not hasattr(self.app, "set_manual_control_mode") so the correct firmware path runs.
            if self.app is None or not hasattr(self.app, "set_manual_control_mode"):
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"ERR:no app", link_id)
                # Return: Sends the enabled/disabled flag value back to the caller.
                return True
            # Variable: current stores the result returned by bool().
            current = bool(getattr(getattr(self.app, "state", None), "manual_control_mode", False))
            # Logic: Branches when val in ("toggle", "t") so the correct firmware path runs.
            if val in ("toggle", "t"):
                # Variable: target stores the calculated unary expression not current.
                target = not current
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Variable: target stores the calculated unary expression not (val in ("0", "false", "off", "exit", "web", "network")).
                target = not (val in ("0", "false", "off", "exit", "web", "network"))
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: enabled stores the result returned by self.app.set_manual_control_mode().
                enabled = self.app.set_manual_control_mode(target, redraw=target, source="webui manual button")
                # Logic: Branches when not target and hasattr(self.app, "on_network_control") so the correct firmware path runs.
                if not target and hasattr(self.app, "on_network_control"):
                    # Exiting the WebUI manual-control lock is still a WebUI
                    # control action, so force the saved-face A/M state back
                    # to M even when it does not draw a face.
                    # Expression: Calls self.app.on_network_control() for its side effects.
                    self.app.on_network_control()
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, ("manualMode|" + ("1" if enabled else "0")).encode(), link_id)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, ("ERR:" + str(exc)).encode(), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Firmware-side WebUI runtime commands.  These move browser-timer
        # playback (scroll text and Unity timeline frames) into the ESP32-S3 loop.
        # Logic: Branches when low == "runtimestatus" or low == "runtimestop" or low.startswith("runtimestop|") or l... so the correct firmware path runs.
        if (low == "runtimestatus" or low == "runtimestop" or low.startswith("runtimestop|") or
                low == "scrolltextstop370" or low.startswith("scrolltextstop370|") or
                low.startswith("scrolltext370|") or
                low.startswith("timeline370loadrnt|") or low.startswith("timeline370asset|") or
                low.startswith("timeline370begin|") or low.startswith("timeline370chunk|") or
                low == "timeline370play" or low.startswith("timeline370play|") or
                low.startswith("timeline370preview|") or
                low == "timeline370stop" or low.startswith("timeline370stop|") or
                low == "timeline370clear" or low.startswith("timeline370clear|")):
            # Logic: Branches when low != "runtimestatus" and self.app is not None and hasattr(self.app, "force_m_mode") so the correct firmware path runs.
            if low != "runtimestatus" and self.app is not None and hasattr(self.app, "force_m_mode"):
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Expression: Calls self.app.force_m_mode() for its side effects.
                    self.app.force_m_mode("webui runtime command", persist=True)
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception as exc:
                    # Expression: Calls print() for its side effects.
                    print("M/A mode reset failed:", exc)
            # Logic: Branches when self.app is not None and hasattr(self.app, "handle_webui_runtime_command") so the correct firmware path runs.
            if self.app is not None and hasattr(self.app, "handle_webui_runtime_command"):
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Variable: reply stores the result returned by self.app.handle_webui_runtime_command().
                    reply = self.app.handle_webui_runtime_command(s)
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception as exc:
                    # Expression: Calls print() for its side effects.
                    print("webui runtime command failed:", exc)
                    # Variable: reply stores the calculated expression "ERR:" + str(exc).
                    reply = "ERR:" + str(exc)
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, str(reply).encode(), link_id)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"ERR:no runtime", link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Color upload from pages/index/index.js: message '#'+color.
        # Logic: Branches when s.startswith("#") and _is_hex_string(s[1:], 6) so the correct firmware path runs.
        if s.startswith("#") and _is_hex_string(s[1:], 6):
            # Expression: Calls self.update_color() for its side effects.
            self.update_color(bytes((int(s[1:3], 16), int(s[3:5], 16), int(s[5:7], 16))))
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Helpful extra: allow rrggbb without # from test tools.
        # Logic: Branches when _is_hex_string(s, 6) so the correct firmware path runs.
        if _is_hex_string(s, 6):
            # Expression: Calls self.update_color() for its side effects.
            self.update_color(bytes((int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))))
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Brightness upload from pages/index/index.js: B000..B255.
        # Logic: Branches when (s.startswith("B") or s.startswith("b")) and len(s) == 4 and s[1:].isdigit() so the correct firmware path runs.
        if (s.startswith("B") or s.startswith("b")) and len(s) == 4 and s[1:].isdigit():
            # Variable: val stores the result returned by int().
            val = int(s[1:])
            # Logic: Branches when 0 <= val <= 255 so the correct firmware path runs.
            if 0 <= val <= 255:
                # Expression: Calls self.update_brightness() for its side effects.
                self.update_brightness(val)
                # Return: Sends the enabled/disabled flag value back to the caller.
                return True
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, b"Command Error!", link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Text request names from the WeChat mini-program.  These return text
        # because the app reads messageList[-1].text.
        # Logic: Branches when low == "requestface" so the correct firmware path runs.
        if low == "requestface":
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, self.encode_face_hex_text().encode(), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low == "requestface370" so the correct firmware path runs.
        if low == "requestface370":
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, ("M370:" + self.encode_physical_hex_text()).encode(), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Logic: Branches when low == "requestsavedfaces370" so the correct firmware path runs.
        if low == "requestsavedfaces370":
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, saved_faces_370.json_list().encode(), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("selectface370|") so the correct firmware path runs.
        if low.startswith("selectface370|"):
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 1)
            # Logic: Branches when self.app is not None and hasattr(self.app, "select_saved_face") and len(parts) == 2 so the correct firmware path runs.
            if self.app is not None and hasattr(self.app, "select_saved_face") and len(parts) == 2:
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Variable: face stores the result returned by self.app.select_saved_face().
                    face = self.app.select_saved_face(parts[1], redraw=True)
                    # Expression: Calls self.reply() for its side effects.
                    self.reply(remote_ip, remote_port, ("OK|" + saved_faces_370.json.dumps(face)).encode(), link_id)
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception as exc:
                    # Expression: Calls self.reply() for its side effects.
                    self.reply(remote_ip, remote_port, ("ERR:" + str(exc)).encode(), link_id)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"ERR:no app")
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("deleteface370index|") so the correct firmware path runs.
        if low.startswith("deleteface370index|"):
            # manual exit for deleteface370index|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 1)
            # Variable: ok stores the result returned by saved_faces_370.delete_by_index().
            ok = saved_faces_370.delete_by_index(parts[1] if len(parts) == 2 else 0)
            # Logic: Branches when ok and self.app is not None and hasattr(self.app, "on_saved_faces_changed") so the correct firmware path runs.
            if ok and self.app is not None and hasattr(self.app, "on_saved_faces_changed"):
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Expression: Calls self.app.on_saved_faces_changed() for its side effects.
                    self.app.on_saved_faces_changed(redraw=False)
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception as exc:
                    # Expression: Calls print() for its side effects.
                    print("saved faces delete notify failed:", exc)
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"LOCKED_OR_NOT_FOUND"), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("moveface370|") so the correct firmware path runs.
        if low.startswith("moveface370|"):
            # manual exit for moveface370|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 2)
            # Variable: ok stores the combined condition len(parts) == 3 and saved_faces_370.move_index(parts[1], parts[2]).
            ok = len(parts) == 3 and saved_faces_370.move_index(parts[1], parts[2])
            # Logic: Branches when ok and self.app is not None and hasattr(self.app, "on_saved_faces_changed") so the correct firmware path runs.
            if ok and self.app is not None and hasattr(self.app, "on_saved_faces_changed"):
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Expression: Calls self.app.on_saved_faces_changed() for its side effects.
                    self.app.on_saved_faces_changed(redraw=False)
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception as exc:
                    # Expression: Calls print() for its side effects.
                    print("saved faces move notify failed:", exc)
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"Command Error!"), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("lockface370|") so the correct firmware path runs.
        if low.startswith("lockface370|"):
            # manual exit for lockface370|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 2)
            # Variable: item stores the conditional expression saved_faces_370.set_lock_by_index(parts[1], parts[2]) if len(parts) == 3 else None.
            item = saved_faces_370.set_lock_by_index(parts[1], parts[2]) if len(parts) == 3 else None
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, (b"OK" if item else b"Command Error!"), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("typeface370|") so the correct firmware path runs.
        if low.startswith("typeface370|"):
            # manual exit for typeface370|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 2)
            # Variable: item stores the conditional expression saved_faces_370.set_type_by_index(parts[1], parts[2]) if len(parts) == 3 else None.
            item = saved_faces_370.set_type_by_index(parts[1], parts[2]) if len(parts) == 3 else None
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, (b"OK" if item else b"Command Error!"), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("renameface370index|") so the correct firmware path runs.
        if low.startswith("renameface370index|"):
            # manual exit for renameface370index|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 2)
            # Variable: item stores the conditional expression saved_faces_370.rename_by_index(parts[1], parts[2]) if len(parts) == 3 else None.
            item = saved_faces_370.rename_by_index(parts[1], parts[2]) if len(parts) == 3 else None
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, (b"OK" if item else b"Command Error!"), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("updateface370|") so the correct firmware path runs.
        if low.startswith("updateface370|"):
            # manual exit for updateface370|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Format: updateFace370|index|name|type|locked
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 4)
            # Variable: item stores the empty sentinel value.
            item = None
            # Logic: Branches when len(parts) >= 5 so the correct firmware path runs.
            if len(parts) >= 5:
                # Variable: item stores the result returned by saved_faces_370.update_by_index().
                item = saved_faces_370.update_by_index(parts[1], name=parts[2], typ=parts[3], locked=parts[4])
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, (b"OK" if item else b"Command Error!"), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("savefaces370json|") so the correct firmware path runs.
        if low.startswith("savefaces370json|"):
            # manual exit for savefaces370json|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Full ordered face-list sync from Web UI v1.5.3.
            # Keeps hardware button cycling order identical to browser order.
            # Variable: payload stores the conditional expression s.split("|", 1)[1] if "|" in s else "".
            payload = s.split("|", 1)[1] if "|" in s else ""
            # Variable: ok stores the result returned by saved_faces_370.save_json().
            ok = saved_faces_370.save_json(payload)
            # Logic: Branches when ok and self.app is not None and hasattr(self.app, "on_saved_faces_changed") so the correct firmware path runs.
            if ok and self.app is not None and hasattr(self.app, "on_saved_faces_changed"):
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Expression: Calls self.app.on_saved_faces_changed() for its side effects.
                    self.app.on_saved_faces_changed(redraw=False)
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception as exc:
                    # Expression: Calls print() for its side effects.
                    print("saved faces change notify failed:", exc)
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"Command Error!"), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("saveface370|") so the correct firmware path runs.
        if low.startswith("saveface370|"):
            # manual exit for saveface370|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Format: saveFace370|name|M370:<93 hex>[|custom|0/1]
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|")
            # Logic: Branches when len(parts) >= 3 so the correct firmware path runs.
            if len(parts) >= 3:
                # Variable: kind stores the conditional expression parts[3] if len(parts) >= 4 else "custom".
                kind = parts[3] if len(parts) >= 4 else "custom"
                # Variable: locked stores the conditional expression parts[4] if len(parts) >= 5 else False.
                locked = parts[4] if len(parts) >= 5 else False
                # Expression: Calls saved_faces_370.add_or_update() for its side effects.
                saved_faces_370.add_or_update(parts[1], parts[2], kind, locked)
                # Logic: Branches when self.app is not None and hasattr(self.app, "on_saved_faces_changed") so the correct firmware path runs.
                if self.app is not None and hasattr(self.app, "on_saved_faces_changed"):
                    # Error handling: Attempts the protected operation so failures can be handled safely.
                    try:
                        # Expression: Calls self.app.on_saved_faces_changed() for its side effects.
                        self.app.on_saved_faces_changed(redraw=False)
                    # Error handling: Runs this recovery branch when the protected operation fails.
                    except Exception as exc:
                        # Expression: Calls print() for its side effects.
                        print("saved face notify failed:", exc)
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"OK", link_id)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"Command Error!", link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("deleteface370|") so the correct firmware path runs.
        if low.startswith("deleteface370|"):
            # manual exit for deleteface370|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 1)
            # Variable: ok stores the enabled/disabled flag value.
            ok = False
            # Logic: Branches when len(parts) == 2 so the correct firmware path runs.
            if len(parts) == 2:
                # Variable: ok stores the result returned by saved_faces_370.delete_by_name().
                ok = saved_faces_370.delete_by_name(parts[1])
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"NOT_FOUND"), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low.startswith("renameface370|") so the correct firmware path runs.
        if low.startswith("renameface370|"):
            # manual exit for renameface370|
            # Expression: Calls self._notify_external_control() for its side effects.
            self._notify_external_control()
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 2)
            # Variable: ok stores the enabled/disabled flag value.
            ok = False
            # Logic: Branches when len(parts) == 3 so the correct firmware path runs.
            if len(parts) == 3:
                # Variable: ok stores the result returned by saved_faces_370.rename_by_name().
                ok = saved_faces_370.rename_by_name(parts[1], parts[2])
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"NOT_FOUND"), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low == "requestcolor" so the correct firmware path runs.
        if low == "requestcolor":
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port,
                       ("#{:02x}{:02x}{:02x}".format(*self.color)).encode(), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low == "requestbright" so the correct firmware path runs.
        if low == "requestbright":
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, str(self.bright).encode(), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low == "requestversion" so the correct firmware path runs.
        if low == "requestversion":
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, VERSION.encode(), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low == "requestbattery" so the correct firmware path runs.
        if low == "requestbattery":
            # Logic: Branches when self.app is not None and hasattr(self.app, "battery_status_json") so the correct firmware path runs.
            if self.app is not None and hasattr(self.app, "battery_status_json"):
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, self.app.battery_status_json().encode(), link_id)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"{}", link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low == "requeststate" so the correct firmware path runs.
        if low == "requeststate":
            # Variable: battery stores the configured text value.
            battery = "{}"
            # Logic: Branches when self.app is not None and hasattr(self.app, "battery_status_json") so the correct firmware path runs.
            if self.app is not None and hasattr(self.app, "battery_status_json"):
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Variable: battery stores the result returned by self.app.battery_status_json().
                    battery = self.app.battery_status_json()
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception:
                    # Variable: battery stores the configured text value.
                    battery = "{}"
            # Variable: payload stores the calculated expression "{" "\"version\":\"" + _json_escape(VERSION) + "\"," "\"color\":\"#{:02x}{:02x}{:02x}....
            payload = ("{"
                       "\"version\":\"" + _json_escape(VERSION) + "\","
                       "\"color\":\"#{:02x}{:02x}{:02x}\",".format(*self.color) +
                       "\"bright\":" + str(int(self.bright)) + ","
                       "\"manual_control_mode\":" + ("true" if (self.app is not None and bool(getattr(getattr(self.app, "state", None), "manual_control_mode", False))) else "false") + ","
                       "\"control_mode\":\"" + ("manual" if (self.app is not None and bool(getattr(getattr(self.app, "state", None), "manual_control_mode", False))) else "web") + "\","
                       "\"face\":\"" + self.encode_face_hex_text() + "\","
                       "\"face370\":\"M370:" + self.encode_physical_hex_text() + "\","
                       "\"battery\":" + battery +
                       "}")
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, payload.encode(), link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when low in ("requestesplog", "requestespstatus") so the correct firmware path runs.
        if low in ("requestesplog", "requestespstatus"):
            # Logic: Branches when self.log_provider so the correct firmware path runs.
            if self.log_provider:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, self.log_provider().encode(), link_id)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"No ESP log", link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # flyAkari/RinaChanBoard legacy ESP8266_Arduino protocol:
        # - "RinaBoardUdpTest" replies "RinaboardIsOn".
        # - "leye,reye,mouth,cheek," sets a 4-part face.
        # The original repository listens on UDP and parses comma-separated
        # decimal indices using atoi().  This ESP32-S3 refactor accepts the same
        # message format through UDP and through the built-in web UI.
        # Logic: Branches when s == "RinaBoardUdpTest" so the correct firmware path runs.
        if s == "RinaBoardUdpTest":
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, b"RinaboardIsOn", link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when "," in s so the correct firmware path runs.
        if "," in s:
            # Variable: parts stores the result returned by s.split().
            parts = s.split(",")
            # original examples end with a trailing comma, leaving an empty
            # final element.  Accept both trailing and non-trailing forms.
            # Variable: nums stores the collection of values used later in this module.
            nums = []
            # Variable: ok stores the enabled/disabled flag value.
            ok = True
            # Loop: Iterates p over parts so each item can be processed.
            for p in parts:
                # Logic: Branches when p == "" so the correct firmware path runs.
                if p == "":
                    # Control: Skips to the next loop iteration after this case is handled.
                    continue
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Expression: Calls nums.append() for its side effects.
                    nums.append(int(p))
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception:
                    # Variable: ok stores the enabled/disabled flag value.
                    ok = False
                    # Control: Stops the loop once the required condition has been met.
                    break
            # Logic: Branches when ok and len(nums) >= 4 so the correct firmware path runs.
            if ok and len(nums) >= 4:
                # Logic: Branches when not self.update_lite_face(nums[0], nums[1], nums[2], nums[3]) so the correct firmware path runs.
                if not self.update_lite_face(nums[0], nums[1], nums[2], nums[3]):
                    # Expression: Calls self.reply() for its side effects.
                    self.reply(remote_ip, remote_port, b"Command Error!", link_id)
                # Return: Sends the enabled/disabled flag value back to the caller.
                return True

        # Extension for the real Rina-Chan-board-370-leds shape:
        # "M370:" + 93 hex chars encodes only real LEDs in row-major physical order.
        # Hidden/padded cells are not included.
        # Logic: Branches when low.startswith("m370:") so the correct firmware path runs.
        if low.startswith("m370:"):
            # Variable: raw stores the result returned by strip().
            raw = s[5:].strip()
            # Logic: Branches when self.update_physical_face_hex(raw) so the correct firmware path runs.
            if self.update_physical_face_hex(raw):
                # Return: Sends the enabled/disabled flag value back to the caller.
                return True
            # Expression: Calls self.reply() for its side effects.
            self.reply(remote_ip, remote_port, b"Command Error!", link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Custom face upload from utils/face_func.js: 16*18 bits -> 72 hex chars.
        # Logic: Branches when _is_hex_string(s, 72) so the correct firmware path runs.
        if _is_hex_string(s, 72):
            # Expression: Calls self.update_full_face() for its side effects.
            self.update_full_face(_hex_to_bytes(s), 0)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Helpful extra for testing/documented protocol: 16-byte text-lite as
        # 32 hex chars and 4-byte face-lite as 8 hex chars.
        # Logic: Branches when _is_hex_string(s, 32) so the correct firmware path runs.
        if _is_hex_string(s, 32):
            # Expression: Calls self.update_text_lite() for its side effects.
            self.update_text_lite(_hex_to_bytes(s))
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Logic: Branches when _is_hex_string(s, 8) so the correct firmware path runs.
        if _is_hex_string(s, 8):
            # Variable: raw stores the result returned by _hex_to_bytes().
            raw = _hex_to_bytes(s)
            # Variable: ok stores the result returned by self.update_lite_face().
            ok = self.update_lite_face(raw[0], raw[1], raw[2], raw[3])
            # Logic: Branches when not ok so the correct firmware path runs.
            if not ok:
                # Expression: Calls self.reply() for its side effects.
                self.reply(remote_ip, remote_port, b"Command Error!", link_id)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
