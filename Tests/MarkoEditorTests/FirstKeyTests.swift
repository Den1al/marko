import AppKit
import Testing
@testable import MarkoEditor

extension EditorTests {
    /// The first keys in an empty document: every frame shows the text as it is, laid out, and
    /// nothing but the typed text moves.
    @Suite struct FirstKeyTests {
        /// Asks TextKit for the layout whenever the selection changes, between an edit and its
        /// textDidChange, as the text view of a key window does for its insertion point. The
        /// tests' windows are never key.
        private final class Caret: NSObject {
            private let layout: NSTextLayoutManager

            init(_ window: EditorWindow) {
                layout = window.layout
                super.init()
                NotificationCenter.default.addObserver(
                    self, selector: #selector(selectionDidChange), name: NSTextView.didChangeSelectionNotification, object: window.textView)
            }

            @objc private func selectionDidChange() {
                layout.ensureLayout(for: layout.documentRange)
            }
        }

        /// Where everything is that typing must not move.
        private struct Places: Equatable {
            var column: NSPoint
            var containerWidth: CGFloat
            var firstLine: NSPoint?
            var scroll: NSPoint
            var windowFrame: NSRect
            var capsuleEdge: NSPoint
            var capsuleHeight: CGFloat
            var isCapsuleHidden: Bool
        }

        private func places(_ w: EditorWindow) -> Places {
            let capsule = w.editor.wordCount.superview!
            return Places(
                column: w.textView.textContainerOrigin, containerWidth: w.textView.textContainer!.size.width,
                firstLine: w.layout.textLayoutFragment(for: w.layout.documentRange.location)?.layoutFragmentFrame.origin,
                scroll: w.editor.scrollView.contentView.bounds.origin, windowFrame: w.window.frame,
                capsuleEdge: NSPoint(x: capsule.frame.maxX, y: capsule.frame.minY), capsuleHeight: capsule.frame.height,
                isCapsuleHidden: capsule.isHidden)
        }

        @Test(arguments: [true, false])
        func everyFrameOfTheFirstKeysShowsTheTextLaidOutAndNothingElseMoves(asInAKeyWindow: Bool) async {
            let w = EditorWindow("")
            defer { w.close() }
            let caret = asInAKeyWindow ? Caret(w) : nil
            defer { withExtendedLifetime(caret) {} }
            // The word count shows once the empty text is counted.
            #expect(await wait { !w.editor.wordCount.stringValue.isEmpty })
            w.pump()
            var before = places(w)
            #expect(!before.isCapsuleHidden)
            // An empty text has no paragraph; the first one starts where the caret stands in it.
            let start = w.caretRect(at: 0)
            #expect(before.firstLine == nil && start.origin == .zero)
            before.firstLine = .zero

            var typed = ""
            for character in "Hello world\rSecond\r# Title\r- item" {
                w.type(String(character))
                typed.append(character)
                // The frame that follows the key is made in the run-loop turn `type` waits for.
                // Nothing here asks for a display: that lays the text out once more.
                #expect(w.paintProblem == nil, "after \(typed.debugDescription): \(w.paintProblem ?? "")")
                #expect(places(w) == before, "after \(typed.debugDescription): \(places(w)), not \(before)")
            }
            #expect(w.textView.string == "Hello world\nSecond\n# Title\n- item")
            #expect(w.characterRect(at: 0).minX == w.textView.textContainerOrigin.x && w.fragment(at: 0).layoutFragmentFrame.height == start.height,
                    "the first line is as high as the empty text's caret")
            #expect(w.storageProblem == nil)
        }

        /// A marker without its blank is an item already. The blank moves the caret; the bullet
        /// and the number stand where they stand in the finished item.
        @Test(arguments: ["-", "1."])
        func aListMarkerStandsWhereItWillWhenItsBlankIsTyped(marker: String) throws {
            let w = EditorWindow("")
            defer { w.close() }
            func markerX() throws -> CGFloat {
                let fragment = try #require(w.fragment(at: 0) as? BlockFragment)
                if let bullet = fragment.bullets.first { return w.inColumn(bullet.rect, ofFragmentAt: 0).minX }
                return w.columnX(at: 0)
            }
            w.type(marker)
            let bare = try markerX(), caret = w.caretRect(at: w.length).minX
            w.type(" ")
            #expect(try abs(markerX() - bare) < 0.01, "the marker stays")
            #expect(w.caretRect(at: w.length).minX > caret, "the blank moves the caret")
            let content = w.caretRect(at: w.length).minX
            w.type("x")
            #expect(try abs(markerX() - bare) < 0.01)
            #expect(abs(w.columnX(at: w.length - 1) - content) < 0.01, "and the text starts where the caret stood")
        }
    }
}
