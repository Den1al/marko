import AppKit
import MarkoCore
import Testing
@testable import MarkoEditor

extension EditorTests {
    /// Regression tests: icons of a terminal prompt, Tab and Shift-Tab in lists,
    /// indentation in code blocks, and tables that use the window's width.
    @Suite struct FeedbackTests {
        private let theme = Theme.standard

        // MARK: icons

        private static let icons = "A \u{F179} \u{F07C} \u{F017} and \u{276F} and \u{F8FF}.\n\nInline `\u{F179} ls` code.\n\n```sh\n\u{F179}\u{F07C} ~/x \u{F017}\nab cd ef gh ij\n```\n"

        /// With `families` as the installed icon fonts for the life of the window.
        private func window(_ text: String, families: [String], size: NSSize = NSSize(width: 900, height: 600)) -> (EditorWindow, restore: () -> Void) {
            let installed = IconFont.families
            IconFont.families = families
            return (EditorWindow(text, size: size), { IconFont.families = installed })
        }

        @Test func charactersOnlyAnIconFontDrawsAreSetInOne() throws {
            // Menlo stands in for a Nerd Font: it is on every Mac, and which font it is does not matter here.
            let (w, restore) = window(Self.icons, families: ["Menlo"])
            defer {
                w.close()
                restore()
            }
            let text = w.textView.string as NSString
            let body = text.range(of: "\u{F179}").location, inline = text.range(of: "`\u{F179}").location + 1, code = text.range(of: "\u{F179}\u{F07C}").location
            for icon in [body, body + 2, body + 4, inline, code, code + 1, code + 7] {
                #expect(w.displayFont(at: icon).familyName == "Menlo", "\(icon)")
            }
            // As large as the text beside it, and in code as wide as the code's characters.
            #expect(w.displayFont(at: body).pointSize == theme.bodySize)
            let codeFont = theme.codeFont(size: theme.codeBlockFontSize)
            #expect(abs(w.displayFont(at: code).maximumAdvancement.width - codeFont.maximumAdvancement.width) < 0.01)
            // Nothing else is: the text around them, a character the system's fonts draw, hidden markers.
            #expect(w.displayFont(at: 0) == theme.bodyFont && w.displayFont(at: body + 1) == theme.bodyFont)
            #expect(w.displayFont(at: text.range(of: "\u{276F}").location) == theme.bodyFont)
            #expect(w.displayFont(at: text.range(of: "\u{F8FF}").location) == theme.bodyFont, "the system has a glyph for this one")
            #expect(w.displayFont(at: inline - 1) == theme.inlineCodeEdgeFont && w.displayFont(at: inline + 1).familyName != "Menlo")
            #expect(w.displayFont(at: code + 2) == codeFont)
            // Every line and the code's panel are as they are with letters in the icons' places.
            let letters = EditorWindow(Self.icons.replacingOccurrences(of: "\u{F179}", with: "x").replacingOccurrences(of: "\u{F07C}", with: "y")
                .replacingOccurrences(of: "\u{F017}", with: "z"))
            defer { letters.close() }
            for line in MarkdownStyler.style(w.textView.string).lines where line.range.length > 0 {
                let frame = w.fragment(at: line.range.location).layoutFragmentFrame, other = letters.fragment(at: line.range.location)
                #expect(frame.height == other.layoutFragmentFrame.height && frame.minY == other.layoutFragmentFrame.minY, "\(line.range)")
                #expect((w.fragment(at: line.range.location) as? BlockFragment)?.codePanelRect == (other as? BlockFragment)?.codePanelRect)
            }
            #expect(w.storageProblem == nil, "the storage keeps its one font")
        }

        @Test func withoutAnIconFontNothingChanges() {
            let (w, restore) = window(Self.icons, families: [])
            defer {
                w.close()
                restore()
            }
            let text = w.textView.string as NSString, code = text.range(of: "\u{F179}\u{F07C}").location
            #expect(w.displayFont(at: text.range(of: "\u{F179}").location) == theme.bodyFont)
            #expect(w.displayFont(at: code) == theme.codeFont(size: theme.codeBlockFontSize) && w.displayFont(at: code + 1) == w.displayFont(at: code + 2))
            #expect(w.fragment(at: 0).layoutFragmentFrame.height == theme.bodyLineHeight)
        }

