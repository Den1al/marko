import AppKit
import MarkoCore
import Testing
@testable import MarkoEditor

extension EditorTests {
    @Suite struct FormatTests {
        private let theme = Theme.standard

        nonisolated struct Case: CustomTestStringConvertible, Sendable {
            var title: String
            var text: String
            var location: Int
            var length = 0
            var result: String
            var toggles = true
            var testDescription: String { title }
        }

        nonisolated static let cases = [
            Case(title: "Bold", text: "a word b\n", location: 2, length: 4, result: "a **word** b\n"),
            Case(title: "Italic", text: "a word b\n", location: 2, length: 4, result: "a *word* b\n"),
            Case(title: "Strikethrough", text: "a word b\n", location: 2, length: 4, result: "a ~~word~~ b\n"),
            Case(title: "Inline Code", text: "a word b\n", location: 2, length: 4, result: "a `word` b\n"),
            Case(title: "Link", text: "a word b\n", location: 2, length: 4, result: "a [word]() b\n"),
            Case(title: "Image", text: "a word b\n", location: 2, length: 4, result: "a ![word]() b\n"),
            Case(title: "Bold", text: "a word b\n", location: 4, result: "a **word** b\n"),
            // An empty pair is not yet emphasis to the parser; FormatCommandsTests has it going off again.
            Case(title: "Italic", text: "", location: 0, result: "**", toggles: false),
            Case(title: "Heading 1", text: "Title\n", location: 2, result: "# Title\n"),
            Case(title: "Heading 2", text: "Title\n", location: 2, result: "## Title\n"),
            Case(title: "Heading 3", text: "Title\n", location: 2, result: "### Title\n"),
            Case(title: "Heading 4", text: "Title\n", location: 2, result: "#### Title\n"),
            Case(title: "Heading 5", text: "Title\n", location: 2, result: "##### Title\n"),
            Case(title: "Heading 6", text: "", location: 0, result: "###### "),
            Case(title: "Paragraph", text: "## Title\n", location: 5, result: "Title\n", toggles: false),
            Case(title: "Increase Heading Level", text: "## Title\n", location: 5, result: "# Title\n", toggles: false),
            Case(title: "Decrease Heading Level", text: "## Title\n", location: 5, result: "### Title\n", toggles: false),
            Case(title: "Bullet List", text: "one\ntwo\n", location: 1, length: 5, result: "- one\n- two\n"),
            Case(title: "Ordered List", text: "one\ntwo\n", location: 1, length: 5, result: "1. one\n2. two\n"),
            Case(title: "Task List", text: "one\n", location: 1, result: "- [ ] one\n"),
            Case(title: "Quote", text: "one\n\ntwo\n", location: 1, length: 6, result: "> one\n>\n> two\n"),
            Case(title: "Code Block", text: "let a = 1\n", location: 3, result: "```\nlet a = 1\n```\n"),
            Case(title: "Horizontal Rule", text: "one\n", location: 2, result: "one\n\n---\n\n", toggles: false),
            Case(title: "Insert Table", text: "", location: 0, result: "|   |   |   |\n|---|---|---|\n|   |   |   |\n|   |   |   |", toggles: false),
        ]

        @Test(arguments: cases) func everyCommandIsOneUndoStepAndTogglesOffWhenChosenAgain(_ test: Case) throws {
            let w = EditorWindow(test.text)
            defer { w.close() }
            let undo = try #require(w.textView.undoManager)
            w.select(test.location, length: test.length)
            w.pump()
            let before = w.chooseFormat(test.title, perform: false)
            #expect(before.isEnabled && !before.isOn)

            w.chooseFormat(test.title)
            #expect(w.textView.string == test.result)
            #expect(w.storageProblem == nil && w.textView.textLayoutManager != nil)
            let selection = w.textView.selectedRange()
            undo.undo()
            w.pump()
            #expect(w.textView.string == test.text, "one undo takes it back")
            #expect(!undo.canUndo)
            undo.redo()
            w.pump()
            #expect(w.textView.string == test.result)

            guard test.toggles else { return }
            w.textView.setSelectedRange(selection)
            w.pump()
            #expect(w.chooseFormat(test.title, perform: false).isOn, "the menu shows it as on")
            w.chooseFormat(test.title)
            #expect(w.textView.string == test.text, "chosen again it is off")
            undo.undo()
            w.pump()
            #expect(w.textView.string == test.result, "which is one undo step too")
        }

