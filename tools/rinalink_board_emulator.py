#!/usr/bin/env python3
"""A tiny RinaLink board emulator over TCP, for driving the iOS app (and the
Apple Watch companion) in the simulator without hardware.

    python3 tools/rinalink_board_emulator.py [logfile]

Then in the app: Settings → Add Board → Home Wi-Fi → host `127.0.0.1` → Connect.
Every distinct host string the phone connects with (e.g. `127.0.0.1` and the
Mac's LAN IP) shows up as a separate board, so one process can stand in for a
two-member board group. Creating the file printed as "scroll flag" before a board first connects
(override with RINA_EMU_SCROLL_FLAG) initializes that board with a running scroll,
which is what enables the scroll speed controls. It answers the handshake,
status, power, blob upload, frame and command messages with plausible replies,
keeps brightness/colour/mode/interval/face state, and pushes an EV_STATUS
every 2 s and after each change so the phone's echo-driven sync follows. It is
a focused firmware stand-in: group bitmap uploads and schedules retain
state and return sampled frames. `apply_saved_face` uses a fixed five-face
list (GET_FACES stays an empty document). RINA_EMU_HOST
and RINA_EMU_PORT override the listening address and port. RINA_EMU_BOARD_ID
and RINA_EMU_BOARD_NAME optionally distinguish boards on separate local ports.
"""
import json, socket, struct, threading, time, sys, os
HOST = os.environ.get("RINA_EMU_HOST", "0.0.0.0")
PORT = int(os.environ.get("RINA_EMU_PORT", "5370"))
BOARD_ID = os.environ.get("RINA_EMU_BOARD_ID")
BOARD_NAME = os.environ.get("RINA_EMU_BOARD_NAME")
def stored_face_frame(index):
    return bytes([index & 0xFF]) + bytes(46)
FACES = [{"id": "face%d" % i, "frame": stored_face_frame(i)} for i in range(5)]
DEFAULT_STATE = dict(brightness=80, color="#ec3fc7", mode="manual", autoIntervalMs=3000,
             autoFaceIndex=0, autoFaceCount=len(FACES), scrollActive=False, scrollIntervalMs=100, uiFps=10,
             scrollPaused=False, groupTimed=False, frameIndex=0, frameCount=0, scrollLoop=True)
log = sys.stdout
STATES = {}
STATE_LOCK = threading.RLock()
CONNS_LOCK = threading.Lock()
def current_state():
    ident = getattr(IDENT, "id", "EMU-1")
    with STATE_LOCK:
        if ident not in STATES:
            state = DEFAULT_STATE.copy()
            state["scrollActive"] = os.path.exists(FLAG)
            STATES[ident] = state
        return STATES[ident]
class Client:
    def __init__(self, socket):
        self.socket = socket
        self.ident = socket.getsockname()[0]
        self.send_lock = threading.Lock()
    def send(self, payload):
        with self.send_lock:
            self.socket.sendall(payload)

def L(*a): print(time.strftime("%H:%M:%S"), *a, file=log)
def frame(t, seq, payload, flags=0):
    return bytes([0xA5, t, seq, flags]) + struct.pack("<H", len(payload)) + payload
IDENT = threading.local()
FLAG = os.environ.get("RINA_EMU_SCROLL_FLAG") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".claude", "scroll.flag")
CONNS = []
def _status():
    ident = getattr(IDENT, "id", "EMU-1")
    playback = scroll_meta()
    return {"ok": True, "power": {"ok": True, "batteryPercent": 73, "batteryValid": True, "charging": False},
            "wifi": {"ip": ident, "boardId": BOARD_ID or "EMU-" + ident},
            "renderer": {"mode": current_state()["mode"], "brightness": current_state()["brightness"], "color": current_state()["color"],
                         "autoIntervalMs": current_state()["autoIntervalMs"], "autoFaceIndex": current_state()["autoFaceIndex"],
                         "autoFaceCount": current_state()["autoFaceCount"], "firmwareScrollActive": current_state()["scrollActive"],
                         "scrollFps": current_state()["uiFps"], **playback}}
def status():
    with STATE_LOCK:
        return _status()
def J(o): return json.dumps(o).encode()
def now_us():
    return time.monotonic_ns() // 1000

