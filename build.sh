#!/bin/bash
set -e
cd "$(dirname "$0")"

# Pure-SPM build. Private frameworks resolve through the rpath flags +
# linkedFramework declarations in Package.swift.
swift build -c release

# Drop the binary at the workspace root so the Makefile / install scripts
# find it where they always have.
cp -f .build/release/Baguette ./Baguette
echo "Build complete: ./Baguette"