        @Test func commandsShowLiveLikeTypedMarkdown() {
            let w = EditorWindow("Title\n\nsome words here\n")
            defer { w.close() }
            w.select(2)
            w.chooseFormat("Heading 2")
            #expect(w.displayFont(at: 3).pointSize == theme.headingSizes[1])
            w.select(w.offset(of: "words"), length: 5)
            w.chooseFormat("Bold")
            #expect(w.displayFont(at: w.offset(of: "words")).fontDescriptor.symbolicTraits.contains(.bold))
            #expect(w.textView.selectedRange() == NSRange(location: w.offset(of: "words"), length: 5), "the words stay selected")
            w.chooseFormat("Link")
            #expect(w.textView.string == "## Title\n\nsome **[words]()** here\n")
            #expect(w.textView.selectedRange() == NSRange(location: w.offset(of: "()") + 1, length: 0), "the caret is where the URL goes")
            w.type("https://example.com")
            #expect(w.textView.string == "## Title\n\nsome **[words](https://example.com)** here\n")
        }

        @Test func theMenuHasTheStandardShortcutsAndTheTableSubmenu() throws {
            let menu = EditorTextView.formatMenu()
            func shortcut(_ title: String) -> String? {
                menu.item(withTitle: title).map { item in
                    let flags = item.keyEquivalentModifierMask
                    return (flags.contains(.control) ? "^" : "") + (flags.contains(.option) ? "~" : "") + (flags.contains(.shift) ? "$" : "")
                        + (flags.contains(.command) ? "@" : "") + item.keyEquivalent
                }
            }
            #expect(shortcut("Bold") == "$@b" && shortcut("Italic") == "@i" && shortcut("Link") == "@k")
            #expect((1...6).allSatisfy { shortcut("Heading \($0)") == "@\($0)" } && shortcut("Paragraph") == "@0")
            for title in ["Strikethrough", "Inline Code", "Image", "Increase Heading Level", "Decrease Heading Level", "Bullet List",
                          "Ordered List", "Task List", "Quote", "Code Block", "Horizontal Rule", "Insert Table"] {
                #expect(shortcut(title)?.isEmpty == false, "\(title)")
            }
            let shortcuts = menu.items.filter { !$0.keyEquivalent.isEmpty }.map { "\($0.keyEquivalentModifierMask.rawValue)\($0.keyEquivalent)" }
            #expect(Set(shortcuts).count == shortcuts.count, "no shortcut is used twice")
            let table = try #require(menu.item(withTitle: "Table")?.submenu)
            #expect(table.items.count { !$0.isSeparatorItem } == 10)
        }

        @Test func theMenuReflectsTheSelection() {
            let w = EditorWindow("# Head\n\nplain **bold *both*** `code`\n\n- [ ] task\n\n> quote\n\n```\ncode\n```\n")
            defer { w.close() }
            func on(_ titles: [String], at text: String) -> Bool {
                w.select(w.offset(of: text) + 1)
                w.pump()
                let all = ["Bold", "Italic", "Strikethrough", "Inline Code", "Link", "Heading 1", "Heading 2", "Paragraph",
                           "Bullet List", "Ordered List", "Task List", "Quote", "Code Block"]
                return all.allSatisfy { w.chooseFormat($0, perform: false).isOn == titles.contains($0) }
            }
            #expect(on(["Heading 1"], at: "Head"))
            #expect(on(["Paragraph"], at: "plain"))
            #expect(on(["Paragraph", "Bold"], at: "bold"))
            #expect(on(["Paragraph", "Bold", "Italic"], at: "both"))
            #expect(on(["Paragraph", "Inline Code"], at: "code`"))
            #expect(on(["Paragraph", "Task List"], at: "task"))
            #expect(on(["Paragraph", "Quote"], at: "quote"))
            #expect(on(["Code Block"], at: "code\n```"))
            // In code the inline commands and the headings do not apply; the code block can be taken off.
            #expect(!w.chooseFormat("Bold", perform: false).isEnabled && !w.chooseFormat("Heading 1", perform: false).isEnabled)
            #expect(w.chooseFormat("Code Block", perform: false).isEnabled)
            #expect(!w.chooseFormat("Paragraph", perform: false).isEnabled || w.textView.string.isEmpty)
            #expect(w.textView.string.hasPrefix("# Head\n\nplain"), "asking changes nothing")
        }

