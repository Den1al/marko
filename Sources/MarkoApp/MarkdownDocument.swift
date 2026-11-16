import AppKit
import MarkoEditor

class MarkdownDocument: NSDocument {
    static let typeName = "net.daringfireball.markdown"
    private var file = MarkdownFile()
    private(set) var editor: EditorController?
    private var window: DocumentWindowController? { windowControllers.first as? DocumentWindowController }

    nonisolated override class var autosavesInPlace: Bool { true }

    /// Relative image and link paths start from the document's file, which Save As and Move To change.
    /// AppKit may set it from the thread a save runs on.
    nonisolated override var fileURL: URL? {
        didSet {
            if Thread.isMainThread {
                MainActor.assumeIsolated { fileURLDidChange() }
            } else {
                Task { @MainActor in fileURLDidChange() }
            }
        }
    }

    private func fileURLDidChange() {
        editor?.documentURL = fileURL
        window?.documentURLDidChange()
        watchFile()
    }

    // MARK: changes made by other programs

    /// Tells when something in the file's folder changed, while a window shows the document.
    private var watcher: (folder: String, FolderWatcher)?

    private func watchFile() {
        let folder = windowControllers.isEmpty ? nil : fileURL?.deletingLastPathComponent()
        guard folder?.path != watcher?.folder else { return }
        watcher = folder.map { folder in
            (folder.path, FolderWatcher(root: folder) { [weak self] changed in
                // The watcher also tells of the folders below.
                if changed?.contains(where: { $0.path == folder.path }) != false { self?.fileMayHaveChanged() }
            })
        }
    }

    /// The file was written by another program: a document without changes of its own shows
    /// the new text; one with changes keeps them, and saving asks which to keep. A file that
    /// is gone leaves the text where it is, and the next save makes the file again.
    private func fileMayHaveChanged() {
        guard let url = fileURL else { return }
        // Asked of the path, not of a URL, which remembers what it was last told.
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              date != fileModificationDate, !isDocumentEdited, !hasUnwrittenText else { return }
        // A file that was only touched is not read into the editor, which would end its undo history.
        if (try? Data(contentsOf: url)) == file.data {
            fileModificationDate = date
        } else {
            try? revert(toContentsOf: url, ofType: fileType ?? Self.typeName)
        }
    }

    /// Changes on disk are this document's to see, through `watchFile`. MEASURED: AppKit is told
    /// of one only now and then, on a thread of its own, and then looks again whether the file
    /// can be written; when the file was gone by then it answered the next key with "The file
    /// cannot be found" and an offer to duplicate the document, and that change was in no save.
    /// Left alone, it goes on taking the file for writable, and the save makes it again.
    nonisolated override func presentedItemDidChange() {}

    /// MEASURED: AppKit refuses to save a document in place whose file is gone ("could not be
    /// autosaved") before it writes anything. Saved as a new file at the same place, it is there again.
    override func save(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let isGone = url == fileURL && !FileManager.default.fileExists(atPath: url.path)
        super.save(to: url, ofType: typeName, for: isGone ? .saveAsOperation : saveOperation, completionHandler: completionHandler)
    }

    /// Whether the editor holds text that was neither read from the file nor written to it. The
    /// change count only hears of an edit when its undo group closes, a run-loop turn later.
    var hasUnwrittenText: Bool {
        editor.map { $0.text != file.text } ?? false
    }

    /// Whether this is a new document nothing was ever done with: no file, no text, no edit.
    var isPristine: Bool {
        fileURL == nil && newFileURL == nil && !isDocumentEdited && (editor?.text ?? file.text).isEmpty
    }

    /// The document's file is gone: it closes, and a window with a folder stays without it.
    func dropFromWindow() {
        if let window { window.drop(self) } else { close() }
    }

    /// Tells the change count of text it has not heard of, so that what follows saves it.
    func noteUnwrittenText() {
        if hasUnwrittenText, !hasUnautosavedChanges { updateChangeCount(.changeDone) }
    }

    /// The last thing before a window closes. A document that takes itself for saved is closed
    /// without being written, whatever its editor holds.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        noteUnwrittenText()
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    /// The open document for a file, or a new one read from it. It has no window yet. A link is
    /// the file it leads to: one file is one document under any name, and is saved where it is.
    static func document(at url: URL) throws -> MarkdownDocument {
        let url = url.resolvingSymlinksInPath()
        if let open = NSDocumentController.shared.document(for: url) as? MarkdownDocument { return open }
        let document = try MarkdownDocument(contentsOf: url, ofType: typeName)
        NSDocumentController.shared.addDocument(document)
        return document
    }

