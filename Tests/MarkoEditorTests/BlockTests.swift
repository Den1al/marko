import AppKit
import FixtureSupport
import MarkoCore
import Testing
@testable import MarkoEditor

extension EditorTests {
    /// Lists, tasks, quotes, code blocks and rules, as laid out and drawn in a real window.
    @Suite struct BlockTests {
        private let theme = Theme.standard

        /// An editor on `source` with the caret parked at the very end, away from everything.
        private func window(_ source: String, size: NSSize = NSSize(width: 900, height: 600)) -> EditorWindow {
            let w = EditorWindow(source + "\nend", size: size)
            w.select(w.length)
            w.pump()
            return w
        }

        private func offset(_ text: String, in w: EditorWindow, occurrence: Int = 0) -> Int {
            var search = NSRange(location: 0, length: w.length), found = NSRange(location: NSNotFound, length: 0)
            for _ in 0...occurrence {
                found = (w.textView.string as NSString).range(of: text, range: search)
                search = NSRange(location: NSMaxRange(found), length: w.length - NSMaxRange(found))
            }
            return found.location
        }

        private func shown(_ w: EditorWindow, at offset: Int) -> String {
            let (text, index) = w.displayParagraph(at: offset)
            return (text.string as NSString).substring(with: NSRange(location: index, length: 1))
        }

        private func color(_ w: EditorWindow, at offset: Int) -> NSColor? {
            w.displayAttributes(at: offset)[.foregroundColor] as? NSColor
        }

        // MARK: lists

