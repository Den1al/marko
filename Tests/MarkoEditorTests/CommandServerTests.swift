import AppKit
import FixtureSupport
import MarkoCommand
import Testing
@testable import MarkoApp
@testable import MarkoEditor

extension EditorTests {
    /// What the app does with a request of the command-line tool. The socket in front of it and
    /// the tool itself are run by scripts/smoke-cli.sh.
    @Suite struct CommandServerTests {
        init() {
            NSApplication.shared.setActivationPolicy(.accessory)
            WebStub.install()
        }

        /// Windows are closed with `close()`: `performClose` plays a click on the close button, and
        /// its event ends the test process without a word, as the notes on the harness warn.
        private func closeAll() {
            for document in NSDocumentController.shared.documents { document.close() }
            for controller in DocumentWindowController.all { controller.window?.close() }
        }

        private func request(_ items: [Request.Item] = [], text: String? = nil, newWindow: Bool = false) -> Request {
            var request = Request()
            request.items = items
            request.text = text
            request.newWindow = newWindow
            return request
        }

        private func caret(_ document: MarkdownDocument) -> Int? {
            document.editor?.textView.selectedRange().location
        }

        private var folderWindows: [DocumentWindowController] {
            DocumentWindowController.all.filter { $0.rootURL != nil && $0.window?.isVisible == true }
        }

        @Test func filesOpenInWindowsOfTheirOwnWithTheCaretOnTheLineAskedFor() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let a = try folder.add("a.md", Data("one\ntwo\nthree\n".utf8)), b = try folder.add("b.md", Data("- item\n- more".utf8))
            defer { closeAll() }

            let opened = CommandServer.open(request([Request.Item(path: a.path, line: 3), Request.Item(path: b.path)]))
            #expect(opened.problems.isEmpty && opened.recents == [a, b])
            #expect(opened.documents.map(\.fileURL) == [a, b])
            let first = opened.documents[0], second = opened.documents[1]
            #expect(first.windowControllers.count == 1 && second.windowControllers.count == 1 && first.windowControllers[0] !== second.windowControllers[0])
            #expect(first.windowControllers[0].window?.isVisible == true && (first.windowControllers[0] as? DocumentWindowController)?.isSidebarVisible == false)
            #expect(caret(first) == 8 && caret(second) == 2, "line 3; and without a line, where a document opens: behind the list marker")

            // Asked for again, the open document comes forward and only the caret moves.
            let again = CommandServer.open(request([Request.Item(path: a.path, line: 2)]))
            #expect(again.documents.count == 1 && again.documents[0] === first && NSDocumentController.shared.documents.count == 2)
            #expect(caret(first) == 4)
        }

        @Test func aLineIsCountedFromOneAndEndsAtTheLastLine() throws {
            let document = MarkdownDocument.untitled(holding: "one\r\ntwo\n\nfour")
            defer { closeAll() }
            for (line, offset) in [(1, 0), (0, 0), (-4, 0), (2, 5), (3, 9), (4, 10), (5, 10), (1_000_000_000, 10)] {
                document.select(line: line)
                #expect(caret(document) == offset, "line \(line)")
            }
            let ending = MarkdownDocument.untitled(holding: "one\n")
            ending.select(line: 2)
            #expect(caret(ending) == 4, "the empty line behind the last line break")
            ending.select(line: 9)
            #expect(caret(ending) == 4)
            let empty = MarkdownDocument.untitled(holding: "")
            empty.select(line: 3)
            #expect(caret(empty) == 0)
        }

        @Test func aFileThatDoesNotExistIsADocumentNamedLikeItAndMadeByItsFirstChange() async throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let url = folder["new.md"]
            defer { closeAll() }

