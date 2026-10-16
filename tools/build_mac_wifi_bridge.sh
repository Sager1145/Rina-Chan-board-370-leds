#!/usr/bin/env bash
# Xcode build phase: CoreWLAN is native macOS-only, so embed a narrow bundle.
set -euo pipefail
[ "${EFFECTIVE_PLATFORM_NAME:-}" = "-maccatalyst" ] || exit 0
SOURCE="$SRCROOT/MacSupport/RinaMacWiFiBridge.swift"
PROTOCOL="$SRCROOT/RinaBoard/Services/MacWiFiBridgeProtocol.swift"
SCAN_POLICY="$SRCROOT/RinaBoard/Services/MacWiFiScanPolicy.swift"
DESTINATION="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/PlugIns/RinaMacWiFiBridge.bundle"
# Module caches and codesign temporary files require a writable subtree. Xcode's
# script sandbox grants TEMP_DIR that access; declared outputs are literal paths.
WORK="$TEMP_DIR/mac-wifi-bridge"
BUNDLE="$WORK/RinaMacWiFiBridge.bundle"
mkdir -p "$BUNDLE/Contents/MacOS" "$WORK/modules"
SDK=$(xcrun --sdk macosx --show-sdk-path)
BINARIES=()
for BRIDGE_ARCH in $ARCHS; do
    BINARY="$WORK/RinaMacWiFiBridge-$BRIDGE_ARCH"
    xcrun --sdk macosx swiftc -emit-library -module-name RinaMacWiFiBridge \
        -target "$BRIDGE_ARCH-apple-macos14.0" -sdk "$SDK" \
        -module-cache-path "$WORK/modules" "$PROTOCOL" "$SCAN_POLICY" "$SOURCE" -o "$BINARY"
    BINARIES+=("$BINARY")
done
xcrun lipo -create "${BINARIES[@]}" -output "$BUNDLE/Contents/MacOS/RinaMacWiFiBridge"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.rinachan.board.mac.wifi-bridge</string>
<key>CFBundleExecutable</key><string>RinaMacWiFiBridge</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSPrincipalClass</key><string>RinaMacWiFiBridge</string>
</dict></plist>
PLIST
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$BUNDLE"
fi

# Publish only the final signed bytes to the explicitly declared output files.
mkdir -p "$DESTINATION/Contents/MacOS"
cp "$BUNDLE/Contents/MacOS/RinaMacWiFiBridge" "$DESTINATION/Contents/MacOS/RinaMacWiFiBridge"
cp "$BUNDLE/Contents/Info.plist" "$DESTINATION/Contents/Info.plist"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
    mkdir -p "$DESTINATION/Contents/_CodeSignature"
    cp "$BUNDLE/Contents/_CodeSignature/CodeResources" "$DESTINATION/Contents/_CodeSignature/CodeResources"
fi
