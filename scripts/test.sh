#!/usr/bin/env bash
# Swift Testing with a Command-Line-Tools-only toolchain: Testing.framework lives outside
# the default search paths, so plain `swift test` fails with "no such module 'Testing'".
# Usage:
#   scripts/test.sh                 run all tests
#   scripts/test.sh <filter>        run tests matching filter (e.g. RondoKitTests)
#   scripts/test.sh build <Target>  compile one test target only (e.g. MediaEngineTests)
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=()
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* ]]; then
  DEV=/Library/Developer/CommandLineTools/Library/Developer
  F="$DEV/Frameworks"
  L="$DEV/usr/lib"
  FLAGS=(-Xswiftc -F -Xswiftc "$F"
         -Xlinker -F -Xlinker "$F"
         -Xlinker -rpath -Xlinker "$F"
         -Xlinker -rpath -Xlinker "$L")
fi

if [[ "${1:-}" == "build" ]]; then
  [[ -n "${2:-}" ]] || { echo "usage: $0 build <TestTarget>" >&2; exit 2; }
  exec swift build --target "$2" "${FLAGS[@]+"${FLAGS[@]}"}"
fi

if [[ $# -gt 0 ]]; then
  exec swift test --filter "$1" "${FLAGS[@]+"${FLAGS[@]}"}"
fi
exec swift test "${FLAGS[@]+"${FLAGS[@]}"}"
