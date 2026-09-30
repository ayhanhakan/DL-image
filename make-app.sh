#!/bin/sh
# Builds AIWallpaper.app, a menu bar only bundle, into .build/AIWallpaper.app
set -e
swift build -c release
APP=.build/AIWallpaper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AIWallpaper "$APP/Contents/MacOS/"
# Bundle.module looks next to the executable, so the segmentation model goes there.
cp -R .build/release/AIWallpaper_AIWallpaper.bundle "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AI Wallpaper</string>
    <key>CFBundleIdentifier</key><string>dev.ayhanhakan.aiwallpaper</string>
    <key>CFBundleExecutable</key><string>AIWallpaper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
