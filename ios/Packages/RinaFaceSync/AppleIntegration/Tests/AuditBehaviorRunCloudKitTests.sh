#!/bin/bash
set -euo pipefail
integration_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
package_dir="$(cd -- "$integration_dir/.." && pwd)"
check_build_dir="${RINA_BEHAVIOR_FACESYNC_BUILD:-/tmp/rina-behavior-cloudkit-check}"
mkdir -p "$check_build_dir"
# The reference integration is deliberately outside the package/app targets.
# Compile its real core dependency directly, with no live CloudKit container.
xcrun swiftc -emit-library -static -emit-module -module-name FaceSyncCore \
    -swift-version 6 -target arm64-apple-macos14.0 \
    -module-cache-path "$check_build_dir/module-cache" \
    -I "$package_dir/Sources/CSQLite" "$package_dir/Sources/FaceSyncCore/"*.swift \
    -o "$check_build_dir/libFaceSyncCore.a"
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos14.0 \
    -module-cache-path "$check_build_dir/module-cache" \
    -I "$check_build_dir" -I "$package_dir/Sources/CSQLite" \
    "$integration_dir/CloudKitFetchedCheckpoint.swift" \
    "$integration_dir/Tests/AuditBehaviorCloudKitCheckpointTests.swift" \
    -L "$check_build_dir" -lFaceSyncCore -lsqlite3 -o "$check_build_dir/AuditBehaviorCloudKitCheckpointTests"
"$check_build_dir/AuditBehaviorCloudKitCheckpointTests"
xcrun swiftc -typecheck -swift-version 6 -target arm64-apple-macos14.0 \
    -module-cache-path "$check_build_dir/module-cache" \
    -I "$check_build_dir" -I "$package_dir/Sources/CSQLite" \
    "$integration_dir/CloudKitFetchedCheckpoint.swift" "$integration_dir/CloudKitFaceSync.swift"
