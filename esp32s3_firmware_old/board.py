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
# Import: Loads Pin from machine so this module can use that dependency.
from machine import Pin
# Import: Loads NeoPixel from neopixel so this module can use that dependency.
from neopixel import NeoPixel
# Import: Loads time so this module can use that dependency.
import time

# ---------------------------------------------------------------------------
# Timing helpers.
#
# MicroPython normally exposes ticks_ms()/sleep_ms() through time/utime.
# A previous build called board.sleep_ms() during the original boot-face
# animation, but this 370 LED board.py did not export that wrapper, causing
# boot to stop with: AttributeError: module object has no attribute sleep_ms.
# ---------------------------------------------------------------------------
# Function: Defines ticks_ms() to handle ticks ms behavior.
def ticks_ms():
    # Logic: Branches when hasattr(time, "ticks_ms") so the correct firmware path runs.
    if hasattr(time, "ticks_ms"):
        # Return: Sends the result returned by time.ticks_ms() back to the caller.
        return time.ticks_ms()
    # Return: Sends the result returned by int() back to the caller.
    return int(time.time() * 1000)


# Function: Defines sleep_ms(ms) to handle sleep ms behavior.
def sleep_ms(ms):
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: ms stores the result returned by int().
        ms = int(ms)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: ms stores the configured literal value.
        ms = 0
    # Logic: Branches when hasattr(time, "sleep_ms") so the correct firmware path runs.
    if hasattr(time, "sleep_ms"):
        # Expression: Calls time.sleep_ms() for its side effects.
        time.sleep_ms(ms)
    # Logic: Runs this fallback branch when the earlier condition did not match.
    else:
        # Expression: Calls time.sleep() for its side effects.
        time.sleep(ms / 1000.0)

# ---------------------------------------------------------------------------
# Hardware configuration.
# LED_PIN is the ESP32-S3 GPIO used for WS2812B data.
# NUM_LEDS is the total number of LEDs in the matrix.
# ---------------------------------------------------------------------------
# Variable: LED_PIN stores the configured literal value.
LED_PIN = 2
# Variable: NUM_LEDS stores the configured literal value.
NUM_LEDS = 370

# ---------------------------------------------------------------------------
# Animation timing defaults.
# TARGET_FPS is the intended frame rate.
# FRAME_TIME_S and FRAME_TIME_MS are derived helpers.
# ---------------------------------------------------------------------------
# Variable: TARGET_FPS stores the configured literal value.
TARGET_FPS = 60
# Variable: FRAME_TIME_S stores the calculated expression 1.0 / TARGET_FPS.
FRAME_TIME_S = 1.0 / TARGET_FPS
# Variable: FRAME_TIME_MS stores the calculated expression 1000.0 / TARGET_FPS.
FRAME_TIME_MS = 1000.0 / TARGET_FPS

# ---------------------------------------------------------------------------
# Runtime brightness cap.
#
# The UI uses a percent (5..100) in 5% steps. That percent is mapped into a
# raw per-channel LED cap by brightness_modes.effective_brightness() before
# being passed to set_max_brightness(). At 100% the cap is 170 (so the
# physical maximum the board ever drives is 170,170,170). Bad Apple and the
# matrix demo mode run at 1/3 of that cap.
#
# Example:
# - UI 100% -> cap each channel to at most 170
# - UI  50% -> cap each channel to at most  85
# - UI  30% -> cap each channel to at most  51
# - UI   5% -> cap each channel to at most   8
#
# HARD_CAP is the absolute ceiling (170).
# FLOOR is the minimum allowed value.
# DEFAULT is the boot-time default.
# MAX_BRIGHTNESS is the current runtime brightness cap.
# ---------------------------------------------------------------------------
# Variable: MAX_BRIGHTNESS_HARD_CAP stores the configured literal value.
MAX_BRIGHTNESS_HARD_CAP = 170
# Variable: MAX_BRIGHTNESS_FLOOR stores the configured literal value.
MAX_BRIGHTNESS_FLOOR = 1
# Variable: MAX_BRIGHTNESS_DEFAULT stores the configured literal value.
MAX_BRIGHTNESS_DEFAULT = 51  # 30% of 170, rounded
# Variable: MAX_BRIGHTNESS stores the current MAX_BRIGHTNESS_DEFAULT value.
MAX_BRIGHTNESS = MAX_BRIGHTNESS_DEFAULT


