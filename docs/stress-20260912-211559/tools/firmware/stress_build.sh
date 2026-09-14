#!/bin/bash
# Build a host stress harness against the REAL firmware translation units.
# Usage: stress_build.sh <harness.cpp> <out-binary> [asan]
# Production TUs compiled unmodified: state utils scroll_session led_renderer
# storage faces config; protocol.cpp and scroll.cpp are #included by the harness
# (so file-static handlers are reachable). Fakes live in stress_fakes/.
set -eo pipefail  # no -u: macOS bash 3.2 treats empty arrays as unbound
HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$HERE/../.." && pwd)"
AJ="${ARDUINOJSON_SRC:-$FW/.pio/libdeps/esp32s3-rmt-dma/ArduinoJson/src}"
HARNESS="$1"; OUT="$2"; MODE="${3:-plain}"
COMMON=(-std=c++17 -g -I"$HERE/stress_fakes" -I"$FW/src" -I"$AJ" -DARDUINOJSON_ENABLE_ARDUINO_STRING=1)
SAN=()
OPT=(-O1)
if [[ "$MODE" == asan ]]; then SAN=(-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer); fi
# Harness + fakes: strict. Production TUs: strict too, so any new warning shows.
STRICT=(-Wall -Wextra -Werror)
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/rina-stress-obj.XXXXXX")"
PIDS=()
for f in state utils scroll_session led_renderer storage faces config; do
  c++ "${COMMON[@]}" "${OPT[@]}" "${SAN[@]}" "${STRICT[@]}" -c "$FW/src/$f.cpp" -o "$OBJ/$f.o" & PIDS+=($!)
done
c++ "${COMMON[@]}" "${OPT[@]}" "${SAN[@]}" "${STRICT[@]}" -c "$HERE/stress_fakes/fake_platform.cpp" -o "$OBJ/fake_platform.o" & PIDS+=($!)
c++ "${COMMON[@]}" "${OPT[@]}" "${SAN[@]}" "${STRICT[@]}" -c "$HARNESS" -o "$OBJ/harness.o" & PIDS+=($!)
for p in "${PIDS[@]}"; do wait "$p"; done
c++ "${COMMON[@]}" "${SAN[@]}" "$OBJ"/*.o -o "$OUT"
rm -rf "$OBJ"