        @Test func theVariantOfTheIconFontGoesByTheTextAroundIt() {
            let installed = IconFont.families
            defer { IconFont.families = installed }
            IconFont.families = ["A Nerd Font", "A Nerd Font Mono", "A Nerd Font Propo", "B Nerd Font Mono"]
            #expect(IconFont.family(forCode: true) == "A Nerd Font Mono" && IconFont.family(forCode: false) == "A Nerd Font Propo")
            IconFont.families = ["A Nerd Font", "B Nerd Font Mono"]
            #expect(IconFont.family(forCode: true) == "B Nerd Font Mono" && IconFont.family(forCode: false) == "B Nerd Font Mono")
            IconFont.families = ["A Nerd Font"]
            #expect(IconFont.family(forCode: true) == "A Nerd Font" && IconFont.family(forCode: false) == "A Nerd Font")
            IconFont.families = ["Menlo"]
            #expect(IconFont.font(for: "\u{F179}", inPlaceOf: theme.bodyFont)?.familyName == "Menlo")
            #expect(IconFont.font(for: "a", inPlaceOf: theme.bodyFont) == nil, "a character the font has")
            #expect(IconFont.font(for: "\u{F8FF}", inPlaceOf: theme.bodyFont) == nil, "a character the system draws")
            IconFont.families = []
            #expect(IconFont.font(for: "\u{F179}", inPlaceOf: theme.bodyFont) == nil)
        }

        /// With the fonts that are installed: where a Nerd Font is among them, the columns of a code block hold.
        @Test func iconsInCodeKeepTheColumnsWhereANerdFontIsInstalled() throws {
            guard IconFont.families.contains(where: { $0.hasSuffix("Nerd Font Mono") }) else { return }
            let w = EditorWindow("```\n\u{F179}\u{F07C}ab\u{F017}cd\nwxyz1234\n```\n")
            defer { w.close() }
            #expect(w.displayFont(at: 4).familyName?.hasSuffix("Nerd Font Mono") == true)
            for column in 0..<8 {
                #expect(abs(w.characterRect(at: 4 + column).minX - w.characterRect(at: 12 + column).minX) < 0.05, "column \(column)")
            }
        }

        /// The icons above U+F0000 (the Material Design ones). MEASURED: the system finds those in
        /// an installed Nerd Font by itself, in a variant and at a size of its own choosing.
        @Test func anIconTheSystemFindsInANerdFontIsSetLikeTheOthers() throws {
            guard let mono = IconFont.families.first(where: { $0.hasSuffix("Nerd Font Mono") }) else { return }
            let w = EditorWindow("Body \u{F0001} end.\n\n```\n\u{F0001}\u{F179}ab\u{F0001}cd\nwxyz1234\n```\n")
            defer { w.close() }
            let text = w.textView.string as NSString, code = text.range(of: "```\n").location + 4
            #expect(w.displayFont(at: code).familyName == mono && w.displayFont(at: code) == w.displayFont(at: code + 2))
            #expect(w.displayFont(at: 5).familyName == IconFont.family(forCode: false))
            // The character is two units of the text; the columns hold on both sides of it.
            let first = [0, 2, 3, 4, 5, 7, 8].map { w.characterRect(at: code + $0).minX }, second = [0, 1, 2, 3, 4, 5, 6].map { w.characterRect(at: code + 10 + $0).minX }
            #expect(zip(first, second).allSatisfy { abs($0 - $1) < 0.05 }, "\(first) \(second)")
        }

        @Test func theIconFontsAreLookedUpAgainWhenFontsAreInstalledOrRemoved() {
            let (w, restore) = window("An icon \u{F179} here.\n", families: ["Menlo"])
            defer {
                w.close()
                restore()
            }
            let icon = w.offset(of: "\u{F179}")
            #expect(w.displayFont(at: icon).familyName == "Menlo")
            NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
            #expect(!IconFont.families.contains("Menlo") && IconFont.families.allSatisfy { $0.contains("Nerd Font") }, "what is installed")
            #expect(w.displayFont(at: icon).familyName != "Menlo", "and the text shows it")
            #expect(w.displayFont(at: icon).familyName == (IconFont.families.isEmpty ? theme.bodyFont.familyName : IconFont.family(forCode: false)))
        }

