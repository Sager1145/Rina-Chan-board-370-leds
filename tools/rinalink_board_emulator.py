#!/usr/bin/env python3
"""A tiny RinaLink board emulator over TCP, for driving the iOS app (and the
Apple Watch companion) in the simulator without hardware.

    python3 tools/rinalink_board_emulator.py [logfile]

Then in the app: Settings → Add Board → Home Wi-Fi → host `127.0.0.1` → Connect.
Every distinct host string the phone connects with (e.g. `127.0.0.1` and the
Mac's LAN IP) shows up as a separate board, so one process can stand in for a
two-member board group. Creating the file printed as "scroll flag" at start
(override with RINA_EMU_SCROLL_FLAG) makes the board report a running scroll,
which is what enables the scroll speed controls. It answers the handshake,
status, power, blob upload, frame and command messages with plausible replies,
keeps brightness/colour/mode/interval/face state, and pushes an EV_STATUS
every 2 s and after each change so the phone's echo-driven sync follows. It is
not a firmware model: scroll timelines are accepted and discarded, faces are
always empty.
"""
import json, socket, struct, threading, time, sys
PORT = 5370
DEFAULT_STATE = dict(brightness=80, color="#ec3fc7", mode="manual", autoIntervalMs=3000,
             autoFaceIndex=0, autoFaceCount=5, scrollActive=False, scrollIntervalMs=100, uiFps=10)
log = sys.stdout
STATES = {}
STATE_LOCK = threading.RLock()
CONNS_LOCK = threading.Lock()
def current_state():
    ident = getattr(IDENT, "id", "EMU-1")
    with STATE_LOCK:
        return STATES.setdefault(ident, DEFAULT_STATE.copy())
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
import os
FLAG = os.environ.get("RINA_EMU_SCROLL_FLAG") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".claude", "scroll.flag")
CONNS = []
def _status():
    ident = getattr(IDENT, "id", "EMU-1")
    current_state()["scrollActive"] = os.path.exists(FLAG)
    return {"ok": True, "power": {"ok": True, "batteryPercent": 73, "batteryValid": True, "charging": False},
            "wifi": {"ip": ident, "boardId": "EMU-" + ident},
            "renderer": {"mode": current_state()["mode"], "brightness": current_state()["brightness"], "color": current_state()["color"],
                         "autoIntervalMs": current_state()["autoIntervalMs"], "autoFaceIndex": current_state()["autoFaceIndex"],
                         "autoFaceCount": current_state()["autoFaceCount"], "firmwareScrollActive": current_state()["scrollActive"],
                         "scrollIntervalMs": current_state()["scrollIntervalMs"], "uiFps": current_state()["uiFps"], "scrollFps": current_state()["uiFps"]}}
def status():
    with STATE_LOCK:
        return _status()
def J(o): return json.dumps(o).encode()
def _handle_cmd(obj):
    c = obj.get("cmd"); changed = True
    if c == "get_info":
        changed = False
        ident = getattr(IDENT, "id", "EMU-1")
        return {"ok": True, "proto": 1, "name": "模拟板 " + ident, "defaultName": "模拟板 " + ident, "bootId": "deadbeef",
                "caps": ["identify", "clock_sample", "scroll_viewport", "group_start"]}, changed
    if c == "set_brightness": current_state()["brightness"] = int(obj.get("raw", current_state()["brightness"]))
    elif c == "set_color": current_state()["color"] = obj.get("hex", current_state()["color"])
    elif c == "set_mode": current_state()["mode"] = obj.get("mode", current_state()["mode"])
    elif c == "set_auto_interval": current_state()["autoIntervalMs"] = int(obj.get("ms", current_state()["autoIntervalMs"]))
    elif c == "button":
        d = 1 if obj.get("button") == "B1" else -1
        current_state()["autoFaceIndex"] = (current_state()["autoFaceIndex"] + d) % current_state()["autoFaceCount"]
    elif c == "stop_scroll": current_state()["scrollActive"] = False
    elif c == "start_scroll":
        current_state()["scrollActive"] = True
        if obj.get("intervalMs"): current_state()["scrollIntervalMs"] = int(obj["intervalMs"])
        if obj.get("fps"): current_state()["uiFps"] = int(obj["fps"])
    elif c == "set_scroll_interval":
        if obj.get("intervalMs"): current_state()["scrollIntervalMs"] = int(obj["intervalMs"])
        if obj.get("fps"): current_state()["uiFps"] = int(obj["fps"])
    elif c == "clock_sample":
        return {"ok": True, "rxUs": 1000, "txUs": 1200, "bootId": "deadbeef"}, False
    else: changed = False
    return {"ok": True}, changed
def handle_cmd(obj):
    with STATE_LOCK:
        return _handle_cmd(obj)
def serve(conn):
    client = Client(conn)
    IDENT.id = client.ident
    with CONNS_LOCK:
        CONNS.append(client)
    buf = b""
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
                send(frame(t | 0x80, seq, J(reply)))
                if changed: send(frame(0x91, 0, J(status())))
            elif t == 0x02: send(frame(t | 0x80, seq, J(status())))
            elif t == 0x03: send(frame(t | 0x80, seq, J(status()["power"])))
            elif t == 0x04: send(frame(t | 0x80, seq, J({"ok": True, "active": current_state()["scrollActive"]})))
            elif t == 0x05: send(frame(t | 0x80, seq, J({"ok": True, "mode": current_state()["mode"], "playback": "auto" if current_state()["mode"]=="auto" else "idle"})))
            elif t == 0x06: send(frame(t | 0x80, seq, J({"ok": True})))
            elif t == 0x10: L("SET_FRAME", n); send(frame(t | 0x80, seq, J({"ok": True})))
            elif t == 0x11: send(frame(t | 0x80, seq, bytes(47)))
            elif t == 0x20: send(frame(t | 0x80, seq, J({"ok": True, "offset": 0, "chunkMax": 4000})))
            elif t == 0x21:
                off = struct.unpack("<I", payload[:4])[0] if n >= 4 else 0
                send(frame(t | 0x80, seq, J({"ok": True, "offset": off + max(0, n - 4)})))
            elif t == 0x22:
                current_state()["scrollActive"] = True
                send(frame(t | 0x80, seq, J({"ok": True, "frameCount": 120})))
                send(frame(0x91, 0, J(status())))
            elif t == 0x23: send(frame(t | 0x80, seq, J({"ok": True})))
            elif t == 0x24: send(frame(t | 0x80, seq, J({"ok": True, "faces": [], "gen": 1})))
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
    srv.bind(("0.0.0.0", PORT)); srv.listen(4); L("listening", PORT)
    while True:
        c, a = srv.accept(); L("accept", a); threading.Thread(target=serve, args=(c,), daemon=True).start()

if __name__ == "__main__":
    main()
