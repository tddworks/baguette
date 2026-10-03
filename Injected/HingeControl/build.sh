#!/bin/bash
# Build HingeControl — an iOS-Simulator *executable* (not a dylib) that
# baguette spawns inside the guest with `simctl spawn` to drive iPhone
# Duo's hinge. See Sources/HingeControl.m for what it speaks.
#
# Same cross-compile recipe as the dylibs: iphonesimulator SDK, fat by
# default, single arch under BAGUETTE_INJECTED_ARCHS, linker-signed adhoc
# and never re-signed (iOS 26+ simulator dyld rejects a post-build
# `codesign --force`).
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=HingeControl

build_slice() {
    local arch="$1"
    xcrun clang \
        -arch "$arch" \
        -isysroot "$SDK" \
        -target "${arch}-apple-ios17.0-simulator" \
        -framework Foundation \
        -fobjc-arc \
        -Wall \
        -Wl,-adhoc_codesign \
        -o "${OUT}.${arch}" \
        Sources/HingeControl.m Sources/Frontmost.m
}

ARCHS=${BAGUETTE_INJECTED_ARCHS:-"arm64 x86_64"}

SLICES=()
for arch in $ARCHS; do
    build_slice "$arch"
    SLICES+=("${OUT}.${arch}")
done

if [ "${#SLICES[@]}" -eq 1 ]; then
    mv "${SLICES[0]}" "$OUT"
else
    xcrun lipo -create "${SLICES[@]}" -output "$OUT"
    rm "${SLICES[@]}"
fi

echo "Built: $(pwd)/$OUT"
