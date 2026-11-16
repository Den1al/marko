import AppKit
import Testing

extension EditorTests {
    /// The undocumented TextKit 2 behaviours the design rests on, checked on a bare NSTextView
    /// with none of the app's code: three for everything, and at the end those that the wrapping
    /// cells of a wide table need besides. Run this first after a macOS or Xcode update: a
    /// failure here names exactly what the system changed. Should the last test fail, set
    /// `ParagraphRenderer.wrapsWideTables` to false: such tables then show as their source.
    @Suite struct OSCanaryTests {
        private final class Substituter: NSObject, NSTextContentStorageDelegate {
            var queries = 0
            let font = NSFont.systemFont(ofSize: 16)
            let attachment: NSTextAttachment = {
                let attachment = NSTextAttachment()
                attachment.image = NSImage(size: NSSize(width: 40, height: 10), flipped: false) { _ in true }
                attachment.bounds = CGRect(x: 0, y: 0, width: 40, height: 10)
                return attachment
            }()

            /// "-" becomes a bullet, "|" a tab, "[" an attachment, and "~" keeps its character at 0.01pt.
            func textContentStorage(_ storage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
                queries += 1
                let source = storage.textStorage!.attributedSubstring(from: range)
                let display = NSMutableAttributedString(string: source.string, attributes: [.font: font])
                for (index, unit) in Array(source.string.utf16).enumerated() {
                    let one = NSRange(location: index, length: 1)
                    switch unit {
                    case 0x2D: display.replaceCharacters(in: one, with: "\u{2022}")
                    case 0x7C: display.replaceCharacters(in: one, with: "\t")
                    case 0x5B:
                        display.replaceCharacters(in: one, with: "\u{FFFC}")
                        display.addAttribute(.attachment, value: attachment, range: one)
                    case 0x7E: display.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.01), range: one)
                    default: break
                    }
                }
                return NSTextParagraph(attributedString: display)
            }
        }

        private let source = "- item\n|cell\n[x\n" + String(repeating: "~", count: 100) + "z\nlast\n"

        private func makeView(_ delegate: Substituter) -> (NSWindow, NSTextView) {
            NSApplication.shared.setActivationPolicy(.accessory)
            let window = NSWindow(
                contentRect: NSRect(x: 120, y: 160, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.moveToBuiltInDisplay()
            window.title = "Marko test (closes by itself)"
            let view = NSTextView(usingTextLayoutManager: true)
            view.frame = window.contentView!.bounds
            view.isRichText = false
            view.textContainer?.lineFragmentPadding = 0
            view.textContentStorage?.delegate = delegate
            window.contentView?.addSubview(view)
            window.orderFrontRegardless()
            view.string = source
            view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
            return (window, view)
        }

        /// x of the caret position before `offset`.
        private func caretX(_ view: NSTextView, _ offset: Int) -> CGFloat {
            let content = view.textContentStorage!, layout = view.textLayoutManager!
            var x = CGFloat.nan
            let location = content.location(content.documentRange.location, offsetBy: offset)!
            layout.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: []) { _, frame, _, _ in
                x = frame.minX
                return false
            }
            return x
        }

        @Test func sameLengthCharacterSubstitutionIsHonoured() {
            let delegate = Substituter()
            let (window, view) = makeView(delegate)
            defer { window.close() }
            #expect(view.string == source, "the storage keeps the source characters")
            let content = view.textContentStorage!
            let laidOut = view.textLayoutManager!.textLayoutFragment(for: content.documentRange.location)!.textLineFragments[0]
            #expect(laidOut.attributedString.string == "\u{2022} item\n", "a bullet is laid out in place of the hyphen")
            #expect(caretX(view, 8) >= 28, "a tab in place of the pipe advances to the first default tab stop")
            #expect(abs(caretX(view, 14) - 40) < 0.01, "U+FFFC with an attachment is as wide as its image")

            view.setSelectedRange(NSRange(location: 0, length: 0))
            for expected in 1...16 {
                view.moveRight(nil)
                #expect(view.selectedRange().location == expected, "caret offsets stay storage offsets")
            }
            #expect(view.textLayoutManager != nil)
        }

        @Test func editedAttributesMakesTheDelegateRenderAgain() {
            let delegate = Substituter()
            let (window, view) = makeView(delegate)
            defer { window.close() }
            let layout = view.textLayoutManager!, storage = view.textStorage!

            let before = delegate.queries
            layout.invalidateLayout(for: layout.documentRange)
            layout.ensureLayout(for: layout.documentRange)
            #expect(delegate.queries == before, "invalidating layout alone reuses the paragraphs (if this changes, the nudge can go)")

            view.textContentStorage!.performEditingTransaction {
                storage.edited(.editedAttributes, range: NSRange(location: 0, length: 7), changeInLength: 0)
            }
            layout.ensureLayout(for: layout.documentRange)
            #expect(delegate.queries > before, "an attribute-only edit makes TextKit ask for the paragraph again")
            #expect(view.string == source)
            #expect(view.undoManager?.canUndo != true, "and registers nothing to undo")
        }

        @Test func aHundredthOfAPointFontTakesNoVisibleWidth() {
            let delegate = Substituter()
            let (window, view) = makeView(delegate)
            defer { window.close() }
            let start = 16, hidden = 100
            let width = caretX(view, start + hidden) - caretX(view, start)
            #expect(width >= 0 && width < 0.01 * CGFloat(hidden), "hidden characters measured \(width / CGFloat(hidden))pt each")
            #expect(caretX(view, start + hidden + 1) - caretX(view, start + hidden) > 5, "and the text after them is laid out normally")
        }

        // MARK: wrapping cells (TableWrap.swift)

        /// "|a|b|c|" as three cells: each pipe between two becomes U+2028, and each cell's part of
        /// the paragraph gets a paragraph style of its own. Only the second cell's lines have a
        /// height; its first character makes its first line 40 points high.
        private final class Wrapper: NSObject, NSTextContentStorageDelegate {
            static let columns: [CGFloat] = [12, 150, 400, 560]

            func textContentStorage(_ storage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
                let source = storage.textStorage!.attributedSubstring(from: range).string as NSString
                guard source.hasPrefix("|") else { return nil }
                let display = NSMutableAttributedString(string: source as String, attributes: [.font: NSFont.systemFont(ofSize: 16)])
                let pipes = (0..<source.length).filter { source.character(at: $0) == 0x7C }
                for (cell, pipe) in pipes.dropLast().enumerated() {
                    let start = cell == 0 ? 0 : pipe + 1
                    let style = NSMutableParagraphStyle()
                    style.firstLineHeadIndent = Self.columns[cell]
                    style.headIndent = Self.columns[cell]
                    style.tailIndent = Self.columns[cell + 1] - 24
                    style.alignment = cell == 2 ? .right : .natural
                    style.minimumLineHeight = cell == 1 ? 26 : 0.01
                    style.maximumLineHeight = style.minimumLineHeight
                    display.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: pipes[cell + 1] + 1 - start))
                    if cell == 1 {
                        let first = style.mutableCopy() as! NSMutableParagraphStyle
                        first.minimumLineHeight = 40
                        first.maximumLineHeight = 40
                        display.addAttribute(.paragraphStyle, value: first, range: NSRange(location: start, length: 1))
                    }
                    display.replaceCharacters(in: NSRange(location: pipe, length: 1), with: cell == 0 ? "\u{2060}" : "\u{2028}")
                }
                return NSTextParagraph(attributedString: display)
            }
        }

        /// The height TextKit takes a paragraph to have that is not laid out, far from the
        /// window: the line height on its first character, once for every line it expects
        /// from the paragraph's length and that character's font. The heights of its other
        /// lines do not count. A row of wrapping cells therefore has its whole height on its
        /// first line and a first character in a font of no size, which makes that one line.
        @Test func aParagraphThatIsNotLaidOutIsTakenToBeAsHighAsItsFirstCharactersLineSays() throws {
            final class Rows: NSObject, NSTextContentStorageDelegate {
                var first: (font: NSFont, height: CGFloat) = (.systemFont(ofSize: 16), 26)
                func textContentStorage(_ storage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
                    let display = NSMutableAttributedString(attributedString: storage.textStorage!.attributedSubstring(from: range))
                    func style(_ height: CGFloat) -> NSParagraphStyle {
                        let style = NSMutableParagraphStyle()
                        style.minimumLineHeight = height
                        style.maximumLineHeight = height
                        return style
                    }
                    display.addAttributes([.font: NSFont.systemFont(ofSize: 16), .paragraphStyle: style(26)], range: NSRange(location: 0, length: display.length))
                    display.addAttributes([.font: first.font, .paragraphStyle: style(first.height)], range: NSRange(location: 0, length: 1))
                    return NSTextParagraph(attributedString: display)
                }
            }
            // In no window: nothing is shown. What is laid out is what the scroll view has room for.
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)), delegate = Rows()
            let view = NSTextView(usingTextLayoutManager: true)
            view.frame = scrollView.bounds
            view.isVerticallyResizable = true
            view.autoresizingMask = [.width]
            view.textContainer?.lineFragmentPadding = 0
            view.textContentStorage?.delegate = delegate
            scrollView.documentView = view
            let layout = try #require(view.textLayoutManager)
            let paragraph = String(repeating: "word ", count: 60) + "\n"
            /// What one more paragraph far below the window adds to the text's height.
            func guess() -> CGFloat {
                let heights = [3000, 2000].map { count -> CGFloat in
                    view.string = String(repeating: paragraph, count: count)
                    layout.textViewportLayoutController.layoutViewport()
                    return layout.usageBoundsForTextContainer.height
                }
                return (heights[0] - heights[1]) / 1000
            }
            // Laid out, the paragraph has three lines; the first is as high as its style says.
            #expect(abs(guess() - 78) < 0.5, "three lines of 26")
            delegate.first = (.systemFont(ofSize: 16), 100)
            #expect(abs(guess() - 300) < 0.5, "three lines of the first one's height, though the paragraph is 152 high")
            delegate.first = (.systemFont(ofSize: 0.01), 100)
            #expect(abs(guess() - 100) < 0.5, "one line of the first one's height")
            delegate.first = (.systemFont(ofSize: 0.01), 0.01)
            #expect(guess() < 0.5, "and next to nothing where the first line has no height")
        }

        @Test func aLineSeparatorAndAParagraphStyleOfItsOwnPutACellsLinesInItsColumn() throws {
            NSApplication.shared.setActivationPolicy(.accessory)
            let window = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.moveToBuiltInDisplay()
            window.title = "Marko test (closes by itself)"
            defer { window.close() }
            let delegate = Wrapper()
            let view = NSTextView(usingTextLayoutManager: true)
            view.frame = window.contentView!.bounds
            view.isRichText = false
            view.textContainer?.lineFragmentPadding = 0
            view.textContentStorage?.delegate = delegate
            window.contentView?.addSubview(view)
            window.orderFrontRegardless()
            let row = "| short | the second cell holds enough words to wrap over three lines of its column | third cell, two lines |"
            for end in ["\nafter\n", ""] {
                view.string = "before\n" + row + end
                let layout = try #require(view.textLayoutManager), content = try #require(view.textContentStorage)
                layout.ensureLayout(for: layout.documentRange)
                #expect(view.string == "before\n" + row + end, "the storage keeps the pipes")
                let fragment = try #require(layout.textLayoutFragment(for: content.location(content.documentRange.location, offsetBy: 7)!))
                let lines = fragment.textLineFragments, frame = fragment.layoutFragmentFrame
                // A line separator in a pipe's place ends a line: one for the first cell, three for the second, two for the third.
                #expect(lines.count == 6, "\(lines.map(\.characterRange))")
                guard lines.count == 6 else { continue }
                let second = (row as NSString).range(of: "| the").location + 1, third = (row as NSString).range(of: "| third").location + 1
                #expect(lines[1].characterRange.location == second && lines[4].characterRange.location == third)
                // Each line has the indents and the alignment of the style on its own characters.
                // Line boxes are relative to the paragraph's frame, whose left edge is the leftmost line's.
                let lefts = lines.map { frame.minX + $0.typographicBounds.minX }, rights = lines.map { frame.minX + $0.typographicBounds.maxX }
                #expect(abs(lefts[0] - 12) < 0.01 && lefts[1...3].allSatisfy { abs($0 - 150) < 0.01 }, "\(lefts)")
                #expect(rights[1...3].allSatisfy { $0 <= 376.5 } && rights[1] > 300, "the second cell's lines end at its tail indent: \(rights)")
                // A blank at the end of a right-aligned line hangs over its edge.
                #expect(lefts[4] > 400 && rights[4...5].allSatisfy { $0 > 530 && $0 < 541 }, "the third cell's lines are aligned right: \(rights)")
                // And its own height: next to nothing for a line of full-size text, and the height
                // that the style on a line's first character alone asks for.
                #expect(lines.map { ($0.typographicBounds.height * 100).rounded() / 100 } == [0.01, 40, 26, 26, 0.01, 0.01])
                // The paragraph is as high as its lines together, with or without a line break behind it.
                #expect(abs(frame.height - 92.03) < 0.001, "\(frame.height)")
                // Text stands at the foot of its line's box, whatever the height.
                #expect(Set(lines.map { (($0.typographicBounds.height - $0.glyphOrigin.y) * 100).rounded() }).count == 1, "\(lines.map(\.glyphOrigin.y))")
                // A character's place is told from its line's start, and the text system's own caret offsets are in the container's coordinates.
                #expect(lines[2].locationForCharacter(at: lines[2].characterRange.location).x == 0)
                var offsets: [CGFloat] = []
                layout.enumerateCaretOffsetsInLineFragment(at: content.location(content.documentRange.location, offsetBy: 7 + lines[2].characterRange.location)!) { x, _, _, _ in
                    offsets.append(x)
                }
                #expect(abs((offsets.first ?? 0) - 150) < 0.01 && (offsets.last ?? 0) > 300, "\(offsets.prefix(3))")
            }
            #expect(view.textLayoutManager != nil)
        }
    }
}
