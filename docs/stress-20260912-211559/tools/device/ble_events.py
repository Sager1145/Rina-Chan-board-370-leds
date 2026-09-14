# Extract BLE connection lifecycle + STATUS telemetry from the board serial log.
# Usage: ble_events.py <serial_log> <out_prefix>
#   <out_prefix>_ble.csv     one row per BLE lifecycle event (board ms clock)
#   <out_prefix>_cycles.csv  disconnect -> next subscribed(value=1) reconnect latency
#   <out_prefix>_status.csv  STATUS snapshots (heap, refresh, accepted/queued)
import csv, re, sys

log, prefix = sys.argv[1], sys.argv[2]
text = open(log, "rb").read().decode("utf-8", "replace")
ev_rx = re.compile(r"\[(\d+) ms\] \[\w+\] \[BLE\] event=(\w+)([^\n]*)")
events = [(int(ms), name, rest.strip()) for ms, name, rest in ev_rx.findall(text)]
with open(prefix + "_ble.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["board_ms", "event", "detail"]); w.writerows(events)

cycles, pending = [], None
for ms, name, rest in events:
    if name == "disconnect":
        pending = (ms, re.search(r"reason=(\d+)", rest).group(1) if "reason=" in rest else "")
    elif name == "tx_subscribed" and "value=1" in rest and pending:
        cycles.append((pending[0], ms, ms - pending[0], pending[1])); pending = None
with open(prefix + "_cycles.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["disconnect_ms", "resubscribed_ms", "gap_ms", "disconnect_reason"]); w.writerows(cycles)

# STATUS blocks: flatten key=value pairs between BEGIN/END.
blocks = re.findall(r"=== STATUS BEGIN ===(.*?)=== STATUS END ===", text, re.S)
keys = ["accepted", "queued", "lit", "refreshUs", "refreshMaxUs", "refreshFail", "heapFree", "largestBlock", "playback", "mode"]
with open(prefix + "_status.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["idx"] + keys)
    for i, b in enumerate(blocks):
        kv = dict(re.findall(r"(\w+)=(\S+)", b)); w.writerow([i] + [kv.get(k, "") for k in keys])

gaps = sorted(c[2] for c in cycles)
anom = re.findall(r"event=(connect_rejected|inbound_overflow|notify_failed|advertise_restart_failed|advertise_start_failed|initialization_timeout)|(Guru Meditation|rst:0x\w+|Task watchdog|Backtrace)", text)
print(f"ble_events={len(events)} cycles={len(cycles)} status_snapshots={len(blocks)}")
if gaps:
    pct = lambda p: gaps[min(len(gaps) - 1, int(p * len(gaps)))]
    print(f"reconnect_gap_ms p50={pct(.5)} p95={pct(.95)} max={gaps[-1]} min={gaps[0]}")
print("anomalies:", sorted(set("".join(a) for a in anom)) or "none")
