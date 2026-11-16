import AppKit
import MarkoCommand
import MarkoEditor

/// The app's end of the `marko` command-line tool: it listens on the socket the tool connects to
/// and opens what a request names.
enum CommandServer {
    struct Opened {
        /// One line for each thing that could not be opened.
        var problems: [String] = []
        /// The documents of the files and of the piped text, which `--wait` waits for.
        var documents: [MarkdownDocument] = []
        var recents: [URL] = []
    }

    /// Listens from a thread of its own, so launching waits for none of it. Nothing happens when
    /// another instance of the app is already listening, except that an instance started for a
    /// socket of its own (`MARKO_SOCKET`) has no purpose without it and ends.
    nonisolated static func start() {
        Thread.detachNewThread {
            guard let listener = Channel.listen(at: Channel.socketPath()) else {
                if ProcessInfo.processInfo.environment["MARKO_SOCKET"] != nil { exit(0) }
                return
            }
            while let connection = Channel.accept(on: listener) {
                DispatchQueue.global(qos: .userInitiated).async {
                    // What is not a whole request is dropped.
                    guard let request = Channel.receive(on: connection) else {
                        close(connection)
                        return
                    }
                    let handle = FileHandle(fileDescriptor: connection, closeOnDealloc: true)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { answer(request, on: handle) }
                    }
                }
            }
        }
    }

    private static func answer(_ request: Request, on handle: FileHandle) {
        Perf.mark("openRequest")
        let started = Perf.clock()
        // The tool returns when the connection closes: with `--wait`, when the last document has,
        // which it is told, since the connection also closes when the app is killed.
        let finish = {
            if request.wait { try? handle.write(contentsOf: Data((Channel.closed + "\n").utf8)) }
            try? handle.close()
        }
        // The answer goes out when the files have been read, which is when everything that can go
        // wrong has: the tool does not wait for the windows.
        let opened = open(request) { problems in
            try? handle.write(contentsOf: Data((problems + [Channel.acknowledgement]).map { $0 + "\n" }.joined().utf8))
            if !request.wait { finish() }
        }
        opened.recents.forEach(NSDocumentController.shared.noteNewRecentDocumentURL)
        if Smoke.isEnabled { Smoke.served(request, opened.documents) } else { NSApp.activate(ignoringOtherApps: true) }
        var waiting = request.wait ? opened.documents.count : 0
        if request.wait, waiting == 0 { finish() }
        Perf.served(opened.documents, since: started)
        for document in opened.documents where waiting > 0 {
            document.closeHandlers.append {
                waiting -= 1
                if waiting == 0 { finish() }
            }
        }
    }

    /// Opens the files and folders of a request, each in a window; one that is open already comes
    /// forward. A file that does not exist yet becomes an empty document that saves there.
    /// `read` hears what could not be opened as soon as that is known, before any window is made.
    static func open(_ request: Request, read: ([String]) -> Void = { _ in }) -> Opened {
        var opened = Opened()
        let controller = NSDocumentController.shared
        /// What is left to do once the files are read.
        var windows: [() -> Void] = []
        func show(_ document: MarkdownDocument) {
            // In a pristine window in front, if there is one and no new window was asked for.
            if document.windowControllers.isEmpty {
                if request.newWindow { DocumentWindowController().show(document) } else { document.makeWindowControllers() }
            }
            document.showWindows()
            opened.documents.append(document)
        }
        for item in request.items {
            // The tool sends whole paths; anything else would be read from wherever the app was started.
            guard item.path.hasPrefix("/") else {
                opened.problems.append("\(item.path): not a whole path")
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            var isFolder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                // `--trust` and `--safe` are the answer for a folder, so that it is not asked about.
                if request.trust == true, !TrustStore.canBeTrusted(url) { opened.problems.append("\(item.path): too much to trust, opened in safe mode") }
                if let trust = request.trust { if trust { TrustStore.shared.trust(url) } else { TrustStore.shared.stopTrusting(url) } }
                windows.append { DocumentWindowController.openFolder(url, inNewWindow: request.newWindow) }
                opened.recents.append(url)
                continue
            }
            do {
                // Any file is taken for Markdown here, whatever its name: a commit message has no extension.
                let document = exists || controller.document(for: url) != nil ? try MarkdownDocument.document(at: url) : .untitled(savingTo: url)
                // For a file they are about that document alone, until the app quits, and are set
                // before it has a window: nothing is fetched in between.
                if let trust = request.trust { document.makeEditor().loadsRemoteImages = trust }
                windows.append {
                    show(document)
                    if let line = item.line { document.select(line: line) }
                }
                if exists { opened.recents.append(url) }
            } catch {
                opened.problems.append("\(item.path): \(error.localizedDescription)")
            }
        }
        read(opened.problems)
        // The empty window in front is for the first that needs a window, whatever comes
        // forward before it.
        DocumentWindowController.front = DocumentWindowController.pristine
        windows.forEach { $0() }
        DocumentWindowController.front = nil
        if let text = request.text {
            let document = MarkdownDocument.untitled(holding: text)
            if let trust = request.trust { document.makeEditor().loadsRemoteImages = trust }
            show(document)
        } else if request.items.isEmpty, request.newWindow || !DocumentWindowController.all.contains(where: { $0.window?.isVisible == true }) {
            show(.untitled())
        }
        return opened
    }
}