# ---------------------------------------------------------------------------
# Set the runtime brightness cap.
# The value is clamped into the allowed range [FLOOR, HARD_CAP].
# Returns the final applied value.
# ---------------------------------------------------------------------------
# Function: Defines set_max_brightness(value) to handle set max brightness behavior.
def set_max_brightness(value):
    # Variable: Marks MAX_BRIGHTNESS as module-level state modified here.
    global MAX_BRIGHTNESS
    # Logic: Branches when value < MAX_BRIGHTNESS_FLOOR so the correct firmware path runs.
    if value < MAX_BRIGHTNESS_FLOOR:
        # Variable: value stores the current MAX_BRIGHTNESS_FLOOR value.
        value = MAX_BRIGHTNESS_FLOOR
    # Logic: Branches when value > MAX_BRIGHTNESS_HARD_CAP so the correct firmware path runs.
    elif value > MAX_BRIGHTNESS_HARD_CAP:
        # Variable: value stores the current MAX_BRIGHTNESS_HARD_CAP value.
        value = MAX_BRIGHTNESS_HARD_CAP
    # Variable: MAX_BRIGHTNESS stores the current value value.
    MAX_BRIGHTNESS = value
    # Return: Sends the current MAX_BRIGHTNESS value back to the caller.
    return MAX_BRIGHTNESS


# ---------------------------------------------------------------------------
# Read the current runtime brightness cap.
# ---------------------------------------------------------------------------
# Function: Defines get_max_brightness() to handle get max brightness behavior.
def get_max_brightness():
    # Return: Sends the current MAX_BRIGHTNESS value back to the caller.
    return MAX_BRIGHTNESS


# ---------------------------------------------------------------------------
# Geometry definition of the irregular 18-row matrix.
#
# Each row has a specific number of physical LEDs. The widest row is 22 LEDs.
# Rows are centered inside a virtual 22-column grid so drawing code can use
# simple (x, y) coordinates.
# ---------------------------------------------------------------------------
# Variable: ROW_LENGTHS stores the collection of values used later in this module.
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
# Variable: ROWS stores the result returned by len().
ROWS = len(ROW_LENGTHS)
# Variable: COLS stores the result returned by max().
COLS = max(ROW_LENGTHS)

# ---------------------------------------------------------------------------
# Orientation / wiring flags.
#
# SERPENTINE:
#   True means odd rows are wired in reverse order.
# FLIP_X / FLIP_Y:
#   Optional logical flips if the display is mounted differently.
# ---------------------------------------------------------------------------
# Variable: SERPENTINE stores the enabled/disabled flag value.
SERPENTINE = True
# Variable: FLIP_X stores the enabled/disabled flag value.
FLIP_X = False
# Variable: FLIP_Y stores the enabled/disabled flag value.
FLIP_Y = False

# ---------------------------------------------------------------------------
# Precompute the starting strip index for each row.
#
# Example:
# - ROW_STARTS[y] gives the first physical LED index of row y.
# This makes logical-to-physical coordinate mapping much faster.
# ---------------------------------------------------------------------------
# Variable: ROW_STARTS stores the collection of values used later in this module.
ROW_STARTS = []
# Variable: _acc stores the configured literal value.
_acc = 0
# Loop: Iterates _w over ROW_LENGTHS so each item can be processed.
for _w in ROW_LENGTHS:
    # Expression: Calls ROW_STARTS.append() for its side effects.
    ROW_STARTS.append(_acc)
    # Variable: Updates _acc in place using the current _w value.
    _acc += _w

# ---------------------------------------------------------------------------
# Safety check: the row lengths must add up exactly to the LED count.
# ---------------------------------------------------------------------------
# Assertion: Verifies _acc == NUM_LEDS before continuing.
assert _acc == NUM_LEDS, "ROW_LENGTHS must sum to NUM_LEDS"

# ---------------------------------------------------------------------------
# Create the single global NeoPixel object used by the whole project.
# ---------------------------------------------------------------------------
# Variable: np stores the result returned by NeoPixel().
np = NeoPixel(Pin(LED_PIN, Pin.OUT), NUM_LEDS)

# ---------------------------------------------------------------------------
# Immediately flush one all-black frame to the strip.
#
# Creating NeoPixel reconfigures GPIO2 from its ESP32-S3 boot strapping
# state to RMT output mode.  That transition produces a brief pin glitch
# (HIGH → OUT-low → RMT-idle-high) which the TXS0108E level shifter
# faithfully amplifies to 5 V and passes to the WS2812 DIN line.  The
# LEDs can latch the transient as one frame of garbage before main.py's
# loop issues the first real np.write().
#
# Sending a reset + 370×(0,0,0) here forces all LEDs to black and
# discards whatever the RMT initialisation injected.
# ---------------------------------------------------------------------------
# Loop: Iterates _i over range(NUM_LEDS) so each item can be processed.
for _i in range(NUM_LEDS):
    # Variable: np[...] stores the collection of values used later in this module.
    np[_i] = (0, 0, 0)
# Expression: Calls np.write() for its side effects.
np.write()
# Cleanup: Deletes _i after it is no longer needed.
del _i