def scroll_meta():
    """Advance the accepted schedule on reads, matching firmware's held start frame."""
    state = current_state()
    count = state["frameCount"]
    if state["scrollActive"] and not state["scrollPaused"] and count:
        elapsed = max(0, now_us() - state.get("atUs", now_us()))
        index = state.get("startFrame", 0) + elapsed // (state["scrollIntervalMs"] * 1000)
        state["frameIndex"] = index % count if state["scrollLoop"] else min(index, count - 1)
        if not state["scrollLoop"] and index >= count:
            state["scrollPaused"] = True
            state["groupTimed"] = False
    meta = state.get("scrollMeta", {})
    return {"ok": True, "scrollTimelineId": meta.get("timelineId"),
            "sourceText": meta.get("sourceText"), "fontId": meta.get("fontId"),
            "generatorVersion": meta.get("generatorVersion"),
            "hasSourceText": bool(meta.get("sourceText")), "uploadComplete": count > 0,
            "frameCount": count, "frameIndex": state["frameIndex"],
            "scrollIntervalMs": state["scrollIntervalMs"], "uiFps": state["uiFps"],
            "firmwareScrollActive": state["scrollActive"], "firmwareScrollPaused": state["scrollPaused"],
            "groupTimed": state["groupTimed"], "scrollLoop": state["scrollLoop"]}

def preview_sync():
    state = current_state()
    return {**scroll_meta(), "mode": state["mode"],
            "playback": "paused" if state["scrollPaused"] else "scroll" if state["scrollActive"] else "auto" if state["mode"] == "auto" else "idle",
            "sampledAtUs": now_us(), "presentedFrameIndex": state["frameIndex"],
            "presentedFrameCount": state["frameCount"]}