        @Test func commandsThatWouldOnlyAddLiteralMarkersAreDisabled() {
            let source = "# Title\n\n- one\n- two\n\na `code` and [link](http://my_site.example/path)\n\n- [ ] task\n\n| a | b |\n|---|---|\n| c | d |\n"
            let w = EditorWindow(source)
            defer { w.close() }
            func isEnabled(_ title: String, _ location: Int, _ length: Int = 0) -> Bool {
                w.select(location, length: length)
                w.pump()
                return w.chooseFormat(title, perform: false).isEnabled
            }
            let items = w.offset(of: "one"), code = w.offset(of: "code"), host = w.offset(of: "my_site"), task = w.offset(of: "task")
            for title in ["Bold", "Italic", "Strikethrough", "Inline Code"] {
                #expect(!isEnabled(title, items, 9), "\(title) over two list items")
                #expect(!isEnabled(title, w.offset(of: "c | d"), 5), "\(title) over two cells")
                #expect(!isEnabled(title, host + 3), "\(title) in a link's destination")
                #expect(isEnabled(title, items, 3) && isEnabled(title, w.offset(of: "c |"), 1))
            }
            #expect(!isEnabled("Bold", code + 2) && !isEnabled("Link", code + 2) && isEnabled("Inline Code", code + 2))
            #expect(!isEnabled("Heading 1", task + 1) && !isEnabled("Increase Heading Level", task + 1) && !isEnabled("Code Block", task + 1))
            #expect(!isEnabled("Code Block", items, 9) && isEnabled("Task List", task + 1))
            // A marker typed over a selection there replaces it, and a pasted URL is pasted.
            w.select(host, length: 2)
            w.type("_")
            #expect(w.textView.string.contains("(http://__site.example/path)"))
            w.undoAll()
            w.select(code, length: 4)
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            pasteboard.setString("https://x.y", forType: .string)
            #expect(w.textView.readSelection(from: pasteboard, type: .string))
            #expect(w.textView.string.contains("a `https://x.y` and"))
            w.undoAll()
            // The whole heading line, as a triple click selects it: the marker stays outside.
            w.select(0, length: 8)
            w.chooseFormat("Bold")
            #expect(w.textView.string.hasPrefix("# **Title**\n") && w.chooseFormat("Bold", perform: false).isOn)
            #expect(MarkdownStyler.style(w.textView.string).lines[0].kind == .heading(level: 1))
            w.chooseFormat("Bold")
            #expect(w.textView.string == source)
        }

        // MARK: typing and pasting

        @Test func aMarkerTypedOverASelectionWrapsIt() throws {
            let w = EditorWindow("a word b\n")
            defer { w.close() }
            let undo = try #require(w.textView.undoManager)
            for (marker, result) in [("*", "a *word* b\n"), ("_", "a _word_ b\n"), ("`", "a `word` b\n"), ("~", "a ~word~ b\n")] {
                w.select(2, length: 4)
                w.type(marker)
                #expect(w.textView.string == result)
                #expect(w.textView.selectedRange() == NSRange(location: 3, length: 4), "the text stays selected")
                undo.undo()
                w.pump()
                #expect(w.textView.string == "a word b\n")
            }
            w.select(2, length: 4)
            w.type("**")
            #expect(w.textView.string == "a **word** b\n")
            #expect(w.displayFont(at: 5).fontDescriptor.symbolicTraits.contains(.bold))

            // Anything else typed replaces the selection, and a marker without a selection is just typed.
            w.type("x")
            #expect(w.textView.string == "a **x** b\n")
            w.select(0)
            w.type("*")
            #expect(w.textView.string == "*a **x** b\n")
        }