        @Test func anIconInATableCellIsMeasuredAsItShows() throws {
            let (w, restore) = window("| a | b |\n|---|---|\n| \u{F179}\u{F179}\u{F179}\u{F179} | y |\n\nend", families: ["Menlo"])
            defer {
                w.close()
                restore()
            }
            let cell = w.offset(of: "\u{F179}")
            let row = try #require(w.displayAttributes(at: cell)[.tableRow] as? TableRow)
            #expect(w.displayFont(at: cell).familyName == "Menlo")
            #expect(w.characterRect(at: cell + 3).maxX - w.textView.columnLeft <= row.edges[1] - theme.tableCellPadding.width + 0.5, "the column is as wide as the icons")
        }

        // MARK: Tab and Shift-Tab in lists

        private let backtab = String(EditorWindow.backtab)

        /// Shift-Tab on the empty item after a bullet did nothing; only a second Return left the list.
        @Test func shiftTabOnTheEmptyItemAfterABulletLeavesTheListInOneUndoStep() {
            let w = EditorWindow()
            defer { w.close() }
            w.type("- one\r")
            #expect(w.textView.string == "- one\n- ")
            w.type(backtab)
            #expect(w.textView.string == "- one\n\n" && w.textView.selectedRange() == NSRange(location: 7, length: 0))
            #expect(w.displayAttributes(at: 0)[.glyphLift] != nil && w.paintProblem == nil)
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == "- one\n- ")
        }

        /// Return, then Tab: the marker stands alone below the text of the item before, which the
        /// parser reads as that text's underline. The keys take it for the item it will be.
        @Test func tabAndShiftTabWorkOnAnItemThatHasNoTextYet() {
            for (first, nested, second) in [("- one", "  - ", "- "), ("* one", "  * ", "* "), ("1. one", "   1. ", "2. "), ("> - one", ">   - ", "> - ")] {
                let w = EditorWindow()
                defer { w.close() }
                w.type(first + "\r\t")
                #expect(w.textView.string == first + "\n" + nested, "Tab nests the empty item")
                w.type(backtab)
                #expect(w.textView.string == first + "\n" + second, "and Shift-Tab takes it back")
                w.type("\ttwo")
                #expect(w.textView.string == first + "\n" + nested + "two")
                #expect(MarkdownStyler.style(w.textView.string).lines[1].listDepth == 2 && w.paintProblem == nil)
                w.type(backtab)
                #expect(w.textView.string == first + "\n" + second + "two", "right after its text was typed")
                w.type("\t\r")
                #expect(w.textView.string.hasSuffix(nested + "two\n" + nested.replacingOccurrences(of: "1.", with: "2.")))
                w.type(backtab)
                #expect(w.textView.string.hasSuffix("two\n" + second), "an empty nested item")
                w.undoAll()
                #expect(w.textView.string == "" && w.storageProblem == nil)
            }
        }

        /// The first nested item is the one the parser does not know; Return and Backspace on it
        /// do what they do on every later one.
        @Test func returnAndBackspaceOnTheEmptyItemThatTabNestedMoveItOutAgain() {
            for key in ["\r", String(EditorWindow.backspace)] {
                let w = EditorWindow()
                defer { w.close() }
                w.type("- one\r\t")
                #expect(w.textView.string == "- one\n  - ")
                w.type(key)
                #expect(w.textView.string == "- one\n- " && w.textView.selectedRange() == NSRange(location: 8, length: 0))
                #expect(w.displayAttributes(at: 0)[.hairline] == nil && w.paintProblem == nil, "and the item above is no heading any more")
                w.textView.undoManager?.undo()
                w.pump()
                #expect(w.textView.string == "- one\n  - ", "one undo step")
                w.type("two\r" + key)
                #expect(w.textView.string == "- one\n  - two\n- ", "as from the second nested item on")
            }
        }

        @Test func aNumberThatGetsLongerOnShiftTabTakesWhatIsNestedInItsItemAlong() {
            let items = (1...9).map { "\($0). a\n" }.joined()
            let w = EditorWindow(items + "   1. b\n      - c\n")
            defer { w.close() }
            w.select(w.offset(of: "b"))
            w.type(backtab)
            #expect(w.textView.string == items + "10. b\n    - c\n")
            #expect(MarkdownStyler.style(w.textView.string).lines.suffix(2).map(\.listDepth) == [1, 2] && w.paintProblem == nil)
            w.type("\t")
            #expect(w.textView.string == items + "   1. b\n      - c\n")
            w.undoAll()
            #expect(w.textView.string == items + "   1. b\n      - c\n" && w.storageProblem == nil)
        }

