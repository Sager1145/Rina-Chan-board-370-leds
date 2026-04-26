import ujson as json
from config import (
    ROWS, COLS, LEGACY_SRC_WIDTH, LEGACY_SRC_HEIGHT,
    LEGACY_ROW_OFFSET, LEGACY_COL_OFFSET,
)
import board
import logger as log


def blank_bitmap():
    return ['.' * COLS for _ in range(ROWS)]


def normalize_bitmap(data):
    src_type = type(data).__name__
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
    log.trace('FACE_CODEC', 'normalize bitmap', src_type=src_type, rows=len(rows))
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
    log.info('FACE_CODEC', 'legacy hex to bitmap', hex_len=len(str(hexstr)), offset_rows=offset_rows, row_offset=row_offset, col_offset=col_offset)
    return legacy_grid_to_bitmap(legacy_hex_to_grid(hexstr, offset_rows=offset_rows), row_offset, col_offset)


def draw_bitmap_data(data, on_color, dim_color):
    board.draw_bitmap(normalize_bitmap(data), on_color=on_color, dim_color=dim_color)


def bitmap_to_points(bitmap):
    bm = normalize_bitmap(bitmap)
    points = []
    for y, row in enumerate(bm):
        for x, ch in enumerate(row):
            if ch != '.' and board.is_real_cell(x, y):
                points.append([x, y, 'dim' if ch == '+' else 'on'])
    log.debug('FACE_CODEC', 'bitmap to points', count=len(points))
    return points
