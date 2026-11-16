import AppKit
import FixtureSupport
import Testing
@testable import MarkoEditor

extension EditorTests {
    @Suite struct ChromeTests {
        private let theme = Theme.standard

        @Test func theTextColumnIsCentredAndCappedAndFollowsTheWindowWidth() {
            let w = EditorWindow("text\n", size: NSSize(width: 1200, height: 500))
            defer { w.close() }
            // Without a table the container is the column, so that a wide window made wider lays out nothing again.
            #expect(w.textView.columnWidth == theme.maximumTextWidth && w.textView.textContainer?.size.width == theme.maximumTextWidth)
            #expect(w.textView.textContainerInset.width == (1200 - theme.maximumTextWidth) / 2)
            let line = w.fragment(at: 0)
            w.window.setContentSize(NSSize(width: 1300, height: 500))
            w.pump()
            #expect(w.textView.textContainerInset.width == (1300 - theme.maximumTextWidth) / 2 && w.fragment(at: 0) === line, "only the margins changed")
            w.window.setContentSize(NSSize(width: 1200, height: 500))
            w.pump()
            // With a table it is the page from padding to padding, which is room for a wide grid, and the column stays where it was.
            w.select(w.length)
            w.type("\n| a | b |\r")
            #expect(w.textView.string.contains("|---|---|") || w.textView.string.contains("| --- | --- |"))
            #expect(w.textView.columnWidth == theme.maximumTextWidth && w.textView.textContainer?.size.width == 1200 - 2 * theme.pagePadding.width)
            #expect(w.textView.columnLeft == (1200 - theme.maximumTextWidth) / 2 && w.columnX(at: 0) == 0)
            // It stays so when the table goes, until another text is loaded: every change of the container lays everything out again.
            w.undoAll()
            #expect(w.textView.string == "text\n" && w.textView.textContainer?.size.width != theme.maximumTextWidth)
            w.editor.text = "other\n"
            #expect(w.textView.textContainer?.size.width == theme.maximumTextWidth)

            w.window.setContentSize(NSSize(width: 500, height: 500))
            w.pump()
            #expect(w.textView.textContainerInset.width == theme.pagePadding.width)
            #expect(w.textView.columnWidth == 500 - 2 * theme.pagePadding.width && w.textView.textContainer?.size.width == w.textView.columnWidth)
            #expect(w.textView.textLayoutManager != nil)
        }

        @Test func chromeComesFromTheTheme() {
            let w = EditorWindow("text\n")
            defer { w.close() }
            #expect(w.editor.scrollView.scrollerStyle == .overlay)
            #expect(w.editor.scrollView.backgroundColor == theme.background)
            #expect(w.textView.backgroundColor == theme.background)
            #expect(w.textView.selectedTextAttributes[.backgroundColor] as? NSColor == theme.selection)
            #expect(w.textView.insertionPointColor == theme.accent)
            #expect(theme.maximumTextWidth >= 760 && theme.maximumTextWidth <= 820)
            #expect(theme.bodyLineHeight / theme.bodySize > 1.5)

            let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
            func background(_ appearance: NSAppearance) -> CGFloat {
                var white: CGFloat = 0
                appearance.performAsCurrentDrawingAppearance {
                    white = theme.background.usingColorSpace(.genericGray)!.whiteComponent
                }
                return white
            }
            #expect(background(light) > 0.9 && background(light) < 1, "soft off-white")
            #expect(background(dark) < 0.2 && background(dark) > 0, "near-black")
        }

