import AppKit
import FixtureSupport
import MarkoCommand
import Testing
@testable import MarkoApp
@testable import MarkoEditor

/// An untitled document that records being asked whether it may close instead of putting up the
/// system's sheet, and answers when the test says so.
private final class AskingDocument: MarkdownDocument {
    private(set) var answer: ((Bool) -> Void)?

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard let object = delegate as? NSObject, let selector = shouldCloseSelector, let method = object.method(for: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        answer = { [unowned self] in unsafeBitCast(method, to: Callback.self)(object, selector, self, $0, contextInfo) }
    }
}

/// A document that counts how often it is closed.
private final class ClosingDocument: MarkdownDocument {
    private(set) var closed = 0

    override func close() {
        closed += 1
        super.close()
    }
}

/// A document that saves without ending the undo group being typed, as every document did before
/// that was found to lose text: what is typed on after a save is then no change the document hears of.
private final class CoalescingDocument: MarkdownDocument {
    override func data(ofType typeName: String) throws -> Data {
        let data = Data((editor?.text ?? "").utf8)
        // The document's record of what is written, which leaves an editor with that text alone.
        try read(from: data, ofType: typeName)
        return data
    }
}

/// What a document answers when it is asked whether it may close.
private final class CloseAnswer: NSObject {
    private(set) var answer: Bool?

    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        answer = shouldClose
    }
}

private final class WeakReference {
    weak var object: AnyObject?

    init(_ object: AnyObject?) { self.object = object }
}

/// A document that counts how often its windows are asked to come forward.
private final class ShownDocument: MarkdownDocument {
    private(set) var shown = 0

    override func showWindows() {
        shown += 1
    }
}

extension EditorTests {
    /// The window with its file tree: what choosing, renaming and deleting files does to the documents.
    @Suite struct WindowTests {
        private let theme = Theme.standard

        init() {
            NSApplication.shared.setActivationPolicy(.accessory)
            WebStub.install()
        }

        /// A window on a file, rooted at a folder or not, on screen without being activated.
        private func window(on url: URL, root: URL? = nil) throws -> DocumentWindowController {
            let controller = DocumentWindowController(rootURL: root)
            controller.show(try MarkdownDocument.document(at: url))
            controller.window?.orderFrontRegardless()
            return controller
        }

        private func closeAll() {
            DocumentWindowController.sidebarWidth = theme.sidebarWidth
            for document in NSDocumentController.shared.documents { document.close() }
            // The window of a folder without a file has no document that would close it.
            for controller in DocumentWindowController.all { controller.window?.close() }
        }

        /// The windows there are.
        private var controllers: [DocumentWindowController] {
            DocumentWindowController.all.filter { $0.window?.isVisible == true }
        }

        /// What is where the text is: an editor's view, or the page of a folder without a file.
        private func page(_ controller: DocumentWindowController) -> NSView? {
            (controller.window?.contentViewController as? NSSplitViewController)?.splitViewItems.last?.viewController.view.subviews.first
        }

        /// Whether anything in the window would take a menu command: nobody means its item is disabled.
        private func takes(_ action: Selector, in controller: DocumentWindowController) -> Bool {
            var responder = controller.window?.firstResponder
            while let next = responder {
                if next.responds(to: action) { return true }
                responder = next.nextResponder
            }
            return controller.responds(to: action) || controller.document?.responds(to: action) == true
        }

        private func document(_ controller: DocumentWindowController) -> MarkdownDocument? {
            controller.document as? MarkdownDocument
        }

        private var openFiles: [String] {
            NSDocumentController.shared.documents.map { $0.fileURL?.lastPathComponent ?? "untitled" }.sorted()
        }

        private func rows(_ controller: DocumentWindowController) -> [String] {
            let outline = controller.sidebar.outlineView
            return (0..<outline.numberOfRows).map {
                String(repeating: "  ", count: outline.level(forRow: $0)) + (outline.item(atRow: $0) as! SidebarController.Node).entry.name
            }
        }

        /// How much of the window the tree takes from the page.
        private func treeWidth(_ controller: DocumentWindowController) -> CGFloat {
            (controller.window?.contentLayoutRect.width ?? 0) - (document(controller)?.editor?.view.frame.width ?? 0)
        }

        private func selected(_ controller: DocumentWindowController) -> String? {
            let outline = controller.sidebar.outlineView
            return (outline.item(atRow: outline.selectedRow) as? SidebarController.Node)?.entry.name
        }

        // MARK: choosing a file

        @Test func choosingAFileShowsItInTheSameWindowAndSavesTheEditsOfTheOneBefore() async throws {
            let crlf = try Fixtures.data("crlf.md"), bom = try Fixtures.data("bom.md"), sink = try Fixtures.data("kitchen-sink.md")
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let a = try folder.add("a.md", crlf), b = try folder.add("sub/b.markdown", bom), c = try folder.add("c.md", sink)
            let controller = try window(on: a, root: folder.url)
            defer { closeAll() }
            let window = try #require(controller.window), first = try #require(document(controller))
            #expect(await wait { selected(controller) == "a.md" })
            let windows = NSApp.windows.count

            // An edit and, in the same turn of the run loop, a click on another file: the change
            // count has not heard of the edit yet.
            first.editor?.textView.insertText("Xé", replacementRange: NSRange(location: 0, length: 0))
            #expect(!first.hasUnautosavedChanges && first.hasUnwrittenText)
            controller.sidebar.opener(b, true)
            #expect(await wait { document(controller)?.fileURL == b })
            #expect(try Data(contentsOf: a) == Data("Xé".utf8) + crlf, "the edit was written, and nothing else changed")
            let second = try #require(document(controller))
            #expect(second !== first && openFiles == ["b.markdown"], "the document that left the window is closed")
            #expect(controller.window === window && NSApp.windows.count == windows && second.editor?.textView.window === window)
            #expect(second.editor?.view.superview != nil && first.editor?.view.superview == nil)
            #expect(window.title == "b.markdown" && second.editor?.titlebar.title == "b.markdown")
            #expect(window.firstResponder === second.editor?.textView, "the keyboard is in the text")
            #expect(second.editor?.text.unicodeScalars.first != "\u{FEFF}" && second.editor?.documentURL == b)
            #expect(try second.data(ofType: MarkdownDocument.typeName) == bom)
            #expect(await wait { selected(controller) == "b.markdown" } && rows(controller) == ["sub", "  b.markdown", "a.md", "c.md"])

            // Nothing to save: a file is left as it is, byte for byte, and comes back as it was written.
            controller.open(c)
            #expect(document(controller)?.fileURL == c, "without edits the change is immediate")
            #expect(try Data(contentsOf: b) == bom)
            controller.open(a)
            #expect(document(controller)?.editor?.text == String(decoding: Data("Xé".utf8) + crlf, as: UTF8.self))
            #expect(try Data(contentsOf: c) == sink && openFiles == ["a.md"])
            #expect(document(controller)?.editor?.textView.textLayoutManager != nil)

            // Undo belongs to the document on screen.
            let third = try #require(document(controller))
            third.editor?.textView.insertText("Q", replacementRange: NSRange(location: 0, length: 0))
            #expect(await wait { third.isDocumentEdited })
            #expect(window.undoManager === third.undoManager && third.undoManager?.canUndo == true)

            // Choosing the file that is open changes nothing.
            controller.open(a)
            #expect(document(controller) === third && third.editor?.text.hasPrefix("QXé") == true)
        }

        @Test func aFileComesBackToThePlaceItWasLeftAt() async throws {
            let long = String(repeating: "A paragraph of some words that fills a line or two of the page.\n\n", count: 200)
            let folder = try TemporaryFolder(["b.md"])
            defer { folder.remove() }
            let a = try folder.add("a.md", Data(long.utf8))
            let controller = try window(on: a, root: folder.url)
            defer { closeAll() }
            controller.window?.displayIfNeeded()
            let first = try #require(document(controller)?.editor)
            // The caret far down, and the view scrolled away from it to somewhere in the middle.
            first.textView.setSelectedRange(NSRange(location: 9000, length: 4))
            first.scrollToSelection()
            first.textView.scroll(NSPoint(x: 0, y: 2500))
            await pause(0.1)
            let place = first.place, top = first.scrollView.contentView.bounds.minY
            #expect(place.top != nil && place.top?.offset != 0 && top > 2000)

            controller.open(folder["b.md"])
            #expect(document(controller)?.fileURL == folder["b.md"])
            document(controller)?.editor?.textView.insertText("B ", replacementRange: NSRange(location: 0, length: 0))
            controller.open(a)
            #expect(await wait { document(controller)?.fileURL == a })
            let second = try #require(document(controller)?.editor)
            #expect(second !== first, "the document was closed and is read again")
            #expect(second.textView.selectedRange() == NSRange(location: 9000, length: 4), "typing goes on where it stopped")
            #expect(second.place.top?.offset == place.top?.offset, "the same paragraph is at the top of the view")
            #expect(abs((second.place.top?.past ?? 0) - (place.top?.past ?? 99)) < 1)
            await pause(0.1)
            #expect(second.place.top?.offset == place.top?.offset, "and stays there once the page has settled")

            // A file that has become shorter meanwhile is shown at its end.
            controller.open(folder["b.md"])
            #expect(await wait { document(controller)?.fileURL == folder["b.md"] })
            try Data("short\n".utf8).write(to: a)
            controller.open(a)
            #expect(await wait { document(controller)?.fileURL == a })
            #expect(document(controller)?.editor?.textView.selectedRange() == NSRange(location: 6, length: 0))
        }

