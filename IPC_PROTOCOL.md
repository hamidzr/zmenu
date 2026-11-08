# zmenu IPC protocol (v3)

zmenu listens on a local Unix domain socket and accepts framed JSON messages.
The API is intended for updating the in-memory item list while the GUI is
running. Unknown fields are ignored for forward compatibility.

Version check: `zmenu --version` prints two lines, `zmenu` and `ipc-protocol 3`. The number is the highest protocol version this build implements (`ipc.protocol_version`); older messages (v2) are still accepted.

## Socket path

The socket lives in the OS temp directory:

- `$TMPDIR/zmenu.<menu_id>.sock` when `--menu-id` (or config `menu_id`) is set
- `$TMPDIR/zmenu.sock` when no menu id is provided

`$TMPDIR` falls back to `$TMP`, `$TEMP` (empty values are skipped), then the per-user Darwin temp dir (`confstr(_CS_DARWIN_USER_TEMP_DIR)`), then `$XDG_RUNTIME_DIR`, then a 0700 `/tmp/zmenu-<uid>`. Never the shared `/tmp`. combo-switcher (`pkg/usertmp`) computes the same directory; change both together.

## Framing

Each message is sent as:

```
<length>\n<json-payload>
```

Where `<length>` is the decimal byte count of the JSON payload.

## JSON schema

```json
{
  "v": 3,
  "cmd": "set" | "append" | "prepend",
  "loading": true,
  "scopes": [ { "prefix": "t", "kind": "tab", "label": "Tabs" } ],
  "items": [
    { "id": "item-id", "label": "Item label", "icon": "/Applications/App.app" }
  ]
}
```

Version 3 is a superset of version 2. zmenu accepts both; every v3 field is optional, so a v2 client keeps working unchanged. Clients send `"v": 3` when they use the new fields.

### Message fields

- `v` is the protocol version (currently `3`).
- `cmd` determines how items are applied.
- `items` is required for `set`, `append`, and `prepend`, unless the message carries `loading` or `scopes`. An items-less message with neither is ignored.
- `loading`: `true` means the client will send more updates. zmenu shows a small spinner left of the counter, and an empty list reads "Loading..." instead of "No results". Absent means `false`: every message sets the flag, so the next message without `loading: true` hides the spinner. The initial "Loading..." overlay before the first update is separate and always shown.
- `scopes`: list of search scopes (below). When present it replaces the previous list; when absent the previous list stays.

### Item fields

- `id` is a stable identifier string (recommended for IPC-only mode). It keeps the selection on the same item across updates.
- `label` is required.
- `icon` is optional. An absolute file or app bundle path displays the macOS workspace icon for that path; image files (`.png`, `.ico`, `.svg`, `.jpg`, `.gif`, `.webp`, `.icns`, ...) display their own contents. An absent, empty, relative, or missing path displays a blank icon cell.
- `subtitle`: dim text drawn after the label on the same row, separated by two spaces. It is tail-truncated before the label is. It is searched as if appended to the label and highlighted.
- `detail`: short right-aligned dim text (for example "Space 3", "5m", "Tab"). At most about 30% of the row width, tail-truncated. Not searched.
- `keywords`: searched, never shown.
- `kind`: item category used by scopes (for example `window`, `tab`, `app`, `tmux`, `t3`, `file`, `setting`, `action`, `uri`, `clipboard`, `ext`, `status`, `search`, `calc`).
- `prefix`, `fallback`, `calc`: template items (below).
- `action`: label of the plain-Enter action (default "Open"). `actions`: list of `{ "mods": "cmd", "label": "...", "confirm": "..." }` alternates; `mods` is the canonical `+`-joined subset in the order ctrl, alt, shift, cmd (any order and case is accepted on input). `confirm` (on the item or an action): a string prompt or `true` for the default prompt "Press Enter again to confirm". See "Actions" below.
- Extra fields on item objects are preserved for IPC-only output.

Matching: label, subtitle and keywords are searched. A label hit scores higher than a subtitle hit, which scores higher than a keywords hit, so "safari" ranks the Safari app above a tab whose subtitle mentions safari. Highlights cover the label and the subtitle only.

### Template items

Template items never take part in fuzzy matching and are not counted in the "n / total" counter. Their rows are normal rows for selection, the number shortcuts and keyboard navigation.

