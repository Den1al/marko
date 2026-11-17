# Development

Commands, test conventions and how to run the app without disturbing a Marko that is in use.
The short rules are in [CLAUDE.md](../CLAUDE.md); how the code works is in
[architecture.md](architecture.md). Timings are from an M3 Max with Swift 6.4.2 on macOS 26.7,
with other work going on; take them as an order of magnitude.

## Commands

| What | Command | Time |
|---|---|---|
| Debug build | `swift build` | under 1 s when up to date |
| App bundle | `scripts/build-app.sh` (release) or `scripts/build-app.sh debug` → `build/Marko.app` | 47 s clean, 14 s clean debug, 4 s up to date, about 22 s after a `swift test` (which makes it compile `MarkoCore` and `MarkoEditor` again) |
| All tests | `perl -e 'alarm 550; exec @ARGV' swift test` | about 4 min 10 s |
| Smoke | `scripts/build-app.sh && scripts/smoke.sh` | about 1 min |
| Fuzz of the partial parse | `scripts/perf/run-all.sh --fuzz` | about 8 min |
| Time budgets | `scripts/perf/run-all.sh --check` | about 7 min; takes the front |
| Full measurement | `scripts/perf/run-all.sh` | about 45 min; takes the front |

**The build may be the tool in use.** `scripts/build-app.sh` deletes and re-creates
`build/Marko.app`. A `marko` link installed from the repository points into that bundle, so
every successful compile replaces the command in use. A compile error leaves the old bundle in
place (which is why `;` would smoke the old app: chain with `&&`); only a failure in the
assembly steps after the compile (icon, copy, codesign) leaves the link dangling. Leave the
bundle as a release build. Do not build while a smoke run is going (it runs that bundle). A
Marko started from the bundle keeps running the old code across a rebuild.

**SwiftPM locks `.build`.** A second `swift build` or `swift test` in the same checkout waits
for the first. Release-mode tests need a scratch directory of their own:
`swift test -c release -Xswiftc -enable-testing --scratch-path <dir>`.

### Reading the test result

An unfiltered `swift test` must print three lines:

```
Test run with 373 tests in 23 suites passed    (MarkoEditorTests)
Test run with 213 tests in 16 suites passed    (MarkoCoreTests)
Test run with 29 tests in 3 suites passed      (MarkoCommandTests)
```

