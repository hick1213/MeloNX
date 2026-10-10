#!/usr/bin/env bash
set -euo pipefail
SOURCE="$PROJECT_DIR/JITDependencies/StikJIT.xcframework/ios-arm64/StikJIT.framework"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/StikJIT.framework"
mkdir -p "$(dirname "$DEST")"
/usr/bin/ditto "$SOURCE" "$DEST"
if [ ! -f "$DEST/Info.plist" ]; then
  cat > "$DEST/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.stikdebug.StikJIT</string>
<key>CFBundleExecutable</key><string>StikJIT</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.9.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.4</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict></plist>
PLIST
fi
if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,flags "$DEST"
fi