# ---------------------------------------------------------------------------
# Frame pacing helper.
#
# This class regulates rendering speed to approximately TARGET_FPS.
# Call tick() once per frame to sleep for the remaining frame budget.
# ---------------------------------------------------------------------------
# Class: Defines FramePacer as the state and behavior container for Frame Pacer.
class FramePacer:
    # Module: Documents the purpose of this scope.
    """Frame-rate regulator. Call tick() once per frame."""

    # Variable: __slots__ stores the collection of values used later in this module.
    __slots__ = ("_fps", "_frame_ms", "_start", "_next")

    # -----------------------------------------------------------------------
    # Initialize the pacer.
    # If ticks_ms is available, the pacer uses precise millisecond timing.
    # Otherwise it falls back to sleep-based pacing only.
    # -----------------------------------------------------------------------
    # Function: Defines __init__(self, fps) to handle init behavior.
    def __init__(self, fps=TARGET_FPS):
        # Variable: self._fps stores the current fps value.
        self._fps = fps
        # Variable: self._frame_ms stores the calculated expression 1000.0 / fps.
        self._frame_ms = 1000.0 / fps
        # Logic: Branches when hasattr(time, "ticks_ms") so the correct firmware path runs.
        if hasattr(time, "ticks_ms"):
            # Variable: self._start stores the result returned by time.ticks_ms().
            self._start = time.ticks_ms()
            # Variable: self._next stores the calculated expression self._start + int(self._frame_ms).
            self._next = self._start + int(self._frame_ms)
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: self._start stores the empty sentinel value.
            self._start = None
            # Variable: self._next stores the empty sentinel value.
            self._next = None

    # -----------------------------------------------------------------------
    # Wait until the next frame boundary.
    # -----------------------------------------------------------------------
    # Function: Defines tick(self) to handle tick behavior.
    def tick(self):
        # Logic: Branches when self._next is None so the correct firmware path runs.
        if self._next is None:
            # Expression: Calls time.sleep() for its side effects.
            time.sleep(1.0 / self._fps)
            # Return: Sends control back to the caller.
            return

        # Variable: now stores the result returned by time.ticks_ms().
        now = time.ticks_ms()
        # Variable: remaining stores the result returned by time.ticks_diff().
        remaining = time.ticks_diff(self._next, now)
        # Logic: Branches when remaining > 0 so the correct firmware path runs.
        if remaining > 0:
            # Expression: Calls time.sleep() for its side effects.
            time.sleep(remaining / 1000.0)

        # Variable: self._next stores the conditional expression time.ticks_add(self._next, int(self._frame_ms)) if hasattr(time, "ticks_add") else se....
        self._next = (
            time.ticks_add(self._next, int(self._frame_ms))
            if hasattr(time, "ticks_add")
            else self._next + int(self._frame_ms)
        )

    # -----------------------------------------------------------------------
    # Return elapsed time since construction, in seconds.
    # -----------------------------------------------------------------------
    # Function: Defines elapsed_s(self) to handle elapsed s behavior.
    def elapsed_s(self):
        # Logic: Branches when self._start is None so the correct firmware path runs.
        if self._start is None:
            # Return: Sends the configured literal value back to the caller.
            return 0.0
        # Return: Sends the calculated expression time.ticks_diff(time.ticks_ms(), self._start) / 1000.0 back to the caller.
        return time.ticks_diff(time.ticks_ms(), self._start) / 1000.0

    # -----------------------------------------------------------------------
    # Return True if the specified duration has elapsed.
    # -----------------------------------------------------------------------
    # Function: Defines done(self, duration_s) to handle done behavior.
    def done(self, duration_s):
        # Logic: Branches when duration_s is None or self._start is None so the correct firmware path runs.
        if duration_s is None or self._start is None:
            # Return: Sends the enabled/disabled flag value back to the caller.
            return False
        # Return: Sends the comparison result time.ticks_diff(time.ticks_ms(), self._start) >= duration_s * 1000 back to the caller.
        return time.ticks_diff(time.ticks_ms(), self._start) >= duration_s * 1000


# ---------------------------------------------------------------------------
# Color helper: clamp a color to the current brightness cap.
#
# Instead of clipping only the channel that exceeds the cap, this scales the
# whole RGB tuple uniformly. That preserves hue better.
# ---------------------------------------------------------------------------
# Function: Defines scale_color(rgb) to handle scale color behavior.
def scale_color(rgb):
    # Variable: r, g, b stores the current rgb value.
    r, g, b = rgb
    # Variable: m stores the result returned by max().
    m = max(r, g, b)
    # Variable: cap stores the current MAX_BRIGHTNESS value.
    cap = MAX_BRIGHTNESS

    # Logic: Branches when m <= cap so the correct firmware path runs.
    if m <= cap:
        # Return: Sends the collection of values used later in this module back to the caller.
        return (
            max(0, min(255, r)),
            max(0, min(255, g)),
            max(0, min(255, b)),
        )

    # Variable: s stores the calculated expression cap / m.
    s = cap / m
    # Return: Sends the collection of values used later in this module back to the caller.
    return (int(r * s), int(g * s), int(b * s))


