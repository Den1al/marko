import AppKit
import FixtureSupport
import Testing
@testable import MarkoApp
@testable import MarkoEditor

extension EditorTests {
    /// The path a file takes in the app: NSDocument read, hand-off to the editor, NSDocument write.
    @Suite struct DocumentTests {
        private let type = "net.daringfireball.markdown"

        /// A fixture's web image must not be fetched for real.
        init() { WebStub.install() }

        @Test func everyFixtureSavesByteIdenticalThroughTheDocument() throws {
            #expect(Fixtures.all.count >= 13)
            for url in Fixtures.all {
                let original = try Data(contentsOf: url)
                let document = MarkdownDocument()
                defer { document.close() }
                try document.read(from: original, ofType: type)
                #expect(try document.data(ofType: type) == original, "\(url.lastPathComponent) before a window exists")

                document.makeWindowControllers()
                let editor = try #require(document.editor)
                #expect(editor.textView.window === document.windowControllers.first?.window)
                #expect(editor.text.unicodeScalars.first != "\u{FEFF}")
                #expect(try document.data(ofType: type) == original, "\(url.lastPathComponent) through the editor")
            }
        }

        @Test func editsAreSavedAndTheBOMIsKept() throws {
            let document = MarkdownDocument()
            defer { document.close() }
            try document.read(from: Fixtures.data("bom.md"), ofType: type)
            document.makeWindowControllers()
            let editor = try #require(document.editor)
            editor.textView.insertText("Xé", replacementRange: NSRange(location: 0, length: 0))
            #expect(try document.data(ofType: type) == Data([0xEF, 0xBB, 0xBF]) + Data("Xé".utf8) + Fixtures.data("bom.md").dropFirst(3))
        }

        /// Revert reads into a document that already has its editor.
        @Test func readingAgainReplacesTheEditorText() throws {
            let document = MarkdownDocument()
            defer { document.close() }
            try document.read(from: Fixtures.data("bom.md"), ofType: type)
            document.makeWindowControllers()
            let crlf = try Fixtures.data("crlf.md")
            try document.read(from: crlf, ofType: type)
            #expect(document.editor?.text == String(decoding: crlf, as: UTF8.self))
            #expect(try document.data(ofType: type) == crlf)
        }

        @Test func nonUTF8DataFailsToReadAndLeavesTheDocumentAlone() throws {
            let document = MarkdownDocument()
            defer { document.close() }
            let lf = try Fixtures.data("lf.md")
            try document.read(from: lf, ofType: type)
            #expect(throws: CocoaError.self) { try document.read(from: Data([0x63, 0x61, 0x66, 0xE9]), ofType: self.type) }
            #expect(try document.data(ofType: type) == lf)
        }

        // MARK: the document on disk

        /// A fixture copied to a folder of its own, which is removed again by `cleanUp`.
        private func temporaryCopy(of name: String) throws -> URL {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marko-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("note.md")
            try Fixtures.data(name).write(to: url)
            return url
        }

        private func save(_ document: NSDocument, to url: URL, _ operation: NSDocument.SaveOperationType) async -> Error? {
            await withCheckedContinuation { continuation in
                document.save(to: url, ofType: type, for: operation) { continuation.resume(returning: $0) }
            }
        }

