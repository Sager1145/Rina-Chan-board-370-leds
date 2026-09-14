# Measure real firmware scroll speed and timeline drift from TRACE `event=tick idx=i/n` samples
# (rate-limited to ~1/s by the firmware). Windows touched by pause/step/seek/start/stop/loop
# INFO events are excluded, because the timeline is intentionally moved there.
# Usage: scroll_drift.py <serial_log> <start_offset> <expected_interval_ms> <out_csv>
import csv, re, sys

log, off, interval, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
text = open(log, "rb").read()[off:].decode("utf-8", "replace")
tick_rx = re.compile(r"\[(\d+) ms\] \[TRACE\] \[SCROLL\] event=tick idx=(\d+)/(\d+)")
ctl_rx = re.compile(r"\[(\d+) ms\] \[INFO\] \[SCROLL\] event=(pause|end_pause|step|seek|start|stop|loop)")
ticks = [(int(a), int(b), int(c)) for a, b, c in tick_rx.findall(text)]
ctl = [int(a) for a, _ in ctl_rx.findall(text)]

rows, expected_fps = [], 1000.0 / interval
for a, b in zip(ticks, ticks[1:]):
    dt = b[0] - a[0]
    touched = any(a[0] <= c <= b[0] for c in ctl)
    advance = (b[1] - a[1]) % b[2] if b[2] == a[2] else None
    fps = advance * 1000.0 / dt if (advance is not None and dt > 0) else None
    rows.append(dict(t0_ms=a[0], t1_ms=b[0], dt_ms=dt, idx0=a[1], idx1=b[1], count=b[2], advance=advance,
                     fps=round(fps, 3) if fps is not None else "", excluded=int(touched)))

clean = [r for r in rows if not r["excluded"] and r["fps"] != ""]
with open(out, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["t0_ms"])
    w.writeheader(); w.writerows(rows)

print("tick_samples=%d intervals=%d clean=%d excluded=%d control_events=%d" % (len(ticks), len(rows), len(clean), len(rows) - len(clean), len(ctl)))
if clean:
    fps = sorted(r["fps"] for r in clean)
    pct = lambda q: fps[min(len(fps) - 1, int(q * len(fps)))]
    total_adv = sum(r["advance"] for r in clean); total_ms = sum(r["dt_ms"] for r in clean)
    drift_frames = total_adv - total_ms / interval
    print("expected_fps=%.2f measured p1=%.2f p50=%.2f p99=%.2f min=%.2f max=%.2f" % (expected_fps, pct(.01), pct(.5), pct(.99), fps[0], fps[-1]))
    print("clean_span_s=%.0f frames_advanced=%d expected=%.1f cumulative_drift_frames=%.2f (%.3f%%)"
          % (total_ms / 1000, total_adv, total_ms / interval, drift_frames, 100.0 * drift_frames / max(1, total_ms / interval)))
    slow = [r for r in clean if abs(r["fps"] - expected_fps) > 0.15 * expected_fps]
    print("intervals_off_by_>15%%=%d" % len(slow), [(r["t0_ms"], r["fps"]) for r in slow[:5]])
