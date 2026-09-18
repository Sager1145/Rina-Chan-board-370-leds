#!/usr/bin/env bash
# Runs every iOS verification lane and fails loudly (external audit A57).
#
# Why this exists: no single Xcode scheme run covers RinaCore. RinaCore is
# attached to RinaBoard.xcodeproj as an XCLocalSwiftPackageReference, and in
# that setup xcodebuild exposes only its library product and never its test
# target. A RinaCoreTests entry hand-added to the shared scheme is dropped
# silently, and even the scheme Xcode generates for the package produces an
# xctestrun with no test configurations. So a green Cmd+U never ran the ~300
# core tests. The repo has no CI, so this script is the explicit step.
#
# Lanes:
#   core         `swift test` for ios/Packages/RinaCore. The package is in
#                Swift 6 language mode, so a data race is already a compile
#                error here.
#   app          RinaBoardTests on the simulator given by RINA_SIM_ID.
#   concurrency  Builds the app (still Swift 5) with complete strict-concurrency
#                checking and counts the distinct diagnostic sites. Fails if the
#                count rises above APP_STRICT_CONCURRENCY_BASELINE. When you fix
#                some sites, lower the baseline to the printed count so it only
#                ever goes down.
#
# A lane passes only if it ran more than zero tests with zero failures.
# xcodebuild reports "Executed 0 tests ... TEST EXECUTE SUCCEEDED" for a
# filter that matched nothing, and in zsh an unquoted variable holding two
# -only-testing flags does exactly that. The script prints executed and
# skipped counts so a run that was mostly skips is visible.
#
# Usage:
#   RINA_SIM_ID=<simulator UDID> ./tools/verify_ios.sh [core] [app] [concurrency]
# With no lane names it runs all three. `xcrun simctl list devices available`
# lists UDIDs. Pass a UDID rather than a name, because several simulators can
# share a name. Build products go under $RINA_VERIFY_DIR (default
# $TMPDIR/rinaboard-verify), outside ~/Documents: SwiftPM's test bundle fails
# codesign when .build sits there.

set -uo pipefail

APP_STRICT_CONCURRENCY_BASELINE=46

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${RINA_VERIFY_DIR:-${TMPDIR:-/tmp}/rinaboard-verify}
mkdir -p "$WORK"

lanes=("$@")
[ ${#lanes[@]} -eq 0 ] && lanes=(core app concurrency)

failed=()
summary=()

# Prints "executed skipped failures" from the last top-level summary line.
test_counts() {
    grep -E 'Executed [0-9]+ tests?, with' "$1" | tail -1 | sed -E \
        -e 's/.*Executed ([0-9]+) tests?, with (([0-9]+) tests? skipped and )?([0-9]+) failures?.*/\1 \3 \4/' \
        | awk '{ print $1, ($3 == "" ? 0 : $2), ($3 == "" ? $2 : $3) }'
}

# $1 lane, $2 log, $3 exit status of the run.
judge_tests() {
    local lane=$1 log=$2 status=$3 counts executed skipped failures
    counts=$(test_counts "$log")
    if [ -z "$counts" ]; then
        failed+=("$lane")
        summary+=("$lane: FAIL, no test summary found (build failure?); see $log")
        return
    fi
    read -r executed skipped failures <<<"$counts"
    if [ "$status" -ne 0 ] || [ "$failures" -ne 0 ] || [ "$executed" -eq 0 ]; then
        failed+=("$lane")
        summary+=("$lane: FAIL, $executed executed, $skipped skipped, $failures failed (exit $status); see $log")
    else
        summary+=("$lane: ok, $executed executed, $skipped skipped, 0 failed")
    fi
}

lane_core() {
    local log="$WORK/core.log"
    echo "==> core: swift test (RinaCore)"
    swift test --package-path "$ROOT/ios/Packages/RinaCore" \
        --scratch-path "$WORK/rinacore-build" >"$log" 2>&1
    judge_tests core "$log" $?
}

require_sim() {
    if [ -z "${RINA_SIM_ID:-}" ]; then
        echo "RINA_SIM_ID is not set. Available iPhone simulators:" >&2
        xcrun simctl list devices available | grep -E 'iPhone' >&2
        return 1
    fi
}

lane_app() {
    local log="$WORK/app.log" dest xctestrun
    require_sim || { failed+=(app); summary+=("app: FAIL, RINA_SIM_ID not set"); return; }
    dest="platform=iOS Simulator,id=$RINA_SIM_ID"
    echo "==> app: RinaBoardTests on $RINA_SIM_ID"
    if ! xcodebuild build-for-testing -project "$ROOT/ios/RinaBoard.xcodeproj" -scheme RinaBoard \
            -destination "$dest" -derivedDataPath "$WORK/app-dd" CODE_SIGNING_ALLOWED=NO \
            >"$WORK/app-build.log" 2>&1; then
        failed+=(app)
        summary+=("app: FAIL, build-for-testing failed; see $WORK/app-build.log")
        return
    fi
    xctestrun=$(ls "$WORK"/app-dd/Build/Products/*.xctestrun 2>/dev/null | head -1)
    xcodebuild test-without-building -xctestrun "$xctestrun" -destination "$dest" \
        -only-testing:RinaBoardTests >"$log" 2>&1
    judge_tests app "$log" $?
}

lane_concurrency() {
    local log="$WORK/concurrency.log" sites
    echo "==> concurrency: app with SWIFT_STRICT_CONCURRENCY=complete"
    # A fresh derived-data dir on every run: an incremental build does not
    # re-emit warnings for unchanged files, so a reused one would undercount.
    rm -rf "$WORK/concurrency-dd"
    if ! xcodebuild build -project "$ROOT/ios/RinaBoard.xcodeproj" -scheme RinaBoard \
            -destination 'generic/platform=iOS Simulator' -derivedDataPath "$WORK/concurrency-dd" \
            CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete >"$log" 2>&1; then
        failed+=(concurrency)
        summary+=("concurrency: FAIL, build failed; see $log")
        return
    fi
    sites=$(grep -E '^/.*/ios/RinaBoard/.*\.swift:[0-9]+:[0-9]+: warning:' "$log" \
        | cut -d: -f1,2 | sort -u | wc -l | tr -d ' ')
    if [ "$sites" -gt "$APP_STRICT_CONCURRENCY_BASELINE" ]; then
        failed+=(concurrency)
        summary+=("concurrency: FAIL, $sites diagnostic sites > baseline $APP_STRICT_CONCURRENCY_BASELINE; see $log")
    elif [ "$sites" -lt "$APP_STRICT_CONCURRENCY_BASELINE" ]; then
        summary+=("concurrency: ok, $sites sites; lower APP_STRICT_CONCURRENCY_BASELINE to $sites")
    else
        summary+=("concurrency: ok, $sites sites (baseline $APP_STRICT_CONCURRENCY_BASELINE)")
    fi
}

for lane in "${lanes[@]}"; do
    case "$lane" in
        core) lane_core ;;
        app) lane_app ;;
        concurrency) lane_concurrency ;;
        *) echo "unknown lane: $lane (expected core, app, concurrency)" >&2; exit 2 ;;
    esac
done

echo
printf '%s\n' "${summary[@]}"
if [ ${#failed[@]} -ne 0 ]; then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "all lanes passed"
