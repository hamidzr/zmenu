# Repository Guidelines

## Project Overview & Requirements

- zmenu is a native macOS AppKit menu selector replacing Go gmenu. It reads items from stdin or IPC and prints the accepted selection to stdout.
- Requires macOS, Zig 0.17.0, and Xcode Command Line Tools for Apple SDK headers.
- Objective-C bindings come from the pinned `loftafi/zig-objc` fork revision in `build.zig.zon` (Zig 0.17 support pending upstream `mitchellh/zig-objc#36`); AppKit and Foundation are system frameworks. Fetched packages live in gitignored `zig-pkg/`.
- Primary consumer is combo-switcher, which drives zmenu over IPC (`--ipc-only`) and maps selections by item `id`.

## Project Structure & Module Organization

- `src/main.zig` parses configuration and dispatches to GUI or terminal mode; `src/zmenuctl.zig` is the IPC client entry point.
- `src/app.zig` orchestrates AppKit setup. `src/app/` separates state, Objective-C classes/callbacks, views, filtering/selection logic, helpers, and streamed updates.
- `src/terminal.zig` provides minimal interactive terminal mode, accepting the first case-insensitive substring match on Enter.
- `src/cli.zig` and `src/cli/` handle arguments, environment variables, config files, and path resolution; `src/config.zig` defines settings and defaults.
- `src/menu.zig` owns menu items and the model; `src/search.zig` and `src/search/` implement matching and scoring.
- `src/ipc.zig` defines IPC messages and socket paths; `src/app/updates.zig` queues stdin/IPC updates for the GUI thread using `std.Io.Mutex`.
- `src/cache.zig` persists query/selection state; `src/pid.zig` enforces a single instance per menu ID.
- `src/exit_codes.zig`: 0 accept, 1 error (including empty stdin), 2 user cancel (Esc, focus loss). Older docs saying Esc exits 1 are stale.
- `src/io_compat.zig` and `src/time_compat.zig` centralize I/O and clock helpers.
- `build.zig` and `build.zig.zon` define the Zig build configuration and dependencies.
- `justfile` provides shorthand commands for common workflows.
- Build artifacts land in `zig-out/` with cache data in `.zig-cache/`.
- `README.md` documents runtime behavior and CLI options; `IPC_PROTOCOL.md` defines framing and item schema; `docs/KEYBINDINGS.md` lists key handling.
- `TODO.md` is the live gmenu-parity backlog. `PLAN.md`, `GMENU_V1_PLAN.md`, and `docs/ZMENU_IPC_ONLY_REQUIREMENTS.md` are historical planning/parity inventories; verify against code before trusting them. `tasks/lessons.md` holds project lessons.

## Build, Test, and Development Commands

- `zig build` / `just build`: build both `zmenu` and `zmenuctl` into `zig-out/bin/`.
- `zig build run` / `just run`: build and launch the GUI; supply newline-separated stdin unless using `--ipc-only`.
- `just dev`: launch with sample stdin items.
- `zig build test` / `just test`: run search and streamed-update tests.
- `just fmt`: format `src/` with Zig; `just check`: `zig fmt --check src/` plus `zig build test` (tests are intentionally part of `check` here; both are fast and headless).
- `just install`: build and copy both binaries to `~/.local/bin/`. Run after rebuilding to refresh installed copies.
- `just visual`: capture/compare a UI snapshot; `UPDATE_SNAPSHOT=1` refreshes the baseline.
- `just bench`, `just render-bench`, and `just startup-bench`: process, rendering, and external-launch keyboard benchmarks respectively.
- `just clean`: remove `zig-out/`, `.zig-cache/`, and `bin/`.

## Coding Style & Naming Conventions

- Use Zig standard formatting (`zig fmt src/`) and 4-space indentation; format build files when changing them.
- Prefer `camelCase` for locals and functions, `PascalCase` for types, and `SCREAMING_SNAKE_CASE` for constants.
- Keep functions small and focused; avoid large monolithic `main` blocks as features expand.
- Preserve allocator ownership across menu items and update queues. Main/GUI lifetimes use arenas; AppKit interop uses an autorelease pool and explicit retention where needed.

## Testing Guidelines

- Use Zig `test` blocks. `build.zig` only has two test roots: `src/search.zig` (pulls in `src/search/`) and `src/updates_test.zig`, which also pulls in `src/cli/config_file.zig` tests via `test { _ = @import(...); }`. Tests in other files do not run unless imported from a root; add the import there (or a new root in `build.zig`).
- Test roots cannot import AppKit/objc code; keep testable logic in plain Zig modules.
- Prefer small, focused tests around text input handling and event flow.
- Visual tests use `scripts/visual_test.sh`, sample input, and `samples/visual_baseline.png`; they require macOS Accessibility and Screen Recording permissions.
- Focus-changing GUI and keyboard-injection tests remain paused at the user's request. Resume only when explicitly requested; see `docs/STARTUP_PERFORMANCE.md`. Compilation, static checks, and headless tests may continue.

## Commit & Pull Request Guidelines

- Commit history uses short lowercase summaries, recently often with conventional prefixes (`fix:`, `docs:`, `ui:`); describe behavior changes plainly.
- PRs should include a brief summary, how to run/verify (`zig build run`), and any screenshots or recordings if the UI changes.

## Configuration & Runtime Tips

- Settings precedence is CLI flags > `GMENU_*` environment variables > config file > defaults.
- Config filename is `config.yaml`. Lookup prefers menu-scoped files, then base files under `~/.config/gmenu/`, `~/.gmenu/`, and the platform/XDG config directory; see `src/cli/paths.zig` for exact order.
- CLI `--menu-id` selects the config namespace before environment overrides are applied. `--init-config` writes defaults and exits.
- Config parsing (`src/cli/config_file.zig`) is a hand-rolled flat key/value YAML subset, not a full YAML library; quoted values keep `#`, unquoted `#` starts a comment. snake_case/camelCase aliases live in `config_key_variants`.
- Adding a setting touches `src/config.zig` (default), `src/cli/args.zig`, `src/cli/env.zig` (`GMENU_*`), and `src/cli/config_file.zig`; keep aliases and precedence intact, update README.
- GUI search methods are `direct`, `fuzzy`, `fuzzy1`, `fuzzy3`, and `default` (`fuzzy`). Regex and `exact` modes are unsupported.
- Numeric selection defaults to `auto`, enabling shortcuts for at most nine filtered items; a query ending in a digit disables shortcuts. Preserve legacy `no_numeric_selection` aliases.
- Classic stdin input is limited to 16 MiB; followed stdin skips lines exceeding 64 KiB. `--auto-accept` accepts a singleton immediately in classic mode, waits for EOF in `--follow-stdin`, and stays disabled in `--ipc-only`.
- IPC v2 uses `<length>\n<json-payload>` frames, with a 1 MiB payload limit and `set`/`append`/`prepend` commands. Sockets are `zmenu.<menu_id>.sock` (or `zmenu.sock`) under `TMPDIR`, falling back to `TMP`, `TEMP`, then `/tmp`.
- IPC sockets start only in `--follow-stdin` or `--ipc-only` mode. IPC-only acceptance prints the stored JSON item; typed IPC parsing currently discards unknown item fields despite the preservation claim in `IPC_PROTOCOL.md`.
- Icons use optional absolute file/app bundle paths and require `--show-icons`; stdin labels are plain text.
- Query/selection caches live under `XDG_CACHE_HOME/gmenu/` or, on macOS, `~/Library/Caches/gmenu/`, scoped by menu ID.
- Use a Terminal to run `zig build run` if you need to see stdout output.