        @Test func aURLPastedOverASelectionMakesALink() {
            let w = EditorWindow("see this page now\n")
            defer { w.close() }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString("https://example.com/a", forType: .string)

            w.select(4, length: 9)
            #expect(w.textView.readSelection(from: pasteboard, type: .string))
            w.pump()
            #expect(w.textView.string == "see [this page](https://example.com/a) now\n")
            #expect(w.textView.selectedRange() == NSRange(location: 38, length: 0))
            #expect(w.displayAttributes(at: 6)[.foregroundColor] as? NSColor == theme.link)
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == "see this page now\n", "one undo step")

            // With a caret it is pasted as it is, and other text replaces the selection as always.
            w.select(0)
            #expect(w.textView.readSelection(from: pasteboard, type: .string))
            #expect(w.textView.string == "https://example.com/asee this page now\n")
            pasteboard.clearContents()
            pasteboard.setString("that", forType: .string)
            w.select(w.offset(of: "this"), length: 4)
            #expect(w.textView.readSelection(from: pasteboard, type: .string))
            #expect(w.textView.string == "https://example.com/asee that page now\n")
        }

        // MARK: large documents

        /// A reference to a link defined elsewhere can only be read with the whole text, and a text of
        /// this size is only parsed whole when the typing pauses or a key needs the map.
        private let large = String(repeating: "some words in a line of [ref] text\n\n", count: 4000) + "[ref]: /url\n"

