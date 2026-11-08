# Keybinding Notes (Developer)

## Cmd+A select-all
AppKit does not always route Cmd+A through `keyDown:` for the search field. In this app it can surface as `noop:` via `control:textView:doCommandBySelector:`. To ensure select-all works, the handler is implemented in `performKeyEquivalent:` on `ZigSearchField`.

## Ctrl+L
Clears the query. Handled in `performKeyEquivalent:` on `ZigSearchField` (exact Ctrl modifier): while the field editor is first responder, `keyDown:` on the field is never called.

## Mouse
A single click accepts the clicked row (`onRowClick:`, the table's action). The table refuses first responder so the field editor stays active after a click. Clicks past the last row are ignored.

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

## Cmd+digit shortcuts
Cmd+1 to Cmd+9 accept the matching row (handled in `performKeyEquivalent:` on `ZigSearchField`), unless `numeric_selection_mode` is `off`. Command chords never collide with typing, so in the GUI `auto` behaves like `on`; the nine-result and trailing-digit rules apply only to terminal mode, where plain digits select. The index column shows `Cmd+N` for the first nine rows and is hidden when the mode is `off`.

## Modifier+Enter, Cmd+K and Esc with actions
Modified Return reaches the app by three routes, all funnelled into one accept:
- `performKeyEquivalent:` on `ZigSearchField` for Cmd (and usually Ctrl) chords with key code 36 (Return) or 76 (keypad Enter).
- `control:textView:doCommandBySelector:` for the field editor's translations: `insertNewline:`, `insertNewlineIgnoringFieldEditor:`, `insertLineBreak:`, `insertParagraphSeparator:`, `insertLineSeparator:`, `insertContainerBreak:`. The modifiers come from `NSApp.currentEvent` masked to shift/ctrl/option/command.
- the field's `onSubmit:` action, as a fallback for plain Enter.

The accept only goes through when the selected item declares an action with exactly those mods; otherwise `NSBeep`. Cmd+K (`performKeyEquivalent:`) toggles the action panel. Esc closes the panel first, then clears a pending confirm, then clears the query, then quits.
