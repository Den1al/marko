# Marko

Native macOS WYSIWYG Markdown editor on TextKit 2: one `NSTextView` whose storage is the file's
exact text, rendered only at display time; a folder sidebar; a `marko` command-line tool; safe
mode. SwiftPM only (no Xcode project), macOS 26 arm64, Swift 6.4 (tools version 6.2, Swift 6
language mode). Bundle id `local.marko`, environment variables `MARKO_*`.

## Commands

```sh
scripts/build-app.sh                              # build/Marko.app, release ("debug" as argument)
perl -e 'alarm 550; exec @ARGV' swift test        # all tests, about 4 min
swift test --filter MarkoCoreTests                # one target; MarkoCommandTests is the quickest
swift test --filter InputRulesTests               # one suite
swift test --filter 'EditorTests/WindowTests'     # an editor suite (all are nested in EditorTests)
swift test --filter aRequestCutShortIsNone        # one test; `swift test list` shows ids
scripts/build-app.sh && scripts/smoke.sh          # about 1 min, must end "smoke: OK"
scripts/snapshot.sh in.md build/out.png [light|dark] [900x1000] [caret[,length]]   # takes focus < 1 s
scripts/install-cli.sh <temp folder>              # without a folder it acts on ~/.local/bin or /usr/local/bin
```

- A full `swift test` must print three `Test run with N tests ... passed` lines (editor, core,
  command; counts in docs/development.md), a filtered run one per bundle that had a match. Count
  them: a test process that died mid-run has exited 0 (seen with `performClose`, posted events).
- Before finishing a change to `Sources/`: full `swift test` and smoke. After a change to
  `Restyle.swift`, `MarkdownStyler.swift` or the swift-markdown version also
  `scripts/perf/run-all.sh --fuzz` (about 8 min).
- `build-app.sh` deletes and re-creates `build/Marko.app`; a `marko` link installed from the
  repository points into it. Leave it a release build; chain with `&&`, never `;`; do not build
  during a smoke run. SwiftPM locks `.build`: no second `swift build`/`swift test` at the same
  time.

## Architecture in short

Full description, with the `MARKO_*` variables: [docs/architecture.md](docs/architecture.md).
Read it before changing the editor, windows, the tool or safe mode, and update it in the same
commit as any change that makes it untrue.

- `MarkoCore` (Foundation + swift-markdown, no AppKit): `MarkdownStyler` turns the parse into a
  `StyleMap` (one `LineStyle` per source line); `Restyle.swift` re-parses only the part around
  an edit; `InputRules`, `FormatCommands`, `TableEdits` are pure `(text, map, selection) ->
  TextEdit?`.
- `MarkoEditor` (AppKit): `EditorController` (storage and text view delegate), `ParagraphRenderer`
  (builds display paragraphs), `BlockFragment` (draws), `EditorTextView`, `Theme`, sidebar,
  `ImageCache`, `TrustStore`.
- `MarkoCommand` (Foundation only) + `MarkoCLI`: the tool, its request and socket.
- `MarkoApp`: documents, windows, menus, `CommandServer`, `Smoke.swift`, `Perf.swift`.
- `MarkoEditor`, `MarkoApp`, `MarkoEditorTests` use default `MainActor` isolation; the rest do not.
  `NSTextLayoutFragment`/`NSTextLayoutManager` subclasses are `nonisolated final class`.

A keystroke: text view → `EditorController` (may substitute a `TextEdit` via `perform`) →
storage changes → `didProcessEditing` runs `MarkdownStyler.restyle` (whole parse only when
needed; deferred 0.25 s above 100,000 units) → `didParse` → TextKit asks `ParagraphRenderer` for
the paragraph → `textDidChange` nudges the other lines whose style changed.

## Invariants

- Storage is the file's exact text with no attributes beyond the base font, colour and paragraph
  style. Saving never rewrites bytes (BOM and line endings kept; strict UTF-8 only).
- A display paragraph has exactly the source line's UTF-16 length: substitute characters one for
  one, never insert or delete.
- Every edit that is not plain typing goes through `EditorController.perform(_:)`.
- The only refresh is `EditorController.nudge` → `fallBehind` → `catchUp`
  (`storage.edited(.editedAttributes, …)` in an editing transaction, viewport only).
  `invalidateLayout` and `needsDisplay` do not re-query the renderer. Never nudge or force layout
  outside the viewport; never call `edited(.editedAttributes)` from `willProcessEditing`.
- Code that reads `renderer.map` for a user action calls `parseIfPending()` first and does
  nothing while `renderer.isStale`. Any new way to change the map ends in `didParse`.
- A new offset-bearing field on `LineStyle` is added to `LineStyle.shift(by:)`. A partial restyle
  must equal a whole parse (asserted per edit in debug builds, so measure only release).
  `MarkdownStyler.style` stays pure; it also runs off the main thread.
