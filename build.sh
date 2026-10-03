#!/bin/bash
set -e
cd "$(dirname "$0")"

# Every iOS-Simulator dylib baguette injects, built and staged into
# Sources/Baguette/Resources/<Name>/ for SPM to `.copy` as a resource.
# Cross-compiled against the iphonesimulator SDK (fat: arm64 + x86_64),
# linker-signed adhoc. All of them are armed through one shared
# DYLD_INSERT_LIBRARIES (see `InjectedDylibs`), and the loop inside picks up
# a new Injected/<Name>/ with no edit here.
./Injected/build.sh

# Pure-SPM build. Private frameworks resolve through the rpath flags +
# linkedFramework declarations in Package.swift.
# Match Package.swift's macOS 15 target across Swift dependencies. Mixed targets
# emit incompatible Clock async specializations in optimized Swift 6.3 builds.
swift build -c release -Xswiftc -target -Xswiftc arm64-apple-macosx15.0 "$@"

# Drop the binary at the workspace root so the Makefile / install scripts
# find it where they always have.
#
# Remove first rather than `cp -f`. macOS caches a binary's code signature
# against its inode, and overwriting in place leaves the kernel validating
# the new bytes against the old cached signature — the copy then dies on
# launch with SIGKILL and no diagnostic. A fresh inode gets evaluated
# honestly.
rm -f ./Baguette
cp .build/release/Baguette ./Baguette
echo "Build complete: ./Baguette"
