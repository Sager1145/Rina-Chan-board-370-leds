#!/usr/bin/env python3
"""Collect STRESSCASE lines from xcodebuild logs into cases.csv (last occurrence of a case wins)."""
import csv, json, sys

logs = sys.argv[2:]
out = sys.argv[1]
cases = {}
order = []
for log in logs:
    with open(log, errors="replace") as fh:
        for line in fh:
            idx = line.find("STRESSCASE {")
            if idx < 0:
                continue
            try:
                obj = json.loads(line[idx + len("STRESSCASE "):])
            except json.JSONDecodeError:
                continue
            cid = obj["case_id"]
            if cid not in cases:
                order.append(cid)
            obj["_log"] = log.split("/")[-1]
            cases[cid] = obj

extra = [row for row in (json.loads(a) for a in []) ]
with open(out, "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["case_id", "layer", "load", "seed", "status", "key_metrics", "evidence"])
    for cid in order:
        c = cases[cid]
        metrics = ";".join(f"{k}={v}" for k, v in sorted(c["metrics"].items()))
        w.writerow([cid, c["layer"], c["load"], c["seed"], c["status"], metrics,
                    f'{c["evidence"]} | logs/ios/{c["_log"]}'])
print(f"{len(order)} cases -> {out}")