        @Test func tabAndShiftTabMoveEverySelectedItemInOneUndoStep() {
            let source = "- one\n- two\n  continued\n- [ ] three\n1. four\n"
            let w = EditorWindow(source)
            defer { w.close() }
            w.select(w.offset(of: "wo"), length: w.offset(of: "hree") - w.offset(of: "wo"))
            w.type("\t")
            #expect(w.textView.string == "- one\n  - two\n    continued\n  - [ ] three\n1. four\n")
            #expect((w.textView.string as NSString).substring(with: w.textView.selectedRange()) == "wo\n    continued\n  - [ ] t", "the selection keeps its text")
            #expect(abs(w.columnX(at: w.offset(of: "two")) - 2 * theme.listIndent) < 0.5 && abs(w.columnX(at: w.offset(of: "three")) - 2 * theme.listIndent) < 0.5)
            w.type(backtab)
            #expect(w.textView.string == source)
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == "- one\n  - two\n    continued\n  - [ ] three\n1. four\n", "one step")
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == source && w.storageProblem == nil)
            // From a line of the item that is not its first, and on the list's first and last items.
            w.select(w.offset(of: "continued") + 3)
            w.type("\t")
            #expect(w.textView.string.hasPrefix("- one\n  - two\n    continued\n- [ ]"))
            w.type(backtab)
            w.select(2)
            w.type("\t")
            w.type(backtab)
            #expect(w.textView.string == source, "the first item has nothing to go under or out to, and Tab types no tab")
            w.select(w.length - 1)
            w.type("\t")
            #expect(w.textView.string == "- one\n- two\n  continued\n- [ ] three\n  1. four\n", "a numbered item starts its list with 1")
        }

        @Test func shiftTabWorksRightAfterTypingInALargeDocumentWhoseParseWaits() {
            let large = String(repeating: "some words in a line of [ref] text\n\n", count: 4000) + "[ref]: /url\n"
            let w = EditorWindow("- one\n  - two [ref]\n\n" + large)
            defer { w.close() }
            w.select(w.offset(of: "two [ref]") + 9)
            w.type("x")
            #expect(w.displayAttributes(at: w.offset(of: "two"))[.glyphLift] == nil, "the map is behind the text")
            w.type(backtab)
            #expect(w.textView.string.hasPrefix("- one\n- two [ref]x\n"))
        }

        // MARK: code blocks

        /// Return after a line that opens a block (a Python `def`, say) did not indent the next line.
        @Test func returnInACodeBlockIndentsAndEveryKeyIsOneUndoStep() {
            let w = EditorWindow()
            defer { w.close() }
            w.type("```python\rdef f():\rif x:\rreturn 1")
            #expect(w.textView.string == "```python\ndef f():\n    if x:\n        return 1\n```", "the fence is closed, the lines are indented")
            w.type("\r")
            #expect(w.textView.string == "```python\ndef f():\n    if x:\n        return 1\n        \n```")
            w.type(String(EditorWindow.backspace))
            #expect(w.textView.string == "```python\ndef f():\n    if x:\n        return 1\n    \n```", "Backspace takes one level")
            w.type("y = [\r1,\r]")
            #expect(w.textView.string == "```python\ndef f():\n    if x:\n        return 1\n    y = [\n        1,\n    ]\n```", "the closing bracket stands one level out")
            w.type(backtab)
            #expect(w.textView.string.hasSuffix("        1,\n]\n```"))
            w.type("\t")
            #expect(w.textView.string.hasSuffix("        1,\n]    \n```"), "Tab at the caret is one level of blanks")
            for expected in ["        1,\n]\n```", "        1,\n    ]\n```", "        1,\n        \n```"] {
                w.textView.undoManager?.undo()
                w.pump()
                #expect(w.textView.string.hasSuffix(expected), "one step back: \(w.textView.string.debugDescription)")
            }
            #expect(w.storageProblem == nil && w.paintProblem == nil)
        }

        @Test func tabAndShiftTabIndentTheSelectedLinesOfCodeAndNotTheListItem() {
            let source = "- item\n\n  ```js\n  a()\n  b()\n  ```\n"
            let w = EditorWindow(source)
            defer { w.close() }
            w.select(w.offset(of: "a()"), length: 9)
            w.type("\t")
            #expect(w.textView.string == "- item\n\n  ```js\n      a()\n      b()\n  ```\n")
            #expect((w.textView.string as NSString).substring(with: w.textView.selectedRange()) == "    a()\n      b()")
            w.type(backtab)
            #expect(w.textView.string == source)
            w.type(backtab)
            #expect(w.textView.string == source, "nothing left to take, and the item stays where it is")
        }

        @Test func linesPastedIntoACodeBlockInAListItemStayInTheBlock() {
            let source = "- a\n  ```py\n  def f():\n      \n  ```"
            let w = EditorWindow(source)
            defer { w.close() }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString("if a:\n        b = [\n    1]\n}", forType: .string)
            w.select(w.offset(of: "      \n") + 6)
            #expect(w.textView.readSelection(from: pasteboard, type: .string))
            #expect(w.textView.string == "- a\n  ```py\n  def f():\n      if a:\n          b = [\n      1]\n  }\n  ```")
            w.pump()
            #expect(MarkdownStyler.style(w.textView.string).lines.allSatisfy { $0.listDepth == 1 } && w.paintProblem == nil)
            #expect((w.fragment(at: w.offset(of: "}")) as? BlockFragment)?.codePanelRect != nil, "the last pasted line is code")
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == source && w.storageProblem == nil, "one undo step")
            // Outside a list or quote the text goes in as it is, by the text view itself.
            let plain = EditorWindow("```\n\n```\n")
            defer { plain.close() }
            plain.select(4)
            #expect(plain.textView.readSelection(from: pasteboard, type: .string))
            #expect(plain.textView.string == "```\nif a:\n        b = [\n    1]\n}\n```\n")
        }

        // MARK: the page

        private static let wide = """
            # Head

            Prose that is long enough to wrap in the text column, so that where it ends shows where the column ends, whatever the window's width may be.

            | Option | What it does | Default | Since | Stable | Notes |
            |---|---|--:|:-:|---|---|
            | `pagePadding` | Space between the text column and the window edge | `44` | 1.0 | yes | none |
            | `maximumTextWidth` | The widest the text column may be at this zoom | `780` | 1.0 | no | changes with zoom |

            > quoted

            ```
            code
            ```

            - item

            Last line.

            """

        private func grid(_ w: EditorWindow) -> TableRow? { w.displayAttributes(at: w.offset(of: "| `pagePadding`"))[.tableRow] as? TableRow }

        /// A window wider than the readable column left a table as narrow as the column.
        @Test func aTableUsesThePagesWidthBeforeItsCellsWrapAndEverythingElseKeepsToTheColumn() throws {
            let w = EditorWindow(Self.wide, size: NSSize(width: 1500, height: 700))
            defer { w.close() }
            let column = w.textView.columnWidth, page = w.textView.textContainer!.size.width
            #expect(column == theme.maximumTextWidth && page == 1500 - 2 * theme.pagePadding.width)
            let row = try #require(grid(w))
            let width = row.edges.last! - row.edges[0]
            #expect(row.cellStarts.isEmpty && width > column && width <= page, "on single lines, wider than the column")
            #expect(abs(row.edges[0] + row.edges.last! - column) <= 1, "in the middle of the page")
            #expect(w.displayFont(at: w.offset(of: "Space between")).pointSize == theme.bodySize, "at the normal size")
            // Prose, a heading's rule, a quote's bar, a code panel and a list keep to the column.
            let prose = w.fragment(at: w.offset(of: "Prose"))
            #expect(prose.textLineFragments.count > 1 && prose.textLineFragments.map { w.inColumn($0.typographicBounds, ofFragmentAt: w.offset(of: "Prose")) }
                .allSatisfy { $0.minX >= 0 && $0.maxX <= column + 0.5 })
            let hairline = try #require((w.fragment(at: 0) as? BlockFragment)?.hairlineRect), panel = try #require((w.fragment(at: w.offset(of: "code")) as? BlockFragment)?.codePanelRect)
            #expect(w.inColumn(hairline, ofFragmentAt: 0).minX == 0 && w.inColumn(hairline, ofFragmentAt: 0).maxX == column)
            #expect(w.inColumn(panel, ofFragmentAt: w.offset(of: "code")).minX == 0 && w.inColumn(panel, ofFragmentAt: w.offset(of: "code")).maxX == column)
            let bar = try #require((w.fragment(at: w.offset(of: "> quoted")) as? BlockFragment)?.quoteBarRects.first)
            #expect(w.inColumn(bar, ofFragmentAt: w.offset(of: "> quoted")).minX == 0)
            #expect(abs(w.columnX(at: w.offset(of: "item")) - theme.listIndent) < 0.5 && w.columnX(at: w.offset(of: "Prose")) == 0)
            // The empty line behind the text is where a line of text starts, also with the caret in it.
            w.select(w.length)
            w.pump()
            #expect((w.fragment(at: w.length - 1).textLineFragments.last?.characterRange.length ?? 1) == 0, "that line is laid out")
            #expect(w.columnOrigin > 300 && abs(w.caretRect(at: w.length).minX - w.columnOrigin) < 0.5)

            // Tab goes from cell to cell and a table command works in the cells beside the column.
            w.select(w.offset(of: "`pagePadding`"))
            #expect(w.columnX(at: w.offset(of: "`pagePadding`")) < 0)
            w.type("\t")
            #expect(w.textView.selectedRange().location == w.offset(of: "Space between"))
            #expect(w.editor.textView.validateUserInterfaceItem(EditorTextView.tableMenu().items[1]))

            // A window too narrow for it on single lines at any size: the cells wrap, in a grid as wide as the page.
            w.window.setContentSize(NSSize(width: 700, height: 700))
            w.pump()
            let narrow = try #require(grid(w)), room = w.textView.textContainer!.size.width
            #expect(!narrow.cellStarts.isEmpty && narrow.edges[0] == 0 && narrow.edges.last! <= room && narrow.edges.last! > room - 8)
            #expect(w.textView.string == Self.wide && w.storageProblem == nil)
        }

        /// The stops a paragraph style has by itself are measured from the container's edge like its
        /// indents: left there, a tab in the column had none to go to, and the line was not laid out.
        @Test func aTabGoesToTheSameStopWhereverTheColumnStandsInThePage() {
            Theme.zoom = 0.8
            defer { Theme.zoom = 1 }
            let text = "# A\n\nProse with a\ttab inside it.\n\nShown raw with a\ttab too.\u{2029}\n\n```go\nfunc f() {\n\tx := 1\n\t\tdeep()\n}\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nEnd.\n"
            let narrow = EditorWindow(text, size: NSSize(width: 600, height: 600)), wide = EditorWindow(text, size: NSSize(width: 1500, height: 600))
            defer {
                narrow.close()
                wide.close()
            }
            #expect(narrow.columnOrigin == 0 && wide.columnOrigin > 336, "past the last of the stops a style starts with")
            #expect(wide.displayAttributes(at: wide.offset(of: "Shown raw"))[.glyphLift] == nil, "a paragraph the renderer leaves as it is")
            for needle in ["tab inside", "tab too", "x := 1", "deep()", "End."] {
                let offset = wide.offset(of: needle)
                #expect(wide.fragment(at: offset).textLineFragments.count(where: { $0.characterRange.length > 0 }) == 1, "\(needle): one line")
                #expect(wide.columnX(at: offset) == narrow.columnX(at: offset) && wide.columnX(at: offset) >= 0, "\(needle)")
            }
            #expect(wide.columnX(at: wide.offset(of: "deep()")) > wide.columnX(at: wide.offset(of: "x := 1")))
        }

        /// A text that had a table keeps the page for its container when all of it is deleted.
        @Test func theCaretInATextThatIsEmptyAgainStandsInTheColumn() {
            let w = EditorWindow(Self.wide, size: NSSize(width: 1500, height: 700))
            defer { w.close() }
            w.select(0, length: w.length)
            w.type(String(EditorWindow.backspace))
            #expect(w.length == 0 && w.columnOrigin > 300 && abs(w.caretRect(at: 0).minX - w.columnOrigin) < 0.5)
            w.type("a")
            #expect(abs(w.columnX(at: 0)) < 0.5 && w.storageProblem == nil)
        }

        @Test func resizingAWideWindowKeepsEveryParagraphInTheColumnAlsoThoseOutOfSight() throws {
            let filler = String(repeating: "A paragraph of the text.\n\n", count: 200)
            let w = EditorWindow(filler + Self.wide + filler, size: NSSize(width: 1300, height: 500))
            defer { w.close() }
            let far = w.length - 26, table = w.offset(of: "| `pagePadding`")
            #expect(w.columnX(at: 0) == 0 && w.columnX(at: far) == 0)
            var kinds: [Bool] = []
            for width in Array(stride(from: 1320, through: 1600, by: 40)) + Array(stride(from: 1560, through: 600, by: -60)) {
                w.window.setContentSize(NSSize(width: CGFloat(width), height: 500))
                w.pump(0.01)
                #expect(w.paintProblem == nil, "\(width)")
                #expect(w.textView.columnLeft == ((CGFloat(width) - w.textView.columnWidth) / 2).rounded(.down), "the column stays in the middle")
                #expect(w.columnX(at: 0) == 0 && w.columnX(at: far) == 0 && w.columnX(at: w.offset(of: "Prose")) == 0, "\(width)")
                let row = try #require(w.displayAttributes(at: table)[.tableRow] as? TableRow)
                #expect(w.columnOrigin + row.edges[0] >= 0 && w.columnOrigin + row.edges.last! <= w.textView.textContainer!.size.width, "\(width): on the page")
                kinds.append(row.cellStarts.isEmpty)
            }
            // A step that leaves the column where it is asks for no paragraph again, so the grid
            // must not move by it either: the rows on screen are where rows rendered now would be.
            for width in [1500, 1501, 1502, 1503] {
                w.window.setContentSize(NSSize(width: CGFloat(width), height: 500))
                w.pump(0.01)
                let shown = try #require(w.displayAttributes(at: table)[.tableRow] as? TableRow)
                let other = EditorWindow(w.textView.string, size: NSSize(width: CGFloat(width), height: 500))
                defer { other.close() }
                let fresh = try #require(other.displayAttributes(at: table)[.tableRow] as? TableRow)
                #expect(shown.edges == fresh.edges && shown.cellStarts.isEmpty && other.columnOrigin == w.columnOrigin, "\(width)")
            }
            // On single lines where the page has the room, with wrapping cells where it has not, and never back and forth.
            #expect(kinds.first == true && kinds.last == false && zip(kinds, kinds.dropFirst()).count { $0 != $1 } == 1, "\(kinds)")
        }

        @Test func fullWidthLetsTheTextColumnFollowTheWindow() throws {
            let w = EditorWindow(Self.wide, size: NSSize(width: 1500, height: 700))
            defer {
                Theme.isFullWidth = false
                w.close()
            }
            let prose = w.offset(of: "Prose"), lines = w.fragment(at: prose).textLineFragments.count
            #expect(!Theme.isFullWidth && lines > 1, "off unless it is chosen")
            w.select(w.offset(of: "quoted"))
            Theme.isFullWidth = true
            w.pump()
            let page = 1500 - 2 * theme.pagePadding.width
            #expect(w.textView.columnWidth == page && w.textView.textContainer?.size.width == page && w.textView.columnLeft == theme.pagePadding.width)
            #expect(w.fragment(at: prose).textLineFragments.count < lines, "the text is set anew in the wider column")
            let panel = try #require((w.fragment(at: w.offset(of: "code")) as? BlockFragment)?.codePanelRect)
            #expect(w.inColumn(panel, ofFragmentAt: w.offset(of: "code")).width == page)
            let row = try #require(grid(w))
            #expect(row.edges[0] == 0 && row.cellStarts.isEmpty, "a table that fits starts where the text does")
            w.window.setContentSize(NSSize(width: 1000, height: 700))
            w.pump()
            #expect(w.textView.columnWidth == 1000 - 2 * theme.pagePadding.width && w.paintProblem == nil)
            Theme.isFullWidth = false
            w.pump()
            #expect(w.textView.columnWidth == theme.maximumTextWidth && w.columnX(at: prose) == 0 && w.paintProblem == nil)
            #expect(w.textView.selectedRange().location == w.offset(of: "quoted") && w.storageProblem == nil)
        }
    }
}
