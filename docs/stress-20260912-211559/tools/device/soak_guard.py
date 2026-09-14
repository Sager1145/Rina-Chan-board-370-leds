# Battery-guarded soak watcher for the real board.
# Follows the serial log written by serial_logger.py from a start offset, samples STATUS and ADC
# telemetry, and stops when the duration elapses or battery drops below the floor.
# Usage: soak_guard.py <serial_log> <start_offset> <duration_s> <battery_floor_pct> <out_csv>
# stdout: one line per minute plus one line per anomaly, and a final STOP line (for Monitor).
import csv, re, sys, time

LOG, OFF, DUR, FLOOR, OUT = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
ANOM = re.compile(r"event=(inbound_overflow|notify_failed|rx_ignored|connect_rejected|disconnect|advertise_restart_failed)"
                  r"|(rst:0x\w+|Guru Meditation|Backtrace|Task watchdog|abort\(\))")
BAT = re.compile(r"\[(\d+) ms\] \[\w+\] \[ADC\] event=battery vbat_raw=\d+ vbat=([\d.]+) percent=(\d+) charging=(\d)")
STAT = re.compile(r"STATUS frameEncoding=\S+ frameBytes=\d+ lit=(\d+) queued=(\d+) accepted=(\d+)[^\n]*\n"
                  r"STATUS ledBackend=\S+ dma=\d ledReady=(\d) refreshUs=(\d+) refreshMaxUs=(\d+) refreshFail=(\d+)[^\n]*\n"
                  r"STATUS heapFree=(\d+) largestBlock=(\d+)")

t0, pos, buf, rows, reason = time.time(), OFF, "", [], "duration"
last_bat = None
last_emit = 0.0
seen_status = 0
while True:
    with open(LOG, "rb") as f:
        f.seek(pos)
        chunk = f.read()
    pos += len(chunk)
    buf += chunk.decode("utf-8", "replace")
    for m in ANOM.finditer(buf):
        print("ANOMALY t=%.0fs %s" % (time.time() - t0, m.group(0)), flush=True)
    for m in BAT.finditer(buf):
        last_bat = (int(m.group(1)), float(m.group(2)), int(m.group(3)), int(m.group(4)))
    for m in STAT.finditer(buf):
        seen_status += 1
        lit, queued, accepted, ready, ref, refmax, fail, heap, largest = map(int, m.groups())
        rows.append(dict(t_s=round(time.time() - t0, 1), lit=lit, queued=queued, accepted=accepted, ledReady=ready,
                         refreshUs=ref, refreshMaxUs=refmax, refreshFail=fail, heapFree=heap, largestBlock=largest,
                         vbat=last_bat[1] if last_bat else "", battery_pct=last_bat[2] if last_bat else "",
                         charging=last_bat[3] if last_bat else ""))
    # Keep only an unfinished tail so multi-line STATUS blocks split across reads still match.
    buf = buf[-600:] if len(buf) > 600 else buf
    elapsed = time.time() - t0
    if elapsed - last_emit >= 60 and rows:
        r = rows[-1]
        print("MINUTE t=%.0fs bat=%s%% vbat=%s heap=%s refreshMaxUs=%s refreshFail=%s accepted=%s statusSamples=%d"
              % (elapsed, r["battery_pct"], r["vbat"], r["heapFree"], r["refreshMaxUs"], r["refreshFail"], r["accepted"],
                 seen_status), flush=True)
        last_emit = elapsed
    if last_bat and last_bat[2] < FLOOR and not last_bat[3]:
        reason = "battery_floor"
        break
    if elapsed >= DUR:
        break
    time.sleep(1.0)

if rows:
    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
print("STOP reason=%s elapsed=%.0fs samples=%d last_battery=%s end_offset=%d"
      % (reason, time.time() - t0, len(rows), last_bat[2] if last_bat else "n/a", pos), flush=True)
