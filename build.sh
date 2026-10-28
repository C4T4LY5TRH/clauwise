#!/bin/bash
set -e
cd "$(dirname "$0")"

# Builds Clauwise.app for Apple Silicon (arm64) with the Swift command-line toolchain.
swift build -c release
BIN=".build/release/Clauwise"

mkdir -p Clauwise.app/Contents/MacOS Clauwise.app/Contents/Resources
cp "$BIN" Clauwise.app/Contents/MacOS/Clauwise
cp Resources/AppIcon.icns Clauwise.app/Contents/Resources/AppIcon.icns
# Ad-hoc sign: unsigned bundles cannot request notification permission.
codesign --force --deep -s - Clauwise.app
echo "Built Clauwise.app ($(lipo -archs "$BIN"))"
