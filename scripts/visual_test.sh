#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="$ROOT/samples/visual_input.txt"
OUT_DIR="$ROOT/zig-out/visual"
ACTUAL="$OUT_DIR/actual.png"
BASELINE="$ROOT/samples/visual_baseline.png"

mkdir -p "$OUT_DIR"

if [ ! -f "$INPUT" ]; then
  echo "missing sample input: $INPUT" >&2
  exit 1
fi

zig build

( cat "$INPUT" | zig build run -- --title "zmenu-visual" --initial-query "al" --min-width 600 --min-height 300 ) &
PID=$!

sleep 0.8

# zmenu is a borderless window, so System Events reports no window id; capture by bounds instead.
GEOM=$(osascript -e 'tell application "System Events" to tell process "zmenu" to get {position, size} of window 1' 2>/dev/null | tr -d ' ' || true)
if [ -z "$GEOM" ]; then
  echo "unable to locate zmenu window (grant Accessibility + Screen Recording permissions)" >&2
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  exit 1
fi

screencapture -x -R"$GEOM" "$ACTUAL"

osascript -e 'tell application "System Events" to keystroke (ASCII character 27)' 2>/dev/null || true
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

if [ "${UPDATE_SNAPSHOT:-}" = "1" ] || [ ! -f "$BASELINE" ]; then
  cp "$ACTUAL" "$BASELINE"
  echo "updated baseline: $BASELINE"
  exit 0
fi

if cmp -s "$ACTUAL" "$BASELINE"; then
  echo "visual snapshot matches"
  exit 0
fi

# allow small rendering differences (caret blink, subpixel AA) when ImageMagick is available
if command -v magick >/dev/null 2>&1; then
  RMSE=$(magick compare -metric RMSE "$BASELINE" "$ACTUAL" null: 2>&1 | sed 's/.*(\(.*\))/\1/' || true)
  if [ -n "$RMSE" ] && awk "BEGIN{exit !($RMSE < 0.01)}"; then
    echo "visual snapshot matches (rmse=$RMSE)"
    exit 0
  fi
fi

echo "visual snapshot mismatch: $ACTUAL" >&2
exit 1
