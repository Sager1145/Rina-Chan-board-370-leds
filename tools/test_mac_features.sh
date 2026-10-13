#!/usr/bin/env bash
# All non-destructive feature families using production models on both boards.
# Provision a scanned test Wi-Fi network in the app first; keep BLE enabled.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIGN_IDENTITY=${RINA_MAC_SIGN_IDENTITY:--}
WORK=${RINA_MAC_DERIVED_DATA:-${TMPDIR:-/tmp}/rina-mac-build}
LOG=${RINA_MAC_FEATURE_LOG:-$WORK/mac-features.log}
mkdir -p "$WORK"
swift "$ROOT/tools/check_mac_board_pairings.swift" || exit 1
TEST_RUNNER_RINA_MAC_HARDWARE_TESTS=1 xcodebuild test \
    -project "$ROOT/ios/RinaBoard.xcodeproj" -scheme RinaBoardMac \
    -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$WORK" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM= \
    -only-testing:RinaBoardTests/MacFeatureHardwareTests/testAllFeaturesOnBothRealBoardsAndRestore \
    -collect-test-diagnostics never -test-timeouts-enabled YES \
    -maximum-test-execution-time-allowance 600 >"$LOG" 2>&1
TEST_STATUS=$?
swift "$ROOT/tools/check_mac_board_pairings.swift"
PAIR_STATUS=$?
COUNTS=$(python3 "$ROOT/tools/ios_test_counts.py" "$LOG")
read -r EXECUTED SKIPPED FAILURES <<<"$COUNTS"
if [ "$TEST_STATUS" -ne 0 ] || [ "$PAIR_STATUS" -ne 0 ] || \
   [ -z "$COUNTS" ] || [ "$((EXECUTED - SKIPPED))" -le 0 ] || [ "$FAILURES" -ne 0 ]; then
    echo "Mac feature hardware check failed; see $LOG" >&2
    exit 1
fi
for BOARD_ID in 80B54EF48E09 80B54EF74801; do
    if ! rg -q "$BOARD_ID originalFacesSettingsOutputRestored=true" "$LOG" || \
       ! rg -q "$BOARD_ID terminalDisconnectConfirmed=true" "$LOG"; then
        echo "$BOARD_ID restoration/disconnection proof missing; see $LOG" >&2
        exit 1
    fi
done
echo "Feature tests passed on both boards; saved faces, settings and output restored; Bluetooth disconnected."
echo "Clear the test Wi-Fi profile on both boards in the app after network testing."