def packed_frame():
    state = current_state()
    index = scroll_meta()["frameIndex"]
    meta = state.get("scrollMeta", {})
    frames = state.get("scrollFrames", b"")
    if frames and state["scrollActive"]:
        return frames[index * 47:(index + 1) * 47]
    bitmap = state.get("scrollBitmap", b"")
    if not bitmap or not state["scrollActive"]:
        return state.get("packedFrame", bytes(47))
    width = meta["width"]
    stride = (width + 7) // 8
    viewport = meta.get("viewportX", 0)
    result = bytearray(47)
    led = 0
    for y, length in enumerate((18, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 22, 20, 20, 20, 18, 16)):
        for x in range((22 - length) // 2, (22 + length) // 2):
            source = index + viewport + x
            offset = y * stride + source // 8
            if 0 <= source < width and offset < len(bitmap) and bitmap[offset] & (1 << (source % 8)):
                result[led // 8] |= 1 << (led % 8)
            led += 1
    return bytes(result)

def generic_cmd_ok():
    """Mirror protocol.cpp reply(): ok + autoFaceIndex, autoFaceId only in range."""
    state = current_state()
    reply = {"ok": True, "autoFaceIndex": state["autoFaceIndex"]}
    index = state["autoFaceIndex"]
    if FACES and 0 <= index < len(FACES):
        reply["autoFaceId"] = FACES[index]["id"]
    return reply
class ErrorReply(dict):
    """JSON body of protocol.cpp sendErrorReply (frame type 0xFF)."""

def error_reply(code, message):
    """Mirror protocol.cpp sendErrorReply: ok false, error, code."""
    return ErrorReply({"ok": False, "error": message, "code": code})
def _handle_cmd(obj):
    c = obj.get("cmd"); changed = True
    if c == "get_info":
        changed = False
        ident = getattr(IDENT, "id", "EMU-1")
        return {"ok": True, "proto": 1, "name": BOARD_NAME or "模拟板 " + ident, "defaultName": "模拟板 " + ident, "bootId": "deadbeef",
                "caps": ["identify", "clock_sample", "scroll_viewport", "group_start", "group_60fps", "apply_face_frame"]}, changed
    if c == "set_brightness": current_state()["brightness"] = int(obj.get("raw", current_state()["brightness"]))
    elif c == "set_color": current_state()["color"] = obj.get("hex", current_state()["color"])
    elif c == "set_mode": current_state()["mode"] = obj.get("mode", current_state()["mode"])
    elif c == "set_auto_interval": current_state()["autoIntervalMs"] = int(obj.get("ms", current_state()["autoIntervalMs"]))
    elif c == "button":
        d = 1 if obj.get("button") == "B1" else -1
        current_state()["autoFaceIndex"] = (current_state()["autoFaceIndex"] + d) % current_state()["autoFaceCount"]
    elif c == "stop_scroll":
        current_state().update(scrollActive=False, scrollPaused=False, groupTimed=False)
    elif c == "group_start":
        state = current_state()
        if obj.get("bootId") != "deadbeef":
            return {"ok": False, "error": "boot_mismatch"}, False
        if not state["frameCount"]:
            return {"ok": False, "error": "no_timeline"}, False
        interval = obj.get("intervalMs", 0)
        start = obj.get("startFrame", 0)
        if not isinstance(obj.get("atUs"), int) or not 17 <= interval <= 2000 or not 0 <= start < state["frameCount"]:
            return {"ok": False, "error": "invalid schedule"}, False
        state.update(scrollActive=True, scrollPaused=False, groupTimed=True, atUs=obj["atUs"],
                     startFrame=start, frameIndex=start, scrollIntervalMs=interval,
                     uiFps=round(1000 / interval), scrollLoop=obj.get("loop", True))
        return {"ok": True, "nowUs": now_us(), "frameCount": state["frameCount"]}, True
    elif c in ("pause_scroll", "scroll_seek", "scroll_step"):
        state = current_state()
        scroll_meta()
        index = state["frameIndex"]
        if c == "scroll_seek": index = obj.get("frameIndex", 0)
        if c == "scroll_step": index += -1 if obj.get("direction", 1) < 0 else 1
        state.update(frameIndex=max(0, min(index, max(0, state["frameCount"] - 1))),
                     scrollPaused=True, groupTimed=False)
    elif c == "resume_scroll":
        state = current_state()
        state.update(scrollPaused=False, groupTimed=False, atUs=now_us(), startFrame=state["frameIndex"])
    elif c == "set_scroll_loop": current_state()["scrollLoop"] = obj.get("loop", True)
    elif c == "start_scroll":
        current_state().update(scrollActive=True, scrollPaused=False, groupTimed=False, atUs=now_us(), startFrame=0)
        if obj.get("intervalMs"): current_state()["scrollIntervalMs"] = int(obj["intervalMs"])
        if obj.get("fps"): current_state()["uiFps"] = int(obj["fps"])
    elif c == "set_scroll_interval":
        if obj.get("intervalMs"): current_state()["scrollIntervalMs"] = int(obj["intervalMs"])
        if obj.get("fps"): current_state()["uiFps"] = int(obj["fps"])
    elif c == "clock_sample":
        rx = now_us()
        return {"ok": True, "rxUs": rx, "txUs": now_us(), "bootId": "deadbeef"}, False
    elif c == "apply_saved_face":
        state = current_state()
        nested = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
        raw_id = nested.get("id", obj.get("id", ""))
        if raw_id is None:
            raw_id = ""
        elif not isinstance(raw_id, str):
            raw_id = str(raw_id)
        if raw_id:
            if not FACES:
                return error_reply(503, "saved faces unavailable"), False
            found = next((i for i, face in enumerate(FACES) if face["id"] == raw_id), None)
            if found is None:
                return error_reply(404, "saved face not found: " + raw_id), False
            index = found
        else:
            if not FACES:
                return error_reply(400, ""), False
            raw_index = nested.get("index", obj.get("index", state["autoFaceIndex"]))
            try:
                index = int(raw_index)
            except (TypeError, ValueError):
                index = state["autoFaceIndex"]
            if index < 0:
                index = 0
            index %= len(FACES)
        state["mode"] = "manual"
        state["autoFaceIndex"] = index
        # Stored face bytes, not the live scroll/presented frame.
        frame = FACES[index]["frame"]
        return {"ok": True, "autoFaceId": FACES[index]["id"], "autoFaceIndex": index,
                "frameEncoding": "packed-lsb-first", "frameHex": frame.hex()}, True
    else: changed = False
    return generic_cmd_ok(), changed
def handle_cmd(obj):
    with STATE_LOCK:
        return _handle_cmd(obj)
def serve(conn):
    client = Client(conn)
    IDENT.id = client.ident
    with CONNS_LOCK:
        CONNS.append(client)
    buf = b""
    upload_meta, upload_bytes = {}, bytearray()
    def send(b):
        try: client.send(b)
        except OSError: pass
    while True:
        try: data = conn.recv(4096)
        except OSError: break
        if not data: break
        buf += data
        while len(buf) >= 6 and buf[0] == 0xA5:
            t, seq, flags = buf[1], buf[2], buf[3]; n = struct.unpack("<H", buf[4:6])[0]
            if len(buf) < 6 + n: break
            payload = buf[6:6+n]; buf = buf[6+n:]
            if t == 0x01:
                try: obj = json.loads(payload)
                except Exception: obj = {}
                L("CMD", getattr(IDENT, "id", "?"), obj)
                reply, changed = handle_cmd(obj)
                # apply_saved_face failures are ERR (0xFF), same seq as the request.
                reply_type = 0xFF if isinstance(reply, ErrorReply) else t | 0x80
                send(frame(reply_type, seq, J(reply)))
                if changed: send(frame(0x91, 0, J(status())))
            elif t == 0x02: send(frame(t | 0x80, seq, J(status())))
            elif t == 0x03: send(frame(t | 0x80, seq, J(status()["power"])))
            elif t == 0x04: send(frame(t | 0x80, seq, J(scroll_meta())))
            elif t == 0x05: send(frame(t | 0x80, seq, J(preview_sync())))
            elif t == 0x06: send(frame(t | 0x80, seq, J({"ok": True})))
            elif t == 0x10:
                current_state()["packedFrame"] = payload[:47]
                current_state().update(scrollActive=False, groupTimed=False)
                L("SET_FRAME", n); send(frame(t | 0x80, seq, J({"ok": True})))
            elif t == 0x11: send(frame(t | 0x80, seq, packed_frame()))
            elif t == 0x20:
                upload_meta, upload_bytes = json.loads(payload), bytearray()
                send(frame(t | 0x80, seq, J({"ok": True, "offset": 0, "chunkMax": 4000})))
            elif t == 0x21:
                off = struct.unpack("<I", payload[:4])[0] if n >= 4 else 0
                if off != len(upload_bytes):
                    send(frame(t | 0x80, seq, J({"ok": False, "error": "offset mismatch"})))
                    continue
                upload_bytes.extend(payload[4:])
                send(frame(t | 0x80, seq, J({"ok": True, "offset": len(upload_bytes)})))
            elif t == 0x22:
                state = current_state()
                if upload_meta.get("kind") == "scroll_bitmap":
                    count = max(1, upload_meta["width"] - upload_meta.get("virtualWidth", 22)) + 1
                    start = json.loads(payload or b"{}").get("start", True)
                    state.update(scrollMeta=upload_meta.copy(), scrollBitmap=bytes(upload_bytes), scrollFrames=b"", frameCount=count,
                                 frameIndex=0, startFrame=0, atUs=now_us(), scrollActive=start,
                                 scrollPaused=False, groupTimed=False,
                                 scrollIntervalMs=upload_meta.get("intervalMs", 100), uiFps=upload_meta.get("fps", 10))
                elif upload_meta.get("kind") == "scroll":
                    start = json.loads(payload or b"{}").get("start", True)
                    state.update(scrollMeta=upload_meta.copy(), scrollFrames=bytes(upload_bytes), scrollBitmap=b"",
                                 frameCount=len(upload_bytes) // 47, frameIndex=0, startFrame=0,
                                 atUs=now_us(), scrollActive=start, scrollPaused=False, groupTimed=False,
                                 scrollIntervalMs=upload_meta.get("intervalMs", 100), uiFps=upload_meta.get("fps", 10))
                send(frame(t | 0x80, seq, J({"ok": True, "frameCount": state["frameCount"]})))
                send(frame(0x91, 0, J(status())))
            elif t == 0x23: send(frame(t | 0x80, seq, J({"ok": True})))
            elif t == 0x24:
                # GET_FACES is a generation-prefixed document, not a JSON envelope.
                document = J({"format": "rina_packed_faces_370_v2", "version": 4,
                              "category": "unified_saved_faces", "faces": []})
                offset = json.loads(payload or b"{}").get("offset", 0)
                send(frame(t | 0x80, seq, struct.pack("<I", 1) + document[offset:]))
            else: L("type", hex(t)); send(frame(t | 0x80, seq, J({"ok": True})))
        if buf and buf[0] != 0xA5: buf = b""
    with CONNS_LOCK:
        if client in CONNS:
            CONNS.remove(client)
    conn.close(); L("closed")
def heartbeat():
    while True:
        time.sleep(2)
        with CONNS_LOCK:
            clients = list(CONNS)
        for client in clients:
            IDENT.id = client.ident
            try: client.send(frame(0x91, 0, J(status())))
            except OSError:
                with CONNS_LOCK:
                    if client in CONNS:
                        CONNS.remove(client)
def main():
    global log
    if len(sys.argv) > 1:
        log = open(sys.argv[1], "a", buffering=1)
    threading.Thread(target=heartbeat, daemon=True).start()
    L("scroll flag:", FLAG)
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT)); srv.listen(8); L("listening", HOST, PORT)
    while True:
        c, a = srv.accept(); L("accept", a); threading.Thread(target=serve, args=(c,), daemon=True).start()

if __name__ == "__main__":
    main()
