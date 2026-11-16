import AppKit
import MarkoEditor

/// A window: the editor of one document, and beside it the file tree when that is shown. Choosing a
/// file in the tree keeps the window and changes the document under it. A window opened for a
/// folder has no document until a file is chosen: the tree, and the folder's name where the text
/// would be.
final class DocumentWindowController: NSWindowController, NSMenuItemValidation, NSWindowRestoration, NSWindowDelegate {
    /// The tree's width in the next new window: the one a tree was last seen at.
    static var sidebarWidth = Theme.standard.sidebarWidth
    /// Every window, from when it is made until it closes. A document keeps its window alive;
    /// the window of a folder without a file has only this.
    private(set) static var all: [DocumentWindowController] = []

    /// The file tree. A window that never shows it never pays for it: the tree and its part of
    /// the window are made when they are first wanted.
    private(set) lazy var sidebar: SidebarController = {
        let sidebar = SidebarController()
        sidebar.opener = { [weak self] in self?.open($0, focus: $1) }
        sidebar.folderOpener = { DocumentWindowController.openFolder($0) }
        sidebar.leaver = { [weak self] in self?.focusPage() }
        sidebar.mover = { DocumentWindowController.documentsFollow(from: $0, to: $1) }
        sidebar.trashHandler = { [weak self] in self?.trash($0) }
        return sidebar
    }()
    private let split = NSSplitViewController()
    private let page = NSViewController()
    private lazy var sidebarItem: NSSplitViewItem = {
        let item = NSSplitViewItem(sidebarWithViewController: sidebar), range = Theme.standard.sidebarWidthRange
        item.minimumThickness = range.lowerBound
        item.maximumThickness = range.upperBound
        item.isCollapsed = true
        split.insertSplitViewItem(item, at: 0)
        hasSidebarItem = true
        return item
    }()
    private var hasSidebarItem = false
    /// The folder the window was opened for. Without one the tree shows the folder of the file
    /// that is open when the tree first appears.
    private(set) var rootURL: URL?
    private(set) var sidebarWidth = DocumentWindowController.sidebarWidth
    /// How many animations of the tree appearing or going are running. Its width is not the
    /// user's meanwhile.
    private var toggling = 0
    /// While the current document is being saved in order to leave it.
    private var isLeaving = false
    /// What to do once the user has answered whether an untitled document may go.
    private var afterClosing: ((Bool) -> Void)?
    /// Where each file was when it left this window, by path: it comes back to the same place.
    private var places: [String: EditorController.Place] = [:]
    /// Whether windows open where the last one of their kind was left, which is kept in the
    /// user's defaults. Only the app itself says so: not a smoke run, and not the tests.
    static var keepsWindowFrames = false
    /// The name the window's frame is kept under.
    var frameName: String { rootURL == nil ? "Document" : "Folder" }
    /// Whether the next window shown is drawn and handed to the window server at once. Set
    /// while the app launches and has shown none.
    static var showsAtOnce = false

