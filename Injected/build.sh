#!/bin/bash
# Build every injected iOS-Simulator dylib and stage it for SPM to bundle.
#
# One loop over `Injected/*/build.sh`, deliberately, because the alternative
# has already bitten us: each dylib used to need its own stanza here, in the
# repo-root build.sh, in .gitignore, *and* in homebrew-core's formula. Adding
# VirtualNetwork updated three of those four, so Homebrew kept shipping the
# committed universal binary and its CI broke on `brew audit`
# ("Unexpected universal binaries were found") plus a relocation failure.
# A new Injected/<Name>/ directory now needs no edit anywhere in this path.
#
# `BAGUETTE_INJECTED_ARCHS` passes straight through to each script — unset
# builds fat (arm64 + x86_64), Homebrew sets the single host arch.
set -e
cd "$(dirname "$0")"

for script in */build.sh; do
    name=$(dirname "$script")
    "./$script"

    # A dylib to inject, or — HingeControl — an executable to spawn in
    # the guest. Either way the product is named for its directory.
    dylib="$name/$name.dylib"
    if [ ! -f "$dylib" ]; then dylib="$name/$name"; fi

    # clang exits 0 when its source glob matched nothing, emitting a valid
    # but symbol-less 16KB stub. That is not hypothetical: homebrew-core's
    # formula pointed at `<Name>/Sources/*.m` instead of
    # `Injected/<Name>/Sources/*.m`, so every Homebrew release shipped empty
    # VirtualCamera / VirtualMotion dylibs that loaded fine and did nothing.
    # A dylib with no exported symbols is always a build bug — fail loudly.
    if [ "$(nm -gU "$dylib" 2>/dev/null | grep -c '^[0-9a-f]')" -eq 0 ]; then
        echo "error: $dylib exports no symbols — did its sources compile?" >&2
        exit 1
    fi

    # Staged where Package.swift `.copy`s it from.
    mkdir -p "../Sources/Baguette/Resources/$name"
    cp -f "$dylib" "../Sources/Baguette/Resources/$name/"
    for license in "$name"/Sources/LICENSE*; do
        [ -f "$license" ] || continue
        cp -f "$license" "../Sources/Baguette/Resources/$name/"
    done
done
