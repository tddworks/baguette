#!/bin/bash
# Build HIDButtons — an iOS-Simulator *executable* (not a dylib) that baguette
# spawns inside the guest with `simctl spawn`. See Sources/main.m for what
# it speaks, and docs/features/injected-programs/design.md for why it is one
# program of four.
#
# Same cross-compile recipe as the dylibs: iphonesimulator SDK, fat by
# default, single arch under BAGUETTE_INJECTED_ARCHS, linker-signed adhoc
# and never re-signed (iOS 26+ simulator dyld rejects a post-build
# `codesign --force`).
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=HIDButtons

build_slice() {
    local arch="$1"
    xcrun clang \
        -arch "$arch" \
        -isysroot "$SDK" \
        -target "${arch}-apple-ios17.0-simulator" \
        -I ../Shared \
        -framework Foundation \
        -fobjc-arc \
        -Wall \
        -Werror \
        -Wl,-adhoc_codesign \
        -o "${OUT}.${arch}" \
        Sources/*.m
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