            let opened = CommandServer.open(request([Request.Item(path: url.path, line: 7)]))
            let document = try #require(opened.documents.first), window = try #require(document.windowControllers.first?.window)
            #expect(opened.problems.isEmpty && opened.recents.isEmpty, "nothing to list under Open Recent yet")
            #expect(document.displayName == "new.md" && window.title == "new.md" && document.editor?.text == "" && !document.isDocumentEdited)
            #expect(!FileManager.default.fileExists(atPath: url.path) && window.attachedSheet == nil)
            #expect(CommandServer.open(request([Request.Item(path: url.path)])).documents.first === document, "asked for twice, it is one document")
            // Command-B shows the folder the file will be in, before there is a file.
            let controller = try #require(document.windowControllers.first as? DocumentWindowController)
            controller.toggleFiles(nil)
            #expect(controller.sidebar.rootURL?.path == folder.url.path)
            controller.toggleFiles(nil)

            document.editor?.textView.insertText("first words\n", replacementRange: NSRange(location: 0, length: 0))
            #expect(await wait { FileManager.default.fileExists(atPath: url.path) && document.fileURL != nil })
            #expect(try String(contentsOf: url, encoding: .utf8) == "first words\n")
            #expect(document.fileURL?.path == url.path && document.editor?.documentURL?.path == url.path && window.attachedSheet == nil)
            #expect(try url.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension == false, "the Finder shows the name as it was given")
            #expect(document.displayName == "new.md" && window.title == "new.md", "and so does the window, as for every other file")
            #expect(NSDocumentController.shared.document(for: url) === document && CommandServer.open(request([Request.Item(path: url.path)])).documents.first === document)

