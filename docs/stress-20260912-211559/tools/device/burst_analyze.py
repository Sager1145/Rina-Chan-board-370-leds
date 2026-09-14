# Analyse one rapid-tap burst from the board serial log.
# Usage: burst_analyze.py <serial_log> <start_offset> [end_offset] [label]
# Prints: commands the board received (in order, with seq gaps), LED apply reasons, scroll
# lifecycle, BLE anomalies/resets, and the last STATUS block after the burst, so the board's
# final state can be compared with what the iPhone UI shows.
import re, sys
from collections import Counter

log, start = sys.argv[1], int(sys.argv[2])
raw = open(log, "rb").read()
end = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] not in ("", "-") else len(raw)
label = sys.argv[4] if len(sys.argv) > 4 else "burst"
t = raw[start:end].decode("utf-8", "replace")

cmds = [(int(ms), int(seq), name) for ms, seq, name in
        re.findall(r"\[(\d+) ms\] \[\w+\] \[PROTO\] event=command slot=\d+ seq=(\d+) name=(\w+)", t)]
cmds_no_poll = [c for c in cmds if c[2] not in ("scroll_status", "get_status", "ping", "get_frame")]
print(f"== {label}: bytes {start}-{end}")
print("commands:", len(cmds), "non-poll:", len(cmds_no_poll), Counter(c[2] for c in cmds).most_common())
if cmds:
    seqs = [c[1] for c in cmds]
    gaps = [(a, b) for a, b in zip(seqs, seqs[1:]) if b != a + 1 and not (a == 255 and b == 1)]
    print("seq range:", seqs[0], "->", seqs[-1], "non-contiguous steps:", gaps[:10])
    span = cmds[-1][0] - cmds[0][0]
    print("board span ms:", span)
print("sequence (non-poll):", " ".join(f"{name}" for _, _, name in cmds_no_poll)[:1500])

applies = re.findall(r"\[(\d+) ms\] \[INFO\] \[LED\] event=apply_packed reason=(\w+) lit=(\d+)", t)
print("apply_packed:", len(applies), Counter(a[1] for a in applies).most_common(), "last:", applies[-1] if applies else None)
scroll = re.findall(r"\[(\d+) ms\] \[INFO\] \[SCROLL\] event=(start|stop|pause|end_pause|seek|loop)([^\n]*)", t)
print("scroll events:", Counter(s[1] for s in scroll).most_common(), "last:", scroll[-1] if scroll else None)
modes = re.findall(r"\[(\d+) ms\] \[\w+\] \[(?:STATE|MODE|PROTO|BTN)\] event=(mode|set_mode|auto|playback|button)[^\n]*", t)
other = Counter(re.findall(r"\[\w+\] \[([A-Z]+)\] event=([a-z_]+)", t))
print("event mix:", [f"{k[0]}.{k[1]}={v}" for k, v in other.most_common(18)])
errs = re.findall(r"[^\n]*(?:\[WARN\]|\[ERROR\]|event=(?:inbound_overflow|notify_failed|rx_ignored|connect_rejected|disconnect|busy|error|reject))[^\n]*", t)
resets = re.findall(r"rst:0x\w+|Guru Meditation|Backtrace|Task watchdog|abort\(\)", t)
print("warn/error lines:", len(errs)); [print("   ", e.strip()[:160]) for e in errs[:12]]
print("resets:", resets or "none")
st = re.findall(r"=== STATUS BEGIN ===(.*?)=== STATUS END ===", t, re.S)
if st:
    print("last STATUS:")
    for line in st[-1].strip().splitlines():
        print("   ", line.strip())
