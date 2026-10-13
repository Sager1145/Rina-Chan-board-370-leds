# Battery-guarded soak watcher for the real board.
# Follows the serial log written by serial_logger.py from a start offset, samples STATUS and ADC
# telemetry, and stops when the duration elapses or battery drops below the floor.
# Usage: soak_guard.py <serial_log> <start_offset> <duration_s> <battery_floor_pct> <out_csv>
# stdout: one line per minute plus one line per anomaly, and a final STOP line (for Monitor).
import csv, re, sys, time

ANOM = re.compile(r"event=(inbound_overflow|notify_failed|rx_ignored|connect_rejected|disconnect|advertise_restart_failed)"
                  r"|(rst:0x\w+|Guru Meditation|Backtrace|Task watchdog|abort\(\))")
BAT = re.compile(r"\[(\d+) ms\] \[\w+\] \[ADC\] event=battery vbat_raw=\d+ vbat=([\d.]+) percent=(\d+) charging=(\d)")
STAT = re.compile(r"STATUS frameEncoding=\S+ frameBytes=\d+ lit=(\d+) queued=(\d+) accepted=(\d+)[^\n]*\n"
                  r"STATUS ledBackend=\S+ dma=\d ledReady=(\d) refreshUs=(\d+) refreshMaxUs=(\d+) refreshFail=(\d+)[^\n]*\n"
                  r"STATUS heapFree=(\d+) largestBlock=(\d+)")

class TelemetryParser:
    """Parse complete records once while retaining split multi-line status blocks."""
    def __init__(self):
        self.buffer = ""
        self.offset = 0
        self.last_end = {}

    def feed(self, chunk):
        self.buffer += chunk
        complete_end = self.buffer.rfind("\n") + 1
        complete = self.buffer[:complete_end]
        events = []
        for kind, pattern in (("anomaly", ANOM), ("battery", BAT), ("status", STAT)):
            for match in pattern.finditer(complete):
                end = self.offset + match.end()
                if end <= self.last_end.get(kind, -1):
                    continue
                self.last_end[kind] = end
                groups = (match.group(0),) if kind == "anomaly" else match.groups()
                events.append((self.offset + match.start(), kind, groups))
        # Retain complete recent lines for a STATUS block crossing reads, and
        # the entire unfinished line. Absolute match positions prevent recounts.
        discard = max(0, complete_end - 600)
        self.buffer = self.buffer[discard:]
        self.offset += discard
        return [(kind, groups) for _, kind, groups in sorted(events)]


def main():
    LOG, OFF, DUR, FLOOR, OUT = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
    t0, pos, rows, reason = time.time(), OFF, [], "duration"
    parser = TelemetryParser()
    last_bat = None
    last_emit = 0.0
    seen_status = 0
    while True:
        with open(LOG, "rb") as f:
            f.seek(pos)
            chunk = f.read()
        pos += len(chunk)
        for kind, groups in parser.feed(chunk.decode("utf-8", "replace")):
            if kind == "anomaly":
                print("ANOMALY t=%.0fs %s" % (time.time() - t0, groups[0]), flush=True)
            elif kind == "battery":
                last_bat = (int(groups[0]), float(groups[1]), int(groups[2]), int(groups[3]))
            elif kind == "status":
                seen_status += 1
                lit, queued, accepted, ready, ref, refmax, fail, heap, largest = map(int, groups)
                rows.append(dict(t_s=round(time.time() - t0, 1), lit=lit, queued=queued, accepted=accepted, ledReady=ready,
                                 refreshUs=ref, refreshMaxUs=refmax, refreshFail=fail, heapFree=heap, largestBlock=largest,
                                 vbat=last_bat[1] if last_bat else "", battery_pct=last_bat[2] if last_bat else "",
                                 charging=last_bat[3] if last_bat else ""))
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

if __name__ == "__main__":
    main()
