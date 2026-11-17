#!/bin/sh
# Builds a release binary and wraps it in "CPU Culprit.app" in the repo root.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product CPUCulprit
APP="CPU Culprit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CPUCulprit "$APP/Contents/MacOS/CPUCulprit"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CPU Culprit</string>
    <key>CFBundleIdentifier</key><string>local.cpu-culprit</string>
    <key>CFBundleExecutable</key><string>CPUCulprit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# The repo may sit in an iCloud synced folder, which tags new files with extended
# attributes that codesign refuses to sign over.
/usr/bin/xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"
