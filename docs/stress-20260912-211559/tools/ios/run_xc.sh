#!/bin/zsh
# usage: run_xc.sh <log> <timeout_s> <xcodebuild args...>
LOG=$1; shift; TO=$1; shift
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd /private/tmp/claude-501/-Users-sager-Documents-GitHub-Rina-Chan-board-370-leds/5af33a97-78fa-47d5-92a1-b11322991fe9/scratchpad/snap/ios
START=$(date +%s)
perl -e 'alarm shift; exec @ARGV' $TO xcodebuild "$@" > $LOG 2>&1
RC=$?
echo "WRAPPER_EXIT=$RC elapsed=$(( $(date +%s) - START ))s timeout=${TO}s" >> $LOG