# ---------------------------------------------------------------------------
# Adafruit-style color wheel helper.
# Maps pos in [0,255] to a rainbow RGB color.
# ---------------------------------------------------------------------------
# Function: Defines wheel(pos) to handle wheel behavior.
def wheel(pos):
    # Variable: pos stores the calculated expression pos & 0xFF.
    pos = pos & 0xFF
    # Logic: Branches when pos < 85 so the correct firmware path runs.
    if pos < 85:
        # Return: Sends the collection of values used later in this module back to the caller.
        return (255 - pos * 3, pos * 3, 0)
    # Logic: Branches when pos < 170 so the correct firmware path runs.
    if pos < 170:
        # Variable: Updates pos in place using the configured literal value.
        pos -= 85
        # Return: Sends the collection of values used later in this module back to the caller.
        return (0, 255 - pos * 3, pos * 3)
    # Variable: Updates pos in place using the configured literal value.
    pos -= 170
    # Return: Sends the collection of values used later in this module back to the caller.
    return (pos * 3, 0, 255 - pos * 3)


# ---------------------------------------------------------------------------
# Convert HSV in [0,1] ranges into RGB in [0,255].
# Output is not brightness-capped yet.
# ---------------------------------------------------------------------------
# Function: Defines hsv_to_rgb(h, s, v) to handle hsv to rgb behavior.
def hsv_to_rgb(h, s, v):
    # Logic: Branches when s <= 0.0 so the correct firmware path runs.
    if s <= 0.0:
        # Variable: x stores the result returned by int().
        x = int(v * 255)
        # Return: Sends the collection of values used later in this module back to the caller.
        return (x, x, x)

    # Variable: i stores the result returned by int().
    i = int(h * 6.0)
    # Variable: f stores the calculated expression h * 6.0 - i.
    f = h * 6.0 - i
    # Variable: p stores the result returned by int().
    p = int(255 * v * (1.0 - s))
    # Variable: q stores the result returned by int().
    q = int(255 * v * (1.0 - s * f))
    # Variable: t stores the result returned by int().
    t = int(255 * v * (1.0 - s * (1.0 - f)))
    # Variable: v stores the result returned by int().
    v = int(255 * v)
    # Variable: Updates i in place using the configured literal value.
    i %= 6

    # Logic: Branches when i == 0 so the correct firmware path runs.
    if i == 0:
        # Return: Sends the collection of values used later in this module back to the caller.
        return (v, t, p)
    # Logic: Branches when i == 1 so the correct firmware path runs.
    if i == 1:
        # Return: Sends the collection of values used later in this module back to the caller.
        return (q, v, p)
    # Logic: Branches when i == 2 so the correct firmware path runs.
    if i == 2:
        # Return: Sends the collection of values used later in this module back to the caller.
        return (p, v, t)
    # Logic: Branches when i == 3 so the correct firmware path runs.
    if i == 3:
        # Return: Sends the collection of values used later in this module back to the caller.
        return (p, q, v)
    # Logic: Branches when i == 4 so the correct firmware path runs.
    if i == 4:
        # Return: Sends the collection of values used later in this module back to the caller.
        return (t, p, v)
    # Return: Sends the collection of values used later in this module back to the caller.
    return (v, p, q)


# ---------------------------------------------------------------------------
# Map a logical (x, y) coordinate in the virtual 22x18 grid to a physical
# LED strip index. Returns None if the coordinate lies outside the shaped
# matrix for that row.
# ---------------------------------------------------------------------------
# Function: Defines logical_to_led_index(x, y) to handle logical to led index behavior.
def logical_to_led_index(x, y):
    # Reject out-of-bounds coordinates.
    # Logic: Branches when x < 0 or x >= COLS or y < 0 or y >= ROWS so the correct firmware path runs.
    if x < 0 or x >= COLS or y < 0 or y >= ROWS:
        # Return: Sends the empty sentinel value back to the caller.
        return None

    # Apply optional logical flips.
    # Logic: Branches when FLIP_X so the correct firmware path runs.
    if FLIP_X:
        # Variable: x stores the calculated expression COLS - 1 - x.
        x = COLS - 1 - x
    # Logic: Branches when FLIP_Y so the correct firmware path runs.
    if FLIP_Y:
        # Variable: y stores the calculated expression ROWS - 1 - y.
        y = ROWS - 1 - y

    # Compute the valid x-range for this row.
    # Variable: row_width stores the selected item ROW_LENGTHS[y].
    row_width = ROW_LENGTHS[y]
    # Variable: left_pad stores the calculated expression (COLS - row_width) // 2.
    left_pad = (COLS - row_width) // 2

    # Reject coordinates that fall into padded empty space.
    # Logic: Branches when x < left_pad or x >= left_pad + row_width so the correct firmware path runs.
    if x < left_pad or x >= left_pad + row_width:
        # Return: Sends the empty sentinel value back to the caller.
        return None

    # Convert logical x into row-local x.
    # Variable: local_x stores the calculated expression x - left_pad.
    local_x = x - left_pad

    # Reverse odd rows if the strip is serpentine-wired.
    # Logic: Branches when SERPENTINE and (y % 2 == 1) so the correct firmware path runs.
    if SERPENTINE and (y % 2 == 1):
        # Variable: local_x stores the calculated expression row_width - 1 - local_x.
        local_x = row_width - 1 - local_x

    # Return the final physical strip index.
    # Return: Sends the calculated expression ROW_STARTS[y] + local_x back to the caller.
    return ROW_STARTS[y] + local_x


