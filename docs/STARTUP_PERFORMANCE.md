# Startup keyboard profiling

Measured locally on 2026-10-07: arm64 macOS 27.0.1, native AppKit, Debug builds.
Priorities: keyboard shortcuts with piped items and combo-switcher's IPC-only menu.

GUI testing was paused, then temporarily resumed at the user's explicit request
for the shadow-flash investigation below. Reproduction commands change focus and
post keyboard events; run them only during an authorized testing window.

## Installed executable comparison

The same installed path was tested before and after installation. Each group had
10 launches, 2,000 synthetic items, and real `qwerty` keyboard events starting at
100 ms after the external process-launch trigger, approximately 10 ms apart.
IPC rows below test input focus before item delivery. No trial's first key was
over 5 ms late. AX queries were deferred until typing finished in these trials.

| Mode | Foreground handoff median / p95, before | After | Incomplete queries before | After |
| --- | --- | --- | --- | --- |
| Piped stdin | 114.6 / 153.8 ms | 67.3 / 87.6 ms | 10/10, 14 missing characters | 0/10 |
| IPC-only | 114.9 / 128.2 ms | 64.6 / 89.0 ms | 9/10, 13 missing characters | 0/10 |

The old installed binary targeted SDK 26.5; the new build targets SDK 27.0.
A rebuilt source baseline using the same Zig 0.16 and SDK 27.0 as the new build
also showed delayed handoff: 107.7 ms median / 144.8 ms p95 and 7/10 incomplete
100 ms queries (nine missing characters). This supports the activation change;
the installed comparison alone cannot attribute every millisecond to it.

Foreground handoff is an OS ownership observation, not proof that the text editor
has processed a key. The complete query assertion establishes preservation of
the tested input. Fixed-offset AX timestamps are post-typing upper bounds and
must not be used as exact readiness measurements.

The change uses accessory activation and starts activation during view setup.
Accessory apps omit the Dock entry and application menu bar while allowing
programmatic activation ([Apple documentation](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory)).
Auto-accept defers activation so a singleton can exit without requesting focus.

## Trigger to actual text handling

Timestamp-only `--startup-profile` logs use the same `CLOCK_UPTIME_RAW` clock as
the harness. `process_start_ns` aligns the child's entry into `main` with the
external trigger, including loader time. Median stage times below come from
three piped trials and five IPC trials with 2,000 items delivered through the
public `zmenuctl` protocol. First keys were posted at 100 ms; all queries survived.

| Stage from external trigger | Piped stdin | IPC with item delivery |
| --- | --- | --- |
| AppKit initialized | 64.7 ms | 59.0 ms |
| Activation requested | 68.4 ms | 64.6 ms |
| UI constructed | 94.7 ms | 87.0 ms |
| First responder request returned | 122.7 ms | 109.4 ms |
| First actual text-change callback | 156.7 ms | 148.5 ms |
| Active app + key window + editor confirmed | 192.3 ms | 168.4 ms |

Keys can queue for the app before its text-change callback runs. The internal
`input_ready` timer is a conservative confirmation, sometimes later than actual
text handling. `first_text_change` is the actual AppKit text notification, unlike
the existing render benchmark's direct `setStringValue:` calls. First filter work
was about 0.24 ms with piped items; AppKit/activation dominated this fixture.

## Producer and launcher delays

With stdin deliberately withheld for one second, normal mode confirmed input
focus at a median 1,162.5 ms. All three 100 ms typing trials lost all six keys.
`--follow-stdin` preserved all six keys in three matching trials and accepted the
correct item after the delayed list arrived.

At measurement time, the actual Ctrl+Cmd+M shortcut called `gui-execute.sh`, whose producer runs
`fd --type x .` in `~/scripts`. Ten read-only runs found 338 items, with producer
median 8.724 ms and p95 19.854 ms. `_themenu.sh` uses `options=$(cat)` before it
spawns zmenu, so it waits for full producer EOF. Shell startup, variable sourcing,
and wrapper conversion add unmeasured time. `--follow-stdin` inside zmenu cannot
remove buffering that happened before zmenu was spawned.

