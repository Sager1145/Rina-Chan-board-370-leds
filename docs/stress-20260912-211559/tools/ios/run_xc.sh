#!/bin/zsh
# usage: run_xc.sh <log> <timeout_s> <xcodebuild args...>
[[ $# -ge 3 ]] || { echo "usage: $0 <log> <timeout_s> <xcodebuild args...>" >&2; exit 2; }
LOG=$1; shift; TO=$1; shift
START=$(date +%s)
# Inherit the caller's checkout and selected Xcode; do not force an obsolete snapshot.
perl -e 'alarm shift; exec @ARGV' "$TO" xcodebuild "$@" > "$LOG" 2>&1
RC=$?
echo "WRAPPER_EXIT=$RC elapsed=$(( $(date +%s) - START ))s timeout=${TO}s" >> "$LOG"
exit "$RC"