- Undo and redo send neither `shouldChangeText` nor `textDidChange`. In the app the edited range
  of one typed character is the whole line: never assume it is tight.
- `ParagraphRenderer` decides, `BlockFragment` only paints from display attributes. How a table
  shows is decided only in `ParagraphRenderer.grid(ofTableAt:in:)`.
- Banned: `textView.layoutManager` and any TextKit 1 API (debug builds assert on fallback),
  `NSTextTable`, `NSTextBlock`, `NSTextList`, `NSTextAttachmentViewProvider`, swift-markdown's
  `format()`, a non-rectangular text container, `.baselineOffset` for placement (line heights
  are fixed and glyphs lifted with `.glyphLift`).
- One network gate: `TrustStore.allowsRemoteImages` → `ImageCache.allowsRemote`. No second
  switch, no other network, update or telemetry call. Linked non-Markdown files are revealed in
  the Finder, never opened. [docs/security.md](docs/security.md) is a promise to users: keep it
  true or change it in the same commit.
- After a macOS or Xcode update run `OSCanaryTests` first; if its two wrapped-table canaries fail,
  set `ParagraphRenderer.wrapsWideTables = false`.

## Running things without disturbing the machine

A developer may have their own Marko open, with documents in it, while tests and smoke runs go
on. Everything a test or script starts is isolated from it.

- Test, smoke and driven windows are placed on the built-in display when there is one
  (`NSWindow.moveToBuiltInDisplay()`), so they keep off an external display that is in use. New
  window-making code in tests, smoke paths and scripts must call it. Without a built-in display
  (a desktop Mac, a closed lid) it returns false and the window stays where AppKit put it.
- Never start `build/Marko.app/Contents/MacOS/Marko` bare, not even for `--version` (that is a
  normal instance with the real settings). Only with `MARKO_SMOKE=1`, via `smoke.sh`,
  `smoke-cli.sh`, `snapshot.sh`. The tool is `Contents/Helpers/marko`.
- Never use the default command socket or the real `local.marko` defaults: give instances
  `MARKO_SOCKET=<temp path>`. A normal (non-smoke) launch only through `scripts/drive/launch.sh`.
- End only processes you started, by pid. No `pkill`/`killall`/pattern kills of Marko or
  `swiftpm-testing-helper`, no Apple events, never quit an app you did not start.
- Do not weaken the smoke checks `startedInDock=false` and `active=false background=true`.
  `scripts/snapshot.sh` takes keyboard focus briefly: do not run it while someone is typing.
- `scripts/perf` (other than `--fuzz`) brings instances to the front for minutes and starts
  other editors: run it only on purpose.
- `swift test` does not prove keyboard behaviour: its window is never key, which hid two
  defects (text typed after a save not saved; first typed letter not drawn). After a change to
  typing, key handling, saving or first-frame drawing, verify with real key events in a key
  window, or say that you did not. Smoke covers only saving after typing and the first key (it
  types the fixed text `smoke edit` + Return); any other key needs `scripts/drive`.

## Tests

- Swift Testing only. Harness: `EditorWindow`, `SidebarWindow`, `TemporaryFolder`, `WebStub`,
  `Fixtures`. No network, and nothing of the person at the Mac: keep `linkOpener`,
  `fileRevealer`, `trasher` stubbed, use `NSPasteboard.withUniqueName()`, no
  `UserDefaults.standard`.
- Never `NSApp.postEvent`, `NSApp.nextEvent`, `window.performClose` or
  `NSDocumentController.newDocument` in the test process (it dies with status 0 or hangs). Use
  `EditorWindow.type`, `window.close()`, `MarkdownDocument.untitled()`.
- Work that arrives on the main queue (listings, FSEvents, images, word count) needs an `async`
  test with `await wait { }`. No wall-clock budgets on window work. Fixtures stay byte-exact.

## Conventions

- Every visual constant lives in `Theme.swift`, sizes scaled by the zoom.
- Comments are `///` full sentences that say why; `MEASURED:` marks a fact found by experiment.
  Do not simplify code beside one without measuring again.
- Menus and shortcuts: `MainMenu.swift` and `formatItems` in `EditorTextView.swift`; update the
  README table with either. `marko --help` is `Command.usage`.
- One dependency, swift-markdown `exact: "0.9.0"`. Add none. If `Package.resolved` changes, renew
  `THIRD-PARTY-NOTICES.txt`.
- Commits: one sentence-case subject line that says what changed.

## Other documents

- [README.md](README.md) – for users: install, usage, shortcuts, security summary, troubleshooting.
- [docs/development.md](docs/development.md) – before running tests, smoke, snapshots or a driven
  copy: test rules in full, where a change goes, cleanup after `scripts/drive`.
- [docs/security.md](docs/security.md), [docs/known-limits.md](docs/known-limits.md) – exact
  user-facing behaviour; update with the code.
- [docs/README.md](docs/README.md) indexes everything.
