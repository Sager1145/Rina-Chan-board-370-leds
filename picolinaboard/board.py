# ---------------------------------------------------------------------------
# board.py
#
# Shared board configuration and drawing primitives for the LED matrix.
# This file defines:
# - hardware pin / LED count
# - matrix geometry and coordinate mapping
# - brightness limiting
# - common color helpers
# - drawing helpers for bitmaps and pixel grids
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# MicroPython hardware imports:
# - Pin: GPIO control
# - NeoPixel: WS2812B LED strip control
# - time: timing / sleep helpers
# ---------------------------------------------------------------------------
from machine import Pin
from neopixel import NeoPixel
import time

# ---------------------------------------------------------------------------
# Hardware configuration.
# LED_PIN is the Pico GPIO used for WS2812B data.
# NUM_LEDS is the total number of LEDs in the matrix.
# ---------------------------------------------------------------------------
LED_PIN = 15
NUM_LEDS = 370

# ---------------------------------------------------------------------------
# Animation timing defaults.
# TARGET_FPS is the intended frame rate.
# FRAME_TIME_S and FRAME_TIME_MS are derived helpers.
# ---------------------------------------------------------------------------
TARGET_FPS = 60
FRAME_TIME_S = 1.0 / TARGET_FPS
FRAME_TIME_MS = 1000.0 / TARGET_FPS

# ---------------------------------------------------------------------------
# Runtime brightness cap.
#
# The UI uses 10..100 to represent brightness steps, and that number is used
# directly as the maximum allowed per-channel LED value.
#
# Example:
# - 50% -> cap each channel to at most 50
# - 100% -> cap each channel to at most 100
#
# HARD_CAP is the absolute ceiling.
# FLOOR is the minimum allowed value.
# DEFAULT is the boot-time default.
# MAX_BRIGHTNESS is the current runtime brightness cap.
# ---------------------------------------------------------------------------
MAX_BRIGHTNESS_HARD_CAP = 100
MAX_BRIGHTNESS_FLOOR = 10
MAX_BRIGHTNESS_DEFAULT = 50
MAX_BRIGHTNESS = MAX_BRIGHTNESS_DEFAULT


# ---------------------------------------------------------------------------
# Set the runtime brightness cap.
# The value is clamped into the allowed range [FLOOR, HARD_CAP].
# Returns the final applied value.
# ---------------------------------------------------------------------------
def set_max_brightness(value):
    global MAX_BRIGHTNESS
    if value < MAX_BRIGHTNESS_FLOOR:
        value = MAX_BRIGHTNESS_FLOOR
    elif value > MAX_BRIGHTNESS_HARD_CAP:
        value = MAX_BRIGHTNESS_HARD_CAP
    MAX_BRIGHTNESS = value
    return MAX_BRIGHTNESS


# ---------------------------------------------------------------------------
# Read the current runtime brightness cap.
# ---------------------------------------------------------------------------
def get_max_brightness():
    return MAX_BRIGHTNESS


# ---------------------------------------------------------------------------
# Geometry definition of the irregular 18-row matrix.
#
# Each row has a specific number of physical LEDs. The widest row is 22 LEDs.
# Rows are centered inside a virtual 22-column grid so drawing code can use
# simple (x, y) coordinates.
# ---------------------------------------------------------------------------
ROW_LENGTHS = [
    18,
    20, 20, 20,
    22, 22, 22, 22, 22, 22, 22, 22, 22,
    20, 20, 20,
    18,
    16,
]

# ---------------------------------------------------------------------------
# Convenience geometry constants.
# ROWS = number of rows
# COLS = width of the virtual logical grid
# ---------------------------------------------------------------------------
ROWS = len(ROW_LENGTHS)
COLS = max(ROW_LENGTHS)

# ---------------------------------------------------------------------------
# Orientation / wiring flags.
#
# SERPENTINE:
#   True means odd rows are wired in reverse order.
# FLIP_X / FLIP_Y:
#   Optional logical flips if the display is mounted differently.
# ---------------------------------------------------------------------------
SERPENTINE = True
FLIP_X = False
FLIP_Y = False

