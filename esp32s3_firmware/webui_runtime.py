# ---------------------------------------------------------------------------
# webui_runtime.py
#
# Firmware-side runtime for WebUI features that were previously driven by
# browser-side JavaScript timers.  Unity timeline assets are stored as text RNT
# files on flash and streamed line-by-line during playback so MicroPython never
# needs to allocate a large list of frames.
# ---------------------------------------------------------------------------

import gc
import time
import display_num

MAX_TIMELINE_FRAMES = 1200
PHYSICAL_HEX_LEN = 93

_HEX = "0123456789abcdefABCDEF"


def _ticks_ms():
    try:
        return time.ticks_ms()
    except Exception:
        return int(time.time() * 1000)


def _ticks_add(a, b):
    try:
        return time.ticks_add(a, int(b))
    except Exception:
        return int(a) + int(b)


def _ticks_diff(a, b):
    try:
        return time.ticks_diff(a, b)
    except Exception:
        return int(a) - int(b)


def _sleep_ms(ms):
    try:
        time.sleep_ms(int(ms))
    except Exception:
        time.sleep(float(ms) / 1000.0)


def _clean_hex(value):
    s = str(value or "").strip()
    if s.upper().startswith("M370:"):
        s = s[5:]
    out = ""
    for ch in s:
        if ch in _HEX:
            out += ch.upper()
    if len(out) < PHYSICAL_HEX_LEN:
        out += "0" * (PHYSICAL_HEX_LEN - len(out))
    return out[:PHYSICAL_HEX_LEN]


def _clean_text(value, limit=96):
    s = str(value or "")
    s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ").replace("|", " ")
    return s[:limit]


def _safe_asset_part(value):
    s = str(value or "").strip()
    out = ""
    for ch in s:
        if ("a" <= ch <= "z") or ("A" <= ch <= "Z") or ("0" <= ch <= "9") or ch in "_.-":
            out += ch
        else:
            out += "_"
    return out[:64]


def _parse_rnt_header(line):
    meta = {}
    for part in str(line or "").strip().split("|")[1:]:
        if "=" in part:
            k, v = part.split("=", 1)
            meta[k.strip()] = v.strip()
    return meta


def _json_escape(value):
    s = str(value or "")
    s = s.replace('\\', '\\\\').replace('"', '\\"')
    s = s.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
    return s


