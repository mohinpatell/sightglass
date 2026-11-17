#!/bin/sh
# Builds a release binary and wraps it in "CPU Culprit.app" in the repo root.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product CPUCulprit
APP="CPU Culprit.app"
# Assemble and sign under .build first. The repo may sit in an iCloud synced folder,
# which tags new files with extended attributes while codesign is still working and
# makes it fail. .build is expected to live outside the synced folder.
STAGE=".build/bundle/$APP"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp .build/release/CPUCulprit "$STAGE/Contents/MacOS/CPUCulprit"
cat > "$STAGE/Contents/Info.plist" <<'PLIST'
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
codesign --force --sign - "$STAGE"
rm -rf "$APP"
cp -R "$STAGE" "$APP"
echo "Built $APP"
