from machine import Pin
try:
    from neopixel import NeoPixel
except ImportError:
    NeoPixel = None

from config import (
    LED_PIN, NUM_LEDS, ROW_LENGTHS, ROWS, COLS,
    SERPENTINE, FLIP_X, FLIP_Y,
    BRIGHTNESS_MAX_CHANNEL, OFF, PINK, DIM,
)

ROW_STARTS = []
_acc = 0
for _w in ROW_LENGTHS:
    ROW_STARTS.append(_acc)
    _acc += _w
assert _acc == NUM_LEDS

_pin = Pin(LED_PIN, Pin.OUT)
np = NeoPixel(_pin, NUM_LEDS) if NeoPixel else None
_raw = bytearray(NUM_LEDS * 3)
_brightness_cap = int(BRIGHTNESS_MAX_CHANNEL * 0.30)


def set_max_brightness(value):
    global _brightness_cap
    value = int(value)
    if value < 1:
        value = 1
    if value > BRIGHTNESS_MAX_CHANNEL:
        value = BRIGHTNESS_MAX_CHANNEL
    _brightness_cap = value
    return value


def get_max_brightness():
    return _brightness_cap


def brightness_percent_to_cap(percent):
    percent = max(0, min(100, int(percent)))
    return max(1, int((BRIGHTNESS_MAX_CHANNEL * percent + 50) // 100))


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
    return ROW_STARTS[y] + local_x


def is_real_cell(x, y):
    return logical_to_led_index(x, y) is not None


def _clamp(v):
    if v < 0:
        return 0
    if v > 255:
        return 255
    return int(v)


def set_pixel_index(i, rgb):
    if i is None or i < 0 or i >= NUM_LEDS:
        return
    j = i * 3
    _raw[j] = _clamp(rgb[0])
    _raw[j + 1] = _clamp(rgb[1])
    _raw[j + 2] = _clamp(rgb[2])


def get_pixel_index(i):
    if i is None or i < 0 or i >= NUM_LEDS:
        return OFF
    j = i * 3
    return (_raw[j], _raw[j + 1], _raw[j + 2])


def set_pixel(x, y, rgb):
    set_pixel_index(logical_to_led_index(int(x), int(y)), rgb)


def clear(write=False):
    for i in range(len(_raw)):
        _raw[i] = 0
    if write:
        show()


def fill(rgb, write=False):
    for i in range(NUM_LEDS):
        set_pixel_index(i, rgb)
    if write:
        show()


def scale_color(rgb, cap=None):
    if cap is None:
        cap = _brightness_cap
    return (
        min(int(rgb[0]), cap),
        min(int(rgb[1]), cap),
        min(int(rgb[2]), cap),
    )


def show():
    if np is None:
        return
    cap = _brightness_cap
    for i in range(NUM_LEDS):
        j = i * 3
        r = _raw[j]
        g = _raw[j + 1]
        b = _raw[j + 2]
        if r > cap:
            r = cap
        if g > cap:
            g = cap
        if b > cap:
            b = cap
        np[i] = (r, g, b)
    np.write()


def update_color(rgb, write=True):
    for i in range(NUM_LEDS):
        j = i * 3
        if _raw[j] or _raw[j + 1] or _raw[j + 2]:
            _raw[j] = _clamp(rgb[0])
            _raw[j + 1] = _clamp(rgb[1])
            _raw[j + 2] = _clamp(rgb[2])
    if write:
        show()


def draw_bitmap(bitmap, on_color=PINK, dim_color=DIM, off_color=OFF, do_show=True, clear_first=True):
    if clear_first:
        clear(False)
    for y, row in enumerate(bitmap):
        if y >= ROWS:
            break
        for x, ch in enumerate(row):
            if x >= COLS:
                break
            idx = logical_to_led_index(x, y)
            if idx is None:
                continue
            if ch == '#':
                set_pixel_index(idx, on_color)
            elif ch == '+':
                set_pixel_index(idx, dim_color)
            elif off_color is not None and not clear_first:
                set_pixel_index(idx, off_color)
    if do_show:
        show()


def draw_physical_rgb_hex(hexstr, do_show=True):
    hexstr = ''.join(str(hexstr).strip().split())
    clear(False)
    n = min(NUM_LEDS, len(hexstr) // 6)
    for i in range(n):
        chunk = hexstr[i * 6:i * 6 + 6]
        try:
            r = int(chunk[0:2], 16)
            g = int(chunk[2:4], 16)
            b = int(chunk[4:6], 16)
        except Exception:
            r = g = b = 0
        set_pixel_index(i, (r, g, b))
    if do_show:
        show()


def draw_physical_bits_hex(hexstr, on_color=PINK, do_show=True):
    hexstr = ''.join(str(hexstr).strip().split())
    clear(False)
    bit_index = 0
    for c in hexstr:
        try:
            v = int(c, 16)
        except Exception:
            continue
        for bit in (3, 2, 1, 0):
            if bit_index >= NUM_LEDS:
                break
            if v & (1 << bit):
                set_pixel_index(bit_index, on_color)
            bit_index += 1
        if bit_index >= NUM_LEDS:
            break
    if do_show:
        show()


def draw_m370_bits_hex(hexstr, on_color=PINK, do_show=True):
    hexstr = ''.join(str(hexstr).strip().split())
    clear(False)
    bits = ''
    for c in hexstr:
        try:
            v = int(c, 16)
        except Exception:
            continue
        bits += '1' if (v & 8) else '0'
        bits += '1' if (v & 4) else '0'
        bits += '1' if (v & 2) else '0'
        bits += '1' if (v & 1) else '0'
    bit_index = 0
    for y in range(ROWS):
        for x in range(COLS):
            idx = logical_to_led_index(x, y)
            if idx is None:
                continue
            if bit_index < len(bits) and bits[bit_index] == '1':
                set_pixel_index(idx, on_color)
            bit_index += 1
    if do_show:
        show()


def draw_frame_hex(hexstr, on_color=PINK, do_show=True):
    s = ''.join(str(hexstr).strip().split())
    if len(s) >= NUM_LEDS * 6:
        draw_physical_rgb_hex(s, do_show=do_show)
    else:
        draw_m370_bits_hex(s, on_color=on_color, do_show=do_show)


def wheel(pos):
    pos = int(pos) & 255
    if pos < 85:
        return (255 - pos * 3, pos * 3, 0)
    if pos < 170:
        pos -= 85
        return (0, 255 - pos * 3, pos * 3)
    pos -= 170
    return (pos * 3, 0, 255 - pos * 3)
