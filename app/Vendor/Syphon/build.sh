#!/bin/bash
# Build vendored Syphon into a static library + Clang module with only the Command Line Tools
# (no Xcode, no SwiftPM, no `metal` compiler).
#
#   ./build.sh <outdir>             -> <outdir>/libSyphon.a, <outdir>/include/{module.modulemap,Syphon/*.h}
#   ./build.sh <outdir> --smoke     -> also builds and runs <outdir>/SyphonSmokeTest
#
# Env: ARCHS (default "arm64 x86_64"), CONFIG (release|debug, default release).
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <outdir> [--smoke]" >&2
    exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
SMOKE="${2:-}"
SRC="$HERE/Sources/Syphon"
ARCHS="${ARCHS:-arm64 x86_64}"
CONFIG="${CONFIG:-release}"
MIN_MACOS=13.0
OBJ="$OUT/obj"

ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(-arch "$a"); done

if [ "$CONFIG" = "debug" ]; then
    OPT_FLAGS=(-O0 -g -DDEBUG=1)       # DEBUG enables upstream SYPHONLOG output
else
    OPT_FLAGS=(-Os -DNDEBUG)
fi

CFLAGS=(
    "${ARCH_FLAGS[@]}"
    -mmacosx-version-min="$MIN_MACOS"
    -isysroot "$(xcrun --show-sdk-path)"
    "${OPT_FLAGS[@]}"
    -fobjc-arc
    -fmodules
    -include "$SRC/Syphon_Prefix.h"      # upstream GCC_PREFIX_HEADER
    -DSYPHON_CORE_SHARE                  # upstream Release define
    -DGL_SILENCE_DEPRECATION
    -I "$SRC" -I "$SRC/include" -I "$SRC/include/Syphon"
    -Wno-deprecated-declarations
)

rm -rf "$OBJ" "$OUT/include" "$OUT/libSyphon.a"
mkdir -p "$OBJ"

echo "Compiling Syphon ($CONFIG; archs: $ARCHS)..."
pids=()
for f in "$SRC"/*.m "$SRC"/*.c; do
    o="$OBJ/$(basename "${f%.*}").o"
    clang "${CFLAGS[@]}" -c "$f" -o "$o" &
    pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
[ $fail -eq 0 ] || { echo "compile failed" >&2; exit 1; }

libtool -static -no_warning_for_no_symbols -o "$OUT/libSyphon.a" "$OBJ"/*.o
rm -rf "$OBJ"

# Public headers + module map (same layout as the SwiftPM target's include dir).
mkdir -p "$OUT/include"
cp -R "$SRC/include/Syphon" "$OUT/include/"
cp "$SRC/include/module.modulemap" "$OUT/include/"

echo "Built $OUT/libSyphon.a ($(lipo -archs "$OUT/libSyphon.a" 2>/dev/null || echo "$ARCHS"))"
echo "Headers/module map in $OUT/include"

if [ "$SMOKE" = "--smoke" ]; then
    echo "Building SyphonSmokeTest..."
    HOST_ARCH="$(uname -m)"
    swiftc -swift-version 5 -O \
        -target "$HOST_ARCH-apple-macosx$MIN_MACOS" \
        -I "$OUT/include" -L "$OUT" -lSyphon \
        -framework Foundation -framework Cocoa -framework Metal -framework IOSurface \
        -framework OpenGL -framework CoreVideo \
        "$HERE/Sources/SyphonSmokeTest/main.swift" -o "$OUT/SyphonSmokeTest"
    "$OUT/SyphonSmokeTest"
fi
