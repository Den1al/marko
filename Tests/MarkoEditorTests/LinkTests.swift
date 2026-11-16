import AppKit
import FixtureSupport
import Testing
@testable import MarkoEditor

extension EditorTests {
    @Suite struct LinkTests {
        private let theme = Theme.standard

        private func middle(_ w: EditorWindow, of text: String) -> NSPoint {
            let rect = w.characterRect(at: w.offset(of: text) + 1)
            return NSPoint(x: rect.midX, y: rect.midY)
        }

        @Test func aCommandClickOpensTheLinkAndAPlainClickDoesNot() {
            let w = EditorWindow("see [the site](https://example.com/a?b=c) and <https://auto.example> or plain text\n\nend\n")
            defer { w.close() }
            var opened: [URL] = []
            w.editor.linkOpener = { opened.append($0) }
            w.select(w.length)
            w.pump()

            w.mouseDown(at: middle(w, of: "the site"), modifiers: .command)
            #expect(opened.map(\.absoluteString) == ["https://example.com/a?b=c"])
            w.mouseDown(at: middle(w, of: "auto.example"), modifiers: .command)
            #expect(opened.map(\.absoluteString) == ["https://example.com/a?b=c", "https://auto.example"])
            #expect(w.textView.selectedRange() == NSRange(location: w.length, length: 0), "opening a link leaves the caret alone")

            // Without Command, and on text that is no link, the click is the text view's.
            #expect(w.textView.clickHandler?(middle(w, of: "the site"), []) == false)
            #expect(w.textView.clickHandler?(middle(w, of: "plain text"), .command) == false)
            #expect(opened.count == 2)
        }

        @Test func relativeLinksAndReferenceLinksResolveAgainstTheDocument() {
            let document = Fixtures.url("images.md").absoluteURL
            let w = EditorWindow("[other](lf.md) [ref][r] [web][w]\n\n[r]: images/pic.png\n[w]: https://example.com\n", documentURL: document)
            defer { w.close() }
            var opened: [URL] = [], revealed: [URL] = []
            w.editor.linkOpener = { opened.append($0) }
            w.editor.fileRevealer = { revealed.append($0) }
            w.select(w.length)
            w.pump()
            for text in ["other", "ref", "web"] { w.mouseDown(at: middle(w, of: text), modifiers: .command) }
            #expect(opened.count == 2)
            #expect(opened.first?.standardizedFileURL.path == Fixtures.url("lf.md").path)
            #expect(opened.last?.absoluteString == "https://example.com")
            #expect(opened.first?.isFileURL == true)
            #expect(revealed.map(\.standardizedFileURL.path) == [Fixtures.url("images/pic.png").path], "a file that is not Markdown is only shown")
        }

        /// A document from somewhere else must not be able to start a program with a click.
        @Test func onlyWebMailAndMarkdownLinksAreOpened() {
            let w = EditorWindow(documentURL: URL(fileURLWithPath: "/tmp/marko-test/doc.md"))
            defer { w.close() }
            var opened: [String] = [], revealed: [String] = []
            w.editor.linkOpener = { opened.append($0.absoluteString) }
            w.editor.fileRevealer = { revealed.append($0.path) }
            for destination in ["./run.command", "file:///System/Applications/Calculator.app", "/bin/sh", "tool.terminal", "a.workflow",
                                "x-custom://run", "javascript:alert(1)", "ssh://host", "vnc://host", "tel:123", "FILE:///bin/ls", "notes.MD",
                                "https://example.com", "HTTP://example.com", "mailto:a@b.c", "other.markdown"] {
                w.editor.open(destination)
            }
            #expect(opened == ["file:///tmp/marko-test/notes.MD", "https://example.com", "HTTP://example.com", "mailto:a@b.c",
                               "file:///tmp/marko-test/other.markdown"])
            #expect(revealed == ["/tmp/marko-test/run.command", "/System/Applications/Calculator.app", "/bin/sh",
                                 "/tmp/marko-test/tool.terminal", "/tmp/marko-test/a.workflow", "/bin/ls"])
        }

        @Test func aLinkInAnUnsavedDocumentWithNowhereToStartFromOpensNothing() {
            let w = EditorWindow("[other](lf.md)\n")
            defer { w.close() }
            var opened: [URL] = []
            w.editor.linkOpener = { opened.append($0) }
            w.mouseDown(at: middle(w, of: "other"), modifiers: .command)
            #expect(opened.isEmpty)
        }

        @Test func anAnchorLinkScrollsToItsHeading() throws {
            let filler = (1...80).map { "Paragraph \($0).\n\n" }.joined()
            let text = "# Top\n\n[go](#the-second-part) [nowhere](#missing)\n\n" + filler + "## The *second* part\n\n" + filler
            let w = EditorWindow(text, size: NSSize(width: 700, height: 400))
            defer { w.close() }
            var opened: [URL] = []
            w.editor.linkOpener = { opened.append($0) }
            let heading = w.offset(of: "## The")
            #expect(w.textView.visibleRect.minY == 0)

            w.mouseDown(at: middle(w, of: "go"), modifiers: .command)
            w.pump()
            #expect(opened.isEmpty, "an anchor is not handed out")
            #expect(w.textView.selectedRange() == NSRange(location: heading + 3, length: 0))
            let frame = w.fragment(at: heading).layoutFragmentFrame, visible = w.textView.visibleRect
            let top = frame.minY + w.textView.textContainerOrigin.y
            #expect(top >= visible.minY && top < visible.minY + 100, "the heading is at the top of the window: \(top) in \(visible)")

            w.editor.open("#missing")
            #expect(w.textView.selectedRange() == NSRange(location: heading + 3, length: 0), "an unknown anchor does nothing")
        }

        @Test func aLinkUnderTheMouseIsUnderlinedWhileCommandIsHeld() {
            let w = EditorWindow("see [the site](https://example.com) and plain text\n\n| [cell](u) | b |\n|---|---|\n\nend\n")
            defer { w.close() }
            w.select(w.length)
            w.pump()
            let link = w.offset(of: "the site")
            func isUnderlined(_ offset: Int) -> Bool { w.displayAttributes(at: offset)[.underlineStyle] != nil }
            #expect(!isUnderlined(link), "no underline until hovered or revealed")

            w.mouseMoved(to: middle(w, of: "the site"))
            #expect(!isUnderlined(link), "not without Command")
            w.mouseMoved(to: middle(w, of: "the site"), modifiers: .command)
            #expect(isUnderlined(link) && !isUnderlined(w.offset(of: "plain")))
            #expect(w.isHidden(w.offset(of: "](https")), "hovering reveals nothing")
            w.mouseMoved(to: middle(w, of: "plain text"), modifiers: .command)
            #expect(!isUnderlined(link))

            // In a table too, and letting go of Command takes the underline away.
            let cell = w.offset(of: "cell")
            w.mouseMoved(to: middle(w, of: "cell"), modifiers: .command)
            #expect(isUnderlined(cell))
            w.mouseMoved(to: middle(w, of: "cell"))
            #expect(!isUnderlined(cell))
            #expect(w.storageProblem == nil)
        }
    }
}
