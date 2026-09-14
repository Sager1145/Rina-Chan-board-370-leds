#!/bin/bash
# Build + run all firmware host stress harnesses (F1-F7) and collect artifacts.
# Usage: stress_run_all.sh <OUT dir> [fuzzIterations=1000000]
# Writes: <OUT>/logs/firmware/*.log, <OUT>/metrics/firmware/cases.csv, <OUT>/tools/firmware/* (sources)
set -eo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$HERE/../.." && pwd)"
OUT="$1"; ITERS="${2:-1000000}"
[[ -n "$OUT" ]] || { echo "usage: $0 <OUT> [iters]"; exit 2; }
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rina-stress.XXXXXX")"
mkdir -p "$OUT/logs/firmware" "$OUT/metrics/firmware" "$OUT/tools/firmware/stress_fakes/freertos"
LOG="$OUT/logs/firmware"
export TMPDIR="$BUILD"

build() { # name source mode
  if ! bash "$HERE/stress_build.sh" "$HERE/$2" "$BUILD/$1" "$3" > "$LOG/${1}_build.log" 2>&1; then echo "BUILD FAIL $1"; return 1; fi
}
PIDS=()
build f1_parser stress_f1_parser.cpp asan & PIDS+=($!)
( c++ -std=c++17 -Wall -Wextra -Werror -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -I"$FW/src" "$HERE/stress_f2_senders.cpp" -o "$BUILD/f2_senders" > "$LOG/f2_senders_build.log" 2>&1 ) & PIDS+=($!)
build f3_queue stress_f3_queue.cpp asan & PIDS+=($!)
build f4_events stress_f4_events.cpp asan & PIDS+=($!)
build f5_f7_blob stress_f5_f7_blob.cpp asan & PIDS+=($!)
build f6_scroll_timing stress_f6_scroll_timing.cpp plain & PIDS+=($!)
build json_capacity stress_json_capacity.cpp plain & PIDS+=($!)
for p in "${PIDS[@]}"; do wait "$p"; done

run() { # name args...
  local n="$1"; shift
  local t0=$(date +%s)
  set +e
  ( ulimit -t 900; ulimit -v 4000000 2>/dev/null; "$BUILD/$n" "$@" ) > "$LOG/$n.log" 2>&1
  local rc=$?
  set -e
  echo "$n exit=$rc secs=$(( $(date +%s) - t0 ))" | tee -a "$LOG/run_summary.txt"
}
: > "$LOG/run_summary.txt"
run f1_parser "$ITERS" 0xC0FFEE &
run f2_senders &
run f3_queue &
run f4_events &
run f5_f7_blob "$BUILD/fakefs" &
run f6_scroll_timing &
run json_capacity "$FW/data/resources/saved_faces.json" &
wait

{
  echo "case_id,layer,load,seed,status,metrics,evidence"
  for f in f1_parser f2_senders f3_queue f4_events f5_f7_blob f6_scroll_timing json_capacity; do
    grep -h '^CASE,' "$LOG/$f.log" | sed 's/^CASE,//' || true
    if ! grep -q '^SUMMARY' "$LOG/$f.log"; then echo "${f}-HARNESS,fw-host,-,-,FAIL,harness did not finish (see log),logs/firmware/$f.log"; fi
  done
} > "$OUT/metrics/firmware/cases.csv"

cp "$HERE"/stress_*.cpp "$HERE"/stress_*.h "$HERE"/stress_*.sh "$OUT/tools/firmware/"
cp "$HERE"/stress_fakes/*.h "$HERE"/stress_fakes/*.cpp "$OUT/tools/firmware/stress_fakes/"
cp "$HERE"/stress_fakes/freertos/*.h "$OUT/tools/firmware/stress_fakes/freertos/"
awk -F, 'NR>1{c[$5]++} END{for(k in c) printf "%s=%d ", k, c[k]; print ""}' "$OUT/metrics/firmware/cases.csv" | tee -a "$LOG/run_summary.txt"
rm -rf "$BUILD"