# ---------------------------------------------------------------------------
# Precompute the starting strip index for each row.
#
# Example:
# - ROW_STARTS[y] gives the first physical LED index of row y.
# This makes logical-to-physical coordinate mapping much faster.
# ---------------------------------------------------------------------------
ROW_STARTS = []
_acc = 0
for _w in ROW_LENGTHS:
    ROW_STARTS.append(_acc)
    _acc += _w

# ---------------------------------------------------------------------------
# Safety check: the row lengths must add up exactly to the LED count.
# ---------------------------------------------------------------------------
assert _acc == NUM_LEDS, "ROW_LENGTHS must sum to NUM_LEDS"

# ---------------------------------------------------------------------------
# Create the single global NeoPixel object used by the whole project.
# ---------------------------------------------------------------------------
np = NeoPixel(Pin(LED_PIN, Pin.OUT), NUM_LEDS)


# ---------------------------------------------------------------------------
# Frame pacing helper.
#
# This class regulates rendering speed to approximately TARGET_FPS.
# Call tick() once per frame to sleep for the remaining frame budget.
# ---------------------------------------------------------------------------
class FramePacer:
    """Frame-rate regulator. Call tick() once per frame."""

    __slots__ = ("_fps", "_frame_ms", "_start", "_next")

    # -----------------------------------------------------------------------
    # Initialize the pacer.
    # If ticks_ms is available, the pacer uses precise millisecond timing.
    # Otherwise it falls back to sleep-based pacing only.
    # -----------------------------------------------------------------------
    def __init__(self, fps=TARGET_FPS):
        self._fps = fps
        self._frame_ms = 1000.0 / fps
        if hasattr(time, "ticks_ms"):
            self._start = time.ticks_ms()
            self._next = self._start + int(self._frame_ms)
        else:
            self._start = None
            self._next = None

    # -----------------------------------------------------------------------
    # Wait until the next frame boundary.
    # -----------------------------------------------------------------------
    def tick(self):
        if self._next is None:
            time.sleep(1.0 / self._fps)
            return

        now = time.ticks_ms()
        remaining = time.ticks_diff(self._next, now)
        if remaining > 0:
            time.sleep(remaining / 1000.0)

        self._next = (
            time.ticks_add(self._next, int(self._frame_ms))
            if hasattr(time, "ticks_add")
            else self._next + int(self._frame_ms)
        )

    # -----------------------------------------------------------------------
    # Return elapsed time since construction, in seconds.
    # -----------------------------------------------------------------------
    def elapsed_s(self):
        if self._start is None:
            return 0.0
        return time.ticks_diff(time.ticks_ms(), self._start) / 1000.0

    # -----------------------------------------------------------------------
    # Return True if the specified duration has elapsed.
    # -----------------------------------------------------------------------
    def done(self, duration_s):
        if duration_s is None or self._start is None:
            return False
        return time.ticks_diff(time.ticks_ms(), self._start) >= duration_s * 1000


# ---------------------------------------------------------------------------
# Color helper: clamp a color to the current brightness cap.
#
# Instead of clipping only the channel that exceeds the cap, this scales the
# whole RGB tuple uniformly. That preserves hue better.
# ---------------------------------------------------------------------------
def scale_color(rgb):
    r, g, b = rgb
    m = max(r, g, b)
    cap = MAX_BRIGHTNESS

    if m <= cap:
        return (
            max(0, min(255, r)),
            max(0, min(255, g)),
            max(0, min(255, b)),
        )

    s = cap / m
    return (int(r * s), int(g * s), int(b * s))


# ---------------------------------------------------------------------------
# Adafruit-style color wheel helper.
# Maps pos in [0,255] to a rainbow RGB color.
# ---------------------------------------------------------------------------
def wheel(pos):
    pos = pos & 0xFF
    if pos < 85:
        return (255 - pos * 3, pos * 3, 0)
    if pos < 170:
        pos -= 85
        return (0, 255 - pos * 3, pos * 3)
    pos -= 170
    return (pos * 3, 0, 255 - pos * 3)


