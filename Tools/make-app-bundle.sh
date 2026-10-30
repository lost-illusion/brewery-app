#!/bin/sh
# Build build/Brewery.app — a proper app bundle so the app gets normal
# activation + Dock presence, and a stable bundle identity for firewall rules
# (a bare `swift run` binary opens its window behind everything and has no Dock icon).
set -eu
cd "$(dirname "$0")/.."

swift build -c release
sh Tools/make-icon.sh

APP=build/Brewery.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BreweryApp "$APP/Contents/MacOS/Brewery"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Brewery</string>
    <key>CFBundleDisplayName</key>       <string>brewery</string>
    <key>CFBundleExecutable</key>        <string>Brewery</string>
    <key>CFBundleIdentifier</key>        <string>com.illusion.brewery</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "built $APP — run with: open build/Brewery.app"
