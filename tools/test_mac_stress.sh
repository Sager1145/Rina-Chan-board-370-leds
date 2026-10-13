#!/usr/bin/env bash
# Real-board stress through the production Mac models; no test Wi-Fi required.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${RINA_MAC_DERIVED_DATA:-${TMPDIR:-/tmp}/rina-mac-build}
LOG=${RINA_MAC_STRESS_LOG:-$WORK/mac-stress.log}
SIGN_IDENTITY=${RINA_MAC_SIGN_IDENTITY:--}
mkdir -p "$WORK"
swift "$ROOT/tools/check_mac_board_pairings.swift" || exit 1
TEST_RUNNER_RINA_MAC_HARDWARE_TESTS=1 TEST_RUNNER_RINA_MAC_STRESS_TESTS=1 xcodebuild test \
    -project "$ROOT/ios/RinaBoard.xcodeproj" -scheme RinaBoardMac \
    -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$WORK" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM= \
    -only-testing:RinaBoardTests/MacBoardStressHardwareTests/testSingleGroupAndSelectedBoardBLEStressAndRestore \
    -collect-test-diagnostics never -test-timeouts-enabled YES \
    -maximum-test-execution-time-allowance 300 >"$LOG" 2>&1
TEST_STATUS=$?
swift "$ROOT/tools/check_mac_board_pairings.swift"
PAIR_STATUS=$?
COUNTS=$(python3 "$ROOT/tools/ios_test_counts.py" "$LOG")
read -r EXECUTED SKIPPED FAILURES <<<"$COUNTS"
if [ "$TEST_STATUS" -ne 0 ] || [ "$PAIR_STATUS" -ne 0 ] || [ -z "$COUNTS" ] || \
   [ "$EXECUTED" -ne 1 ] || [ "$SKIPPED" -ne 0 ] || [ "$FAILURES" -ne 0 ]; then
    echo "Mac real-board stress failed; see $LOG" >&2
    exit 1
fi
for BOARD_ID in 80B54EF48E09 80B54EF74801; do
    for PROOF in 'singleFrames=50' 'singleControlBursts=5' \
                 'originalFacesNameNetworkTimelineBootPreserved=true' \
                 'originalSettingsOutputRestored=true' 'terminalDisconnectConfirmed=true'; do
        if ! rg -q "$BOARD_ID $PROOF" "$LOG"; then
            echo "$BOARD_ID missing proof: $PROOF; see $LOG" >&2
            exit 1
        fi
    done
done
for PROOF in 'mode=mirror groupFrames=50' 'mode=stitched groupFrames=50' \
             'selectedBoardSwitches=20' 'phasesCompleted=true'; do
    if ! rg -q "$PROOF" "$LOG"; then
        echo "Missing stress proof: $PROOF; see $LOG" >&2
        exit 1
    fi
done
echo "Physical single-board, group, and selected-board stress passed; originals restored and both boards disconnected."
