# ---------------------------------------------------------------------------
# badapple_mode.py
#
# Runtime player for the split, compressed Bad Apple files.
#
# Design goals:
# - load only one video segment at a time to save RAM
# - free the previous segment before loading the next one
# - keep playback centered on the shaped 22x18 matrix
# - allow the main app to pause overlays, resync timing, and exit cleanly
# ---------------------------------------------------------------------------

import gc
import sys
import time

import board
from board import COLS, ROWS, np, show, clear, logical_to_led_index, scale_color
from config import BADAPPLE_PART_MODULES, BADAPPLE_ON_COLOR, BADAPPLE_OFF_COLOR


def _rle_decode(src, raw_len):
    # -----------------------------------------------------------------------
    # Decode the custom RLE format produced by converter.py.
    #
    # ctrl < 128  -> literal run of ctrl+1 bytes
    # ctrl >= 128 -> repeated-byte run of ctrl-127 bytes
    # -----------------------------------------------------------------------
    out = bytearray(raw_len)
    si = 0
    oi = 0
    n = len(src)
    while si < n and oi < raw_len:
        ctrl = src[si]
        si += 1
        if ctrl < 128:
            ln = ctrl + 1
            out[oi:oi + ln] = src[si:si + ln]
            si += ln
            oi += ln
        else:
            ln = ctrl - 127
            b = src[si]
            si += 1
            out[oi:oi + ln] = bytes((b,)) * ln
            oi += ln
    if oi != raw_len:
        raise ValueError("decode length mismatch")
    return out


class SplitBadApplePlayer:
    # -----------------------------------------------------------------------
    # One in-memory video segment player.
    #
    # data holds the decoded bytes for the current part only.
    # part_index / frame_index track where playback is.
    # next_frame_ms implements non-blocking frame timing.
    # -----------------------------------------------------------------------
    __slots__ = (
        "loop", "enabled", "part_index", "frame_index", "data",
        "fps", "width", "height", "frame_bytes", "frames_count",
        "frame_period_ms", "next_frame_ms", "x_offset", "y_offset",
        "_last_error",
    )

    def __init__(self, loop=True):
        self.loop = bool(loop)
        self.enabled = False
        self.part_index = 0
        self.frame_index = 0
        self.data = b""
        self.fps = 10
        self.width = 20
        self.height = 15
        self.frame_bytes = 38
        self.frames_count = 0
        self.frame_period_ms = 100
        self.next_frame_ms = 0
        self.x_offset = 0
        self.y_offset = 0
        self._last_error = None

    def last_error(self):
        # Return the most recent startup / loading error string.
        return self._last_error

    def _set_error(self, message):
        # Record and print the error so USB serial can show it immediately.
        self._last_error = message
        print(message)

    def _drop_current_part(self):
        # Clear the currently loaded part and force a garbage collection pass.
        self.data = b""
        self.frames_count = 0
        self.frame_index = 0
        gc.collect()

    def _load_part(self, part_index):
        # -------------------------------------------------------------------
        # Import one generated badapple_partX module, decode it into RAM,
        # compute playback geometry, then unload the module object again.
        # -------------------------------------------------------------------
        self._drop_current_part()
        name = BADAPPLE_PART_MODULES[part_index]
        gc.collect()
        mod = __import__(name)
        try:
            self.part_index = part_index
            self.fps = int(mod.FPS)
            self.width = int(mod.WIDTH)
            self.height = int(mod.HEIGHT)
            self.frame_bytes = int(mod.FRAME_BYTES)
            self.frames_count = int(mod.FRAMES_COUNT)
            self.data = _rle_decode(mod.DATA, int(mod.RAW_BYTES))
            self.frame_period_ms = max(1, 1000 // max(1, self.fps))
            self.x_offset = max(0, (COLS - self.width) // 2)
            self.y_offset = max(0, (ROWS - self.height) // 2)
            if len(self.data) != self.frames_count * self.frame_bytes:
                raise ValueError("packed data length mismatch")
        finally:
            if name in sys.modules:
                del sys.modules[name]
            del mod
            gc.collect()

    def _advance_part(self):
        # Move to the next segment, or loop back to part 0 if enabled.
        nxt = self.part_index + 1
        if nxt >= len(BADAPPLE_PART_MODULES):
            if not self.loop:
                self.enabled = False
                return False
            nxt = 0
        self._load_part(nxt)
        return True

    def _draw_frame_from_current_data(self, frame_index=None):
        # -------------------------------------------------------------------
        # Draw one decoded frame from the currently loaded part.
        # Each pixel is read from the packed 1-bit frame bytes and mapped into
        # the centered logical rectangle inside the 22x18 matrix.
        # -------------------------------------------------------------------
        fi = self.frame_index if frame_index is None else frame_index
        start = fi * self.frame_bytes
        on_color = scale_color(BADAPPLE_ON_COLOR)
        off_color = scale_color(BADAPPLE_OFF_COLOR)
        bit = 0
        for y in range(self.height):
            py = y + self.y_offset
            for x in range(self.width):
                idx = logical_to_led_index(x + self.x_offset, py)
                on = self.data[start + (bit >> 3)] & (1 << (7 - (bit & 7)))
                if idx is not None:
                    np[idx] = on_color if on else off_color
                bit += 1
        show()

    def enter(self):
        # -------------------------------------------------------------------
        # Start playback from the beginning.
        # Returns True on success, False if loading failed.
        # -------------------------------------------------------------------
        self._last_error = None
        try:
            self.enabled = True
            self._load_part(0)
            clear(True)
            self._draw_frame_from_current_data(0)
            self.next_frame_ms = time.ticks_add(time.ticks_ms(), self.frame_period_ms)
            return True
        except Exception as e:
            self.enabled = False
            self._set_error("badapple start failed: {}".format(e))
            clear(True)
            return False

    def exit(self):
        # Stop playback and release currently loaded part memory.
        self.enabled = False
        self._drop_current_part()
        clear(True)

    def redraw_current(self):
        # Redraw the current frame after an overlay or brightness change.
        if not self.enabled or not self.data or self.frames_count <= 0:
            return
        if self.frame_index >= self.frames_count:
            self.frame_index = self.frames_count - 1
        self._draw_frame_from_current_data(self.frame_index)

    def resync(self, now_ms):
        # -------------------------------------------------------------------
        # After a blocking overlay, realign the next frame deadline to "now"
        # so playback continues smoothly instead of trying to catch up.
        # -------------------------------------------------------------------
        self.next_frame_ms = time.ticks_add(now_ms, self.frame_period_ms)

    def _advance_one_frame(self):
        # Advance within the current segment or move to the next segment.
        self.frame_index += 1
        if self.frame_index < self.frames_count:
            return True
        return self._advance_part()

    def play_step(self):
        # -------------------------------------------------------------------
        # Non-blocking playback step.
        # main.py calls this every loop tick. If the frame deadline has not
        # been reached yet, nothing is drawn. If we are late, multiple frame
        # deadlines may be consumed, but only the newest frame gets rendered.
        # -------------------------------------------------------------------
        if not self.enabled:
            return False
        now = time.ticks_ms()
        if time.ticks_diff(now, self.next_frame_ms) < 0:
            return True

        needs_draw = False
        while time.ticks_diff(now, self.next_frame_ms) >= 0:
            if not self._advance_one_frame():
                return False
            self.next_frame_ms = time.ticks_add(self.next_frame_ms, self.frame_period_ms)
            needs_draw = True

        if needs_draw:
            self._draw_frame_from_current_data(self.frame_index)
        return True


# Single shared player instance used by main.py.
PLAYER = SplitBadApplePlayer(loop=False)
