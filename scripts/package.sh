#!/usr/bin/env bash
# Zip build/Rondo.app for a GitHub release and write its SHA-256 + release notes.
# Usage: scripts/package.sh v0.1.0   (tag must match CFBundleShortVersionString)
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: $0 vX.Y.Z}"
VERSION="${TAG#v}"
PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw build/Rondo.app/Contents/Info.plist)"
[[ "$VERSION" == "$PLIST_VERSION" ]] || { echo "tag $TAG != app version $PLIST_VERSION" >&2; exit 1; }

mkdir -p dist
ZIP="dist/Rondo-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Rondo.app "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

ARCHS="$(lipo -archs build/Rondo.app/Contents/MacOS/Rondo)"
# Notes = this version's CHANGELOG section + install steps.
{
  awk -v v="$VERSION" '$0 ~ "^## \\[?"v"\\]?" {on=1; next} /^## / && on {exit} on' CHANGELOG.md
  echo
  echo "### Install"
  echo "1. Download **Rondo-$VERSION.zip**, unzip, drag **Rondo.app** to Applications."
  echo "2. First launch: macOS blocks apps that aren't notarized. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run \`xattr -dr com.apple.quarantine /Applications/Rondo.app\`."
  echo "3. Optional helpers for video/audio and WebP/AVIF/SVG: \`brew install ffmpeg imagemagick\`."
  echo
  echo "Architectures: \`$ARCHS\` · SHA-256: \`$(cut -d' ' -f1 "$ZIP.sha256")\`"
} > dist/notes.md
echo "Packaged $ZIP ($ARCHS)"