        @Test func saveAutosaveSaveAsAndRevertGoThroughTheDocument() async throws {
            let url = try temporaryCopy(of: "crlf.md"), original = try Fixtures.data("crlf.md")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            #expect(MarkdownDocument.autosavesInPlace && MarkdownDocument.preservesVersions)
            let document = try MarkdownDocument(contentsOf: url, ofType: type)
            defer { document.close() }
            document.makeWindowControllers()
            let editor = try #require(document.editor), window = try #require(document.windowControllers.first?.window)
            let titlebar = editor.titlebar
            // The document hears of an edit when the undo group of the event closes, some run-loop turn later.
            func wait(for condition: () -> Bool) async throws {
                for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            }
            #expect(editor.documentURL == url, "relative paths start from the file")
            #expect(!document.isDocumentEdited && titlebar.title == "note.md")

            // An edit marks the document and the title; Save writes only the edit and clears both.
            editor.textView.insertText("Xé", replacementRange: NSRange(location: 0, length: 0))
            try await wait { document.isDocumentEdited && titlebar.title == "note.md — Edited" }
            #expect(document.isDocumentEdited)
            #expect(titlebar.title == "note.md — Edited")
            #expect(await save(document, to: url, .saveOperation) == nil)
            #expect(try Data(contentsOf: url) == Data("Xé".utf8) + original)
            #expect(!document.isDocumentEdited && titlebar.title == "note.md")
            document.undoManager?.undo()
            #expect(document.isDocumentEdited && titlebar.title == "note.md — Edited", "undoing past a save is an edit too")
            document.undoManager?.redo()

            // Autosave writes in place.
            editor.textView.insertText("Y", replacementRange: NSRange(location: 0, length: 0))
            try await wait { document.hasUnautosavedChanges }
            #expect(document.hasUnautosavedChanges)
            try await document.autosave(withImplicitCancellability: false)
            #expect(try Data(contentsOf: url) == Data("YXé".utf8) + original)
            #expect(!document.hasUnautosavedChanges)

            // Save As moves the document, and with it where relative paths start.
            let other = url.deletingLastPathComponent().appendingPathComponent("sub/other.md")
            #expect(await save(document, to: other, .saveAsOperation) == nil)
            #expect(document.fileURL == other && editor.documentURL == other)
            #expect(try Data(contentsOf: other) == Data("YXé".utf8) + original)
            try await wait { window.title.hasPrefix("other") && titlebar.title == window.title }
            #expect(window.title == document.displayName && window.title.hasPrefix("other") && titlebar.title == window.title)

            // Revert reads the file again and forgets the edit.
            editor.textView.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
            try await wait { document.isDocumentEdited }
            try document.revert(toContentsOf: other, ofType: type)
            #expect(editor.text == String(decoding: Data("YXé".utf8) + original, as: UTF8.self))
            #expect(!document.isDocumentEdited && titlebar.title == window.title)
            #expect(try document.data(ofType: type) == Data("YXé".utf8) + original)
        }

        @Test func anUntitledDocumentHasNoPlaceUntilItIsSaved() async throws {
            let url = try temporaryCopy(of: "lf.md")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let document = MarkdownDocument()
            defer { document.close() }
            document.makeWindowControllers()
            let editor = try #require(document.editor)
            #expect(editor.documentURL == nil && document.windowControllers.first?.window?.title == "Untitled")
            editor.textView.insertText("![x](pic.png)", replacementRange: NSRange(location: 0, length: 0))
            let saved = url.deletingLastPathComponent().appendingPathComponent("new.md")
            #expect(await save(document, to: saved, .saveAsOperation) == nil)
            #expect(editor.documentURL == saved)
            #expect(try Data(contentsOf: saved) == Data("![x](pic.png)".utf8))
        }

        /// A document made for a file that is not there yet writes it at the first change. The
        /// title never shows that change as unsaved: the mark would be there for one frame.
        @Test func theFirstChangeOfADocumentForANewFileIsWrittenWithoutTheEditedMarkShowing() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marko-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("new.md")
            let document = MarkdownDocument.untitled(savingTo: url)
            defer { document.close() }
            let editor = document.makeEditor()
            #expect(document.displayName == "new.md" && !editor.isEdited)
            func wait(for condition: () -> Bool) async throws {
                for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            }

            editor.textView.insertText("H", replacementRange: NSRange(location: 0, length: 0))
            document.updateChangeCount(.changeDone)
            #expect(!editor.isEdited, "the write that follows is this change")
            try await wait { document.fileURL != nil }
            #expect(try Data(contentsOf: url) == Data("H".utf8))
            #expect(!document.isDocumentEdited && !editor.isEdited && document.displayName == "new.md")

            // What is typed after that is a change like any other.
            editor.textView.insertText("e", replacementRange: NSRange(location: 1, length: 0))
            document.updateChangeCount(.changeDone)
            #expect(editor.isEdited)
        }

        // MARK: windows

        @Test func theWindowIsRestorableAndCanGoFullScreen() throws {
            let document = MarkdownDocument()
            defer { document.close() }
            document.makeWindowControllers()
            let controller = try #require(document.windowControllers.first), window = try #require(controller.window)
            #expect(window.isRestorable && window.restorationClass != nil)
            #expect((controller as? DocumentWindowController)?.frameName == "Document")
            #expect(window.styleMask.contains(.fullSizeContentView) && window.titlebarAppearsTransparent && window.titleVisibility == .hidden)
            // What the system needs to offer full screen: a resizable window that does not opt out,
            // and the menu item. What it looks like there is not tested here.
            #expect(window.styleMask.contains(.resizable) && window.collectionBehavior.isDisjoint(with: [.fullScreenNone, .fullScreenAuxiliary]))
            #expect(MainMenuProbe.viewItem("Enter Full Screen")?.action == #selector(NSWindow.toggleFullScreen(_:)))
            #expect(window.tabbingMode == .automatic)
        }

