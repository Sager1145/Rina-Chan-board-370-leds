import math
import random
import time
from board import (
    COLS, ROWS, np, clear, show, logical_to_led_index,
    scale_color, wheel, hsv_to_rgb,
)
DEFAULT_DEMO_INTERVAL_MS = 5000
FPS = 30
FRAME_MS = 1000 // FPS
_ALL_COORDS = []
_ALL_COLUMNS = []
for y in range(ROWS):
    for x in range(COLS):
        idx = logical_to_led_index(x, y)
        if idx is not None:
            _ALL_COORDS.append((x, y, idx))
for x in range(COLS):
    col = []
    for y in range(ROWS):
        idx = logical_to_led_index(x, y)
        if idx is not None:
            col.append((x, y, idx))
    if col:
        _ALL_COLUMNS.append(col)
DEMO_NAMES = (
    "rgb",
    "fire",
    "hacker",
    "hello_world",
)
_FONT = {
    "A": [
        ".###.",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
    ],
    "D": [
        "####.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "####.",
    ],
    "E": [
        "#####",
        "#....",
        "#....",
        "####.",
        "#....",
        "#....",
        "#####",
    ],
    "H": [
        "#...#",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
    ],
    "L": [
        "#....",
        "#....",
        "#....",
        "#....",
        "#....",
        "#....",
        "#####",
    ],
    "O": [
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
    ],
    "R": [
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#.#..",
        "#..#.",
        "#...#",
    ],
    "W": [
        "#...#",
        "#...#",
        "#...#",
        "#.#.#",
        "#.#.#",
        "##.##",
        "#...#",
    ],
    " ": [
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
    ],
}
_TEXT = " HELLO WORLD "
_TEXT_H = 7
def _clear_all():
    clear(write=False)
def _glyph_rows(ch):
    return _FONT.get(ch, _FONT[" "])
def _build_text_columns(text):
    cols = []
    for i, ch in enumerate(text):
        rows = _glyph_rows(ch)
        w = len(rows[0])
        for x in range(w):
            col = []
            for y in range(_TEXT_H):
                col.append(rows[y][x])
            cols.append(col)
        if i != len(text) - 1:
            cols.append(["."] * _TEXT_H)
    return cols
