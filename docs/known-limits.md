# Editing rules and known limits

The complete list. The [README](../README.md#known-limits) has the ones most people meet.

## Editing rules in detail

**Lists.** Tab and ⇧Tab move the item the caret is in, from any of its lines, and every item of
a selection, each with what is nested in it; ⇧Tab on an empty item of the outermost level leaves
the list, as Return does there.

**Code blocks.** Return starts the next line as deep as the line before, and one level deeper
behind a line that leaves a bracket open or, in Python and languages like it, ends with a colon.
Tab and ⇧Tab add and take one level of indentation, for every line of code a selection reaches,
also one that starts on the block's fence or in text above it. Backspace among the blanks a line
starts with takes one level, and a closing bracket typed on an otherwise empty line stands one
level out. A level is what the block already uses (tabs, or the smallest step between two of its
lines, or its smallest indent), four spaces in a block that has none. Lines pasted into a code
block that stands in a list item or a quote are kept in it: each gets the item's indentation or
the quote's marker in front, and is otherwise as pasted.

**Full Width.** View > Full Width lets the text column follow the window instead of keeping to a
width that reads well; it is remembered. Without it, only a table wider than the text column
goes on beside it, in the middle of the page.

## Limits

- **Tables.** A table that fits the page (the window's width less its padding) on single lines
  shows that way, in smaller type where only that makes it fit; one that is wider than the text
  column stands in the middle of the page. A table too wide for the page is as wide as the page
  and the text of its cells wraps. A table inside a list or a quote starts at its indent and
  only goes on to the right. Only where cells wrap is a `<br>` in a cell a line break (it shows
  as the text it is while the caret or an end of the selection touches it, and in a table of
  single lines). A table with more columns than the page has room for at 48 points each (16 in a
  window of the default size) shows as its Markdown source. In a window with a table the word
  count stands in a band at the window's foot instead of floating in the page's margin.
  With Shift, the arrow keys select in the order of the text, which in a row of wrapping cells
  runs through the cells to the left or right on the way. Where a line of a cell wraps, the place
  behind the blank it wraps at is the start of the next line: a click beside the line's end and
  Command-Right put the caret in front of that blank. Where a long table of wrapping cells
  stands below text of quite other line lengths (many short lines, say), the scroller's knob
  still jumps while the window passes from one to the other: the text system guesses the height
  of what is not laid out from what is, as it does in any long document.
  Spelling is not marked in a table whose cells wrap (it is in one on single lines): the text
  system draws the marks of such a cell's lines in the wrong place.
  A table written without the outer pipes, or with a row that has too many cells, shows as its
  Markdown source. Tables are not re-padded when edited. Images inside table cells show as source.
- **Shown as source, never rendered:** raw HTML, footnotes, front matter, math, diagrams and link
  reference definitions. They are kept byte for byte.
- **Lists.** Bullet, number and quote markers are never shown as text: Backspace at the start of an
  item removes the marker, but `-` cannot be changed to `*` in place. Ordered lists are not
  renumbered: an item inserted in the middle gets the next number and the items after it keep
  theirs (Markdown renders them in order all the same). A numbered item that Tab or ⇧Tab moves
  takes the number after the item it then follows, or 1 where it starts a nested list; the items
  around it keep theirs. ⇧Tab does nothing on an item of the outermost level that has text, and
  Tab nothing on an item that has no item before it to go under; with several items selected,
  those that cannot move stay. Tab on an empty item directly below the text of the item before
  shows that text as a heading until the item's first letter is typed: a lone `-` below text is
  Markdown's heading underline. Return, Backspace and ⇧Tab there move the empty item out again.
- **Find** is the system find bar: no highlighting of all matches while typing, no regular
  expressions. It searches the Markdown source, so it also finds text in hidden syntax; a match in
  a link's address or a heading's `#` is revealed, but a match in syntax that is never shown as
  text (list and quote markers, `[x]` of a task, the `|---|` row of a table) only moves the caret
  there.
- **Copy** gives the Markdown source. There is no export and no rich-text or HTML copy.
- **Code** is coloured by a small generic tokenizer (comments, strings, numbers, keywords), not by
  per-language grammars. Indentation goes by the line before: its blanks, a bracket left open,
  a colon at its end in Python, YAML and the like. Nothing else of a language is known (no
  step back after `return`, no pairing of brackets). In a very large document whose parse waits
  for a pause in typing, a closing bracket typed meanwhile is not moved out.
- **Code fences.** Return behind an opening fence adds the closing one, which is hidden until the
  caret is on its line. A closing fence typed by hand above it replaces it at the next Return;
  one that is typed and then left with an arrow key or the mouse leaves the added one behind.
- **Icons** of a terminal prompt (characters of Unicode's private use areas, which only an icon
  font draws) show in a Nerd Font if one is installed: any font family with "Nerd Font" in its
  name, its "Mono" variant in code, where an icon is then as wide as a letter, and its "Propo"
  variant in other text. Without one they show as the system's box with a question mark. Marko
  brings no font of its own. A Nerd Font installed while Marko runs is used at once.
- **Parsing** follows GitHub Flavored Markdown (cmark-gfm) strictly; `---` directly under a line
  of text makes that line a heading. A heading written that way over more than one line cannot be
  converted by the heading commands.
- **Files** must be UTF-8 (with or without a byte order mark); anything else is refused rather
  than rewritten. In large documents (from a few hundred KB) the scroller's knob jumps while
  scrolling, because the heights of text that has not been laid out yet are estimates.
- **The sidebar** does not list names that start with a dot, `node_modules`, or editor backups
  (`name~`, `name~.md`). Folders come first, in the Finder's order.
- **Switching files in the sidebar** closes the file that is left: its undo history ends there.
  So does a file being loaded again after another program changed it.
- **A file written slowly by another program** (emptied first and filled over more than a moment,
  as `command > notes.md` does) may be shown half written, with the caret and the scroll position
  moved to where that shorter text ends; the whole text follows when the program is done.
- **Dropping.** A file dropped on a text inserts a link or image (only an empty untitled window
  opens a Markdown file dropped on it). Nothing can be dropped on the empty page of a folder's
  window. Rows of the file tree are dragged one at a time, and cannot be moved inside the tree
  by dragging. Dragging a row out onto a terminal or the Finder works but is covered by no
  automated test beyond what the drag offers.
- **Accessibility.** VoiceOver reads the raw Markdown, including hidden markers; task checkboxes
  and table rows are text of the one text area, not elements of their own. The rectangle
  accessibility gives for an empty range is one line above the caret, as it is in a stock text
  view of the system (the rectangle input methods ask for is right).
- **Untested by anyone:** VoiceOver itself, a Chinese, Japanese or Korean input method, the
  press-and-hold accent popup, right-to-left text. Dead keys were driven and work.
- **Full screen.** The page and the file tree start at the top of the screen; the window's
  title, the folder's name beside the window buttons and the buttons themselves are not shown.
  The buttons come down with the menu bar when the pointer is at the screen's top.
- **Window tabs.** Window > Merge All Windows and View > Show Tab Bar make tabs of the windows;
  whether new documents open as tabs by themselves is the system's setting (Desktop & Dock,
  "Prefer tabs when opening documents").
- **Safe mode:** see [security.md](security.md#limits).
- **The `marko` tool** has no protocol version: after an update, a Marko that is still running
  is the old one until it is quit, and an option it does not know is ignored.
- **Distribution.** Releases and `build/Marko.app` are signed ad hoc, not with a Developer ID, and
  are not notarized. On a Mac that downloaded the app Gatekeeper refuses it until it is allowed
  in System Settings > Privacy & Security or its quarantine attribute is removed (README,
  "Install").