    var isSidebarVisible: Bool { hasSidebarItem && !sidebarItem.isCollapsed }
    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }
    /// The folder the window has: the one it was opened for, else the one its tree shows.
    private var folder: URL? { rootURL ?? (isSidebarVisible ? sidebar.rootURL : nil) }
    /// Whether the window holds nothing worth keeping: no folder, and an untitled document that
    /// was never saved, has no text and was never edited. What is opened next takes its place.
    private var isPristine: Bool {
        rootURL == nil && window?.attachedSheet == nil && markdownDocument?.isPristine == true
    }

    /// The window taken for the frontmost while the windows of one request are made, which
    /// bring others forward on the way.
    static var front: DocumentWindowController?

    /// The window that what is opened next goes into instead of a new one: the frontmost, if
    /// it is pristine.
    static var pristine: DocumentWindowController? {
        let front = front ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? DocumentWindowController }.first
        return front?.isPristine == true ? front : nil
    }

    /// The window a file that is opened goes into instead of a new one: the pristine one, else
    /// one that shows the file's folder and no file yet.
    static func vacant(for file: URL?) -> DocumentWindowController? {
        pristine ?? file.flatMap { file in
            all.first { $0.document == nil && $0.rootURL.map { FileTree.isPath(file.path, atOrInside: $0) } == true }
        }
    }

    init(rootURL: URL? = nil) {
        let theme = Theme.standard
        self.rootURL = rootURL
        page.view = NSView()
        let pageItem = NSSplitViewItem(viewController: page)
        pageItem.minimumThickness = theme.minimumWindowSize.width
        split.addSplitViewItem(pageItem)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: theme.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        // MEASURED: a window with a transparent titlebar takes no part in window tabs (Show Tab
        // Bar disabled, no Merge All Windows) until it is given a tabbing identifier of its own.
        window.tabbingIdentifier = "Marko"
        window.backgroundColor = theme.background
        // The editor draws the title itself, centred.
        window.titleVisibility = .hidden
        // MEASURED: only under a titlebar as high as a unified toolbar's does the tree's panel
        // run the whole height of the window, with the window buttons inside it. The toolbar is empty.
        let toolbar = NSToolbar()
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentViewController = split
        // A window that opens with the tree is wider by it, so the page is the same in both.
        window.setContentSize(NSSize(width: theme.windowSize.width + (rootURL == nil ? 0 : sidebarWidth), height: theme.windowSize.height))
        window.contentMinSize = NSSize(width: 0, height: theme.minimumWindowSize.height)
        window.center()
        super.init(window: window)
        window.delegate = self
        // A new window opens where the last one of its kind was left, a step down and right of any other.
        // One that is not the user's (a smoke or measuring run, the tests) goes on the built-in display.
        if Self.keepsWindowFrames { windowFrameAutosaveName = frameName } else { window.moveToBuiltInDisplay() }
        if rootURL != nil { setSidebarVisible(true, animated: false) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitDidResize), name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        Self.all.append(self)
    }

    /// MEASURED: a window's first picture goes to the window server at the end of the run-loop
    /// turn in which it was shown, which for the first window of a launch is after everything
    /// AppKit still does to finish launching (190 against 215 ms from the start of the process,
    /// in turn, with the file shown first thing). Handed over here, it is on screen while that
    /// goes on: with the main thread stopped right after this, the window server had the drawn
    /// window, and without, none. The launch as a whole ends 20 ms later for it.
    override func showWindow(_ sender: Any?) {
        stepAside()
        super.showWindow(sender)
        guard Self.showsAtOnce else { return }
        Self.showsAtOnce = false
        CATransaction.flush()
        Perf.noteFrames()
    }

    /// A window about to appear exactly where another one is moves to the right until it is not,
    /// as far as its display has room. MEASURED: AppKit's own step down and right needs room
    /// below, which a window nearly as high as the display does not have (900 pt on a 949 pt
    /// display): every new window then opened at the frame of the last one and hid it whole.
    private func stepAside() {
        guard let window, !window.isVisible, let room = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let taken = Self.all.compactMap { $0 === self || $0.window?.isVisible != true ? nil : $0.window?.frame }
        var frame = window.frame
        let step = Theme.standard.windowCascadeStep
        while taken.contains(frame), frame.maxX + step <= room.maxX { frame.origin.x += step }
        window.setFrameOrigin(frame.origin)
    }

    /// In full screen the titlebar comes and goes with the menu bar. MEASURED, in pictures of a
    /// full-screen window: left in place, the titlebar is a band of its own colour across the
    /// page's top, as high as the empty toolbar, however transparent it is in a window.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }

    func windowWillClose(_ notification: Notification) {
        Self.all.removeAll { $0 === self }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: documents

    /// Puts a document's editor in the window, or with nil the folder's name alone, and lets go
    /// of the document that was there, which must have been saved: a document without a window
    /// is closed.
    func show(_ document: MarkdownDocument?, focus: Bool = true) {
        let previous = markdownDocument
        guard previous !== document || page.view.subviews.isEmpty else { return }
        // The keyboard stays in the text when it was there.
        let hadKeyboard = window?.firstResponder === previous?.editor?.textView
        if let path = previous?.fileURL?.path { places[path] = previous?.editor?.place }
        previous?.removeWindowController(self)
        document?.addWindowController(self)
        let editor = document?.makeEditor()
        let view = editor?.view ?? EmptyPage(folder: folder?.lastPathComponent ?? "")
        page.view.subviews.forEach { $0.removeFromSuperview() }
        view.frame = page.view.bounds
        view.autoresizingMask = [.width, .height]
        page.view.addSubview(view)
        if let editor {
            window?.initialFirstResponder = editor.textView
            if let place = document?.fileURL.flatMap({ places[$0.path] }) {
                // The text has its width only once the page is laid out.
                page.view.layoutSubtreeIfNeeded()
                editor.place = place
            }
            if focus || hadKeyboard { focusPage() }
        } else {
            // AppKit names and restores the window of a document; this one is the folder's.
            window?.title = folder?.lastPathComponent ?? ""
            window?.representedURL = folder
            window?.identifier = NSUserInterfaceItemIdentifier("Folder")
            window?.restorationClass = Self.self
            invalidateRestorableState()
            setSidebarVisible(true, animated: false)
            window?.initialFirstResponder = sidebar.outlineView
            focusPage()
        }
        documentURLDidChange()
        if let previous, previous.windowControllers.isEmpty { previous.close() }
    }

    /// Lets go of a document whose file is gone. A window with a folder stays and shows no file;
    /// one without closes with its document.
    func drop(_ document: MarkdownDocument) {
        if document === markdownDocument, let folder {
            rootURL = folder
            show(nil)
        } else {
            document.close()
        }
    }

    /// The document was saved somewhere else, renamed, or is another one.
    func documentURLDidChange() {
        if isSidebarVisible { showTree() }
    }

    /// The keyboard goes to the text, or to the tree while there is no text.
    private func focusPage() {
        window?.makeFirstResponder(markdownDocument?.editor?.textView ?? sidebar.outlineView)
    }

    /// A file chosen in the tree: shown here, after what is here now is safe. A file that another
    /// window shows comes forward in that window.
    func open(_ url: URL, focus: Bool = true) {
        guard !isLeaving else { return }
        // A link in the tree is the file it leads to.
        let url = url.resolvingSymlinksInPath()
        if markdownDocument?.fileURL?.path == url.path {
            if focus { focusPage() }
            return
        }
        if let open = NSDocumentController.shared.document(for: url), !open.windowControllers.isEmpty {
            open.showWindows()
            return
        }
        leave(markdownDocument) { [weak self] mayLeave in
            guard let self, mayLeave else { return }
            do {
                show(try MarkdownDocument.document(at: url), focus: focus)
            } catch {
                present(error)
            }
        }
    }

    /// Makes the document safe to take out of the window: one with a file is saved to it, an
    /// untitled one with text asks, as it does when its window closes. `then` hears whether it may go.
    private func leave(_ document: MarkdownDocument?, then: @escaping (Bool) -> Void) {
        guard let document else { return then(true) }
        // An edit of this very event has not reached the change count yet.
        document.noteUnwrittenText()
        guard document.hasUnautosavedChanges || (document.fileURL == nil && document.isDocumentEdited) else { return then(true) }
        isLeaving = true
        let finish: (Bool) -> Void = { [weak self] mayLeave in
            self?.isLeaving = false
            then(mayLeave)
        }
        if document.fileURL == nil {
            afterClosing = finish
            document.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
        } else {
            document.autosave(withImplicitCancellability: false) { [weak self] error in
                if let error { self?.present(error) }
                finish(error == nil)
            }
        }
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let then = afterClosing
        afterClosing = nil
        then?(shouldClose)
    }

    private func present(_ error: Error) {
        guard let window else { return }
        presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
    }

    /// The open documents of a renamed file, or of the files in a renamed folder, go with it.
    private static func documentsFollow(from old: URL, to new: URL) {
        for document in NSDocumentController.shared.documents {
            if let path = document.fileURL.flatMap({ FileTree.path($0.path, movedFrom: old, to: new) }) {
                document.fileURL = URL(fileURLWithPath: path)
            }
        }
    }

    /// Move to Trash: the open documents in question are written first, so the Trash holds what
    /// the editor showed, and closed afterwards. A window with a folder goes on without a file.
    private func trash(_ url: URL) {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }.filter {
            $0.fileURL.map { FileTree.isPath($0.path, atOrInside: url) } == true
        }
        func save(_ rest: ArraySlice<MarkdownDocument>) {
            guard let document = rest.first else {
                guard sidebar.trash(url) else { return }
                documents.forEach { $0.dropFromWindow() }
                return
            }
            leave(document) { saved in
                if saved { save(rest.dropFirst()) }
            }
        }
        save(documents[...])
    }

    // MARK: folders

    /// Opens a folder: its tree, and no file until one is chosen. A window the folder already
    /// has comes forward, and a pristine window in front becomes the folder's, unless a new
    /// window is asked for.
    static func openFolder(_ url: URL, inNewWindow: Bool = false) {
        // The tree goes by real paths, as the documents do.
        let url = url.resolvingSymlinksInPath()
        var controller = inNewWindow ? nil : all.first { $0.rootURL?.path == url.path }
        if controller == nil {
            let taken = (inNewWindow ? nil : pristine) ?? DocumentWindowController(rootURL: url)
            taken.rootURL = url
            taken.show(nil)
            controller = taken
        }
        controller?.showWindow(nil)
        controller?.askAboutTrustIfUndecided()
    }

    // MARK: trust

    /// Whether a folder that has no answer yet is asked about when it is opened. Only the app
    /// itself says so: not a smoke run, and not the tests, unless one is about the question.
    static var asksAboutTrust = false

    /// The folder that trusting is about here: the window's, else the one the file is in.
    private var trustFolder: URL? { folder ?? markdownDocument?.fileURL?.deletingLastPathComponent() }

    /// A folder is asked about once, when it is opened and has no answer. The window is on
    /// screen by then, in safe mode, and the question comes a turn later, as a sheet on it.
    private func askAboutTrustIfUndecided() {
        guard Self.asksAboutTrust, let rootURL, !TrustStore.shared.isDecided(rootURL) else { return }
        DispatchQueue.main.async { [weak self] in self?.askAboutTrust(of: rootURL) }
    }

    /// Either answer is kept: Return and Escape both mean safe mode.
    private func askAboutTrust(of folder: URL) {
        guard let window, window.isVisible, window.attachedSheet == nil, TrustStore.canBeTrusted(folder) else { return }
        let alert = NSAlert()
        alert.messageText = "Do you trust the authors of the files in this folder?"
        // What the question says names nothing. The folder's own name, which whoever made the
        // folder chose, is under it: one line, cut in the middle, in the type of a path.
        alert.informativeText = "Documents in this folder and its subfolders will load images from the web. Those servers see when "
            + "you open a document, and your IP address. Safe mode loads nothing from the network."
        let path = NSTextField(labelWithString: (folder.path as NSString).abbreviatingWithTildeInPath.onOneLine)
        path.font = Theme.standard.promptPathFont
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.frame.size = NSSize(width: Theme.standard.promptPathWidth, height: path.fittingSize.height)
        alert.accessoryView = path
        alert.addButton(withTitle: "Open in Safe Mode")
        alert.addButton(withTitle: "Trust Folder")
        // An alert takes Escape only for a button named Cancel, and a button has one key: a
        // button that is not drawn takes Escape and answers as the first one does.
        let escape = NSButton(title: "", target: self, action: #selector(answerSafe(_:)))
        escape.keyEquivalent = "\u{1b}"
        escape.isTransparent = true
        escape.frame = .zero
        // It is a key, not a third answer: nothing to step to or to read out.
        escape.refusesFirstResponder = true
        escape.setAccessibilityElement(false)
        escape.cell?.setAccessibilityElement(false)
        alert.window.contentView?.addSubview(escape)
        asked = (folder, Self.answer(for: folder))
        NotificationCenter.default.addObserver(self, selector: #selector(trustDidChange), name: TrustStore.didChange, object: nil)
        alert.beginSheetModal(for: window) { response in
            NotificationCenter.default.removeObserver(self, name: TrustStore.didChange, object: nil)
            switch response {
            case .alertFirstButtonReturn: TrustStore.shared.stopTrusting(folder)
            case .alertSecondButtonReturn: TrustStore.shared.trust(folder)
            default: break
            }
        }
    }

    /// The folder the question on this window is about, and the answer it had when it was asked.
    private var asked: (folder: URL, answer: [Bool])?

    private static func answer(for folder: URL) -> [Bool] {
        [TrustStore.shared.isTrusted(folder), TrustStore.shared.isDecided(folder)]
    }

    /// An answer that comes from elsewhere while the question is up (`marko --trust`, the
    /// Trusted Folders menu) takes the question away: its Return would undo that answer.
    @objc private func trustDidChange() {
        guard let asked, let window, let sheet = window.attachedSheet, Self.answer(for: asked.folder) != asked.answer else { return }
        window.endSheet(sheet, returnCode: .abort)
    }

    @objc private func answerSafe(_ sender: Any?) {
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
    }

    /// File > Trust This Folder…, which asks as opening the folder does, or Stop Trusting This Folder.
    @objc func toggleFolderTrust(_ sender: Any?) {
        guard let folder = trustFolder else { return }
        if TrustStore.shared.isTrusted(folder) { TrustStore.shared.stopTrusting(folder) } else { askAboutTrust(of: folder) }
    }

    /// View > Load Remote Images: this document's, until the app quits.
    @objc func toggleRemoteImages(_ sender: Any?) {
        markdownDocument?.editor?.loadsRemoteImages.toggle()
    }

    /// Command-N in a folder's window that shows no file: the new document goes there. Anywhere
    /// else it gets a window of its own, as always.
    @objc func newDocument(_ sender: Any?) {
        if document == nil { show(.untitled()) } else { NSDocumentController.shared.newDocument(sender) }
    }

    /// Reads and watches the folder the tree is to show, the first time it is needed, and marks
    /// the window's file in it.
    private func showTree() {
        let file = markdownDocument?.fileURL
        // A document for a file that is not there yet is in that file's folder already.
        if sidebar.rootURL == nil { sidebar.rootURL = rootURL ?? (file ?? markdownDocument?.newFileURL)?.deletingLastPathComponent() }
        sidebar.currentURL = file
    }

    // MARK: sidebar

    @objc func toggleFiles(_ sender: Any?) {
        setSidebarVisible(!isSidebarVisible, animated: true)
        // The keyboard goes where the user is looking: into the tree that appeared, back to the text otherwise.
        if isSidebarVisible { window?.makeFirstResponder(sidebar.outlineView) } else { focusPage() }
    }

    private func setSidebarVisible(_ isVisible: Bool, animated: Bool) {
        guard isVisible != isSidebarVisible else { return }
        if isVisible {
            showTree()
            makeRoom()
            // MEASURED: the divider can only be placed while the tree is open and laid out, so it is
            // opened and given its width first, and closed again for the animation to open it.
            sidebarItem.isCollapsed = false
            placeDivider()
        } else {
            noteSidebarWidth()
        }
        if animated {
            sidebarItem.isCollapsed = isVisible
            toggling += 1
            NSAnimationContext.runAnimationGroup { _ in
                sidebarItem.animator().isCollapsed = !isVisible
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.toggling -= 1 }
            }
        } else {
            sidebarItem.isCollapsed = !isVisible
        }
        invalidateRestorableState()
    }

    /// MEASURED: in a window too narrow for the page beside the tree, AppKit widens the window
    /// only as far as the tree's smallest width needs. The window is widened here first, for the
    /// width the tree is to have.
    private func makeRoom() {
        guard let window, let size = window.contentView?.frame.size else { return }
        let width = sidebarWidth + Theme.standard.minimumWindowSize.width
        if size.width < width { window.setContentSize(NSSize(width: width, height: size.height)) }
    }

    private func placeDivider() {
        split.view.layoutSubtreeIfNeeded()
        split.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
    }

    /// Takes the width the tree has now as the one to show it at again, here and in the next new
    /// window. It is the width of the tree's part of the window; the tree floats inside it with a margin.
    /// A tree that is sliding in or out has no width worth keeping.
    private func noteSidebarWidth() {
        let width = split.splitView.arrangedSubviews[0].frame.width
        guard toggling == 0, Theme.standard.sidebarWidthRange.contains(width) else { return }
        sidebarWidth = width
        Self.sidebarWidth = width
    }

    /// The divider may have been dragged; the width is read when the state is saved.
    @objc private func splitDidResize(_ notification: Notification) {
        invalidateRestorableState()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleFiles(_:)):
            item.title = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        case #selector(toggleFolderTrust(_:)):
            let isTrusted = trustFolder.map(TrustStore.shared.isTrusted) == true
            item.title = isTrusted ? "Stop Trusting This Folder" : "Trust This Folder…"
            return isTrusted || trustFolder.map(TrustStore.canBeTrusted) == true
        case #selector(toggleRemoteImages(_:)):
            let editor = markdownDocument?.editor
            item.state = editor?.loadsRemoteImages == true ? .on : .off
            return editor != nil
        default: break
        }
        return true
    }

    // MARK: restoration
    //
    // AppKit reopens the document and makes its window; the tree comes back here. The window of a
    // folder without a file has no document to be reopened and is made again by `restoreWindow`.

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        if isSidebarVisible { noteSidebarWidth() }
        coder.encode(isSidebarVisible, forKey: "sidebarVisible")
        coder.encode(Double(sidebarWidth), forKey: "sidebarWidth")
        // The folder the tree showed, also where the window was opened for a file alone.
        coder.encode(((hasSidebarItem ? sidebar.rootURL : nil) ?? rootURL)?.path as NSString?, forKey: "root")
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        if let root = coder.decodeObject(of: NSString.self, forKey: "root") { rootURL = URL(fileURLWithPath: root as String, isDirectory: true) }
        if coder.containsValue(forKey: "sidebarWidth") { sidebarWidth = coder.decodeDouble(forKey: "sidebarWidth") }
        setSidebarVisible(coder.decodeBool(forKey: "sidebarVisible"), animated: false)
    }

    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) {
        // Asked with links followed: "/tmp", "/var" and "/etc" stay links in a resolved path.
        var isFolder: ObjCBool = false
        guard let root = state.decodeObject(of: NSString.self, forKey: "root") as String?,
              FileManager.default.fileExists(atPath: root, isDirectory: &isFolder), isFolder.boolValue else {
            return completionHandler(nil, CocoaError(.fileNoSuchFile))
        }
        let controller = DocumentWindowController(rootURL: URL(fileURLWithPath: root, isDirectory: true))
        controller.show(nil)
        completionHandler(controller.window, nil)
    }
}

extension String {
    /// A path as one line of a question or a menu. A name can hold line breaks and characters
    /// that are not drawn or that turn the writing round, and would pass for more of the
    /// question with them: each becomes a space, and a long path is cut in the middle.
    var onOneLine: String {
        let hidden = CharacterSet.controlCharacters.union(.newlines).union(.illegalCharacters)
        var scalars = String.UnicodeScalarView()
        for scalar in unicodeScalars { scalars.append(hidden.contains(scalar) ? " " : scalar) }
        let line = String(scalars), half = Theme.standard.shownPathLength / 2
        return line.count <= 2 * half ? line : line.prefix(half) + "…" + line.suffix(half)
    }
}
