#!/bin/sh
# Install the Mac frames a Mac display's page can show it in, where
# `baguette serve --share-mac` reads them.
#
#   scripts/install-mac-frames.sh [frames folder]
#
# Installs every picture in scripts/mac-frames/ — named as the frames
# baguette measured (Sources/Device/Chrome/MacFrame.swift) — into the
# frames folder (default ~/Library/Application Support/baguette/Frames).
# A picture for any other measured frame, named the same way, can be
# dropped into that folder by hand.
set -eu

src=$(cd "$(dirname "$0")/mac-frames" && pwd)
dest=${1:-"$HOME/Library/Application Support/baguette/Frames"}
mkdir -p "$dest"

for picture in "$src"/*.png; do
    cp "$picture" "$dest/"
    echo "installed $(basename "$picture" .png)"
done
echo "frames in $dest"
