#!/usr/bin/env bash
# Build the iPad sources as a locally signed Mac Catalyst app.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${1:-Release}
SIGN_IDENTITY=${RINA_MAC_SIGN_IDENTITY:--}
WORK=${RINA_MAC_DERIVED_DATA:-${TMPDIR:-/tmp}/rina-mac-build}
OUT=${RINA_MAC_OUTPUT:-$HOME/Applications/RinaBoard-Mac}
xcodebuild build -project "$ROOT/ios/RinaBoard.xcodeproj" -scheme RinaBoardMac \
    -configuration "$CONFIG" -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$WORK" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
mkdir -p "$OUT"
ditto --norsrc --noextattr "$WORK/Build/Products/$CONFIG-maccatalyst/RinaBoard.app" "$OUT/RinaBoard.app"
# File-provider folders can attach Finder metadata during the copy. Remove
# only signing-incompatible metadata from this generated application.
python3 - "$OUT/RinaBoard.app" <<'PYTHON'
import os, subprocess, sys
for directory, folders, files in os.walk(sys.argv[1]):
    for path in [directory] + [os.path.join(directory, name) for name in files]:
        attributes = subprocess.run(["/usr/bin/xattr", path], check=True,
                                    capture_output=True, text=True).stdout.splitlines()
        for name in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
            if name in attributes:
                subprocess.run(["/usr/bin/xattr", "-d", name, path], check=True)

PYTHON
codesign --verify --deep --strict "$OUT/RinaBoard.app"
echo "Mac app: $OUT/RinaBoard.app"
