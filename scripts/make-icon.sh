#!/usr/bin/env bash
# Build Resources/AppIcon.icns from the original vector design in scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p build
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
