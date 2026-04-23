# tasks

## todo
- [x] read `tasks/fix-auto-accept-streaming.md`
- [x] add stream-final state tracking for follow-stdin and ipc-only
- [x] move auto-accept out of generic filter path, gate on final results, debounce stream-close path
- [x] document streaming and ipc-only auto-accept behavior
- [x] run fmt/build/tests, then capture review notes
- [x] read Zig 0.16 build break and upstream `zig-objc` state
- [x] update build config and dependency for current Zig
- [x] run fmt/check/build with current Zig, fix fallout
- [x] stage changes, commit once build is green

## review
- added stream lifecycle state to `AppState`, plus pending debounce state for EOF-triggered auto-accept
- `followStdinThread` now queues a `stream_closed` signal on EOF, main-thread update timer applies it after final item updates
- auto-accept removed from generic `applyFilter`, now runs only from startup, user query changes, and stream-close retry path
- documented `--auto-accept` behavior for classic mode, `--follow-stdin`, and `--ipc-only`
- updated `build.zig`, `build.zig.zon`, and `zig-objc` dependency for Zig `0.16.0`
- added `io_compat` and `time_compat` shims, plus targeted stdlib migrations for fs, io, net, mutex, and process args APIs
- verified with local Zig `0.16.0` using `just fmt`, `zig build`, `just check`, and `git diff --check`
- upstream `zig-objc` `main` at `c8de82ff80281215ad92900866dab7103a8efa8b` has Zig 0.16 build updates and Apple SDK handling
