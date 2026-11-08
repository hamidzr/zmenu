#!/bin/bash
# Dev-only offscreen renders of the menu into zig-out/snapshots/. Never shows or
# activates a window (see src/app/snapshot.zig), so it does not take focus.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/zig-out/snapshots"
BIN="$ROOT/zig-out/bin/zmenu"
ITEMS="$ROOT/samples/snapshot_items.txt"
IPC="$ROOT/samples/snapshot_ipc.json"
V3="$ROOT/samples/snapshot_v3.json"
V3_LOADING="$ROOT/samples/snapshot_v3_loading.json"

mkdir -p "$OUT"
rm -f "$OUT"/*.png

# default settings regardless of the developer's own gmenu/zmenu config files
HOME="$(mktemp -d)"
export HOME
unset XDG_CONFIG_HOME
trap 'rm -rf "$HOME"' EXIT

# snap NAME APPEARANCE IPC_FILE|- SELECT|- [ZMENU_ARGS...]  (stdin comes from ITEMS unless IPC_FILE)
# plain positional arguments: bash 3.2 on macOS crashes on the array handling this used
snap() {
  local name="$1" appearance="$2" ipc="$3" select="$4"
  shift 4
  [ "$ipc" = "-" ] && ipc=""
  [ "$select" = "-" ] && select=""
  env ZMENU_SNAPSHOT="$OUT/$name.png" ZMENU_SNAPSHOT_APPEARANCE="$appearance" \
    ZMENU_SNAPSHOT_IPC="$ipc" ZMENU_SNAPSHOT_SELECT="$select" \
    "$BIN" --menu-id snapshot "$@" < "$ITEMS"
  echo "$OUT/$name.png"
}

for look in dark light; do
  snap "$look-all" "$look" - -
  snap "$look-query" "$look" - - --initial-query "sa"
  snap "$look-selected" "$look" - 2 --initial-query "s"
  snap "$look-none" "$look" - - --initial-query "zzzzqq"
  snap "$look-loading" "$look" - - --ipc-only
  snap "$look-ipc-icons" "$look" "$IPC" - --show-icons
  snap "$look-ipc-query" "$look" "$IPC" - --show-icons --initial-query "mon"
  # protocol v3: subtitle, detail, calc, prefix, fallback, scope and loading
  snap "$look-v3" "$look" "$V3" - --ipc-only --show-icons
  snap "$look-v3-calc" "$look" "$V3" - --ipc-only --show-icons --initial-query "12*(3+4)"
  snap "$look-v3-prefix" "$look" "$V3" - --ipc-only --show-icons --initial-query "g weather"
  snap "$look-v3-fallback" "$look" "$V3" - --ipc-only --show-icons --initial-query "qqzzx"
  snap "$look-v3-scope" "$look" "$V3" - --ipc-only --show-icons --initial-query "t gmail"
  snap "$look-v3-search" "$look" "$V3" - --ipc-only --show-icons --initial-query "safari"
  snap "$look-v3-loading" "$look" "$V3_LOADING" - --ipc-only --show-icons
done
