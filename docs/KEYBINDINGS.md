# Keybinding Notes (Developer)

## Cmd+A select-all
AppKit does not always route Cmd+A through `keyDown:` for the search field. In this app it can surface as `noop:` via `control:textView:doCommandBySelector:`. To ensure select-all works, the handler is implemented in `performKeyEquivalent:` on `ZigSearchField`.

## Esc
`cancelOperation:` (from the field editor via `control:textView:doCommandBySelector:`, or on `ZigSearchField` directly) clears the query and re-filters when the field has text. With an empty field it quits with the user-cancel exit code.
