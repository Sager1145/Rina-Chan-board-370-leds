import ujson as json
from config import (
    ROWS, COLS, LEGACY_SRC_WIDTH, LEGACY_SRC_HEIGHT,
    LEGACY_ROW_OFFSET, LEGACY_COL_OFFSET,
)
import board
def blank_bitmap():
    return ['.' * COLS for _ in range(ROWS)]
def normalize_bitmap(data):
    if isinstance(data, str):
        text = data.strip()
        if text.startswith('['):
            try:
                data = json.loads(text)
            except Exception:
                data = text.splitlines()
        else:
            data = text.replace('|', '\n').splitlines()
    rows = []
    for y in range(ROWS):
        row = data[y] if y < len(data) else ''
        row = str(row)
        out = []
        for x in range(COLS):
            ch = row[x] if x < len(row) else '.'
            out.append('#' if ch == '#' else ('+' if ch == '+' else '.'))
        rows.append(''.join(out))
    return rows
def legacy_bits_to_grid(bit_bytes, offset_rows=0):
    grid = [[0 for _ in range(LEGACY_SRC_WIDTH)] for _ in range(LEGACY_SRC_HEIGHT)]
    bit_index = 0
    for byte in bit_bytes:
        if isinstance(byte, str):
            byte = ord(byte)
        for bit in range(7, -1, -1):
            row = offset_rows + (bit_index // LEGACY_SRC_WIDTH)
            col = bit_index % LEGACY_SRC_WIDTH
            if row >= LEGACY_SRC_HEIGHT:
                return grid
            if row >= 0:
                grid[row][col] = 1 if (byte & (1 << bit)) else 0
            bit_index += 1
    return grid
def legacy_hex_to_grid(hexstr, offset_rows=0):
    s = ''.join(str(hexstr).strip().split())
    data = bytearray()
    if len(s) % 2:
        s += '0'
    for i in range(0, len(s), 2):
        try:
            data.append(int(s[i:i + 2], 16))
        except Exception:
            data.append(0)
    return legacy_bits_to_grid(data, offset_rows=offset_rows)
def legacy_grid_to_bitmap(grid, row_offset=LEGACY_ROW_OFFSET, col_offset=LEGACY_COL_OFFSET):
    out = [['.' for _ in range(COLS)] for _ in range(ROWS)]
    for y in range(min(LEGACY_SRC_HEIGHT, len(grid))):
        yy = y + row_offset
        if yy < 0 or yy >= ROWS:
            continue
        row = grid[y]
        for x in range(min(LEGACY_SRC_WIDTH, len(row))):
            xx = x + col_offset
            if xx < 0 or xx >= COLS:
                continue
            if row[x]:
                out[yy][xx] = '#'
    return [''.join(r) for r in out]
def legacy_hex_to_bitmap(hexstr, offset_rows=0, row_offset=LEGACY_ROW_OFFSET, col_offset=LEGACY_COL_OFFSET):
    return legacy_grid_to_bitmap(legacy_hex_to_grid(hexstr, offset_rows=offset_rows), row_offset, col_offset)
def m370_hex_to_bitmap(hexstr):
    s = str(hexstr or '').strip()
    if s.upper().startswith('M370:'):
        s = s[5:]
    bits = ''
    for c in ''.join(s.split()):
        try:
            v = int(c, 16)
        except Exception:
            continue
        bits += '1' if (v & 8) else '0'
        bits += '1' if (v & 4) else '0'
        bits += '1' if (v & 2) else '0'
        bits += '1' if (v & 1) else '0'
    out = [['.' for _ in range(COLS)] for _ in range(ROWS)]
    k = 0
    for y in range(ROWS):
        for x in range(COLS):
            if not board.is_real_cell(x, y):
                continue
            if k < len(bits) and bits[k] == '1':
                out[y][x] = '#'
            k += 1
    return [''.join(r) for r in out]
def bitmap_to_m370_hex(bitmap):
    bm = normalize_bitmap(bitmap)
    bits = ''
    for y in range(ROWS):
        row = bm[y] if y < len(bm) else ''
        for x in range(COLS):
            if not board.is_real_cell(x, y):
                continue
            ch = row[x] if x < len(row) else '.'
            bits += '1' if ch in ('#', '+') else '0'
    while len(bits) % 4:
        bits += '0'
    out = ''
    for i in range(0, len(bits), 4):
        try:
            out += '{:X}'.format(int(bits[i:i + 4], 2))
        except Exception:
            out += '0'
    return out
def bitmap_to_legacy_hex(bitmap):
    bm = normalize_bitmap(bitmap)
    bits = ''
    for y in range(LEGACY_SRC_HEIGHT):
        yy = y + LEGACY_ROW_OFFSET
        row = bm[yy] if 0 <= yy < len(bm) else ''
        for x in range(LEGACY_SRC_WIDTH):
            xx = x + LEGACY_COL_OFFSET
            ch = row[xx] if 0 <= xx < len(row) else '.'
            bits += '1' if ch in ('#', '+') else '0'
    while len(bits) % 8:
        bits += '0'
    out = ''
    for i in range(0, len(bits), 8):
        try:
            out += '{:02X}'.format(int(bits[i:i + 8], 2))
        except Exception:
            out += '00'
    return out
def draw_bitmap_data(data, on_color, dim_color):
    board.draw_bitmap(normalize_bitmap(data), on_color=on_color, dim_color=dim_color)
def bitmap_to_points(bitmap):
    bm = normalize_bitmap(bitmap)
    points = []
    for y, row in enumerate(bm):
        for x, ch in enumerate(row):
            if ch != '.' and board.is_real_cell(x, y):
                points.append([x, y, 'dim' if ch == '+' else 'on'])
    return points