        @Test func twoDocumentsShareAWindowAsTabsUnderTheTitlebar() throws {
            let documents = [MarkdownDocument(), MarkdownDocument()]
            defer { documents.forEach { $0.close() } }
            var windows: [NSWindow] = []
            for document in documents {
                try document.read(from: Fixtures.data("lf.md"), ofType: type)
                document.makeWindowControllers()
                let window = try #require(document.windowControllers.first?.window)
                window.setFrame(NSRect(x: 140, y: 180, width: 700, height: 500), display: false)
                window.moveToBuiltInDisplay()
                windows.append(window)
            }
            windows[0].orderFrontRegardless()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            let editor = try #require(documents[0].editor)
            let titlebar = editor.titlebar
            let band = editor.view.safeAreaInsets.top
            #expect(band > 20 && titlebar.frame.height == band + Theme.standard.titlebarFadeHeight)

            windows[0].addTabbedWindow(windows[1], ordered: .above)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            #expect(windows[0].tabGroup?.windows.count == 2 && windows[0].tabGroup?.isTabBarVisible == true)
            windows[0].tabGroup?.selectedWindow = windows[0]
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            let tabbed = editor.view.safeAreaInsets.top
            #expect(tabbed > band, "the tab bar takes its room from the page, not from under it")
            #expect(titlebar.frame.height == tabbed + Theme.standard.titlebarFadeHeight, "and the titlebar band covers it")
            #expect(editor.textView.textLayoutManager != nil)
            #expect(try documents[0].data(ofType: type) == Fixtures.data("lf.md"))
        }

        @Test func theCaretIsRestoredWithTheDocument() throws {
            let data = try Fixtures.data("lf.md")
            func document(_ data: Data) throws -> MarkdownDocument {
                let document = MarkdownDocument()
                try document.read(from: data, ofType: type)
                document.makeWindowControllers()
                return document
            }
            let first = try document(data), second = try document(data), shorter = try document(data.prefix(10))
            defer { [first, second, shorter].forEach { $0.close() } }
            first.editor?.textView.setSelectedRange(NSRange(location: 12, length: 5))
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            first.encodeRestorableState(with: coder)
            for (restored, expected) in [(second, NSRange(location: 12, length: 5)), (shorter, NSRange(location: 10, length: 0))] {
                let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
                decoder.requiresSecureCoding = true
                restored.restoreState(with: decoder)
                #expect(restored.editor?.textView.selectedRange() == expected)
            }
        }

        // MARK: the View menu

        @Test func theViewMenuZoomsEveryEditorAndHidesTheWordCount() async throws {
            let app = AppDelegate()
            let document = MarkdownDocument()
            defer {
                Theme.zoom = 1
                Theme.showsWordCount = true
                document.close()
            }
            try document.read(from: Fixtures.data("lf.md"), ofType: type)
            document.makeWindowControllers()
            let editor = try #require(document.editor)
            func isEnabled(_ action: Selector) -> Bool { app.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
            #expect(!isEnabled(#selector(AppDelegate.resetZoom(_:))), "already at the actual size")

            app.increaseZoom(nil)
            #expect(Theme.zoom == 1.1 && editor.textView.font?.pointSize == 16 * 1.1)
            app.increaseZoom(nil)
            #expect(Theme.zoom == 1.25)
            for _ in 0..<10 { app.increaseZoom(nil) }
            #expect(Theme.zoom == 2 && !isEnabled(#selector(AppDelegate.increaseZoom(_:))))
            app.resetZoom(nil)
            #expect(Theme.zoom == 1 && editor.textView.font?.pointSize == 16)
            app.decreaseZoom(nil)
            app.decreaseZoom(nil)
            app.decreaseZoom(nil)
            #expect(Theme.zoom == 0.8 && !isEnabled(#selector(AppDelegate.decreaseZoom(_:))) && isEnabled(#selector(AppDelegate.resetZoom(_:))))
            app.resetZoom(nil)

            #expect(await wait { !editor.wordCount.stringValue.isEmpty })
            let item = NSMenuItem(title: "", action: #selector(AppDelegate.toggleWordCount(_:)), keyEquivalent: "")
            #expect(app.validateMenuItem(item) && item.title == "Hide Word Count")
            app.toggleWordCount(nil)
            #expect(editor.wordCount.isHidden)
            #expect(app.validateMenuItem(item) && item.title == "Show Word Count")
            app.toggleWordCount(nil)
            #expect(!editor.wordCount.isHidden)
            #expect(try document.data(ofType: type) == Fixtures.data("lf.md"), "the view settings never touch the text")
        }
    }
}