# ---------------------------------------------------------------------------
# Clear the entire LED strip to black.
# If write=True, send the cleared frame to the LEDs immediately.
# ---------------------------------------------------------------------------
# Function: Defines clear(write) to handle clear behavior.
def clear(write=False):
    # Variable: off stores the collection of values used later in this module.
    off = (0, 0, 0)
    # Loop: Iterates i over range(NUM_LEDS) so each item can be processed.
    for i in range(NUM_LEDS):
        # Variable: np[...] stores the current off value.
        np[i] = off
    # Logic: Branches when write so the correct firmware path runs.
    if write:
        # Expression: Calls np.write() for its side effects.
        np.write()


# ---------------------------------------------------------------------------
# Push the current pixel buffer to the LEDs.
# ---------------------------------------------------------------------------
# Function: Defines show() to handle show behavior.
def show():
    # Expression: Calls np.write() for its side effects.
    np.write()


# ---------------------------------------------------------------------------
# Set one logical pixel to a color, after brightness scaling.
# If the logical coordinate does not map to a physical LED, do nothing.
# ---------------------------------------------------------------------------
# Function: Defines set_pixel(x, y, rgb) to handle set pixel behavior.
def set_pixel(x, y, rgb):
    # Variable: idx stores the result returned by logical_to_led_index().
    idx = logical_to_led_index(x, y)
    # Logic: Branches when idx is None so the correct firmware path runs.
    if idx is None:
        # Return: Sends control back to the caller.
        return
    # Variable: np[...] stores the result returned by scale_color().
    np[idx] = scale_color(rgb)


# ---------------------------------------------------------------------------
# Fill the entire physical strip with one color.
# ---------------------------------------------------------------------------
# Function: Defines fill(rgb) to handle fill behavior.
def fill(rgb):
    # Variable: c stores the result returned by scale_color().
    c = scale_color(rgb)
    # Loop: Iterates i over range(NUM_LEDS) so each item can be processed.
    for i in range(NUM_LEDS):
        # Variable: np[...] stores the current c value.
        np[i] = c


# ---------------------------------------------------------------------------
# Fill all valid logical pixels with one color.
# This skips padded logical positions that do not correspond to a real LED.
# ---------------------------------------------------------------------------
# Function: Defines fill_logical(rgb) to handle fill logical behavior.
def fill_logical(rgb):
    # Variable: c stores the result returned by scale_color().
    c = scale_color(rgb)
    # Loop: Iterates y over range(ROWS) so each item can be processed.
    for y in range(ROWS):
        # Loop: Iterates x over range(COLS) so each item can be processed.
        for x in range(COLS):
            # Variable: idx stores the result returned by logical_to_led_index().
            idx = logical_to_led_index(x, y)
            # Logic: Branches when idx is not None so the correct firmware path runs.
            if idx is not None:
                # Variable: np[...] stores the current c value.
                np[idx] = c


# ---------------------------------------------------------------------------
# Linear interpolation between numeric values a and b.
# t=0 returns a, t=1 returns b.
# ---------------------------------------------------------------------------
# Function: Defines lerp(a, b, t) to handle lerp behavior.
def lerp(a, b, t):
    # Logic: Branches when t <= 0.0 so the correct firmware path runs.
    if t <= 0.0:
        # Return: Sends the current a value back to the caller.
        return a
    # Logic: Branches when t >= 1.0 so the correct firmware path runs.
    if t >= 1.0:
        # Return: Sends the current b value back to the caller.
        return b
    # Return: Sends the calculated expression a + (b - a) * t back to the caller.
    return a + (b - a) * t


# ---------------------------------------------------------------------------
# Blend two RGB colors linearly by parameter t.
# ---------------------------------------------------------------------------
# Function: Defines blend(c1, c2, t) to handle blend behavior.
def blend(c1, c2, t):
    # Logic: Branches when t <= 0.0 so the correct firmware path runs.
    if t <= 0.0:
        # Return: Sends the current c1 value back to the caller.
        return c1
    # Logic: Branches when t >= 1.0 so the correct firmware path runs.
    if t >= 1.0:
        # Return: Sends the current c2 value back to the caller.
        return c2
    # Return: Sends the collection of values used later in this module back to the caller.
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
# Function: Defines dim(rgb, factor) to handle dim behavior.
def dim(rgb, factor):
    # Logic: Branches when factor <= 0.0 so the correct firmware path runs.
    if factor <= 0.0:
        # Return: Sends the collection of values used later in this module back to the caller.
        return (0, 0, 0)
    # Logic: Branches when factor >= 1.0 so the correct firmware path runs.
    if factor >= 1.0:
        # Return: Sends the current rgb value back to the caller.
        return rgb
    # Return: Sends the collection of values used later in this module back to the caller.
    return (
        int(rgb[0] * factor),
        int(rgb[1] * factor),
        int(rgb[2] * factor),
    )