# ---------------------------------------------------------------------------
# Convert HSV in [0,1] ranges into RGB in [0,255].
# Output is not brightness-capped yet.
# ---------------------------------------------------------------------------
def hsv_to_rgb(h, s, v):
    if s <= 0.0:
        x = int(v * 255)
        return (x, x, x)

    i = int(h * 6.0)
    f = h * 6.0 - i
    p = int(255 * v * (1.0 - s))
    q = int(255 * v * (1.0 - s * f))
    t = int(255 * v * (1.0 - s * (1.0 - f)))
    v = int(255 * v)
    i %= 6

    if i == 0:
        return (v, t, p)
    if i == 1:
        return (q, v, p)
    if i == 2:
        return (p, v, t)
    if i == 3:
        return (p, q, v)
    if i == 4:
        return (t, p, v)
    return (v, p, q)


# ---------------------------------------------------------------------------
# Map a logical (x, y) coordinate in the virtual 22x18 grid to a physical
# LED strip index. Returns None if the coordinate lies outside the shaped
# matrix for that row.
# ---------------------------------------------------------------------------
def logical_to_led_index(x, y):
    # Reject out-of-bounds coordinates.
    if x < 0 or x >= COLS or y < 0 or y >= ROWS:
        return None

    # Apply optional logical flips.
    if FLIP_X:
        x = COLS - 1 - x
    if FLIP_Y:
        y = ROWS - 1 - y

    # Compute the valid x-range for this row.
    row_width = ROW_LENGTHS[y]
    left_pad = (COLS - row_width) // 2

    # Reject coordinates that fall into padded empty space.
    if x < left_pad or x >= left_pad + row_width:
        return None

    # Convert logical x into row-local x.
    local_x = x - left_pad

    # Reverse odd rows if the strip is serpentine-wired.
    if SERPENTINE and (y % 2 == 1):
        local_x = row_width - 1 - local_x

    # Return the final physical strip index.
    return ROW_STARTS[y] + local_x


# ---------------------------------------------------------------------------
# Clear the entire LED strip to black.
# If write=True, send the cleared frame to the LEDs immediately.
# ---------------------------------------------------------------------------
def clear(write=False):
    off = (0, 0, 0)
    for i in range(NUM_LEDS):
        np[i] = off
    if write:
        np.write()


# ---------------------------------------------------------------------------
# Push the current pixel buffer to the LEDs.
# ---------------------------------------------------------------------------
def show():
    np.write()


# ---------------------------------------------------------------------------
# Set one logical pixel to a color, after brightness scaling.
# If the logical coordinate does not map to a physical LED, do nothing.
# ---------------------------------------------------------------------------
def set_pixel(x, y, rgb):
    idx = logical_to_led_index(x, y)
    if idx is None:
        return
    np[idx] = scale_color(rgb)


# ---------------------------------------------------------------------------
# Fill the entire physical strip with one color.
# ---------------------------------------------------------------------------
def fill(rgb):
    c = scale_color(rgb)
    for i in range(NUM_LEDS):
        np[i] = c


# ---------------------------------------------------------------------------
# Fill all valid logical pixels with one color.
# This skips padded logical positions that do not correspond to a real LED.
# ---------------------------------------------------------------------------
def fill_logical(rgb):
    c = scale_color(rgb)
    for y in range(ROWS):
        for x in range(COLS):
            idx = logical_to_led_index(x, y)
            if idx is not None:
                np[idx] = c


# ---------------------------------------------------------------------------
# Linear interpolation between numeric values a and b.
# t=0 returns a, t=1 returns b.
# ---------------------------------------------------------------------------
def lerp(a, b, t):
    if t <= 0.0:
        return a
    if t >= 1.0:
        return b
    return a + (b - a) * t


# ---------------------------------------------------------------------------
# Blend two RGB colors linearly by parameter t.
# ---------------------------------------------------------------------------
def blend(c1, c2, t):
    if t <= 0.0:
        return c1
    if t >= 1.0:
        return c2
    return (
        int(c1[0] + (c2[0] - c1[0]) * t),
        int(c1[1] + (c2[1] - c1[1]) * t),
        int(c1[2] + (c2[2] - c1[2]) * t),
    )


# ---------------------------------------------------------------------------
# Dim an RGB color by a scalar factor.
# factor <= 0 produces black.
# factor >= 1 returns the original color.
# ---------------------------------------------------------------------------
def dim(rgb, factor):
    if factor <= 0.0:
        return (0, 0, 0)
    if factor >= 1.0:
        return rgb
    return (
        int(rgb[0] * factor),
        int(rgb[1] * factor),
        int(rgb[2] * factor),
    )


