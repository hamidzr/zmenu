#!/bin/bash
# Compile and run the macOS external-launch keyboard benchmark.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/zig-out/tools/startup-bench"
SOURCE="$ROOT/scripts/startup_bench.swift"

mkdir -p "$(dirname "$TOOL")"
if [ ! -x "$TOOL" ] || [ "$SOURCE" -nt "$TOOL" ]; then
  swiftc -O "$SOURCE" -o "$TOOL" -framework AppKit -framework ApplicationServices
fi

exec "$TOOL" --binary "$ROOT/zig-out/bin/zmenu" "$@"
