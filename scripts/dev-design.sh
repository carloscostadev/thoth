#!/bin/bash
# Builds a side-by-side "Thoth Design" app for testing the redesign.
# It lives in build/ and runs next to the stable Thoth: it never touches
# /Applications/Thoth.app and only restarts its own instance.
set -e

cd "$(dirname "$0")/.."

APP_NAME="Thoth Design"
EXECUTABLE="Thoth"
BUNDLE_ID="com.carloscosta.thoth.design"
BUILD_DIR="build"
APP_BUNDLE="$PWD/$BUILD_DIR/$APP_NAME.app"
ICON_SRC="icon/icon_1024.png"
VERSION="$(tr -d '[:space:]' < VERSION)-design"

echo "Building $APP_NAME (debug)..."
swift build

BIN_PATH=$(swift build --show-bin-path)

# Stop only the design instance (matched by its full path), never the stable app.
pkill -f "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
sleep 0.5

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/"

ICON_KEY=""
if [ -f "$ICON_SRC" ]; then
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    $ICON_KEY
</dict>
</plist>
PLIST

echo "Opening $APP_BUNDLE..."
open -n "$APP_BUNDLE"

echo "Done! $APP_NAME ($BUNDLE_ID) is running from $BUILD_DIR/."
