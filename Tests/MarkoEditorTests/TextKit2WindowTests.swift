import AppKit
import FixtureSupport
@testable import MarkoEditor
import Testing

extension EditorTests {
    /// Runs in a window that is ordered on screen: the TextKit 1 fallback only fires in a windowed view.
    @Suite struct TextKit2WindowTests {
        @Test func staysOnTextKit2AfterTypingUndoAndFind() throws {
            NSApplication.shared.setActivationPolicy(.accessory)
            var fallbacks = 0
            let observer = NotificationCenter.default.addObserver(
                forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: nil, queue: nil
            ) { _ in MainActor.assumeIsolated { fallbacks += 1 } }
            defer { NotificationCenter.default.removeObserver(observer) }

            let editor = EditorController()
            let textView = editor.textView
            let window = NSWindow(
                contentRect: NSRect(x: 120, y: 160, width: 900, height: 500),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.moveToBuiltInDisplay()
            window.title = "Marko test (closes by itself)"
            window.contentView = editor.view
            window.makeFirstResponder(textView)
            window.orderFrontRegardless()
            defer { window.close() }

            let source = try String(contentsOf: Fixtures.url("kitchen-sink.md"), encoding: .utf8)
            editor.text = source
            pump()
            #expect(window.isVisible)
            #expect(textView.textLayoutManager != nil)
            #expect(textView.columnLeft == ((textView.frame.width - Theme.standard.maximumTextWidth) / 2).rounded(.down))

            textView.setSelectedRange(NSRange(location: 0, length: 0))
            for character in "needle \"q\" -- " {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    window.sendEvent(try #require(NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: String(character),
                        charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)))
                }
                pump(0.005)
            }
            #expect(textView.string == "needle \"q\" -- " + source, "typed text is inserted verbatim, with no smart substitution")
            #expect(textView.textLayoutManager != nil)

            while textView.undoManager?.canUndo == true { textView.undoManager?.undo() }
            pump()
            #expect(textView.string == source)
            textView.undoManager?.redo()
            pump()
            #expect(textView.string.hasPrefix("needle "))
            #expect(textView.textLayoutManager != nil)

            // The find bar shares its search string through the system find pasteboard; put the user's back afterwards.
            let findPasteboard = NSPasteboard(name: .find)
            let savedSearch = findPasteboard.string(forType: .string)
            defer {
                findPasteboard.clearContents()
                if let savedSearch { findPasteboard.setString(savedSearch, forType: .string) }
            }
            findPasteboard.clearContents()
            findPasteboard.setString("needle", forType: .string)

            textView.setSelectedRange(NSRange(location: 20, length: 0))
            finderAction(.showFindInterface, textView)
            pump(0.3)
            #expect(editor.scrollView.isFindBarVisible)
            finderAction(.nextMatch, textView)
            pump(0.2)
            #expect(textView.selectedRange() == NSRange(location: 0, length: 6), "find next wraps to the typed match")
            finderAction(.hideFindInterface, textView)
            pump(0.1)
            #expect(!editor.scrollView.isFindBarVisible)

            #expect(textView.textLayoutManager != nil)
            #expect(fallbacks == 0)
            #expect(textView.textStorage?.string.hasPrefix("needle ") == true)
        }

        @Test func editorTextViewIsPlainWithSubstitutionsOff() {
            let textView = EditorTextView.make()
            #expect(textView.textLayoutManager != nil)
            #expect(!textView.isRichText)
            #expect(textView.allowsUndo)
            #expect(textView.usesFindBar)
            #expect(!textView.isIncrementalSearchingEnabled)
            #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
            #expect(!textView.isAutomaticDashSubstitutionEnabled)
            #expect(!textView.isAutomaticTextReplacementEnabled)
            #expect(!textView.isAutomaticSpellingCorrectionEnabled)
            #expect(!textView.isAutomaticLinkDetectionEnabled)
            #expect(!textView.smartInsertDeleteEnabled)
            #expect(!textView.usesFontPanel)
            #expect(!textView.usesRuler)
        }

        private func finderAction(_ action: NSTextFinder.Action, _ textView: NSTextView) {
            let item = NSMenuItem()
            item.tag = action.rawValue
            textView.performTextFinderAction(item)
        }

        private func pump(_ seconds: TimeInterval = 0.05) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        }
    }
}
