import board
import saved_faces_370
import emoji_db
try:
    from config import DEFAULT_COLOR, DEFAULT_COLOR_HEX
except Exception:
    DEFAULT_COLOR_HEX = 'f971d4'
    DEFAULT_COLOR = (249, 113, 212)
VERSION = "1.6.0-esp32s3-native"
LOCAL_UDP_PORT = 1234
REMOTE_UDP_PORT = 4321
HTTP_PSEUDO_IP = "127.0.0.1"
HTTP_PSEUDO_PORT = 0xF0F0
FACE_FULL_LEN = 36
FACE_TEXT_LITE_LEN = 16
FACE_LITE_LEN = 4
COLOR_LEN = 3
REQUEST_LEN = 2
BRIGHT_LEN = 1
TEXT_CENTER_ALIGN_OFFSET_ROWS = 4
REQUEST_FACE = 0x1001
REQUEST_COLOR = 0x1002
REQUEST_BRIGHT = 0x1003
REQUEST_VERSION = 0x1004
REQUEST_BATTERY = 0x1005
REQUEST_ESP_LOG = 0x10FE
DEFAULT_BRIGHT = 16
_HEX_CHARS = "0123456789abcdefABCDEF"
STRICT_ORIGINAL_LITE_INDEX_GUARD = False
def _empty_face():
    return [[0 for _ in range(board.SRC_COLS)] for _ in range(board.SRC_ROWS)]
PHYSICAL_BITS = sum(board.ROW_LENGTHS)
PHYSICAL_HEX_LEN = (PHYSICAL_BITS + 3) // 4
_NIBBLE_BITS = (
    "0000", "0001", "0010", "0011",
    "0100", "0101", "0110", "0111",
    "1000", "1001", "1010", "1011",
    "1100", "1101", "1110", "1111",
)
def _empty_physical():
    return [[0 for _ in range(board.COLS)] for _ in range(board.ROWS)]
def _legacy_to_physical(face):
    physical = _empty_physical()
    for row in range(board.SRC_ROWS):
        for col in range(board.SRC_COLS):
            if face[row][col]:
                y = row + board.SRC_TO_DST_ROW_OFFSET
                x = col + board.SRC_TO_DST_COL_OFFSET
                if 0 <= y < board.ROWS and 0 <= x < board.COLS:
                    if board.logical_to_led_index(x, y) is not None:
                        physical[y][x] = 1
    return physical
def _is_hex_string(s, length=None):
    if length is not None and len(s) != length:
        return False
    if not s:
        return False
    for c in s:
        if c not in _HEX_CHARS:
            return False
    return True
def _hex_to_bytes(s):
    return bytes(int(s[i:i + 2], 16) for i in range(0, len(s), 2))
def _json_escape(value):
    try:
        text = str(value)
    except Exception:
        text = repr(value)
    text = text.replace('\\', '\\\\').replace('"', '\\"')
    text = text.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
    return text
def _sleep_ms(ms):
    try:
        if hasattr(board, "sleep_ms"):
            board.sleep_ms(ms)
            return
    except Exception as exc:
        print("board.sleep_ms failed:", exc)
    try:
        import time as _time
        if hasattr(_time, "sleep_ms"):
            _time.sleep_ms(int(ms))
        else:
            _time.sleep(int(ms) / 1000.0)
    except Exception as exc:
        print("sleep_ms failed:", exc)
