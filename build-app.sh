#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="build/NotchPerch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" /private/tmp/notchperch-swift-cache
./build-icon.sh
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NotchPerch</string>
<!-- Retain the original identifier for existing preferences and login-item identity. -->
<key>CFBundleIdentifier</key><string>dev.local.drop</string>
<key>CFBundleName</key><string>NotchPerch</string>
<key>CFBundleDisplayName</key><string>NotchPerch</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -module-cache-path /private/tmp/notchperch-swift-cache -parse-as-library -O \
  -target arm64-apple-macosx13.0 sources/notchperch/ShelfCore.swift sources/notchperch/ShelfPointerGeometry.swift sources/notchperch/VerifiedFileMove.swift sources/notchperch/main.swift \
  -framework AppKit -framework ServiceManagement \
  -o "$APP/Contents/MacOS/NotchPerch"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