# ---------------------------------------------------------------------------
# Apply gamma correction to an RGB tuple.
# Useful if a perceptually smoother brightness response is needed.
# ---------------------------------------------------------------------------
# Function: Defines gamma_correct(rgb, gamma) to handle gamma correct behavior.
def gamma_correct(rgb, gamma=2.2):
    # Variable: r, g, b stores the current rgb value.
    r, g, b = rgb
    # Return: Sends the collection of values used later in this module back to the caller.
    return (
        int(((r / 255) ** gamma) * 255),
        int(((g / 255) ** gamma) * 255),
        int(((b / 255) ** gamma) * 255),
    )


# ---------------------------------------------------------------------------
# Compute a radial falloff factor for a point (x, y).
# Returns a value in [0,1], where the center is brightest and the edge is 0.
# ---------------------------------------------------------------------------
# Function: Defines radial_factor(x, y, cx, cy, radius) to handle radial factor behavior.
def radial_factor(x, y, cx=None, cy=None, radius=None):
    # Logic: Branches when cx is None so the correct firmware path runs.
    if cx is None:
        # Variable: cx stores the calculated expression (COLS - 1) / 2.0.
        cx = (COLS - 1) / 2.0
    # Logic: Branches when cy is None so the correct firmware path runs.
    if cy is None:
        # Variable: cy stores the calculated expression (ROWS - 1) / 2.0.
        cy = (ROWS - 1) / 2.0
    # Logic: Branches when radius is None so the correct firmware path runs.
    if radius is None:
        # Variable: radius stores the calculated expression (cx * cx + cy * cy) ** 0.5.
        radius = (cx * cx + cy * cy) ** 0.5

    # Variable: dx stores the calculated expression x - cx.
    dx = x - cx
    # Variable: dy stores the calculated expression y - cy.
    dy = y - cy
    # Variable: d stores the calculated expression (dx * dx + dy * dy) ** 0.5.
    d = (dx * dx + dy * dy) ** 0.5

    # Logic: Branches when d >= radius so the correct firmware path runs.
    if d >= radius:
        # Return: Sends the configured literal value back to the caller.
        return 0.0
    # Return: Sends the calculated expression 1.0 - (d / radius) back to the caller.
    return 1.0 - (d / radius)


# ---------------------------------------------------------------------------
# Render an ASCII-art bitmap to the display.
#
# Characters:
# - '#' -> on_color
# - '+' -> dim_color
# - anything else -> off_color
# ---------------------------------------------------------------------------
# Function: Defines draw_bitmap(bitmap, on_color, dim_color, off_color, do_show) to handle draw bitmap behavior.
def draw_bitmap(bitmap, on_color=(66, 0, 36), dim_color=(24, 0, 14),
                off_color=(0, 0, 0), do_show=True):
    # Variable: on_c stores the result returned by scale_color().
    on_c = scale_color(on_color)
    # Variable: dim_c stores the result returned by scale_color().
    dim_c = scale_color(dim_color)
    # Variable: off_c stores the result returned by scale_color().
    off_c = scale_color(off_color)

    # Expression: Calls clear() for its side effects.
    clear()

    # Loop: Iterates y, row over enumerate(bitmap) so each item can be processed.
    for y, row in enumerate(bitmap):
        # Logic: Branches when y >= ROWS so the correct firmware path runs.
        if y >= ROWS:
            # Control: Stops the loop once the required condition has been met.
            break
        # Loop: Iterates x, ch over enumerate(row) so each item can be processed.
        for x, ch in enumerate(row):
            # Logic: Branches when x >= COLS so the correct firmware path runs.
            if x >= COLS:
                # Control: Stops the loop once the required condition has been met.
                break
            # Variable: idx stores the result returned by logical_to_led_index().
            idx = logical_to_led_index(x, y)
            # Logic: Branches when idx is None so the correct firmware path runs.
            if idx is None:
                # Control: Skips to the next loop iteration after this case is handled.
                continue

            # Logic: Branches when ch == "#" so the correct firmware path runs.
            if ch == "#":
                # Variable: np[...] stores the current on_c value.
                np[idx] = on_c
            # Logic: Branches when ch == "+" so the correct firmware path runs.
            elif ch == "+":
                # Variable: np[...] stores the current dim_c value.
                np[idx] = dim_c
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Variable: np[...] stores the current off_c value.
                np[idx] = off_c

    # Logic: Branches when do_show so the correct firmware path runs.
    if do_show:
        # Expression: Calls np.write() for its side effects.
        np.write()


