from board import COLS, ROWS, logical_to_led_index, np, clear, show, scale_color
from config import BATTERY_CHARGE_LAST_COLUMN_FLASH_MS

_FONT = {
    "0": [".###.","#...#","#..##","#.#.#","##..#","#...#",".###."],
    "1": [".##..","#.#..","..#..","..#..","..#..","..#..","#####"],
    "2": [".###.","#...#","....#","...#.","..#..",".#...","#####"],
    "3": ["####.","....#","....#",".###.","....#","....#","####."],
    "4": ["...#.","..##.",".#.#.","#..#.","#####","...#.","...#."],
    "5": ["#####","#....","####.","....#","....#","#...#",".###."],
    "6": [".###.","#...#","#....","####.","#...#","#...#",".###."],
    "7": ["#####","....#","...#.","..#..",".#...",".#...",".#..."],
    "8": [".###.","#...#","#...#",".###.","#...#","#...#",".###."],
    "9": [".###.","#...#","#...#",".####","....#","#...#",".###."],
    "S": [".####","#....","#....",".###.","....#","....#","####."],
    "V": ["#...#","#...#","#...#",".#.#.",".#.#.","..#..","..#.."],
    "H": ["#...#","#...#","#...#","#####","#...#","#...#","#...#"],
    "M": ["#...#","##.##","#.#.#","#.#.#","#...#","#...#","#...#"],
}
_DOT=[".",".",".",".",".",".","#"]
_PCT_3=["#.#","..#",".#.",".#.","#..","#.#","..."]
GLYPH_H=7
DEFAULT_COLOR=(0,120,255)
BRIGHTNESS_COLOR=(0,120,255)
MODE_COLOR=(180,0,255)
_BIG_A=["...####...","..######..",".##....##.",".##....##.",".##....##.",".##....##.",".########.",".########.",".##....##.",".##....##.",".##....##.",".##....##.",".##....##."]
_BIG_M=["##......##","###....###","####..####","##.####.##","##..##..##","##......##","##......##","##......##","##......##","##......##","##......##","##......##","##......##"]
_BIG_W=len(_BIG_A[0]); _BIG_H=len(_BIG_A)
CLOCK_ICON=["......................",".........####.........","........#...##........","........#..#.#........","........#....#........","........#....#........",".........####.........","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
SUN_ICON_1=["......................",".......#......#.##....","....##.#......#.......","........#....#........",".........####..#......",".......#........#.....","......#....#..........","...........#..........","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
SUN_ICON_2=["......................",".......##....##.##....","....##.###..###.......","........######........",".........####..#......",".......#........#.....","......#....#..........","...........#..........","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
SUN_ICON_3=["......................",".......########.##....","....##.########.......","........######........",".........####..#......",".......#........#.....","......#....#..........","...........#..........","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
BATTERY_ICON=["......................","......#########.......","......#........#......","......#........#......","......#........#......","......#########.......","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
ICON_TOP_Y=0
TEXT_Y_WITH_ICON=9

def _blank_bitmap(h,w): return ["."*w for _ in range(h)]
def _glyph_for(ch):
    if ch==".": return (_DOT,1)
    if ch=="%": return (_PCT_3,3)
    g=_FONT.get(ch)
    return (_blank_bitmap(7,5),5) if g is None else (g,len(g[0]) if g else 0)

def _draw_bitmap_rows(rows,color,dim_color=None,x0=0,y0=0):
    on_c=scale_color(color)
    if dim_color is None: dim_color=(color[0]//3,color[1]//3,color[2]//3)
    dim_c=scale_color(dim_color)
    for ry,line in enumerate(rows):
        py=y0+ry
        if py<0 or py>=ROWS: continue
        for rx,ch in enumerate(line):
            idx=logical_to_led_index(x0+rx,py)
            if idx is None: continue
            if ch=="#": np[idx]=on_c
            elif ch=="+": np[idx]=dim_c

def _render_string(text,color,icon_rows=None,char_extra_x=None,icon_color=None):
    glyphs=[_glyph_for(ch) for ch in text]
    gap=1; total_w=0
    for i,(_,w) in enumerate(glyphs):
        total_w += w + (gap if i < len(glyphs)-1 else 0)
    x0=(COLS-total_w)//2
    y0=TEXT_Y_WITH_ICON if icon_rows is not None else (ROWS-GLYPH_H)//2
    clear()
    if icon_rows is not None:
        _draw_bitmap_rows(icon_rows, icon_color if icon_color is not None else color, x0=0, y0=ICON_TOP_Y)
    c=scale_color(color); x=x0; char_extra_x=char_extra_x or {}
    for gi,(rows,w) in enumerate(glyphs):
        for ry in range(GLYPH_H):
            line=rows[ry] if ry < len(rows) else ""
            for rx in range(w):
                if (line[rx] if rx < len(line) else ".") != "#": continue
                idx=logical_to_led_index(x+rx+int(char_extra_x.get(gi,0)), y0+ry)
                if idx is not None: np[idx]=c
        x += w + gap
    show()

def _format_interval(seconds):
    tenths=int(round(seconds*10)); whole=tenths//10; frac=tenths%10
    return "10" if whole==10 and frac==0 else "{}.{}".format(whole, frac)

def _sun_icon_rows(percent):
    return SUN_ICON_1

def _battery_fill_cols(percent):
    p = max(0, min(100, int(percent)))
    inner_cols = 8
    if p < 10:
        return 0
    if p > 90:
        return inner_cols
    return ((p - 10) * inner_cols + 79) // 80

def _battery_icon_rows(percent, charging=False, charging_phase_ms=0, charge_step_interval_s=1.0, flash_last_column=False, animate=True):
    rows = BATTERY_ICON[:]
    inner_rows = (2, 3, 4)
    inner_left = 7
    inner_cols = 8
    filled_cols = _battery_fill_cols(percent)

    if charging and animate:
        p = int(percent)
        if p < 10:
            # Below 10%: a single column (col 0) blinks on and off.
            # No sweep. Uses the same flash half-period as the discharging
            # low-battery flash for consistency.
            flash_period_ms = max(1, int(BATTERY_CHARGE_LAST_COLUMN_FLASH_MS))
            on = ((int(charging_phase_ms) // flash_period_ms) % 2) == 0
            lit_cols = 1 if on else 0
            flash_col = None
        else:
            # 10%-90%: solid sweep 1, 2, 3, ..., target, then back to 1.
            # Above 90%: target is the full 8 columns, same sweep mechanic.
            # At/above 100%: same as >90% (all eight columns participate).
            target_cols = inner_cols if p > 90 else max(1, filled_cols)
            step_ms = max(1, int(charge_step_interval_s * 1000))
            anim_step = int(charging_phase_ms) // step_ms
            lit_cols = (anim_step % target_cols) + 1
            flash_col = None
    else:
        lit_cols = filled_cols
        flash_col = (lit_cols - 1) if (flash_last_column and lit_cols > 0) else None

    flash_on = True
    if flash_col is not None:
        flash_period_ms = max(1, int(BATTERY_CHARGE_LAST_COLUMN_FLASH_MS))
        flash_on = ((int(charging_phase_ms) // flash_period_ms) % 2) == 0

    for y in inner_rows:
        row = list(rows[y])
        for i in range(inner_cols):
            x = inner_left + i
            ch = "."
            if i < lit_cols:
                ch = "#"
            if flash_col is not None and i == flash_col:
                ch = "#" if flash_on else "."
            row[x] = ch
        rows[y] = "".join(row)
    return rows

def render_interval(seconds,color=MODE_COLOR): _render_string(_format_interval(seconds)+"S", color, icon_rows=CLOCK_ICON)
def render_brightness_percent(percent,color=BRIGHTNESS_COLOR): _render_string("{}%".format(int(percent)), color, icon_rows=_sun_icon_rows(percent))
def render_battery_percent(percent,color=DEFAULT_COLOR,charging=False,charging_phase_ms=0,charge_step_interval_s=1.0,flash_last_column=False,animate=True):
    _render_string("{}%".format(int(percent)), color, icon_rows=_battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate=animate))
def render_percent(percent,color=DEFAULT_COLOR): _render_string("{}%".format(int(percent)), color)
def render_ip_octet(octet,color=MODE_COLOR): _render_string(str(int(octet)), color)
def _render_big_glyph(rows,w,h,color):
    c=scale_color(color); x0=(COLS-w)//2; y0=(ROWS-h)//2; clear()
    for ry in range(h):
        line=rows[ry] if ry < len(rows) else ""
        for rx in range(w):
            if (line[rx] if rx < len(line) else ".") != "#": continue
            idx=logical_to_led_index(x0+rx, y0+ry)
            if idx is not None: np[idx]=c
    show()
def render_mode(auto,color=MODE_COLOR): _render_big_glyph(_BIG_A if auto else _BIG_M,_BIG_W,_BIG_H,color)
def render_battery_voltage(voltage, percent=0, color=DEFAULT_COLOR, charging=False, charging_phase_ms=0, charge_step_interval_s=1.0, flash_last_column=False, text_color=None, animate=True):
    icon_rows=_battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate=animate)
    draw_color=text_color if text_color is not None else color
    if voltage is None:
        text = "0.0V"
    elif voltage < 10.0:
        text = "{:.1f}V".format(voltage)
    else:
        text = "{:.1f}V".format(voltage)
    _render_string(text, draw_color, icon_rows=icon_rows, char_extra_x={3:1}, icon_color=color)
def render_battery_time(hours_remaining, percent=0, color=DEFAULT_COLOR, charging=False, charging_phase_ms=0, charge_step_interval_s=1.0, flash_last_column=False, animate=True):
    if hours_remaining is None:
        text="--"
    elif hours_remaining <= 0.0:
        text="0M"
    else:
        minutes=int(round(hours_remaining*60.0))
        if minutes < 60:
            text="{}M".format(minutes)
        else:
            tenths_hours=max(10,min(99,int(round(hours_remaining*10.0))))
            whole=tenths_hours//10; frac=tenths_hours%10
            text="{}H".format(whole) if frac==0 else "{}.{}H".format(whole,frac)
    _render_string(text, color, icon_rows=_battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate=animate))
def render_charge_voltage(voltage, percent=0, icon_color=DEFAULT_COLOR, charging=False, charging_phase_ms=0, charge_step_interval_s=1.0, flash_last_column=False, animate=True):
    icon_rows=_battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate=animate)
    if voltage is None:
        text="0.0"
    else:
        text="{:.1f}".format(voltage)
    _render_string(text, (255,255,255), icon_rows=icon_rows, icon_color=icon_color)
# ---------------------------------------------------------------------------
# Full 22x18 irregular-matrix scrolling text renderer for B2+B6 IP/SSID.
# This is intentionally independent from the older centered number renderer.
# It uses only real LED cells; hidden/padded cells remain dark.
# ---------------------------------------------------------------------------
_SCROLL_FONT = dict(_FONT)
_SCROLL_FONT.update({
    " ": [".....",".....",".....",".....",".....",".....","....."],
    ".": [".....",".....",".....",".....",".....",".##..",".##.."],
    "-": [".....",".....",".....","#####",".....",".....","....."],
    "_": [".....",".....",".....",".....",".....",".....","#####"],
    "/": ["....#","...#.","...#.","..#..",".#...",".#...","#...."],
    ":": [".....",".##..",".##..",".....",".##..",".##..","....."],
    "A": [".###.","#...#","#...#","#####","#...#","#...#","#...#"],
    "B": ["####.","#...#","#...#","####.","#...#","#...#","####."],
    "C": [".####","#....","#....","#....","#....","#....",".####"],
    "D": ["####.","#...#","#...#","#...#","#...#","#...#","####."],
    "E": ["#####","#....","#....","####.","#....","#....","#####"],
    "F": ["#####","#....","#....","####.","#....","#....","#...."],
    "G": [".####","#....","#....","#.###","#...#","#...#",".###."],
    "I": ["#####","..#..","..#..","..#..","..#..","..#..","#####"],
    "J": ["..###","...#.","...#.","...#.","...#.","#..#.",".##.."],
    "K": ["#...#","#..#.","#.#..","##...","#.#..","#..#.","#...#"],
    "L": ["#....","#....","#....","#....","#....","#....","#####"],
    "N": ["#...#","##..#","#.#.#","#..##","#...#","#...#","#...#"],
    "O": [".###.","#...#","#...#","#...#","#...#","#...#",".###."],
    "P": ["####.","#...#","#...#","####.","#....","#....","#...."],
    "Q": [".###.","#...#","#...#","#...#","#.#.#","#..#.",".##.#"],
    "R": ["####.","#...#","#...#","####.","#.#..","#..#.","#...#"],
    "T": ["#####","..#..","..#..","..#..","..#..","..#..","..#.."],
    "U": ["#...#","#...#","#...#","#...#","#...#","#...#",".###."],
    "W": ["#...#","#...#","#...#","#.#.#","#.#.#","##.##","#...#"],
    "X": ["#...#","#...#",".#.#.","..#..",".#.#.","#...#","#...#"],
    "Y": ["#...#","#...#",".#.#.","..#..","..#..","..#..","..#.."],
    "Z": ["#####","....#","...#.","..#..",".#...","#....","#####"],
    "?": [".###.","#...#","....#","...#.","..#..",".....","..#.."],
})

def _scroll_columns(text):
    cols = []
    for ch in str(text or ""):
        g = _SCROLL_FONT.get(ch.upper(), _SCROLL_FONT.get("?"))
        w = len(g[0]) if g else 0
        for x in range(w):
            cols.append([1 if (g[y][x] if x < len(g[y]) else ".") == "#" else 0 for y in range(7)])
        cols.append([0,0,0,0,0,0,0])
    for _ in range(COLS):
        cols.append([0,0,0,0,0,0,0])
    return cols

def render_scrolling_text_window(text, offset=0, color=MODE_COLOR):
    cols = _scroll_columns(text)
    if not cols:
        cols = [[0,0,0,0,0,0,0]]
    c = scale_color(color)
    clear()
    y0 = 5
    for x in range(COLS):
        col = cols[(int(offset) + x) % len(cols)]
        for y in range(7):
            if not col[y]:
                continue
            idx = logical_to_led_index(x, y0 + y)
            if idx is not None:
                np[idx] = c
    show()
    return len(cols)
