# ---------------------------------------------------------------------------
# webui_runtime.py
#
# Firmware-side runtime for WebUI features that were previously driven by
# browser-side JavaScript timers.  Unity timeline assets are stored as text RNT
# files on flash and streamed line-by-line during playback so MicroPython never
# needs to allocate a large list of frames.
# ---------------------------------------------------------------------------

# Import: Loads gc so this module can use that dependency.
import gc
# Import: Loads time so this module can use that dependency.
import time
# Import: Loads display_num so this module can use that dependency.
import display_num

# Variable: MAX_TIMELINE_FRAMES stores the configured literal value.
MAX_TIMELINE_FRAMES = 1200
# Variable: PHYSICAL_HEX_LEN stores the configured literal value.
PHYSICAL_HEX_LEN = 93

# Variable: _HEX stores the configured text value.
_HEX = "0123456789abcdefABCDEF"


# Function: Defines _ticks_ms() to handle ticks ms behavior.
def _ticks_ms():
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Return: Sends the result returned by time.ticks_ms() back to the caller.
        return time.ticks_ms()
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Return: Sends the result returned by int() back to the caller.
        return int(time.time() * 1000)


# Function: Defines _ticks_add(a, b) to handle ticks add behavior.
def _ticks_add(a, b):
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Return: Sends the result returned by time.ticks_add() back to the caller.
        return time.ticks_add(a, int(b))
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Return: Sends the calculated expression int(a) + int(b) back to the caller.
        return int(a) + int(b)


# Function: Defines _ticks_diff(a, b) to handle ticks diff behavior.
def _ticks_diff(a, b):
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Return: Sends the result returned by time.ticks_diff() back to the caller.
        return time.ticks_diff(a, b)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Return: Sends the calculated expression int(a) - int(b) back to the caller.
        return int(a) - int(b)


# Function: Defines _sleep_ms(ms) to handle sleep ms behavior.
def _sleep_ms(ms):
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Expression: Calls time.sleep_ms() for its side effects.
        time.sleep_ms(int(ms))
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Expression: Calls time.sleep() for its side effects.
        time.sleep(float(ms) / 1000.0)


# Function: Defines _clean_hex(value) to handle clean hex behavior.
def _clean_hex(value):
    # Variable: s stores the result returned by str.strip().
    s = str(value or "").strip()
    # Logic: Branches when s.upper().startswith("M370:") so the correct firmware path runs.
    if s.upper().startswith("M370:"):
        # Variable: s stores the selected item s[5:].
        s = s[5:]
    # Variable: out stores the configured text value.
    out = ""
    # Loop: Iterates ch over s so each item can be processed.
    for ch in s:
        # Logic: Branches when ch in _HEX so the correct firmware path runs.
        if ch in _HEX:
            # Variable: Updates out in place using the result returned by ch.upper().
            out += ch.upper()
    # Logic: Branches when len(out) < PHYSICAL_HEX_LEN so the correct firmware path runs.
    if len(out) < PHYSICAL_HEX_LEN:
        # Variable: Updates out in place using the calculated expression "0" * (PHYSICAL_HEX_LEN - len(out)).
        out += "0" * (PHYSICAL_HEX_LEN - len(out))
    # Return: Sends the selected item out[:PHYSICAL_HEX_LEN] back to the caller.
    return out[:PHYSICAL_HEX_LEN]


# Function: Defines _clean_text(value, limit) to handle clean text behavior.
def _clean_text(value, limit=96):
    # Variable: s stores the result returned by str().
    s = str(value or "")
    # Variable: s stores the result returned by s.replace.replace.replace.replace().
    s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ").replace("|", " ")
    # Return: Sends the selected item s[:limit] back to the caller.
    return s[:limit]


# Function: Defines _safe_asset_part(value) to handle safe asset part behavior.
def _safe_asset_part(value):
    # Variable: s stores the result returned by str.strip().
    s = str(value or "").strip()
    # Variable: out stores the configured text value.
    out = ""
    # Loop: Iterates ch over s so each item can be processed.
    for ch in s:
        # Logic: Branches when ("a" <= ch <= "z") or ("A" <= ch <= "Z") or ("0" <= ch <= "9") or ch in "_.-" so the correct firmware path runs.
        if ("a" <= ch <= "z") or ("A" <= ch <= "Z") or ("0" <= ch <= "9") or ch in "_.-":
            # Variable: Updates out in place using the current ch value.
            out += ch
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: Updates out in place using the configured text value.
            out += "_"
    # Return: Sends the selected item out[:64] back to the caller.
    return out[:64]


# Function: Defines _parse_rnt_header(line) to handle parse rnt header behavior.
def _parse_rnt_header(line):
    # Variable: meta stores the lookup table used by this module.
    meta = {}
    # Loop: Iterates part over str(line or "").strip().split("|")[1:] so each item can be processed.
    for part in str(line or "").strip().split("|")[1:]:
        # Logic: Branches when "=" in part so the correct firmware path runs.
        if "=" in part:
            # Variable: k, v stores the result returned by part.split().
            k, v = part.split("=", 1)
            # Variable: meta[...] stores the result returned by v.strip().
            meta[k.strip()] = v.strip()
    # Return: Sends the current meta value back to the caller.
    return meta


# Function: Defines _json_escape(value) to handle json escape behavior.
def _json_escape(value):
    # Variable: s stores the result returned by str().
    s = str(value or "")
    # Variable: s stores the result returned by s.replace.replace().
    s = s.replace('\\', '\\\\').replace('"', '\\"')
    # Variable: s stores the result returned by s.replace.replace.replace().
    s = s.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
    # Return: Sends the current s value back to the caller.
    return s


