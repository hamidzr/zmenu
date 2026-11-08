# Keybinding Notes (Developer)

## Cmd+A select-all
AppKit does not always route Cmd+A through `keyDown:` for the search field. In this app it can surface as `noop:` via `control:textView:doCommandBySelector:`. To ensure select-all works, the handler is implemented in `performKeyEquivalent:` on `ZigSearchField`.

## Esc
`cancelOperation:` (from the field editor via `control:textView:doCommandBySelector:`, or on `ZigSearchField` directly) clears the query and re-filters when the field has text. With an empty field it quits with the user-cancel exit code.

## List navigation
`control:textView:doCommandBySelector:` (the field editor's translated commands) handles:

| Key | Selector | Action |
| --- | --- | --- |
| Up / Down | `moveUp:` / `moveDown:` | previous / next row, wrapping. Ctrl+N / Ctrl+P produce the same selectors from AppKit's default key bindings |
| Tab / Shift+Tab | `insertTab:` / `insertBacktab:` | next / previous row |
| PageUp / PageDown | `pageUp:` `scrollPageUp:` / `pageDown:` `scrollPageDown:` | one visible page of rows, clamped at the ends |
| Cmd+Up / Cmd+Down | `moveToBeginningOfDocument:` / `moveToEndOfDocument:` | first / last row |
| Home / End | `scrollToBeginningOfDocument:` / `scrollToEndOfDocument:` | first / last row, only while the query is empty; otherwise the field edits the caret as usual |

Ctrl+N/P/J/K are also taken in `performKeyEquivalent:` on `ZigSearchField` (exact Ctrl modifier only), so Ctrl+J/Ctrl+K move down/up unconditionally and Ctrl+K never deletes to end of line.

Every selection movement sets `Model.moved`, which makes the selection stick to its item across IPC `set` updates (see `Model.applyFilterKeepSelection`). A query change clears it.