The non-numbered macOS zmenu path in `~/scripts/dmenu/_themenu.sh` now forwards
stdin directly, allowing the producer and process loader to overlap.
It retains normal stdin EOF semantics. Numbered menus and gmenu/dmenu fallbacks
retain their prior behavior. Scripts commit `787c99b` includes a headless regression
suite in `dmenu/test-themenu.sh`: it reproduces the old EOF gate and verifies early
spawn, exact stdin, prompts, numbering, fallbacks, and cancellation using mock menus
on an isolated PATH. Real shortcut timing and focus behavior after this launcher
change are pending. Existing dotfiles shortcut bindings need no changes.

The actual IPC shortcut calls `cs-cli toggle` and a resident daemon. Before spawn,
the daemon runs stale-menu cleanup with `pgrep` and a conditional 50 ms sleep.
After spawn, it polls for the socket in 40 ms intervals. Cached/loading items
arrive before background providers finish. These CLI/daemon costs are outside
the binary harness. Combo-switcher was inspected read-only; no daemon changes were
made.

## Verification and limits

- Six focused-input + Return trials passed: three piped and three populated IPC
  menus, 2,000 items each, including exact stdout and exit status.
- Five 100 ms IPC trials preserved the query while 2,000 items arrived; three
  additional trials passed with the icon column. Icons were synthetic/null, so
  real provider and workspace-icon loading costs remain unmeasured.
- Default trials exit via Escape. Singleton auto-accept returned the expected
  line without an activation request in the profile.
- Existing render benchmark crashed on a 17-byte label. Sample storage now
  covers all eight rounds, and the query buffer includes its terminator. Labels
  of 17 and 128 bytes passed with 136 and 1,024 samples respectively.
- Zig tests passed, 11 total. Changed-source formatting, Swift compilation with
  warnings as errors, shell syntax, help, and invalid-argument checks passed.
- `bash ~/scripts/dmenu/test-themenu.sh` passed without launching native apps.
  Script syntax, scoped shfmt, shellcheck (excluding existing SC2001), and commit
  hooks also passed in the scripts repository.
- GUI binaries were built and installed through `just install` from an isolated
  Zig 0.16 snapshot while another session migrated the checkout to Zig 0.17.
  Completed migration now builds both binaries with system Zig 0.17, passes all
  11 project tests, and passes the full Zig format check. CLI forwarding,
  singleton auto-accept without activation, and IPC framing also pass.
  Focus-changing GUI and keyboard checks remain paused.
- `COUNT=2000 RUNS=3 scripts/render_bench.sh` passed: 72 samples, 3.842 ms median
  filter/reload/paint, 2.641 ms median paint. This measures rendering and does not
  exercise OS keyboard delivery.

These are repeated local launches, not cache-eviction or real shortcut-to-focus
measurements. Small samples do not establish a no-loss guarantee. One exploratory
instrumented launch took 97 ms just to enter `main` and lost keys started at
100 ms. Earlier input, a slow producer, or scheduling/loader outliers can still
lose keys. Eliminating that interval requires buffering in the shortcut owner or
a resident menu process. This change reduces the interval within zmenu.

## Reproduce

```bash
scripts/startup_bench.sh --binary "$(command -v zmenu)" --runs 10 --delays 100
scripts/startup_bench.sh --binary "$(command -v zmenu)" --ready --accept --profile
scripts/startup_bench.sh --binary "$(command -v zmenu)" --mode ipc --ipc-items --show-icons --profile
scripts/startup_bench.sh --binary "$(command -v zmenu)" --mode follow --stdin-delay-ms 1000 --delays 100 --accept
```

Synthetic raw JSONL measurements are saved under `zig-out/bench/startup/` locally.
The harness requires existing Accessibility and event-posting permissions, uses
an owned window to catch early keys, and aborts if an unrelated app becomes
foreground. `--ready` asserts complete input; `--accept` also asserts selection;
fixed-offset runs report expected early-key loss without failing solely for it.

## Pending after testing resumes

- Measure actual shortcut trigger to text acceptance after the stdin-forwarding
  wrapper change, including producer and shell startup.
- Exercise combo-switcher's actual providers and icons, cached queries, and
  stale-menu cleanup. Keep private window titles and item payloads out of logs.
- Repeat early-key sweeps and cold/loaded launch observations; verify Enter,
  Escape, and cancellation through the actual wrappers.
- Verify GUI and keyboard behavior with the installed Zig 0.17 binaries.

## Input-area popup investigation and fix

Reproduced on macOS 27.0.1 with Zig 0.17 Debug builds after the user authorized
GUI testing. Synthetic direct-stdin and populated IPC menus both showed a small,
blank, shadowed popup underneath the input, after the main menu was already drawn.

