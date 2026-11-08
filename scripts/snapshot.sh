#!/bin/bash
# Dev-only offscreen renders of the menu into zig-out/snapshots/. Never shows or
# activates a window (see src/app/snapshot.zig), so it does not take focus.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/zig-out/snapshots"
BIN="$ROOT/zig-out/bin/zmenu"
ITEMS="$ROOT/samples/snapshot_items.txt"
IPC="$ROOT/samples/snapshot_ipc.json"

mkdir -p "$OUT"
rm -f "$OUT"/*.png

# snap NAME APPEARANCE [ENV=VALUE...] -- ZMENU_ARGS...  (stdin comes from ITEMS unless ipc)
snap() {
  local name="$1" appearance="$2"
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  env ZMENU_SNAPSHOT="$OUT/$name.png" ZMENU_SNAPSHOT_APPEARANCE="$appearance" \
    ${envs[@]+"${envs[@]}"} "$BIN" --menu-id snapshot "$@" < "$ITEMS"
  echo "$OUT/$name.png"
}

for look in dark light; do
  snap "$look-all" "$look" --
  snap "$look-query" "$look" -- --initial-query "sa"
  snap "$look-selected" "$look" ZMENU_SNAPSHOT_SELECT=2 -- --initial-query "s"
  snap "$look-none" "$look" -- --initial-query "zzzzqq"
  snap "$look-loading" "$look" -- --ipc-only
  snap "$look-ipc-icons" "$look" "ZMENU_SNAPSHOT_IPC=$IPC" -- --show-icons
  snap "$look-ipc-query" "$look" "ZMENU_SNAPSHOT_IPC=$IPC" -- --show-icons --initial-query "mon"
done
