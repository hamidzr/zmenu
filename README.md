# zmenu

Native macOS AppKit MVP for the gmenu replacement (zmenu).

## What it does
- Reads menu items from stdin (one per line). If stdin is empty, it exits with a non-zero code.
- Opens a native window with a search field and a list of items.
- Typing filters the list with a tokenized, case-insensitive fuzzy match (results capped at 10). If there are no matches, it falls back to Levenshtein distance suggestions unless disabled.
- Enter prints the selected (default top) item to stdout and exits 0; Esc cancels with a non-zero exit code.
- Up/Down/Tab move the selection within the filtered list.
- Double-clicking a row accepts that item.
- Keys 1-9 accept the corresponding item when numeric selection is active.
- Ctrl+L clears the query.
- A pid file in the temp dir prevents multiple instances per menu id.
- When `menu_id` is set, the last query + selection are stored under `~/.cache/gmenu/<menu_id>/cache.yaml`.

## Requirements
- macOS
- Zig 0.17.0
- Xcode Command Line Tools (for AppKit headers)

## Run
Provide stdin, then launch the app:

```bash
printf "alpha\nbravo\ncharlie\n" | zig build run
```

If you run without stdin, zmenu exits with an error.

### Visual regression
`just visual` captures a snapshot of the UI using `scripts/visual_test.sh`. The first run writes
`samples/visual_baseline.png`; set `UPDATE_SNAPSHOT=1` to refresh the baseline. The script relies
on macOS Accessibility + Screen Recording permissions to capture the window.

### Spawn benchmark
`just bench` (or `scripts/bench_spawn.sh`) measures cold spawn-to-accept latency with hyperfine.
It feeds a single item so `--auto-accept` fires without user interaction. Note this exits before
`app.run()`, so it is a process-init/filter floor, not paint-to-visible.

### Render benchmark
`just render-bench` (or `scripts/render_bench.sh`, `COUNT=2000` by default) measures table
reload + paint cost. It runs `zmenu --render-bench`, which shows the window, types the first
item's label one character at a time (filter + reload + paint per keystroke), accepts the item,
and exits. It prints per-keystroke stats plus spawn-to-window time, and times the whole flow
with hyperfine when available. The table is view-based (`tableView:viewForTableColumn:row:` and
a custom `NSTableRowView`), so `selection_color` draws the row highlight.

### Startup keyboard benchmark
`just startup-bench` (or `scripts/startup_bench.sh`) sends real keyboard events at fixed offsets
from process launch and checks the complete query. An owned test window catches early keys.
Requires existing macOS Accessibility and event-posting permissions.
Use `--binary "$(command -v zmenu)" --ready --accept --profile` to test the installed executable,
or `--mode ipc --ipc-items` to include dynamic item delivery through `zmenuctl`.
`zmenu --startup-profile` logs timestamp-only startup stages to stderr, including the first
accepted text change. See [startup measurements and limits](docs/STARTUP_PERFORMANCE.md).

