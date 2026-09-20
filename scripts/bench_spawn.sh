#!/bin/bash
# Measures zmenu cold spawn-to-accept cost.
#
# zmenu only auto-accepts when exactly one item matches (src/app/logic.zig), so
# this feeds a single item and lets --auto-accept fire without user interaction.
# No --menu-id is passed so per-menu caches cannot seed an initial query.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/zmenu"
RUNS="${RUNS:-10}"

if [ ! -x "$BIN" ]; then
  echo "missing $BIN; run: zig build" >&2
  exit 1
fi

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine is required (brew install hyperfine)" >&2
  exit 1
fi

hyperfine --warmup 2 --runs "$RUNS" --style basic \
  "printf 'bench-item\n' | '$BIN' --auto-accept --title zmenu-bench"