        @Test func inALargeDocumentAHeldBackspaceDoesNotParseButACommandKeyDoes() {
            #expect((large as NSString).length > EditorController.synchronousParseLimit)
            let w = EditorWindow(large)
            defer { w.close() }
            // A line shows raw while the map is behind the text.
            func isBehind() -> Bool { w.displayAttributes(at: 0)[.glyphLift] == nil }
            #expect(!isBehind())
            w.select(15)
            w.type(" new")
            #expect(isBehind(), "typing waits for a pause")
            w.type(String(repeating: EditorWindow.backspace, count: 2))
            #expect(w.textView.string.hasPrefix("some words in a n line"))
            #expect(isBehind(), "and so does deleting")
            w.type(String(EditorWindow.backspace))
            w.command(#selector(NSResponder.deleteForward(_:)))
            #expect(w.textView.string.hasPrefix("some words in a line"))
            #expect(isBehind())

            w.type("x ")
            #expect(isBehind())
            w.command(#selector(NSResponder.moveLeft(_:)))
            #expect(!isBehind(), "a key that needs the map brings it up to date")
            #expect(w.textView.selectedRange() == NSRange(location: 17, length: 0))
        }

        /// A line that waits for its parse shows raw, and its text stands where it stood: lifted
        /// to the middle of its line like a paragraph's.
        @Test func inALargeDocumentALineThatWaitsForItsParseStandsWhereItStood() throws {
            let w = EditorWindow(large)
            defer { w.close() }
            /// The pixel rows of the first line that have ink in its first words. Drawn here and
            /// now: the run loop would bring the parse.
            func ink() throws -> ClosedRange<Int> {
                let bitmap = try #require(w.textView.bitmapImageRepForCachingDisplay(in: w.textView.bounds))
                w.textView.cacheDisplay(in: w.textView.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / w.textView.bounds.width, origin = w.textView.textContainerOrigin
                let page = bitmap.colorAt(x: 2, y: 2), left = Int(origin.x * scale), top = Int(origin.y * scale)
                let rows = (top..<top + Int(w.fragment(at: 0).layoutFragmentFrame.height * scale)).filter { y in
                    (left..<left + Int(60 * scale)).contains { bitmap.colorAt(x: $0, y: y) != page }
                }
                return try #require(rows.first)...(try #require(rows.last))
            }
            let rendered = try ink()
            w.select(15)
            w.type(" new")
            #expect(w.displayAttributes(at: 0)[.glyphLift] == nil, "the line shows raw")
            let raw = try ink()
            #expect(raw == rendered)
            #expect(w.displayAttributes(at: 0)[.glyphLift] == nil, "and still does in what was compared")
        }

        @Test func aLargeDocumentWithoutDefinitionsIsParsedOnEveryKey() {
            let w = EditorWindow("x- item\n\n" + String(repeating: "some words in a line of text\n\n", count: 4000))
            defer { w.close() }
            #expect(w.length > EditorController.synchronousParseLimit)
            w.select(1)
            w.type(String(EditorWindow.backspace))
            #expect(w.textView.selectedRange() == NSRange(location: 2, length: 0), "the caret is behind the marker at once")
            #expect(w.displayParagraph(at: 0).text.string.hasPrefix(theme.bullets[0]))
            w.type("**b**")
            #expect(w.displayAttributes(at: 0)[.glyphLift] != nil && w.displayFont(at: 4).fontDescriptor.symbolicTraits.contains(.bold))
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.displayAttributes(at: 0)[.glyphLift] != nil && w.storageProblem == nil)
        }

        /// A block as long as a large text is not parsed on every key (MEASURED: 90 ms a key in a
        /// list of 16,000 items); it waits for the pause like any edit that needs the whole text.
        /// A key in the text of an item that is one line is parsed with that line alone.
        @Test func aLargeDocumentThatIsOneBlockIsParsedInThePause() {
            let w = EditorWindow("# List\n\n" + String(repeating: "- an item of a long list\n", count: 5000))
            defer { w.close() }
            #expect(w.length > EditorController.synchronousParseLimit)
            let item = w.offset(of: "- an item") + 2
            w.select(item)
            w.type("**b**")
            #expect(w.displayAttributes(at: item)[.glyphLift] != nil && w.displayFont(at: item + 2).fontDescriptor.symbolicTraits.contains(.bold),
                    "the item's own text is styled at once")
            w.type("\r")
            let below = w.textView.selectedRange().location
            #expect(w.displayAttributes(at: below)[.glyphLift] == nil, "a new line is the list's business: it shows raw until the parse")
            w.pump(EditorController.parseDelay + 0.3)
            #expect(w.displayAttributes(at: below)[.glyphLift] != nil && w.displayFont(at: item + 2).fontDescriptor.symbolicTraits.contains(.bold))
            #expect(w.storageProblem == nil)
        }

        @Test func inALargeDocumentBackspaceAtTheMarkersStillFollowsTheRules() {
            let w = EditorWindow("- item\n\n| a | b |\n|---|---|\n| c | d |\n\n" + large)
            defer { w.close() }
            w.select(6)
            w.type("s")
            w.select(2)
            w.type(String(EditorWindow.backspace))
            #expect(w.textView.string.hasPrefix("items\n\n| a |"), "the list marker goes, not one character of it")
            let cell = w.offset(of: "c |")
            w.select(cell + 1)
            w.type("x")
            w.select(cell - 1)
            w.type(String(EditorWindow.backspace))
            #expect(w.textView.string.contains("\n| cx | d |\n"), "and a pipe stays")
        }

        @Test func afterTheDeferredParseTheCaretIsNotLeftAmongMarkers() {
            let w = EditorWindow("x- item [ref]\n\n" + large)
            defer { w.close() }
            w.select(1)
            w.type(String(EditorWindow.backspace))
            #expect(w.textView.string.hasPrefix("- item [ref]\n") && w.textView.selectedRange().location == 0)
            w.pump(EditorController.parseDelay + 0.3)
            #expect(w.textView.selectedRange() == NSRange(location: 2, length: 0))
            #expect(w.displayParagraph(at: 0).text.string.hasPrefix(theme.bullets[0]), "the marker is a bullet again, with the caret behind it")
        }

        @Test func inALargeDocumentTheDeferredParseWaitsForAnInputMethod() {
            let w = EditorWindow("**b** tail\n\n" + large)
            defer { w.close() }
            w.select(11)
            w.textView.setMarkedText("zz", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 11, length: 0))
            let marked = w.textView.markedRange(), selection = w.textView.selectedRange()
            #expect(marked == NSRange(location: 11, length: 2) && selection == NSRange(location: 12, length: 0))
            // The pause in which a candidate is chosen is longer than the parse delay.
            w.pump(2 * EditorController.parseDelay + 0.3)
            #expect(w.textView.hasMarkedText() && w.textView.markedRange() == marked && w.textView.selectedRange() == selection)
            #expect(w.displayAttributes(at: 0)[.glyphLift] == nil, "nothing was parsed meanwhile: the edited text still shows raw")
            // A menu command leaves the composition alone as well.
            #expect(!w.chooseFormat("Bold").isEnabled)
            #expect(w.textView.markedRange() == marked && w.displayAttributes(at: 0)[.glyphLift] == nil)
            w.textView.insertText("done", replacementRange: w.textView.markedRange())
            w.pump(EditorController.parseDelay + 0.3)
            #expect(!w.textView.hasMarkedText() && w.textView.string.hasPrefix("**b** tail\ndone\n"))
            #expect(w.displayAttributes(at: 0)[.glyphLift] != nil && w.isHidden(0), "the commit is parsed after its own pause")
        }

