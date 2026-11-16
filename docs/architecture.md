# Architecture

How Marko works today. No history and no measurements here: the reason behind a single line
of code is usually a `MEASURED:` comment beside it.
A change that makes a statement here untrue updates this file in the same commit.

Contents: [The idea](#the-idea) · [Targets](#targets) · [The model](#the-model) ·
[A keystroke, end to end](#a-keystroke-end-to-end) · [Refreshing what is shown](#refreshing-what-is-shown) ·
[Invariants](#invariants) · [Tables](#tables) · [Windows and documents](#windows-and-documents) ·
[The marko tool and the socket](#the-marko-tool-and-the-socket) · [Safe mode and trust](#safe-mode-and-trust) ·
[Platform behaviour relied on](#platform-behaviour-relied-on) · [Run modes and MARKO_ variables](#run-modes-and-marko_-variables) ·
[Tests](#tests) · [Where things live](#where-things-live)

## The idea

One `NSTextView` on TextKit 2. Its `NSTextStorage` holds the file's text exactly, with nothing
added. What you see is produced only when TextKit asks for a paragraph to lay out:

- `NSTextContentStorageDelegate` (`ParagraphRenderer`) returns a *display paragraph* for each
  source line: a copy of the line, of the same UTF-16 length, with fonts, colours, a paragraph
  style and a few custom attributes. Syntax is hidden by giving it a near-zero clear font, or by
  putting another character of the same length in its place.
- One `NSTextLayoutFragment` subclass (`BlockFragment`) draws the decoration around the text the
  system lays out: code panels, quote bars, table grids, bullets, rules, pictures.

There is no second document model, no serializer and no operation log. Saving writes the
storage's string. Undo, find, spelling, input methods and selection are the text view's own,
working on the Markdown source.

```
 key ─► EditorTextView ─► EditorController ──(pure rule in MarkoCore)──► TextEdit
                               │                                            │
                               ▼                                            ▼
                        NSTextStorage  ◄──────── replaceCharacters ─────────┘
                        (the file's text)
                               │ didProcessEditing
                               ▼
          MarkdownStyler.restyle (a part) or .style (the whole)
                               │
                               ▼
                 StyleMap: one LineStyle per source line        ── model, MarkoCore
                               │
     TextKit asks ─► ParagraphRenderer ─► display paragraph     ── same length as the line
                               │
                               ▼
                 BlockFragment draws decoration + text          ── paints only
```

## Targets

Defined in [Package.swift](../Package.swift) (SwiftPM only; there is no Xcode project).

| Target | Depends on | What it is |
|---|---|---|
| `MarkoCore` | Foundation, swift-markdown | Parsing into the per-line `StyleMap`, and the editing rules as pure functions. No AppKit. |
| `MarkoEditor` | AppKit, `MarkoCore` | The text view, renderer, fragment, theme, sidebar, images, trust store. |
| `MarkoCommand` | Foundation only | What the tool and the app agree on: argument parsing, the request, the socket. Kept small so the tool starts fast. |
| `MarkoCLI` (executable) | `MarkoCommand` | The `marko` tool; shipped as `Marko.app/Contents/Helpers/marko`. |
| `MarkoApp` (executable) | `MarkoEditor`, `MarkoCommand` | Documents, windows, menus, the command server, smoke and measuring modes. |
| `FixtureSupport` | | Owns `Tests/Fixtures` as a copied resource for the test targets. |

`MarkoEditor`, `MarkoApp` and `MarkoEditorTests` are built with default `MainActor` isolation;
the others are not. `NSTextLayoutFragment` and `NSTextLayoutManager` subclasses are
`nonisolated final class`. The only dependency is swift-markdown, pinned `exact: "0.9.0"`.

[scripts/build-app.sh](../scripts/build-app.sh) assembles `build/Marko.app` from the two
executables, [Support/Info.plist](../Support/Info.plist), the icon, `install-cli.sh` and
`THIRD-PARTY-NOTICES.txt`, and signs it ad hoc.

## The model

[Sources/MarkoCore/StyleMap.swift](../Sources/MarkoCore/StyleMap.swift). All offsets are UTF-16
offsets into the whole text.

- `StyleMap`: `lines: [LineStyle]`, `tables: [TableStyle]` and `hasReferences`.
- `LineStyle`: `range` (the line with its terminator); `kind` (`paragraph`, `heading(level)`,
  `headingUnderline(level)`, `codeFence(language, isClosing)`, `codeBody(language)`,
  `tableRow(isHeader)`, `tableDelimiter(alignments)`, `rule`, `blank`, `source`); `containers`
  (enclosing `.quote` and `.listItem(markerLength)`, outermost first: lists and quotes are not
  kinds); `prefixRange`, `listMarkers` (with checkbox), `headingMarkers`, `fenceMarker`, `cells`,
  `pipes`, `tokens` (`InlineToken`: kind, whole range, marker ranges, content range,
  destination), `codeTokens` and `mayDefineReference` (feeds `StyleMap.hasReferences`).
- `source` lines show as written: HTML blocks, front matter, link reference definitions.
- `TableStyle`: the table's line range and column alignments. `StyleMap.isRegular(_:)` says
  whether it can show as a grid.
- `LineDiff`: `old`, `new`, `changed` line ranges between two maps.

[MarkdownStyler](../Sources/MarkoCore/MarkdownStyler.swift) builds the map from swift-markdown's
document. Every range the parser reports is checked against the source characters, and a line
whose ranges do not check out is emitted plain. `MarkdownStyler.style` is pure and is also called
off the main thread ([Preparse](../Sources/MarkoEditor/Preparse.swift), at launch).

[Restyle.swift](../Sources/MarkoCore/Restyle.swift) brings a map up to date after an edit by
parsing only a part: one table body row (`restyleRow`), one single-line list item (`restyleItem`),
or the top-level blocks between two "border" lines around the edit. It returns the `LineDiff`, or
nil when only a whole parse will do (reference definitions, front matter, a part over the limit,
and the other cases its header comment lists).

## A keystroke, end to end

All in [EditorController](../Sources/MarkoEditor/EditorController.swift) unless said otherwise.

1. **Before the edit.** A typed character goes through `EditorTextView.insertText` to
   `typingHandler` (`editTyping`), a command key through `textView(_:doCommandBy:)`. Either may
   replace the stock edit with a `TextEdit` computed by a pure rule in `MarkoCore`
   (`InputRules`, `FormatCommands`, `TableEdits`) and run it through `perform(_:)`, the one
   helper for every edit that is not plain typing. `textView(_:shouldChangeTextIn:replacementString:)`
   records `asked` (range, replacement, text length, how the table the edit starts in shows)
   while map and text still agree.
2. **The storage changes.** `textStorage(_:didProcessEditing:...)` runs only when the mask has
   `.editedCharacters`. It shifts the reveal selection and the renderer's `rendered`/`behind`
   sets through the edit, narrows the reported range to the exact edit using `asked` (in the
   app the storage reports a typed character as its whole line), and then:
   - while loading: `reparse()` (whole text, or the launch `Preparse` if it is of this text);
   - otherwise, unless the map is already stale, `MarkdownStyler.restyle` (limit `partParseLimit` = 25,000 units once the text is
     longer than `synchronousParseLimit` = 100,000); debug builds assert that the result equals
     a whole parse;
   - if that returns nil and the text is at most 100,000 units: `reparse()`;
   - else (also for every further edit while the map is stale) `renderer.isStale = true` and a timer of `parseDelay` (0.25 s) does the whole parse
     when typing pauses.
3. **`didParse`** keeps the renderer's per-line measurement caches in step (`keepWidths`),
   narrows a table's diff to the changed row when the table shows as before, merges the diff
   into `changedLines`, recomputes what the selection reveals and schedules the word count.
4. **TextKit asks for the edited paragraph**:
   `ParagraphRenderer.textContentStorage(_:textParagraphWith:)` notes the range in `rendered` and
   returns the styled display paragraph, or the raw text when `isStale` or when the map's line
   does not have exactly that range.
5. **`textDidChange` → `restyleChangedLines`** nudges `changedLines`, one line wider on each
   side (an edit can restyle lines it did not touch: a fence, a multi-line token), then
   `refreshReveal`, then scrolls the selection into view.

Undo and redo send neither `shouldChangeText` nor `textDidChange`; they arrive through
`NSUndoManagerDidUndoChange`/`DidRedoChange` (`didUndoOrRedo`). A programmatic `text =` and an
input-method composition that is given up send no `textDidChange` either
(`compositionEndHandler` covers the latter). Markers are not revealed or hidden while
`hasMarkedText()`.

**Reveal.** A token, heading or fence shows its markers while the selection touches it, both
boundaries included (`ParagraphRenderer.touches`, `revealedRanges`). `refreshReveal` nudges the
symmetric difference between what was and what is revealed. Selection snapping
(`snapped`, from `willChangeSelection`) keeps the caret out of characters that are never shown:
block prefixes, the pipes of a grid row, the delimiter row, the leads of wrapped cells.

## Refreshing what is shown

TextKit keeps the display paragraphs it was given. The only thing that makes it ask again is an
attribute-only edit notification on the storage; `invalidateLayout` and `needsDisplay` lay out or
draw the paragraphs it already has.

- `nudge(ranges)` never touches TextKit. It calls `renderer.fallBehind(range)`, which adds to the
  `behind` set only what TextKit has actually asked for (`rendered`), then `catchUp(in: viewport)`.
- `catchUp(in:)` is the **single** call site of
  `storage.edited(.editedAttributes, range:, changeInLength: 0)`, inside
  `performEditingTransaction`, and only for `behind` ranges inside the given ranges (normally the
  viewport). Everything else waits in `behind` until the window reaches it.
- `EditorTextView.layout()` runs `super.layout()`, then up to `layoutPassLimit` (4) rounds of
  `layoutHandler` (`catchUpViewport` = `catchUp(viewport)` + `refit`) each followed by
  `super.layout()` again, then captures the scroll anchor. Without the extra pass a paragraph
  asked for again after layout is drawn from a layout TextKit no longer has (the first letter
  typed into an empty document was not drawn).
- `refit` renders again the wrapped table rows that TextKit broke into other lines than the
  renderer counted.

Rules, each from a measured failure (see the comments at `nudge`, `catchUpViewport`,
`themeDidChange`):

- Never nudge or ask for layout outside the window's own paragraphs. Taking the layout from
  under the top of the window once left TextKit estimating without end in `ensureLayoutForBounds`.
- Never call `edited(.editedAttributes)` with a widened range from `willProcessEditing`: the
  caret jumps and typed text lands on other lines.
- `catchUpViewport` is not called from `nudge`.
- A width change that does not change what a paragraph is made of marks the paragraph views
  `needsDisplay` instead of nudging (`updateColumnWidth`).

## Invariants

1. **Storage is the file.** Its text is the file's text after UTF-8 decoding; its attributes are
   only the base font, colour and default paragraph style of a plain-text view
   (`EditorTextView.applyTheme`, `didUndoOrRedo`). Tests check with `EditorWindow.storageProblem`.
   Saving never rewrites bytes: a BOM is stripped on read and written back, line endings are
   untouched ([MarkdownFile](../Sources/MarkoEditor/MarkdownFile.swift)); only strict UTF-8 opens.
2. **Same length.** A display paragraph has exactly its source line's UTF-16 length.
   Substitutions are one for one: pipe → tab; bullet character → a glyph from `Theme`; the `[`
   of a checkbox and the `!` of an image → U+FFFC; in wrapped rows pipe → U+2028, hidden
   characters → U+2060, hidden inline markers → U+200C. Never insert or delete.
3. **One edit helper.** Every edit that is not plain typing goes through
   `EditorController.perform(_:)`. Rules in `MarkoCore` are pure:
   `(text, StyleMap, selection) -> TextEdit?`.
4. **One refresh.** `catchUp`'s `edited(.editedAttributes)`; see above.
5. **A stale map is not read.** Anything that reads `renderer.map` on the user's behalf calls
   `parseIfPending()` first and does nothing if `renderer.isStale` is still true (an input method
   is composing). While stale, every paragraph renders raw.
6. **Any change of the map ends in `didParse`** with the edited range: the per-line width caches
   depend on it.
7. **`LineStyle.shift(by:)` moves every offset.** A new field that holds an offset must be added
   there, or partial parsing and `diff` break.
8. **A partial restyle equals a whole parse.** Asserted on every edit in debug builds, fuzzed by
   `RestyleTests` (`MARKO_FUZZ`). Debug builds therefore do a whole parse per key: measure only
   release builds.
9. **Fixed line heights.** Every block sets minimum and maximum line height to the same value
   (`ParagraphRenderer.block`); `BlockFragment` lifts the glyphs by `.glyphLift`. Never
   `.baselineOffset` for vertical placement, never `.kern` on hidden characters.
10. **The renderer decides, the fragment paints.** `BlockFragment` reads everything from the
    display paragraph's attributes (`.picture`, `.inlineBackground`, `.bullet`, `.hairline`,
    `.rule`, `.quoteBars`, `.codePanel`, `.tableRow`, `.glyphLift`).
11. **TextKit 2 only.** `textView.layoutManager` is never read; a fallback to TextKit 1 is an
    `assertionFailure` in debug builds (`willSwitchToTextKit1`). Not used: `NSTextTable`,
    `NSTextBlock`, `NSTextList`, `NSTextAttachmentViewProvider`, swift-markdown's `format()`, a
    non-rectangular text container.
12. **One network gate.** `TrustStore.allowsRemoteImages(for:)`, read in
    `EditorController.trustDidChange`, which sets `ImageCache.allowsRemote`. See
    [Safe mode and trust](#safe-mode-and-trust).
13. **Documents go by the real path.** Documents, tree roots and the tool's request items are made
    from symlink-resolved paths (`MarkdownDocument.document(at:)`,
    `DocumentController.openDocument`, `Request.Item`).
14. **Every visual constant is in [Theme.swift](../Sources/MarkoEditor/Theme.swift)**, sizes
    multiplied by the zoom. Caches keyed by size are dropped in `forgetMeasurements`. Code that
    uses `maximumTextWidth` must expect it to be unbounded (View > Full Width).

## Tables

One decision point: `ParagraphRenderer.grid(ofTableAt:in:)`, cached per header line and cleared
when the map, the reveal selection or the room changes. In order:

1. Not stale, and `StyleMap.isRegular(table)` (a leading pipe on every line, both outer pipes
   on the delimiter line, no row with too many cells, all lines in the same containers).
   Otherwise **source**.
2. **Single-line grid** at normal size, if its width with every marker hidden fits the room.
3. **Compact grid** (smaller type) by the same test.
4. **Wrapped grid**, if `ParagraphRenderer.wrapsWideTables` and the columns fit at
   `Theme.tableMinimumCellWidth` of text each plus the cell padding (48 points a column at
   zoom 1): columns share the room, cell text wraps, `<br>` is a line break.
5. Otherwise **source**: monospaced lines in a code panel.

Fit is judged with markers hidden so that revealing a marker never changes the kind of grid; a
single-line grid's edges are computed with touched tokens revealed, so its columns widen while
a marker shows.

The room is `tableRoom`: the text container's width less the list or quote indent. Once a text
has a table, `EditorTextView.runsOn` makes the container the whole page between the paddings
instead of the text column, every paragraph style then keeps ordinary text in the column
(`columnOrigin`), and a grid wider than the column is centred on the page. Width changes arrive
through `EditorTextView.setFrameSize` → `widthHandler` → `updateColumnWidth` →
`renderer.tablesChangingDisplay`, the only place `columnWidth` and `tableRoom` are set.

A wrapped row is still one paragraph. Each cell's lines are separated by U+2028 and carry a
paragraph style of their own; every line but the first is `Theme.hiddenSize` high, so the row's
height sits on its first line, and `BlockFragment` places each line in its cell box.
[GridLayoutManager](../Sources/MarkoEditor/TableWrap.swift) overrides
`lineFragmentRange(for:inContainerAt:)` and `enumerateTextSegments` so that clicks, carets and
selections land in the cells; `EditorController` replaces the vertical arrow moves there.
Spelling marks are suppressed in wrapped rows. These paths switch on lazily
(`hasWrappedRows`).

## Windows and documents

Not NSDocument's one-window-per-document default.
[MarkdownDocument](../Sources/MarkoApp/MarkdownDocument.swift),
[DocumentWindowController](../Sources/MarkoApp/DocumentWindowController.swift),
[DocumentController](../Sources/MarkoApp/DocumentController.swift).

- A `MarkdownDocument` (`autosavesInPlace`) owns one `EditorController`. A
  `DocumentWindowController` is a split view (lazy sidebar + page) that *shows* a document;
  choosing a file in the tree keeps the window and swaps the document under it. The document that
  is left is saved first and closed when it has no other window; its caret and scroll place are
  remembered per path.
- A **folder window** has a tree and no document until a file is chosen
  (`DocumentWindowController.openFolder`, `EmptyPage`). `DocumentWindowController.all` keeps such
  windows alive.
- **Pristine reuse.** `pristine` is the frontmost window when it has no folder, no sheet and a
  document with no file, no text and no edit. `vacant(for:)` is that, else a folder window with no
  document whose folder contains the file. What is opened next goes there instead of into a new
  window, except with `--new-window`, for a document that is itself pristine, and while windows
  are being restored (`DocumentController.restoring`).
- **A file that does not exist yet** is `MarkdownDocument.untitled(savingTo:)` with a
  `newFileURL`, written at its first change (AppKit refuses a document whose `fileURL` does not
  exist).
- **Changes from outside.** A per-document `FolderWatcher` (FSEvents) on the file's folder calls
  `fileMayHaveChanged`: a document with no changes of its own reverts to the file's contents
  (identical bytes are skipped, to keep undo); one with changes keeps them. AppKit's own
  `presentedItemDidChange` is overridden to do nothing: it arrives only now and then, and when
  the file was gone by then AppKit refused the next edit ("The file cannot be found").
- **Unsaved text.** The change count hears of an edit only when its undo group closes, so
  `hasUnwrittenText`/`noteUnwrittenText` are consulted in `canClose`, when leaving a file in the
  tree and in `applicationShouldTerminate`, and `data(ofType:)` breaks undo coalescing.
- **Restoration.** Document windows by AppKit plus selection and sidebar state; folder windows by
  `DocumentWindowController.restoreWindow`. `NSQuitAlwaysKeepsWindows` is registered as a default
  only, so the System Settings choice wins once made.
- Everything asked to open comes through `DocumentController.openDocument`, which resolves
  links and sends folders to `openFolder`.

## The marko tool and the socket

[Command](../Sources/MarkoCommand/Command.swift) (argv; `Command.usage` is the `--help` text),
[Request](../Sources/MarkoCommand/Request.swift), [Channel](../Sources/MarkoCommand/Channel.swift),
[the tool](../Sources/MarkoCLI/main.swift), [CommandServer](../Sources/MarkoApp/CommandServer.swift).

- **Socket.** A Unix stream socket at `<DARWIN_USER_TEMP_DIR>local.marko.socket`, or the path in
  `MARKO_SOCKET`.
- **Request.** One JSON object on one line ending in `\n` (`items[{path, line?}]`, `text?`,
  `wait`, `newWindow`, `trust?`; paths absolute with links resolved), then `shutdown(SHUT_WR)`.
  The line break, not the shutdown, ends the request.
- **Reply.** One line per thing that could not be opened, then `ok` once the files are read
  (before any window exists). With `--wait`, `closed` when the last waited document closes. Then
  the connection closes.
- **Exit status.** 2 for a usage error; 1 for any problem line, a connection that ends before
  `ok` (or before `closed` under `--wait`), an app that does not start within 20 s, or piped text
  that is not UTF-8; else 0.
- **Server.** A thread of its own. `Channel.listen` holds `flock` on `<socket>.lock` for the life
  of the process (of several instances exactly one listens) and replaces a stale socket file.
  Accepted connections get `SO_NOSIGPIPE` and a 2 s receive timeout; a request is at most 64 MB.
  An instance started with `MARKO_SOCKET` that cannot listen there exits. A smoke run listens
  only when `MARKO_SOCKET` is set.
- **Starting the app.** If nobody listens, the tool takes `flock` on `<socket>.launch`, tries
  again, and otherwise `posix_spawn`s the executable of the app bundle it sits in: a session of
  its own, descriptors closed, stdio to `/dev/null`, cwd `/`, a reduced environment, and
  responsibility disclaimed where the system has the call (a private symbol found with `dlsym`).
  It passes `MARKO_CLI=1` when the request opens something and `MARKO_FILE=<path>` for a first
  item that is an existing file without a line number or trust option; its own `MARKO_*`
  variables go along only when `MARKO_SOCKET` is set. Then it polls the socket every 2 ms.
- **In `CommandServer.open`**, everything that can fail must fail before `read` is called: the
  tool is answered before the windows are made. `--trust`/`--safe` for a folder go to the
  `TrustStore`; for a file or piped text they are that document's choice until the app quits, set
  before it has a window.
- The tool finds its app from its own real path, so `marko --version` is the version of the
  bundle the tool is in, not of the instance that is running. The request has no version: an
  option a running older app does not know is dropped silently by its JSON decoder.

## Safe mode and trust

User-facing text: [security.md](security.md). In code:

- [TrustStore](../Sources/MarkoEditor/TrustStore.swift). `TrustStore.shared` is in memory unless
  [main.swift](../Sources/MarkoApp/main.swift) replaces it with one on `UserDefaults.standard`,
  which it does only in a normal launch. Keys `TrustedFolders` (path → inode number) and
  `SafeFolders` (paths).
- Trust is for the directory inode at a path: a folder that is moved or replaced loses it.
  `canBeTrusted` refuses non-absolute paths, top-level folders, and the home and temporary
  folders or anything above them. The nearest answer above a document wins; "safe" answers are
  compared without regard to case.
- `allowsRemoteImages(for:)`: the choice made for that document since launch, else its folder's
  trust; false for no URL; no disk access while nothing is trusted or chosen. A document without
  a file keeps its choice in `EditorController.choiceWithoutFile` until it is saved.
- [ImageCache](../Sources/MarkoEditor/ImageCache.swift) blocks every image with a remote source
  unless `allowsRemote`: `http(s)` and scheme-less `//host` addresses, `file://otherhost/`, and
  paths that lead onto a network volume, which
  [NetworkVolume](../Sources/MarkoEditor/NetworkVolume.swift) tells from the mount list without
  touching the path. `http` is fetched as `https`. Limits: 32 MB (`byteLimit`) and 64 million
  pixels (`pixelLimit`) per image, local or remote. The fetch is the app's only network call and
  uses `ImageCache.session`: no cookie storage, no credential storage, no URL cache.
- Links: Markdown files open in Marko, `http`/`https`/`mailto` go to `NSWorkspace`, any other
  file is revealed in the Finder and never opened (`linkOpener`, `fileRevealer`).
- [FileTree](../Sources/MarkoEditor/FileTree.swift): a double click opens only pictures, audio,
  video, PDF and plain text in the system's default app; listing does not follow a link onto a
  network volume; names starting with `.`, `node_modules` and editor backups are not listed.

## Platform behaviour relied on

Undocumented AppKit/TextKit behaviour the design rests on. Run `OSCanaryTests` first after a
macOS or Xcode update.

| Behaviour | Guard |
|---|---|
| A delegate paragraph with same-length substituted characters is honoured | `OSCanaryTests.sameLengthCharacterSubstitutionIsHonoured` |
| `edited(.editedAttributes)` makes the delegate render the paragraph again | `OSCanaryTests.editedAttributesMakesTheDelegateRenderAgain` |
| A font of a hundredth of a point takes no visible width | `OSCanaryTests.aHundredthOfAPointFontTakesNoVisibleWidth` |
| A paragraph not laid out is estimated from its first character's line height (why a wrapped row puts its height on its first line) | `OSCanaryTests.aParagraphThatIsNotLaidOutIsTakenToBeAsHighAsItsFirstCharactersLineSays` |
| U+2028 plus a paragraph style per cell puts a cell's lines in its column | `OSCanaryTests.aLineSeparatorAndAParagraphStyleOfItsOwnPutACellsLinesInItsColumn` |
| No fallback to TextKit 1 through typing, undo and find | `TextKit2WindowTests.staysOnTextKit2AfterTypingUndoAndFind`, the debug assertion |
| A paragraph asked for again after `layout()` is not laid out before drawing | `FirstKeyTests`, `CatchUpTests` |

If one of the two wrapped-table canaries (the last two of `OSCanaryTests`) fails, set
`ParagraphRenderer.wrapsWideTables = false`: wide tables then show as source (`TableTests`
exercises that switch).

Relied on without a canary of its own, recorded as `MEASURED:` comments where they matter:

- The storage reports a typed character as a change of its whole line (`didProcessEditing`).
- Undo puts text back with the attributes it was removed with (`didUndoOrRedo`).
- Undo/redo and a cancelled composition send no `textDidChange`.
- `enumerateTextSegments` reports the lines of a wrapped row at the row's left edge, and the
  trailing empty line at the container's left edge (`GridLayoutManager`).
- A TextKit 2 text view's storage and layout manager keep each other alive
  (`EditorController`'s `isolated deinit` takes them apart in a fixed order).
- `NSTextView.viewDidEndLiveResize` scrolls to the first character shown (`EditorTextView`
  override); the scroll anchor in `layout()`/`setFrameSize` holds the text in place.
- A window with a transparent titlebar takes part in window tabs only with a
  `tabbingIdentifier`; the sidebar runs the window's full height only under an (empty) unified
  toolbar.
- `LSUIElement` written into the bundle's info dictionary before `NSApplication` exists, plus
  activation policy `.prohibited`, keep smoke instances out of the Dock and off the front.
- Saved window state is one place per bundle identifier, whatever instance writes it: hence
  `ApplePersistenceIgnoreState` in smoke and measuring runs.
- NSDocument: a document whose file is gone cannot be saved in place (saved as a save-as
  instead); a symbolic link cannot be opened or saved as such.
- A `read()` that starts as the peer calls `shutdown()` is sometimes not woken: the request is
  line-delimited.

## Run modes and MARKO_ variables

Decided in [main.swift](../Sources/MarkoApp/main.swift). The variables are compiled into the
release app; the header comments of [Smoke.swift](../Sources/MarkoApp/Smoke.swift) and
[Perf.swift](../Sources/MarkoApp/Perf.swift) are the source of truth.

**Normal launch** (no `MARKO_SMOKE`, no `MARKO_PERF`): keeps window frames, uses the persistent
`TrustStore`, asks about trust, restores windows, listens on the user's socket, shows in the Dock.
The app executable takes no options: started bare it is a normal instance with the user's
settings.

**Smoke run** (`MARKO_SMOKE=1`): opens what it is given, prints `smoke: key=value` lines and
quits; hard timeout 20 s (60 s with `MARKO_SERVE`). In-memory trust, no window restoration, no
saved frames, nothing added to Open Recent, windows on the built-in display, `LSUIElement` and
activation policy `.prohibited`, no command server unless `MARKO_SOCKET` is set.

**Measuring run** (`MARKO_PERF=<scenario>`): the same isolation, but it may take the front.

| Variable | Read by | Meaning |
|---|---|---|
| `MARKO_SOCKET=<path>` | app, tool | The socket to listen on or connect to. Makes the tool forward its `MARKO_*` variables to an app it starts. |
| `MARKO_FILE=<path>` | app | Set by the tool: the file to read and parse while AppKit starts. |
| `MARKO_CLI=1` | app | Set by the tool: do not open an untitled document at launch. |
| `MARKO_SMOKE=1` | app | Smoke run. |
| `MARKO_LINK=<destination>` | smoke | Follow that link from the document; merge the windows into tabs. |
| `MARKO_UNTITLED=1` | smoke | Allow the empty document at launch. |
| `MARKO_SIDEBAR=1` | smoke | Toggle the sidebar first. |
| `MARKO_RENAME=<path>` | smoke | Start renaming that item in the tree. |
| `MARKO_SWITCH=<path>` | smoke | Type into the first file, then choose that file in the tree. |
| `MARKO_INSTALL=<folder>` | smoke | Install the command-line link there, as the menu item does. |
| `MARKO_SERVE=<log>` | smoke | Open nothing; serve the tool on `MARKO_SOCKET` and log each request. The pid is in the log's `serve: started pid=` line. |
| `MARKO_TRUST=ask` | smoke | Let a folder without an answer be asked about. |
| `MARKO_SNAPSHOT=<png>` | smoke | Picture of the window; the instance takes the front for a moment. With `MARKO_APPEARANCE=light\|dark`, `MARKO_CARET=<offset>[,<length>]`, `MARKO_SIZE=<w>x<h>`, `MARKO_ZOOM=<factor>`, `MARKO_FULLWIDTH=1`. |
| `MARKO_PERF=<scenario>` | perf | `launch`, `idle`, `open`, `typing`, `scroll`, `resize`, `switch`, `folder`, `serve`. Options `MARKO_PERF_OUT`, `_OFFSETS`, `_PASTE`, `_FILES`, `_EXPAND`, `_COUNT`, `_GAP`, `_WIDTH`, `_FRAME_GAP`, `_PROFILE`, `_KEYS`, `_POLICY`, `_TIMEOUT`, `_ACTIVATE` (see Perf.swift). |
| `MARKO_FUZZ=<n>` | `RestyleTests` | Multiplier for the restyle fuzz; `scripts/perf/run-all.sh --fuzz` sets it. |
| `MARKO_PERF_APP`, `MARKO_PERF_CORPUS`, `MARKO_CONTROL_FLUSH` | `scripts/perf` only | Not read by the app. |

[scripts/drive/launch.sh](../scripts/drive/launch.sh) is the one way to run a *normal* launch
without touching a Marko that is in use: a copy of the app with bundle identifier
`local.marko.drive`, a home and socket of its own, pinned to the built-in display. See
[development.md](development.md).

## Tests

Swift Testing only, in three bundles. Counts, details and rules: [development.md](development.md).

- `MarkoCoreTests`: the styler against fixtures, the partial restyle against the whole
  parse (fuzz), the edit rules. No AppKit. The only tests with time budgets.
- `MarkoCommandTests`: argument parsing, path resolution, the socket.
- `MarkoEditorTests`: every suite is nested in the serialized parent `EditorTests` and
  works in a real window that is on screen on the built-in display but never active.
  [EditorWindow](../Tests/MarkoEditorTests/EditorWindow.swift) is the harness: it types through
  `window.sendEvent`, and probes what TextKit laid out (`fragment(at:)`, `displayAttributes(at:)`,
  `caretRect(at:)`, `pixels()`, `storageProblem`, `paintProblem`). `WebStub` answers every
  http(s) request of the test process, so no test reaches the network.
- [scripts/smoke.sh](../scripts/smoke.sh) and [scripts/smoke-cli.sh](../scripts/smoke-cli.sh)
  run the built app and the tool as processes, with real key events for the `--wait` journey.

What the in-process harness cannot show: behaviour that depends on the window being key, or on
keys arriving through the event queue. Two defects (text typed after a save not saved; the first
typed letter not drawn) were invisible to it.

## Where things live

`Sources/MarkoCore`
- `SourceIndex` – line table; the parser's line/UTF-8 column to UTF-16 offset.
- `BlockPrefixScanner` – where block markers end on a line.
- `MarkdownStyler`, `Restyle` – parser output to `StyleMap`; partial restyle.
- `StyleMap` – the model, `diff`, `isRegular`.
- `CodeTokenizer` – generic syntax colouring of code.
- `InputRules`, `FormatCommands`, `TableEdits` – pure edit rules returning `TextEdit`.

`Sources/MarkoEditor`
- `EditorController` – storage and text view delegate: parse scheduling, reveal, nudge and
  catch-up, the edit helper, key dispatch, selection snapping, scrolling, links, trust state.
- `ParagraphRenderer` – content-storage and layout-manager delegate: owns the map, `isStale`,
  the reveal selection, table grids and measurement caches; builds display paragraphs.
- `BlockFragment` – drawing, and the geometry of wrapped rows.
- `TableWrap` (`GridLayoutManager`) – hit-testing and selection segments in wrapped rows.
- `EditorTextView` – the TextKit 2 stack (assembled by hand in `make()`), container sizing,
  layout passes, scroll anchor, menu actions, drops.
- `Theme` – every visual constant; zoom, word count and full width as static state that posts
  `Theme.didChange`.
- `ImageCache`, `TrustStore`, `NetworkVolume` – safe mode.
- `FileTree`, `SidebarController` – the sidebar. `Chrome` – titlebar, footer, empty page,
  status capsule. `MarkdownFile` – bytes to text and back. `Preparse` – the parse made ahead at
  launch. `IconFont` – Nerd Font fallback. `BuiltInDisplay` – `NSWindow.moveToBuiltInDisplay()`.

`Sources/MarkoApp`
- `main` – run mode switches. `AppDelegate` – settings (`Zoom`, `ShowsWordCount`, `FullWidth`,
  `SidebarWidth` in the `local.marko` defaults), quit. `MainMenu` – the menu bar (format and
  table items come from `formatItems` in `EditorTextView`).
- `DocumentController`, `MarkdownDocument`, `DocumentWindowController` – see above.
- `CommandServer`, `CommandLineTool` (the install menu item), `Smoke`, `Perf`.

`Sources/MarkoCommand`, `Sources/MarkoCLI` – the tool.