_TEXT_COLS = _build_text_columns(_TEXT)
_TEXT_WIDTH = len(_TEXT_COLS)
class DemoController:
    __slots__ = (
        "enabled",
        "demo_index",
        "demo_started_ms",
        "last_frame_ms",
        "coords",
        "name",
        "columns",
        "fire_heat",
        "hacker_heads",
        "hacker_speeds",
        "hacker_brightness_bias",
        "hacker_last_step_ms",
        "auto_enabled",
        "interval_ms",
    )
    def __init__(self):
        self.enabled = False
        self.demo_index = 0
        self.demo_started_ms = 0
        self.last_frame_ms = 0
        self.coords = _ALL_COORDS
        self.columns = _ALL_COLUMNS
        self.name = ""
        self.fire_heat = []
        self.hacker_heads = []
        self.hacker_speeds = []
        self.hacker_brightness_bias = []
        self.hacker_last_step_ms = 0
        self.auto_enabled = True
        self.interval_ms = DEFAULT_DEMO_INTERVAL_MS
        self._reset_demo_state()
    def _reset_demo_state(self):
        self.fire_heat = []
        for col in self.columns:
            self.fire_heat.append([0] * len(col))
        self.hacker_heads = []
        self.hacker_speeds = []
        self.hacker_brightness_bias = []
        for col in self.columns:
            length = len(col)
            self.hacker_heads.append(-random.randrange(length + 4))
            self.hacker_speeds.append(1 + random.randrange(3))
            self.hacker_brightness_bias.append(110 + random.randrange(100))
        self.hacker_last_step_ms = 0
    def enter(self):
        self.enabled = True
        self.demo_index = 0
        self.demo_started_ms = time.ticks_ms()
        self.last_frame_ms = 0
        self._reset_demo_state()
        self.name = self.demo_name()
        _clear_all()
        show()
    def exit(self):
        self.enabled = False
        _clear_all()
        show()
    def toggle(self):
        if self.enabled:
            self.exit()
            return False
        self.enter()
        return True
    def demo_name(self):
        return DEMO_NAMES[self.demo_index % len(DEMO_NAMES)]
    def set_interval_ms(self, interval_ms):
        if interval_ms < 500:
            interval_ms = 500
        self.interval_ms = int(interval_ms)
    def set_auto(self, enabled):
        self.auto_enabled = bool(enabled)
    def next_demo(self, now_ms=None):
        if now_ms is None:
            now_ms = time.ticks_ms()
        self._advance_demo(now_ms)
    def prev_demo(self, now_ms=None):
        if now_ms is None:
            now_ms = time.ticks_ms()
        self.demo_index = (self.demo_index - 1) % len(DEMO_NAMES)
        self.demo_started_ms = now_ms
        self.last_frame_ms = 0
        self._reset_demo_state()
        self.name = self.demo_name()
        _clear_all()
        show()
    def refresh_timer(self, now_ms=None):
        if now_ms is None:
            now_ms = time.ticks_ms()
        self.demo_started_ms = now_ms
    def _advance_demo(self, now_ms):
        self.demo_index = (self.demo_index + 1) % len(DEMO_NAMES)
        self.demo_started_ms = now_ms
        self.last_frame_ms = 0
        self._reset_demo_state()
        self.name = self.demo_name()
        _clear_all()
        show()
    def force_render(self, now_ms=None):
        self.render(now_ms=now_ms, force=True)
    def render(self, now_ms=None, force=False):
        if not self.enabled:
            return
        if now_ms is None:
            now_ms = time.ticks_ms()
        if self.auto_enabled and time.ticks_diff(now_ms, self.demo_started_ms) >= self.interval_ms:
            self._advance_demo(now_ms)
        if (not force and self.last_frame_ms and
                time.ticks_diff(now_ms, self.last_frame_ms) < FRAME_MS):
            return
        if self.last_frame_ms:
            dt_ms = time.ticks_diff(now_ms, self.last_frame_ms)
        else:
            dt_ms = FRAME_MS
        self.last_frame_ms = now_ms
        t = time.ticks_diff(now_ms, self.demo_started_ms) / 1000.0
        dt = dt_ms / 1000.0
        if self.demo_index == 0:
            self._rgb(t)
        elif self.demo_index == 1:
            self._fire(dt)
        elif self.demo_index == 2:
            self._hacker(now_ms)
        else:
            self._hello_world(now_ms)
        show()
    def _rgb(self, t):
        _clear_all()
        for x, y, idx in self.coords:
            band = 0.5 + 0.5 * math.sin((x * 0.48) + (y * 0.31) + t * 2.4)
            if band < 0.52:
                continue
            hue = (x * 9 + y * 5 + int(t * 70)) & 255
            v = 0.18 + 0.82 * ((band - 0.52) / 0.48)
            np[idx] = scale_color(hsv_to_rgb(hue / 255.0, 1.0, v))
    def _fire_color(self, heat):
        if heat <= 0:
            return (0, 0, 0)
        if heat < 85:
            return (heat * 3, 0, 0)
        if heat < 170:
            h = heat - 85
            return (255, h * 2, 0)
        h = heat - 170
        return (255, 170 + h, h * 2)
    def _fire(self, dt):
        _clear_all()
        for col_index, col in enumerate(self.columns):
            heat = self.fire_heat[col_index]
            n = len(heat)
            if n <= 0:
                continue
            cool_scale = 2 + int(dt * 70)
            for i in range(n):
                cooldown = random.randrange(cool_scale + 1)
                v = heat[i] - cooldown
                if v < 0:
                    v = 0
                heat[i] = v
            for i in range(0, n - 1):
                below = heat[i + 1]
                below2 = heat[i + 2] if (i + 2) < n else below
                heat[i] = (below + below2 + below2) // 3
            for _ in range(1 + random.randrange(2)):
                j = n - 1 - random.randrange(1 if n < 3 else 3)
                spark = 160 + random.randrange(96)
                v = heat[j] + spark
                if v > 255:
                    v = 255
                heat[j] = v
            for i in range(n):
                x, y, idx = col[i]
                temp = heat[i]
                if temp < 90:
                    continue
                np[idx] = scale_color(self._fire_color(temp))
    def _hacker(self, now_ms):
        _clear_all()
        if (self.hacker_last_step_ms == 0 or
                time.ticks_diff(now_ms, self.hacker_last_step_ms) >= 95):
            self.hacker_last_step_ms = now_ms
            for i, col in enumerate(self.columns):
                n = len(col)
                self.hacker_heads[i] += self.hacker_speeds[i]
                if self.hacker_heads[i] >= n + 6:
                    self.hacker_heads[i] = -random.randrange(3, n + 4)
                    self.hacker_speeds[i] = 1 + random.randrange(3)
                    self.hacker_brightness_bias[i] = 110 + random.randrange(100)
        pulse = 0.72 + 0.28 * (0.5 + 0.5 * math.sin(now_ms / 700.0))
        for i, col in enumerate(self.columns):
            n = len(col)
            head = self.hacker_heads[i]
            bias = self.hacker_brightness_bias[i]
            for row_i in range(n):
                tail = head - row_i
                if tail < 0 or tail > 7:
                    continue
                x, y, idx = col[row_i]
                if tail == 0:
                    c = (bias, 255, bias)
                elif tail == 1:
                    c = (80, 220, 80)
                else:
                    level = int((8 - tail) * 18 * pulse)
                    c = (0, level + 8, 0)
                np[idx] = scale_color(c)
        count = len(self.coords)
        for _ in range(4):
            _, _, idx = self.coords[random.randrange(count)]
            r, g, b = np[idx]
            if g < 40:
                np[idx] = scale_color((0, 24 + random.randrange(32), 0))
    def _hello_world(self, now_ms):
        _clear_all()
        elapsed = time.ticks_diff(now_ms, self.demo_started_ms)
        interval = self.interval_ms if self.interval_ms > 0 else DEFAULT_DEMO_INTERVAL_MS
        progress = elapsed / float(interval)
        if progress < 0.0:
            progress = 0.0
        if progress > 1.0:
            progress = 1.0
        start_x = COLS
        end_x = -_TEXT_WIDTH
        scroll_x = int(round(start_x + (end_x - start_x) * progress))
        y0 = (ROWS - _TEXT_H) // 2
        hue_base = (elapsed * 255) // interval
        lit_count = 0
        for src_x, col in enumerate(_TEXT_COLS):
            px = scroll_x + src_x
            if px < 0 or px >= COLS:
                continue
            for gy in range(_TEXT_H):
                if col[gy] != "#":
                    continue
                py = y0 + gy
                idx = logical_to_led_index(px, py)
                if idx is None:
                    continue
                hue = (hue_base + src_x * 5 + gy * 7) & 255
                r, g, b = wheel(hue)
                np[idx] = scale_color((int(r * 0.85), int(g * 0.85), int(b * 0.85)))
                lit_count += 1
        if lit_count < 8:
            px = scroll_x - 1
            py = y0 + (_TEXT_H // 2)
            idx = logical_to_led_index(px, py)
            if idx is not None:
                np[idx] = scale_color((40, 40, 80))
DEMOS = DemoController()