        // MARK: view settings

        @Test func zoomScalesThePageThroughTheTheme() {
            let w = EditorWindow("# Head\n\ntext **bold**\n\n- item\n\n| a | b |\n|---|---|\n| c | d |\n", size: NSSize(width: 1400, height: 600))
            defer {
                Theme.zoom = 1
                w.close()
            }
            w.select(w.length)
            w.pump()
            let text = w.offset(of: "text"), column = w.textView.columnWidth
            #expect(theme.bodySize == 16 && column == 780)
            func grid() -> CGFloat { (w.fragment(at: w.offset(of: "| c")) as? BlockFragment)?.tableRowRect?.width ?? 0 }
            let height = w.fragment(at: text).layoutFragmentFrame.height, table = grid()

            Theme.zoom = 1.5
            w.pump()
            #expect(theme.bodySize == 24 && theme.bodyLineHeight == 39)
            #expect(w.displayFont(at: text).pointSize == 24 && w.displayFont(at: 3).pointSize == 45)
            #expect(w.fragment(at: text).layoutFragmentFrame.height == 39 && height == 26)
            #expect(w.textView.columnWidth == 1170, "the column grows with the text")
            #expect(table > 0 && grid() > table * 1.3, "measured widths are measured again")
            #expect(w.storageProblem == nil, "the storage keeps nothing but the base attributes, at the new size")
            w.type("typed")
            #expect(w.storageProblem == nil && w.textView.string.hasSuffix("| c | d |\n\ntyped"))

            Theme.zoom = 9
            #expect(Theme.zoom == 2, "clamped to the steps")
            Theme.zoom = 1
            w.pump()
            #expect(w.displayFont(at: text).pointSize == 16 && w.fragment(at: text).layoutFragmentFrame.height == 26)
            #expect(w.textView.columnWidth == 780 && w.storageProblem == nil)
            #expect(w.textView.textLayoutManager != nil)
        }

        @Test func theWordCountCanBeHidden() async throws {
            let w = EditorWindow("one two\n")
            defer {
                Theme.showsWordCount = true
                w.close()
            }
            let count = w.editor.wordCount
            #expect(await wait { count.stringValue == "2 words" } && !count.isHidden)
            Theme.showsWordCount = false
            #expect(count.isHidden)
            #expect(EditorController().wordCount.isHidden, "a window opened later follows")
            Theme.showsWordCount = true
            #expect(!count.isHidden)
        }
    }
}