The exit status alone is not proof: a test process that died in the middle of a run has exited
0 (seen with `performClose` and posted events, see [Rules](#rules)). A run with a failing test
exits 1 and prints `Test run with ... failed`. The three XCTest "Executed 0 tests" blocks in the
log are not the result. A filtered run prints one line per bundle that had a match.

A run that hangs: the `alarm` ends `swift test` but the `swiftpm-testing-helper` child survives.
End it by its pid, never by a pattern (other runs in this checkout would be hit too).

### Running fewer tests

Swift Testing only. `swift test list` prints the ids; `--filter` is a regular expression over
them.

```sh
swift test --filter MarkoCommandTests              # a target: 29 tests, 4 s
swift test --filter MarkoCoreTests                 # 213 tests, 36 s
swift test --filter InputRulesTests                # a suite: 48 tests, 2 s
swift test --filter 'EditorTests/WindowTests'      # an editor suite: 41 tests, 23 s
swift test --filter aRequestCutShortIsNone         # one test by name
swift test --filter 'MarkoCommandTests.ChannelTests/aRequestCutShortIsNone'
swift test --filter 'EditorTests/TableTests'       # the editor's grid suite alone: 43 tests
swift test --filter 'TableTests|TableEditsTests|TableStyleTests'
    # everything about tables, about 100 s: editor TableTests (43) and WrappedTableTests (44),
    # core TableEditsTests (21) and TableStyleTests (7); two result lines, one per bundle
```

Every editor suite is nested in the serialized suite `EditorTests`
(`MarkoEditorTests.EditorTests/WindowTests/twoWindowsMergeIntoTabs()`). A bare
`--filter WindowTests` also matches `TextKit2WindowTests`. The slow suites are
`WrappedTableTests` (52 s), `TableTests` (44 s), `RestyleTests` (35 s, nearly all of it one test),
`FormatTests`, `WindowTests`.

### What must pass

- Before a commit that touches `Sources/`: the full `swift test` and `scripts/smoke.sh`.
- After a change to `Restyle.swift`, `MarkdownStyler.swift` or the swift-markdown version:
  `scripts/perf/run-all.sh --fuzz` as well (a release test run, not a measurement).
- Anything else under `scripts/perf` only on purpose: `--check` exists for changes on a key,
  launch, scroll or tool path, and it brings instances to the front for minutes. The numbers
  differ by a third between sessions on the same machine, so compare two builds in one run.

## Tests

### Harness

- [EditorWindow](../Tests/MarkoEditorTests/EditorWindow.swift): an `EditorController` in a real
  window, on screen on the built-in display, never active. `type(_:)` sends key events through
  `window.sendEvent`; `command(_:)` runs a movement or delete selector through the delegate;
  `placeCaret(at:)` is an ordinary click; `mouseDown(at:)` only for clicks the view consumes at
  once (a checkbox); `chooseFormat` picks a Format menu item. Probes: `fragment(at:)`,
  `displayAttributes(at:)`, `isHidden`, `caretRect(at:)`, `columnX(at:)`, `pixels()`,
  `storageProblem`, `paintProblem`.
- `SidebarWindow` and `TemporaryFolder`
  ([SidebarTests.swift](../Tests/MarkoEditorTests/SidebarTests.swift)), `WebStub` (a
  `URLProtocol` that answers every http(s) request and records what was asked for), `Fixtures`
  ([FixtureSupport](../Tests/FixtureSupport/Fixtures.swift)).
- Fixtures are in `Tests/Fixtures` and stay byte-exact (`.gitattributes`:
  `Tests/Fixtures/** -text`). A new fixture is picked up by every fixture suite through
  `Fixtures.all`.

### Rules

Each of these ended or hung a test run, or touched something of the person at the Mac.

- Never `NSApp.postEvent`, `NSApp.nextEvent` or `window.performClose` in the test process: the
  process ends silently with status 0 a moment later. Use `EditorWindow.type`, `window.close()`.
- Never `NSDocumentController.newDocument` (a modal error; the run hangs): use
  `MarkdownDocument.untitled()`. Never Command-click where there is no link (the tracking loop
  hangs).
- Listings, FSEvents, image loads and the word count arrive on the main queue: such a test is
  `async` and uses `await wait { ... }` instead of spinning the run loop.
- Keep `linkOpener`, `fileRevealer` and `trasher` stubbed (the defaults open the browser, a
  Finder window, and move files to the real Trash). Use `NSPasteboard.withUniqueName()`; the one
  test of the find pasteboard saves and restores it. No `UserDefaults.standard`; persistent trust
  in a test is `UserDefaults(suiteName:)` on a path in the test's temporary folder. No network:
  `WebStub`.
- A test that wants a remote image sets `editor.loadsRemoteImages = true` or trusts the folder.
- Reset `Theme.zoom`, `Theme.showsWordCount` and `IconFont.families` in a `defer`.
- `paintProblem` must be read before anything that lays out (`displayIfNeeded`, `fragment(at:)`,
  `caretRect`). `fragment(at:)` catches up and refits; a test that reads TextKit's fragments
  directly does so itself. In rows of wrapping cells use `caretRect`, not `characterRect` or
  `columnX`. A raw (unparsed) paragraph is `displayAttributes(at:)[.glyphLift] == nil`.
- No wall-clock budgets on window work; only `MarkoCoreTests` has timing tests.
- Any window a test makes is moved with `NSWindow.moveToBuiltInDisplay()`: on a Mac with a
  built-in display the test windows are there, and keep off an external display that is in use.
- Do not name a top-level test type `Picture` (it collides with a system type).

### What the harness cannot show

The test window is never key, and its keys are handed to the window rather than coming through
the event queue. Two defects were invisible for that reason:

- Text typed after a save was not saved on close: keys handed to a window never close the undo
  manager's per-event group, so the test's document heard of edits the real one did not.
- The first letter typed into an empty document was not drawn: only a key window's text view
  asks for layout between the edit and `textDidChange`.

Also, in the app the storage reports a typed character as a change of its whole line; in the
test window it is the one character. Code must never assume a tight edited range.

So for a change to typing, key handling, saving or the first frames: verify with real key
events in a key window, or say plainly that it was not verified that way. Smoke covers only
saving after typing and the first key: its `--wait` step posts real keys in the app, but always
the fixed text `smoke edit` + Return ([Smoke.swift](../Sources/MarkoApp/Smoke.swift)). A green
smoke run says nothing about any other key; that needs a driven copy (`scripts/drive`, below).

## Where a change goes

| Change | Code | Tests |
|---|---|---|
| What a key does (Return, Backspace, Delete, Tab, paste, a typed pipe or closing bracket) | the rule in `Sources/MarkoCore/InputRules.swift` (`newline`, `deleteBackward`, `deleteForward`, `indent`, `outdent`, `paste`, `closingBracket`) or `TableEdits.swift`; dispatched from `EditorController.textView(_:doCommandBy:)` (command keys) and `editTyping` (typed characters) | `InputRulesTests`, `TableEditsTests` for the rule; `BlockTests`, `TableTests` for the key in a window; then real keys with `scripts/drive` |
| A Format menu command or shortcut | `FormatCommand` and `FormatCommands` in `Sources/MarkoCore/FormatCommands.swift`; the item in `formatItems` (`EditorTextView.swift`); other menus in `MainMenu.swift`; the README shortcut table | `FormatCommandsTests`; `FormatTests` (uses `chooseFormat`, asserts the shortcuts); `WindowTests` keeps Command-B for the sidebar |
| A size, colour or spacing | `Theme.swift` only | `RenderingTests` (each heading level smaller than the one above); `FormatTests` asserts some literal point sizes and fragment heights; `BlockTests.fragmentHeightsAreExact`; `PolishTests`, `FeedbackTests` |

`FeedbackTests` and `PolishTests` are regression tests across all areas, so a change anywhere
can fail there. Look before adding: Return on an empty list item already leaves the list
(`InputRulesTests.returnOnAnEmptyItemLeavesTheList`), and Strikethrough is already in
`formatItems`.

## Running the app beside a Marko that is in use

Whoever works on the code may have their own Marko open, with documents in it. Rules:

1. Never start `build/Marko.app/Contents/MacOS/Marko` bare. It takes no options: `Marko
   --version` is an ordinary instance with the real settings, socket and saved windows. The
   version query is `build/Marko.app/Contents/Helpers/marko --version`.
2. Start it only with `MARKO_SMOKE=1` (through `scripts/smoke.sh`, `smoke-cli.sh`,
   `snapshot.sh`), and with `MARKO_SOCKET=<temp path>` whenever the tool is involved. Never the
   default socket, never the `local.marko` defaults domain, never `open -a build/Marko.app`.
3. End only processes you started, by pid (`$!`, or the `serve: started pid=` line of your own
   log). No `pkill`, `killall`, pattern kills or Apple events.
4. Windows go on the built-in display where there is one. Without one (a desktop Mac, a closed
   lid) `moveToBuiltInDisplay()` returns false and moves nothing: the windows of tests and smoke
   runs then appear on the display in use, and `scripts/drive` does not run.
5. Smoke instances stay out of the Dock and off the front; `smoke.sh` and `smoke-cli.sh` fail
   unless they see `startedInDock=false` and `active=false background=true`. Do not weaken
   those checks.
6. Never run `scripts/install-cli.sh` without an explicit temporary folder: without one it acts
   on `~/.local/bin` or `/usr/local/bin`, where an installed link is.
7. Never launch with `-ApplePersistenceIgnoreState NO` or `-NSQuitAlwaysKeepsWindows`: an
   instance with bundle identifier `local.marko` then replaces the saved windows of the real one.

### Smoke

`scripts/smoke.sh` needs a current `build/Marko.app` (it does not build), the built-in display,
`perl`, `git` and `PlistBuddy`. It launches the app about 14 times with `MARKO_SMOKE=1` on files,
a folder, links and the system's open event, greps the `smoke: key=value` lines each run
prints, installs the tool into temporary folders, then runs `scripts/smoke-cli.sh`, which drives
the `marko` tool against serving instances on sockets of their own (refusals, line numbers,
piped text, `--wait`, git's editor, safe mode against a local listener, five tools cold-starting
at once, a 40 ms median budget for the warm tool, and no instance ever frontmost). It must end
with `smoke: OK`.

To extend it: print a `smoke:` line in [Smoke.swift](../Sources/MarkoApp/Smoke.swift) and grep
for it in the script. The switches are listed in that file's header comment and in
[architecture.md](architecture.md#run-modes-and-marko_-variables).

### A picture of a rendering

```sh
scripts/snapshot.sh <file.md|folder> <out.png> [light|dark] [<width>x<height>] [<caret>[,<length>]]
```

Defaults: light, 900x1000, caret 0. Write pictures under `build/` (ignored). The instance takes
keyboard focus for under a second (the window must be key for the caret to be drawn; keys are
dropped meanwhile) and hands it back: do not run it while someone is typing.

It needs a current `build/Marko.app` (it does not build) and an existing output folder. With
the Screen Recording permission for the terminal the PNG is the whole window, otherwise the
page only; the height is cut to what the built-in display allows. Example:
`scripts/build-app.sh && scripts/snapshot.sh Tests/Fixtures/kitchen-sink.md build/kitchen-dark.png dark`.

### A normal launch, driven

For what a smoke run does not have (menus, restoration, recent documents, real mouse and key
events): `scripts/drive`. The scripts' headers have the details.

- `scripts/drive/launch.sh <work folder> <seconds> [app arguments]` starts a **copy** of
  `build/Marko.app` with bundle identifier `local.marko.drive`, a home and socket inside the
  work folder, pinned to the built-in display and kept from activating itself (`pin.m`), and
  prints its pid. `-ApplePersistenceIgnoreState YES` as an app argument starts without restored
  windows. The copy is made once per work folder: remove `<work>/Marko.app` after a rebuild.
  The copy shows a Dock icon named Marko while it runs.
- `build/drive/drive <pid> < commands` (from `drive.swift`) posts mouse and key events to that
  one process and reads results through accessibility. Clicks and key equivalents that act on a
  window need the copy in front: batch them as `idle 2`, `front`, the clicks, `hide`. Plain
  keys, Quit and the `marko` tool do not. Never match menu items across the whole accessibility
  tree: the Apple menu is in it.
- The driver's commands (`type`, `key`, `text`, `sel`, `at`, `cap`, `front`, `hide`, `idle` and
  more) are listed in the header of `scripts/drive/drive.swift`, one a line on standard input;
  `text` prints the document's text, which is how a typed result is checked.
- `drive` needs the Accessibility and event-posting permissions for the terminal (it stops with
  `no permission to post events or read the accessibility tree`) and a built-in display.
  `launch.sh` builds `build/drive/drive` and `pin.dylib` itself.
- `pb.swift` saves and restores the clipboard and find pasteboard around a check that
  writes them. `drop.swift` is a drop target window that logs what a drag offers.
- Cleanup: quit the last launch with Marko > Quit and Close All Windows, remove the work
  folder, then `defaults delete local.marko.drive`, `lsregister -u <work>/Marko.app`, and remove
  `~/Library/Caches/local.marko.drive`, `~/Library/HTTPStorages/local.marko.drive`, the copy's
  recent-documents list (`local.marko.drive.sfl4`) and
  `$TMPDIR/local.marko.drive.savedState`. A file the copy moves to the Trash goes to the real
  Trash.

## Releasing

Set `CFBundleShortVersionString` in `Support/Info.plist`, commit, then tag that commit
`v<version>` and push the tag. [.github/workflows/release.yml](../.github/workflows/release.yml)
refuses a tag that differs from the plist, runs the core and command tests, builds with
`scripts/build-app.sh`, attests the archive's provenance and attaches
`Marko-<version>-macos-arm64.zip` with its checksum to a GitHub Release. A pushed tag and a
published release cannot be changed afterwards, so after a change to the workflow run it by
hand first (`gh workflow run release.yml`), which does everything but publish. The editor tests and the smoke run are not part of it: run them before tagging.

## Conventions

- Swift 6 language mode. Isolation per target as in
  [architecture.md](architecture.md#targets); observers on `@MainActor` `NSObject` subclasses use
  selectors, not `@Sendable` closures.
- Comments are `///` full sentences that say why. A fact established by experiment starts with
  `MEASURED:`; do not simplify the code beside one without measuring again. No commented-out code.
- Every visual constant goes in `Theme.swift`.
- Menus and shortcuts are defined in `Sources/MarkoApp/MainMenu.swift` and in `formatItems` in
  `Sources/MarkoEditor/EditorTextView.swift`; the README's shortcut table follows both. The
  `--help` text is `Command.usage`.
- Dependencies: swift-markdown `exact: "0.9.0"` and nothing else. If `Package.resolved` changes,
  renew `THIRD-PARTY-NOTICES.txt` and run the fuzz.
- Commits: one subject line in sentence case that says what changed.

## Repository map

- `Sources/`, `Tests/` – see [architecture.md](architecture.md#where-things-live).
- `Support/Info.plist` – bundle identifier `local.marko`, version, document types.
- `scripts/` – `build-app.sh`, `install-cli.sh`, `smoke.sh`, `smoke-cli.sh`, `snapshot.sh`,
  `make-icon.swift`, `drive/`, `perf/`.
- `build/` – output, ignored by git.
- `docs/` – see [docs/README.md](README.md).