### Config + CLI
Supported flags: `--menu-id/-m`, `--initial-query/-q`, `--search-method/-s`, `--preserve-order/-o`, `--no-levenshtein-fallback`, `--auto-accept`, `--terminal`, `--follow-stdin`, `--ipc-only`, `--numeric-selection-mode`, `--no-numeric-selection`, `--show-icons`, `--title/-t`, `--prompt/-p`, `--min-width`, `--min-height`, `--max-width`, `--max-height`, `--row-height`, `--field-height`, `--padding`, `--numeric-column-width`, `--icon-column-width`, `--alternate-rows`, `--background-color`, `--list-background-color`, `--field-background-color`, `--text-color`, `--secondary-text-color`, `--selection-color`, `--corner-radius`, `--no-vibrancy`, `--vibrancy=`, `--init-config`, `--render-bench`, `--startup-profile`.
Supported env: `GMENU_MENU_ID`, `GMENU_INITIAL_QUERY`, `GMENU_SEARCH_METHOD`, `GMENU_PRESERVE_ORDER`, `GMENU_LEVENSHTEIN_FALLBACK`, `GMENU_AUTO_ACCEPT`, `GMENU_TERMINAL_MODE`, `GMENU_FOLLOW_STDIN`, `GMENU_IPC_ONLY`, `GMENU_NUMERIC_SELECTION_MODE`, `GMENU_NO_NUMERIC_SELECTION`, `GMENU_SHOW_ICONS`, `GMENU_ACCEPT_CUSTOM_SELECTION`, `GMENU_TITLE`, `GMENU_PROMPT`, `GMENU_MIN_WIDTH`, `GMENU_MIN_HEIGHT`, `GMENU_MAX_WIDTH`, `GMENU_MAX_HEIGHT`, `GMENU_ROW_HEIGHT`, `GMENU_FIELD_HEIGHT`, `GMENU_PADDING`, `GMENU_NUMERIC_COLUMN_WIDTH`, `GMENU_ICON_COLUMN_WIDTH`, `GMENU_ALTERNATE_ROWS`, `GMENU_BACKGROUND_COLOR`, `GMENU_LIST_BACKGROUND_COLOR`, `GMENU_FIELD_BACKGROUND_COLOR`, `GMENU_TEXT_COLOR`, `GMENU_SECONDARY_TEXT_COLOR`, `GMENU_SELECTION_COLOR`, `GMENU_CORNER_RADIUS`, `GMENU_VIBRANCY`.
Rounded corners (14pt) and a translucent `hudWindow` vibrancy material are on by default; disable
with `--no-vibrancy` or set `corner_radius`/`vibrancy` in the config file.
Theme colors accept hex strings like `#RRGGBB` or `#RRGGBBAA` (empty/`none`/`default` keeps system defaults). Size tuning is available via `field_height`, `padding`, and the column width settings.
`--auto-accept` fires immediately in classic mode, waits for stdin EOF in `--follow-stdin`, and stays disabled in `--ipc-only` because that stream never naturally closes.


### IPC + dynamic items
zmenu listens on a local Unix socket for dynamic item updates. Protocol v2 accepts an optional
absolute file or app bundle path in `icon`; `--show-icons` enables its workspace icon column.
Use `zmenuctl` to send `set`, `append`, or `prepend` commands to a running instance:

```bash
printf "alpha\nbravo\n" | zmenuctl --menu-id demo set --stdin
zmenuctl --menu-id demo append "charlie"
```

Protocol details live in `IPC_PROTOCOL.md`.

IPC-only selection mode ignores stdin and prints the full JSON item on accept:

```bash
zmenu --menu-id demo --ipc-only
```

Example stdout:

```json
{"id":"window:123","label":"Safari — Docs","icon":"/Applications/Safari.app"}
```

### Compatibility notes
- Search methods supported: `direct`, `fuzzy`, `fuzzy1`, `fuzzy3`, `default` (`default` matches `fuzzy`). Regex or `exact` modes are not implemented.
- The config filename is `config.yaml` in the standard gmenu config locations; `gmenu.yaml` is not read.
- Default window bounds are `800x450` with max `1920x1080` (override via config/env/flags).
- Default row height is `34`, field height `44`, icon column `46`, numeric column `30`; tune via
  `row_height`, `field_height`, `icon_column_width`, and `numeric_column_width`.
- Default `selection_color` is an accent blue that stays visible under vibrancy; set it to an empty
  string to fall back to the system selection highlight.

### Migration from Go gmenu
- Copy your existing `config.yaml` into the same gmenu config locations; ensure `search_method` is one of the supported values above.
- If you previously used `exact` or `regex`, switch to `direct` or `fuzzy` since zmenu does not implement regex search.
- Numeric selection defaults to `numeric_selection_mode: auto`, which enables 1-9 hints only when filtered results are `<= 9`.
- Set `numeric_selection_mode: on` to always enable numeric shortcuts, or `off` to always disable them.
- `no_numeric_selection` and `GMENU_NO_NUMERIC_SELECTION` are still supported as legacy on/off aliases.
- Terminal mode is intentionally minimal and chooses the first match on Enter.
