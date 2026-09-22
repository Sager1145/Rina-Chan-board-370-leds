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
state = dict(brightness=80, color="#ec3fc7", mode="manual", autoIntervalMs=3000,
             autoFaceIndex=0, autoFaceCount=5, scrollActive=False, scrollIntervalMs=100, uiFps=10)
log = open(sys.argv[1] if len(sys.argv) > 1 else "/dev/stdout", "a", buffering=1)
def L(*a): print(time.strftime("%H:%M:%S"), *a, file=log)
def frame(t, seq, payload, flags=0):
    return bytes([0xA5, t, seq, flags]) + struct.pack("<H", len(payload)) + payload
IDENT = threading.local()
import os
FLAG = os.environ.get("RINA_EMU_SCROLL_FLAG") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".claude", "scroll.flag")
CONNS = []
def status():
    ident = getattr(IDENT, "id", "EMU-1")
    state["scrollActive"] = os.path.exists(FLAG)
    return {"ok": True, "power": {"ok": True, "batteryPercent": 73, "batteryValid": True, "charging": False},
            "wifi": {"ip": ident, "boardId": "EMU-" + ident},
            "renderer": {"mode": state["mode"], "brightness": state["brightness"], "color": state["color"],
                         "autoIntervalMs": state["autoIntervalMs"], "autoFaceIndex": state["autoFaceIndex"],
                         "autoFaceCount": state["autoFaceCount"], "firmwareScrollActive": state["scrollActive"],
                         "scrollIntervalMs": state["scrollIntervalMs"], "uiFps": state["uiFps"], "scrollFps": state["uiFps"]}}
def J(o): return json.dumps(o).encode()
def handle_cmd(obj):
    c = obj.get("cmd"); changed = True
    if c == "get_info":
        changed = False
        ident = getattr(IDENT, "id", "EMU-1")
        return {"ok": True, "proto": 1, "name": "模拟板 " + ident, "defaultName": "模拟板 " + ident, "bootId": "deadbeef",
                "caps": ["identify", "clock_sample", "scroll_viewport", "group_start"]}, changed
    if c == "set_brightness": state["brightness"] = int(obj.get("raw", state["brightness"]))
    elif c == "set_color": state["color"] = obj.get("hex", state["color"])
    elif c == "set_mode": state["mode"] = obj.get("mode", state["mode"])
    elif c == "set_auto_interval": state["autoIntervalMs"] = int(obj.get("ms", state["autoIntervalMs"]))
    elif c == "button":
        d = 1 if obj.get("button") == "B1" else -1
        state["autoFaceIndex"] = (state["autoFaceIndex"] + d) % state["autoFaceCount"]
    elif c == "stop_scroll": state["scrollActive"] = False
    elif c == "start_scroll":
        state["scrollActive"] = True
        if obj.get("intervalMs"): state["scrollIntervalMs"] = int(obj["intervalMs"])
        if obj.get("fps"): state["uiFps"] = int(obj["fps"])
    elif c == "set_scroll_interval":
        if obj.get("intervalMs"): state["scrollIntervalMs"] = int(obj["intervalMs"])
        if obj.get("fps"): state["uiFps"] = int(obj["fps"])
    elif c == "clock_sample":
        return {"ok": True, "rxUs": 1000, "txUs": 1200, "bootId": "deadbeef"}, False
    else: changed = False
    return {"ok": True}, changed
def serve(conn):
    IDENT.id = conn.getsockname()[0]
    CONNS.append((conn, IDENT.id))
    buf = b""
    def send(b):
        try: conn.sendall(b)
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
            elif t == 0x04: send(frame(t | 0x80, seq, J({"ok": True, "active": state["scrollActive"]})))
            elif t == 0x05: send(frame(t | 0x80, seq, J({"ok": True, "mode": state["mode"], "playback": "auto" if state["mode"]=="auto" else "idle"})))
            elif t == 0x06: send(frame(t | 0x80, seq, J({"ok": True})))
            elif t == 0x10: L("SET_FRAME", n); send(frame(t | 0x80, seq, J({"ok": True})))
            elif t == 0x11: send(frame(t | 0x80, seq, bytes(47)))
            elif t == 0x20: send(frame(t | 0x80, seq, J({"ok": True, "offset": 0, "chunkMax": 4000})))
            elif t == 0x21:
                off = struct.unpack("<I", payload[:4])[0] if n >= 4 else 0
                send(frame(t | 0x80, seq, J({"ok": True, "offset": off + max(0, n - 4)})))
            elif t == 0x22:
                state["scrollActive"] = True
                send(frame(t | 0x80, seq, J({"ok": True, "frameCount": 120})))
                send(frame(0x91, 0, J(status())))
            elif t == 0x23: send(frame(t | 0x80, seq, J({"ok": True})))
            elif t == 0x24: send(frame(t | 0x80, seq, J({"ok": True, "faces": [], "gen": 1})))
            else: L("type", hex(t)); send(frame(t | 0x80, seq, J({"ok": True})))
        if buf and buf[0] != 0xA5: buf = b""
    conn.close(); L("closed")
def heartbeat():
    while True:
        time.sleep(2)
        for c, ident in list(CONNS):
            IDENT.id = ident
            try: c.sendall(frame(0x91, 0, J(status())))
            except OSError: CONNS.remove((c, ident))
threading.Thread(target=heartbeat, daemon=True).start()
L("scroll flag:", FLAG)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", PORT)); srv.listen(4); L("listening", PORT)
while True:
    c, a = srv.accept(); L("accept", a); threading.Thread(target=serve, args=(c,), daemon=True).start()
