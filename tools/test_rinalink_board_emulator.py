"""Protocol regressions for the connected simulator board fixture."""
import importlib.util
import json
import io
import socket
import struct
import tempfile
import threading
import unittest
from pathlib import Path


class EmulatorProtocolTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("emulator", Path(__file__).with_name("rinalink_board_emulator.py"))
        self.emulator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.emulator)
        self.tmp = tempfile.TemporaryDirectory()
        self.emulator.log = io.StringIO()
        self.emulator.FLAG = str(Path(self.tmp.name) / "scroll.flag")
        self.clock = 1_000_000
        self.emulator.now_us = lambda: self.clock
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        self.client = socket.create_connection(listener.getsockname())
        self.client.settimeout(2)
        server, _ = listener.accept()
        listener.close()
        self.worker = threading.Thread(target=self.emulator.serve, args=(server,), daemon=True)
        self.worker.start()
        self.seq = 0

    def tearDown(self):
        self.client.close()
        self.worker.join(timeout=2)
        self.assertFalse(self.worker.is_alive())
        self.tmp.cleanup()

    def read(self, count):
        data = b""
        while len(data) < count:
            part = self.client.recv(count - len(data))
            if not part:
                self.fail("Emulator closed before replying")
            data += part
        return data

    def request(self, kind, payload=b"", binary=False):
        self.seq += 1
        if isinstance(payload, dict): payload = json.dumps(payload).encode()
        self.client.sendall(self.emulator.frame(kind, self.seq, payload))
        while True:
            header = self.read(6)
            result = self.read(struct.unpack("<H", header[4:])[0])
            if header[1] == kind | 0x80 and header[2] == self.seq:
                return result if binary else json.loads(result)

    def command(self, cmd, **fields):
        return self.request(1, {"cmd": cmd, **fields})

    def upload(self, viewport=0):
        width = 70
        # One lit source pixel in row zero: viewport zero sees it at local x=2,
        # viewport 22 sees a dark frame. Exercises real bitmap packing/cropping.
        bitmap = bytearray(((width + 7) // 8) * 18)
        bitmap[0] = 1 << 2
        self.request(0x20, {"kind": "scroll_bitmap", "width": width, "rows": 18,
                           "virtualWidth": 44, "viewportX": viewport, "totalBytes": len(bitmap),
                           "timelineId": "shared", "sourceText": "test", "fps": 10, "intervalMs": 100})
        self.request(0x21, struct.pack("<I", 0) + bitmap)
        reply = self.request(0x22, {"start": False})
        self.assertEqual(reply["frameCount"], 27)
        self.assertFalse(self.request(4)["firmwareScrollActive"])

    def test_group_schedule_pause_seek_resume_and_stop_persist_through_status(self):
        self.upload()
        reply = self.command("group_start", bootId="deadbeef", atUs=self.clock + 400_000,
                             intervalMs=100, startFrame=3, loop=True)
        self.assertTrue(reply["ok"])
        self.assertEqual(self.request(4)["frameIndex"], 3)
        self.clock += 650_000
        self.assertEqual(self.request(4)["frameIndex"], 5)
        self.command("pause_scroll")
        self.clock += 1_000_000
        paused = self.request(4)
        self.assertEqual(paused["frameIndex"], 5)
        self.assertTrue(paused["firmwareScrollPaused"])
        self.assertFalse(paused["groupTimed"])
        self.command("scroll_seek", frameIndex=9)
        self.assertEqual(self.request(5)["presentedFrameIndex"], 9)
        self.command("resume_scroll")
        self.clock += 200_000
        self.assertEqual(self.request(4)["frameIndex"], 11)
        self.command("stop_scroll")
        self.assertFalse(self.request(2)["renderer"]["firmwareScrollActive"])

    def test_upload_viewport_change_changes_sampled_board_frame(self):
        self.upload()
        self.command("group_start", bootId="deadbeef", atUs=self.clock, intervalMs=100, startFrame=0, loop=True)
        self.assertEqual(self.request(0x11, binary=True)[0], 1)
        self.upload(viewport=22)
        self.command("group_start", bootId="deadbeef", atUs=self.clock, intervalMs=100, startFrame=0, loop=True)
        self.assertEqual(self.request(0x11, binary=True), bytes(47))

    def test_original_packed_scroll_upload_and_nonloop_end(self):
        frames = bytes([1]) + bytes(46) + bytes([2]) + bytes(46)
        self.request(0x20, {"kind": "scroll", "totalBytes": len(frames), "fps": 10, "intervalMs": 100})
        self.request(0x21, struct.pack("<I", 0) + frames)
        self.assertEqual(self.request(0x22, {"start": True})["frameCount"], 2)
        self.command("set_scroll_loop", loop=False)
        self.assertEqual(self.request(0x11, binary=True)[0], 1)
        self.clock += 100_000
        self.assertEqual(self.request(0x11, binary=True)[0], 2)
        self.clock += 100_000
        self.assertTrue(self.request(4)["firmwareScrollPaused"])
        self.assertEqual(self.request(0x11, binary=True)[0], 2)

    def test_explicit_identity_name_and_binary_saved_faces_document(self):
        self.emulator.BOARD_ID = "EMU-FIXTURE-3"
        self.emulator.BOARD_NAME = "Simulator Board 3"
        self.assertEqual(self.request(2)["wifi"]["boardId"], "EMU-FIXTURE-3")
        self.assertEqual(self.command("get_info")["name"], "Simulator Board 3")
        payload = self.request(0x24, {"offset": 0}, binary=True)
        self.assertEqual(struct.unpack("<I", payload[:4])[0], 1)
        document = json.loads(payload[4:])
        self.assertEqual(document, {"format": "rina_packed_faces_370_v2", "version": 4,
                                    "category": "unified_saved_faces", "faces": []})
        next_page = self.request(0x24, {"offset": 10, "gen": 1}, binary=True)
        self.assertEqual(next_page[4:], payload[14:])

    def test_flag_initializes_once_and_clock_samples_use_monotonic_time(self):
        Path(self.emulator.FLAG).touch()
        self.assertTrue(self.request(2)["renderer"]["firmwareScrollActive"])
        self.command("stop_scroll")
        self.assertFalse(self.request(2)["renderer"]["firmwareScrollActive"])
        first = self.command("clock_sample")
        self.clock += 250_000
        second = self.command("clock_sample")
        self.assertEqual(second["rxUs"] - first["rxUs"], 250_000)
        self.assertGreaterEqual(second["txUs"], second["rxUs"])
        self.assertFalse(self.command("group_start", bootId="bad", atUs=self.clock, intervalMs=100)["ok"])

    def test_apply_saved_face_reply_and_optional_cap(self):
        info = self.command("get_info")
        self.assertEqual(info["caps"], ["identify", "clock_sample", "scroll_viewport", "group_start", "apply_face_frame"])
        reply = self.command("apply_saved_face", index=7)
        self.assertEqual(set(reply), {"ok", "autoFaceId", "autoFaceIndex", "frameEncoding", "frameHex"})
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["autoFaceIndex"], 7 % 5)
        self.assertEqual(reply["autoFaceId"], "face%d" % (7 % 5))
        self.assertEqual(reply["frameEncoding"], "packed-lsb-first")
        self.assertEqual(len(reply["frameHex"]), 94)
        self.assertEqual(reply["frameHex"], reply["frameHex"].lower())
        self.assertTrue(all(ch in "0123456789abcdef" for ch in reply["frameHex"]))
        selected = bytes([reply["autoFaceIndex"] & 0xFF]) + bytes(46)
        self.assertEqual(reply["frameHex"], selected.hex())
        self.assertEqual(self.command("set_brightness", raw=40), {"ok": True})
        self.assertEqual(self.request(0x10, bytes(47)), {"ok": True})


if __name__ == "__main__":
    unittest.main()
