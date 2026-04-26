# ---------------------------------------------------------------------------
# unity_module.py
#
# Unity media / timeline playback module.
# Handles timeline loading (begin + chunk), playback, preview, and stop.
# Extracted from webui_runtime.py for modular architecture.
# ---------------------------------------------------------------------------

import time


MAX_TIMELINE_FRAMES = 800
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


def _clean_text(value, limit=48):
    s = str(value or "")
    s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ").replace("|", " ")
    return s[:limit]


def _json_escape(value):
    s = str(value or "")
    s = s.replace('\\', '\\\\').replace('"', '\\"')
    s = s.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
    return s


class UnityModule:
    """Manages Unity timeline loading, playback, and preview."""

    __slots__ = (
        "proto",
        "timeline", "timeline_expected", "timeline_last_frame",
        "timeline_fps", "timeline_loop", "timeline_name",
        "timeline_playing", "timeline_started_ms", "timeline_last_index",
        "timeline_loaded_ms", "active_flag",
        # Callbacks
        "_on_prepare", "_on_stop_done",
    )

    def __init__(self):
        self.proto = None
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
        self.active_flag = False
        self._on_prepare = None
        self._on_stop_done = None

    def set_protocol(self, proto):
        self.proto = proto

    # ------------------------------------------------------------------
    # Query
    # ------------------------------------------------------------------
    def active(self):
        return self.active_flag

    # ------------------------------------------------------------------
    # Timeline loading
    # ------------------------------------------------------------------
    def begin(self, fps=30, last_frame=0, loop=False, expected=0, name=""):
        """Initialize a new timeline (clears old data)."""
        self.stop(redraw=False)
        if self._on_prepare:
            self._on_prepare()
        try:
            fps = int(fps)
        except Exception:
            fps = 30
        fps = max(1, min(60, fps))
        try:
            last_frame = int(last_frame)
        except Exception:
            last_frame = 0
        try:
            expected = int(expected)
        except Exception:
            expected = 0
        self.active_flag = True
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
        print("unity module: timeline begin fps={} last={} expected={} loop={} name={}".format(
            fps, self.timeline_last_frame, expected, self.timeline_loop, self.timeline_name))

    def add_chunk(self, chunk):
        """Add timeline frames from a chunk string: 'frame,HEX;frame,HEX;...'"""
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

    # ------------------------------------------------------------------
    # Playback
    # ------------------------------------------------------------------
    def play(self):
        """Start playing the loaded timeline."""
        if not self.timeline:
            return False
        if self._on_prepare:
            self._on_prepare()
        self.active_flag = True
        self.timeline_playing = True
        self.timeline_started_ms = _ticks_ms()
        self.timeline_last_index = -1
        self._render_frame(0, force=True)
        print("unity module: timeline play frames={} last={} fps={} loop={}".format(
            len(self.timeline), self.timeline_last_frame,
            self.timeline_fps, self.timeline_loop))
        return True

    def preview(self, frame=0):
        """Show a single timeline frame without playing."""
        if not self.timeline:
            return False
        try:
            frame = int(frame)
        except Exception:
            frame = 0
        if self._on_prepare:
            self._on_prepare()
        self.active_flag = True
        self.timeline_playing = False
        self._render_frame(frame, force=True)
        return True

    # ------------------------------------------------------------------
    # Frame rendering
    # ------------------------------------------------------------------
    def _find_index(self, frame):
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
        if self.proto is not None and hasattr(self.proto, "update_physical_face_hex"):
            try:
                return self.proto.update_physical_face_hex(hx, notify=False)
            except TypeError:
                return self.proto.update_physical_face_hex(hx)
            except Exception as exc:
                print("unity module draw failed:", exc)
        return False

    def _render_frame(self, frame, force=False):
        idx = self._find_index(frame)
        if idx < 0:
            return False
        if not force and idx == self.timeline_last_index:
            return True
        self.timeline_last_index = idx
        self._draw_hex(self.timeline[idx][1])
        return True

    # ------------------------------------------------------------------
    # Service (called every tick from main loop)
    # ------------------------------------------------------------------
    def service(self):
        """Advance timeline playback if active."""
        if not self.active_flag or not self.timeline_playing:
            return
        now = _ticks_ms()
        elapsed_ms = _ticks_diff(now, self.timeline_started_ms)
        frame = int((elapsed_ms * self.timeline_fps) // 1000)
        if self.timeline_last_frame and frame > self.timeline_last_frame:
            if self.timeline_loop:
                self.timeline_started_ms = now
                self.timeline_last_index = -1
                frame = 0
            else:
                self.stop(redraw=True)
                return
        self._render_frame(frame, force=False)

    # ------------------------------------------------------------------
    # Stop / Clear
    # ------------------------------------------------------------------
    def stop(self, redraw=True):
        """Stop playback. Returns True if was active."""
        was_active = self.active_flag
        self.active_flag = False
        self.timeline_playing = False
        self.timeline_last_index = -1
        if was_active and redraw and self._on_stop_done:
            self._on_stop_done()
        return was_active

    def clear(self):
        """Stop and discard all timeline data."""
        self.stop(redraw=True)
        self.timeline = []
        self.timeline_expected = 0
        self.timeline_last_frame = 0
        self.timeline_name = ""

    # ------------------------------------------------------------------
    # Status JSON
    # ------------------------------------------------------------------
    def status_json(self):
        return ("{"
                "\"active\":" + ("true" if self.active_flag else "false") + ","
                "\"mode\":\"" + ("timeline" if self.active_flag else "idle") + "\","
                "\"timeline_name\":\"" + _json_escape(self.timeline_name) + "\","
                "\"timeline_frames\":" + str(len(self.timeline)) + ","
                "\"timeline_expected\":" + str(int(self.timeline_expected)) + ","
                "\"timeline_last_frame\":" + str(int(self.timeline_last_frame)) + ","
                "\"timeline_fps\":" + str(int(self.timeline_fps)) + ","
                "\"timeline_loop\":" + ("true" if self.timeline_loop else "false") + ","
                "\"timeline_playing\":" + ("true" if self.timeline_playing else "false") +
                "}")

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------
    def set_on_prepare(self, callback):
        """Called before timeline begins/plays (to clear overlays etc.)."""
        self._on_prepare = callback

    def set_on_stop_done(self, callback):
        """Called when playback stops and face should be redrawn."""
        self._on_stop_done = callback