# Class: Defines WebUIRuntime as the state and behavior container for Web UIRuntime.
class WebUIRuntime:
    # Variable: __slots__ stores the collection of values used later in this module.
    __slots__ = (
        "app", "mode", "scroll_text", "scroll_speed_ms", "scroll_offset",
        "scroll_next_ms", "timeline", "timeline_expected", "timeline_last_frame",
        "timeline_fps", "timeline_loop", "timeline_name", "timeline_playing",
        "timeline_started_ms", "timeline_last_index", "timeline_loaded_ms",
        "timeline_asset_path", "timeline_asset_kind", "timeline_asset_key",
        "timeline_stream", "timeline_next_frame", "timeline_next_hex",
        "timeline_current_hex", "timeline_stream_done", "timeline_asset_frames_seen",
    )

    # Function: Defines __init__(self, app) to handle init behavior.
    def __init__(self, app):
        # Variable: self.app stores the current app value.
        self.app = app
        # Variable: self.mode stores the empty sentinel value.
        self.mode = None
        # Variable: self.scroll_text stores the configured text value.
        self.scroll_text = ""
        # Variable: self.scroll_speed_ms stores the configured literal value.
        self.scroll_speed_ms = 120
        # Variable: self.scroll_offset stores the configured literal value.
        self.scroll_offset = 0
        # Variable: self.scroll_next_ms stores the configured literal value.
        self.scroll_next_ms = 0
        # Variable: self.timeline stores the collection of values used later in this module.
        self.timeline = []
        # Variable: self.timeline_expected stores the configured literal value.
        self.timeline_expected = 0
        # Variable: self.timeline_last_frame stores the configured literal value.
        self.timeline_last_frame = 0
        # Variable: self.timeline_fps stores the configured literal value.
        self.timeline_fps = 30
        # Variable: self.timeline_loop stores the enabled/disabled flag value.
        self.timeline_loop = False
        # Variable: self.timeline_name stores the configured text value.
        self.timeline_name = ""
        # Variable: self.timeline_playing stores the enabled/disabled flag value.
        self.timeline_playing = False
        # Variable: self.timeline_started_ms stores the configured literal value.
        self.timeline_started_ms = 0
        # Variable: self.timeline_last_index stores the calculated unary expression -1.
        self.timeline_last_index = -1
        # Variable: self.timeline_loaded_ms stores the configured literal value.
        self.timeline_loaded_ms = 0
        # Variable: self.timeline_asset_path stores the configured text value.
        self.timeline_asset_path = ""
        # Variable: self.timeline_asset_kind stores the configured text value.
        self.timeline_asset_kind = ""
        # Variable: self.timeline_asset_key stores the configured text value.
        self.timeline_asset_key = ""
        # Variable: self.timeline_stream stores the empty sentinel value.
        self.timeline_stream = None
        # Variable: self.timeline_next_frame stores the calculated unary expression -1.
        self.timeline_next_frame = -1
        # Variable: self.timeline_next_hex stores the empty sentinel value.
        self.timeline_next_hex = None
        # Variable: self.timeline_current_hex stores the empty sentinel value.
        self.timeline_current_hex = None
        # Variable: self.timeline_stream_done stores the enabled/disabled flag value.
        self.timeline_stream_done = False
        # Variable: self.timeline_asset_frames_seen stores the configured literal value.
        self.timeline_asset_frames_seen = 0

    # Function: Defines active(self) to handle active behavior.
    def active(self):
        # Return: Sends the comparison result self.mode in ("scroll", "timeline") back to the caller.
        return self.mode in ("scroll", "timeline")

    # Function: Defines _prepare(self) to handle prepare behavior.
    def _prepare(self):
        # Logic: Branches when hasattr(self.app, "exit_manual_control_from_network") so the correct firmware path runs.
        if hasattr(self.app, "exit_manual_control_from_network"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.app.exit_manual_control_from_network() for its side effects.
                self.app.exit_manual_control_from_network("webui runtime")
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("manual mode exit failed:", exc)
        # Variable: st stores the referenced self.app.state value.
        st = self.app.state
        # Logic: Branches when hasattr(self.app, "force_m_mode") so the correct firmware path runs.
        if hasattr(self.app, "force_m_mode"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.app.force_m_mode() for its side effects.
                self.app.force_m_mode("webui runtime", persist=True)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("M/A mode reset failed:", exc)
                # Variable: st.auto stores the enabled/disabled flag value.
                st.auto = False
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: st.auto stores the enabled/disabled flag value.
            st.auto = False
        # Variable: st.flash_active stores the enabled/disabled flag value.
        st.flash_active = False
        # Variable: st.flash_kind stores the empty sentinel value.
        st.flash_kind = None
        # Variable: st.flash_value stores the empty sentinel value.
        st.flash_value = None
        # Variable: st.edge_flash_active stores the enabled/disabled flag value.
        st.edge_flash_active = False
        # Variable: st.battery_display_active stores the enabled/disabled flag value.
        st.battery_display_active = False
        # Variable: st.battery_display_single_shot stores the enabled/disabled flag value.
        st.battery_display_single_shot = False
        # Variable: st.ip_display_active stores the enabled/disabled flag value.
        st.ip_display_active = False
        # Variable: st.b6_pending stores the enabled/disabled flag value.
        st.b6_pending = False
        # Variable: st.b6_long_fired stores the enabled/disabled flag value.
        st.b6_long_fired = False
        # Variable: self.app.button_face_active stores the enabled/disabled flag value.
        self.app.button_face_active = False

    # Function: Defines _close_rnt_stream(self) to handle close rnt stream behavior.
    def _close_rnt_stream(self):
        # Logic: Branches when self.timeline_stream is not None so the correct firmware path runs.
        if self.timeline_stream is not None:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.timeline_stream.close() for its side effects.
                self.timeline_stream.close()
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
        # Variable: self.timeline_stream stores the empty sentinel value.
        self.timeline_stream = None
        # Variable: self.timeline_next_frame stores the calculated unary expression -1.
        self.timeline_next_frame = -1
        # Variable: self.timeline_next_hex stores the empty sentinel value.
        self.timeline_next_hex = None
        # Variable: self.timeline_current_hex stores the empty sentinel value.
        self.timeline_current_hex = None
        # Variable: self.timeline_stream_done stores the enabled/disabled flag value.
        self.timeline_stream_done = False
        # Variable: self.timeline_asset_frames_seen stores the configured literal value.
        self.timeline_asset_frames_seen = 0

    # Function: Defines _clear_asset(self) to handle clear asset behavior.
    def _clear_asset(self):
        # Expression: Calls self._close_rnt_stream() for its side effects.
        self._close_rnt_stream()
        # Variable: self.timeline_asset_path stores the configured text value.
        self.timeline_asset_path = ""
        # Variable: self.timeline_asset_kind stores the configured text value.
        self.timeline_asset_kind = ""
        # Variable: self.timeline_asset_key stores the configured text value.
        self.timeline_asset_key = ""

    # Function: Defines stop(self, redraw) to handle stop behavior.
    def stop(self, redraw=True):
        # Variable: was_active stores the result returned by self.active().
        was_active = self.active()
        # Variable: self.mode stores the empty sentinel value.
        self.mode = None
        # Variable: self.scroll_text stores the configured text value.
        self.scroll_text = ""
        # Variable: self.scroll_offset stores the configured literal value.
        self.scroll_offset = 0
        # Variable: self.scroll_next_ms stores the configured literal value.
        self.scroll_next_ms = 0
        # Variable: self.timeline_playing stores the enabled/disabled flag value.
        self.timeline_playing = False
        # Variable: self.timeline_last_index stores the calculated unary expression -1.
        self.timeline_last_index = -1
        # Expression: Calls self._clear_asset() for its side effects.
        self._clear_asset()
        # Logic: Branches when was_active and redraw so the correct firmware path runs.
        if was_active and redraw:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls self.app.draw_current_face() for its side effects.
                self.app.draw_current_face()
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("webui runtime redraw failed:", exc)
        # Expression: Calls gc.collect() for its side effects.
        gc.collect()
        # Return: Sends the current was_active value back to the caller.
        return was_active

    # ------------------------------------------------------------------
    # Scrolling text
    # ------------------------------------------------------------------
    # Function: Defines start_scroll(self, text, speed_ms) to handle start scroll behavior.
    def start_scroll(self, text, speed_ms=120):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: speed_ms stores the result returned by int().
            speed_ms = int(speed_ms)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: speed_ms stores the configured literal value.
            speed_ms = 120
        # Logic: Branches when speed_ms < 40 so the correct firmware path runs.
        if speed_ms < 40:
            # Variable: speed_ms stores the configured literal value.
            speed_ms = 40
        # Logic: Branches when speed_ms > 1000 so the correct firmware path runs.
        if speed_ms > 1000:
            # Variable: speed_ms stores the configured literal value.
            speed_ms = 1000
        # Expression: Calls self.stop() for its side effects.
        self.stop(redraw=False)
        # Expression: Calls self._prepare() for its side effects.
        self._prepare()
        # Variable: self.mode stores the configured text value.
        self.mode = "scroll"
        # Variable: self.scroll_text stores the result returned by _clean_text().
        self.scroll_text = _clean_text(text, 96)
        # Variable: self.scroll_speed_ms stores the current speed_ms value.
        self.scroll_speed_ms = speed_ms
        # Variable: self.scroll_offset stores the configured literal value.
        self.scroll_offset = 0
        # Variable: self.scroll_next_ms stores the configured literal value.
        self.scroll_next_ms = 0
        # Expression: Calls self._render_scroll() for its side effects.
        self._render_scroll()
        # Expression: Calls print() for its side effects.
        print("webui runtime: scroll start speed={} text={}".format(speed_ms, self.scroll_text))

    # Function: Defines _render_scroll(self) to handle render scroll behavior.
    def _render_scroll(self):
        # Variable: color stores the empty sentinel value.
        color = None
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: color stores the result returned by self.app.get_color().
            color = self.app.get_color()
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: color stores the empty sentinel value.
            color = None
        # Expression: Calls display_num.render_scrolling_text_window() for its side effects.
        display_num.render_scrolling_text_window(
            self.scroll_text, self.scroll_offset,
            color=color if color is not None else display_num.MODE_COLOR,
        )

    # Function: Defines _service_scroll(self, now) to handle service scroll behavior.
    def _service_scroll(self, now):
        # Logic: Branches when not self.scroll_next_ms or _ticks_diff(now, self.scroll_next_ms) >= 0 so the correct firmware path runs.
        if not self.scroll_next_ms or _ticks_diff(now, self.scroll_next_ms) >= 0:
            # Expression: Calls self._render_scroll() for its side effects.
            self._render_scroll()
            # Variable: total stores the result returned by max().
            total = max(1, len(self.scroll_text) * 6 + 22)
            # Variable: self.scroll_offset stores the calculated expression (self.scroll_offset + 1) % total.
            self.scroll_offset = (self.scroll_offset + 1) % total
            # Variable: self.scroll_next_ms stores the result returned by _ticks_add().
            self.scroll_next_ms = _ticks_add(now, self.scroll_speed_ms)

    # ------------------------------------------------------------------
    # Timeline playback: legacy in-RAM chunks and low-memory RNT streaming
    # ------------------------------------------------------------------
    # Function: Defines begin_timeline(self, fps, last_frame, loop, expected, name) to handle begin timeline behavior.
    def begin_timeline(self, fps=30, last_frame=0, loop=False, expected=0, name=""):
        # Expression: Calls self.stop() for its side effects.
        self.stop(redraw=False)
        # Expression: Calls self._prepare() for its side effects.
        self._prepare()
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: fps stores the result returned by int().
            fps = int(fps)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: fps stores the configured literal value.
            fps = 30
        # Logic: Branches when fps < 1 so the correct firmware path runs.
        if fps < 1:
            # Variable: fps stores the configured literal value.
            fps = 1
        # Logic: Branches when fps > 60 so the correct firmware path runs.
        if fps > 60:
            # Variable: fps stores the configured literal value.
            fps = 60
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: last_frame stores the result returned by int().
            last_frame = int(last_frame)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: last_frame stores the configured literal value.
            last_frame = 0
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: expected stores the result returned by int().
            expected = int(expected)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: expected stores the configured literal value.
            expected = 0
        # Variable: self.mode stores the configured text value.
        self.mode = "timeline"
        # Variable: self.timeline stores the collection of values used later in this module.
        self.timeline = []
        # Variable: self.timeline_expected stores the current expected value.
        self.timeline_expected = expected
        # Variable: self.timeline_last_frame stores the result returned by max().
        self.timeline_last_frame = max(0, last_frame)
        # Variable: self.timeline_fps stores the current fps value.
        self.timeline_fps = fps
        # Variable: self.timeline_loop stores the result returned by bool().
        self.timeline_loop = bool(loop)
        # Variable: self.timeline_name stores the result returned by _clean_text().
        self.timeline_name = _clean_text(name, 48)
        # Variable: self.timeline_playing stores the enabled/disabled flag value.
        self.timeline_playing = False
        # Variable: self.timeline_started_ms stores the configured literal value.
        self.timeline_started_ms = 0
        # Variable: self.timeline_last_index stores the calculated unary expression -1.
        self.timeline_last_index = -1
        # Variable: self.timeline_loaded_ms stores the result returned by _ticks_ms().
        self.timeline_loaded_ms = _ticks_ms()
        # Expression: Calls print() for its side effects.
        print("webui runtime: timeline begin fps={} last={} expected={} loop={} name={}".format(
            fps, self.timeline_last_frame, expected, self.timeline_loop, self.timeline_name))

    # Function: Defines add_timeline_chunk(self, chunk) to handle add timeline chunk behavior.
    def add_timeline_chunk(self, chunk):
        # Chunk format: "frame,HEX;frame,HEX;...". Kept only for debugging or
        # very small assets. Normal Unity media playback now uses RNT streaming.
        # Variable: added stores the configured literal value.
        added = 0
        # Loop: Iterates raw over str(chunk or "").split(";") so each item can be processed.
        for raw in str(chunk or "").split(";"):
            # Logic: Branches when not raw so the correct firmware path runs.
            if not raw:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Logic: Branches when "," in raw so the correct firmware path runs.
            if "," in raw:
                # Variable: a, b stores the result returned by raw.split().
                a, b = raw.split(",", 1)
            # Logic: Branches when ":" in raw so the correct firmware path runs.
            elif ":" in raw:
                # Variable: a, b stores the result returned by raw.split().
                a, b = raw.split(":", 1)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Logic: Branches when len(self.timeline) >= MAX_TIMELINE_FRAMES so the correct firmware path runs.
            if len(self.timeline) >= MAX_TIMELINE_FRAMES:
                # Control: Stops the loop once the required condition has been met.
                break
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: frame stores the result returned by int().
                frame = int(a)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Variable: hx stores the result returned by _clean_hex().
            hx = _clean_hex(b)
            # Expression: Calls self.timeline.append() for its side effects.
            self.timeline.append((max(0, frame), hx))
            # Variable: Updates added in place using the configured literal value.
            added += 1
        # Logic: Branches when added so the correct firmware path runs.
        if added:
            # Expression: Calls self.timeline.sort() for its side effects.
            self.timeline.sort(key=lambda item: item[0])
        # Return: Sends the current added value back to the caller.
        return added

    # Function: Defines _rnt_read_meta(self, filepath) to handle rnt read meta behavior.
    def _rnt_read_meta(self, filepath):
        # Variable: meta stores the lookup table used by this module.
        meta = {}
        # Variable: f stores the empty sentinel value.
        f = None
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: f stores the result returned by open().
            f = open(filepath, "r")
            # Loop: Iterates raw over f so each item can be processed.
            for raw in f:
                # Variable: line stores the result returned by str.strip().
                line = str(raw or "").strip()
                # Logic: Branches when not line or line[0] == "#" so the correct firmware path runs.
                if not line or line[0] == "#":
                    # Control: Skips to the next loop iteration after this case is handled.
                    continue
                # Logic: Branches when line.startswith("RNT") so the correct firmware path runs.
                if line.startswith("RNT"):
                    # Variable: meta stores the result returned by _parse_rnt_header().
                    meta = _parse_rnt_header(line)
                    # Control: Stops the loop once the required condition has been met.
                    break
                # A data line before a header is allowed, but means defaults.
                # Control: Stops the loop once the required condition has been met.
                break
        # Cleanup: Runs this cleanup branch whether the protected operation succeeds or fails.
        finally:
            # Logic: Branches when f is not None so the correct firmware path runs.
            if f is not None:
                # Error handling: Attempts the protected operation so failures can be handled safely.
                try:
                    # Expression: Calls f.close() for its side effects.
                    f.close()
                # Error handling: Runs this recovery branch when the protected operation fails.
                except Exception:
                    # Control: Leaves this branch intentionally empty.
                    pass
        # Return: Sends the current meta value back to the caller.
        return meta

    # Function: Defines load_rnt_timeline(self, kind, key, loop) to handle load rnt timeline behavior.
    def load_rnt_timeline(self, kind, key, loop=False):
        # Variable: kind stores the result returned by _safe_asset_part().
        kind = _safe_asset_part(kind or "voice")
        # Logic: Branches when kind not in ("voice", "music", "video") so the correct firmware path runs.
        if kind not in ("voice", "music", "video"):
            # Return: Sends the configured text value back to the caller.
            return "ERR:bad kind"
        # Variable: key stores the result returned by _safe_asset_part().
        key = _safe_asset_part(key or "")
        # Logic: Branches when not key so the correct firmware path runs.
        if not key:
            # Return: Sends the configured text value back to the caller.
            return "ERR:missing key"
        # Variable: filepath stores the result returned by format().
        filepath = "assets/unity_{}/{}.rnt".format(kind, key)
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: meta stores the result returned by self._rnt_read_meta().
            meta = self._rnt_read_meta(filepath)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Return: Sends the result returned by format() back to the caller.
            return "ERR:open {} {}".format(filepath, exc)

        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: fps stores the result returned by int().
            fps = int(meta.get("fps", "30") or 30)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: fps stores the configured literal value.
            fps = 30
        # Logic: Branches when fps < 1 so the correct firmware path runs.
        if fps < 1:
            # Variable: fps stores the configured literal value.
            fps = 1
        # Logic: Branches when fps > 60 so the correct firmware path runs.
        if fps > 60:
            # Variable: fps stores the configured literal value.
            fps = 60
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: count stores the result returned by int().
            count = int(meta.get("count", "0") or 0)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: count stores the configured literal value.
            count = 0
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: last_frame stores the result returned by int().
            last_frame = int(meta.get("last", "0") or 0)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: last_frame stores the configured literal value.
            last_frame = 0

        # Expression: Calls self.stop() for its side effects.
        self.stop(redraw=False)
        # Expression: Calls self._prepare() for its side effects.
        self._prepare()
        # Variable: self.mode stores the configured text value.
        self.mode = "timeline"
        # Variable: self.timeline stores the collection of values used later in this module.
        self.timeline = []
        # Variable: self.timeline_expected stores the result returned by max().
        self.timeline_expected = max(0, count)
        # Variable: self.timeline_last_frame stores the result returned by max().
        self.timeline_last_frame = max(0, last_frame)
        # Variable: self.timeline_fps stores the current fps value.
        self.timeline_fps = fps
        # Variable: self.timeline_loop stores the result returned by bool().
        self.timeline_loop = bool(loop)
        # Variable: self.timeline_name stores the result returned by _clean_text().
        self.timeline_name = _clean_text("{}:{}".format(kind, key), 48)
        # Variable: self.timeline_playing stores the enabled/disabled flag value.
        self.timeline_playing = False
        # Variable: self.timeline_started_ms stores the configured literal value.
        self.timeline_started_ms = 0
        # Variable: self.timeline_last_index stores the calculated unary expression -1.
        self.timeline_last_index = -1
        # Variable: self.timeline_loaded_ms stores the result returned by _ticks_ms().
        self.timeline_loaded_ms = _ticks_ms()
        # Variable: self.timeline_asset_path stores the current filepath value.
        self.timeline_asset_path = filepath
        # Variable: self.timeline_asset_kind stores the current kind value.
        self.timeline_asset_kind = kind
        # Variable: self.timeline_asset_key stores the current key value.
        self.timeline_asset_key = key
        # Expression: Calls gc.collect() for its side effects.
        gc.collect()
        # Expression: Calls print() for its side effects.
        print("webui runtime: RNT stream asset ready {} count={} last={} fps={} loop={} heap_free={}".format(
            filepath, self.timeline_expected, self.timeline_last_frame, self.timeline_fps,
            self.timeline_loop, gc.mem_free() if hasattr(gc, "mem_free") else -1))
        # Return: Sends the result returned by format() back to the caller.
        return "OK:asset:{}:{}:{}".format(self.timeline_expected, self.timeline_last_frame, self.timeline_fps)

    # Function: Defines _read_next_rnt_entry(self) to handle read next rnt entry behavior.
    def _read_next_rnt_entry(self):
        # Variable: f stores the referenced self.timeline_stream value.
        f = self.timeline_stream
        # Logic: Branches when f is None so the correct firmware path runs.
        if f is None:
            # Variable: self.timeline_stream_done stores the enabled/disabled flag value.
            self.timeline_stream_done = True
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Loop: Repeats while True remains true.
        while True:
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: raw stores the result returned by f.readline().
                raw = f.readline()
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("webui runtime: RNT read failed:", exc)
                # Variable: self.timeline_stream_done stores the enabled/disabled flag value.
                self.timeline_stream_done = True
                # Return: Sends the enabled/disabled flag value back to the caller.
                return False
            # Logic: Branches when not raw so the correct firmware path runs.
            if not raw:
                # Variable: self.timeline_stream_done stores the enabled/disabled flag value.
                self.timeline_stream_done = True
                # Return: Sends the enabled/disabled flag value back to the caller.
                return False
            # Variable: line stores the result returned by str.strip().
            line = str(raw or "").strip()
            # Logic: Branches when not line or line[0] == "#" or line.startswith("RNT") so the correct firmware path runs.
            if not line or line[0] == "#" or line.startswith("RNT"):
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Variable: parts stores the result returned by line.split().
            parts = line.split("|", 3)
            # Logic: Branches when len(parts) < 4 so the correct firmware path runs.
            if len(parts) < 4:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Variable: frame stores the result returned by int().
                frame = int(parts[0])
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Variable: self.timeline_next_frame stores the result returned by max().
            self.timeline_next_frame = max(0, frame)
            # Variable: self.timeline_next_hex stores the result returned by _clean_hex().
            self.timeline_next_hex = _clean_hex(parts[3])
            # Variable: Updates self.timeline_asset_frames_seen in place using the configured literal value.
            self.timeline_asset_frames_seen += 1
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True

    # Function: Defines _reset_rnt_stream(self) to handle reset rnt stream behavior.
    def _reset_rnt_stream(self):
        # Expression: Calls self._close_rnt_stream() for its side effects.
        self._close_rnt_stream()
        # Logic: Branches when not self.timeline_asset_path so the correct firmware path runs.
        if not self.timeline_asset_path:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: self.timeline_stream stores the result returned by open().
            self.timeline_stream = open(self.timeline_asset_path, "r")
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls print() for its side effects.
            print("webui runtime: RNT open failed {} {}".format(self.timeline_asset_path, exc))
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Variable: self.timeline_stream_done stores the enabled/disabled flag value.
        self.timeline_stream_done = False
        # Variable: self.timeline_next_frame stores the calculated unary expression -1.
        self.timeline_next_frame = -1
        # Variable: self.timeline_next_hex stores the empty sentinel value.
        self.timeline_next_hex = None
        # Variable: self.timeline_current_hex stores the empty sentinel value.
        self.timeline_current_hex = None
        # Variable: self.timeline_asset_frames_seen stores the configured literal value.
        self.timeline_asset_frames_seen = 0
        # Variable: ok stores the result returned by self._read_next_rnt_entry().
        ok = self._read_next_rnt_entry()
        # Logic: Branches when not ok so the correct firmware path runs.
        if not ok:
            # Expression: Calls self._close_rnt_stream() for its side effects.
            self._close_rnt_stream()
        # Return: Sends the current ok value back to the caller.
        return ok

    # Function: Defines play_timeline(self) to handle play timeline behavior.
    def play_timeline(self):
        # Logic: Branches when self.timeline_asset_path so the correct firmware path runs.
        if self.timeline_asset_path:
            # Logic: Branches when not self._reset_rnt_stream() so the correct firmware path runs.
            if not self._reset_rnt_stream():
                # Return: Sends the enabled/disabled flag value back to the caller.
                return False
        # Logic: Branches when not self.timeline so the correct firmware path runs.
        elif not self.timeline:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Expression: Calls self._prepare() for its side effects.
        self._prepare()
        # Variable: self.mode stores the configured text value.
        self.mode = "timeline"
        # Variable: self.timeline_playing stores the enabled/disabled flag value.
        self.timeline_playing = True
        # Variable: self.timeline_started_ms stores the result returned by _ticks_ms().
        self.timeline_started_ms = _ticks_ms()
        # Variable: self.timeline_last_index stores the calculated unary expression -1.
        self.timeline_last_index = -1
        # Expression: Calls self._render_timeline_frame() for its side effects.
        self._render_timeline_frame(0, force=True)
        # Expression: Calls print() for its side effects.
        print("webui runtime: timeline play source={} frames={} last={} fps={} loop={} heap_free={}".format(
            "rnt" if self.timeline_asset_path else "ram",
            self.timeline_expected if self.timeline_asset_path else len(self.timeline),
            self.timeline_last_frame, self.timeline_fps, self.timeline_loop,
            gc.mem_free() if hasattr(gc, "mem_free") else -1))
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # Function: Defines preview_timeline(self, frame) to handle preview timeline behavior.
    def preview_timeline(self, frame=0):
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Variable: frame stores the result returned by int().
            frame = int(frame)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception:
            # Variable: frame stores the configured literal value.
            frame = 0
        # Logic: Branches when self.timeline_asset_path so the correct firmware path runs.
        if self.timeline_asset_path:
            # Logic: Branches when not self._reset_rnt_stream() so the correct firmware path runs.
            if not self._reset_rnt_stream():
                # Return: Sends the enabled/disabled flag value back to the caller.
                return False
        # Logic: Branches when not self.timeline so the correct firmware path runs.
        elif not self.timeline:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Expression: Calls self._prepare() for its side effects.
        self._prepare()
        # Variable: self.mode stores the configured text value.
        self.mode = "timeline"
        # Variable: self.timeline_playing stores the enabled/disabled flag value.
        self.timeline_playing = False
        # Expression: Calls self._render_timeline_frame() for its side effects.
        self._render_timeline_frame(frame, force=True)
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # Function: Defines _find_timeline_index(self, frame) to handle find timeline index behavior.
    def _find_timeline_index(self, frame):
        # Logic: Branches when not self.timeline so the correct firmware path runs.
        if not self.timeline:
            # Return: Sends the calculated unary expression -1 back to the caller.
            return -1
        # Variable: idx stores the referenced self.timeline_last_index value.
        idx = self.timeline_last_index
        # Logic: Branches when idx < 0 so the correct firmware path runs.
        if idx < 0:
            # Variable: idx stores the configured literal value.
            idx = 0
        # Logic: Branches when idx >= len(self.timeline) so the correct firmware path runs.
        if idx >= len(self.timeline):
            # Variable: idx stores the calculated expression len(self.timeline) - 1.
            idx = len(self.timeline) - 1
        # Loop: Repeats while idx + 1 < len(self.timeline) and self.timeline[idx + 1][0] <= frame remains true.
        while idx + 1 < len(self.timeline) and self.timeline[idx + 1][0] <= frame:
            # Variable: Updates idx in place using the configured literal value.
            idx += 1
        # Loop: Repeats while idx > 0 and self.timeline[idx][0] > frame remains true.
        while idx > 0 and self.timeline[idx][0] > frame:
            # Variable: Updates idx in place using the configured literal value.
            idx -= 1
        # Return: Sends the current idx value back to the caller.
        return idx

    # Function: Defines _draw_hex(self, hx) to handle draw hex behavior.
    def _draw_hex(self, hx):
        # Variable: proto stores the result returned by getattr().
        proto = getattr(self.app, "proto", None)
        # Logic: Branches when proto is not None and hasattr(proto, "update_physical_face_hex") so the correct firmware path runs.
        if proto is not None and hasattr(proto, "update_physical_face_hex"):
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Return: Sends the result returned by proto.update_physical_face_hex() back to the caller.
                return proto.update_physical_face_hex(hx, notify=False)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except TypeError:
                # Return: Sends the result returned by proto.update_physical_face_hex() back to the caller.
                return proto.update_physical_face_hex(hx)
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception as exc:
                # Expression: Calls print() for its side effects.
                print("webui runtime draw failed:", exc)
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False

    # Function: Defines _render_stream_frame(self, frame, force) to handle render stream frame behavior.
    def _render_stream_frame(self, frame, force=False):
        # Variable: advanced stores the enabled/disabled flag value.
        advanced = False
        # Loop: Repeats while self.timeline_next_hex is not None and self.timeline_next_frame <= frame remains true.
        while self.timeline_next_hex is not None and self.timeline_next_frame <= frame:
            # Variable: self.timeline_current_hex stores the referenced self.timeline_next_hex value.
            self.timeline_current_hex = self.timeline_next_hex
            # Variable: advanced stores the enabled/disabled flag value.
            advanced = True
            # Logic: Branches when not self._read_next_rnt_entry() so the correct firmware path runs.
            if not self._read_next_rnt_entry():
                # Variable: self.timeline_next_hex stores the empty sentinel value.
                self.timeline_next_hex = None
                # Variable: self.timeline_next_frame stores the calculated unary expression -1.
                self.timeline_next_frame = -1
                # Control: Stops the loop once the required condition has been met.
                break
        # Logic: Branches when self.timeline_current_hex is None so the correct firmware path runs.
        if self.timeline_current_hex is None:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Logic: Branches when force or advanced so the correct firmware path runs.
        if force or advanced:
            # Expression: Calls self._draw_hex() for its side effects.
            self._draw_hex(self.timeline_current_hex)
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # Function: Defines _render_timeline_frame(self, frame, force) to handle render timeline frame behavior.
    def _render_timeline_frame(self, frame, force=False):
        # Logic: Branches when self.timeline_asset_path so the correct firmware path runs.
        if self.timeline_asset_path:
            # Return: Sends the result returned by self._render_stream_frame() back to the caller.
            return self._render_stream_frame(frame, force=force)
        # Variable: idx stores the result returned by self._find_timeline_index().
        idx = self._find_timeline_index(frame)
        # Logic: Branches when idx < 0 so the correct firmware path runs.
        if idx < 0:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Logic: Branches when not force and idx == self.timeline_last_index so the correct firmware path runs.
        if not force and idx == self.timeline_last_index:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
        # Variable: self.timeline_last_index stores the current idx value.
        self.timeline_last_index = idx
        # Expression: Calls self._draw_hex() for its side effects.
        self._draw_hex(self.timeline[idx][1])
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True

    # Function: Defines _service_timeline(self, now) to handle service timeline behavior.
    def _service_timeline(self, now):
        # Logic: Branches when not self.timeline_playing so the correct firmware path runs.
        if not self.timeline_playing:
            # Return: Sends control back to the caller.
            return
        # Variable: elapsed_ms stores the result returned by _ticks_diff().
        elapsed_ms = _ticks_diff(now, self.timeline_started_ms)
        # Variable: frame stores the result returned by int().
        frame = int((elapsed_ms * self.timeline_fps) // 1000)
        # Logic: Branches when self.timeline_last_frame and frame > self.timeline_last_frame so the correct firmware path runs.
        if self.timeline_last_frame and frame > self.timeline_last_frame:
            # Logic: Branches when self.timeline_loop so the correct firmware path runs.
            if self.timeline_loop:
                # Variable: self.timeline_started_ms stores the current now value.
                self.timeline_started_ms = now
                # Variable: self.timeline_last_index stores the calculated unary expression -1.
                self.timeline_last_index = -1
                # Variable: frame stores the configured literal value.
                frame = 0
                # Logic: Branches when self.timeline_asset_path so the correct firmware path runs.
                if self.timeline_asset_path:
                    # Expression: Calls self._reset_rnt_stream() for its side effects.
                    self._reset_rnt_stream()
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Expression: Calls self.stop() for its side effects.
                self.stop(redraw=True)
                # Return: Sends control back to the caller.
                return
        # Expression: Calls self._render_timeline_frame() for its side effects.
        self._render_timeline_frame(frame, force=False)

    # Function: Defines service(self) to handle service behavior.
    def service(self):
        # Logic: Branches when not self.active() so the correct firmware path runs.
        if not self.active():
            # Return: Sends control back to the caller.
            return
        # Variable: now stores the result returned by _ticks_ms().
        now = _ticks_ms()
        # Logic: Branches when self.mode == "scroll" so the correct firmware path runs.
        if self.mode == "scroll":
            # Expression: Calls self._service_scroll() for its side effects.
            self._service_scroll(now)
        # Logic: Branches when self.mode == "timeline" so the correct firmware path runs.
        elif self.mode == "timeline":
            # Expression: Calls self._service_timeline() for its side effects.
            self._service_timeline(now)

    # ------------------------------------------------------------------
    # Protocol command entry point
    # ------------------------------------------------------------------
    # Function: Defines handle_command(self, command) to handle handle command behavior.
    def handle_command(self, command):
        # Variable: s stores the result returned by str.strip().
        s = str(command or "").strip()
        # Variable: preview stores the conditional expression s if len(s) <= 160 else (s[:160] + "...({} chars)".format(len(s))).
        preview = s if len(s) <= 160 else (s[:160] + "...({} chars)".format(len(s)))
        # Expression: Calls print() for its side effects.
        print(">>> [API Command] 收到前端指令: {}".format(preview))
        # Error handling: Attempts the protected operation so failures can be handled safely.
        try:
            # Return: Sends the result returned by self._handle_command_impl() back to the caller.
            return self._handle_command_impl(s)
        # Error handling: Runs this recovery branch when the protected operation fails.
        except Exception as exc:
            # Expression: Calls print() for its side effects.
            print("!!! [API Crash] 处理前端指令时发生严重错误: {}".format(exc))
            # Error handling: Attempts the protected operation so failures can be handled safely.
            try:
                # Expression: Calls gc.collect() for its side effects.
                gc.collect()
            # Error handling: Runs this recovery branch when the protected operation fails.
            except Exception:
                # Control: Leaves this branch intentionally empty.
                pass
            # Return: Sends the result returned by format() back to the caller.
            return "ERR:runtime crash {}".format(exc)

    # Function: Defines _handle_command_impl(self, s) to handle handle command impl behavior.
    def _handle_command_impl(self, s):
        # Variable: low stores the result returned by s.lower().
        low = s.lower()
        # Logic: Branches when low == "runtimestatus" so the correct firmware path runs.
        if low == "runtimestatus":
            # Return: Sends the result returned by self.status_json() back to the caller.
            return self.status_json()
        # Logic: Branches when low == "runtimestop" or low.startswith("runtimestop|") so the correct firmware path runs.
        if low == "runtimestop" or low.startswith("runtimestop|"):
            # Expression: Calls self.stop() for its side effects.
            self.stop(redraw=True)
            # Return: Sends the configured text value back to the caller.
            return "OK"
        # Logic: Branches when low == "scrolltextstop370" or low.startswith("scrolltextstop370|") so the correct firmware path runs.
        if low == "scrolltextstop370" or low.startswith("scrolltextstop370|"):
            # Expression: Calls self.stop() for its side effects.
            self.stop(redraw=True)
            # Return: Sends the configured text value back to the caller.
            return "OK"
        # Logic: Branches when low.startswith("scrolltext370|") so the correct firmware path runs.
        if low.startswith("scrolltext370|"):
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 2)
            # Logic: Branches when len(parts) < 3 so the correct firmware path runs.
            if len(parts) < 3:
                # Return: Sends the configured text value back to the caller.
                return "ERR:scrollText370 needs speed and text"
            # Expression: Calls self.start_scroll() for its side effects.
            self.start_scroll(parts[2], parts[1])
            # Return: Sends the configured text value back to the caller.
            return "OK"
        # Logic: Branches when low.startswith("timeline370loadrnt|") or low.startswith("timeline370asset|") so the correct firmware path runs.
        if low.startswith("timeline370loadrnt|") or low.startswith("timeline370asset|"):
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 3)
            # Logic: Branches when len(parts) < 3 so the correct firmware path runs.
            if len(parts) < 3:
                # Return: Sends the configured text value back to the caller.
                return "ERR:timeline370LoadRnt needs kind and key"
            # Variable: loop stores the enabled/disabled flag value.
            loop = False
            # Logic: Branches when len(parts) >= 4 so the correct firmware path runs.
            if len(parts) >= 4:
                # Variable: loop stores the comparison result str(parts[3]).strip().lower() in ("1", "true", "on", "yes", "loop").
                loop = str(parts[3]).strip().lower() in ("1", "true", "on", "yes", "loop")
            # Return: Sends the result returned by self.load_rnt_timeline() back to the caller.
            return self.load_rnt_timeline(parts[1], parts[2], loop)
        # Logic: Branches when low.startswith("timeline370begin|") so the correct firmware path runs.
        if low.startswith("timeline370begin|"):
            # Variable: parts stores the result returned by s.split().
            parts = s.split("|", 5)
            # Logic: Branches when len(parts) < 5 so the correct firmware path runs.
            if len(parts) < 5:
                # Return: Sends the configured text value back to the caller.
                return "ERR:timeline370Begin needs fps,last,loop,count"
            # Variable: name stores the conditional expression parts[5] if len(parts) >= 6 else "".
            name = parts[5] if len(parts) >= 6 else ""
            # Expression: Calls self.begin_timeline() for its side effects.
            self.begin_timeline(parts[1], parts[2], str(parts[3]).strip() in ("1", "true", "on", "yes"), parts[4], name)
            # Return: Sends the configured text value back to the caller.
            return "OK"
        # Logic: Branches when low.startswith("timeline370chunk|") so the correct firmware path runs.
        if low.startswith("timeline370chunk|"):
            # Variable: chunk stores the conditional expression s.split("|", 1)[1] if "|" in s else "".
            chunk = s.split("|", 1)[1] if "|" in s else ""
            # Variable: added stores the result returned by self.add_timeline_chunk().
            added = self.add_timeline_chunk(chunk)
            # Return: Sends the result returned by format() back to the caller.
            return "OK:{}".format(added)
        # Logic: Branches when low == "timeline370play" or low.startswith("timeline370play|") so the correct firmware path runs.
        if low == "timeline370play" or low.startswith("timeline370play|"):
            # Return: Sends the conditional expression "OK" if self.play_timeline() else "ERR:no timeline" back to the caller.
            return "OK" if self.play_timeline() else "ERR:no timeline"
        # Logic: Branches when low.startswith("timeline370preview|") so the correct firmware path runs.
        if low.startswith("timeline370preview|"):
            # Variable: frame stores the conditional expression s.split("|", 1)[1] if "|" in s else "0".
            frame = s.split("|", 1)[1] if "|" in s else "0"
            # Return: Sends the conditional expression "OK" if self.preview_timeline(frame) else "ERR:no timeline" back to the caller.
            return "OK" if self.preview_timeline(frame) else "ERR:no timeline"
        # Logic: Branches when low == "timeline370stop" or low.startswith("timeline370stop|") so the correct firmware path runs.
        if low == "timeline370stop" or low.startswith("timeline370stop|"):
            # Expression: Calls self.stop() for its side effects.
            self.stop(redraw=True)
            # Return: Sends the configured text value back to the caller.
            return "OK"
        # Logic: Branches when low == "timeline370clear" or low.startswith("timeline370clear|") so the correct firmware path runs.
        if low == "timeline370clear" or low.startswith("timeline370clear|"):
            # Expression: Calls self.stop() for its side effects.
            self.stop(redraw=True)
            # Variable: self.timeline stores the collection of values used later in this module.
            self.timeline = []
            # Variable: self.timeline_expected stores the configured literal value.
            self.timeline_expected = 0
            # Variable: self.timeline_last_frame stores the configured literal value.
            self.timeline_last_frame = 0
            # Variable: self.timeline_name stores the configured text value.
            self.timeline_name = ""
            # Return: Sends the configured text value back to the caller.
            return "OK"
        # Return: Sends the configured text value back to the caller.
        return "ERR:unknown runtime command"

    # Function: Defines status_json(self) to handle status json behavior.
    def status_json(self):
        # Variable: frames stores the conditional expression self.timeline_expected if self.timeline_asset_path else len(self.timeline).
        frames = self.timeline_expected if self.timeline_asset_path else len(self.timeline)
        # Return: Sends the calculated expression "{" "\"active\":" + ("true" if self.active() else "false") + "," "\"mode\":\"" + _jso... back to the caller.
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
