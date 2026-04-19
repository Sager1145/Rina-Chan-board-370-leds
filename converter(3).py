#!/usr/bin/env python3
"""converter.py

PC-side converter for Bad Apple source video.

What this script does:
- samples the input video down to the requested FPS
- resizes frames to the requested LED matrix dimensions
- thresholds to 1-bit black/white pixels
- packs each frame into bytes
- compresses all frames with a simple RLE scheme
- splits the result into badapple_partX.py modules
- writes a standalone player.py and main.py for the generated output

Required dependency on the PC:
    pip install opencv-python

Example command for the converter:
    python converter.py input.mp4 output_dir --fps 15 --width 22 --height 18 --threshold 128 --frames-per-file 200

If your source video is inverted, add:
    --invert
"""
import argparse
from pathlib import Path

try:
    import cv2
except ImportError:
    raise SystemExit("error: install opencv-python first: pip install opencv-python")

PLAYER_TEMPLATE = '"""\nplayer.py\n\nRuntime Bad Apple player for the 370-LED 22x18 shaped matrix.\nLoads compressed video segments one at a time and plays them in sequence.\n"""\n\nimport gc\nimport sys\nimport time\n\ntry:\n    from machine import Pin\n    from neopixel import NeoPixel\nexcept ImportError:\n    Pin = NeoPixel = None\n\nLED_PIN = 15\nNUM_LEDS = 370\nROW_LENGTHS = [18,20,20,20,22,22,22,22,22,22,22,22,22,20,20,20,18,16]\nROWS = len(ROW_LENGTHS)\nCOLS = max(ROW_LENGTHS)\nSERPENTINE = True\nFLIP_X = False\nFLIP_Y = False\nMAX_BRIGHTNESS_HARD_CAP = 100\nMAX_BRIGHTNESS_FLOOR = 10\nMAX_BRIGHTNESS_DEFAULT = 20\nMAX_BRIGHTNESS = MAX_BRIGHTNESS_DEFAULT\nON_COLOR = (255,255,255)\nOFF_COLOR = (0,0,0)\nPART_MODULES = {part_modules}\n\nROW_STARTS = []\n_a = 0\nfor _w in ROW_LENGTHS:\n    ROW_STARTS.append(_a)\n    _a += _w\nassert _a == NUM_LEDS\n\nif Pin is not None and NeoPixel is not None:\n    np = NeoPixel(Pin(LED_PIN, Pin.OUT), NUM_LEDS)\nelse:\n    class _DummyNP:\n        def __init__(self, n): self.buf = [(0,0,0)] * n\n        def __setitem__(self, i, v): self.buf[i] = v\n        def write(self): pass\n    np = _DummyNP(NUM_LEDS)\n\n\ndef set_max_brightness(v):\n    global MAX_BRIGHTNESS\n    MAX_BRIGHTNESS = max(MAX_BRIGHTNESS_FLOOR, min(MAX_BRIGHTNESS_HARD_CAP, int(v)))\n    return MAX_BRIGHTNESS\n\n\ndef scale_color(rgb):\n    r, g, b = rgb\n    m = max(r, g, b)\n    if m <= MAX_BRIGHTNESS:\n        return max(0, min(255, int(r))), max(0, min(255, int(g))), max(0, min(255, int(b)))\n    s = MAX_BRIGHTNESS / float(m)\n    return int(r * s), int(g * s), int(b * s)\n\n\ndef logical_to_led_index(x, y):\n    if x < 0 or x >= COLS or y < 0 or y >= ROWS:\n        return None\n    if FLIP_X:\n        x = COLS - 1 - x\n    if FLIP_Y:\n        y = ROWS - 1 - y\n    w = ROW_LENGTHS[y]\n    pad = (COLS - w) >> 1\n    if x < pad or x >= pad + w:\n        return None\n    x -= pad\n    if SERPENTINE and (y & 1):\n        x = w - 1 - x\n    return ROW_STARTS[y] + x\n\n\ndef clear(write=False):\n    c = scale_color(OFF_COLOR)\n    for i in range(NUM_LEDS):\n        np[i] = c\n    if write:\n        np.write()\n\n\ndef show():\n    np.write()\n\n\ndef rle_decode(src, raw_len):\n    out = bytearray(raw_len)\n    si = 0\n    oi = 0\n    n = len(src)\n    while si < n and oi < raw_len:\n        ctrl = src[si]\n        si += 1\n        if ctrl < 128:\n            ln = ctrl + 1\n            out[oi:oi + ln] = src[si:si + ln]\n            si += ln\n            oi += ln\n        else:\n            ln = ctrl - 127\n            b = src[si]\n            si += 1\n            out[oi:oi + ln] = bytes((b,)) * ln\n            oi += ln\n    if oi != raw_len:\n        raise ValueError(\'decode length mismatch\')\n    return out\n\n\nclass SplitVideoPlayer:\n    __slots__ = (\n        \'fps\', \'width\', \'height\', \'loop\', \'frame_period_ms\', \'next_frame_ms\',\n        \'x_offset\', \'y_offset\', \'on_scaled\', \'off_scaled\', \'enabled\',\n        \'part_index\', \'frame_index\', \'frame_bytes\', \'frames_count\', \'data\'\n    )\n\n    def __init__(self, loop=True):\n        self.loop = bool(loop)\n        self.enabled = False\n        self.part_index = 0\n        self.frame_index = 0\n        self.data = b\'\'\n        self.fps = 10\n        self.width = 20\n        self.height = 15\n        self.frame_bytes = 38\n        self.frames_count = 0\n        self.frame_period_ms = 100\n        self.next_frame_ms = 0\n        self.x_offset = 0\n        self.y_offset = 0\n        self.on_scaled = scale_color(ON_COLOR)\n        self.off_scaled = scale_color(OFF_COLOR)\n        self._load_part(0)\n\n    def _refresh_palette(self):\n        self.on_scaled = scale_color(ON_COLOR)\n        self.off_scaled = scale_color(OFF_COLOR)\n\n    def _drop_current_part(self):\n        self.data = b\'\'\n        self.frames_count = 0\n        self.frame_index = 0\n        gc.collect()\n\n    def _load_part(self, part_index):\n        self._drop_current_part()\n        name = PART_MODULES[part_index]\n        gc.collect()\n        mod = __import__(name)\n        self.part_index = part_index\n        self.fps = mod.FPS\n        self.width = mod.WIDTH\n        self.height = mod.HEIGHT\n        self.frame_bytes = mod.FRAME_BYTES\n        self.frames_count = mod.FRAMES_COUNT\n        self.data = rle_decode(mod.DATA, mod.RAW_BYTES)\n        self.frame_period_ms = max(1, 1000 // max(1, self.fps))\n        self.x_offset = max(0, (COLS - self.width) >> 1)\n        self.y_offset = max(0, (ROWS - self.height) >> 1)\n        if name in sys.modules:\n            del sys.modules[name]\n        del mod\n        gc.collect()\n        if len(self.data) != self.frames_count * self.frame_bytes:\n            raise ValueError(\'packed data length mismatch\')\n\n    def _advance_part(self):\n        nxt = self.part_index + 1\n        if nxt >= len(PART_MODULES):\n            if not self.loop:\n                self.enabled = False\n                return False\n            nxt = 0\n        self._load_part(nxt)\n        return True\n\n    def draw_frame(self, frame_index=None):\n        fi = self.frame_index if frame_index is None else frame_index\n        start = fi * self.frame_bytes\n        self._refresh_palette()\n        bit = 0\n        for y in range(self.height):\n            py = y + self.y_offset\n            for x in range(self.width):\n                idx = logical_to_led_index(x + self.x_offset, py)\n                on = self.data[start + (bit >> 3)] & (1 << (7 - (bit & 7)))\n                if idx is not None:\n                    np[idx] = self.on_scaled if on else self.off_scaled\n                bit += 1\n        show()\n\n    def enter(self):\n        self.enabled = True\n        self._load_part(0)\n        clear(True)\n        self.draw_frame(0)\n        self.next_frame_ms = time.ticks_add(time.ticks_ms(), self.frame_period_ms)\n\n    def stop(self):\n        self.enabled = False\n        clear(True)\n\n    def _advance_one_frame(self):\n        self.frame_index += 1\n        if self.frame_index < self.frames_count:\n            return True\n        return self._advance_part()\n\n    def play_step(self):\n        if not self.enabled:\n            return False\n        now = time.ticks_ms()\n        if time.ticks_diff(now, self.next_frame_ms) < 0:\n            return True\n        needs_draw = False\n        while time.ticks_diff(now, self.next_frame_ms) >= 0:\n            if not self._advance_one_frame():\n                return False\n            self.next_frame_ms = time.ticks_add(self.next_frame_ms, self.frame_period_ms)\n            needs_draw = True\n        if needs_draw:\n            self.draw_frame(self.frame_index)\n        return True\n'
MAIN_TEMPLATE = 'import time\nimport player\n\nplayer.set_max_brightness(20)\nv = player.SplitVideoPlayer(loop=True)\nv.enter()\nwhile True:\n    v.play_step()\n    time.sleep_ms(1)\n'