        @Test func bulletsAreSubstitutedAndOrderedMarkersShowAsTyped() throws {
            let source = "- one\n  * two\n    + three\n      - four\n\n7. seven\n"
            let w = window(source)
            defer { w.close() }
            #expect(shown(w, at: 0) == "\u{2022}")
            #expect(shown(w, at: offset("*", in: w)) == "\u{25E6}")
            #expect(shown(w, at: offset("+", in: w)) == "\u{25AA}")
            #expect(shown(w, at: offset("- four", in: w)) == "\u{25AA}", "deeper levels keep the last glyph")
            #expect(shown(w, at: offset("7.", in: w)) == "7" && shown(w, at: offset("7.", in: w) + 1) == ".")
            #expect(!w.isHidden(0) && !w.isHidden(1), "the marker and one space show")
            #expect(shown(w, at: 1) == theme.bulletGap && shown(w, at: offset("7.", in: w) + 2) == " ")
            #expect(["- one", "*", "+", "- four"].map { w.displayAttributes(at: offset($0, in: w))[.bullet] as? Int } == [1, 2, 3, 3])
            #expect((6...7).allSatisfy(w.isHidden), "indentation is hidden")
            #expect(color(w, at: 0) == .clear, "the fragment draws the bullet's shape")
            #expect(color(w, at: offset("7.", in: w)) == theme.listMarker)

            // Pixels: a disc for the first level, a ring with a hole for the second, each beside its text.
            let (isBackground, _) = w.pixels()
            for (marker, isHollow) in [(0, false), (offset("*", in: w), true)] {
                let fragment = try #require(w.fragment(at: marker) as? BlockFragment)
                let rect = w.inColumn(try #require(fragment.bullets.first).rect, ofFragmentAt: marker)
                let glyph = w.characterRect(at: marker).offsetBy(dx: -w.textView.textContainerOrigin.x, dy: -w.textView.textContainerOrigin.y)
                #expect(abs(rect.midX - glyph.midX) < 0.01 && rect.minY > glyph.minY && rect.maxY < glyph.maxY)
                #expect(isBackground(rect.midX, rect.midY) == isHollow, "bullet at \(marker)")
                #expect(!isBackground(rect.minX + 0.75, rect.midY) && isBackground(rect.minX - 1.5, rect.midY))
            }
            #expect(w.textView.string == source + "\nend")
            #expect(w.storageProblem == nil)
        }

        @Test func listContentHangsAtItsLevelsIndent() {
            let long = String(repeating: "wrapping words ", count: 12)
            let source = "- one \(long)\n  continued\n  - two\n    1. three\n\n       loose paragraph\n100. hundred\n"
            let w = window(source, size: NSSize(width: 600, height: 600))
            defer { w.close() }
            let step = theme.listIndent
            #expect(abs(w.columnX(at: offset("one", in: w)) - step) < 0.5)
            #expect(abs(w.columnX(at: offset("continued", in: w)) - step) < 0.5)
            #expect(abs(w.columnX(at: offset("two", in: w)) - 2 * step) < 0.5)
            #expect(abs(w.columnX(at: offset("three", in: w)) - 3 * step) < 0.5)
            #expect(abs(w.columnX(at: offset("loose", in: w)) - 3 * step) < 0.5)

            let wrapped = w.fragment(at: 0).textLineFragments
            #expect(wrapped.count > 1, "the first item wraps")
            let frame = w.fragment(at: 0).layoutFragmentFrame
            #expect(abs(frame.minX + wrapped[1].typographicBounds.minX - step) < 0.5, "wrapped lines hang under the content")
            #expect(w.columnX(at: 0) < step - 8 && w.columnX(at: 0) > 0, "the bullet hangs in the indent")

            let hundred = offset("100.", in: w)
            #expect(w.columnX(at: hundred) >= 0 && w.columnX(at: hundred + 5) >= step, "a wide marker pushes its content, not the margin")
        }

        @Test func everyItemOfAnOrderedListStartsItsTextAtTheSameIndent() {
            let long = String(repeating: "wrapping words ", count: 12)
            let w = window("9. nine\n10. ten \(long)\n    - nested\n11. eleven\n\npara\n\n1. one\n", size: NSSize(width: 600, height: 600))
            defer { w.close() }
            let x = w.columnX(at: offset("nine", in: w))
            #expect(x > theme.listIndent && x < theme.listIndent + 8, "the list is indented by what its widest number needs")
            #expect(abs(w.columnX(at: offset("ten", in: w)) - x) < 0.01 && abs(w.columnX(at: offset("eleven", in: w)) - x) < 0.01)
            let ten = w.fragment(at: offset("10.", in: w))
            #expect(ten.textLineFragments.count > 1)
            #expect(abs(ten.layoutFragmentFrame.minX + ten.textLineFragments[1].typographicBounds.minX - x) < 0.01, "wrapped lines too")
            #expect(w.columnX(at: offset("10.", in: w)) >= 0, "and the number stays inside the column")
            #expect(abs(w.columnX(at: offset("nested", in: w)) - (x + theme.listIndent)) < 0.01)
            #expect(abs(w.columnX(at: offset("one", in: w)) - theme.listIndent) < 0.01, "a list of short numbers keeps the usual indent")
        }

        @Test func anEmptyItemKeepsAFullLineForItsBullet() {
            let w = window("- one\n- \n\nplain\n")
            defer { w.close() }
            #expect(w.fragment(at: 6).layoutFragmentFrame.height == theme.bodyLineHeight)
            #expect(w.fragment(at: 9).layoutFragmentFrame.height == theme.blankLineHeight)
        }

        // MARK: tasks

        @Test func checkboxesAreAttachmentsOnALineOfNormalHeight() {
            let source = "- [ ] open\n- [x] done\n- plain\n"
            let w = window(source)
            defer { w.close() }
            for (box, content) in [(2, 6), (13, 17)] {
                #expect(shown(w, at: box) == "\u{FFFC}")
                #expect(w.displayAttributes(at: box)[.attachment] is NSTextAttachment)
                #expect((box - 2..<box).allSatisfy(w.isHidden) && w.isHidden(box + 1) && w.isHidden(box + 2), "the bullet and the brackets are hidden")
                #expect(abs(w.columnX(at: content) - theme.listIndent) < 0.5, "task text lines up with list text")
                #expect(w.fragment(at: box).layoutFragmentFrame.height == theme.bodyLineHeight)
            }
            let open = w.displayAttributes(at: 2)[.attachment] as! NSTextAttachment
            let done = w.displayAttributes(at: 13)[.attachment] as! NSTextAttachment
            #expect(open.image != nil && done.image != nil && open.image !== done.image)
            #expect(open.bounds.height <= theme.bodyLineHeight - 4)
            #expect(w.storageProblem == nil)
        }

        @Test func aClickOnACheckboxTogglesTheSourceInOneUndoStep() {
            let source = "- [ ] open\n- [x] done\n"
            let w = window(source)
            defer { w.close() }
            w.select(8)
            w.type("!")
            let typed = "- [ ] op!en\n- [x] done\n\nend"
            #expect(w.textView.string == typed)

            let box = w.characterRect(at: 2)
            w.mouseDown(at: NSPoint(x: box.midX, y: box.midY))
            #expect(w.textView.string == "- [x] op!en\n- [x] done\n\nend")
            #expect(w.textView.selectedRange() == NSRange(location: 9, length: 0), "the caret stays where it was")
            #expect((w.displayAttributes(at: 2)[.attachment] as? NSTextAttachment)?.image === (w.displayAttributes(at: 14)[.attachment] as? NSTextAttachment)?.image)

            let second = w.characterRect(at: 14)
            w.mouseDown(at: NSPoint(x: second.midX, y: second.midY))
            #expect(w.textView.string == "- [x] op!en\n- [ ] done\n\nend")

            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == "- [x] op!en\n- [x] done\n\nend")
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == typed, "one undo per toggle, and the typing before it is its own step")
            w.textView.undoManager?.redo()
            w.pump()
            #expect(w.textView.string == "- [x] op!en\n- [x] done\n\nend")
            #expect(w.storageProblem == nil)

            let text = w.characterRect(at: 8)
            #expect(w.textView.clickHandler?(NSPoint(x: text.midX, y: text.midY), []) == false, "a click on the text is left to the text view")
            #expect(w.textView.clickHandler?(NSPoint(x: box.maxX + 3, y: box.midY), []) == false, "and so is one just beside the box")
            #expect(w.textView.string == "- [x] op!en\n- [x] done\n\nend")
        }

        // MARK: quotes

        @Test func quoteMarkersAreHiddenAndTheTextIsMuted() {
            let source = "> quoted **bold**\n> > deeper\n>\n> back\nlazy\n\nplain\n"
            let w = window(source)
            defer { w.close() }
            #expect(w.isHidden(0) && w.isHidden(1) && (18...21).allSatisfy(w.isHidden))
            #expect(color(w, at: 2) == theme.quoteText && color(w, at: offset("lazy", in: w)) == theme.quoteText)
            #expect(color(w, at: offset("plain", in: w)) == theme.text)
            #expect(abs(w.columnX(at: 2) - theme.quoteIndent) < 0.5)
            #expect(abs(w.columnX(at: offset("deeper", in: w)) - 2 * theme.quoteIndent) < 0.5)
            #expect(abs(w.columnX(at: offset("lazy", in: w)) - theme.quoteIndent) < 0.5)
            #expect(w.fragment(at: offset(">\n", in: w)).layoutFragmentFrame.height == theme.blankLineHeight)
        }

