# Timestamped serial logger: every line gets "[HOST <epoch>]" prefix.
# Sends `log level debug` at start and `status` every 10 s; extra commands can be
# appended to <log>.cmd (one per line).
import serial, sys, time, os
port, path, dur = sys.argv[1], sys.argv[2], float(sys.argv[3])
s = serial.Serial(port, 115200, timeout=0.1)
f = open(path, "ab", buffering=0); cmdp = path + ".cmd"; open(cmdp, "a").close(); off = os.path.getsize(cmdp)
buf = b""
def stamp(line): f.write(b"[HOST %.3f] " % time.time() + line + b"\n")
def send(c):
    stamp(b">> " + c.encode()); s.write(c.encode() + b"\r\n")
time.sleep(2.0)
send("log level debug"); t0 = time.time(); last = 0
while time.time() - t0 < dur:
    d = s.read(8192)
    if d:
        buf += d.replace(b"\x00", b"")
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1); stamp(line.rstrip(b"\r"))
    if time.time() - last > 10: send("status"); last = time.time()
    sz = os.path.getsize(cmdp)
    if sz > off:
        with open(cmdp) as c: c.seek(off); [send(l.strip()) for l in c.read().splitlines() if l.strip()]
        off = sz
