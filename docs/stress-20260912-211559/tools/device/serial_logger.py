# Serial logger for real-hardware stress: logs everything, sends `status` every 10 s,
# accepts extra commands by appending lines to <log>.cmd
import serial, sys, time, os
port, path, dur = sys.argv[1], sys.argv[2], float(sys.argv[3])
s = serial.Serial(port, 115200, timeout=0.1)
f = open(path, "ab", buffering=0); cmdp = path + ".cmd"; open(cmdp, "a").close(); off = os.path.getsize(cmdp)
def send(c):
    f.write(b"\n[HOST %.3f] >> %s\n" % (time.time(), c.encode())); s.write(c.encode() + b"\r\n")
send("log level debug"); t0 = time.time(); last = 0
while time.time() - t0 < dur:
    d = s.read(8192)
    if d: f.write(d)
    if time.time() - last > 10: send("status"); last = time.time()
    sz = os.path.getsize(cmdp)
    if sz > off:
        with open(cmdp) as c: c.seek(off); [send(l.strip()) for l in c.read().splitlines() if l.strip()]
        off = sz