            // From here on it is a document like any other: later changes are autosaved in place.
            document.editor?.textView.insertText("more ", replacementRange: NSRange(location: 0, length: 0))
            #expect(await wait { document.hasUnautosavedChanges })
            try await document.autosave(withImplicitCancellability: false)
            #expect(try String(contentsOf: url, encoding: .utf8) == "more first words\n")
        }

        @Test func aNewFileThatIsClosedUntouchedLeavesNothingBehind() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let document = try #require(CommandServer.open(request([Request.Item(path: folder["new.md"].path)])).documents.first)
            document.windowControllers.first?.window?.close()
            #expect(NSDocumentController.shared.documents.isEmpty && !FileManager.default.fileExists(atPath: folder["new.md"].path))
        }

        @Test func aFileWithoutTheMarkdownExtensionIsOpenedAndKeepsItsName() async throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let message = try folder.add("COMMIT_EDITMSG", Data("\n# Please enter the commit message\n".utf8))
            defer { closeAll() }

            let opened = CommandServer.open(request([Request.Item(path: message.path)]))
            let document = try #require(opened.documents.first)
            #expect(opened.problems.isEmpty && document.editor?.text == "\n# Please enter the commit message\n")
            document.editor?.textView.insertText("Fix it", replacementRange: NSRange(location: 0, length: 0))
            #expect(await wait { document.hasUnautosavedChanges })
            try await document.autosave(withImplicitCancellability: false)
            #expect(try String(contentsOf: message, encoding: .utf8) == "Fix it\n# Please enter the commit message\n")
            #expect(document.fileURL?.path == message.path && !FileManager.default.fileExists(atPath: message.path + ".md"))
        }

        @Test func whatCannotBeReadIsReportedAndTheRestStillOpens() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let binary = try folder.add("binary.md", Data([0xFF, 0xFE, 0x00])), fine = try folder.add("fine.md")
            defer { closeAll() }

            let opened = CommandServer.open(request([Request.Item(path: binary.path), Request.Item(path: fine.path)]))
            #expect(opened.problems.count == 1 && opened.problems[0].hasPrefix("\(binary.path): "))
            #expect(opened.documents.map(\.fileURL) == [fine] && opened.recents == [fine])
            #expect(NSDocumentController.shared.documents.count == 1)
        }

        @Test func whatWentWrongIsKnownBeforeAnyWindowIsMade() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let binary = try folder.add("binary.md", Data([0xFF, 0xFE, 0x00])), fine = try folder.add("fine.md", Data("one\ntwo\n".utf8))
            defer { closeAll() }

            // The tool is answered from here, so it does not wait for the windows.
            var heard: [[String]] = []
            let opened = CommandServer.open(request([Request.Item(path: binary.path), Request.Item(path: fine.path, line: 2), Request.Item(path: "x")])) { problems in
                heard.append(problems)
                let document = NSDocumentController.shared.document(for: fine)
                #expect(document != nil && document?.windowControllers.isEmpty == true, "read, and not shown yet")
            }
            #expect(heard == [opened.problems] && opened.problems.count == 2)
            #expect(opened.documents.map(\.fileURL) == [fine] && opened.documents[0].windowControllers.first?.window?.isVisible == true)
            #expect(caret(opened.documents[0]) == 4)
        }

        @Test func aPathThatIsNotWholeIsReportedAndNotReadFromWhereTheAppIs() throws {
            defer { closeAll() }
            let opened = CommandServer.open(request([Request.Item(path: ""), Request.Item(path: "Package.swift"), Request.Item(path: "Sources")]))
            #expect(opened.problems == [": not a whole path", "Package.swift: not a whole path", "Sources: not a whole path"])
            #expect(opened.documents.isEmpty && opened.recents.isEmpty && NSDocumentController.shared.documents.isEmpty && folderWindows.isEmpty)
        }

        @Test func pipedTextIsANewDocumentThatAsksBeforeItIsThrownAway() throws {
            defer { closeAll() }
            let opened = CommandServer.open(request(text: "# piped\n"))
            let document = try #require(opened.documents.first)
            #expect(opened.documents.count == 1 && opened.problems.isEmpty && opened.recents.isEmpty)
            #expect(document.fileURL == nil && document.editor?.text == "# piped\n" && document.isDocumentEdited)
            #expect(document.windowControllers.first?.window?.isVisible == true)
        }

        @Test func aFolderOpensWithItsTreeAndOnlyTwiceWhenANewWindowIsAskedFor() async throws {
            let folder = try TemporaryFolder(["README.md", "notes.md"])
            defer { folder.remove() }
            defer { closeAll() }

            let opened = CommandServer.open(request([Request.Item(path: folder.url.path)]))
            #expect(opened.documents.isEmpty && opened.problems.isEmpty && opened.recents.map(\.path) == [folder.url.path])
            let window = try #require(folderWindows.first)
            #expect(folderWindows.count == 1 && window.isSidebarVisible && window.rootURL?.path == folder.url.path)
            #expect(window.document == nil && NSDocumentController.shared.documents.isEmpty, "the folder, and no file of it")

            _ = CommandServer.open(request([Request.Item(path: folder.url.path)]))
            await pause(0.3)
            #expect(folderWindows.count == 1, "the window it has comes forward")
            _ = CommandServer.open(request([Request.Item(path: folder.url.path)], newWindow: true))
            #expect(folderWindows.count == 2)
        }

        @Test func nothingToOpenMakesAWindowOnlyWhenThereIsNoneOrOneIsAskedFor() throws {
            defer { closeAll() }
            let first = CommandServer.open(request()).documents
            #expect(first.count == 1 && first[0].fileURL == nil && first[0].windowControllers.first?.window?.isVisible == true,
                    "like a click on the Dock icon without a window")
            #expect(CommandServer.open(request()).documents.isEmpty && NSDocumentController.shared.documents.count == 1)
            #expect(CommandServer.open(request(newWindow: true)).documents.count == 1 && NSDocumentController.shared.documents.count == 2)
        }

        @Test func aDocumentTellsWhenItHasClosedOnce() async throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let a = try folder.add("a.md")
            let document = try #require(CommandServer.open(request([Request.Item(path: a.path)])).documents.first)
            var closed = 0
            document.closeHandlers.append { closed += 1 }
            #expect(closed == 0)
            document.windowControllers.first?.window?.close()
            #expect(await wait { closed == 1 } && NSDocumentController.shared.documents.isEmpty)
            document.close()
            #expect(closed == 1)
        }
    }
}
