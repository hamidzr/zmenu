#!/bin/bash
# Measures zmenu table reload + layout + paint cost for a large item list.
#
# Runs the app in --render-bench mode: once the window is shown it repeatedly
# forces reloadData + layoutSubtreeIfNeeded + displayIfNeeded and prints timing
# stats to stderr, then exits. Compare the median across table architectures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/zmenu"
COUNT="${COUNT:-2000}"

if [ ! -x "$BIN" ]; then
  echo "missing $BIN; run: zig build" >&2
  exit 1
fi

awk -v n="$COUNT" 'BEGIN { for (i = 0; i < n; i++) printf "item-%04d\n", i }' \
  | "$BIN" --render-bench --limit 0 --title zmenu-render-bench