    static func untitled() -> MarkdownDocument {
        let document = MarkdownDocument()
        document.fileType = typeName
        NSDocumentController.shared.addDocument(document)
        return document
    }

    /// The document for a file that is not there yet: empty, named like the file, and written
    /// there at its first change.
    static func untitled(savingTo url: URL) -> MarkdownDocument {
        let documents = NSDocumentController.shared.documents.lazy.compactMap { $0 as? MarkdownDocument }
        if let waiting = documents.first(where: { $0.newFileURL?.path == url.path }) { return waiting }
        let document = untitled()
        document.newFileURL = url
        return document
    }

    /// Where the first change saves a document made for a new file. MEASURED: the place cannot
    /// simply be its `fileURL` from the start; AppKit answers the first edit of a document whose
    /// file does not exist with "The file cannot be found" and offers to duplicate it.
    private(set) var newFileURL: URL?

    override var displayName: String! {
        get { newFileURL?.lastPathComponent ?? super.displayName }
        set { super.displayName = newValue }
    }

    /// MEASURED: a file opened under another name than ".md", such as git's COMMIT_EDITMSG, is
    /// otherwise renamed to end in ".md" by the first autosave. A document keeps the name it has.
    nonisolated override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        fileURL?.pathExtension ?? super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    /// MEASURED: a file made by the first save of `untitled(savingTo:)` got the Finder's "hide
    /// extension" flag, and the window's title went from "notes.md" to "notes" at the first key:
    /// AppKit takes the flag from the last save panel, and takes it for set when there was none.
    /// The extension is hidden only where the user has seen a save panel and left it so.
    nonisolated override func fileAttributesToWrite(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL: URL?
    ) throws -> [String: Any] {
        var attributes = try super.fileAttributesToWrite(to: url, ofType: typeName, for: saveOperation, originalContentsURL: originalContentsURL)
        let key = FileAttributeKey.extensionHidden.rawValue
        // Saving is not concurrent here: AppKit asks on the main thread.
        if attributes[key] != nil, Thread.isMainThread, !MainActor.assumeIsolated({ hasRunSavePanel }) { attributes[key] = false }
        return attributes
    }

