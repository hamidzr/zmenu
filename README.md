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
- When `menu_id` is set, the last query + selection are stored under `~/.cache/gmenu/<menu_id>/cache.yaml`. Cache dir is created 0700 and cache.yaml / pid files 0600.

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
Environment overrides are listed under [Environment variables](#environment-variables).
Rounded corners (14pt) and a translucent `hudWindow` vibrancy material are on by default; disable
with `--no-vibrancy` or set `corner_radius`/`vibrancy` in the config file.
Theme colors accept hex strings like `#RRGGBB` or `#RRGGBBAA` (empty/`none`/`default` keeps system defaults). Size tuning is available via `field_height`, `padding`, and the column width settings.
`--auto-accept` fires immediately in classic mode, waits for stdin EOF in `--follow-stdin`, and stays disabled in `--ipc-only` because that stream never naturally closes.


### Environment variables
Settings precedence is CLI flags > `GMENU_*` env > config file > defaults. Read in
`src/cli/env.zig`; defaults come from `src/config.zig`. Invalid values abort startup.
Booleans accept `true/false`, `1/0`, `yes/no`, `on/off` (case-insensitive). Colors accept
`#RRGGBB` or `#RRGGBBAA`; empty, `none`, or `default` clears the color to the system default.
Sizes are floating-point points.

| Variable | Meaning | Default |
| --- | --- | --- |
| `GMENU_TITLE` | Window title | `gmenu` |
| `GMENU_PROMPT` | Search field placeholder (terminal mode prompt) | `Search` |
| `GMENU_MENU_ID` | Menu ID (letters, digits, `-`, `_`, `.`; max 64; no leading dot) for cache, PID lock, and IPC socket names. Applied after config load, so only `--menu-id` selects the scoped config file | empty |
| `GMENU_INITIAL_QUERY` | Prefilled query | empty (cached last query when a menu ID is set) |
| `GMENU_TERMINAL_MODE` | Use terminal mode instead of the GUI | `false` |
| `GMENU_FOLLOW_STDIN` | Keep reading stdin and stream new items | `false` |
| `GMENU_IPC_ONLY` | Ignore stdin; take items over IPC and print the JSON item on accept | `false` |
| `GMENU_UNIQUE` | Drop items with duplicate labels (stdin and IPC updates) | `false` |
| `GMENU_MIN_WIDTH` | Initial window width, capped by max width | `800` |
| `GMENU_MIN_HEIGHT` | Initial window height, capped by max height and snapped to whole rows | `450` |
| `GMENU_MAX_WIDTH` | Max window width (`0` disables the cap) | `1920` |
| `GMENU_MAX_HEIGHT` | Max window height (`0` disables the cap) | `1080` |
| `GMENU_ROW_HEIGHT` | Result row height | `34` |
| `GMENU_FIELD_HEIGHT` | Search field height | `44` |
| `GMENU_PADDING` | Window padding | `14` |
| `GMENU_NUMERIC_COLUMN_WIDTH` | Numeric shortcut column width | `30` |
| `GMENU_ICON_COLUMN_WIDTH` | Icon column width | `46` |
| `GMENU_ALTERNATE_ROWS` | Alternating row backgrounds | `false` |
| `GMENU_CORNER_RADIUS` | Window corner radius | `14` |
| `GMENU_VIBRANCY` | Translucent `hudWindow` vibrancy background | `true` |
| `GMENU_BACKGROUND_COLOR` | Window background color | dark (rgba 0.06, 0.07, 0.09, 0.98) |
| `GMENU_LIST_BACKGROUND_COLOR` | Result list background color | dark (rgba 0.06, 0.07, 0.09, 0.98) |
| `GMENU_FIELD_BACKGROUND_COLOR` | Search field background color | rgba 0.12, 0.13, 0.17, 1.0 |
| `GMENU_TEXT_COLOR` | Primary text color | rgba 0.94, 0.95, 0.97, 1.0 |
| `GMENU_SECONDARY_TEXT_COLOR` | Secondary text color | rgba 0.75, 0.77, 0.82, 1.0 |
| `GMENU_SELECTION_COLOR` | Selected row highlight | accent blue (rgba 0.21, 0.38, 0.78, 0.95) |
| `GMENU_SEARCH_METHOD` | `direct`, `fuzzy`, `fuzzy1`, `fuzzy3`, or `default` (= `fuzzy`) | `fuzzy` |
| `GMENU_PRESERVE_ORDER` | Keep input order instead of sorting matches by score | `false` |
| `GMENU_LEVENSHTEIN_FALLBACK` | Add edit-distance matches when fewer than 3 results match | `true` |
| `GMENU_AUTO_ACCEPT` | Accept a single item automatically (see `--auto-accept` notes above) | `false` |
| `GMENU_ACCEPT_CUSTOM_SELECTION` | Enter with no matches prints the typed query (not in `--ipc-only`) | `true` |
| `GMENU_NUMERIC_SELECTION_MODE` | `on`, `off`, or `auto` (shortcuts only when at most 9 items match) | `auto` |
| `GMENU_NO_NUMERIC_SELECTION` | Legacy alias: true sets mode `off`, false sets `on`; `GMENU_NUMERIC_SELECTION_MODE` wins if both are set | unset |
| `GMENU_SHOW_ICONS` | Show the item icon column | `false` |

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