        @Test func quoteBarsRunDownTheQuoteOnePerLevel() throws {
            let source = "> one\n> > two\n>\n> three\n\nplain\n"
            let w = window(source)
            defer { w.close() }
            func bars(_ offset: Int) -> [QuoteBar] { w.displayAttributes(at: offset)[.quoteBars] as? [QuoteBar] ?? [] }
            let indent = theme.quoteIndent
            #expect(bars(0) == [QuoteBar(x: 0, isFirst: true, isLast: false)])
            #expect(bars(6) == [QuoteBar(x: 0, isFirst: false, isLast: false), QuoteBar(x: indent, isFirst: true, isLast: true)])
            #expect(bars(14) == [QuoteBar(x: 0, isFirst: false, isLast: false)])
            #expect(bars(16) == [QuoteBar(x: 0, isFirst: false, isLast: true)])
            #expect(bars(offset("plain", in: w)).isEmpty)

            // Geometry: each line's bar is as high as its fragment, and consecutive ones meet.
            var bottom: CGFloat?
            for start in [0, 6, 14, 16] {
                let fragment = try #require(w.fragment(at: start) as? BlockFragment)
                let rect = w.inColumn(fragment.quoteBarRects[0], ofFragmentAt: start)
                #expect(rect.minX == 0 && rect.width == theme.quoteBarWidth)
                #expect(rect.height == fragment.layoutFragmentFrame.height)
                if let bottom { #expect(abs(rect.minY - bottom) < 0.01) }
                bottom = rect.maxY
            }
            let nested = try #require(w.fragment(at: 6) as? BlockFragment)
            #expect(w.inColumn(nested.quoteBarRects[1], ofFragmentAt: 6).minX == indent)

            // Pixels: the bar is painted, left of the text and nowhere else.
            let (isBackground, _) = w.pixels()
            let midY = w.fragment(at: 0).layoutFragmentFrame.midY
            #expect(!isBackground(theme.quoteBarWidth / 2, midY))
            #expect(isBackground(theme.quoteBarWidth + 3, midY))
            #expect(!isBackground(theme.quoteBarWidth / 2, w.fragment(at: 14).layoutFragmentFrame.midY), "also on the empty quote line")
            #expect(!isBackground(indent + theme.quoteBarWidth / 2, w.fragment(at: 6).layoutFragmentFrame.midY))
            #expect(isBackground(theme.quoteBarWidth / 2, w.fragment(at: 24).layoutFragmentFrame.midY), "the blank line after the quote")
        }

        @Test func aNewQuoteLineMovesTheEndOfTheBar() {
            let w = window("> one\n\nplain\n")
            defer { w.close() }
            func bar(_ offset: Int) -> QuoteBar? { (w.displayAttributes(at: offset)[.quoteBars] as? [QuoteBar])?.first }
            #expect(bar(0) == QuoteBar(x: 0, isFirst: true, isLast: true))
            w.select(5)
            w.type("\rtwo")
            #expect(w.textView.string.hasPrefix("> one\n> two\n"))
            #expect(bar(0) == QuoteBar(x: 0, isFirst: true, isLast: false), "the line above was restyled although its text did not change")
            #expect(bar(8) == QuoteBar(x: 0, isFirst: false, isLast: true))
            w.undoAll()
            #expect(bar(0) == QuoteBar(x: 0, isFirst: true, isLast: true))
        }

        @Test func aQuoteInAListKeepsTheBulletLeftOfTheBar() throws {
            let w = window("- > quoted\n  > more\n")
            defer { w.close() }
            let bar = try #require((w.displayAttributes(at: 0)[.quoteBars] as? [QuoteBar])?.first)
            #expect(bar.x == theme.listIndent)
            #expect(w.characterRect(at: 0).maxX - w.textView.textContainerOrigin.x < bar.x, "the bullet")
            #expect(abs(w.columnX(at: 4) - (theme.listIndent + theme.quoteIndent)) < 0.5)
            #expect(abs(w.columnX(at: offset("more", in: w)) - (theme.listIndent + theme.quoteIndent)) < 0.5)
        }

        // MARK: code blocks

        @Test func codeBlocksAreMonospacedWithSmallDimmedFenceLines() {
            let source = "```swift\nlet answer = 42 // why\nprint(\"x\")\n```\n"
            let w = window(source)
            defer { w.close() }
            let body = theme.codeFont(size: theme.codeBlockFontSize)
            // The fences show only while the selection is on their line; the language always does.
            let closing = offset("```\n", in: w), height = w.fragment(at: closing).layoutFragmentFrame.height
            w.select(offset("answer", in: w))
            #expect(w.isHidden(0) && w.isHidden(closing) && color(w, at: 0) == .clear)
            #expect(w.displayFont(at: 3) == theme.codeFont(size: theme.fenceFontSize) && color(w, at: 3) == theme.mutedText, "muted language")
            #expect(abs(w.columnX(at: 3) - theme.codePanelPadding) < 0.5, "the language starts where the code does")
            w.select(closing)
            #expect(w.displayFont(at: closing) == theme.codeFont(size: theme.fenceFontSize) && color(w, at: closing) == theme.marker, "small and dim")
            #expect(w.isHidden(0) && w.fragment(at: closing).layoutFragmentFrame.height == height, "nothing moves")
            w.select(0)
            #expect(!w.isHidden(0) && color(w, at: 0) == theme.marker && color(w, at: 3) == theme.mutedText && w.isHidden(closing))
            #expect(w.displayFont(at: offset("answer", in: w)) == body)
            #expect(color(w, at: offset("let", in: w)) == theme.codeKeyword)
            #expect(color(w, at: offset("answer", in: w)) == theme.text)
            #expect(color(w, at: offset("42", in: w)) == theme.codeNumber)
            #expect(color(w, at: offset("// why", in: w)) == theme.codeComment)
            #expect(color(w, at: offset("\"x\"", in: w)) == theme.codeString)
            #expect(w.fragment(at: offset("let", in: w)).layoutFragmentFrame.height == theme.codeBlockLineHeight)
            #expect(abs(w.columnX(at: offset("let", in: w)) - theme.codePanelPadding) < 0.5, "code is inset from the panel's edge")
            #expect(w.storageProblem == nil)
        }

        @Test func aWrappedLineOfCodeContinuesIndented() {
            let w = window("```\nshort\nlet long = \"\(String(repeating: "word ", count: 30))\"\n```\n", size: NSSize(width: 500, height: 400))
            defer { w.close() }
            let long = w.fragment(at: offset("let long", in: w))
            #expect(long.textLineFragments.count > 1)
            #expect(long.textLineFragments[0].typographicBounds.minX + long.layoutFragmentFrame.minX == theme.codePanelPadding)
            #expect(long.textLineFragments[1].typographicBounds.minX + long.layoutFragmentFrame.minX == theme.codePanelPadding + theme.codeWrapIndent)
        }

        @Test func theCodePanelSpansTheBlocksLinesAndTheColumn() throws {
            let source = "before\n```swift\nlet a = 1\n\nlet b = 2\n```\nafter\n"
            let w = window(source)
            defer { w.close() }
            let columnWidth = w.textView.columnWidth
            let starts = [7, 16, 26, 27, 37]
            #expect(w.displayAttributes(at: 7)[.codePanel] as? CodePanel == CodePanel(x: 0, top: 0, bottom: nil))
            #expect(w.displayAttributes(at: 16)[.codePanel] as? CodePanel == CodePanel(x: 0, top: nil, bottom: nil))
            #expect(w.displayAttributes(at: 37)[.codePanel] as? CodePanel == CodePanel(x: 0, top: nil, bottom: 0))
            #expect(w.displayAttributes(at: 0)[.codePanel] == nil && w.displayAttributes(at: 41)[.codePanel] == nil)

            var bottom: CGFloat?, top: CGFloat = 0
            for start in starts {
                let fragment = try #require(w.fragment(at: start) as? BlockFragment)
                let rect = w.inColumn(try #require(fragment.codePanelRect), ofFragmentAt: start)
                #expect(rect.minX == 0 && abs(rect.width - columnWidth) < 0.01, "line at \(start)")
                if let bottom { #expect(abs(rect.minY - bottom) < 0.01, "the parts meet at \(start)") } else { top = rect.minY }
                bottom = rect.maxY
            }
            let before = w.fragment(at: 0).layoutFragmentFrame, after = w.fragment(at: 41).layoutFragmentFrame
            #expect(abs(top - before.maxY - theme.codePanelMargin) < 0.01, "a small gap to the line above")
            #expect(abs(after.minY - bottom! - theme.codePanelMargin) < 0.01, "and to the line below")
            #expect(try #require(w.fragment(at: 0) as? BlockFragment).codePanelRect == nil)

            // Pixels: filled from edge to edge, blank line included, with rounded corners and nothing outside.
            let (isBackground, color) = w.pixels()
            let blank = w.fragment(at: 26).layoutFragmentFrame.midY
            #expect(!isBackground(columnWidth / 2, blank) && !isBackground(3, blank) && !isBackground(columnWidth - 3, blank))
            #expect(!isBackground(columnWidth / 2, top + 3) && !isBackground(columnWidth / 2, bottom! - 3))
            #expect(isBackground(0.5, top + 0.5) && isBackground(columnWidth - 0.5, bottom! - 0.5), "the corners are cut")
            #expect(isBackground(columnWidth / 2, top - 2) && isBackground(columnWidth / 2, bottom! + 2))
            let fill = color(columnWidth / 2, blank), edge = color(0.5, blank)
            #expect(abs(fill.redComponent - edge.redComponent) > 0.02, "the border is a different shade from the fill")
        }

        @Test func codeInContainersAndWithoutFencesGetsItsPanelToo() throws {
            let source = "> ```\n> quoted code\n> ```\n\n    indented code\n    second line\n\n- item\n\n  ```js\n  const x = 1\n  ```\n"
            let w = window(source)
            defer { w.close() }
            #expect((w.displayAttributes(at: 6)[.codePanel] as? CodePanel)?.x == theme.quoteIndent)
            #expect(abs(w.columnX(at: offset("quoted code", in: w)) - (theme.quoteIndent + theme.codePanelPadding)) < 0.5)
            #expect((w.displayAttributes(at: 0)[.quoteBars] as? [QuoteBar])?.count == 1)
            #expect((w.displayAttributes(at: offset("const", in: w))[.codePanel] as? CodePanel)?.x == theme.listIndent)
            #expect(color(w, at: offset("const", in: w)) == theme.codeKeyword)

            let inset = theme.codePanelInset
            let first = offset("    indented", in: w), second = offset("    second", in: w)
            #expect((first..<first + 4).allSatisfy(w.isHidden), "the indentation that makes it code is not shown")
            #expect(abs(w.columnX(at: first + 4) - theme.codePanelPadding) < 0.5, "so the code starts where fenced code does")
            w.select(first)
            #expect(w.textView.selectedRange() == NSRange(location: first + 4, length: 0), "and the caret stays out of it")
            w.select(w.length)
            #expect(w.displayAttributes(at: first)[.codePanel] as? CodePanel == CodePanel(x: 0, top: inset, bottom: nil))
            #expect(w.displayAttributes(at: second)[.codePanel] as? CodePanel == CodePanel(x: 0, top: nil, bottom: inset))
            let top = try #require(w.fragment(at: first) as? BlockFragment), bottom = try #require(w.fragment(at: second) as? BlockFragment)
            let upper = w.inColumn(try #require(top.codePanelRect), ofFragmentAt: first)
            let lower = w.inColumn(try #require(bottom.codePanelRect), ofFragmentAt: second)
            #expect(abs(upper.maxY - lower.minY) < 0.01)
            #expect(abs(upper.height + lower.height - (2 * theme.codeBlockLineHeight + 2 * inset)) < 0.01, "padding stands in for the missing fence lines")
        }

        @Test func aListMarkerOnAFenceLineStaysOutsideThePanel() {
            let w = window("- ```\n  code\n  ```\n")
            defer { w.close() }
            #expect(w.characterRect(at: 0).maxX - w.textView.textContainerOrigin.x <= theme.listIndent)
            #expect(abs(w.columnX(at: 2) - (theme.listIndent + theme.codePanelPadding)) < 0.5)
            #expect(abs(w.columnX(at: offset("code", in: w)) - (theme.listIndent + theme.codePanelPadding)) < 0.5)
        }

        // MARK: rules

        @Test func aRuleIsAHairlineAcrossTheMiddleOfItsLine() throws {
            let source = "above\n\n---\n\nbelow\n\n> ***\n"
            let w = window(source)
            defer { w.close() }
            #expect((7...9).allSatisfy(w.isHidden), "the source is hidden")
            let fragment = try #require(w.fragment(at: 7) as? BlockFragment)
            #expect(fragment.layoutFragmentFrame.height == theme.ruleLineHeight)
            let rect = w.inColumn(try #require(fragment.ruleRect), ofFragmentAt: 7)
            #expect(rect.minX == 0 && abs(rect.width - w.textView.columnWidth) < 0.01)
            #expect(rect.height == theme.hairlineWidth)
            #expect(abs(rect.midY - fragment.layoutFragmentFrame.midY) <= 1, "vertically centred")

            let (isBackground, _) = w.pixels()
            #expect(!isBackground(10, rect.midY) && !isBackground(rect.width - 10, rect.midY))
            #expect(isBackground(10, rect.midY - 5) && isBackground(10, rect.midY + 5))

            let quoted = offset("***", in: w)
            let inQuote = w.inColumn(try #require((w.fragment(at: quoted) as? BlockFragment)?.ruleRect), ofFragmentAt: quoted)
            #expect(inQuote.minX == theme.quoteIndent, "inside a quote it starts after the bar")
        }

        @Test func aRuleShowsItsSourceWhileTheCaretIsOnIt() {
            let w = window("above\n\n---\n\nbelow\n")
            defer { w.close() }
            w.select(8)
            w.pump()
            #expect(!w.isHidden(7) && color(w, at: 7) == theme.marker)
            #expect(w.displayAttributes(at: 7)[.rule] == nil)
            #expect(w.fragment(at: 7).layoutFragmentFrame.height == theme.ruleLineHeight, "the line does not change height")
            w.select(0)
            w.pump()
            #expect(w.isHidden(7) && w.displayAttributes(at: 7)[.rule] != nil)
        }

        // MARK: the caret and hidden prefixes

        /// Every offset that lies among hidden block markers: inside a prefix, its start included.
        private func prefixOffsets(_ text: String) -> Set<Int> {
            var offsets: Set<Int> = []
            for line in MarkdownStyler.style(text).lines {
                offsets.formUnion(line.prefixRange.location..<NSMaxRange(line.prefixRange))
            }
            return offsets
        }

        @Test func arrowKeysNeverLeaveTheCaretInAPrefix() throws {
            let source = try MarkdownFile(data: Fixtures.data("nested-lists-quotes.md")).text
            let w = EditorWindow(source)
            defer { w.close() }
            let forbidden = prefixOffsets(source)
            #expect(forbidden.count > 60)
            let moves: [(name: String, move: Selector, end: Int)] = [
                ("right", #selector(NSResponder.moveRight(_:)), w.length), ("left", #selector(NSResponder.moveLeft(_:)), 2),
                ("down", #selector(NSResponder.moveDown(_:)), w.length), ("up", #selector(NSResponder.moveUp(_:)), 2),
                ("word right", #selector(NSResponder.moveWordRight(_:)), w.length), ("word left", #selector(NSResponder.moveWordLeft(_:)), 2),
            ]
            #expect(w.textView.selectedRange() == NSRange(location: 2, length: 0), "the document opens with the caret after the first bullet")
            for (name, move, end) in moves {
                var visited: Set<Int> = []
                for _ in 0...w.length {
                    let before = w.textView.selectedRange()
                    w.command(move)
                    let now = w.textView.selectedRange()
                    #expect(now.length == 0 && !forbidden.contains(now.location), "\(name) reached \(now.location)")
                    visited.insert(now.location)
                    if now == before { break }
                }
                #expect(w.textView.selectedRange().location == end, "\(name) walks the whole document")
                if name == "right" || name == "left" {
                    #expect(visited.count >= w.length - forbidden.count - 1, "\(name) stops at every other offset")
                }
            }
        }

        @Test func leftFromTheStartOfAnItemGoesToTheEndOfTheLineAbove() {
            let w = EditorWindow("- one\r\n  - two\r\n> three\r\n")
            defer { w.close() }
            w.select(11)
            w.command(#selector(NSResponder.moveLeft(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: 5, length: 0), "before the CRLF")
            w.command(#selector(NSResponder.moveRight(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: 11, length: 0), "\(w.textView.selectedRange())")
            for command in [#selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)),
                            #selector(NSResponder.moveToBeginningOfParagraph(_:))] {
                w.select(13)
                w.textView.doCommand(by: command)
                #expect(w.textView.selectedRange() == NSRange(location: 11, length: 0), "\(command) goes to the start of the content")
                w.textView.doCommand(by: command)
                #expect(w.textView.selectedRange() == NSRange(location: 11, length: 0), "and stays there")
            }
            w.select(2)
            w.command(#selector(NSResponder.moveLeft(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: 2, length: 0), "nowhere to go on the first line")
            w.textView.moveToBeginningOfDocument(nil)
            #expect(w.textView.selectedRange() == NSRange(location: 2, length: 0))
        }

        /// The selection an ordinary click proposes, not a mouse event: see EditorWindow.mouseDown(at:).
        @Test func aClickOnAMarkerPutsTheCaretAfterIt() {
            let w = window("- one\n  - two\n> three\n1. four\n")
            defer { w.close() }
            for (marker, content) in [(0, 2), (8, 10), (22, 25)] {
                let rect = w.characterRect(at: marker)
                w.placeCaret(at: NSPoint(x: rect.minX + 1, y: rect.midY))
                #expect(w.textView.selectedRange() == NSRange(location: content, length: 0), "marker at \(marker): \(w.textView.selectedRange())")
            }
            let quote = w.characterRect(at: 16)
            w.placeCaret(at: NSPoint(x: w.textView.textContainerOrigin.x + 1, y: quote.midY))
            #expect(w.textView.selectedRange() == NSRange(location: 16, length: 0), "a click on the quote bar")

            // Also when the caret is already behind that marker: a click is not a Left arrow.
            for (marker, content) in [(0, 2), (8, 10), (22, 25)] {
                w.select(content)
                let rect = w.characterRect(at: marker)
                w.placeCaret(at: NSPoint(x: rect.minX + 1, y: rect.midY))
                #expect(w.textView.selectedRange() == NSRange(location: content, length: 0), "marker at \(marker): \(w.textView.selectedRange())")
            }
        }

        @Test func aSelectionTakesAPrefixWholeOrNotAtAll() {
            let source = "- one\n  - two\n> three\n"
            let w = EditorWindow(source)
            defer { w.close() }
            let forbidden = prefixOffsets(source)
            func isClean(_ range: NSRange) -> Bool {
                // An endpoint at the very start of a prefix takes all of it, which is allowed for a range.
                let starts = Set(MarkdownStyler.style(source).lines.map(\.range.location))
                return [range.location, NSMaxRange(range)].allSatisfy { !forbidden.contains($0) || starts.contains($0) }
            }
            w.select(3)
            for _ in 0..<source.count {
                w.textView.moveRightAndModifySelection(nil)
                #expect(isClean(w.textView.selectedRange()), "\(w.textView.selectedRange())")
            }
            #expect(w.textView.selectedRange() == NSRange(location: 3, length: w.length - 3))
            for _ in 0..<2 * source.count {
                w.textView.moveLeftAndModifySelection(nil)
                #expect(isClean(w.textView.selectedRange()), "\(w.textView.selectedRange())")
            }
            #expect(w.textView.selectedRange() == NSRange(location: 0, length: 3), "leftwards the first bullet is taken whole")

            w.select(12)
            w.textView.moveUpAndModifySelection(nil)
            #expect(isClean(w.textView.selectedRange()) && w.textView.selectedRange().length > 0)
            w.select(4)
            w.textView.moveDownAndModifySelection(nil)
            w.textView.moveDownAndModifySelection(nil)
            #expect(isClean(w.textView.selectedRange()) && w.textView.selectedRange().length > 0)

            w.textView.selectAll(nil)
            #expect(w.textView.selectedRange() == NSRange(location: 0, length: w.length), "select all keeps the first marker")
            // A selection shrinking onto the start of the markers must not leave the caret there.
            for start in [{ w.textView.selectAll(nil) }, { w.select(9); w.textView.selectParagraph(nil) }] {
                start()
                for _ in 0...source.count {
                    w.textView.moveLeftAndModifySelection(nil)
                    let now = w.textView.selectedRange()
                    #expect(now.length > 0 || !forbidden.contains(now.location), "\(now)")
                }
            }
            w.textView.setSelectedRange(NSRange(location: 7, length: 5))
            #expect(w.textView.selectedRange() == NSRange(location: 10, length: 2), "a start among the markers moves out of them")
        }

        // MARK: input rules through real keys

        @Test func aClosingFenceTypedByHandLeavesNoSecondOne() {
            let w = EditorWindow()
            defer { w.close() }
            w.type("```swift\rlet x = 1\r")
            #expect(w.textView.string == "```swift\nlet x = 1\n\n```", "Return behind the opening fence added the closing one")
            w.type("```\r\rmore")
            #expect(w.textView.string == "```swift\nlet x = 1\n```\n\nmore")
            #expect(MarkdownStyler.style(w.textView.string).lines.last?.kind == .paragraph, "and what follows is text")
        }

        @Test func returnContinuesAndLeavesListsAndUndoes() {
            let w = EditorWindow()
            defer { w.close() }
            w.type("- one\rtwo\r")
            #expect(w.textView.string == "- one\n- two\n- ")
            #expect(w.storageProblem == nil, "also in a document that started empty")
            w.type("\r")
            #expect(w.textView.string == "- one\n- two\n\n", "Return on the empty item leaves the list")
            #expect(w.textView.selectedRange() == NSRange(location: 13, length: 0))
            w.type("1. a\rb\r\r")
            #expect(w.textView.string == "- one\n- two\n\n1. a\n2. b\n\n")
            w.type("- [x] t\ru\r\r> q\rr\r\rz")
            #expect(w.textView.string == "- one\n- two\n\n1. a\n2. b\n\n- [x] t\n- [ ] u\n\n> q\n> r\n\nz")
            #expect(w.storageProblem == nil)
            #expect(w.textView.textLayoutManager != nil)

            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == "- one\n- two\n\n1. a\n2. b\n\n- [x] t\n- [ ] u\n\n> q\n> r\n\n", "typing after a rule is its own step")
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == "- one\n- two\n\n1. a\n2. b\n\n- [x] t\n- [ ] u\n\n> q\n> r\n> ", "and so is the rule")
            w.undoAll()
            #expect(w.textView.string == "")
            #expect(w.storageProblem == nil)
        }

        @Test func tabAndShiftTabMoveAnItemAndUndo() {
            let source = "- one\n- two\n  - child\n- three\n"
            let w = EditorWindow(source)
            defer { w.close() }
            w.select(11)
            w.type("\t")
            #expect(w.textView.string == "- one\n  - two\n    - child\n- three\n")
            #expect(w.textView.selectedRange() == NSRange(location: 13, length: 0))
            #expect(abs(w.columnX(at: 10) - 2 * theme.listIndent) < 0.5, "and it is laid out one level deeper")
            #expect(abs(w.columnX(at: 20) - 3 * theme.listIndent) < 0.5, "with its child")
            w.type(String(EditorWindow.backtab))
            #expect(w.textView.string == source)
            #expect(w.textView.selectedRange() == NSRange(location: 11, length: 0))
            w.type(String(EditorWindow.backtab))
            #expect(w.textView.string == source, "a top-level item has nowhere to go")
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == "- one\n  - two\n    - child\n- three\n")
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == source)
            #expect(w.storageProblem == nil)

            w.select(w.length)
            w.type("\rplain")
            w.type("\t")
            #expect(w.textView.string == source + "\nplain\t", "outside a list Tab is a tab")
        }

        @Test func backspaceAtTheStartOfTheContentRemovesTheInnermostMarker() {
            let source = "- one\n  - [ ] two\n\n> three\n"
            let w = EditorWindow(source)
            defer { w.close() }
            let backspace = String(EditorWindow.backspace)
            w.select(14)
            w.type(backspace)
            #expect(w.textView.string == "- one\n  - two\n\n> three\n", "the task becomes a bullet")
            #expect(w.textView.selectedRange() == NSRange(location: 10, length: 0))
            #expect(w.displayAttributes(at: 8)[.attachment] == nil)
            w.type(backspace)
            #expect(w.textView.string == "- one\n- two\n\n> three\n", "the nested item moves out")
            w.type(backspace)
            #expect(w.textView.string == "- one\n\ntwo\n\n> three\n", "the item becomes a paragraph of its own")
            #expect(w.textView.selectedRange() == NSRange(location: 7, length: 0))
            #expect(w.displayFont(at: 7) == theme.bodyFont && abs(w.columnX(at: 7)) < 0.5)
            w.type(backspace)
            #expect(w.textView.string == "- one\ntwo\n\n> three\n", "after that Backspace is ordinary")

            w.select(13)
            w.type(backspace)
            #expect(w.textView.string == "- one\ntwo\n\nthree\n", "the quote marker goes")
            w.type("x" + backspace)
            #expect(w.textView.string == "- one\ntwo\n\nthree\n", "inside the content Backspace deletes a character")

            w.undoAll()
            #expect(w.textView.string == source)
            #expect(w.storageProblem == nil)
        }

        @Test func backspaceOnTheFirstLineOfAQuoteRemovesItsMarker() {
            let w = EditorWindow("para\n> quote\n")
            defer { w.close() }
            w.select(7)
            w.type(String(EditorWindow.backspace))
            #expect(w.textView.string == "para\n\nquote\n", "the quote is not joined to the paragraph above")
            w.undoAll()
            #expect(w.textView.string == "para\n> quote\n")
        }

        @Test func deletingBackByWordOrLineStopsAtTheMarkers() {
            let source = "- alpha\n- beta gamma\n  - nested item\n> quote text\n"
            let w = EditorWindow(source)
            defer { w.close() }
            func result(_ command: Selector, at location: Int) -> String {
                w.editor.text = source
                w.select(location)
                w.command(command)
                return w.textView.string
            }
            let toLineStart = #selector(NSResponder.deleteToBeginningOfLine(_:)), wordBack = #selector(NSResponder.deleteWordBackward(_:))
            #expect(result(toLineStart, at: 20) == "- alpha\n- \n  - nested item\n> quote text\n", "the item stays")
            #expect(w.textView.selectedRange() == NSRange(location: 10, length: 0))
            w.textView.undoManager?.undo()
            #expect(w.textView.string == source, "in one undo step")
            #expect(result(#selector(NSResponder.deleteToBeginningOfParagraph(_:)), at: 44) == "- alpha\n- beta gamma\n  - nested item\n>  text\n")
            #expect(result(wordBack, at: 20) == "- alpha\n- beta \n  - nested item\n> quote text\n", "inside the content it is the usual command")

            // At the start of the content each of them does what Backspace does there.
            let unwrapped = "- alpha\n\nbeta gamma\n  - nested item\n> quote text\n"
            for command in [toLineStart, wordBack, #selector(NSResponder.deleteToBeginningOfParagraph(_:)),
                            #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:))] {
                #expect(result(command, at: 10) == unwrapped, "\(command)")
            }
            #expect(result(wordBack, at: 25) == "- alpha\n- beta gamma\n- nested item\n> quote text\n")

            let wrapping = "- " + String(repeating: "wrapping words ", count: 12) + "\n"
            let narrow = EditorWindow(wrapping, size: NSSize(width: 400, height: 300))
            defer { narrow.close() }
            let secondLine = narrow.fragment(at: 0).textLineFragments[1].characterRange.location
            narrow.select(secondLine + 5)
            narrow.command(toLineStart)
            #expect(narrow.textView.string == String(wrapping.prefix(secondLine)) + wrapping.dropFirst(secondLine + 5), "on a wrapped line, back to where it wraps")
        }

        @Test func deletingForwardAtTheEndOfALineJoinsTheNextLinesContent() {
            let source = "- alpha\n- beta gamma\n"
            let w = EditorWindow(source)
            defer { w.close() }
            for command in [#selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordForward(_:)),
                            #selector(NSResponder.deleteToEndOfLine(_:)), #selector(NSResponder.deleteToEndOfParagraph(_:))] {
                w.editor.text = source
                w.select(7)
                w.command(command)
                #expect(w.textView.string == "- alphabeta gamma\n", "\(command)")
                #expect(w.textView.selectedRange() == NSRange(location: 7, length: 0))
                w.textView.undoManager?.undo()
                #expect(w.textView.string == source)
            }
            w.select(3)
            w.command(#selector(NSResponder.deleteForward(_:)))
            #expect(w.textView.string == "- apha\n- beta gamma\n", "elsewhere it deletes a character")
        }

        @Test func returnKeepsTheLineEndingsOfACRLFDocument() {
            let w = EditorWindow("- a\r\n- b\r\n")
            defer { w.close() }
            w.select(3)
            w.type("\rx")
            #expect(w.textView.string == "- a\r\n- x\r\n- b\r\n")
            w.select(w.length)
            w.type("plain\ry")
            #expect(w.textView.string == "- a\r\n- x\r\n- b\r\nplain\r\ny")
            w.undoAll()
            #expect(w.textView.string == "- a\r\n- b\r\n")
        }

        @Test func anOpeningFenceAndReturnLeaveAClosedBlockAndTheRestUnrestyled() {
            let rest = "# Title\n\nsome **bold** and `code`\n\n- item\n"
            let w = EditorWindow("\n" + rest)
            defer { w.close() }
            w.select(w.length)
            w.pump()
            func restStyle() -> [String] {
                let start = w.length - (rest as NSString).length
                return (start..<w.length).map { offset in
                    let attributes = w.displayAttributes(at: offset)
                    let (text, index) = w.displayParagraph(at: offset)
                    return "\((text.string as NSString).character(at: index)) \(attributes[.font]!) \(attributes[.foregroundColor]!) \(attributes[.paragraphStyle]!) \(attributes[.codePanel] ?? "-")"
                }
            }
            let before = restStyle()
            #expect(w.isHidden(16) && w.displayFont(at: 3) == theme.headingFont(level: 1))

            w.select(0)
            w.type("```swift\r")
            #expect(w.textView.string == "```swift\n\n```\n" + rest)
            #expect(w.textView.selectedRange() == NSRange(location: 9, length: 0), "the caret is on the empty line inside")
            #expect(restStyle() == before, "nothing after the block changed")
            #expect(w.displayAttributes(at: 0)[.codePanel] as? CodePanel == CodePanel(x: 0, top: 0, bottom: nil))
            #expect(w.displayAttributes(at: 10)[.codePanel] as? CodePanel == CodePanel(x: 0, top: nil, bottom: 0))

            w.type("let x = 1")
            #expect(w.textView.string == "```swift\nlet x = 1\n```\n" + rest)
            #expect(w.displayAttributes(at: 9)[.foregroundColor] as? NSColor == theme.codeKeyword)
            #expect(restStyle() == before)
            #expect(w.storageProblem == nil)

            w.undoAll()
            #expect(w.textView.string == "\n" + rest)
            #expect(restStyle() == before)
        }

        // MARK: geometry of every kind together

        @Test func fragmentHeightsAreExact() {
            let source = "- item\n1. one\n- [ ] task\n> quote\n>\n```\ncode\n```\n---\n"
            let w = window(source)
            defer { w.close() }
            let margin = theme.codePanelMargin
            let expected: [(String, CGFloat)] = [
                ("- item", theme.bodyLineHeight), ("1. one", theme.bodyLineHeight), ("- [ ] task", theme.bodyLineHeight),
                ("> quote", theme.bodyLineHeight), (">\n", theme.blankLineHeight), ("```\ncode", theme.fenceLineHeight + margin),
                ("code", theme.codeBlockLineHeight), ("```\n---", theme.fenceLineHeight + margin), ("---", theme.ruleLineHeight),
            ]
            for (text, height) in expected {
                #expect(w.fragment(at: offset(text, in: w)).layoutFragmentFrame.height == height, "\(text.debugDescription)")
            }
        }
    }
}