class RinaProtocol:
    def __init__(self, sender=None, log_provider=None, app=None):
        self.face = _empty_face()
        self.physical = _legacy_to_physical(self.face)
        self.display_mode = "legacy"
        self.color = DEFAULT_COLOR
        self.bright = DEFAULT_BRIGHT
        self.sender = sender
        self.log_provider = log_provider
        self.app = app
    def _reply_port(self, remote_ip, remote_port):
        try:
            rport = int(remote_port or 0)
        except Exception:
            rport = 0
        if remote_ip == HTTP_PSEUDO_IP and rport == HTTP_PSEUDO_PORT:
            return HTTP_PSEUDO_PORT
        return REMOTE_UDP_PORT
    def reply(self, remote_ip, remote_port, data, link_id=0):
        self.send(remote_ip, self._reply_port(remote_ip, remote_port), data, link_id)
    def _notify_external_control(self):
        if self.app is not None and hasattr(self.app, "on_network_control"):
            try:
                self.app.on_network_control()
            except Exception as exc:
                print("app network-control hook failed:", exc)
    def _bright_color(self):
        r, g, b = self.color
        bright = max(0, min(255, int(self.bright)))
        return ((int(r) * bright) // 255,
                (int(g) * bright) // 255,
                (int(b) * bright) // 255)
    def _draw_physical_matrix(self, write=True):
        board.draw_pixel_grid(self.physical, {1: self._bright_color(), 0: (0, 0, 0)}, write)
    def redraw(self, notify=True):
        if notify:
            self._notify_external_control()
        if self.display_mode == "physical":
            self._draw_physical_matrix(True)
        else:
            self.physical = _legacy_to_physical(self.face)
            board.draw_face_matrix(self.face, self.color, self.bright, True)
    def set_sender(self, sender):
        self.sender = sender
    def show_hex_face(self, hex_string, delay_ms=0):
        self.face = self.decode_hex_string(hex_string)
        self.display_mode = "legacy"
        self.redraw()
        if delay_ms:
            _sleep_ms(delay_ms)
    def boot_animation(self):
        return
    @staticmethod
    def decode_hex_string(hex_string):
        return RinaProtocol.decode_face_bytes(_hex_to_bytes(hex_string), 0)
    @staticmethod
    def decode_face_bytes(data, offset_rows=0):
        face = _empty_face()
        bit_index = 0
        for byte in data:
            for bit in range(7, -1, -1):
                row = offset_rows + (bit_index // board.SRC_COLS)
                col = bit_index % board.SRC_COLS
                if row >= board.SRC_ROWS:
                    return face
                face[row][col] = 1 if (byte & (1 << bit)) else 0
                bit_index += 1
        return face
    def encode_face_bytes(self):
        out = bytearray(FACE_FULL_LEN)
        bit_index = 0
        invalid_cols = getattr(board, "SRC_INVALID_COLS", ())
        for row in range(board.SRC_ROWS):
            for col in range(board.SRC_COLS):
                if col not in invalid_cols and self.face[row][col]:
                    out[bit_index // 8] |= 1 << (7 - (bit_index % 8))
                bit_index += 1
        return bytes(out)
    def encode_face_hex_text(self):
        return self.encode_face_bytes().hex()
    def encode_physical_hex_text(self):
        binary = ""
        for y in range(board.ROWS):
            for x in range(board.COLS):
                if board.logical_to_led_index(x, y) is not None:
                    binary += "1" if self.physical[y][x] else "0"
        while len(binary) % 4:
            binary += "0"
        out = ""
        for i in range(0, len(binary), 4):
            out += "{:x}".format(int(binary[i:i + 4], 2))
        return out
    def update_physical_face_hex(self, hex_text, notify=True):
        hex_text = hex_text.strip()
        if len(hex_text) != PHYSICAL_HEX_LEN or not _is_hex_string(hex_text):
            return False
        binary = ""
        for h in hex_text:
            binary += _NIBBLE_BITS[int(h, 16)]
        physical = _empty_physical()
        k = 0
        for y in range(board.ROWS):
            for x in range(board.COLS):
                if board.logical_to_led_index(x, y) is None:
                    continue
                physical[y][x] = 1 if binary[k] == "1" else 0
                k += 1
        self.physical = physical
        self.display_mode = "physical"
        self.redraw(notify=notify)
        return True
    def update_full_face(self, data, offset_rows=0):
        self.face = self.decode_face_bytes(data, offset_rows)
        self.display_mode = "legacy"
        self.redraw()
    def update_text_lite(self, data):
        self.update_full_face(data, TEXT_CENTER_ALIGN_OFFSET_ROWS)
    @staticmethod
    def _bitpacked_get(rows, y, x, width):
        return 1 if (rows[y] & (1 << (width - 1 - x))) else 0
    @staticmethod
    def _draw_part(face, bitmap, start_row, start_col, height, width, xflip=False):
        for y in range(height):
            for x in range(width):
                sx = width - 1 - x if xflip else x
                row = start_row + y
                col = start_col + x
                if 0 <= row < board.SRC_ROWS and 0 <= col < board.SRC_COLS:
                    face[row][col] = RinaProtocol._bitpacked_get(bitmap, y, sx, width)
    @staticmethod
    def _valid_lite_index(index, max_index):
        if STRICT_ORIGINAL_LITE_INDEX_GUARD:
            return 0 <= index < max_index
        return 0 <= index <= max_index
    def update_lite_face(self, leye, reye, mouth, cheek):
        if (not self._valid_lite_index(leye, emoji_db.MAX_LEYE_COUNT) or
                not self._valid_lite_index(reye, emoji_db.MAX_REYE_COUNT) or
                not self._valid_lite_index(mouth, emoji_db.MAX_MOUTH_COUNT) or
                not self._valid_lite_index(cheek, emoji_db.MAX_CHEEK_COUNT)):
            return False
        face = _empty_face()
        self._draw_part(face, emoji_db.LEYE[leye], emoji_db.L_EYE_START_ROW,
                        emoji_db.L_EYE_START_COL, emoji_db.EYE_SIZE, emoji_db.EYE_SIZE)
        self._draw_part(face, emoji_db.REYE[reye], emoji_db.R_EYE_START_ROW,
                        emoji_db.R_EYE_START_COL, emoji_db.EYE_SIZE, emoji_db.EYE_SIZE)
        self._draw_part(face, emoji_db.MOUTH[mouth], emoji_db.MOUTH_START_ROW,
                        emoji_db.MOUTH_START_COL, emoji_db.MOUTH_SIZE, emoji_db.MOUTH_SIZE)
        self._draw_part(face, emoji_db.CHEEK[cheek], emoji_db.R_CHEEK_START_ROW,
                        emoji_db.R_CHEEK_START_COL, emoji_db.CHEEK_SIZE, emoji_db.CHEEK_SIZE)
        self._draw_part(face, emoji_db.CHEEK[cheek], emoji_db.L_CHEEK_START_ROW,
                        emoji_db.L_CHEEK_START_COL, emoji_db.CHEEK_SIZE, emoji_db.CHEEK_SIZE,
                        xflip=True)
        self.face = face
        self.display_mode = "legacy"
        self.redraw()
        return True
    def update_color(self, data):
        self.color = (data[0] & 0xFF, data[1] & 0xFF, data[2] & 0xFF)
        if self.app is not None and hasattr(self.app, "on_protocol_color_updated"):
            try:
                self.app.on_protocol_color_updated(self.color)
            except Exception as exc:
                print("app color-sync hook failed:", exc)
        self.redraw()
    def update_brightness(self, bright):
        self.bright = bright & 0xFF
        if self.app is not None and hasattr(self.app, "on_protocol_brightness_updated"):
            try:
                self.app.on_protocol_brightness_updated(self.bright)
            except Exception as exc:
                print("app brightness-sync hook failed:", exc)
        self.redraw()
    def set_physical_from_ascii_bitmap(self, bitmap):
        physical = []
        for y in range(board.ROWS):
            row_bits = []
            src = bitmap[y] if y < len(bitmap) else ""
            for x in range(board.COLS):
                if board.logical_to_led_index(x, y) is None:
                    row_bits.append(0)
                else:
                    ch = src[x] if x < len(src) else " "
                    row_bits.append(1 if ch in ("#", "+") else 0)
            physical.append(row_bits)
        self.physical = physical
        self.display_mode = "physical"
    def handle_packet(self, data, remote_ip=None, remote_port=None, link_id=0):
        if not data:
            return
        if self._handle_text_packet(data, remote_ip, remote_port, link_id):
            return
        n = len(data)
        if n == FACE_FULL_LEN:
            self.update_full_face(data, 0)
        elif n == FACE_TEXT_LITE_LEN:
            self.update_text_lite(data)
        elif n == FACE_LITE_LEN:
            ok = self.update_lite_face(data[0], data[1], data[2], data[3])
            if not ok:
                self.reply(remote_ip, remote_port, b"Command Error!", link_id)
        elif n == COLOR_LEN:
            self.update_color(data)
        elif n == REQUEST_LEN:
            self.handle_request((data[0] << 8) | data[1], remote_ip, remote_port, link_id)
        elif n == BRIGHT_LEN:
            self.update_brightness(data[0])
        else:
            self.reply(remote_ip, remote_port, b"Command Error!", link_id)
    def handle_request(self, request, remote_ip, remote_port, link_id):
        if request == REQUEST_FACE:
            self.reply(remote_ip, remote_port, self.encode_face_bytes(), link_id)
        elif request == REQUEST_COLOR:
            self.reply(remote_ip, remote_port, bytes(self.color), link_id)
        elif request == REQUEST_BRIGHT:
            self.reply(remote_ip, remote_port, bytes((self.bright,)), link_id)
        elif request == REQUEST_VERSION:
            self.reply(remote_ip, remote_port, VERSION.encode(), link_id)
        elif request == REQUEST_BATTERY:
            return
        elif request == REQUEST_ESP_LOG:
            if self.log_provider:
                self.reply(remote_ip, remote_port, self.log_provider().encode(), link_id)
            else:
                self.reply(remote_ip, remote_port, b"No ESP log", link_id)
        else:
            self.reply(remote_ip, remote_port, b"Command Error!", link_id)
    def send(self, remote_ip, remote_port, data, link_id=0):
        if self.sender:
            self.sender(remote_ip, remote_port, data, link_id)
    def _handle_text_packet(self, data, remote_ip, remote_port, link_id):
        try:
            s = data.decode().strip()
        except Exception:
            return False
        if not s:
            return False
        low = s.lower()
        if low == "requestmanualmode" or low == "requestcontrolmode":
            if self.app is not None and hasattr(self.app, "manual_control_status_json"):
                self.reply(remote_ip, remote_port, self.app.manual_control_status_json().encode(), link_id)
            else:
                self.reply(remote_ip, remote_port, b"{\"manual_control_mode\":false}", link_id)
            return True
        if low.startswith("manualmode") or low.startswith("manualcontrolmode"):
            parts = s.split("|", 1)
            val = parts[1].strip().lower() if len(parts) == 2 else "1"
            if self.app is None or not hasattr(self.app, "set_manual_control_mode"):
                self.reply(remote_ip, remote_port, b"ERR:no app", link_id)
                return True
            current = bool(getattr(getattr(self.app, "state", None), "manual_control_mode", False))
            if val in ("toggle", "t"):
                target = not current
            else:
                target = not (val in ("0", "false", "off", "exit", "web", "network"))
            try:
                enabled = self.app.set_manual_control_mode(target, redraw=target, source="webui manual button")
                self.reply(remote_ip, remote_port, ("manualMode|" + ("1" if enabled else "0")).encode(), link_id)
            except Exception as exc:
                self.reply(remote_ip, remote_port, ("ERR:" + str(exc)).encode(), link_id)
            return True
        if (low == "runtimestatus" or low == "runtimestop" or low.startswith("runtimestop|") or
                low == "scrolltextstop370" or low.startswith("scrolltextstop370|") or
                low.startswith("scrolltext370|") or
                low.startswith("timeline370begin|") or low.startswith("timeline370chunk|") or
                low == "timeline370play" or low.startswith("timeline370play|") or
                low.startswith("timeline370preview|") or
                low == "timeline370stop" or low.startswith("timeline370stop|") or
                low == "timeline370clear" or low.startswith("timeline370clear|")):
            if self.app is not None and hasattr(self.app, "handle_webui_runtime_command"):
                try:
                    reply = self.app.handle_webui_runtime_command(s)
                except Exception as exc:
                    print("webui runtime command failed:", exc)
                    reply = "ERR:" + str(exc)
                self.reply(remote_ip, remote_port, str(reply).encode(), link_id)
            else:
                self.reply(remote_ip, remote_port, b"ERR:no runtime", link_id)
            return True
        if s.startswith("#") and _is_hex_string(s[1:], 6):
            self.update_color(bytes((int(s[1:3], 16), int(s[3:5], 16), int(s[5:7], 16))))
            return True
        if _is_hex_string(s, 6):
            self.update_color(bytes((int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))))
            return True
        if (s.startswith("B") or s.startswith("b")) and len(s) == 4 and s[1:].isdigit():
            val = int(s[1:])
            if 0 <= val <= 255:
                self.update_brightness(val)
                return True
            self.reply(remote_ip, remote_port, b"Command Error!", link_id)
            return True
        if low == "requestface":
            self.reply(remote_ip, remote_port, self.encode_face_hex_text().encode(), link_id)
            return True
        if low == "requestface370":
            self.reply(remote_ip, remote_port, ("M370:" + self.encode_physical_hex_text()).encode(), link_id)
            return True
        if low == "requestsavedfaces370":
            self.reply(remote_ip, remote_port, saved_faces_370.json_list().encode(), link_id)
            return True
        if low.startswith("selectface370|"):
            parts = s.split("|", 1)
            if self.app is not None and hasattr(self.app, "select_saved_face") and len(parts) == 2:
                try:
                    face = self.app.select_saved_face(parts[1], redraw=True)
                    self.reply(remote_ip, remote_port, ("OK|" + saved_faces_370.json.dumps(face)).encode(), link_id)
                except Exception as exc:
                    self.reply(remote_ip, remote_port, ("ERR:" + str(exc)).encode(), link_id)
            else:
                self.reply(remote_ip, remote_port, b"ERR:no app")
            return True
        if low.startswith("deleteface370index|"):
            self._notify_external_control()
            parts = s.split("|", 1)
            ok = saved_faces_370.delete_by_index(parts[1] if len(parts) == 2 else 0)
            if ok and self.app is not None and hasattr(self.app, "on_saved_faces_changed"):
                try:
                    self.app.on_saved_faces_changed(redraw=False)
                except Exception as exc:
                    print("saved faces delete notify failed:", exc)
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"LOCKED_OR_NOT_FOUND"), link_id)
            return True
        if low.startswith("moveface370|"):
            self._notify_external_control()
            parts = s.split("|", 2)
            ok = len(parts) == 3 and saved_faces_370.move_index(parts[1], parts[2])
            if ok and self.app is not None and hasattr(self.app, "on_saved_faces_changed"):
                try:
                    self.app.on_saved_faces_changed(redraw=False)
                except Exception as exc:
                    print("saved faces move notify failed:", exc)
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"Command Error!"), link_id)
            return True
        if low.startswith("lockface370|"):
            self._notify_external_control()
            parts = s.split("|", 2)
            item = saved_faces_370.set_lock_by_index(parts[1], parts[2]) if len(parts) == 3 else None
            self.reply(remote_ip, remote_port, (b"OK" if item else b"Command Error!"), link_id)
            return True
        if low.startswith("typeface370|"):
            self._notify_external_control()
            parts = s.split("|", 2)
            item = saved_faces_370.set_type_by_index(parts[1], parts[2]) if len(parts) == 3 else None
            self.reply(remote_ip, remote_port, (b"OK" if item else b"Command Error!"), link_id)
            return True
        if low.startswith("renameface370index|"):
            self._notify_external_control()
            parts = s.split("|", 2)
            item = saved_faces_370.rename_by_index(parts[1], parts[2]) if len(parts) == 3 else None
            self.reply(remote_ip, remote_port, (b"OK" if item else b"Command Error!"), link_id)
            return True
        if low.startswith("updateface370|"):
            self._notify_external_control()
            parts = s.split("|", 4)
            item = None
            if len(parts) >= 5:
                item = saved_faces_370.update_by_index(parts[1], name=parts[2], typ=parts[3], locked=parts[4])
            self.reply(remote_ip, remote_port, (b"OK" if item else b"Command Error!"), link_id)
            return True
        if low.startswith("savefaces370json|"):
            self._notify_external_control()
            payload = s.split("|", 1)[1] if "|" in s else ""
            ok = saved_faces_370.save_json(payload)
            if ok and self.app is not None and hasattr(self.app, "on_saved_faces_changed"):
                try:
                    self.app.on_saved_faces_changed(redraw=False)
                except Exception as exc:
                    print("saved faces change notify failed:", exc)
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"Command Error!"), link_id)
            return True
        if low.startswith("saveface370|"):
            self._notify_external_control()
            parts = s.split("|")
            if len(parts) >= 3:
                kind = parts[3] if len(parts) >= 4 else "custom"
                locked = parts[4] if len(parts) >= 5 else False
                saved_faces_370.add_or_update(parts[1], parts[2], kind, locked)
                if self.app is not None and hasattr(self.app, "on_saved_faces_changed"):
                    try:
                        self.app.on_saved_faces_changed(redraw=False)
                    except Exception as exc:
                        print("saved face notify failed:", exc)
                self.reply(remote_ip, remote_port, b"OK", link_id)
            else:
                self.reply(remote_ip, remote_port, b"Command Error!", link_id)
            return True
        if low.startswith("deleteface370|"):
            self._notify_external_control()
            parts = s.split("|", 1)
            ok = False
            if len(parts) == 2:
                ok = saved_faces_370.delete_by_name(parts[1])
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"NOT_FOUND"), link_id)
            return True
        if low.startswith("renameface370|"):
            self._notify_external_control()
            parts = s.split("|", 2)
            ok = False
            if len(parts) == 3:
                ok = saved_faces_370.rename_by_name(parts[1], parts[2])
            self.reply(remote_ip, remote_port, (b"OK" if ok else b"NOT_FOUND"), link_id)
            return True
        if low == "requestcolor":
            self.reply(remote_ip, remote_port,
                       ("#{:02x}{:02x}{:02x}".format(*self.color)).encode(), link_id)
            return True
        if low == "requestbright":
            self.reply(remote_ip, remote_port, str(self.bright).encode(), link_id)
            return True
        if low == "requestversion":
            self.reply(remote_ip, remote_port, VERSION.encode(), link_id)
            return True
        if low == "requestbattery":
            if self.app is not None and hasattr(self.app, "battery_status_json"):
                self.reply(remote_ip, remote_port, self.app.battery_status_json().encode(), link_id)
            else:
                self.reply(remote_ip, remote_port, b"{}", link_id)
            return True
        if low == "requeststate":
            battery = "{}"
            if self.app is not None and hasattr(self.app, "battery_status_json"):
                try:
                    battery = self.app.battery_status_json()
                except Exception:
                    battery = "{}"
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
            self.reply(remote_ip, remote_port, payload.encode(), link_id)
            return True
        if low in ("requestesplog", "requestespstatus"):
            if self.log_provider:
                self.reply(remote_ip, remote_port, self.log_provider().encode(), link_id)
            else:
                self.reply(remote_ip, remote_port, b"No ESP log", link_id)
            return True
        if s == "RinaBoardUdpTest":
            self.reply(remote_ip, remote_port, b"RinaboardIsOn", link_id)
            return True
        if "," in s:
            parts = s.split(",")
            nums = []
            ok = True
            for p in parts:
                if p == "":
                    continue
                try:
                    nums.append(int(p))
                except Exception:
                    ok = False
                    break
            if ok and len(nums) >= 4:
                if not self.update_lite_face(nums[0], nums[1], nums[2], nums[3]):
                    self.reply(remote_ip, remote_port, b"Command Error!", link_id)
                return True
        if low.startswith("m370:"):
            raw = s[5:].strip()
            if self.update_physical_face_hex(raw):
                return True
            self.reply(remote_ip, remote_port, b"Command Error!", link_id)
            return True
        if _is_hex_string(s, 72):
            self.update_full_face(_hex_to_bytes(s), 0)
            return True
        if _is_hex_string(s, 32):
            self.update_text_lite(_hex_to_bytes(s))
            return True
        if _is_hex_string(s, 8):
            raw = _hex_to_bytes(s)
            ok = self.update_lite_face(raw[0], raw[1], raw[2], raw[3])
            if not ok:
                self.reply(remote_ip, remote_port, b"Command Error!", link_id)
            return True
        return False
