#!/usr/bin/env bash
# Builds Skylark for the iOS Simulator into ./build/Skylark.app.
# Pass a UDID to install it there too: ./build.sh <UDID>
set -euo pipefail
cd "$(dirname "$0")"
app=build/Skylark.app
rm -rf build
mkdir -p "$app"
cp Info.plist "$app/Info.plist"
xcrun swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -o "$app/Skylark" main.swift
codesign -f -s - "$app" >/dev/null 2>&1
echo "built $app"
if [ $# -gt 0 ]; then
  xcrun simctl install "$1" "$app"
  echo "installed on $1 (bundle id dev.baguette.skylark)"
fi
