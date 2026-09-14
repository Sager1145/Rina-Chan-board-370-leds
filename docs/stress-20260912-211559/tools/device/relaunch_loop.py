# Real-hardware reconnect stress: force-quit / relaunch RinaBoard on the attached iPhone N times
# and measure BLE reconnect latency from the board's serial log (written by serial_logger.py).
# Usage: relaunch_loop.py <udid> <serial_log> <cycles> <out_csv> [seed]
import csv, json, os, random, re, subprocess, sys, tempfile, time

UDID, LOG, CYCLES, OUT = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
SEED = int(sys.argv[5]) if len(sys.argv) > 5 else 20260912
BUNDLE = "com.rinachan.board"
ENV = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer")
RECONNECT_DEADLINE_S = 15.0
rng = random.Random(SEED)


def devicectl(*args, positional=()):
    # Options must precede positionals: anything after `process launch <bundle>` is passed to the app.
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
        path = tmp.name
    r = subprocess.run(["xcrun", "devicectl", *args, "--device", UDID, "--json-output", path, "-q", *positional],
                       env=ENV, capture_output=True, text=True, timeout=60)
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
    os.unlink(path)
    return r.returncode, data, r.stderr[-400:]


def app_pid():
    rc, data, _ = devicectl("device", "info", "processes")
    for p in data.get("result", {}).get("runningProcesses", []):
        if p.get("executable", "").endswith("/RinaBoard.app/RinaBoard"):
            return p.get("processIdentifier")
    return None


def log_size():
    return os.path.getsize(LOG)


def wait_for(pattern, start_offset, deadline_s):
    rx = re.compile(pattern)
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        with open(LOG, "rb") as f:
            f.seek(start_offset)
            chunk = f.read().decode("utf-8", "replace")
        m = rx.search(chunk)
        if m:
            return time.time() - t0, m.group(0)
        time.sleep(0.1)
    return None, None


rows = []
for i in range(CYCLES):
    pid = app_pid()
    off = log_size()
    t_kill = time.time()
    kill_rc = None
    if pid:
        kill_rc, _, _ = devicectl("device", "process", "terminate", "--pid", str(pid), "--kill")
    disc_s, _ = wait_for(r"\[BLE\] event=disconnect[^\n]*", off, 8.0)
    # Randomised dwell so reconnects land at different phases of the board's advertise restart.
    dwell = rng.choice([0.0, 0.2, 0.5, 1.0, 2.0, 3.0])
    time.sleep(dwell)
    off2 = log_size()
    t_launch = time.time()
    launch_rc, _, launch_err = devicectl("device", "process", "launch", positional=(BUNDLE,))
    conn_s, conn_line = wait_for(r"\[BLE\] event=connect[^\n]*", off2, RECONNECT_DEADLINE_S)
    sub_s, _ = wait_for(r"\[BLE\] event=tx_subscribed[^\n]*value=1", off2, RECONNECT_DEADLINE_S)
    rx_s, _ = wait_for(r"\[BLE\] event=rx_write[^\n]*", off2, RECONNECT_DEADLINE_S)
    with open(LOG, "rb") as f:
        f.seek(off)
        seg = f.read().decode("utf-8", "replace")
    anomalies = sorted(set(re.findall(
        r"event=(connect_rejected|inbound_overflow|notify_failed|advertise_restart_failed|"
        r"advertise_start_failed|initialization_timeout|rx_ignored)|Guru Meditation|rst:0x|abort\(\)|"
        r"Task watchdog|Backtrace", seg)))
    row = dict(cycle=i, seed=SEED, pid_before=pid, kill_rc=kill_rc, disconnect_s=disc_s, dwell_s=dwell,
               launch_rc=launch_rc, connect_s=conn_s, subscribed_s=sub_s, first_rx_s=rx_s,
               status="PASS" if (launch_rc == 0 and sub_s is not None and rx_s is not None) else "FAIL",
               anomalies="|".join(a for a in anomalies if a), launch_err=launch_err.strip()[:120] if launch_rc else "")
    rows.append(row)
    print(json.dumps(row), flush=True)
    time.sleep(1.0)

with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)