        @Test func theTitlebarBandIsOpaqueAndTheFadeHangsBelowIt() throws {
            let window = NSWindow(
                contentRect: NSRect(x: 120, y: 160, width: 500, height: 300),
                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.moveToBuiltInDisplay()
            window.titlebarAppearsTransparent = true
            let editor = EditorController()
            window.contentView = editor.view
            window.orderFrontRegardless()
            defer { window.close() }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

            let band = editor.view.safeAreaInsets.top
            #expect(band > 20, "the content runs under the titlebar")
            let titlebar = try #require(editor.view.subviews.last)
            #expect(titlebar.frame.maxY == editor.view.bounds.maxY)
            #expect(abs(titlebar.frame.height - (band + theme.titlebarFadeHeight)) < 0.5)

            let bitmap = try #require(titlebar.bitmapImageRepForCachingDisplay(in: titlebar.bounds))
            titlebar.cacheDisplay(in: titlebar.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / titlebar.bounds.height
            // Bitmap rows count from the top.
            func alpha(_ y: CGFloat) -> CGFloat { bitmap.colorAt(x: 10, y: Int(y * scale))!.alphaComponent }
            #expect(alpha(1) > 0.99 && alpha(band - 1) > 0.99, "nothing shows through where the title is")
            #expect(alpha(band + theme.titlebarFadeHeight / 2) > 0.2 && alpha(band + theme.titlebarFadeHeight / 2) < 0.8)
            #expect(alpha(band + theme.titlebarFadeHeight - 0.5) < 0.1, "the fade ends clear")
        }

        /// The first key brings the mark of unsaved changes and a save takes it away again. The
        /// name is centred by itself and stays where it is; the mark hangs to its right.
        @Test func theNameInTheTitleStaysWhereItIsWhenTheEditedMarkComesAndGoes() throws {
            let window = NSWindow(
                contentRect: NSRect(x: 120, y: 160, width: 700, height: 300),
                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.moveToBuiltInDisplay()
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Untitled"
            let editor = EditorController()
            window.contentView = editor.view
            window.orderFrontRegardless()
            defer { window.close() }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

            let titlebar = editor.titlebar
            /// The columns of the title's band that have ink, in points from the left.
            func ink() throws -> ClosedRange<CGFloat> {
                let bitmap = try #require(titlebar.bitmapImageRepForCachingDisplay(in: titlebar.bounds))
                titlebar.cacheDisplay(in: titlebar.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / titlebar.bounds.width, band = Int(editor.view.safeAreaInsets.top * scale)
                let page = try #require(bitmap.colorAt(x: 2, y: 2))
                let columns = (0..<bitmap.pixelsWide).filter { x in (0..<band).contains { bitmap.colorAt(x: x, y: $0) != page } }
                return CGFloat(try #require(columns.first)) / scale...CGFloat(try #require(columns.last) + 1) / scale
            }
            let name = try ink()
            #expect(abs((name.lowerBound + name.upperBound) / 2 - titlebar.bounds.midX) < 1.5, "the name is centred")
            editor.isEdited = true
            let marked = try ink()
            #expect(titlebar.title == "Untitled — Edited")
            #expect(marked.lowerBound == name.lowerBound, "the name has not moved")
            #expect(marked.upperBound > name.upperBound + 20, "the mark stands behind it")
            editor.isEdited = false
            #expect(try ink() == name)

            // A name too long for that is centred with its mark and cut in the middle.
            window.title = String(repeating: "a very long name ", count: 12)
            editor.isEdited = true
            let long = try ink()
            #expect(long.lowerBound >= theme.titleInset - 1 && long.upperBound <= titlebar.bounds.width - theme.titleInset + 1)
        }

        @Test func theWordCountFollowsTheText() async throws {
            let w = EditorWindow("One **two** three.\n\n- four\n")
            defer { w.close() }
            let label = w.editor.wordCount
            #expect(label.superview?.superview?.isHidden == true, "nothing shows before the first count")
            #expect(await wait { label.stringValue == "4 words" } && !label.isHidden && label.superview?.superview?.isHidden == false)
            w.select(w.length)
            w.type("five six")
            #expect(label.stringValue == "4 words", "counted when the typing pauses")
            #expect(await wait { label.stringValue == "6 words" })
            w.undoAll()
            #expect(await wait { label.stringValue == "4 words" })
            w.editor.text = "alone"
            #expect(await wait { label.stringValue == "1 word" })
            w.pump()
            let capsule = try #require(label.superview?.superview), frame = capsule.frame
            #expect(abs(frame.maxX - (w.editor.view.bounds.maxX - theme.statusInset.width)) < 0.5)
            #expect(abs(frame.minY - theme.statusInset.height) < 0.5, "in the bottom corner")
            // A document without a trusted folder is in safe mode, whose mark stands in front of the count.
            let text = label.alignmentRect(forFrame: label.frame), mark = w.editor.safeMode
            #expect(w.editor.isInSafeMode && !mark.isHidden && abs(mark.frame.maxX + theme.statusGap - text.minX) < 0.5)
            #expect(abs(frame.width - (mark.frame.width + theme.statusGap + text.width + 2 * theme.statusPadding.width)) < 0.5, "a capsule just around the two")
            #expect(!label.drawsBackground, "nothing opaque lies over the document")
        }

        @Test func theWordCountNeverLiesOnTheText() async throws {
            let text = String(repeating: "A line of text that is long enough to reach the right edge of the text column wherever that is.\n\n", count: 40)
            let w = EditorWindow(text, size: NSSize(width: 880, height: 500))
            defer { w.close() }
            #expect(await wait { !w.editor.wordCount.stringValue.isEmpty })
            let capsule = try #require(w.editor.wordCount.superview?.superview), footer = w.editor.footer
            func columnEdge() -> CGFloat { w.textView.textContainerOrigin.x + w.textView.columnWidth }
            // Too narrow for the readout beside the column: the foot of the window is kept clear for it.
            for width in [880.0, 500, 360] {
                w.window.setContentSize(NSSize(width: width, height: 500))
                w.pump()
                #expect(capsule.frame.minX < columnEdge() && !footer.isHidden, "\(width)")
                #expect(footer.frame.minY == 0 && footer.frame.width == w.editor.view.bounds.width)
                #expect(footer.frame.maxY == capsule.frame.maxY + theme.titlebarFadeHeight, "opaque up to the capsule's top, then the fade")
                #expect(footer.frame.maxY <= theme.scrollMargin, "a selection scrolled into view stays above it")
            }
            // The page's last line ends above the readout.
            w.select(w.length)
            w.editor.scrollToSelection()
            w.pump()
            let last = w.textView.convert(w.characterRect(at: w.length - 3), to: w.editor.view)
            #expect(last.minY >= capsule.frame.maxY)
            // Wide enough: it floats in the margin and nothing is covered.
            w.window.setContentSize(NSSize(width: 1100, height: 500))
            w.pump()
            #expect(capsule.frame.minX >= columnEdge() + theme.statusInset.width && footer.isHidden)
            Theme.showsWordCount = false
            defer { Theme.showsWordCount = true }
            w.window.setContentSize(NSSize(width: 500, height: 500))
            w.pump()
            #expect(w.editor.wordCount.isHidden && !capsule.isHidden && !footer.isHidden, "the mark of safe mode stays, and clear of the text")
        }

        @Test func scrollingToTheSelectionLeavesRoomAroundIt() throws {
            let document = Fixtures.url("kitchen-sink.md").absoluteURL
            let text = try String(contentsOf: document, encoding: .utf8)
            for location in [(text as NSString).length, (text as NSString).range(of: "Footnote text").location, 1070, 400, 0] {
                // As when a document is restored: straight after loading, before anything below the first screen is laid out.
                let w = EditorWindow(text, size: NSSize(width: 880, height: 500), documentURL: document)
                defer { w.close() }
                w.select(location)
                w.editor.scrollToSelection()
                w.pump(0.2)
                let caret = w.textView.convert(w.window.convertFromScreen(w.textView.firstRect(forCharacterRange: w.textView.selectedRange(), actualRange: nil)), from: nil)
                let visible = w.textView.visibleRect, margin = theme.scrollMargin - 1
                #expect(caret.height > 0 && caret.minY >= min(visible.minY + margin, caret.minY.rounded(.down)) && caret.minY >= visible.minY, "\(location)")
                let roomBelow = min(margin, w.textView.bounds.maxY - caret.maxY)
                #expect(caret.maxY <= visible.maxY - roomBelow, "\(location): \(caret) in \(visible)")
            }
        }

        /// Pixels of what BlockFragment draws: geometry cannot tell whether anything was painted.
        @Test func hairlinesAndInlineCodeBackgroundsAreDrawn() throws {
            let w = EditorWindow("# Title\n\nsome   `code`   here\n\nplain\n")
            defer { w.close() }
            w.select(w.length)
            w.pump()
            let view = w.textView
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            func isBackground(_ x: CGFloat, _ y: CGFloat) -> Bool {
                let color = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.sRGB)!
                let corner = bitmap.colorAt(x: 2, y: 2)!.usingColorSpace(.sRGB)!
                return abs(color.redComponent - corner.redComponent) + abs(color.greenComponent - corner.greenComponent)
                    + abs(color.blueComponent - corner.blueComponent) < 0.01
            }
            let origin = view.textContainerOrigin, columnWidth = view.columnWidth

            let heading = w.fragment(at: 0)
            let ruleY = origin.y + heading.layoutFragmentFrame.minY + heading.textLineFragments[0].typographicBounds.maxY
                + theme.hairlineGap + theme.hairlineWidth / 2
            #expect(!isBackground(origin.x + columnWidth - 10, ruleY), "the hairline spans the column")
            #expect(!isBackground(origin.x + 10, ruleY))
            #expect(isBackground(origin.x + columnWidth - 10, ruleY - 4))
            #expect(isBackground(origin.x + columnWidth + 6, ruleY), "and stops at its edge")

            let line = w.fragment(at: 9)
            let midY = origin.y + line.layoutFragmentFrame.midY
            let codeStart = line.textLineFragments[0].locationForCharacter(at: 8).x
            let codeEnd = line.textLineFragments[0].locationForCharacter(at: 12).x
            #expect(!isBackground(origin.x + codeStart - theme.inlineCodePadding.width / 2, midY), "the fill pads the code span")
            #expect(!isBackground(origin.x + codeEnd + theme.inlineCodePadding.width / 2, midY))
            #expect(isBackground(origin.x + codeStart - theme.inlineCodePadding.width - 4, midY))
            #expect(isBackground(origin.x + codeEnd + theme.inlineCodePadding.width + 4, midY))
            #expect(isBackground(origin.x + (codeStart + codeEnd) / 2, origin.y + line.layoutFragmentFrame.minY + 1), "and is shorter than the line")
        }

        /// TextKit 2 replaces estimated heights above the viewport as it scrolls up; without
        /// anchoring the text on screen jumps by the correction.
        @Test func scrollingUpThroughUnmeasuredTextDoesNotMoveWhatIsOnScreen() {
            var source = ""
            for index in 0..<3000 {
                switch index % 7 {
                case 0: source += "## Heading \(index)\n\n"
                case 3: source += String(repeating: "A long paragraph with **bold** words that wraps over several lines. ", count: 6) + "\n\n"
                default: source += "Line \(index) with `code` and a [link](http://example.com/\(index)).\n"
                }
            }
            let w = EditorWindow(source, size: NSSize(width: 700, height: 500))
            defer { w.close() }
            let clip = w.editor.scrollView.contentView
            func scroll(to y: CGFloat) {
                clip.scroll(to: NSPoint(x: 0, y: y))
                w.editor.scrollView.reflectScrolledClipView(clip)
                w.pump(0.02)
            }
            /// A laid-out fragment in the middle of the viewport and its distance from the viewport top.
            func probe() -> (offset: Int, y: CGFloat) {
                let fragment = w.layout.textLayoutFragment(
                    for: CGPoint(x: 1, y: clip.bounds.midY - w.textView.textContainerOrigin.y))!
                let offset = w.content.offset(from: w.content.documentRange.location, to: fragment.rangeInElement.location)
                return (offset, fragment.layoutFragmentFrame.minY - clip.bounds.minY)
            }
            func screenY(_ offset: Int) -> CGFloat {
                let location = w.content.location(w.content.documentRange.location, offsetBy: offset)!
                return w.layout.textLayoutFragment(for: location)!.layoutFragmentFrame.minY - clip.bounds.minY
            }

            scroll(to: w.textView.frame.height * 0.6)
            var moved: [CGFloat] = [], frameChanges = 0
            for _ in 0..<40 {
                let before = probe(), origin = clip.bounds.minY, height = w.textView.frame.height
                scroll(to: origin - 150)
                if w.textView.frame.height != height { frameChanges += 1 }
                moved.append(screenY(before.offset) - before.y)
            }
            #expect(frameChanges > 0, "the scroll replaced height estimates, so there was something to correct")
            #expect(moved.allSatisfy { abs($0 - 150) < 1 }, "on-screen movement per 150pt step: \(moved.map { Int($0.rounded()) })")
            #expect(w.textView.textLayoutManager != nil)
        }
    }
}
