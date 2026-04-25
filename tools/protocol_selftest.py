#!/usr/bin/env python3
"""CPython self-test for pico_firmware/rina_protocol.py.

This creates a mock board_370 module so the MicroPython protocol code can be
validated without a Pico.  It checks both documented binary packets and the
WeChat mini-program textual compatibility packets.
"""
import importlib.util
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parents[1]
PICO = ROOT / "pico_firmware"

# Mock board_370 before importing rina_protocol.
mock_board = types.ModuleType("board_370")
mock_board.SRC_ROWS = 16
mock_board.SRC_COLS = 18
mock_board.SRC_INVALID_COLS = (0, 17)
mock_board.LED_PIN = 15
mock_board.NUM_LEDS = 370
mock_board.ROW_LENGTHS = [18, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 22, 20, 20, 20, 18, 16]
mock_board.ROWS = len(mock_board.ROW_LENGTHS)
mock_board.COLS = max(mock_board.ROW_LENGTHS)
mock_board.SRC_TO_DST_ROW_OFFSET = 1
mock_board.SRC_TO_DST_COL_OFFSET = 2
mock_board.last_draw = None
mock_board.last_pixel_grid = None
mock_board.sleep_calls = []


def logical_to_led_index(x, y):
    if x < 0 or x >= mock_board.COLS or y < 0 or y >= mock_board.ROWS:
        return None
    row_width = mock_board.ROW_LENGTHS[y]
    left_pad = (mock_board.COLS - row_width) // 2
    if x < left_pad or x >= left_pad + row_width:
        return None
    return sum(mock_board.ROW_LENGTHS[:y]) + (x - left_pad)


def draw_face_matrix(face, color, bright=255, write=True):
    mock_board.last_draw = (face, color, bright, write)


def draw_pixel_grid(grid, palette, do_show=True):
    mock_board.last_pixel_grid = (grid, palette, do_show)


def sleep_ms(ms):
    mock_board.sleep_calls.append(ms)


def hardware_summary():
    return "mock"


mock_board.draw_face_matrix = draw_face_matrix
mock_board.draw_pixel_grid = draw_pixel_grid
mock_board.logical_to_led_index = logical_to_led_index
mock_board.sleep_ms = sleep_ms
mock_board.hardware_summary = hardware_summary
sys.modules["board_370"] = mock_board
sys.modules["board"] = mock_board
sys.path.insert(0, str(PICO))

spec = importlib.util.spec_from_file_location("rina_protocol", PICO / "rina_protocol.py")
rina_protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rina_protocol)

sent = []


def sender(ip, port, data, link_id=0):
    sent.append((ip, port, bytes(data), link_id))


class MockApp:
    def battery_status_json(self):
        return "{\"battery_v\":7.4}"

p = rina_protocol.RinaProtocol(sender=sender, log_provider=lambda: "log ok", app=MockApp())

# 1. Text full face from WeChat custom/voice/music pages.
face_hex = "00000000000000c00c30030c00c30030000000000000003f000840012000300000000000"
p.handle_packet(face_hex.encode(), "192.168.1.50", 12345)
assert p.encode_face_hex_text() == face_hex
p.handle_packet(b"requestFace", "192.168.1.50", 12345)
assert sent[-1][1] == 4321
assert sent[-1][2] == face_hex.encode()

# 2. Text color / bright from WeChat index page.
p.handle_packet(b"#f971d4", "192.168.1.50", 12345)
assert p.color == (249, 113, 212)
p.handle_packet(b"requestColor", "192.168.1.50", 12345)
assert sent[-1][2] == b"#f971d4"
p.handle_packet(b"B128", "192.168.1.50", 12345)
assert p.bright == 128
p.handle_packet(b"requestBright", "192.168.1.50", 12345)
assert sent[-1][2] == b"128"

# 3. Binary color and binary request color.
p.handle_packet(bytes([1, 2, 3]), "192.168.1.50", 12345)
assert p.color == (1, 2, 3)
p.handle_packet(bytes([0x10, 0x02]), "192.168.1.50", 12345)
assert sent[-1][2] == bytes([1, 2, 3])

# 4. Binary brightness and request.
p.handle_packet(bytes([16]), "192.168.1.50", 12345)
assert p.bright == 16
p.handle_packet(bytes([0x10, 0x03]), "192.168.1.50", 12345)
assert sent[-1][2] == bytes([16])

# 5. Binary face request returns 36 bytes and zeroes the original invalid
#    padding columns exactly like getFaceHex() in led.cpp.
p.handle_packet(bytes([0xFF]) * 36, "192.168.1.50", 12345)
p.handle_packet(bytes([0x10, 0x01]), "192.168.1.50", 12345)
assert len(sent[-1][2]) == 36
face_resp = sent[-1][2]
for bit_index in range(16 * 18):
    col = bit_index % 18
    bit = (face_resp[bit_index // 8] >> (7 - (bit_index % 8))) & 1
    if col in (0, 17):
        assert bit == 0, (bit_index, col, face_resp.hex())
    else:
        assert bit == 1, (bit_index, col, face_resp.hex())

# 6. Binary/text face-lite, including max generated indices.
p.handle_packet(bytes([27, 27, 32, 5]), "192.168.1.50", 12345)
assert mock_board.last_draw is not None
p.handle_packet(b"01010600", "192.168.1.50", 12345)
assert mock_board.last_draw is not None

# 7. Version, battery, ESP log. Binary 0x1005 keeps original TODO no-reply; text requestBattery returns JSON.
p.handle_packet(bytes([0x10, 0x04]), "192.168.1.50", 12345)
assert rina_protocol.VERSION.encode() in sent[-1][2]
before_len = len(sent)
p.handle_packet(bytes([0x10, 0x05]), "192.168.1.50", 12345)
assert len(sent) == before_len
p.handle_packet(b"requestBattery", "192.168.1.50", 12345)
assert b"battery_v" in sent[-1][2]
p.handle_packet(b"requestState", "192.168.1.50", 12345)
assert b"\"face\"" in sent[-1][2] and b"\"battery\"" in sent[-1][2]
p.handle_packet(bytes([0x10, 0xFE]), "192.168.1.50", 12345)
assert sent[-1][2] == b"log ok"


# 8. HTTP proxy pseudo endpoint: replies must return to 0xF0F0, not public UDP 4321.
p.handle_packet(b"requestVersion", "127.0.0.1", 0xF0F0)
assert sent[-1][0] == "127.0.0.1"
assert sent[-1][1] == 0xF0F0
assert rina_protocol.VERSION.encode() in sent[-1][2]

# 9. Matrix370 extension: M370: + 93 hex chars represents only real LEDs.
m370 = "f" * rina_protocol.PHYSICAL_HEX_LEN
p.handle_packet(("M370:" + m370).encode(), "192.168.1.50", 12345)
assert p.display_mode == "physical"
assert mock_board.last_pixel_grid is not None
p.handle_packet(b"requestFace370", "192.168.1.50", 12345)
assert sent[-1][2].startswith(b"M370:")
assert len(sent[-1][2]) == 5 + rina_protocol.PHYSICAL_HEX_LEN
p.handle_packet(b"requestState", "192.168.1.50", 12345)
assert b"\"face370\":\"M370:" in sent[-1][2]

print("protocol_selftest: PASS")
