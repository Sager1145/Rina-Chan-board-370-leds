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
# With no lane names it runs core, facesync, facesync-guard, app, concurrency and mac.
# The Mac lane runs the same app unit tests on Mac Catalyst; physical boards
# are opt-in through tools/test_mac_boards.sh.
# The UI lane is explicit: add `ui` when a simulator is available for UI automation.
# `xcrun simctl list devices available`
# lists UDIDs. Pass a UDID rather than a name, because several simulators can
# share a name. Build products go under $RINA_VERIFY_DIR (default
# $TMPDIR/rinaboard-verify), outside ~/Documents: SwiftPM's test bundle fails
# codesign when .build sits there.

set -uo pipefail

# Distinct file:line sites, counted the way lane_concurrency counts them.
APP_STRICT_CONCURRENCY_BASELINE=29

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${RINA_VERIFY_DIR:-${TMPDIR:-/tmp}/rinaboard-verify}
mkdir -p "$WORK"

lanes=("$@")
[ ${#lanes[@]} -eq 0 ] && lanes=(core facesync facesync-guard app concurrency mac)

failed=()
summary=()

# Prints "executed skipped failures" from the last top-level summary line.
test_counts() {
    python3 "$ROOT/tools/ios_test_counts.py" "$1"
}

# $1 lane, $2 log, $3 exit status of the run.
judge_tests() {
    local lane=$1 log=$2 status=$3 counts executed skipped failures
    counts=$(test_counts "$log" "$lane")
    if [ -z "$counts" ]; then
        failed+=("$lane")
        summary+=("$lane: FAIL, no test summary found (build failure?); see $log")
        return
    fi
    read -r executed skipped failures <<<"$counts"
    if [ "$status" -ne 0 ] || [ "$failures" -ne 0 ] || [ "$((executed - skipped))" -le 0 ]; then
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

lane_facesync() {
    local log="$WORK/facesync.log"
    echo "==> facesync: swift test (RinaFaceSync)"
    swift test --package-path "$ROOT/ios/Packages/RinaFaceSync" \
        --scratch-path "$WORK/facesync-build" >"$log" 2>&1
    judge_tests facesync "$log" $?
}

lane_facesync_guard() {
    local log="$WORK/facesync-guard.log"
    echo "==> facesync-guard: integration boundary checks"
    if c++ -std=c++17 -Wall -Wextra -Werror "$ROOT/ios/Packages/RinaFaceSync/Firmware/guard_test.cpp" \
            -o "$WORK/facesync-guard" >"$log" 2>&1 && "$WORK/facesync-guard" >>"$log" 2>&1; then
        summary+=("facesync-guard: ok; see $log")
    else
        failed+=(facesync-guard)
        summary+=("facesync-guard: FAIL; see $log")
    fi
}

lane_ui() {
    local log="$WORK/ui.log"
    require_sim || { failed+=(ui); summary+=("ui: FAIL, RINA_SIM_ID not set"); return; }
    echo "==> ui: RinaBoardUITests on $RINA_SIM_ID"
    xcodebuild test -project "$ROOT/ios/RinaBoard.xcodeproj" -scheme RinaBoard \
        -destination "platform=iOS Simulator,id=$RINA_SIM_ID" -derivedDataPath "$WORK/ui-dd" \
        CODE_SIGNING_ALLOWED=NO -only-testing:RinaBoardUITests \
        -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 >"$log" 2>&1
    judge_tests ui "$log" $?
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
    # A hung test must fail by name. Without a per-test timeout a stuck stress
    # test stalls the whole run for about 10 minutes, and the only summary left
    # belongs to whichever sub-suite finished last.
    xcodebuild test-without-building -xctestrun "$xctestrun" -destination "$dest" \
        -only-testing:RinaBoardTests \
        -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 >"$log" 2>&1
    judge_tests app "$log" $?
}

lane_mac() {
    local log="$WORK/mac.log" sign_identity="${RINA_MAC_SIGN_IDENTITY:--}"
    echo "==> mac: shared RinaBoardTests on Mac Catalyst"
    TEST_RUNNER_RINA_MAC_TEST_HOST=1 xcodebuild test -project "$ROOT/ios/RinaBoard.xcodeproj" -scheme RinaBoardMac \
        -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$WORK/mac-dd" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$sign_identity" DEVELOPMENT_TEAM= \
        -only-testing:RinaBoardTests -skip-testing:RinaBoardTests/MacBoardHardwareTests \
        -skip-testing:RinaBoardTests/MacFeatureHardwareTests \
        -skip-testing:RinaBoardTests/MacBoardStressHardwareTests \
        -collect-test-diagnostics never -test-timeouts-enabled YES \
        -maximum-test-execution-time-allowance 120 >"$log" 2>&1
    judge_tests mac "$log" $?
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
        facesync) lane_facesync ;;
        facesync-guard) lane_facesync_guard ;;
        app) lane_app ;;
        ui) lane_ui ;;
        concurrency) lane_concurrency ;;
        mac) lane_mac ;;
        *) echo "unknown lane: $lane (expected core, facesync, facesync-guard, app, ui, concurrency, mac)" >&2; exit 2 ;;
    esac
done

echo
printf '%s\n' "${summary[@]}"
if [ ${#failed[@]} -ne 0 ]; then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "all lanes passed"
