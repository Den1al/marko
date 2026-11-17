# Marko

A native macOS Markdown editor that **renders as you type**. The file on disk stays *exactly*
the Markdown you wrote, with ~~no hidden rewriting~~ and `no web view`.

## What you get

- Editing in place: the syntax appears only around the thing you are editing
- Tables, code, images and [links](https://github.com/Den1al/marko) shown where they are
  1. Nested lists
  2. Ordered or not
- [x] Files kept byte for byte
- [x] Safe mode: nothing is fetched until you trust a folder
- [ ] Telemetry and update checks (never)

> One native text view on TextKit 2. Undo, find and spelling are the system's.

| Shortcut | Does              | Also       |
|----------|-------------------|------------|
| ⌘B       | Show the sidebar  | file tree  |
| ⇧⌘B, ⌘I  | Bold, italic      | ⌘K: link   |
| ⌥⌘T      | Insert a table    | Tab: next cell |

```sh
export EDITOR="marko --wait"     # use it from the terminal
marko notes.md:12                # open a file on line 12
```

---

Light and dark, zoom, window tabs, full screen.
