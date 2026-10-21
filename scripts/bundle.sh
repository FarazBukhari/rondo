#!/usr/bin/env bash
# Build the Rondo executable and assemble build/Rondo.app (no Xcode needed).
# Usage: [UNIVERSAL=1] [SIGN_ID="Rondo Dev"] scripts/bundle.sh [debug|release]
# Signing: uses $SIGN_ID if that code-signing identity exists, else ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${1:-debug}"
case "$CONF" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2 ;; esac

# UNIVERSAL=1 builds arm64 + x86_64 (requires full Xcode; Command Line Tools build the host arch only).
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == "1" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c "$CONF" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --product Rondo
BIN_DIR="$(swift build -c "$CONF" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

APP="build/Rondo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Rondo" "$APP/Contents/MacOS/Rondo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles, if any target declares resources
for b in "$BIN_DIR"/*.bundle; do [[ -e "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"; done

# Self-signed identities (e.g. "Rondo Dev" from Keychain Access) aren't "valid" to Apple's trust
# policy, so don't use -v: any code-signing identity with that name in the keychain works.
IDENTITY="-"
if [[ -n "${SIGN_ID:-}" ]]; then
  if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    IDENTITY="$SIGN_ID"
  else
    echo "warning: signing identity \"$SIGN_ID\" not found; using ad-hoc signature" >&2
  fi
fi
codesign --force --sign "$IDENTITY" --identifier com.farazbukhari.rondo "$APP"
echo "Built $APP ($CONF, signed: $IDENTITY)"