Temporary timestamp-only window diagnostics identified a second zmenu-owned
window, approximately 312 x 237 points. Its runtime class was
`NSKVONotifying_SPRoundedWindow`, hosting `NSKVONotifying_NSRemoteView`; the
underlying class came from Apple's `SafariPlatformSupport.framework`. It appeared
roughly 300-385 ms after entry into `main`, before the first scheduled key at one
second. This identifies an OS text-services popup, rather than an incompletely
painted menu shadow. AutoFill/completion is the likely service family; the popup's
contents remained blank, and no account data or provider payloads were inspected.

The query control now subclasses public `NSSearchField` instead of generic
`NSTextField`. Search/cancel button cells are hidden to keep the plain custom
header. Query edits still filter through the existing delegate. Setting
`sendsWholeSearchString` prevents search actions from accepting an item during
typing; Return submits. The field-editor command delegate handles Escape as
zmenu cancellation. Initial query selection uses the existing editor directly.
No private framework calls, sleeps, or delayed keyboard focus remain in the fix.
See Apple's [search-field API](https://developer.apple.com/documentation/appkit/nssearchfield)
and [submission behavior](https://developer.apple.com/documentation/appkit/nssearchfield/sendswholesearchstring).

Changing initial selection alone, disabling automatic text completion, and
setting an empty content type did not reliably suppress the popup. Native search
fields produced no auxiliary popup in three direct and three populated IPC
prototype recordings. Two final recordings, one per input mode, also showed no
popup and passed Escape cancellation. Earlier text-field controls sometimes had
clean runs too; this is an intermittent effect, so small samples cannot prove a
universal OS guarantee. Temporary class/window diagnostics were removed.

Final keyboard checks passed:

- Three prefilled direct menus and three prefilled populated IPC menus replaced
  synthetic `stale` with `qwerty` and returned the exact expected selection on
  Return, exit status 0.
- Arrow Down in direct mode and Tab in populated IPC mode selected the next
  result; Return produced the exact expected second item in both checks.
- Five direct typing trials beginning at 100 ms preserved every character before
  and after the change. Escape returned status 2 in every final timing trial.
- Earlier 75 ms typing still lost input: three of five baseline trials and one of
  five final trials were incomplete. Two final trials' first keys were over 5 ms
  late, so these groups must not be used to claim an improved loss rate.

| 100 ms typing fixture, five warm launches each | Text field baseline | Final search field |
| --- | --- | --- |
| Foreground handoff median | 73.9 ms | 74.0 ms |
| First actual text-change callback median | 166.8 ms | 176.0 ms |
| Complete queries | 5/5 | 5/5 |

These are small local samples with observed scheduler variability, not a no-loss
or exact-readiness guarantee. One first launch of an intermediate build lost four
characters at 100 ms; loader and scheduling outliers remain possible. Captured
video runs have recorder overhead and are excluded from the timing comparison.
Native screen recordings advertise 120 fps but emit variable-frame-rate updates;
this does not establish uninterrupted 8.3 ms sampling.

The benchmark now supports `--prefill` for query-replacement checks and asserts
Escape status 2 on non-accept trials. `--record-dir` records three-second menu-region
videos over an owned gray backdrop, with no audio or permission prompts. Recording
uses default numeric selection and requires existing Screen Recording permission.
Use a fresh output directory; existing recording files are not overwritten.

```bash
scripts/startup_bench.sh --count 8 --runs 3 --delays 1000 --record-dir zig-out/visual/shadow/repro-direct
scripts/startup_bench.sh --mode ipc --ipc-items --show-icons --count 8 --runs 3 --delays 1000 --record-dir zig-out/visual/shadow/repro-ipc
scripts/startup_bench.sh --prefill --ready --accept --runs 3 --profile
```

Raw synthetic recordings, contact sheets, diagnostics, and timing JSONL remain
under `zig-out/visual/shadow/` locally. `confirmed-popup.png` shows the reproduced
text-field popup; `validated-direct-contact.png` and `validated-ipc-contact.png`
show the final opening sequences. The usual single-frame visual snapshot test was
not used to diagnose a transient opening effect, and its baseline was not changed.

`zig build`, `just check` (full Zig formatting and 11 project tests), Swift
compilation with warnings as errors, and `git diff --check` passed. `just install`
refreshed the local binaries; installed zmenu matches the validated build and its
help entrypoint passed. GUI test processes have finished.