class WebUIRuntime:
    __slots__ = (
        "app", "mode", "scroll_text", "scroll_speed_ms", "scroll_offset",
        "scroll_next_ms", "timeline", "timeline_expected", "timeline_last_frame",
        "timeline_fps", "timeline_loop", "timeline_name", "timeline_playing",
        "timeline_started_ms", "timeline_last_index", "timeline_loaded_ms",
        "timeline_asset_path", "timeline_asset_kind", "timeline_asset_key",
        "timeline_stream", "timeline_next_frame", "timeline_next_hex",
        "timeline_current_hex", "timeline_stream_done", "timeline_asset_frames_seen",
    )

    def __init__(self, app):
        self.app = app
        self.mode = None
        self.scroll_text = ""
        self.scroll_speed_ms = 120
        self.scroll_offset = 0
        self.scroll_next_ms = 0
        self.timeline = []
        self.timeline_expected = 0
        self.timeline_last_frame = 0
        self.timeline_fps = 30
        self.timeline_loop = False
        self.timeline_name = ""
        self.timeline_playing = False
        self.timeline_started_ms = 0
        self.timeline_last_index = -1
        self.timeline_loaded_ms = 0
        self.timeline_asset_path = ""
        self.timeline_asset_kind = ""
        self.timeline_asset_key = ""
        self.timeline_stream = None
        self.timeline_next_frame = -1
        self.timeline_next_hex = None
        self.timeline_current_hex = None
        self.timeline_stream_done = False
        self.timeline_asset_frames_seen = 0

    def active(self):
        return self.mode in ("scroll", "timeline")

    def _prepare(self):
        if hasattr(self.app, "exit_manual_control_from_network"):
            try:
                self.app.exit_manual_control_from_network("webui runtime")
            except Exception as exc:
                print("manual mode exit failed:", exc)
        st = self.app.state
        st.special_demo_mode = False
        if hasattr(self.app, "force_m_mode"):
            try:
                self.app.force_m_mode("webui runtime", persist=True)
            except Exception as exc:
                print("M/A mode reset failed:", exc)
                st.auto = False
        else:
            st.auto = False
        st.flash_active = False
        st.flash_kind = None
        st.flash_value = None
        st.edge_flash_active = False
        st.battery_display_active = False
        st.battery_display_single_shot = False
        st.ip_display_active = False
        st.b6_pending = False
        st.b6_long_fired = False
        self.app.button_face_active = False

    def _close_rnt_stream(self):
        if self.timeline_stream is not None:
            try:
                self.timeline_stream.close()
            except Exception:
                pass
        self.timeline_stream = None
        self.timeline_next_frame = -1
        self.timeline_next_hex = None
        self.timeline_current_hex = None
        self.timeline_stream_done = False
        self.timeline_asset_frames_seen = 0

    def _clear_asset(self):
        self._close_rnt_stream()
        self.timeline_asset_path = ""
        self.timeline_asset_kind = ""
        self.timeline_asset_key = ""

    def stop(self, redraw=True):
        was_active = self.active()
        self.mode = None
        self.scroll_text = ""
        self.scroll_offset = 0
        self.scroll_next_ms = 0
        self.timeline_playing = False
        self.timeline_last_index = -1
        self._clear_asset()
        if was_active and redraw:
            try:
                self.app.draw_current_face()
            except Exception as exc:
                print("webui runtime redraw failed:", exc)
        gc.collect()
        return was_active

    # ------------------------------------------------------------------
    # Scrolling text
    # ------------------------------------------------------------------
    def start_scroll(self, text, speed_ms=120):
        try:
            speed_ms = int(speed_ms)
        except Exception:
            speed_ms = 120
        if speed_ms < 40:
            speed_ms = 40
        if speed_ms > 1000:
            speed_ms = 1000
        self.stop(redraw=False)
        self._prepare()
        self.mode = "scroll"
        self.scroll_text = _clean_text(text, 96)
        self.scroll_speed_ms = speed_ms
        self.scroll_offset = 0
        self.scroll_next_ms = 0
        self._render_scroll()
        print("webui runtime: scroll start speed={} text={}".format(speed_ms, self.scroll_text))

    def _render_scroll(self):
        color = None
        try:
            color = self.app._current_home_color()
        except Exception:
            color = None
        if color is None:
            display_num.render_scrolling_text_window(self.scroll_text, self.scroll_offset)
        else:
            display_num.render_scrolling_text_window(self.scroll_text, self.scroll_offset, color=color)

    def _service_scroll(self, now):
        if not self.scroll_next_ms or _ticks_diff(now, self.scroll_next_ms) >= 0:
            self._render_scroll()
            total = max(1, len(self.scroll_text) * 6 + 22)
            self.scroll_offset = (self.scroll_offset + 1) % total
            self.scroll_next_ms = _ticks_add(now, self.scroll_speed_ms)

    # ------------------------------------------------------------------
    # Timeline playback: legacy in-RAM chunks and low-memory RNT streaming
    # ------------------------------------------------------------------
    def begin_timeline(self, fps=30, last_frame=0, loop=False, expected=0, name=""):
        self.stop(redraw=False)
        self._prepare()
        try:
            fps = int(fps)
        except Exception:
            fps = 30
        if fps < 1:
            fps = 1
        if fps > 60:
            fps = 60
        try:
            last_frame = int(last_frame)
        except Exception:
            last_frame = 0
        try:
            expected = int(expected)
        except Exception:
            expected = 0
        self.mode = "timeline"
        self.timeline = []
        self.timeline_expected = expected
        self.timeline_last_frame = max(0, last_frame)
        self.timeline_fps = fps
        self.timeline_loop = bool(loop)
        self.timeline_name = _clean_text(name, 48)
        self.timeline_playing = False
        self.timeline_started_ms = 0
        self.timeline_last_index = -1
        self.timeline_loaded_ms = _ticks_ms()
        print("webui runtime: timeline begin fps={} last={} expected={} loop={} name={}".format(
            fps, self.timeline_last_frame, expected, self.timeline_loop, self.timeline_name))

    def add_timeline_chunk(self, chunk):
        # Chunk format: "frame,HEX;frame,HEX;...". Kept only for debugging or
        # very small assets. Normal Unity media playback now uses RNT streaming.
        added = 0
        for raw in str(chunk or "").split(";"):
            if not raw:
                continue
            if "," in raw:
                a, b = raw.split(",", 1)
            elif ":" in raw:
                a, b = raw.split(":", 1)
            else:
                continue
            if len(self.timeline) >= MAX_TIMELINE_FRAMES:
                break
            try:
                frame = int(a)
            except Exception:
                continue
            hx = _clean_hex(b)
            self.timeline.append((max(0, frame), hx))
            added += 1
        if added:
            self.timeline.sort(key=lambda item: item[0])
        return added

    def _rnt_read_meta(self, filepath):
        meta = {}
        f = None
        try:
            f = open(filepath, "r")
            for raw in f:
                line = str(raw or "").strip()
                if not line or line[0] == "#":
                    continue
                if line.startswith("RNT"):
                    meta = _parse_rnt_header(line)
                    break
                # A data line before a header is allowed, but means defaults.
                break
        finally:
            if f is not None:
                try:
                    f.close()
                except Exception:
                    pass
        return meta

    def load_rnt_timeline(self, kind, key, loop=False):
        kind = _safe_asset_part(kind or "voice")
        if kind not in ("voice", "music", "video"):
            return "ERR:bad kind"
        key = _safe_asset_part(key or "")
        if not key:
            return "ERR:missing key"
        filepath = "assets/unity_{}/{}.rnt".format(kind, key)
        try:
            meta = self._rnt_read_meta(filepath)
        except Exception as exc:
            return "ERR:open {} {}".format(filepath, exc)

        try:
            fps = int(meta.get("fps", "30") or 30)
        except Exception:
            fps = 30
        if fps < 1:
            fps = 1
        if fps > 60:
            fps = 60
        try:
            count = int(meta.get("count", "0") or 0)
        except Exception:
            count = 0
        try:
            last_frame = int(meta.get("last", "0") or 0)
        except Exception:
            last_frame = 0

        self.stop(redraw=False)
        self._prepare()
        self.mode = "timeline"
        self.timeline = []
        self.timeline_expected = max(0, count)
        self.timeline_last_frame = max(0, last_frame)
        self.timeline_fps = fps
        self.timeline_loop = bool(loop)
        self.timeline_name = _clean_text("{}:{}".format(kind, key), 48)
        self.timeline_playing = False
        self.timeline_started_ms = 0
        self.timeline_last_index = -1
        self.timeline_loaded_ms = _ticks_ms()
        self.timeline_asset_path = filepath
        self.timeline_asset_kind = kind
        self.timeline_asset_key = key
        gc.collect()
        print("webui runtime: RNT stream asset ready {} count={} last={} fps={} loop={} heap_free={}".format(
            filepath, self.timeline_expected, self.timeline_last_frame, self.timeline_fps,
            self.timeline_loop, gc.mem_free() if hasattr(gc, "mem_free") else -1))
        return "OK:asset:{}:{}:{}".format(self.timeline_expected, self.timeline_last_frame, self.timeline_fps)

    def _read_next_rnt_entry(self):
        f = self.timeline_stream
        if f is None:
            self.timeline_stream_done = True
            return False
        while True:
            try:
                raw = f.readline()
            except Exception as exc:
                print("webui runtime: RNT read failed:", exc)
                self.timeline_stream_done = True
                return False
            if not raw:
                self.timeline_stream_done = True
                return False
            line = str(raw or "").strip()
            if not line or line[0] == "#" or line.startswith("RNT"):
                continue
            parts = line.split("|", 3)
            if len(parts) < 4:
                continue
            try:
                frame = int(parts[0])
            except Exception:
                continue
            self.timeline_next_frame = max(0, frame)
            self.timeline_next_hex = _clean_hex(parts[3])
            self.timeline_asset_frames_seen += 1
            return True

    def _reset_rnt_stream(self):
        self._close_rnt_stream()
        if not self.timeline_asset_path:
            return False
        try:
            self.timeline_stream = open(self.timeline_asset_path, "r")
        except Exception as exc:
            print("webui runtime: RNT open failed {} {}".format(self.timeline_asset_path, exc))
            return False
        self.timeline_stream_done = False
        self.timeline_next_frame = -1
        self.timeline_next_hex = None
        self.timeline_current_hex = None
        self.timeline_asset_frames_seen = 0
        ok = self._read_next_rnt_entry()
        if not ok:
            self._close_rnt_stream()
        return ok

    def play_timeline(self):
        if self.timeline_asset_path:
            if not self._reset_rnt_stream():
                return False
        elif not self.timeline:
            return False
        self._prepare()
        self.mode = "timeline"
        self.timeline_playing = True
        self.timeline_started_ms = _ticks_ms()
        self.timeline_last_index = -1
        self._render_timeline_frame(0, force=True)
        print("webui runtime: timeline play source={} frames={} last={} fps={} loop={} heap_free={}".format(
            "rnt" if self.timeline_asset_path else "ram",
            self.timeline_expected if self.timeline_asset_path else len(self.timeline),
            self.timeline_last_frame, self.timeline_fps, self.timeline_loop,
            gc.mem_free() if hasattr(gc, "mem_free") else -1))
        return True

    def preview_timeline(self, frame=0):
        try:
            frame = int(frame)
        except Exception:
            frame = 0
        if self.timeline_asset_path:
            if not self._reset_rnt_stream():
                return False
        elif not self.timeline:
            return False
        self._prepare()
        self.mode = "timeline"
        self.timeline_playing = False
        self._render_timeline_frame(frame, force=True)
        return True

    def _find_timeline_index(self, frame):
        if not self.timeline:
            return -1
        idx = self.timeline_last_index
        if idx < 0:
            idx = 0
        if idx >= len(self.timeline):
            idx = len(self.timeline) - 1
        while idx + 1 < len(self.timeline) and self.timeline[idx + 1][0] <= frame:
            idx += 1
        while idx > 0 and self.timeline[idx][0] > frame:
            idx -= 1
        return idx

    def _draw_hex(self, hx):
        proto = getattr(self.app, "proto", None)
        if proto is not None and hasattr(proto, "update_physical_face_hex"):
            try:
                return proto.update_physical_face_hex(hx, notify=False)
            except TypeError:
                return proto.update_physical_face_hex(hx)
            except Exception as exc:
                print("webui runtime draw failed:", exc)
        return False

    def _render_stream_frame(self, frame, force=False):
        advanced = False
        while self.timeline_next_hex is not None and self.timeline_next_frame <= frame:
            self.timeline_current_hex = self.timeline_next_hex
            advanced = True
            if not self._read_next_rnt_entry():
                self.timeline_next_hex = None
                self.timeline_next_frame = -1
                break
        if self.timeline_current_hex is None:
            return False
        if force or advanced:
            self._draw_hex(self.timeline_current_hex)
        return True

    def _render_timeline_frame(self, frame, force=False):
        if self.timeline_asset_path:
            return self._render_stream_frame(frame, force=force)
        idx = self._find_timeline_index(frame)
        if idx < 0:
            return False
        if not force and idx == self.timeline_last_index:
            return True
        self.timeline_last_index = idx
        self._draw_hex(self.timeline[idx][1])
        return True

    def _service_timeline(self, now):
        if not self.timeline_playing:
            return
        elapsed_ms = _ticks_diff(now, self.timeline_started_ms)
        frame = int((elapsed_ms * self.timeline_fps) // 1000)
        if self.timeline_last_frame and frame > self.timeline_last_frame:
            if self.timeline_loop:
                self.timeline_started_ms = now
                self.timeline_last_index = -1
                frame = 0
                if self.timeline_asset_path:
                    self._reset_rnt_stream()
            else:
                self.stop(redraw=True)
                return
        self._render_timeline_frame(frame, force=False)

    def service(self):
        if not self.active():
            return
        now = _ticks_ms()
        if self.mode == "scroll":
            self._service_scroll(now)
        elif self.mode == "timeline":
            self._service_timeline(now)

    # ------------------------------------------------------------------
    # Protocol command entry point
    # ------------------------------------------------------------------
    def handle_command(self, command):
        s = str(command or "").strip()
        preview = s if len(s) <= 160 else (s[:160] + "...({} chars)".format(len(s)))
        print(">>> [API Command] 收到前端指令: {}".format(preview))
        try:
            return self._handle_command_impl(s)
        except Exception as exc:
            print("!!! [API Crash] 处理前端指令时发生严重错误: {}".format(exc))
            try:
                gc.collect()
            except Exception:
                pass
            return "ERR:runtime crash {}".format(exc)

    def _handle_command_impl(self, s):
        low = s.lower()
        if low == "runtimestatus":
            return self.status_json()
        if low == "runtimestop" or low.startswith("runtimestop|"):
            self.stop(redraw=True)
            return "OK"
        if low == "scrolltextstop370" or low.startswith("scrolltextstop370|"):
            self.stop(redraw=True)
            return "OK"
        if low.startswith("scrolltext370|"):
            parts = s.split("|", 2)
            if len(parts) < 3:
                return "ERR:scrollText370 needs speed and text"
            self.start_scroll(parts[2], parts[1])
            return "OK"
        if low.startswith("timeline370loadrnt|") or low.startswith("timeline370asset|"):
            parts = s.split("|", 3)
            if len(parts) < 3:
                return "ERR:timeline370LoadRnt needs kind and key"
            loop = False
            if len(parts) >= 4:
                loop = str(parts[3]).strip().lower() in ("1", "true", "on", "yes", "loop")
            return self.load_rnt_timeline(parts[1], parts[2], loop)
        if low.startswith("timeline370begin|"):
            parts = s.split("|", 5)
            if len(parts) < 5:
                return "ERR:timeline370Begin needs fps,last,loop,count"
            name = parts[5] if len(parts) >= 6 else ""
            self.begin_timeline(parts[1], parts[2], str(parts[3]).strip() in ("1", "true", "on", "yes"), parts[4], name)
            return "OK"
        if low.startswith("timeline370chunk|"):
            chunk = s.split("|", 1)[1] if "|" in s else ""
            added = self.add_timeline_chunk(chunk)
            return "OK:{}".format(added)
        if low == "timeline370play" or low.startswith("timeline370play|"):
            return "OK" if self.play_timeline() else "ERR:no timeline"
        if low.startswith("timeline370preview|"):
            frame = s.split("|", 1)[1] if "|" in s else "0"
            return "OK" if self.preview_timeline(frame) else "ERR:no timeline"
        if low == "timeline370stop" or low.startswith("timeline370stop|"):
            self.stop(redraw=True)
            return "OK"
        if low == "timeline370clear" or low.startswith("timeline370clear|"):
            self.stop(redraw=True)
            self.timeline = []
            self.timeline_expected = 0
            self.timeline_last_frame = 0
            self.timeline_name = ""
            return "OK"
        return "ERR:unknown runtime command"

    def status_json(self):
        frames = self.timeline_expected if self.timeline_asset_path else len(self.timeline)
        return ("{"
                "\"active\":" + ("true" if self.active() else "false") + ","
                "\"mode\":\"" + _json_escape(self.mode or "idle") + "\"," 
                "\"scroll_text\":\"" + _json_escape(self.scroll_text) + "\"," 
                "\"timeline_name\":\"" + _json_escape(self.timeline_name) + "\"," 
                "\"timeline_source\":\"" + ("rnt" if self.timeline_asset_path else "ram") + "\"," 
                "\"timeline_frames\":" + str(int(frames)) + ","
                "\"timeline_expected\":" + str(int(self.timeline_expected)) + ","
                "\"timeline_last_frame\":" + str(int(self.timeline_last_frame)) + ","
                "\"timeline_fps\":" + str(int(self.timeline_fps)) + ","
                "\"timeline_loop\":" + ("true" if self.timeline_loop else "false") + ","
                "\"timeline_playing\":" + ("true" if self.timeline_playing else "false") +
                "}")