        // MARK: saving

        @Test func textTypedOnAfterASaveIsAChangeOfItsOwn() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["a.md"]), shown = try #require(document(controller)), window = try #require(controller.window)
            defer { closeAll() }
            // Typed with key events, as the keyboard does: NSTextView makes one undo group of it,
            // and the document hears of a group, not of a key.
            SidebarWindow.type("one", in: window)
            #expect(await wait { shown.hasUnautosavedChanges })
            try await shown.autosave(withImplicitCancellability: false)
            #expect(try !shown.hasUnautosavedChanges && String(contentsOf: folder["a.md"], encoding: .utf8) == "onea.md")
            // On without moving the caret: before, this was more of the same group and no change.
            SidebarWindow.type(" two", in: window)
            #expect(await wait { shown.hasUnautosavedChanges }, "the document knows of the text typed after the save")
            try await shown.autosave(withImplicitCancellability: false)
            #expect(try String(contentsOf: folder["a.md"], encoding: .utf8) == "one twoa.md")
            // Undo takes back what was typed since the save, not all of it.
            shown.undoManager?.undo()
            #expect(shown.editor?.text == "onea.md")
        }

        @Test func aWindowIsNotClosedOverTextTheDocumentHasNotHeardOf() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["a.md"]), shown = try #require(document(controller))
            defer { closeAll() }
            // An edit and, in the same turn of the run loop, the question a closing window asks.
            shown.editor?.textView.insertText("kept ", replacementRange: NSRange(location: 0, length: 0))
            #expect(!shown.hasUnautosavedChanges && shown.hasUnwrittenText)
            let asked = CloseAnswer()
            shown.canClose(withDelegate: asked, shouldClose: #selector(CloseAnswer.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            #expect(await wait { asked.answer != nil })
            #expect(try asked.answer == true && String(contentsOf: folder["a.md"], encoding: .utf8) == "kept a.md", "it was saved before it may close")
        }

        @Test func aFileThatCannotBeReadLeavesTheWindowOnItsDocument() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let latin = try folder.add("latin.md", Data([0x63, 0x61, 0x66, 0xE9]))
            let controller = try window(on: folder["a.md"], root: folder.url)
            defer { closeAll() }
            let first = document(controller)
            first?.editor?.textView.insertText("kept ", replacementRange: NSRange(location: 0, length: 0))
            controller.open(latin)
            #expect(await wait { controller.window?.attachedSheet != nil }, "the reason is shown")
            var reason = ""
            do { _ = try MarkdownDocument.document(at: latin) } catch {
                reason = error.localizedDescription + " " + ((error as NSError).localizedRecoverySuggestion ?? "")
            }
            #expect(reason.contains("“latin.md” is not UTF-8 text") && reason.contains("UTF-8 files only"), "it names the file and what is wanted")
            controller.window?.attachedSheet.map { controller.window?.endSheet($0) }
            #expect(document(controller) === first && first?.editor?.text == "kept a.md" && openFiles == ["a.md"])
            #expect(try Data(contentsOf: latin) == Data([0x63, 0x61, 0x66, 0xE9]))
        }

        @Test func aFileAnotherWindowShowsComesForwardThere() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md"])
            defer { folder.remove() }
            let elsewhere = try ShownDocument(contentsOf: folder["b.md"], ofType: MarkdownDocument.typeName)
            NSDocumentController.shared.addDocument(elsewhere)
            let controller = try window(on: folder["a.md"], root: folder.url), other = try window(on: folder["b.md"])
            defer { closeAll() }
            #expect(document(other) === elsewhere && elsewhere.shown == 0)
            controller.open(folder["b.md"])
            await pause(0.1)
            #expect(elsewhere.shown == 1, "its window is brought forward")
            #expect(document(controller)?.fileURL == folder["a.md"] && document(other) === elsewhere)
            #expect(openFiles == ["a.md", "b.md"] && NSDocumentController.shared.documents.allSatisfy { $0.windowControllers.count == 1 })
        }

        /// In full screen the titlebar, which is empty but as high as a toolbar, comes and goes
        /// with the menu bar: the page and the tree start at the screen's top.
        @Test func inFullScreenTheTitlebarHidesWithTheMenuBar() throws {
            let controller = DocumentWindowController()
            defer { closeAll() }
            let window = try #require(controller.window)
            #expect(window.delegate === controller)
            let options = controller.window(window, willUseFullScreenPresentationOptions: [.fullScreen, .autoHideMenuBar])
            #expect(options == [.fullScreen, .autoHideMenuBar, .autoHideToolbar])
            #expect(window.collectionBehavior.contains(.fullScreenPrimary) || window.styleMask.contains(.resizable), "the window can enter full screen")
        }

        @Test func anUntitledDocumentWithTextAsksBeforeItIsLeft() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let untitled = AskingDocument()
            NSDocumentController.shared.addDocument(untitled)
            let controller = DocumentWindowController(rootURL: folder.url)
            controller.show(untitled)
            controller.window?.orderFrontRegardless()
            defer { closeAll() }

            untitled.editor?.textView.insertText("a draft", replacementRange: NSRange(location: 0, length: 0))
            controller.open(folder["a.md"])
            let answer = try #require(untitled.answer, "the document was asked")
            #expect(document(controller) === untitled && untitled.editor?.text == "a draft")
            controller.open(folder["a.md"])
            #expect(document(controller) === untitled, "a second choice waits for the answer to the first")
            answer(false)
            #expect(document(controller) === untitled && untitled.editor?.text == "a draft" && openFiles == ["untitled"])

            controller.open(folder["a.md"])
            let again = try #require(untitled.answer)
            again(true)
            #expect(document(controller)?.fileURL == folder["a.md"] && openFiles == ["a.md"])
        }

        @Test func anEmptyUntitledDocumentIsLeftWithoutAQuestion() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let untitled = AskingDocument()
            NSDocumentController.shared.addDocument(untitled)
            let controller = DocumentWindowController(rootURL: folder.url)
            controller.show(untitled)
            defer { closeAll() }
            controller.open(folder["a.md"])
            #expect(untitled.answer == nil && document(controller)?.fileURL == folder["a.md"] && openFiles == ["a.md"])
        }

        @Test func aLinkToAFileIsTheFileItLeadsTo() async throws {
            let folder = try TemporaryFolder(["docs/real.md", "other.md"])
            defer { folder.remove() }
            let real = folder["docs/real.md"], other = folder["other.md"], link = folder["link.md"]
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "docs/real.md")
            let controller = try window(on: other, root: folder.url), outline = controller.sidebar.outlineView
            defer { closeAll() }
            #expect(await wait { rows(controller) == ["docs", "link.md", "other.md"] })
            func isMarked(_ row: Int) -> Bool {
                (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.font == theme.sidebarCurrentFont
            }

            // Chosen in the tree, as a click does it: the row is selected and then opened.
            outline.selectRowIndexes([1], byExtendingSelection: false)
            controller.sidebar.openSelection()
            let shown = try #require(document(controller))
            #expect(shown.fileURL == real && openFiles == ["real.md"])
            #expect(selected(controller) == "link.md" && isMarked(1) && !isMarked(2), "the link stays selected and is marked as the window's file")
            shown.editor?.textView.insertText("EDIT ", replacementRange: NSRange(location: 0, length: 0))
            controller.open(other)
            #expect(await wait { document(controller)?.fileURL == other })
            #expect(controller.window?.attachedSheet == nil)
            #expect((try? String(contentsOf: real, encoding: .utf8)) == "EDIT docs/real.md", "the edit is in the file the link leads to")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "docs/real.md", "and the link is still a link")
            #expect(!isMarked(1) && isMarked(2))

            // The file and the link are one document: shown in one window, the other brings it forward.
            let second = try window(on: real)
            #expect(try MarkdownDocument.document(at: link) === document(second))
            controller.open(link)
            await pause(0.1)
            #expect(document(controller)?.fileURL == other && openFiles == ["other.md", "real.md"])
            second.open(link)
            #expect(document(second)?.fileURL == real && openFiles == ["other.md", "real.md"], "choosing the link to the file that is shown changes nothing")
        }

        // MARK: file commands

        @Test func anOpenDocumentFollowsARename() async throws {
            let lf = try Fixtures.data("lf.md")
            let folder = try TemporaryFolder(["b.md"])
            defer { folder.remove() }
            let a = try folder.add("docs/a.md", lf)
            let controller = try window(on: a, root: folder.url)
            defer { closeAll() }
            let shown = try #require(document(controller)), sidebar = controller.sidebar
            #expect(await wait { selected(controller) == "a.md" })
            shown.editor?.textView.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))

            sidebar.rename(try #require(sidebar.node(at: a)), to: "renamed.md")
            let renamed = folder["docs/renamed.md"]
            #expect(shown.fileURL == renamed && shown.editor?.documentURL == renamed && document(controller) === shown)
            #expect(shown.editor?.text.hasPrefix("edit ") == true, "the edit is still in the editor")
            #expect(await wait { controller.window?.title == "renamed.md" && selected(controller) == "renamed.md" })
            #expect(sidebar.currentURL == renamed)
            #expect(await wait { shown.hasUnautosavedChanges })
            try await shown.autosave(withImplicitCancellability: false)
            #expect(try Data(contentsOf: renamed) == Data("edit ".utf8) + lf && !FileManager.default.fileExists(atPath: a.path))

            // The folder above it: the document goes along.
            #expect(rows(controller) == ["docs", "  renamed.md", "b.md"])
            sidebar.rename(try #require(sidebar.node(at: folder["docs/"])), to: "texts")
            #expect(shown.fileURL?.path == folder["texts/renamed.md"].path)
            #expect(await wait { rows(controller) == ["texts", "  renamed.md", "b.md"] && selected(controller) == "renamed.md" })
            shown.editor?.textView.insertText("more ", replacementRange: NSRange(location: 0, length: 0))
            controller.open(folder["b.md"])
            #expect(await wait { document(controller)?.fileURL == folder["b.md"] })
            #expect(try Data(contentsOf: folder["texts/renamed.md"]) == Data("more edit ".utf8) + lf)
        }

        @Test func movingAnOpenFileToTheTrashWritesItFirstAndLeavesTheFolderWithoutAFile() async throws {
            let lf = try Fixtures.data("lf.md")
            let folder = try TemporaryFolder(["b.md", "docs/c.md"]), trash = try TemporaryFolder()
            defer { [folder, trash].forEach { $0.remove() } }
            let a = try folder.add("a.md", lf)
            let controller = try window(on: a, root: folder.url), other = try window(on: folder["docs/c.md"])
            defer { closeAll() }
            controller.sidebar.trasher = { try FileManager.default.moveItem(at: $0, to: trash[$0.lastPathComponent]) }
            let window = controller.window
            #expect(await wait { rows(controller) == ["docs", "a.md", "b.md"] })

            document(controller)?.editor?.textView.insertText("last words ", replacementRange: NSRange(location: 0, length: 0))
            controller.sidebar.trashHandler(a)
            #expect(await wait { rows(controller) == ["docs", "b.md"] })
            #expect(try Data(contentsOf: trash["a.md"]) == Data("last words ".utf8) + lf, "what the editor showed is what is in the Trash")
            #expect(controller.window === window && window?.isVisible == true && controller.document == nil)
            #expect(page(controller) is EmptyPage && openFiles == ["c.md"], "no other file is chosen in its place")
            // The keyboard was in the text that went, and is in the tree.
            #expect(window?.firstResponder === controller.sidebar.outlineView && window?.title == folder.url.lastPathComponent)
            #expect(window?.representedURL?.path == folder.url.path, "the window stands for the folder, not for the file that went")

            // A folder takes the documents of its files with it, also one in another window.
            document(other)?.editor?.textView.insertText("too ", replacementRange: NSRange(location: 0, length: 0))
            controller.sidebar.trashHandler(folder["docs/"])
            #expect(await wait { rows(controller) == ["b.md"] })
            #expect((try? String(contentsOf: trash["docs/c.md"], encoding: .utf8)) == "too docs/c.md")
            #expect(openFiles.isEmpty && other.window?.isVisible != true, "a window without a folder closes with its file")

            // A file no document shows just goes.
            controller.sidebar.trashHandler(folder["b.md"])
            #expect(rows(controller).isEmpty && FileManager.default.fileExists(atPath: trash["b.md"].path))

            // A window opened for a file, with the tree beside it: the tree's folder is what stays.
            let single = try self.window(on: try folder.add("d.md"))
            single.sidebar.trasher = controller.sidebar.trasher
            single.toggleFiles(nil)
            #expect(await wait { rows(single) == ["d.md"] })
            single.sidebar.trashHandler(folder["d.md"])
            #expect(single.document == nil && single.rootURL == folder.url && page(single) is EmptyPage && single.window?.isVisible == true)

            // With the tree hidden again it is a file's window, and closes with the file.
            let hidden = try self.window(on: try folder.add("e.md"))
            hidden.toggleFiles(nil)
            hidden.toggleFiles(nil)
            document(hidden)?.dropFromWindow()
            #expect(hidden.window?.isVisible != true && hidden.rootURL == nil && openFiles.isEmpty)
        }

        @Test func theWindowsOwnDocumentIsClosedOnceWhenItsFileGoesToTheTrash() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md"]), trash = try TemporaryFolder()
            defer { [folder, trash].forEach { $0.remove() } }
            let shown = try ClosingDocument(contentsOf: folder["a.md"], ofType: MarkdownDocument.typeName)
            NSDocumentController.shared.addDocument(shown)
            let controller = DocumentWindowController(rootURL: folder.url)
            controller.show(shown)
            defer { closeAll() }
            controller.sidebar.trasher = { try FileManager.default.moveItem(at: $0, to: trash[$0.lastPathComponent]) }
            #expect(await wait { rows(controller) == ["a.md", "b.md"] })
            controller.sidebar.trashHandler(folder["a.md"])
            #expect(await wait { rows(controller) == ["b.md"] })
            #expect(shown.closed == 1 && openFiles.isEmpty)
        }

        @Test func aDocumentThatLeavesTheWindowLeavesNothingOfItsTextBehind() async throws {
            let folder = try TemporaryFolder(["b.md"])
            defer { folder.remove() }
            let a = try folder.add("a.md", try Fixtures.data("kitchen-sink.md"))
            let controller = try window(on: a, root: folder.url)
            defer { closeAll() }
            controller.window?.displayIfNeeded()
            // What the editor's text view is made of; the views of its paragraphs are the last.
            let left = autoreleasepool { () -> [WeakReference] in
                guard let textView = document(controller)?.editor?.textView else { return [] }
                return ([textView, textView.textStorage, textView.textLayoutManager, textView.textContentStorage]
                    + textView.subviews.flatMap(\.subviews)).map(WeakReference.init)
            }
            #expect(left.count > 8 && left.allSatisfy { $0.object != nil }, "the paragraphs on screen have views")
            controller.open(folder["b.md"])
            #expect(await wait { left.allSatisfy { $0.object == nil } },
                    "\(left.compactMap { $0.object.map { "\(type(of: $0))" } }) outlive the document")
        }

        @Test func savingNeverPutsABackupBesideTheFile() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["a.md"]), shown = try #require(document(controller))
            defer { closeAll() }
            // Looked for the whole time, from another thread: it would be there for a second after the first save.
            let path = folder.url.path
            let watching = Task.detached {
                var seen: Set<String> = []
                while !Task.isCancelled { seen.formUnion((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []) }
                return seen
            }
            shown.editor?.textView.insertText("more ", replacementRange: NSRange(location: 0, length: 0))
            #expect(await wait { shown.hasUnautosavedChanges })
            try await shown.autosave(withImplicitCancellability: false)
            #expect(try FileManager.default.contentsOfDirectory(atPath: path) == ["a.md"])
            await pause(1.2)
            watching.cancel()
            #expect(await watching.value == ["a.md"])
            #expect(try String(contentsOf: folder["a.md"], encoding: .utf8) == "more a.md")
            #expect(NSFileVersion.otherVersionsOfItem(at: folder["a.md"])?.count == 1, "the text before the save is still kept as a version")
        }

        @Test func aNewWindowNeverOpensExactlyOverAnother() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md", "c.md"])
            defer { folder.remove() }
            defer { closeAll() }
            // As high as the default window on the built-in display: there is no room to step down.
            let frames = try ["a.md", "b.md", "c.md"].map { name -> NSRect in
                let document = try MarkdownDocument.document(at: folder[name])
                document.makeWindowControllers()
                document.showWindows()
                return try #require(document.windowControllers.first?.window).frame
            }
            let step = theme.windowCascadeStep
            #expect(frames.map(\.minX) == [frames[0].minX, frames[0].minX + step, frames[0].minX + 2 * step], "each a step to the right: \(frames)")
            #expect(Set(frames.map(\.minY)).count == 1 && Set(frames.map(\.size.width)).count == 1)
            // Shown again, a window stays where it is.
            NSDocumentController.shared.documents.forEach { $0.showWindows() }
            #expect(controllers.compactMap { $0.window?.frame.minX }.sorted() == frames.map(\.minX))
        }

        @Test func twoWindowsMergeIntoTabs() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md"])
            defer { folder.remove() }
            let a = try window(on: folder["a.md"]), b = try window(on: folder["b.md"], root: folder.url)
            defer { closeAll() }
            let first = try #require(a.window), second = try #require(b.window)
            await pause(0.2)
            func isEnabled(_ action: Selector) -> Bool { first.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
            #expect(isEnabled(#selector(NSWindow.toggleTabBar(_:))) && isEnabled(#selector(NSWindow.mergeAllWindows(_:))), "the View and Window menus' items")
            first.mergeAllWindows(nil)
            await pause(0.3)
            #expect(first.tabbedWindows?.count == 2 && first.tabGroup === second.tabGroup && first.tabGroup?.isTabBarVisible == true)
            #expect([first, second].allSatisfy { $0.screen == nil || $0.screen === NSScreen.builtIn })
            first.moveTabToNewWindow(nil)
            await pause(0.3)
            #expect(first.tabbedWindows == nil && second.tabbedWindows == nil)
        }

        @Test func theInstallScriptsPathsAreShortenedOnlyWhereTheyStartWithTheHomeFolder() throws {
            // A home that is reached through a link, as /tmp is: "/private~/.local/bin/marko" was shown.
            let folder = try TemporaryFolder([])
            defer { folder.remove() }
            let real = folder.url.resolvingSymlinksInPath().appendingPathComponent("real").path, home = folder.url.path + "/home"
            try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: home, withDestinationPath: real)
            func short(_ said: String) -> String { CommandLineTool.abbreviated(said, home: home) }
            #expect(short("\(home)/.local/bin/marko now points to \(real)/Marko.app/Contents/Helpers/marko.")
                == "~/.local/bin/marko now points to ~/Marko.app/Contents/Helpers/marko.")
            #expect(short("/private\(home)/bin is not on your PATH") == "/private\(home)/bin is not on your PATH", "not inside another path")
            #expect(short("\(home)2/bin and \(home)") == "\(home)2/bin and ~", "a whole folder name")
        }

        @Test func theFoldersNameIsBesideTheWindowButtons() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["a.md"], root: folder.url), sidebar = controller.sidebar
            defer { closeAll() }
            let window = try #require(controller.window), zoom = try #require(window.standardWindowButton(.zoomButton))
            window.layoutIfNeeded()
            let header = sidebar.header, buttons = sidebar.view.convert(zoom.bounds, from: zoom)
            #expect(header.stringValue == folder.url.lastPathComponent && header.textColor == theme.sidebarHeaderText)
            #expect(header.frame.minX == buttons.maxX + theme.sidebarHeaderGap && abs(header.frame.midY - buttons.midY) <= 0.5)
            #expect(header.frame.maxX == sidebar.view.bounds.maxX - theme.sidebarHeaderGap && sidebar.view.bounds.contains(header.frame))
        }

        @Test func aNewFileOpensInTheWindowAndFollowsTheNameItIsGiven() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["a.md"], root: folder.url), sidebar = controller.sidebar
            defer { closeAll() }
            let window = try #require(controller.window)
            #expect(await wait { rows(controller) == ["a.md"] })
            document(controller)?.editor?.textView.insertText("kept ", replacementRange: NSRange(location: 0, length: 0))

            let root = try #require(sidebar.node(at: folder.url))
            let made = try #require(sidebar.create(in: root, isDirectory: false))
            #expect(await wait { document(controller)?.fileURL == made })
            #expect((try? String(contentsOf: folder["a.md"], encoding: .utf8)) == "kept a.md")
            #expect(rows(controller) == ["a.md", "Untitled.md"] && selected(controller) == "Untitled.md")
            let name = try #require(window.firstResponder as? NSTextView)
            #expect(name !== document(controller)?.editor?.textView && name.string == "Untitled.md", "the keyboard is in the name, not in the text")
            SidebarWindow.type("ideas\r", in: window)
            #expect(await wait { document(controller)?.fileURL?.path == folder["ideas.md"].path })
            #expect(rows(controller) == ["a.md", "ideas.md"] && selected(controller) == "ideas.md" && window.title == "ideas.md")
            #expect(FileManager.default.fileExists(atPath: folder["ideas.md"].path) && !FileManager.default.fileExists(atPath: made.path))
            #expect(openFiles == ["ideas.md"])
        }

        // MARK: the sidebar in the window

        @Test func aFileAloneOpensWithoutTheSidebarAndCommandBShowsItsFolder() async throws {
            let folder = try TemporaryFolder(["notes/a.md", "notes/b.md", "notes/sub/c.md", "outside.md"])
            defer { folder.remove() }
            let shown = try MarkdownDocument.document(at: folder["notes/a.md"])
            shown.makeWindowControllers()
            defer { closeAll() }
            let controller = try #require(shown.windowControllers.first as? DocumentWindowController), window = try #require(controller.window)
            window.orderFrontRegardless()
            let textView = try #require(shown.editor?.textView)
            #expect(!controller.isSidebarVisible && controller.rootURL == nil)
            let split = try #require(window.contentViewController as? NSSplitViewController)
            #expect(split.splitViewItems.count == 1, "the tree's views are not even made")
            #expect(controller.sidebar.rootURL == nil, "nothing is read or watched for a tree nobody sees")
            #expect(window.firstResponder === textView)
            let pane = try #require(shown.editor?.view.frame.width)
            #expect(pane == window.contentLayoutRect.width)

            let item = NSMenuItem(title: "", action: #selector(DocumentWindowController.toggleFiles(_:)), keyEquivalent: "")
            #expect(controller.validateMenuItem(item) && item.title == "Show Sidebar")
            let menuItem = try #require(MainMenuProbe.viewItem("Show Sidebar"))
            #expect(menuItem.keyEquivalent == "b" && menuItem.keyEquivalentModifierMask == .command)
            #expect(EditorTextView.formatMenu().items.allSatisfy { !($0.keyEquivalent == "b" && $0.keyEquivalentModifierMask == .command) })

            controller.toggleFiles(nil)
            #expect(controller.isSidebarVisible && controller.sidebar.rootURL?.path == folder["notes/"].path)
            #expect(window.firstResponder === controller.sidebar.outlineView, "the keyboard goes to the tree that appeared")
            #expect(await wait { rows(controller) == ["sub", "a.md", "b.md"] && selected(controller) == "a.md" })
            #expect(controller.validateMenuItem(item) && item.title == "Hide Sidebar")
            // The animation ends with the tree at its width and the page beside it.
            #expect(await wait { treeWidth(controller) == theme.sidebarWidth })
            #expect(shown.editor?.view.frame.width == pane - theme.sidebarWidth)
            // The tree's panel runs the whole height of the window and holds the window buttons.
            #expect(window.toolbar?.items.isEmpty == true && window.toolbarStyle == .unified)
            let panel = controller.sidebar.view, close = try #require(window.standardWindowButton(.closeButton))
            #expect(panel.convert(panel.bounds, to: nil).contains(close.convert(close.bounds, to: nil)))
            #expect(panel.safeAreaInsets.top >= close.convert(close.bounds, to: nil).height, "and the rows start below them")

            // Down and Return: the file below opens and the keyboard is in its text.
            SidebarWindow.type(SidebarWindow.down + "\r", in: window)
            #expect(await wait { document(controller)?.fileURL == folder["notes/b.md"] })
            #expect(window.firstResponder === document(controller)?.editor?.textView)
            #expect(controller.sidebar.rootURL?.path == folder["notes/"].path, "the tree stays on the folder it showed first")

            // Escape in the tree gives the keyboard back to the text.
            window.makeFirstResponder(controller.sidebar.outlineView)
            SidebarWindow.type("\u{1B}", in: window)
            #expect(window.firstResponder === document(controller)?.editor?.textView)

            window.makeFirstResponder(controller.sidebar.outlineView)
            controller.toggleFiles(nil)
            #expect(!controller.isSidebarVisible && window.firstResponder === document(controller)?.editor?.textView, "closing it returns the keyboard")
            #expect(await wait { document(controller)?.editor?.view.frame.width == pane })
        }

        @Test func theSidebarsStateIsKeptWithTheWindowAndRestored() async throws {
            let folder = try TemporaryFolder(["a.md", "docs/b.md", "c.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["docs/b.md"], root: folder.url)
            defer { closeAll() }
            #expect(controller.isSidebarVisible && controller.frameName == "Folder")
            #expect(controller.windowFrameAutosaveName.isEmpty, "only the app keeps window frames in the user's defaults, not a test")
            #expect(await wait { treeWidth(controller) == theme.sidebarWidth })
            // The divider dragged to 300.
            let split = try #require(controller.window?.contentViewController as? NSSplitViewController)
            split.splitView.setPosition(300, ofDividerAt: 0)
            #expect(await wait { treeWidth(controller) == 300 })

            func restored(from source: DocumentWindowController, on url: URL) throws -> DocumentWindowController {
                let coder = NSKeyedArchiver(requiringSecureCoding: true)
                source.encodeRestorableState(with: coder)
                let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
                decoder.requiresSecureCoding = true
                // AppKit reopens the document, which makes a plain window, and then restores into it.
                let document = try MarkdownDocument.document(at: url)
                document.makeWindowControllers()
                let controller = try #require(document.windowControllers.first as? DocumentWindowController)
                #expect(!controller.isSidebarVisible)
                controller.restoreState(with: decoder)
                controller.window?.orderFrontRegardless()
                return controller
            }
            let second = try restored(from: controller, on: folder["a.md"])
            #expect(second.isSidebarVisible && second.rootURL?.path == folder.url.path)
            #expect(await wait { treeWidth(second) == 300 && rows(second) == ["docs", "a.md", "c.md"] })
            #expect(DocumentWindowController.sidebarWidth == 300, "the next new window starts with the width the user chose")

            // A hidden sidebar stays hidden, and remembers its width for when it is shown.
            second.toggleFiles(nil)
            let third = try restored(from: second, on: folder["c.md"])
            #expect(!third.isSidebarVisible && third.rootURL?.path == folder.url.path && third.sidebar.rootURL == nil)
            third.toggleFiles(nil)
            #expect(await wait { treeWidth(third) == 300 && rows(third) == ["docs", "a.md", "c.md"] })
        }

        @Test func theWidthTheUserGaveTheSidebarSurvivesQuickTogglingAndANarrowWindow() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["a.md"])
            defer { closeAll() }
            let window = try #require(controller.window), split = try #require(window.contentViewController as? NSSplitViewController)
            func tree() -> CGFloat { split.splitView.arrangedSubviews[0].frame.width }
            controller.toggleFiles(nil)
            #expect(await wait { tree() == theme.sidebarWidth })
            // The animation ends a moment after the tree has its width.
            await pause(0.3)
            split.splitView.setPosition(320, ofDividerAt: 0)
            controller.toggleFiles(nil)
            await pause(0.6)
            #expect(controller.sidebarWidth == 320 && DocumentWindowController.sidebarWidth == 320)

            // Shown and hidden again before it has slid in: the width in between is nobody's choice.
            controller.toggleFiles(nil)
            await pause(0.05)
            #expect(tree() < 320, "the tree is still sliding in")
            controller.toggleFiles(nil)
            await pause(0.6)
            #expect(controller.sidebarWidth == 320 && DocumentWindowController.sidebarWidth == 320)
            controller.toggleFiles(nil)
            controller.toggleFiles(nil)
            await pause(0.6)
            #expect(controller.sidebarWidth == 320 && DocumentWindowController.sidebarWidth == 320)

            // The window's state is saved while the tree slides in.
            controller.toggleFiles(nil)
            await pause(0.05)
            controller.encodeRestorableState(with: NSKeyedArchiver(requiringSecureCoding: true))
            #expect(controller.sidebarWidth == 320 && DocumentWindowController.sidebarWidth == 320)
            #expect(await wait { tree() == 320 })
            await pause(0.3)
            // Once it is there, a drag of the divider is taken.
            split.splitView.setPosition(280, ofDividerAt: 0)
            controller.encodeRestorableState(with: NSKeyedArchiver(requiringSecureCoding: true))
            #expect(controller.sidebarWidth == 280 && DocumentWindowController.sidebarWidth == 280)
            controller.toggleFiles(nil)
            await pause(0.6)

            // A window too narrow for the page beside the tree grows for the tree's width, not for its smallest.
            window.setContentSize(NSSize(width: 500, height: 400))
            await pause(0.1)
            controller.toggleFiles(nil)
            #expect(await wait { tree() == 280 })
            #expect(window.contentLayoutRect.width == 280 + theme.minimumWindowSize.width)
            controller.toggleFiles(nil)
            await pause(0.6)
            #expect(controller.sidebarWidth == 280 && DocumentWindowController.sidebarWidth == 280)
        }

        @Test func theTextColumnStaysCentredInThePageBesideTheSidebar() async throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let file = try folder.add("a.md", Fixtures.data("kitchen-sink.md"))
            let controller = try window(on: file, root: folder.url)
            defer { closeAll() }
            let window = try #require(controller.window), editor = try #require(document(controller)?.editor)
            let textView = editor.textView, sidebar = theme.sidebarWidth

            window.setContentSize(NSSize(width: 1400, height: 700))
            #expect(await wait { treeWidth(controller) == sidebar && editor.view.frame.width == 1400 - sidebar })
            let pane = editor.view.frame.width
            #expect(editor.view.convert(editor.view.bounds, to: nil).minX == sidebar, "the page starts where the tree ends")
            #expect(textView.frame.width == pane && textView.columnWidth == theme.maximumTextWidth)
            #expect(textView.columnLeft == ((pane - theme.maximumTextWidth) / 2).rounded(.down), "the column is centred in the page, not in the window")
            #expect(editor.titlebar.frame.width == pane && editor.titlebar.frame.minX == 0)
            #expect(editor.titlebar.frame.height == editor.view.safeAreaInsets.top + theme.titlebarFadeHeight && editor.view.safeAreaInsets.top > 20)
            #expect(editor.footer.frame.width == pane)

            // Narrow: the column gives way, with the page's padding on both sides.
            window.setContentSize(NSSize(width: sidebar + 520, height: 700))
            #expect(await wait { editor.view.frame.width == 520 })
            #expect(textView.textContainerInset.width == theme.pagePadding.width && textView.columnWidth == 520 - 2 * theme.pagePadding.width)

            // The window cannot be made narrower than the tree and the smallest page together.
            window.setContentSize(NSSize(width: 300, height: 700))
            await pause(0.2)
            #expect(editor.view.frame.width >= theme.minimumWindowSize.width && treeWidth(controller) >= theme.sidebarWidthRange.lowerBound)

            // Showing and hiding the tree does not scroll the text or change it.
            window.setContentSize(NSSize(width: 1100, height: 500))
            await pause(0.2)
            let top = editor.scrollView.contentView.bounds.minY
            controller.toggleFiles(nil)
            #expect(await wait { editor.view.frame.width == 1100 })
            await pause(0.3)
            #expect(editor.scrollView.contentView.bounds.minY == top)
            controller.toggleFiles(nil)
            #expect(await wait { editor.view.frame.width == 1100 - treeWidth(controller) && treeWidth(controller) >= sidebar })
            await pause(0.3)
            #expect(editor.scrollView.contentView.bounds.minY == top)
            #expect(try document(controller)?.data(ofType: MarkdownDocument.typeName) == Fixtures.data("kitchen-sink.md"))
            #expect(textView.textLayoutManager != nil)
        }

        // MARK: folders

        @Test func openingAFolderShowsItsTreeAndNoFile() async throws {
            let folder = try TemporaryFolder(["a.md", "docs/x.md", "Readme.md", "z.txt"])
            defer { folder.remove() }
            defer { closeAll() }
            #expect(controllers.isEmpty)

            DocumentWindowController.openFolder(folder.url)
            DocumentWindowController.openFolder(folder.url)
            #expect(controllers.count == 1, "asked for twice, as by a launch that names the folder, it still gets one window")
            let controller = try #require(controllers.first), window = try #require(controller.window)
            #expect(controller.rootURL == folder.url && controller.isSidebarVisible)
            #expect(controller.document == nil && NSDocumentController.shared.documents.isEmpty, "no file is chosen for the user")
            #expect(await wait { rows(controller) == ["docs", "a.md", "Readme.md", "z.txt"] } && selected(controller) == nil)
            #expect(window.title == folder.url.lastPathComponent && page(controller) is EmptyPage)
            let empty = try #require(page(controller))
            #expect(empty.isAccessibilityElement() && empty.accessibilityRole() == .staticText, "what the page draws is text to VoiceOver")
            #expect((empty.accessibilityValue() as? String)?.hasPrefix("\(folder.url.lastPathComponent). Select a file") == true)
            #expect(window.firstResponder === controller.sidebar.outlineView, "the keyboard is in the tree")

            // There is no text: typing does nothing, and nobody takes Save, the format commands or Find.
            SidebarWindow.type("qq", in: window)
            #expect(controller.document == nil && NSDocumentController.shared.documents.isEmpty && page(controller) is EmptyPage)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted() == ["Readme.md", "a.md", "docs", "z.txt"])
            for action in [#selector(NSDocument.save(_:)), #selector(EditorTextView.performFormatCommand(_:)), #selector(NSTextView.performTextFinderAction(_:))] {
                #expect(!takes(action, in: controller), "\(action)")
            }
            #expect(takes(#selector(DocumentWindowController.toggleFiles(_:)), in: controller) && takes(#selector(NSDocumentController.newDocument(_:)), in: controller))

            // Command-B hides and shows the tree; the keyboard comes back to it.
            controller.toggleFiles(nil)
            #expect(!controller.isSidebarVisible && page(controller) is EmptyPage)
            controller.toggleFiles(nil)
            #expect(controller.isSidebarVisible && window.firstResponder === controller.sidebar.outlineView)

            // The arrow keys and Return choose a file, which is then the window's document.
            SidebarWindow.type(SidebarWindow.down + SidebarWindow.down + "\r", in: window)
            #expect(await wait { document(controller)?.fileURL == folder["a.md"] })
            #expect(window.title == "a.md" && window.firstResponder === document(controller)?.editor?.textView && !(page(controller) is EmptyPage))
            #expect(controllers.count == 1 && openFiles == ["a.md"] && window.restorationClass != DocumentWindowController.self)

            // Asked for again, the folder's window comes forward; there is no second one. Dropped
            // on the tree or on the text, a folder opens the same way.
            DocumentWindowController.openFolder(folder.url)
            controller.sidebar.folderOpener(folder.url)
            document(controller)?.editor?.textView.folderOpener?(folder.url)
            #expect(controllers.count == 1 && openFiles == ["a.md"])

            // Closed, the window is gone for good.
            let reference = WeakReference(controller)
            document(controller)?.close()
            #expect(controllers.isEmpty)
            DocumentWindowController.openFolder(folder.url)
            let second = try #require(controllers.first)
            #expect(second !== reference.object && second.document == nil)
            second.window?.close()
            #expect(controllers.isEmpty && DocumentWindowController.all.isEmpty)
        }

        @Test func commandNInAFolderWithoutAFileMakesTheNewDocumentThere() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            defer { closeAll() }
            DocumentWindowController.openFolder(folder.url)
            let controller = try #require(controllers.first), window = try #require(controller.window)
            controller.newDocument(nil)
            let made = try #require(document(controller))
            #expect(made.fileURL == nil && made.fileType == MarkdownDocument.typeName && controllers.count == 1 && controller.window === window)
            #expect(controller.isSidebarVisible && window.title == "Untitled" && window.firstResponder === made.editor?.textView)
            SidebarWindow.type("note", in: window)
            #expect(made.editor?.text == "note")
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["a.md"], "it is no file until it is saved")
        }

        @Test func aFolderWithoutAFileIsRestoredAsItWas() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md"])
            defer { folder.remove() }
            defer { closeAll() }
            DocumentWindowController.openFolder(folder.url)
            let controller = try #require(controllers.first)
            #expect(controller.window?.isRestorable == true && controller.window?.restorationClass == DocumentWindowController.self)
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            controller.encodeRestorableState(with: coder)
            controller.window?.close()
            #expect(controllers.isEmpty)

            // There is no document for AppKit to reopen: it asks the window's class for the window.
            func restore() throws -> (window: NSWindow?, error: (any Error)?) {
                let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
                decoder.requiresSecureCoding = true
                var result: (NSWindow?, (any Error)?) = (nil, nil)
                DocumentWindowController.restoreWindow(withIdentifier: NSUserInterfaceItemIdentifier("folder"), state: decoder) { result = ($0, $1) }
                (result.0?.windowController as? DocumentWindowController)?.restoreState(with: decoder)
                return result
            }
            let restored = try #require(try restore().window?.windowController as? DocumentWindowController)
            restored.window?.orderFrontRegardless()
            #expect(restored.rootURL?.path == folder.url.path && restored.isSidebarVisible && restored.document == nil && page(restored) is EmptyPage)
            #expect(await wait { rows(restored) == ["a.md", "b.md"] } && NSDocumentController.shared.documents.isEmpty)
            restored.window?.close()

            // A folder that is gone gives no window.
            folder.remove()
            let missing = try restore()
            #expect(missing.window == nil && missing.error != nil && controllers.isEmpty)
        }

        // MARK: the empty window

        /// An untitled document in a window, as the app has when it is started by itself.
        private func untitledWindow() throws -> DocumentWindowController {
            let untitled = MarkdownDocument.untitled()
            untitled.makeWindowControllers()
            let controller = try #require(untitled.windowControllers.first as? DocumentWindowController)
            controller.window?.orderFrontRegardless()
            return controller
        }

        /// What every way of opening a file comes down to: its document asks for its window.
        private func open(_ url: URL) throws -> DocumentWindowController {
            let opened = try MarkdownDocument.document(at: url)
            opened.makeWindowControllers()
            let controller = try #require(opened.windowControllers.first as? DocumentWindowController)
            controller.window?.orderFrontRegardless()
            return controller
        }

        @Test func aFileThatIsOpenedTakesThePlaceOfAnEmptyUntitledDocument() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md", "c.md", "d.md", "e.md"])
            defer { folder.remove() }
            defer { closeAll() }
            let pristine = try untitledWindow(), window = try #require(pristine.window)
            window.setFrame(NSRect(x: 140, y: 120, width: 700, height: 520), display: false)
            window.moveToBuiltInDisplay()
            let frame = window.frame

            let first = try open(folder["a.md"])
            #expect(first === pristine && first.window === window && window.frame == frame, "the same window, where it was")
            #expect(controllers.count == 1 && openFiles == ["a.md"] && window.title == "a.md", "the empty document is gone")
            #expect(window.firstResponder === document(first)?.editor?.textView && !first.isSidebarVisible)

            // A window with a file is not taken over, nor is one that shows a folder.
            let second = try open(folder["b.md"])
            #expect(second !== first && controllers.count == 2 && openFiles == ["a.md", "b.md"])
            DocumentWindowController.openFolder(folder.url)
            let tree = try #require(controllers.first { $0.rootURL != nil })
            tree.newDocument(nil)
            #expect(document(tree)?.isPristine == true)
            #expect(try open(folder["c.md"]) !== tree && document(tree)?.fileURL == nil && controllers.count == 4)

            // An untitled document with text is never replaced, nor one whose text was typed and taken back.
            let written = try untitledWindow()
            document(written)?.editor?.textView.insertText("mine", replacementRange: NSRange(location: 0, length: 0))
            #expect(try open(folder["d.md"]) !== written && document(written)?.editor?.text == "mine" && controllers.count == 6)
            let emptied = try untitledWindow(), text = try #require(document(emptied)?.editor?.textView)
            SidebarWindow.type("x", in: try #require(emptied.window))
            text.deleteBackward(nil)
            #expect(await wait { self.document(emptied)?.isDocumentEdited == true } && text.string.isEmpty)
            document(first)?.close()
            #expect(try open(folder["a.md"]) !== emptied && document(emptied)?.fileURL == nil)

            // Dropped on the empty text, a Markdown file is opened there; dropped on a text, it is linked to.
            func drop(_ url: URL, on controller: DocumentWindowController) throws -> Bool {
                let pasteboard = NSPasteboard.withUniqueName()
                pasteboard.clearContents()
                pasteboard.writeObjects([url.absoluteURL as NSURL])
                let window = try #require(controller.window), text = try #require(document(controller)?.editor?.textView)
                return text.performDragOperation(Drop(pasteboard: pasteboard, location: NSPoint(x: 60, y: 60), window: window))
            }
            let target = try untitledWindow()
            #expect(try drop(folder["c.md"], on: written) && document(written)?.fileURL == nil && document(written)?.editor?.text.contains("c.md") == true)
            #expect(try drop(folder["e.md"], on: target) && document(target)?.fileURL == folder["e.md"] && document(target)?.editor?.text == "e.md")
            #expect(openFiles.filter { $0 == "untitled" }.count == 3, "the folder's new document, the one with text and the emptied one stay")

            // A new empty document does not take the place of another: Command-N twice is two windows.
            let one = try untitledWindow(), two = try untitledWindow()
            #expect(one !== two && document(one) !== document(two))

            // Only the window in front counts: an empty one behind a file's stays as it is.
            closeAll()
            let behind = try untitledWindow()
            _ = try self.window(on: folder["b.md"])
            #expect(try open(folder["a.md"]) !== behind && document(behind)?.isPristine == true && controllers.count == 3)
        }

        @Test func aFolderThatIsOpenedTakesThePlaceOfAnEmptyUntitledDocument() async throws {
            let folder = try TemporaryFolder(["a.md", "docs/b.md"]), other = try TemporaryFolder(["x.md"])
            defer { [folder, other].forEach { $0.remove() } }
            defer { closeAll() }
            let pristine = try untitledWindow(), window = try #require(pristine.window)
            window.setFrame(NSRect(x: 140, y: 120, width: 900, height: 520), display: false)
            window.moveToBuiltInDisplay()
            let frame = window.frame

            DocumentWindowController.openFolder(folder.url)
            #expect(controllers.count == 1 && controllers.first === pristine && pristine.window === window && window.frame == frame)
            #expect(pristine.rootURL == folder.url && pristine.isSidebarVisible && pristine.document == nil && page(pristine) is EmptyPage)
            #expect(NSDocumentController.shared.documents.isEmpty && window.title == folder.url.lastPathComponent)
            #expect(await wait { rows(pristine) == ["docs", "a.md"] } && window.firstResponder === pristine.sidebar.outlineView)

            // With a new window asked for, the empty one is left alone.
            let second = try untitledWindow()
            DocumentWindowController.openFolder(other.url, inNewWindow: true)
            #expect(controllers.count == 3 && document(second)?.isPristine == true && second.rootURL == nil)
            // And so it is by the command-line tool's --new-window, for a file as for a folder.
            var request = Request()
            request.items = [Request.Item(path: folder["a.md"].path)]
            request.newWindow = true
            let alone = try #require(CommandServer.open(request).documents.first)
            #expect(alone.windowControllers.first !== second && document(second)?.isPristine == true && controllers.count == 4)
            // Without it the tool's file goes into the empty window, and its folder would too.
            second.window?.orderFrontRegardless()
            request.items = [Request.Item(path: folder["docs/b.md"].path)]
            request.newWindow = false
            let reused = try #require(CommandServer.open(request).documents.first)
            #expect(reused.windowControllers.first === second && controllers.count == 4 && openFiles == ["a.md", "b.md"])
        }

        @Test func aFileOpenedFromElsewhereGoesIntoTheWindowOfItsFolderThatShowsNoFile() async throws {
            let folder = try TemporaryFolder(["a.md", "docs/b.md"]), other = try TemporaryFolder(["x.md"])
            defer { [folder, other].forEach { $0.remove() } }
            defer { closeAll() }
            DocumentWindowController.openFolder(folder.url)
            let tree = try #require(controllers.first), window = try #require(tree.window)

            // A file of another folder gets a window of its own.
            #expect(try open(other["x.md"]) !== tree && tree.document == nil && controllers.count == 2)
            // One of this folder, however deep, is shown where its folder is waiting for a file.
            #expect(try open(folder["docs/b.md"]) === tree && controllers.count == 2 && window.title == "b.md")
            #expect(tree.rootURL == folder.url && tree.isSidebarVisible && window.firstResponder === document(tree)?.editor?.textView)
            #expect(await wait { rows(tree) == ["docs", "  b.md", "a.md"] })
            // The window has its file now: the next one gets its own.
            #expect(try open(folder["a.md"]) !== tree && document(tree)?.fileURL == folder["docs/b.md"] && controllers.count == 3)
        }

        @Test func theEmptyWindowInFrontIsTakenWhateverComesForwardBeforeIt() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md"])
            defer { folder.remove() }
            defer { closeAll() }
            let first = try window(on: folder["a.md"]), pristine = try untitledWindow()
            var request = Request()
            request.items = [Request.Item(path: folder["a.md"].path), Request.Item(path: folder["b.md"].path)]
            let opened = CommandServer.open(request).documents
            #expect(opened.map(\.fileURL) == [folder["a.md"], folder["b.md"]] && document(first) === opened.first)
            #expect(document(pristine) === opened.last && controllers.count == 2 && openFiles == ["a.md", "b.md"])
        }

        /// AppKit reopens the documents of the last run one after the other, an empty untitled
        /// one among them. What it then restores into a document's window is that document's.
        @Test func aDocumentThatComesBackWithTheWindowsOfTheLastRunGetsAWindowOfItsOwn() throws {
            let folder = try TemporaryFolder(["a.md", "docs/b.md"])
            defer { folder.remove() }
            defer { closeAll() }
            DocumentWindowController.openFolder(folder.url)
            let tree = try #require(controllers.first), pristine = try untitledWindow()
            DocumentController.restoring += 1
            let restored = [try open(folder["a.md"]), try open(folder["docs/b.md"])]
            DocumentController.restoring -= 1
            #expect(controllers.count == 4 && restored.allSatisfy { $0 !== pristine && $0 !== tree } && restored[0] !== restored[1])
            #expect(document(pristine)?.isPristine == true && tree.document == nil)
            // Opened afterwards, a file goes into the empty window in front as ever.
            pristine.window?.orderFrontRegardless()
            let later = try TemporaryFolder(["c.md"])
            defer { later.remove() }
            #expect(try open(later["c.md"]) === pristine && controllers.count == 4)
        }

        // MARK: changes made by other programs

        @Test func aFileRewrittenByAnotherProgramIsShownAgainWhereTheUserWas() async throws {
            let sink = try Fixtures.data("kitchen-sink.md"), bom = try Fixtures.data("bom.md")
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let a = try folder.add("a.md", sink)
            let controller = try window(on: a), shown = try #require(document(controller)), editor = try #require(shown.editor)
            defer { closeAll() }
            controller.window?.setContentSize(NSSize(width: 700, height: 300))
            editor.textView.setSelectedRange(NSRange(location: 1200, length: 4))
            editor.scrollToSelection()
            // Where the user is: the selection, and which paragraph is at the top of the window,
            // with how much of it is scrolled out of sight. (The scroll offset itself also counts
            // the estimated heights of what is above.)
            func atTop() throws -> (offset: Int, past: CGFloat) {
                let text = editor.textView, layout = try #require(text.textLayoutManager), content = try #require(text.textContentStorage)
                let y = text.visibleRect.minY - text.textContainerOrigin.y
                let fragment = try #require(layout.textLayoutFragment(for: CGPoint(x: 1, y: y + 1)))
                return (content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location), y - fragment.layoutFragmentFrame.minY)
            }
            let selection = editor.textView.selectedRange(), top = try atTop()
            #expect(top.offset > 500)

            // More text at the end, and a byte order mark in front: what is shown is the file, byte for byte.
            let rewritten = bom.prefix(3) + sink + Data("\r\nlast line\r\n".utf8)
            try rewritten.write(to: a)
            #expect(await wait { editor.text.hasSuffix("last line\r\n") })
            #expect(try shown.data(ofType: MarkdownDocument.typeName) == rewritten && shown.fileURL == a)
            #expect(!shown.isDocumentEdited && !shown.hasUnautosavedChanges && shown.undoManager?.canUndo == false)
            let after = try atTop()
            #expect(editor.textView.selectedRange() == selection && after.offset == top.offset && abs(after.past - top.past) < 1)
            #expect(editor.textView.textLayoutManager != nil && controller.window?.firstResponder === editor.textView)

            // A shorter text: the caret is at its end.
            try Data("short\n".utf8).write(to: a)
            #expect(await wait { editor.text == "short\n" } && editor.textView.selectedRange() == NSRange(location: 6, length: 0))

            // Replaced by a file made beside it, as most programs save.
            let beside = try folder.add("a.md.tmp", Data("replaced\n".utf8))
            _ = try FileManager.default.replaceItemAt(a, withItemAt: beside)
            #expect(await wait { editor.text == "replaced\n" } && !shown.isDocumentEdited)
        }

        @Test func aFileRewrittenWhileItHasUnsavedChangesKeepsTheUsersText() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["a.md"]), shown = try #require(document(controller)), window = try #require(controller.window)
            defer { closeAll() }
            SidebarWindow.type("mine ", in: window)
            #expect(await wait { shown.hasUnautosavedChanges })
            try Data("theirs\n".utf8).write(to: folder["a.md"])
            await pause(0.8)
            #expect(shown.editor?.text == "mine a.md" && shown.isDocumentEdited, "the text on screen is the user's")
            #expect(try String(contentsOf: folder["a.md"], encoding: .utf8) == "theirs\n", "and nothing was written over the other program's")
            // Taken back, the user's changes no longer stand in the way: the window shows the file.
            shown.undoManager?.undo()
            #expect(await wait { shown.editor?.text == "theirs\n" } && !shown.isDocumentEdited)
            #expect(try String(contentsOf: folder["a.md"], encoding: .utf8) == "theirs\n")
        }

        @Test func savingDoesNotReadTheFileAgain() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["a.md"]), shown = try #require(document(controller)), window = try #require(controller.window)
            defer { closeAll() }
            SidebarWindow.type("one ", in: window)
            #expect(await wait { shown.hasUnautosavedChanges })
            try await shown.autosave(withImplicitCancellability: false)
            await pause(0.8)
            #expect(try String(contentsOf: folder["a.md"], encoding: .utf8) == "one a.md" && shown.editor?.textView.selectedRange().location == 4)
            // The undo history would be gone had the text been loaded.
            shown.undoManager?.undo()
            #expect(shown.editor?.text == "a.md")
            // A file that was only touched is not loaded either.
            shown.undoManager?.redo()
            try await shown.autosave(withImplicitCancellability: false)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: folder["a.md"].path)
            await pause(0.8)
            shown.undoManager?.undo()
            #expect(shown.editor?.text == "a.md")
        }

        @Test func aFileThatIsDeletedKeepsItsTextAndIsWrittenAgainByTheNextChange() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md"])
            defer { folder.remove() }
            let a = folder["a.md"]
            let controller = try window(on: a, root: folder.url), shown = try #require(document(controller)), window = try #require(controller.window)
            defer { closeAll() }
            #expect(await wait { rows(controller) == ["a.md", "b.md"] })

            try FileManager.default.removeItem(at: a)
            #expect(await wait { rows(controller) == ["b.md"] })
            await pause(0.5)
            #expect(shown.editor?.text == "a.md" && window.title == "a.md" && controller.document === shown && !shown.isDocumentEdited)
            #expect(shown.fileURL == a && !FileManager.default.fileExists(atPath: a.path), "nothing is written by itself")
            // Made again by another program while nothing was changed here: that is the text.
            try Data("again\n".utf8).write(to: a)
            #expect(await wait { shown.editor?.text == "again\n" } && shown.fileURL == a && !shown.isDocumentEdited)
            // The tree lists it a moment later; until then it still shows what the deletion left.
            #expect(await wait { rows(controller) == ["a.md", "b.md"] })

            // Deleted, and then typed into: the next save makes the file again.
            try FileManager.default.removeItem(at: a)
            #expect(await wait { rows(controller) == ["b.md"] })
            SidebarWindow.type("more ", in: window)
            #expect(await wait { shown.hasUnautosavedChanges })
            try await shown.autosave(withImplicitCancellability: false)
            #expect(try String(contentsOf: a, encoding: .utf8) == "more again\n" && window.title == "a.md" && shown.fileURL == a)
            #expect(!shown.isDocumentEdited && !shown.hasUnautosavedChanges)
            #expect(await wait { rows(controller) == ["a.md", "b.md"] })
            // And it is an ordinary file again: the next change is saved in place, and one from outside is shown.
            SidebarWindow.type("and ", in: window)
            #expect(await wait { shown.hasUnautosavedChanges })
            try await shown.autosave(withImplicitCancellability: false)
            #expect(try String(contentsOf: a, encoding: .utf8) == "more and again\n")
            try Data("theirs\n".utf8).write(to: a)
            #expect(await wait { shown.editor?.text == "theirs\n" })
        }

        /// AppKit is told of a change to a document's file only now and then, on a thread of its
        /// own, and then looks whether the file can still be written. MEASURED: when the file was
        /// gone by then, the next key was answered with a sheet, "The file cannot be found", and
        /// the change was in no save. That is how the test above failed once in a while.
        @Test func aFileThatIsGoneWhenTheSystemTellsOfAChangeStillTakesTheNextChange() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md"])
            defer { folder.remove() }
            let a = folder["a.md"]
            let controller = try window(on: a, root: folder.url), shown = try #require(document(controller)), window = try #require(controller.window)
            defer { closeAll() }
            #expect(await wait { rows(controller) == ["a.md", "b.md"] })
            try FileManager.default.removeItem(at: a)
            #expect(await wait { rows(controller) == ["b.md"] })
            nonisolated(unsafe) let presenter = shown
            await withCheckedContinuation { (told: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    presenter.presentedItemDidChange()
                    told.resume()
                }
            }
            // What AppKit did about it, it did on the main queue.
            await pause(0.2)

            SidebarWindow.type("more ", in: window)
            #expect(await wait { shown.hasUnautosavedChanges } && window.attachedSheet == nil)
            try await shown.autosave(withImplicitCancellability: false)
            #expect(try String(contentsOf: a, encoding: .utf8) == "more a.md" && !shown.isDocumentEdited)
        }

        @Test func aFileThatIsMovedIsFollowed() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let controller = try window(on: folder["a.md"]), shown = try #require(document(controller))
            defer { closeAll() }
            await pause(0.5)
            try FileManager.default.createDirectory(at: folder["sub/"], withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: folder["a.md"], to: folder["sub/b.md"])
            #expect(await wait { shown.fileURL?.path == folder["sub/b.md"].path })
            #expect(shown.editor?.text == "a.md" && shown.editor?.documentURL?.path == folder["sub/b.md"].path)
            // It is watched where it is now.
            try Data("there\n".utf8).write(to: folder["sub/b.md"])
            #expect(await wait { shown.editor?.text == "there\n" })
        }

        // MARK: where the windows are

        /// The windows of the tests, and the app's own when it is not the user's app (here, and
        /// in a smoke or measuring run), are on the Mac's own display, so that they keep off an
        /// external one. Asked of AppKit and of the window server. Nothing to check without one.
        @Test func windowsThatAreNotTheUsersAreOnTheBuiltInDisplay() throws {
            guard let screen = NSScreen.builtIn, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
            #expect(CGDisplayIsBuiltin(number) != 0)
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            defer { closeAll() }
            let editor = EditorWindow("text")
            defer { editor.close() }
            let file = try window(on: folder["a.md"]), tree = DocumentWindowController(rootURL: folder.url)
            tree.show(nil)
            tree.showWindow(nil)
            #expect(!DocumentWindowController.keepsWindowFrames)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            let windows = try [editor.window, #require(file.window), #require(tree.window)]
            for window in windows {
                #expect(window.isVisible && window.screen === screen)
                #expect(screen.frame.contains(NSPoint(x: window.frame.minX, y: window.frame.maxY - 1)), "top left corner at \(window.frame)")
            }
            // The window server's coordinates start at the top left of the main display.
            let bounds = CGDisplayBounds(number)
            let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []).filter {
                ($0[kCGWindowOwnerPID] as? pid_t) == getpid()
            }
            #expect(listed.count >= windows.count)
            for entry in listed {
                let frame = (entry[kCGWindowBounds] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .null
                // Its rectangle is a point larger all round than the window's.
                #expect(bounds.contains(CGPoint(x: frame.minX + 2, y: frame.minY + 2)), "a window of the tests at \(frame), outside the built-in display \(bounds)")
            }
        }

        /// The first window of a launch is on its way to the screen when `showWindow` returns,
        /// not at the end of the run-loop turn, which at a launch is after the rest of the launch.
        @Test func theFirstWindowOfALaunchIsDrawnTheMomentItIsShown() throws {
            let folder = try TemporaryFolder(["a.md", "b.md"])
            defer { folder.remove() }
            defer {
                DocumentWindowController.showsAtOnce = false
                closeAll()
            }
            func isDrawn(_ document: MarkdownDocument) -> Bool {
                document.editor?.textView.subviews.contains { $0.subviews.contains { $0.layer?.contents != nil } } == true
            }
            let later = try MarkdownDocument.document(at: folder["a.md"]), atOnce = try MarkdownDocument.document(at: folder["b.md"])
            later.makeWindowControllers()
            later.showWindows()
            #expect(later.windowControllers.first?.window?.isVisible == true && !isDrawn(later), "what AppKit does by itself: drawn when the turn ends")
            DocumentWindowController.showsAtOnce = true
            atOnce.makeWindowControllers()
            atOnce.showWindows()
            #expect(isDrawn(atOnce) && !DocumentWindowController.showsAtOnce, "drawn, and only the first window is")
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            #expect(isDrawn(later))
        }

        // MARK: closing

        /// The last defence against losing text typed after a save, by itself: with a save that
        /// leaves the undo group open, only the question a closing window asks stands between the
        /// text typed afterwards and a window that closes without writing it.
        @Test func textTheDocumentNeverHeardOfIsSavedBeforeItsWindowCloses() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let shown = try CoalescingDocument(contentsOf: folder["a.md"], ofType: MarkdownDocument.typeName)
            NSDocumentController.shared.addDocument(shown)
            let controller = DocumentWindowController()
            controller.show(shown)
            let window = try #require(controller.window)
            window.orderFrontRegardless()
            defer { closeAll() }
            // As a person does it, with keys: type, save, type on without moving the caret, close.
            SidebarWindow.type("one", in: window)
            #expect(await wait { shown.hasUnautosavedChanges })
            try await shown.autosave(withImplicitCancellability: false)
            #expect(try String(contentsOf: folder["a.md"], encoding: .utf8) == "onea.md" && !shown.isDocumentEdited && !shown.hasUnwrittenText)
            SidebarWindow.type(" two", in: window)
            await pause(0.3)
            #expect(shown.editor?.text == "one twoa.md" && !shown.isDocumentEdited && !shown.hasUnautosavedChanges,
                    "the trap: more of the same undo group, of which the document hears nothing")
            let asked = CloseAnswer()
            shown.canClose(withDelegate: asked, shouldClose: #selector(CloseAnswer.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            #expect(shown.isDocumentEdited || asked.answer != nil, "the document is seen as edited")
            #expect(await wait { asked.answer != nil })
            #expect(try asked.answer == true && String(contentsOf: folder["a.md"], encoding: .utf8) == "one twoa.md", "nothing typed is lost")
        }
    }
}

/// The View menu as the app installs it.
enum MainMenuProbe {
    static func viewItem(_ title: String) -> NSMenuItem? {
        let saved = NSApp.mainMenu
        defer { NSApp.mainMenu = saved }
        MainMenu.install()
        return NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu?.item(withTitle: title)
    }
}
