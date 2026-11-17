#!/bin/sh
# Builds a release binary and wraps it in "Sightglass.app" in the repo root.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product Sightglass
APP="Sightglass.app"
# Assemble and sign under .build first. The repo may sit in an iCloud synced folder,
# which tags new files with extended attributes while codesign is still working and
# makes it fail. .build is expected to live outside the synced folder.
STAGE=".build/bundle/$APP"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp .build/release/Sightglass "$STAGE/Contents/MacOS/Sightglass"
cp Support/Info.plist "$STAGE/Contents/Info.plist"
codesign --force --sign - "$STAGE"
rm -rf "$APP"
cp -R "$STAGE" "$APP"
echo "Built $APP"
