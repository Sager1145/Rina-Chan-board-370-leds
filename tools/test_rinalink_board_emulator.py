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
            if header[2] == self.seq and header[1] in (kind | 0x80, 0xFF):
                self.reply_type = header[1]
                self.reply_seq = header[2]
                return result if binary else json.loads(result)

    def command(self, cmd, **fields):
        return self.request(1, {"cmd": cmd, **fields})

    def upload(self, viewport=0):
        width = 70
        # One lit source pixel in row zero: viewport zero sees it at local x=2,
        # viewport 22 sees a dark frame. Exercises real bitmap packing/cropping.
        bitmap = bytearray(((width + 7) // 8) * 18)
        bitmap[0] = 1 << 2
        begin = self.request(0x20, {"kind": "scroll_bitmap", "width": width, "rows": 18,
                                   "virtualWidth": 44, "viewportX": viewport, "totalBytes": len(bitmap),
                                   "timelineId": "shared", "sourceText": "test", "fps": 10, "intervalMs": 100})
        self.assertEqual(begin["chunkMax"], 4032)
        self.request(0x21, struct.pack("<I", 0) + bitmap)
        reply = self.request(0x22, {"start": False})
        self.assertEqual(reply["frames"], 27)
        self.assertEqual(reply["rotation"], 0)
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
        end = self.request(0x22, {"start": True})
        self.assertEqual(end["frames"], 2)
        self.assertNotIn("rotation", end)
        self.assertNotIn("width", end)
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
        self.assertEqual(info["caps"], ["identify", "clock_sample", "scroll_viewport", "group_start", "group_60fps", "apply_face_frame"])
        reply = self.command("apply_saved_face", index=7)
        self.assertEqual(set(reply), {"ok", "autoFaceId", "autoFaceIndex", "frameEncoding", "frameHex"})
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["autoFaceIndex"], 7 % 5)
        self.assertEqual(reply["autoFaceId"], "face%d" % (7 % 5))
        self.assertEqual(reply["frameEncoding"], "packed-lsb-first")
        self.assertEqual(len(reply["frameHex"]), 94)
        self.assertEqual(reply["frameHex"], reply["frameHex"].lower())
        self.assertTrue(all(ch in "0123456789abcdef" for ch in reply["frameHex"]))
        stored = self.emulator.FACES[reply["autoFaceIndex"]]["frame"]
        self.assertEqual(reply["frameHex"], stored.hex())
        missing = self.command("apply_saved_face", id="nope")
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(self.reply_seq, self.seq)
        self.assertEqual(missing["ok"], False)
        self.assertEqual(missing["code"], 404)
        self.assertEqual(missing["error"], "saved face not found: nope")
        bright = self.command("set_brightness", raw=40)
        self.assertEqual(bright["ok"], True)
        self.assertEqual(set(bright), {"ok", "autoFaceIndex", "autoFaceId"})
        self.assertEqual(bright["autoFaceIndex"], reply["autoFaceIndex"])
        self.assertEqual(bright["autoFaceId"], reply["autoFaceId"])
        self.assertEqual(self.request(0x10, bytes([0, 0]) + bytes(47)), {"ok": True})
        self.emulator.FACES.clear()
        # Index-only apply hits applySavedFaceIndex; empty library leaves errCode at 400.
        empty = self.command("apply_saved_face", index=0)
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(self.reply_seq, self.seq)
        self.assertEqual(empty["ok"], False)
        self.assertEqual(empty["code"], 400)
        self.assertEqual(empty["error"], "")

    def test_blob_end_uses_firmware_keys_and_chunk_max_is_4032(self):
        width = 40
        bitmap = bytearray(((width + 7) // 8) * 18)
        bitmap[30 // 8] |= 1 << (30 % 8)  # row 0, column 30; that row's rightmost x is 19, so frame 11
        begin = self.request(0x20, {"kind": "scroll_bitmap", "width": width, "rows": 18,
                                   "totalBytes": len(bitmap), "timelineId": "plain", "fps": 10, "intervalMs": 100})
        self.assertEqual(set(begin), {"ok", "offset", "chunkMax"})
        self.assertEqual(begin["chunkMax"], 4032)
        self.assertEqual(begin["offset"], 0)
        self.request(0x21, struct.pack("<I", 0) + bytes(bitmap))
        plain = self.request(0x22, {"start": False})
        self.assertEqual(set(plain), {"ok", "frames", "chunkFrames", "append", "started", "timelineId",
                                      "uploadComplete", "frameBytes", "scrollIntervalMs", "uiFps", "scrollFps",
                                      "width", "rotation"})
        self.assertEqual(plain["frames"], 19)
        self.assertEqual(plain["chunkFrames"], 19)
        self.assertEqual(plain["rotation"], 11)
        self.assertEqual(plain["width"], width)
        self.assertFalse(plain["append"])
        self.assertFalse(plain["started"])
        self.assertTrue(plain["uploadComplete"])
        self.assertEqual(plain["frameBytes"], 47)
        self.assertEqual(plain["timelineId"], "plain")
        self.assertEqual(plain["scrollIntervalMs"], 100)
        self.assertEqual(plain["uiFps"], 10)
        self.assertEqual(plain["scrollFps"], 10)

        begin = self.request(0x20, {"kind": "scroll_bitmap", "width": width, "rows": 18,
                                   "virtualWidth": 22, "viewportX": 0, "totalBytes": len(bitmap),
                                   "timelineId": "group", "fps": 10, "intervalMs": 100})
        self.assertEqual(begin["chunkMax"], 4032)
        self.request(0x21, struct.pack("<I", 0) + bytes(bitmap))
        viewport = self.request(0x22, {"start": True})
        self.assertEqual(set(viewport), {"ok", "frames", "chunkFrames", "append", "started", "timelineId",
                                         "uploadComplete", "frameBytes", "scrollIntervalMs", "uiFps", "scrollFps",
                                         "width", "rotation", "viewportX", "virtualWidth"})
        self.assertEqual(viewport["frames"], 19)
        self.assertEqual(viewport["rotation"], 0)
        self.assertEqual(viewport["viewportX"], 0)
        self.assertEqual(viewport["virtualWidth"], 22)
        self.assertTrue(viewport["started"])
        self.assertEqual(viewport["timelineId"], "group")

        frames = bytes([1]) + bytes(46) + bytes([2]) + bytes(46)
        raw_begin = self.request(0x20, {"kind": "scroll", "totalBytes": len(frames), "totalFrames": 2,
                                       "fps": 10, "intervalMs": 100, "timelineId": "raw"})
        self.assertEqual(raw_begin["chunkMax"], 4032)
        self.request(0x21, struct.pack("<I", 0) + frames)
        raw = self.request(0x22, {"start": True})
        self.assertEqual(set(raw), {"ok", "frames", "chunkFrames", "append", "started", "timelineId",
                                    "uploadComplete", "frameBytes", "scrollIntervalMs", "uiFps", "scrollFps"})
        self.assertEqual(raw["frames"], 2)
        self.assertEqual(raw["chunkFrames"], 2)
        self.assertTrue(raw["started"])
        self.assertFalse(raw["append"])
        self.assertEqual(raw["timelineId"], "raw")
        self.assertEqual(raw["frameBytes"], 47)
        self.assertNotIn("rotation", raw)
        self.assertNotIn("width", raw)

    def test_set_frame_stores_bytes_after_playback_and_reason(self):
        reason = b"pencil"
        frame = bytes([0xAB]) + bytes(46)
        payload = bytes([2, len(reason)]) + reason + frame
        self.assertEqual(self.request(0x10, payload), {"ok": True})
        self.assertEqual(self.reply_type, 0x90)
        self.assertEqual(self.request(0x11, binary=True), frame)
        short = self.request(0x10, bytes(47))
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(self.reply_seq, self.seq)
        self.assertEqual(short["ok"], False)
        self.assertEqual(short["code"], 400)
        self.assertEqual(short["error"], "SET_FRAME payload truncated")
        # The rejected prefix must not replace the frame stored above.
        self.assertEqual(self.request(0x11, binary=True), frame)
        empty = self.request(0x10, b"\x00")
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(empty["code"], 400)
        self.assertEqual(empty["error"], "SET_FRAME payload too short")

    def test_group_start_failures_are_err_frames_with_firmware_codes(self):
        missing = self.command("group_start", bootId="deadbeef", atUs=self.clock, intervalMs=100, startFrame=0)
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(self.reply_seq, self.seq)
        self.assertEqual(missing["ok"], False)
        self.assertEqual(missing["code"], 409)
        self.assertEqual(missing["error"], "no_timeline")
        mismatch = self.command("group_start", bootId="bad", atUs=self.clock, intervalMs=100)
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(mismatch["code"], 409)
        self.assertEqual(mismatch["error"], "boot_mismatch")

        self.upload()
        schedule = "group_start requires atUs (u64), intervalMs 17..2000, startFrame 0..65535"
        bad_interval = self.command("group_start", bootId="deadbeef", atUs=self.clock, intervalMs=16, startFrame=0)
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(bad_interval["code"], 400)
        self.assertEqual(bad_interval["error"], schedule)
        missing_at = self.command("group_start", bootId="deadbeef", intervalMs=100, startFrame=0)
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(missing_at["code"], 400)
        self.assertEqual(missing_at["error"], schedule)
        too_far = self.command("group_start", bootId="deadbeef", atUs=self.clock, intervalMs=100, startFrame=65536)
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(too_far["code"], 400)
        self.assertEqual(too_far["error"], schedule)
        over = self.command("group_start", bootId="deadbeef", atUs=self.clock, intervalMs=100, startFrame=27)
        self.assertEqual(self.reply_type, 0xFF)
        self.assertEqual(over["code"], 400)
        self.assertEqual(over["error"], "startFrame exceeds frameCount-1")
        ok = self.command("group_start", bootId="deadbeef", atUs=self.clock, intervalMs=100, startFrame=0, loop=True)
        self.assertEqual(self.reply_type, 0x81)
        self.assertEqual(ok["ok"], True)
        self.assertEqual(ok["frameCount"], 27)


if __name__ == "__main__":
    unittest.main()