# ---------------------------------------------------------------------------
# Resize one grayscale frame, threshold it to 1-bit pixels, and pack those
# pixels into bytes (MSB first). One bit = one LED pixel.
# ---------------------------------------------------------------------------
def pack_frame(gray, w, h, threshold, invert=False):
    img = cv2.resize(gray, (w, h), interpolation=cv2.INTER_AREA)
    out = bytearray((w * h + 7) // 8)
    bit = 0
    for y in range(h):
        for x in range(w):
            v = int(img[y, x])
            if invert:
                v = 255 - v
            if v >= threshold:
                out[bit >> 3] |= 1 << (7 - (bit & 7))
            bit += 1
    return bytes(out)


# ---------------------------------------------------------------------------
# Compress a byte stream using a simple custom RLE format.
# - repeated runs of length >= 3 are stored as repeat runs
# - everything else is emitted as literal blocks
# ---------------------------------------------------------------------------
def rle_encode(data):
    out = bytearray()
    n = len(data)
    i = 0
    lit_start = 0
    while i < n:
        run_len = 1
        b = data[i]
        while i + run_len < n and run_len < 128 and data[i + run_len] == b:
            run_len += 1
        if run_len >= 3:
            while lit_start < i:
                lit_len = min(128, i - lit_start)
                out.append(lit_len - 1)
                out.extend(data[lit_start:lit_start + lit_len])
                lit_start += lit_len
            out.append(127 + run_len)
            out.append(b)
            i += run_len
            lit_start = i
        else:
            i += 1
            if i - lit_start == 128:
                out.append(127)
                out.extend(data[lit_start:i])
                lit_start = i
    while lit_start < n:
        lit_len = min(128, n - lit_start)
        out.append(lit_len - 1)
        out.extend(data[lit_start:lit_start + lit_len])
        lit_start += lit_len
    return bytes(out)


# ---------------------------------------------------------------------------
# Open the input video and sample it at the requested output FPS.
# Each chosen frame is converted to grayscale, packed, and appended.
# ---------------------------------------------------------------------------
def sample_video_frames(video_path, fps, width, height, threshold, invert=False):
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise SystemExit(f"error: could not open {video_path}")
    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    if src_fps <= 0:
        src_fps = 30.0
    out_period = 1.0 / fps
    src_period = 1.0 / src_fps
    frames = []
    src_t = 0.0
    next_sample_t = 0.0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if src_t + 1e-9 >= next_sample_t:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            frames.append(pack_frame(gray, width, height, threshold, invert))
            next_sample_t += out_period
        src_t += src_period
    cap.release()
    if not frames:
        raise SystemExit("error: no frames generated")
    return frames


# ---------------------------------------------------------------------------
# Write one generated badapple_partX.py module containing metadata plus the
# compressed DATA bytes for that segment.
# ---------------------------------------------------------------------------
def write_part_module(path, fps, width, height, frames):
    frame_bytes = (width * height + 7) // 8
    raw = b''.join(frames)
    comp = rle_encode(raw)
    lines = [
        '"""Auto-generated compressed Bad Apple video segment."""',
        f'FPS={fps}',
        f'WIDTH={width}',
        f'HEIGHT={height}',
        f'FRAME_BYTES={frame_bytes}',
        f'FRAMES_COUNT={len(frames)}',
        f'RAW_BYTES={len(raw)}',
        f'COMPRESSED_BYTES={len(comp)}',
        'DATA=(',
    ]
    chunk = 96
    for i in range(0, len(comp), chunk):
        lines.append(f'    {comp[i:i+chunk]!r}')
    lines += [')', '']
    path.write_text("\n".join(lines), encoding='utf-8')


# ---------------------------------------------------------------------------
# Parse arguments, convert the full source video, split it into modules, then
# emit the standalone runtime player files.
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('input_video')
    ap.add_argument('output_dir', nargs='?', default='.')
    ap.add_argument('--fps', type=int, default=10)
    ap.add_argument('--width', type=int, default=20)
    ap.add_argument('--height', type=int, default=15)
    ap.add_argument('--threshold', type=int, default=128)
    ap.add_argument('--frames-per-file', type=int, default=200)
    ap.add_argument('--invert', action='store_true')
    a = ap.parse_args()
    if a.frames_per_file < 1:
        raise SystemExit('error: --frames-per-file must be >= 1')

    outdir = Path(a.output_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    frames = sample_video_frames(Path(a.input_video), a.fps, a.width, a.height, a.threshold, a.invert)

    part_names = []
    for i in range(0, len(frames), a.frames_per_file):
        name = f'badapple_part{len(part_names)}'
        part_names.append(name)
        write_part_module(outdir / f'{name}.py', a.fps, a.width, a.height, frames[i:i + a.frames_per_file])

    (outdir / 'player.py').write_text(PLAYER_TEMPLATE.format(part_modules=repr(tuple(part_names))), encoding='utf-8')
    (outdir / 'main.py').write_text(MAIN_TEMPLATE, encoding='utf-8')
    print(f'wrote {len(frames)} frames across {len(part_names)} files into {outdir}')


if __name__ == '__main__':
    main()
