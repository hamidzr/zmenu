#!/bin/bash
# Measures zmenu table reload + paint cost, plus a cold end-to-end flow.
#
# In-process: runs --render-bench, which shows the window, types the first
# item's label one character at a time (filter + reload + paint per keystroke),
# then accepts the item and exits. It prints per-keystroke stats and total wall
# time since process start.
#
# Cold: if hyperfine is available, times the whole spawn -> show -> type ->
# accept -> exit flow.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/zmenu"
COUNT="${COUNT:-2000}"
RUNS="${RUNS:-10}"

if [ ! -x "$BIN" ]; then
  echo "missing $BIN; run: zig build" >&2
  exit 1
fi

ITEMS_FILE="$(mktemp -t zmenu-bench-items)"
trap 'rm -f "$ITEMS_FILE"' EXIT
awk -v n="$COUNT" 'BEGIN { for (i = 0; i < n; i++) printf "item-%04d\n", i }' > "$ITEMS_FILE"

echo "== in-process render bench (COUNT=$COUNT) =="
"$BIN" --render-bench --limit 0 --title zmenu-render-bench < "$ITEMS_FILE"

if command -v hyperfine >/dev/null 2>&1; then
  echo "== cold spawn -> type -> accept -> exit (wall clock) =="
  hyperfine --warmup 2 --runs "$RUNS" --style basic \
    "cat '$ITEMS_FILE' | '$BIN' --render-bench --limit 0 --title zmenu-render-bench"
else
  echo "(hyperfine not found; skipping cold wall-clock run)"
fi
