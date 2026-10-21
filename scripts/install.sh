#!/usr/bin/env bash
# Release-build Rondo, sign it (SIGN_ID, default "Rondo Dev" if present), install to /Applications, relaunch.
# Usage: scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export SIGN_ID="${SIGN_ID:-Rondo Dev}"
scripts/bundle.sh release

if pgrep -x Rondo >/dev/null; then
  osascript -e 'tell application id "com.farazbukhari.rondo" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do pgrep -x Rondo >/dev/null || break; sleep 0.25; done
fi
ditto build/Rondo.app /Applications/Rondo.app
codesign -v /Applications/Rondo.app
codesign -dv /Applications/Rondo.app 2>&1 | grep -E "^(Authority|Signature)=" || true
open /Applications/Rondo.app
echo "Installed /Applications/Rondo.app"
