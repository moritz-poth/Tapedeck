#!/bin/bash
# Builds SystemRecorder.app next to this script (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"
APP=SystemRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
# Universal binary (Apple Silicon + Intel), macOS 13+
BUILD=$(mktemp -d)
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos13.0 *.swift -o "$BUILD/SystemRecorder-$arch"
done
lipo -create "$BUILD"/SystemRecorder-* -output "$APP/Contents/MacOS/SystemRecorder"

# App icon: rendered by the app itself, then scaled into an .icns
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/SystemRecorder" --render-icon "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ICONSET/icon_512x512@2x.png" AppIcon.png
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.moritzpoth.SystemRecorder</string>
  <key>CFBundleName</key><string>SystemRecorder</string>
  <key>CFBundleExecutable</key><string>SystemRecorder</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
# make Finder/Dock pick up the new icon instead of a cached one
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Fertig: $(pwd)/$APP"
