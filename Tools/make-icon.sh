#!/bin/sh
# Build build/AppIcon.icns from Resources/AppIcon-source.png.
#BODY = icon body size in px within the 1024 canvas (padding = canvas - body).
set -eu
cd "$(dirname "$0")/.."

SRC=Resources/AppIcon-source.png
BODY=${BODY:-824}
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

swift Tools/render-icon.swift "$SRC" build/AppIcon-1024.png "$BODY"

rm -rf build/AppIcon.iconset
mkdir -p build/AppIcon.iconset
sips -Z   16 build/AppIcon-1024.png --out build/AppIcon.iconset/icon_16x16.png      >/dev/null
sips -Z   32 build/AppIcon-1024.png --out build/AppIcon.iconset/icon_16x16@2x.png   >/dev/null
sips -Z   32 build/AppIcon-1024.png --out build/AppIcon.iconset/icon_32x32.png      >/dev/null
sips -Z   64 build/AppIcon-1024.png --out build/AppIcon.iconset/icon_32x32@2x.png   >/dev/null
sips -Z  128 build/AppIcon-1024.png --out build/AppIcon.iconset/icon_128x128.png    >/dev/null
sips -Z  256 build/AppIcon-1024.png --out build/AppIcon.iconset/icon_128x128@2x.png >/dev/null
sips -Z  256 build/AppIcon-1024.png --out build/AppIcon.iconset/icon_256x256.png    >/dev/null
sips -Z  512 build/AppIcon-1024.png --out build/AppIcon.iconset/icon_256x256@2x.png >/dev/null
sips -Z  512 build/AppIcon-1024.png --out build/AppIcon.iconset/icon_512x512.png    >/dev/null
cp build/AppIcon-1024.png build/AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
echo "built build/AppIcon.icns"
