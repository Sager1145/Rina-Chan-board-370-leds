# Merge per-layer case tables into CASES.csv with one schema:
# case_id, layer, load, status, metrics, evidence, source
# Each source CSV keeps its own columns; unknown columns are folded into `metrics` as key=value.
# Status is normalised to PASS / FAIL / BLOCKED / NOT_RUN by its leading word.
import csv, glob, os, re, sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
out = os.path.join(root, "CASES.csv")
sources = sorted(glob.glob(os.path.join(root, "logs/baseline/summary.csv"))) + \
          sorted(glob.glob(os.path.join(root, "metrics/*/*.csv")))
skip = re.compile(r"_(ble|cycles|status|scroll_drift)\.csv$|relaunch_cycles\.csv$|soak_status\.csv$")
STATUS = re.compile(r"^\s*(PASS|FAIL|BLOCKED|NOT_RUN)")
ID_KEYS = ("case_id", "id", "case")
LOAD_KEYS = ("load", "command", "scenario")
EVID_KEYS = ("evidence", "log_path", "evidence_path")

rows, seen = [], set()
for path in sources:
    if skip.search(path):
        continue
    rel = os.path.relpath(path, root)
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            cid = next((r[k] for k in ID_KEYS if r.get(k)), "")
            if rel.startswith("logs/baseline/") and cid.isdigit():
                cid = "BASE-" + cid
            if not cid:
                continue
            status_raw = r.get("status", "")
            m = STATUS.match(status_raw)
            status = m.group(1) if m else "UNKNOWN"
            load = next((r[k] for k in LOAD_KEYS if r.get(k)), "")
            evid = next((r[k] for k in EVID_KEYS if r.get(k)), "")
            used = set(ID_KEYS) | set(LOAD_KEYS) | set(EVID_KEYS) | {"status", "layer"}
            extra = "; ".join(f"{k}={v}" for k, v in r.items() if k not in used and v not in ("", None))
            note = status_raw[m.end():].strip(" ()") if m else status_raw
            metrics = "; ".join(x for x in (note, extra) if x)
            key = (cid, rel)
            if key in seen:
                continue
            seen.add(key)
            rows.append(dict(case_id=cid, layer=r.get("layer", ""), load=load, status=status,
                             metrics=metrics, evidence=evid, source=rel))

with open(out, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["case_id", "layer", "load", "status", "metrics", "evidence", "source"])
    w.writeheader()
    w.writerows(rows)

from collections import Counter
by_src = Counter((r["source"], r["status"]) for r in rows)
print("wrote", out, "rows", len(rows))
for (src, st), n in sorted(by_src.items()):
    print(f"  {src}: {st}={n}")
dups = Counter(r["case_id"] for r in rows)
print("case_ids appearing in >1 source:", [k for k, v in dups.items() if v > 1] or "none")