# ---------------------------------------------------------------------------
# Blend between two ASCII-art bitmaps.
# Each cell color is looked up from bitmap_a and bitmap_b, then blended by t.
# ---------------------------------------------------------------------------
# Function: Defines draw_bitmap_blend(bitmap_a, bitmap_b, t, on_color, dim_color, off_color, do_show) to handle draw bitmap blend behavior.
def draw_bitmap_blend(bitmap_a, bitmap_b, t, on_color=(66, 0, 36),
                      dim_color=(24, 0, 14), off_color=(0, 0, 0),
                      do_show=True):
    # Variable: on_c stores the result returned by scale_color().
    on_c = scale_color(on_color)
    # Variable: dim_c stores the result returned by scale_color().
    dim_c = scale_color(dim_color)
    # Variable: off_c stores the result returned by scale_color().
    off_c = scale_color(off_color)

    # -----------------------------------------------------------------------
    # Helper to convert one bitmap cell into a concrete RGB color.
    # -----------------------------------------------------------------------
    # Function: Defines cell_color(bitmap, y, x) to handle cell color behavior.
    def cell_color(bitmap, y, x):
        # Logic: Branches when y >= len(bitmap) so the correct firmware path runs.
        if y >= len(bitmap):
            # Return: Sends the current off_c value back to the caller.
            return off_c
        # Variable: row stores the selected item bitmap[y].
        row = bitmap[y]
        # Logic: Branches when x >= len(row) so the correct firmware path runs.
        if x >= len(row):
            # Return: Sends the current off_c value back to the caller.
            return off_c

        # Variable: ch stores the selected item row[x].
        ch = row[x]
        # Logic: Branches when ch == "#" so the correct firmware path runs.
        if ch == "#":
            # Return: Sends the current on_c value back to the caller.
            return on_c
        # Logic: Branches when ch == "+" so the correct firmware path runs.
        if ch == "+":
            # Return: Sends the current dim_c value back to the caller.
            return dim_c
        # Return: Sends the current off_c value back to the caller.
        return off_c

    # Expression: Calls clear() for its side effects.
    clear()

    # Loop: Iterates y over range(ROWS) so each item can be processed.
    for y in range(ROWS):
        # Loop: Iterates x over range(COLS) so each item can be processed.
        for x in range(COLS):
            # Variable: idx stores the result returned by logical_to_led_index().
            idx = logical_to_led_index(x, y)
            # Logic: Branches when idx is None so the correct firmware path runs.
            if idx is None:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Variable: ca stores the result returned by cell_color().
            ca = cell_color(bitmap_a, y, x)
            # Variable: cb stores the result returned by cell_color().
            cb = cell_color(bitmap_b, y, x)
            # Variable: np[...] stores the result returned by blend().
            np[idx] = blend(ca, cb, t)

    # Logic: Branches when do_show so the correct firmware path runs.
    if do_show:
        # Expression: Calls np.write() for its side effects.
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
# Function: Defines draw_pixel_grid(grid, palette, do_show) to handle draw pixel grid behavior.
def draw_pixel_grid(grid, palette, do_show=True):
    # Variable: off_c stores the collection of values used later in this module.
    off_c = (0, 0, 0)
    # Expression: Calls clear() for its side effects.
    clear()

    # Loop: Iterates y, row over enumerate(grid) so each item can be processed.
    for y, row in enumerate(grid):
        # Logic: Branches when y >= ROWS so the correct firmware path runs.
        if y >= ROWS:
            # Control: Stops the loop once the required condition has been met.
            break
        # Loop: Iterates x, key over enumerate(row) so each item can be processed.
        for x, key in enumerate(row):
            # Logic: Branches when x >= COLS so the correct firmware path runs.
            if x >= COLS:
                # Control: Stops the loop once the required condition has been met.
                break
            # Variable: idx stores the result returned by logical_to_led_index().
            idx = logical_to_led_index(x, y)
            # Logic: Branches when idx is None so the correct firmware path runs.
            if idx is None:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Variable: col stores the result returned by palette.get().
            col = palette.get(key, off_c)
            # Variable: np[...] stores the result returned by scale_color().
            np[idx] = scale_color(col)

    # Logic: Branches when do_show so the correct firmware path runs.
    if do_show:
        # Expression: Calls np.write() for its side effects.
        np.write()

