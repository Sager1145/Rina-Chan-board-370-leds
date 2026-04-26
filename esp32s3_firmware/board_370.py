from machine import Pin
from neopixel import NeoPixel
import time
LED_PIN = 2
NUM_LEDS = 370
ROW_LENGTHS = (
    18,
    20, 20, 20,
    22, 22, 22, 22, 22, 22, 22, 22, 22,
    20, 20, 20,
    18,
    16,
)
ROWS = len(ROW_LENGTHS)
COLS = 22
SERPENTINE = True
FLIP_X = False
FLIP_Y = False
SRC_ROWS = 16
SRC_COLS = 18
SRC_TO_DST_ROW_OFFSET = 1
SRC_TO_DST_COL_OFFSET = 2
SRC_INVALID_COLS = (0, 17)
APPLY_370_SAFETY_CAP = True
MAX_CHANNEL_HARD_CAP = 170
_row_starts = []
_acc = 0
for _w in ROW_LENGTHS:
    _row_starts.append(_acc)
    _acc += _w
assert _acc == NUM_LEDS, "ROW_LENGTHS must sum to NUM_LEDS"
np = NeoPixel(Pin(LED_PIN, Pin.OUT), NUM_LEDS)
def ticks_ms():
    return time.ticks_ms()
def sleep_ms(ms):
    time.sleep_ms(ms)
def logical_to_led_index(x, y):
    if x < 0 or x >= COLS or y < 0 or y >= ROWS:
        return None
    if FLIP_X:
        x = COLS - 1 - x
    if FLIP_Y:
        y = ROWS - 1 - y
    row_width = ROW_LENGTHS[y]
    left_pad = (COLS - row_width) // 2
    if x < left_pad or x >= left_pad + row_width:
        return None
    local_x = x - left_pad
    if SERPENTINE and (y & 1):
        local_x = row_width - 1 - local_x
    return _row_starts[y] + local_x
def src_to_led_index(row, col):
    if row < 0 or row >= SRC_ROWS or col < 0 or col >= SRC_COLS:
        return None
    if col in SRC_INVALID_COLS:
        return None
    return logical_to_led_index(col + SRC_TO_DST_COL_OFFSET,
                                row + SRC_TO_DST_ROW_OFFSET)
def _scale_uniform_to_cap(rgb, cap):
    r, g, b = rgb
    r = max(0, min(255, int(r)))
    g = max(0, min(255, int(g)))
    b = max(0, min(255, int(b)))
    m = max(r, g, b)
    if m <= cap or m <= 0:
        return (r, g, b)
    scale = cap / m
    return (int(r * scale), int(g * scale), int(b * scale))
def apply_brightness(rgb, bright):
    if bright < 0:
        bright = 0
    elif bright > 255:
        bright = 255
    r, g, b = rgb
    r = (int(r) * bright) // 255
    g = (int(g) * bright) // 255
    b = (int(b) * bright) // 255
    if APPLY_370_SAFETY_CAP:
        return _scale_uniform_to_cap((r, g, b), MAX_CHANNEL_HARD_CAP)
    return (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
def clear(write=False):
    off = (0, 0, 0)
    for i in range(NUM_LEDS):
        np[i] = off
    if write:
        np.write()
def show():
    np.write()
def draw_face_matrix(face, color, bright=255, write=True):
    on = apply_brightness(color, bright)
    off = (0, 0, 0)
    clear(False)
    for row in range(SRC_ROWS):
        frow = face[row]
        for col in range(SRC_COLS):
            if not frow[col]:
                continue
            idx = src_to_led_index(row, col)
            if idx is not None:
                np[idx] = on
    if write:
        show()
def fill_valid(rgb, bright=255, write=True):
    c = apply_brightness(rgb, bright)
    for i in range(NUM_LEDS):
        np[i] = c
    if write:
        show()
def hardware_summary():
    return "ESP32-S3 GPIO{} WS2812, {} LEDs, virtual {}x{}, src {}x{} centered +{}r +{}c".format(
        LED_PIN, NUM_LEDS, COLS, ROWS, SRC_COLS, SRC_ROWS,
        SRC_TO_DST_ROW_OFFSET, SRC_TO_DST_COL_OFFSET)
