#!/usr/bin/env bash
# Bundle Rondo, quit any running instance, launch the fresh build.
# Usage: scripts/run.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh "${1:-debug}"
if pgrep -x Rondo >/dev/null; then
  osascript -e 'tell application id "com.farazbukhari.rondo" to quit' >/dev/null 2>&1 || pkill -x Rondo || true
  for _ in {1..20}; do pgrep -x Rondo >/dev/null || break; sleep 0.25; done
fi
open build/Rondo.app