# ---------------------------------------------------------------------------
# RinaChanBoard-main 16x18 protocol compatibility layer.
# The physical board is the full Rina-Chan-board-370-leds matrix: 22x18,
# 370 LEDs, irregular row lengths from this file.  Legacy RinaChanBoard-main
# packets are 18 columns x 16 rows and are centered on the 370-LED board.
# ---------------------------------------------------------------------------
# Variable: SRC_ROWS stores the configured literal value.
SRC_ROWS = 16
# Variable: SRC_COLS stores the configured literal value.
SRC_COLS = 18
# Variable: SRC_TO_DST_ROW_OFFSET stores the configured literal value.
SRC_TO_DST_ROW_OFFSET = 1
# Variable: SRC_TO_DST_COL_OFFSET stores the configured literal value.
SRC_TO_DST_COL_OFFSET = 2
# Variable: SRC_INVALID_COLS stores the collection of values used later in this module.
SRC_INVALID_COLS = (0, 17)


# Function: Defines hardware_summary() to handle hardware summary behavior.
def hardware_summary():
    # Return: Sends the result returned by format() back to the caller.
    return "ESP32-S3 GPIO{} WS2812, {} LEDs, physical {}x{} irregular 370 matrix, row_lengths={}, legacy src {}x{} centered +{}r +{}c".format(
        LED_PIN, NUM_LEDS, COLS, ROWS, ROW_LENGTHS, SRC_COLS, SRC_ROWS,
        SRC_TO_DST_ROW_OFFSET, SRC_TO_DST_COL_OFFSET)


# Function: Defines src_to_led_index(row, col) to handle src to led index behavior.
def src_to_led_index(row, col):
    # Logic: Branches when row < 0 or row >= SRC_ROWS or col < 0 or col >= SRC_COLS so the correct firmware path runs.
    if row < 0 or row >= SRC_ROWS or col < 0 or col >= SRC_COLS:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Logic: Branches when col in SRC_INVALID_COLS so the correct firmware path runs.
    if col in SRC_INVALID_COLS:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Return: Sends the result returned by logical_to_led_index() back to the caller.
    return logical_to_led_index(col + SRC_TO_DST_COL_OFFSET,
                                row + SRC_TO_DST_ROW_OFFSET)


# Function: Defines _fastled_byte_scale(rgb, bright) to handle fastled byte scale behavior.
def _fastled_byte_scale(rgb, bright):
    # Logic: Branches when bright < 0 so the correct firmware path runs.
    if bright < 0:
        # Variable: bright stores the configured literal value.
        bright = 0
    # Logic: Branches when bright > 255 so the correct firmware path runs.
    elif bright > 255:
        # Variable: bright stores the configured literal value.
        bright = 255
    # Variable: r, g, b stores the current rgb value.
    r, g, b = rgb
    # Return: Sends the collection of values used later in this module back to the caller.
    return ((int(r) * bright) // 255,
            (int(g) * bright) // 255,
            (int(b) * bright) // 255)


# Function: Defines draw_src_face_matrix(face, color, bright, write) to handle draw src face matrix behavior.
def draw_src_face_matrix(face, color, bright=255, write=True):
    # Module: Documents the purpose of this scope.
    """Draw a legacy 16x18 RinaChanBoard-main face centered on the 22x18 370 board."""
    # Variable: on stores the result returned by scale_color().
    on = scale_color(_fastled_byte_scale(color, bright))
    # Expression: Calls clear() for its side effects.
    clear(False)
    # Loop: Iterates row over range(SRC_ROWS) so each item can be processed.
    for row in range(SRC_ROWS):
        # Variable: frow stores the selected item face[row].
        frow = face[row]
        # Loop: Iterates col over range(SRC_COLS) so each item can be processed.
        for col in range(SRC_COLS):
            # Logic: Branches when not frow[col] so the correct firmware path runs.
            if not frow[col]:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Variable: idx stores the result returned by src_to_led_index().
            idx = src_to_led_index(row, col)
            # Logic: Branches when idx is not None so the correct firmware path runs.
            if idx is not None:
                # Variable: np[...] stores the current on value.
                np[idx] = on
    # Logic: Branches when write so the correct firmware path runs.
    if write:
        # Expression: Calls show() for its side effects.
        show()


# Function: Defines draw_face_matrix(face, color, bright, write) to handle draw face matrix behavior.
def draw_face_matrix(face, color, bright=255, write=True):
    # Expression: Calls draw_src_face_matrix() for its side effects.
    draw_src_face_matrix(face, color, bright, write)


# Function: Defines fill_valid(rgb, bright, write) to handle fill valid behavior.
def fill_valid(rgb, bright=255, write=True):
    # Variable: c stores the result returned by scale_color().
    c = scale_color(_fastled_byte_scale(rgb, bright))
    # Loop: Iterates y over range(ROWS) so each item can be processed.
    for y in range(ROWS):
        # Loop: Iterates x over range(COLS) so each item can be processed.
        for x in range(COLS):
            # Variable: idx stores the result returned by logical_to_led_index().
            idx = logical_to_led_index(x, y)
            # Logic: Branches when idx is not None so the correct firmware path runs.
            if idx is not None:
                # Variable: np[...] stores the current c value.
                np[idx] = c
    # Logic: Branches when write so the correct firmware path runs.
    if write:
        # Expression: Calls show() for its side effects.
        show()