- `"prefix": "g "`: hidden unless the query starts with the prefix (ASCII case-insensitive). Then it is pinned above the regular matches, with `{q}` in the label and subtitle replaced by the query after the prefix, leading spaces trimmed.
- `"fallback": true`: shown only when the query is non-empty, no regular item matches and no calc row is shown. `{q}` is the full query. Fallbacks keep the supplied order.
- `"calc": true`: shown pinned at the very top when the whole query is an arithmetic expression with at least one binary operator (or parentheses around an operation) that evaluates to a finite number. `{q}` is the query and `{result}` the formatted result.
  - Grammar: numbers (digits, optional `.`, optional `_` digit separators), `+ - * / %` (modulo), `^` (power, right-associative, so `-2^2` is `-4`), unary minus and plus, parentheses, whitespace. Queries over 256 bytes are not evaluated.
  - Division by zero, NaN and infinity: not shown.
  - Result format: up to 12 significant digits, no trailing zeros, plain notation for `1e-6 <= |x| < 1e15`, otherwise exponent form such as `1.5e20`.

Row order: calc rows, active prefix rows, regular matches, then fallbacks when there is no regular match and no calc row (a shown calc result is the answer, so fallbacks hide). "No results" shows only when there are no rows at all.

### Scopes

`{ "prefix": "t", "kind": "tab", "label": "Tabs" }`. When the query starts with the scope prefix followed by one space (prefix compared ASCII case-insensitive), only regular items with `kind == scope.kind` are candidates and the search text is the remainder. The counter reads "Tabs · n / total", where total counts the scope's items. `label` falls back to `kind`. The first matching scope wins, and scopes take precedence over prefix template items with the same leading token. While a scope is active, template items are hidden.

## Behavior

- `set`: replaces all items.
- `append`: adds items to the end.
- `prepend`: adds items to the beginning.

zmenu re-filters the list after each update using the current query text.

## IPC-only selection mode

When `--ipc-only` (or config `ipc_only: true`) is set, zmenu ignores stdin and
starts with an empty list. On accept, it prints the full JSON item to stdout on a
single line, preserving any extra item fields. `--auto-accept` does not fire in
this mode because the item stream has no EOF. Cancels exit non-zero without
stdout output.

The stored item object gets these fields added (a same-named key already in the item is replaced, so the injected value wins and no key repeats; values are JSON-escaped):

- `query`: the full raw query text, always.
- `arg`: template rows only. The prefix remainder for a prefix item, the full query for a fallback, the expression for a calc item.
- `result`: calc rows only. The formatted result.
- `mods`: the canonical modifier string, only when the accept used modifiers (`Cmd+Enter` gives `"cmd"`). Absent for plain Enter.

The item is re-serialized from parsed JSON, so key order is kept but whitespace is normalized and numbers are printed in `std.json` form (for example `1.0` becomes `1e0`). Send identifiers and other exact values as strings.

## Actions

Shown when any listed row has `action` or `actions`.

- Footer bar: `Enter <action or Open>`, up to two alternates as `Cmd+Enter <label>` (the selected row's), then `Cmd+K Actions`.
- Modifier+Enter (Cmd, Alt, Shift, Ctrl and combinations) accepts the selected item with those `mods` only if it declares an action with exactly those mods. Otherwise the system beeps and nothing happens. Plain Enter is unchanged.
- Cmd+K opens an action panel for the selected item: the primary action plus one row per action, placeholder "Actions for <label>", number shortcuts, filtering. Enter accepts the original item with the chosen row's mods. Esc or Cmd+K closes it and restores query, scroll and selection. IPC updates keep applying to the underlying list and show once the panel closes. The panel keeps its own copy of the item.
- Confirm: `item.confirm` guards plain Enter, `action.confirm` guards that action. The first accept shows the prompt in the row's detail in a warning color. A second accept of the same row with the same mods within 4 seconds goes through. A query change, selection change, item removal or the timeout clears it (one-shot timer).

## Size limits

Messages larger than 1MB are ignored.

## Examples

Using `zmenuctl`:

```bash
printf "alpha\nbravo\n" | zmenuctl --menu-id demo set --stdin
zmenuctl --menu-id demo append "charlie"
zmenuctl --menu-id demo set # clear all items
zmenuctl --menu-id demo --json < message.json # send a raw protocol message
```

Or raw protocol:

```text
46
{"v":2,"cmd":"append","items":[{"id":"hi","label":"hi"}]}
```

A v3 message with a scope, a loading flag and rich rows:

```json
{"v":3,"cmd":"set","loading":true,"scopes":[{"prefix":"t","kind":"tab","label":"Tabs"}],"items":[{"id":"tab:1","label":"Inbox - Gmail","subtitle":"mail.google.com","detail":"Tab","kind":"tab"},{"id":"g","label":"Search Google for {q}","prefix":"g "}]}
```
