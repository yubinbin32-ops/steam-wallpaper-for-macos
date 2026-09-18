#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

APP_NAME="Wallpaper.app"
echo "🔨 Building release binary..."
swift build -c release

echo "📦 Creating $APP_NAME bundle..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

# Copy binary
cp ".build/release/WallpaperApp" "$APP_NAME/Contents/MacOS/WallpaperApp"

# Generate icns if logo.png exists and AppIcon.icns doesn't exist
if [ -f "logo.png" ] && [ ! -f "AppIcon.icns" ]; then
    echo "🎨 Generating AppIcon.icns from logo.png..."
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    sips -z 16 16     logo.png --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32     logo.png --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32     logo.png --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64     logo.png --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128   logo.png --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256   logo.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   logo.png --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512   logo.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   logo.png --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1
    sips -z 1024 1024 logo.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o AppIcon.icns
    rm -rf "$ICONSET"
fi

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$APP_NAME/Contents/Resources/AppIcon.icns"
fi

if [ -f "logo_white.png" ]; then
    cp "logo_white.png" "$APP_NAME/Contents/Resources/logo_white.png"
    cp "logo_white.png" "$APP_NAME/Contents/Resources/logo.png"
elif [ -f "logo.png" ]; then
    cp "logo.png" "$APP_NAME/Contents/Resources/logo.png"
fi

# Write Info.plist
cat << 'PLIST' > "$APP_NAME/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>WallpaperApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.wallpaper.mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Wallpaper</string>
    <key>CFBundleDisplayName</key>
    <string>Steam Wallpaper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

echo "🔏 Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_NAME"

echo "✅ $APP_NAME successfully packaged!"

if [ "$1" == "--zip" ]; then
    echo "🗜️ Creating SteamWallpaper-macOS.zip..."
    ditto -c -k --keepParent "$APP_NAME" "SteamWallpaper-macOS.zip"
    echo "✅ SteamWallpaper-macOS.zip ready!"
fi
