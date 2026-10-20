#!/usr/bin/env bash
# Build the Rondo executable and assemble build/Rondo.app (no Xcode needed).
# Usage: scripts/bundle.sh [debug|release]
# Signing: uses $SIGN_ID if that code-signing identity exists, else ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${1:-debug}"
case "$CONF" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2 ;; esac

swift build -c "$CONF" --product Rondo
BIN_DIR="$(swift build -c "$CONF" --show-bin-path)"

APP="build/Rondo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Rondo" "$APP/Contents/MacOS/Rondo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles, if any target declares resources
for b in "$BIN_DIR"/*.bundle; do [[ -e "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"; done

IDENTITY="-"
if [[ -n "${SIGN_ID:-}" ]] && security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  IDENTITY="$SIGN_ID"
fi
codesign --force --sign "$IDENTITY" --identifier com.farazbukhari.rondo "$APP"
echo "Built $APP ($CONF, signed: $IDENTITY)"
