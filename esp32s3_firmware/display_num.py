# Import: Loads COLS, ROWS, logical_to_led_index, np, clear, show, scale_color from board so this module can use that dependency.
from board import COLS, ROWS, logical_to_led_index, np, clear, show, scale_color
# Import: Loads BATTERY_CHARGE_LAST_COLUMN_FLASH_MS from config so this module can use that dependency.
from config import BATTERY_CHARGE_LAST_COLUMN_FLASH_MS

# Variable: _FONT stores the lookup table used by this module.
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
# Variable: _DOT stores the collection of values used later in this module.
_DOT=[".",".",".",".",".",".","#"]
# Variable: _PCT_3 stores the collection of values used later in this module.
_PCT_3=["#.#","..#",".#.",".#.","#..","#.#","..."]
# Variable: GLYPH_H stores the configured literal value.
GLYPH_H=7
# Variable: DEFAULT_COLOR stores the collection of values used later in this module.
DEFAULT_COLOR=(0,120,255)
# Variable: BRIGHTNESS_COLOR stores the collection of values used later in this module.
BRIGHTNESS_COLOR=(0,120,255)
# Variable: MODE_COLOR stores the collection of values used later in this module.
MODE_COLOR=(180,0,255)
# Variable: _BIG_A stores the collection of values used later in this module.
_BIG_A=["...####...","..######..",".##....##.",".##....##.",".##....##.",".##....##.",".########.",".########.",".##....##.",".##....##.",".##....##.",".##....##.",".##....##."]
# Variable: _BIG_M stores the collection of values used later in this module.
_BIG_M=["##......##","###....###","####..####","##.####.##","##..##..##","##......##","##......##","##......##","##......##","##......##","##......##","##......##","##......##"]
# Variable: _BIG_H stores the result returned by len().
# Variable: _BIG_W stores the result returned by len().
_BIG_W=len(_BIG_A[0]); _BIG_H=len(_BIG_A)
# Variable: CLOCK_ICON stores the collection of values used later in this module.
CLOCK_ICON=["......................",".........####.........","........#...##........","........#..#.#........","........#....#........","........#....#........",".........####.........","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
# Variable: SUN_ICON_1 stores the collection of values used later in this module.
SUN_ICON_1=["......................",".......#......#.##....","....##.#......#.......","........#....#........",".........####..#......",".......#........#.....","......#....#..........","...........#..........","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
# Variable: SUN_ICON_2 stores the collection of values used later in this module.
SUN_ICON_2=["......................",".......##....##.##....","....##.###..###.......","........######........",".........####..#......",".......#........#.....","......#....#..........","...........#..........","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
# Variable: SUN_ICON_3 stores the collection of values used later in this module.
SUN_ICON_3=["......................",".......########.##....","....##.########.......","........######........",".........####..#......",".......#........#.....","......#....#..........","...........#..........","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
# Variable: BATTERY_ICON stores the collection of values used later in this module.
BATTERY_ICON=["......................","......#########.......","......#........#......","......#........#......","......#........#......","......#########.......","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................","......................"]
# Variable: ICON_TOP_Y stores the configured literal value.
ICON_TOP_Y=0
# Variable: TEXT_Y_WITH_ICON stores the configured literal value.
TEXT_Y_WITH_ICON=9

# Return: Sends the expression ["."*w for _ in range(h)] back to the caller.
# Function: Defines _blank_bitmap(h, w) to handle blank bitmap behavior.
def _blank_bitmap(h,w): return ["."*w for _ in range(h)]
# Function: Defines _glyph_for(ch) to handle glyph for behavior.
def _glyph_for(ch):
    # Return: Sends the collection of values used later in this module back to the caller.
    # Logic: Branches when ch=="." so the correct firmware path runs.
    if ch==".": return (_DOT,1)
    # Return: Sends the collection of values used later in this module back to the caller.
    # Logic: Branches when ch=="%" so the correct firmware path runs.
    if ch=="%": return (_PCT_3,3)
    # Variable: g stores the result returned by _FONT.get().
    g=_FONT.get(ch)
    # Return: Sends the conditional expression (_blank_bitmap(7,5),5) if g is None else (g,len(g[0]) if g else 0) back to the caller.
    return (_blank_bitmap(7,5),5) if g is None else (g,len(g[0]) if g else 0)

# Function: Defines _draw_bitmap_rows(rows, color, dim_color, x0, y0) to handle draw bitmap rows behavior.
def _draw_bitmap_rows(rows,color,dim_color=None,x0=0,y0=0):
    # Variable: on_c stores the result returned by scale_color().
    on_c=scale_color(color)
    # Variable: dim_color stores the collection of values used later in this module.
    # Logic: Branches when dim_color is None so the correct firmware path runs.
    if dim_color is None: dim_color=(color[0]//3,color[1]//3,color[2]//3)
    # Variable: dim_c stores the result returned by scale_color().
    dim_c=scale_color(dim_color)
    # Loop: Iterates ry, line over enumerate(rows) so each item can be processed.
    for ry,line in enumerate(rows):
        # Variable: py stores the calculated expression y0+ry.
        py=y0+ry
        # Control: Skips to the next loop iteration after this case is handled.
        # Logic: Branches when py<0 or py>=ROWS so the correct firmware path runs.
        if py<0 or py>=ROWS: continue
        # Loop: Iterates rx, ch over enumerate(line) so each item can be processed.
        for rx,ch in enumerate(line):
            # Variable: idx stores the result returned by logical_to_led_index().
            idx=logical_to_led_index(x0+rx,py)
            # Control: Skips to the next loop iteration after this case is handled.
            # Logic: Branches when idx is None so the correct firmware path runs.
            if idx is None: continue
            # Variable: np[...] stores the current on_c value.
            # Logic: Branches when ch=="#" so the correct firmware path runs.
            if ch=="#": np[idx]=on_c
            # Variable: np[...] stores the current dim_c value.
            # Logic: Branches when ch=="+" so the correct firmware path runs.
            elif ch=="+": np[idx]=dim_c

# Function: Defines _render_string(text, color, icon_rows, char_extra_x, icon_color) to handle render string behavior.
def _render_string(text,color,icon_rows=None,char_extra_x=None,icon_color=None):
    # Variable: glyphs stores the expression [_glyph_for(ch) for ch in text].
    glyphs=[_glyph_for(ch) for ch in text]
    # Variable: total_w stores the configured literal value.
    # Variable: gap stores the configured literal value.
    gap=1; total_w=0
    # Loop: Iterates i, _, w over enumerate(glyphs) so each item can be processed.
    for i,(_,w) in enumerate(glyphs):
        # Variable: Updates total_w in place using the calculated expression w + (gap if i < len(glyphs)-1 else 0).
        total_w += w + (gap if i < len(glyphs)-1 else 0)
    # Variable: x0 stores the calculated expression (COLS-total_w)//2.
    x0=(COLS-total_w)//2
    # Variable: y0 stores the conditional expression TEXT_Y_WITH_ICON if icon_rows is not None else (ROWS-GLYPH_H)//2.
    y0=TEXT_Y_WITH_ICON if icon_rows is not None else (ROWS-GLYPH_H)//2
    # Expression: Calls clear() for its side effects.
    clear()
    # Logic: Branches when icon_rows is not None so the correct firmware path runs.
    if icon_rows is not None:
        # Expression: Calls _draw_bitmap_rows() for its side effects.
        _draw_bitmap_rows(icon_rows, icon_color if icon_color is not None else color, x0=0, y0=ICON_TOP_Y)
    # Variable: char_extra_x stores the combined condition char_extra_x or {}.
    # Variable: x stores the current x0 value.
    # Variable: c stores the result returned by scale_color().
    c=scale_color(color); x=x0; char_extra_x=char_extra_x or {}
    # Loop: Iterates gi, rows, w over enumerate(glyphs) so each item can be processed.
    for gi,(rows,w) in enumerate(glyphs):
        # Loop: Iterates ry over range(GLYPH_H) so each item can be processed.
        for ry in range(GLYPH_H):
            # Variable: line stores the conditional expression rows[ry] if ry < len(rows) else "".
            line=rows[ry] if ry < len(rows) else ""
            # Loop: Iterates rx over range(w) so each item can be processed.
            for rx in range(w):
                # Control: Skips to the next loop iteration after this case is handled.
                # Logic: Branches when (line[rx] if rx < len(line) else ".") != "#" so the correct firmware path runs.
                if (line[rx] if rx < len(line) else ".") != "#": continue
                # Variable: idx stores the result returned by logical_to_led_index().
                idx=logical_to_led_index(x+rx+int(char_extra_x.get(gi,0)), y0+ry)
                # Variable: np[...] stores the current c value.
                # Logic: Branches when idx is not None so the correct firmware path runs.
                if idx is not None: np[idx]=c
        # Variable: Updates x in place using the calculated expression w + gap.
        x += w + gap
    # Expression: Calls show() for its side effects.
    show()

# Function: Defines _format_interval(seconds) to handle format interval behavior.
def _format_interval(seconds):
    # Variable: frac stores the calculated expression tenths%10.
    # Variable: whole stores the calculated expression tenths//10.
    # Variable: tenths stores the result returned by int().
    tenths=int(round(seconds*10)); whole=tenths//10; frac=tenths%10
    # Return: Sends the conditional expression "10" if whole==10 and frac==0 else "{}.{}".format(whole, frac) back to the caller.
    return "10" if whole==10 and frac==0 else "{}.{}".format(whole, frac)

# Function: Defines _sun_icon_rows(percent) to handle sun icon rows behavior.
def _sun_icon_rows(percent):
    # Return: Sends the current SUN_ICON_1 value back to the caller.
    return SUN_ICON_1

# Function: Defines _battery_fill_cols(percent) to handle battery fill cols behavior.
def _battery_fill_cols(percent):
    # Variable: p stores the result returned by max().
    p = max(0, min(100, int(percent)))
    # Variable: inner_cols stores the configured literal value.
    inner_cols = 8
    # Logic: Branches when p < 10 so the correct firmware path runs.
    if p < 10:
        # Return: Sends the configured literal value back to the caller.
        return 0
    # Logic: Branches when p > 90 so the correct firmware path runs.
    if p > 90:
        # Return: Sends the current inner_cols value back to the caller.
        return inner_cols
    # Return: Sends the calculated expression ((p - 10) * inner_cols + 79) // 80 back to the caller.
    return ((p - 10) * inner_cols + 79) // 80

# Function: Defines _battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate) to handle battery icon rows behavior.
def _battery_icon_rows(percent, charging=False, charging_phase_ms=0, charge_step_interval_s=1.0, flash_last_column=False, animate=True):
    # Variable: rows stores the selected item BATTERY_ICON[:].
    rows = BATTERY_ICON[:]
    # Variable: inner_rows stores the collection of values used later in this module.
    inner_rows = (2, 3, 4)
    # Variable: inner_left stores the configured literal value.
    inner_left = 7
    # Variable: inner_cols stores the configured literal value.
    inner_cols = 8
    # Variable: filled_cols stores the result returned by _battery_fill_cols().
    filled_cols = _battery_fill_cols(percent)

    # Logic: Branches when charging and animate so the correct firmware path runs.
    if charging and animate:
        # Variable: p stores the result returned by int().
        p = int(percent)
        # Logic: Branches when p < 10 so the correct firmware path runs.
        if p < 10:
            # Below 10%: a single column (col 0) blinks on and off.
            # No sweep. Uses the same flash half-period as the discharging
            # low-battery flash for consistency.
            # Variable: flash_period_ms stores the result returned by max().
            flash_period_ms = max(1, int(BATTERY_CHARGE_LAST_COLUMN_FLASH_MS))
            # Variable: on stores the comparison result ((int(charging_phase_ms) // flash_period_ms) % 2) == 0.
            on = ((int(charging_phase_ms) // flash_period_ms) % 2) == 0
            # Variable: lit_cols stores the conditional expression 1 if on else 0.
            lit_cols = 1 if on else 0
            # Variable: flash_col stores the empty sentinel value.
            flash_col = None
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # 10%-90%: solid sweep 1, 2, 3, ..., target, then back to 1.
            # Above 90%: target is the full 8 columns, same sweep mechanic.
            # At/above 100%: same as >90% (all eight columns participate).
            # Variable: target_cols stores the conditional expression inner_cols if p > 90 else max(1, filled_cols).
            target_cols = inner_cols if p > 90 else max(1, filled_cols)
            # Variable: step_ms stores the result returned by max().
            step_ms = max(1, int(charge_step_interval_s * 1000))
            # Variable: anim_step stores the calculated expression int(charging_phase_ms) // step_ms.
            anim_step = int(charging_phase_ms) // step_ms
            # Variable: lit_cols stores the calculated expression (anim_step % target_cols) + 1.
            lit_cols = (anim_step % target_cols) + 1
            # Variable: flash_col stores the empty sentinel value.
            flash_col = None
    # Logic: Runs this fallback branch when the earlier condition did not match.
    else:
        # Variable: lit_cols stores the current filled_cols value.
        lit_cols = filled_cols
        # Variable: flash_col stores the conditional expression (lit_cols - 1) if (flash_last_column and lit_cols > 0) else None.
        flash_col = (lit_cols - 1) if (flash_last_column and lit_cols > 0) else None

    # Variable: flash_on stores the enabled/disabled flag value.
    flash_on = True
    # Logic: Branches when flash_col is not None so the correct firmware path runs.
    if flash_col is not None:
        # Variable: flash_period_ms stores the result returned by max().
        flash_period_ms = max(1, int(BATTERY_CHARGE_LAST_COLUMN_FLASH_MS))
        # Variable: flash_on stores the comparison result ((int(charging_phase_ms) // flash_period_ms) % 2) == 0.
        flash_on = ((int(charging_phase_ms) // flash_period_ms) % 2) == 0

    # Loop: Iterates y over inner_rows so each item can be processed.
    for y in inner_rows:
        # Variable: row stores the result returned by list().
        row = list(rows[y])
        # Loop: Iterates i over range(inner_cols) so each item can be processed.
        for i in range(inner_cols):
            # Variable: x stores the calculated expression inner_left + i.
            x = inner_left + i
            # Variable: ch stores the configured text value.
            ch = "."
            # Logic: Branches when i < lit_cols so the correct firmware path runs.
            if i < lit_cols:
                # Variable: ch stores the configured text value.
                ch = "#"
            # Logic: Branches when flash_col is not None and i == flash_col so the correct firmware path runs.
            if flash_col is not None and i == flash_col:
                # Variable: ch stores the conditional expression "#" if flash_on else ".".
                ch = "#" if flash_on else "."
            # Variable: row[...] stores the current ch value.
            row[x] = ch
        # Variable: rows[...] stores the result returned by join().
        rows[y] = "".join(row)
    # Return: Sends the current rows value back to the caller.
    return rows

# Expression: Calls _render_string() for its side effects.
# Function: Defines render_interval(seconds, color) to handle render interval behavior.
def render_interval(seconds,color=MODE_COLOR): _render_string(_format_interval(seconds)+"S", color, icon_rows=CLOCK_ICON)
# Expression: Calls _render_string() for its side effects.
# Function: Defines render_brightness_percent(percent, color) to handle render brightness percent behavior.
def render_brightness_percent(percent,color=BRIGHTNESS_COLOR): _render_string("{}%".format(int(percent)), color, icon_rows=_sun_icon_rows(percent))
# Function: Defines render_battery_percent(percent, color, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate) to handle render battery percent behavior.
def render_battery_percent(percent,color=DEFAULT_COLOR,charging=False,charging_phase_ms=0,charge_step_interval_s=1.0,flash_last_column=False,animate=True):
    # Expression: Calls _render_string() for its side effects.
    _render_string("{}%".format(int(percent)), color, icon_rows=_battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate=animate))
# Expression: Calls _render_string() for its side effects.
# Function: Defines render_percent(percent, color) to handle render percent behavior.
def render_percent(percent,color=DEFAULT_COLOR): _render_string("{}%".format(int(percent)), color)
# Expression: Calls _render_string() for its side effects.
# Function: Defines render_ip_octet(octet, color) to handle render ip octet behavior.
def render_ip_octet(octet,color=MODE_COLOR): _render_string(str(int(octet)), color)
# Function: Defines _render_big_glyph(rows, w, h, color) to handle render big glyph behavior.
def _render_big_glyph(rows,w,h,color):
    # Expression: Calls clear() for its side effects.
    # Variable: y0 stores the calculated expression (ROWS-h)//2.
    # Variable: x0 stores the calculated expression (COLS-w)//2.
    # Variable: c stores the result returned by scale_color().
    c=scale_color(color); x0=(COLS-w)//2; y0=(ROWS-h)//2; clear()
    # Loop: Iterates ry over range(h) so each item can be processed.
    for ry in range(h):
        # Variable: line stores the conditional expression rows[ry] if ry < len(rows) else "".
        line=rows[ry] if ry < len(rows) else ""
        # Loop: Iterates rx over range(w) so each item can be processed.
        for rx in range(w):
            # Control: Skips to the next loop iteration after this case is handled.
            # Logic: Branches when (line[rx] if rx < len(line) else ".") != "#" so the correct firmware path runs.
            if (line[rx] if rx < len(line) else ".") != "#": continue
            # Variable: idx stores the result returned by logical_to_led_index().
            idx=logical_to_led_index(x0+rx, y0+ry)
            # Variable: np[...] stores the current c value.
            # Logic: Branches when idx is not None so the correct firmware path runs.
            if idx is not None: np[idx]=c
    # Expression: Calls show() for its side effects.
    show()
# Expression: Calls _render_big_glyph() for its side effects.
# Function: Defines render_mode(auto, color) to handle render mode behavior.
def render_mode(auto,color=MODE_COLOR): _render_big_glyph(_BIG_A if auto else _BIG_M,_BIG_W,_BIG_H,color)
# Function: Defines render_battery_voltage(voltage, percent, color, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, text_color, animate) to handle render battery voltage behavior.
def render_battery_voltage(voltage, percent=0, color=DEFAULT_COLOR, charging=False, charging_phase_ms=0, charge_step_interval_s=1.0, flash_last_column=False, text_color=None, animate=True):
    # Variable: icon_rows stores the result returned by _battery_icon_rows().
    icon_rows=_battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate=animate)
    # Variable: draw_color stores the conditional expression text_color if text_color is not None else color.
    draw_color=text_color if text_color is not None else color
    # Logic: Branches when voltage is None so the correct firmware path runs.
    if voltage is None:
        # Variable: text stores the configured text value.
        text = "0.0V"
    # Logic: Branches when voltage < 10.0 so the correct firmware path runs.
    elif voltage < 10.0:
        # Variable: text stores the result returned by format().
        text = "{:.1f}V".format(voltage)
    # Logic: Runs this fallback branch when the earlier condition did not match.
    else:
        # Variable: text stores the result returned by format().
        text = "{:.1f}V".format(voltage)
    # Expression: Calls _render_string() for its side effects.
    _render_string(text, draw_color, icon_rows=icon_rows, char_extra_x={3:1}, icon_color=color)
# Function: Defines render_battery_time(hours_remaining, percent, color, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate) to handle render battery time behavior.
def render_battery_time(hours_remaining, percent=0, color=DEFAULT_COLOR, charging=False, charging_phase_ms=0, charge_step_interval_s=1.0, flash_last_column=False, animate=True):
    # Logic: Branches when hours_remaining is None so the correct firmware path runs.
    if hours_remaining is None:
        # Variable: text stores the configured text value.
        text="--"
    # Logic: Branches when hours_remaining <= 0.0 so the correct firmware path runs.
    elif hours_remaining <= 0.0:
        # Variable: text stores the configured text value.
        text="0M"
    # Logic: Runs this fallback branch when the earlier condition did not match.
    else:
        # Variable: minutes stores the result returned by int().
        minutes=int(round(hours_remaining*60.0))
        # Logic: Branches when minutes < 60 so the correct firmware path runs.
        if minutes < 60:
            # Variable: text stores the result returned by format().
            text="{}M".format(minutes)
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: tenths_hours stores the result returned by max().
            tenths_hours=max(10,min(99,int(round(hours_remaining*10.0))))
            # Variable: frac stores the calculated expression tenths_hours%10.
            # Variable: whole stores the calculated expression tenths_hours//10.
            whole=tenths_hours//10; frac=tenths_hours%10
            # Variable: text stores the conditional expression "{}H".format(whole) if frac==0 else "{}.{}H".format(whole,frac).
            text="{}H".format(whole) if frac==0 else "{}.{}H".format(whole,frac)
    # Expression: Calls _render_string() for its side effects.
    _render_string(text, color, icon_rows=_battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate=animate))
# Function: Defines render_charge_voltage(voltage, percent, icon_color, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate) to handle render charge voltage behavior.
def render_charge_voltage(voltage, percent=0, icon_color=DEFAULT_COLOR, charging=False, charging_phase_ms=0, charge_step_interval_s=1.0, flash_last_column=False, animate=True):
    # Variable: icon_rows stores the result returned by _battery_icon_rows().
    icon_rows=_battery_icon_rows(percent, charging, charging_phase_ms, charge_step_interval_s, flash_last_column, animate=animate)
    # Logic: Branches when voltage is None so the correct firmware path runs.
    if voltage is None:
        # Variable: text stores the configured text value.
        text="0.0"
    # Logic: Runs this fallback branch when the earlier condition did not match.
    else:
        # Variable: text stores the result returned by format().
        text="{:.1f}".format(voltage)
    # Expression: Calls _render_string() for its side effects.
    _render_string(text, (255,255,255), icon_rows=icon_rows, icon_color=icon_color)
# ---------------------------------------------------------------------------
# Full 22x18 irregular-matrix scrolling text renderer for B2+B6 IP/SSID.
# This is intentionally independent from the older centered number renderer.
# It uses only real LED cells; hidden/padded cells remain dark.
# ---------------------------------------------------------------------------
# Variable: _SCROLL_FONT stores the result returned by dict().
_SCROLL_FONT = dict(_FONT)
# Expression: Calls _SCROLL_FONT.update() for its side effects.
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

# Function: Defines _scroll_columns(text) to handle scroll columns behavior.
def _scroll_columns(text):
    # Variable: cols stores the collection of values used later in this module.
    cols = []
    # Loop: Iterates ch over str(text or "") so each item can be processed.
    for ch in str(text or ""):
        # Variable: g stores the result returned by _SCROLL_FONT.get().
        g = _SCROLL_FONT.get(ch.upper(), _SCROLL_FONT.get("?"))
        # Variable: w stores the conditional expression len(g[0]) if g else 0.
        w = len(g[0]) if g else 0
        # Loop: Iterates x over range(w) so each item can be processed.
        for x in range(w):
            # Expression: Calls cols.append() for its side effects.
            cols.append([1 if (g[y][x] if x < len(g[y]) else ".") == "#" else 0 for y in range(7)])
        # Expression: Calls cols.append() for its side effects.
        cols.append([0,0,0,0,0,0,0])
    # Loop: Iterates _ over range(COLS) so each item can be processed.
    for _ in range(COLS):
        # Expression: Calls cols.append() for its side effects.
        cols.append([0,0,0,0,0,0,0])
    # Return: Sends the current cols value back to the caller.
    return cols

# Function: Defines render_scrolling_text_window(text, offset, color) to handle render scrolling text window behavior.
def render_scrolling_text_window(text, offset=0, color=MODE_COLOR):
    # Variable: cols stores the result returned by _scroll_columns().
    cols = _scroll_columns(text)
    # Logic: Branches when not cols so the correct firmware path runs.
    if not cols:
        # Variable: cols stores the collection of values used later in this module.
        cols = [[0,0,0,0,0,0,0]]
    # Variable: c stores the result returned by scale_color().
    c = scale_color(color)
    # Expression: Calls clear() for its side effects.
    clear()
    # Variable: y0 stores the configured literal value.
    y0 = 5
    # Loop: Iterates x over range(COLS) so each item can be processed.
    for x in range(COLS):
        # Variable: col stores the selected item cols[(int(offset) + x) % len(cols)].
        col = cols[(int(offset) + x) % len(cols)]
        # Loop: Iterates y over range(7) so each item can be processed.
        for y in range(7):
            # Logic: Branches when not col[y] so the correct firmware path runs.
            if not col[y]:
                # Control: Skips to the next loop iteration after this case is handled.
                continue
            # Variable: idx stores the result returned by logical_to_led_index().
            idx = logical_to_led_index(x, y0 + y)
            # Logic: Branches when idx is not None so the correct firmware path runs.
            if idx is not None:
                # Variable: np[...] stores the current c value.
                np[idx] = c
    # Expression: Calls show() for its side effects.
    show()
    # Return: Sends the result returned by len() back to the caller.
    return len(cols)
