# ---------------------------------------------------------------------------
# display_num.py
#
# Render centered short text on the LED matrix for:
# - interval values, e.g. "1.5s"
# - brightness values, e.g. "70%"
# - battery values, e.g. "82%"
# - mode indicator: large "A" or "M"
#
# These renderers are non-blocking:
# they draw one frame and return immediately.
# main.py is responsible for deciding how long the overlay stays visible.
# ---------------------------------------------------------------------------

from board import (
    COLS, ROWS, logical_to_led_index, np, clear, show, scale_color,
)

_FONT = {
    "0": [
        ".###.",
        "#...#",
        "#..##",
        "#.#.#",
        "##..#",
        "#...#",
        ".###.",
    ],
    "1": [
        ".##..",
        "#.#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "#####",
    ],
    "2": [
        ".###.",
        "#...#",
        "....#",
        "...#.",
        "..#..",
        ".#...",
        "#####",
    ],
    "3": [
        "####.",
        "....#",
        "....#",
        ".###.",
        "....#",
        "....#",
        "####.",
    ],
    "4": [
        "...#.",
        "..##.",
        ".#.#.",
        "#..#.",
        "#####",
        "...#.",
        "...#.",
    ],
    "5": [
        "#####",
        "#....",
        "####.",
        "....#",
        "....#",
        "#...#",
        ".###.",
    ],
    "6": [
        ".###.",
        "#...#",
        "#....",
        "####.",
        "#...#",
        "#...#",
        ".###.",
    ],
    "7": [
        "#####",
        "....#",
        "...#.",
        "..#..",
        ".#...",
        ".#...",
        ".#...",
    ],
    "8": [
        ".###.",
        "#...#",
        "#...#",
        ".###.",
        "#...#",
        "#...#",
        ".###.",
    ],
    "9": [
        ".###.",
        "#...#",
        "#...#",
        ".####",
        "....#",
        "#...#",
        ".###.",
    ],
    "S": [
        ".####",
        "#....",
        "#....",
        ".###.",
        "....#",
        "....#",
        "####.",
    ],
    "V": [
        "#...#",
        "#...#",
        "#...#",
        ".#.#.",
        ".#.#.",
        "..#..",
        "..#..",
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
    "M": [
        "#...#",
        "##.##",
        "#.#.#",
        "#.#.#",
        "#...#",
        "#...#",
        "#...#",
    ],
}

_DOT = [
    ".",
    ".",
    ".",
    ".",
    ".",
    ".",
    "#",
]

_PCT_3 = [
    "#.#",
    "..#",
    ".#.",
    ".#.",
    "#..",
    "#.#",
    "...",
]

GLYPH_H = 7

# Default blue used for interval / brightness / battery unless overridden
DEFAULT_COLOR = (0, 120, 255)

# Keep brightness blue
BRIGHTNESS_COLOR = (0, 120, 255)

# Make M/A mode display purple
MODE_COLOR = (180, 0, 255)

_BIG_A = [
    "...####...",
    "..######..",
    ".##....##.",
    ".##....##.",
    ".##....##.",
    ".##....##.",
    ".########.",
    ".########.",
    ".##....##.",
    ".##....##.",
    ".##....##.",
    ".##....##.",
    ".##....##.",
]

_BIG_M = [
    "##......##",
    "###....###",
    "####..####",
    "##.####.##",
    "##..##..##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
    "##......##",
]

# These big glyph rows are 10 columns wide.
_BIG_W = len(_BIG_A[0])
_BIG_H = len(_BIG_A)

CLOCK_ICON = [
    "......................",
    ".........####.........",
    "........#...##........",
    "........#..#.#........",
    "........#....#........",
    "........#....#........",
    ".........####.........",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
]

SUN_ICON_1 = [
    "......................",
    ".......#......#.##....",
    "....##.#......#.......",
    "........#....#........",
    ".........####..#......",
    ".......#........#.....",
    "......#....#..........",
    "...........#..........",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
]

SUN_ICON_2 = [
    "......................",
    ".......##....##.##....",
    "....##.###..###.......",
    "........######........",
    ".........####..#......",
    ".......#........#.....",
    "......#....#..........",
    "...........#..........",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
]

SUN_ICON_3 = [
    "......................",
    ".......########.##....",
    "....##.########.......",
    "........######........",
    ".........####..#......",
    ".......#........#.....",
    "......#....#..........",
    "...........#..........",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
]

BATTERY_ICON = [
    "......................",
    "......#########.......",
    "......#........#......",
    "......#........#......",
    "......#........#......",
    "......#########.......",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
    "......................",
]

ICON_TOP_Y = 0
TEXT_Y_WITH_ICON = 9


def _blank_bitmap(height, width):
    return ["." * width for _ in range(height)]


def _glyph_for(ch):
    if ch == ".":
        return (_DOT, 1)
    if ch == "%":
        return (_PCT_3, 3)
    g = _FONT.get(ch)
    if g is None:
        return (_blank_bitmap(7, 5), 5)
    return (g, len(g[0]) if g else 0)


def _draw_bitmap_rows(rows, color, dim_color=None, x0=0, y0=0):
    on_c = scale_color(color)
    if dim_color is None:
        dim_color = (color[0] // 3, color[1] // 3, color[2] // 3)
    dim_c = scale_color(dim_color)

    for ry, line in enumerate(rows):
        py = y0 + ry
        if py < 0 or py >= ROWS:
            continue
        for rx, ch in enumerate(line):
            px = x0 + rx
            idx = logical_to_led_index(px, py)
            if idx is None:
                continue
            if ch == "#":
                np[idx] = on_c
            elif ch == "+":
                np[idx] = dim_c


def _render_string(text, color, icon_rows=None):
    glyphs = [_glyph_for(ch) for ch in text]
    gap = 1
    total_w = 0
    for i, (_, w) in enumerate(glyphs):
        total_w += w
        if i < len(glyphs) - 1:
            total_w += gap

    x0 = (COLS - total_w) // 2
    y0 = TEXT_Y_WITH_ICON if icon_rows is not None else (ROWS - GLYPH_H) // 2

    clear()
    if icon_rows is not None:
        _draw_bitmap_rows(icon_rows, color, x0=0, y0=ICON_TOP_Y)

    c = scale_color(color)
    x = x0
    for (rows, w) in glyphs:
        for ry in range(GLYPH_H):
            line = rows[ry] if ry < len(rows) else ""
            for rx in range(w):
                ch = line[rx] if rx < len(line) else "."
                if ch != "#":
                    continue
                px = x + rx
                py = y0 + ry
                idx = logical_to_led_index(px, py)
                if idx is None:
                    continue
                np[idx] = c
        x += w + gap

    show()


def _format_interval(seconds):
    tenths = int(round(seconds * 10))
    whole = tenths // 10
    frac = tenths % 10

    if whole == 10 and frac == 0:
        return "10"

    return "{}.{}".format(whole, frac)


def _sun_icon_rows(percent):
    p = int(percent)
    if p < 0:
        p = 0
    elif p > 100:
        p = 100

    if p < 40:
        return SUN_ICON_1
    elif p < 70:
        return SUN_ICON_2
    return SUN_ICON_3


def _battery_icon_rows(percent):
    p = int(percent)
    if p < 0:
        p = 0
    elif p > 100:
        p = 100

    rows = BATTERY_ICON[:]

    # Based on the battery icon in this file:
    #   interior rows:    2, 3, 4
    #   interior columns: 7..14  (8 columns total)
    inner_rows = (2, 3, 4)
    inner_left = 7
    inner_cols = 8

    # Fill rule:
    # - below 10%  -> empty
    # - above 90%  -> full
    # - between    -> fill column-by-column
    if p < 10:
        filled_cols = 0
    elif p > 90:
        filled_cols = inner_cols
    else:
        # 10 -> 0 columns
        # 11..20 -> 1 column
        # 21..30 -> 2 columns
        # ...
        # 81..90 -> 8 columns
        filled_cols = ((p - 10) * inner_cols + 79) // 80

    for y in inner_rows:
        row = list(rows[y])
        for i in range(inner_cols):
            x = inner_left + i
            row[x] = "#" if i < filled_cols else "."
        rows[y] = "".join(row)

    return rows


def render_interval(seconds, color=MODE_COLOR):
    _render_string(_format_interval(seconds) + "s", color, icon_rows=CLOCK_ICON)


def render_brightness_percent(percent, color=BRIGHTNESS_COLOR):
    _render_string("{}%".format(int(percent)), color,
                   icon_rows=_sun_icon_rows(percent))


def render_battery_percent(percent, color=DEFAULT_COLOR):
    _render_string("{}%".format(int(percent)), color,
                   icon_rows=_battery_icon_rows(percent))


def render_percent(percent, color=DEFAULT_COLOR):
    _render_string("{}%".format(int(percent)), color)


def _render_big_glyph(rows, w, h, color):
    c = scale_color(color)
    x0 = (COLS - w) // 2
    y0 = (ROWS - h) // 2

    clear()
    for ry in range(h):
        line = rows[ry] if ry < len(rows) else ""
        for rx in range(w):
            ch = line[rx] if rx < len(line) else "."
            if ch != "#":
                continue
            px = x0 + rx
            py = y0 + ry
            idx = logical_to_led_index(px, py)
            if idx is None:
                continue
            np[idx] = c
    show()


def render_mode(auto, color=MODE_COLOR):
    rows = _BIG_A if auto else _BIG_M
    _render_big_glyph(rows, _BIG_W, _BIG_H, color)

def render_battery_voltage(voltage, percent=0, color=DEFAULT_COLOR):
    if voltage is None:
        _render_string("0.0V", color, icon_rows=_battery_icon_rows(percent))
        return
    # Keep this compact enough to fit on the 22-column matrix.
    _render_string("{:.1f}V".format(voltage), color,
                   icon_rows=_battery_icon_rows(percent))


def render_battery_time(hours_remaining, percent=0, color=DEFAULT_COLOR):
    if hours_remaining is None:
        _render_string("--", color, icon_rows=_battery_icon_rows(percent))
        return

    if hours_remaining <= 0.0:
        text = "0M"
    else:
        minutes = int(round(hours_remaining * 60.0))
        if minutes < 60:
            text = "{}M".format(minutes)
        else:
            tenths_hours = int(round(hours_remaining * 10.0))
            if tenths_hours < 10:
                tenths_hours = 10
            elif tenths_hours > 99:
                tenths_hours = 99

            whole = tenths_hours // 10
            frac = tenths_hours % 10
            if frac == 0:
                text = "{}H".format(whole)
            else:
                text = "{}.{}H".format(whole, frac)

    _render_string(text, color, icon_rows=_battery_icon_rows(percent))