# ---------------------------------------------------------------------------
# Apply gamma correction to an RGB tuple.
# Useful if a perceptually smoother brightness response is needed.
# ---------------------------------------------------------------------------
def gamma_correct(rgb, gamma=2.2):
    r, g, b = rgb
    return (
        int(((r / 255) ** gamma) * 255),
        int(((g / 255) ** gamma) * 255),
        int(((b / 255) ** gamma) * 255),
    )


# ---------------------------------------------------------------------------
# Compute a radial falloff factor for a point (x, y).
# Returns a value in [0,1], where the center is brightest and the edge is 0.
# ---------------------------------------------------------------------------
def radial_factor(x, y, cx=None, cy=None, radius=None):
    if cx is None:
        cx = (COLS - 1) / 2.0
    if cy is None:
        cy = (ROWS - 1) / 2.0
    if radius is None:
        radius = (cx * cx + cy * cy) ** 0.5

    dx = x - cx
    dy = y - cy
    d = (dx * dx + dy * dy) ** 0.5

    if d >= radius:
        return 0.0
    return 1.0 - (d / radius)


# ---------------------------------------------------------------------------
# Render an ASCII-art bitmap to the display.
#
# Characters:
# - '#' -> on_color
# - '+' -> dim_color
# - anything else -> off_color
# ---------------------------------------------------------------------------
def draw_bitmap(bitmap, on_color=(66, 0, 36), dim_color=(24, 0, 14),
                off_color=(0, 0, 0), do_show=True):
    on_c = scale_color(on_color)
    dim_c = scale_color(dim_color)
    off_c = scale_color(off_color)

    clear()

    for y, row in enumerate(bitmap):
        if y >= ROWS:
            break
        for x, ch in enumerate(row):
            if x >= COLS:
                break
            idx = logical_to_led_index(x, y)
            if idx is None:
                continue

            if ch == "#":
                np[idx] = on_c
            elif ch == "+":
                np[idx] = dim_c
            else:
                np[idx] = off_c

    if do_show:
        np.write()


# ---------------------------------------------------------------------------
# Blend between two ASCII-art bitmaps.
# Each cell color is looked up from bitmap_a and bitmap_b, then blended by t.
# ---------------------------------------------------------------------------
def draw_bitmap_blend(bitmap_a, bitmap_b, t, on_color=(66, 0, 36),
                      dim_color=(24, 0, 14), off_color=(0, 0, 0),
                      do_show=True):
    on_c = scale_color(on_color)
    dim_c = scale_color(dim_color)
    off_c = scale_color(off_color)

    # -----------------------------------------------------------------------
    # Helper to convert one bitmap cell into a concrete RGB color.
    # -----------------------------------------------------------------------
    def cell_color(bitmap, y, x):
        if y >= len(bitmap):
            return off_c
        row = bitmap[y]
        if x >= len(row):
            return off_c

        ch = row[x]
        if ch == "#":
            return on_c
        if ch == "+":
            return dim_c
        return off_c

    clear()

    for y in range(ROWS):
        for x in range(COLS):
            idx = logical_to_led_index(x, y)
            if idx is None:
                continue
            ca = cell_color(bitmap_a, y, x)
            cb = cell_color(bitmap_b, y, x)
            np[idx] = blend(ca, cb, t)

    if do_show:
        np.write()


# ---------------------------------------------------------------------------
# Draw a grid of symbolic keys using a palette dictionary.
#
# grid:
#   2D array of keys
# palette:
#   dict mapping each key to an RGB color
# Missing keys default to off/black.
# ---------------------------------------------------------------------------
def draw_pixel_grid(grid, palette, do_show=True):
    off_c = (0, 0, 0)
    clear()

    for y, row in enumerate(grid):
        if y >= ROWS:
            break
        for x, key in enumerate(row):
            if x >= COLS:
                break
            idx = logical_to_led_index(x, y)
            if idx is None:
                continue
            col = palette.get(key, off_c)
            np[idx] = scale_color(col)

    if do_show:
        np.write()