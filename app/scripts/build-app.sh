#!/bin/bash
# Build LowerThirds.app with only the Xcode Command Line Tools (no Xcode, no SwiftPM).
#
#   app/scripts/build-app.sh                 # release build, ad-hoc signed
#   SIGN_ID="Developer ID Application: LIFE (TEAMID)" app/scripts/build-app.sh
#   VERSION=1.2.0 BUILD=42 app/scripts/build-app.sh
#
# Output: app/build/LowerThirds.app  (+ app/build/lt-render CLI)
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$APP_DIR/build"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git -C "$APP_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_ID="${SIGN_ID:--}"           # "-" = ad-hoc
ARCHS="${ARCHS:-arm64 x86_64}"    # universal by default
MIN_OS=13.0

rm -rf "$OUT/LowerThirds.app"
mkdir -p "$OUT/obj"

echo "==> Syphon"
"$APP_DIR/Vendor/Syphon/build.sh" "$OUT/syphon"

CORE=("$APP_DIR"/Sources/LowerThirdsCore/*.swift)
APPSRC=("$APP_DIR"/Sources/LowerThirds/*.swift)

bins=()
for arch in $ARCHS; do
  echo "==> LowerThirds ($arch)"
  swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_OS" -module-name LowerThirds \
    -I "$OUT/syphon/include" -L "$OUT/syphon" -lSyphon \
    -Xlinker -ObjC \
    -framework Metal -framework IOSurface -framework OpenGL -framework CoreVideo -framework Cocoa \
    -framework ServiceManagement \
    "${CORE[@]}" "${APPSRC[@]}" -o "$OUT/obj/LowerThirds-$arch"
  bins+=("$OUT/obj/LowerThirds-$arch")
done

echo "==> lt-render (native arch)"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos$MIN_OS" -module-name lt_render \
  "${CORE[@]}" "$APP_DIR/Sources/lt-render/main.swift" -o "$OUT/lt-render"
cp "$APP_DIR"/Sources/LowerThirdsCore/Resources/*.png "$OUT/"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos$MIN_OS" -I "$OUT/syphon/include" -L "$OUT/syphon" -lSyphon \
  -framework Metal -framework IOSurface -framework OpenGL -framework CoreVideo -framework Cocoa \
  "$APP_DIR/Tools/syphon-grab.swift" -o "$OUT/syphon-grab"

echo "==> Bundle"
APP="$OUT/LowerThirds.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/LowerThirds"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$APP_DIR/Support/Info.plist" > "$APP/Contents/Info.plist"
cp "$APP_DIR"/Sources/LowerThirdsCore/Resources/*.png "$APP/Contents/Resources/"
[ -f "$APP_DIR/Support/AppIcon.icns" ] && cp "$APP_DIR/Support/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Sign ($SIGN_ID)"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - --entitlements "$APP_DIR/Support/LowerThirds.entitlements" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" \
    --entitlements "$APP_DIR/Support/LowerThirds.entitlements" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
lipo -info "$APP/Contents/MacOS/LowerThirds"
echo "Built $APP ($VERSION build $BUILD)"
