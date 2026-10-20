#!/usr/bin/env bash
# Conversion + headless-tool matrix over generated fixtures, validated per output type.
# Usage: scripts/smoke.sh [--min 0.9] [--only image|video|audio|pdf|document|spreadsheet|subtitle|archive|folder]
# Summary table also written to fixtures/out/smoke/summary.md.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -d fixtures/out/src ]] || scripts/make-fixtures.sh
rm -rf fixtures/out/smoke
swift build --product rondo-cli >/dev/null
"$(swift build --show-bin-path)/rondo-cli" smoke fixtures/out/src fixtures/out/smoke "$@"