    private var hasRunSavePanel = false

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        hasRunSavePanel = true
        return super.prepareSavePanel(savePanel)
    }

    /// A new document that starts with text which is in no file.
    static func untitled(holding text: String) -> MarkdownDocument {
        let document = untitled()
        document.makeEditor().text = text
        document.updateChangeCount(.changeDone)
        return document
    }

    /// Puts the caret at the start of a line, counted from 1; past the last line, on the last.
    func select(line: Int) {
        let editor = makeEditor(), text = editor.text as NSString
        var start = 0
        for _ in 1..<max(line, 1) {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            // The end of the text is a line of its own only behind a line break.
            if next == start || (next == text.length && text.lineRange(for: NSRange(location: next, length: 0)).location != next) { break }
            start = next
        }
        editor.textView.setSelectedRange(NSRange(location: start, length: 0))
        editor.scrollToSelection()
    }

    /// MEASURED: the first save after opening otherwise leaves the old text as "name~.md" beside
    /// the file for about a second, where the tree, git and whatever runs after `marko --wait`
    /// find it. Without it the save still replaces the file in one step, and the version browser
    /// still gets the old text.
    nonisolated override var backupFileURL: URL? { nil }

    /// Run once when the document has closed: what `marko --wait` waits for.
    var closeHandlers: [() -> Void] = []

    override func close() {
        super.close()
        watcher = nil
        let handlers = closeHandlers
        closeHandlers = []
        handlers.forEach { $0() }
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        guard change == .changeDone, let url = newFileURL else {
            editor?.isEdited = isDocumentEdited
            // Changes taken back: what another program wrote meanwhile was kept out, and is shown now.
            if !isDocumentEdited { fileMayHaveChanged() }
            return
        }
        // MEASURED: the title showed this change as unsaved for one frame, until the write some
        // 10 ms later. It shows what the document is when the write is over.
        newFileURL = nil
        save(to: url, ofType: Self.typeName, for: .saveAsOperation) { [weak self] error in
            guard let self else { return }
            editor?.isEdited = isDocumentEdited
            if let error { presentError(error) }
        }
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        editor?.isEdited = isDocumentEdited
    }

    // MARK: restoration
    //
    // AppKit reopens the document and puts its window back; where the caret was is kept here.

    @objc private func selectionDidChange(_ notification: Notification) {
        invalidateRestorableState()
    }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        if let editor { coder.encode(NSStringFromRange(editor.textView.selectedRange()) as NSString, forKey: "selection") }
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        guard let editor, let saved = coder.decodeObject(of: NSString.self, forKey: "selection") else { return }
        // The file may have become shorter since.
        let range = NSRangeFromString(saved as String), length = (editor.text as NSString).length
        let selection = NSRange(location: min(range.location, length), length: min(range.length, length - min(range.location, length)))
        editor.textView.setSelectedRange(selection)
        editor.scrollToSelection()
    }

    /// A link to a Markdown file opens here; a web or mail address goes to the app the system has
    /// for it. The editor hands over nothing else, and any other file would not be opened: it
    /// could be a program.
    static func open(_ url: URL) {
        guard url.isFileURL else {
            NSWorkspace.shared.open(url)
            return
        }
        guard MarkdownFile.isMarkdown(url) else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    /// The system's message for text in another encoding names neither the file nor the encoding wanted.
    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        do {
            try super.read(from: url, ofType: typeName)
        } catch let error as CocoaError where error.code == .fileReadInapplicableStringEncoding {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [
                NSURLErrorKey: url,
                NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” is not UTF-8 text.",
                NSLocalizedRecoverySuggestionErrorKey: "Marko opens UTF-8 files only, so that it never saves one in another encoding than it had. "
                    + "Convert the file to UTF-8 to edit it here.",
            ])
        }
    }

    // AppKit declares this nonisolated but calls it on the main thread, since concurrent reading is not enabled.
    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        let file = try MarkdownFile(data: data)
        MainActor.assumeIsolated {
            self.file = file
            // The same text again (a file that was only touched) leaves the editor and its undo alone;
            // other text comes up where the user was, as far as it reaches.
            guard let editor, editor.text != file.text else { return }
            let place = editor.place
            editor.text = file.text
            editor.place = place
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        if let editor {
            file.text = editor.text
            // MEASURED: typing that goes on is one undo group, and the change count hears of a
            // group when it is first made, not of every key in it. Text typed on after a save was
            // in no change: the document stayed "saved" and its window closed without writing it.
            // What is typed from here on is a new group.
            editor.textView.breakUndoCoalescing()
        }
        return file.data
    }

    /// The parse of a file the app is about to be asked for, begun as soon as its path is known:
    /// at launch that is well before AppKit gets to the document. The next editor made takes it
    /// if it is for that file.
    static var preparse: Preparse?

    /// The document's editor, which lives as long as the document; windows show it.
    func makeEditor() -> EditorController {
        if let editor { return editor }
        let editor = EditorController()
        if let ahead = Self.preparse, ahead.path == fileURL?.path { editor.preparse = ahead }
        Self.preparse = nil
        editor.text = file.text
        editor.documentURL = fileURL
        editor.linkOpener = Self.open
        editor.textView.folderOpener = { DocumentWindowController.openFolder($0) }
        // Dropped on a document nothing was ever done with, a file is opened in its place.
        editor.textView.fileOpener = { [weak self] url in
            guard let self, isPristine, let window, let dropped = try? MarkdownDocument.document(at: url) else { return false }
            if dropped.windowControllers.isEmpty { window.show(dropped) }
            dropped.showWindows()
            return true
        }
        self.editor = editor
        // MEASURED: making the watcher takes over a millisecond, and from here it runs after the
        // window's first frame. What another program wrote meanwhile is seen when it starts.
        DispatchQueue.main.async { [weak self] in
            self?.watchFile()
            self?.fileMayHaveChanged()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionDidChange), name: NSTextView.didChangeSelectionNotification, object: editor.textView)
        return editor
    }

    /// A document that is opened takes the place of a pristine one in front, or goes into the
    /// window of its folder that shows no file yet; a new empty document always gets a window,
    /// and so does one that comes back with the windows of the last run.
    override func makeWindowControllers() {
        let vacant = isPristine || DocumentController.restoring > 0 ? nil : DocumentWindowController.vacant(for: fileURL ?? newFileURL)
        (vacant ?? DocumentWindowController()).show(self)
    }
}
