import AppKit
import MarkoCommand
import MarkoEditor

/// Self-terminating launch check: `MARKO_SMOKE=1 Marko <file or folder>` opens it, prints what it sees
/// and quits. Without an argument it waits for the window of what the system asks it to open, which
/// is how a file or folder dropped on the app's icon arrives.
///
/// `MARKO_LINK=<destination>` also follows that link from the document, and merges the windows
/// there are then into tabs.
/// `MARKO_UNTITLED=1` lets the app open an empty document when it is started for nothing else, as
/// it does outside a smoke run.
/// `MARKO_SIDEBAR=1` toggles the sidebar first, as Command-B does.
/// `MARKO_RENAME=<path>` starts editing that item's name in the tree.
/// `MARKO_SWITCH=<path>` also chooses that file in the sidebar's folder, after typing into the
/// first if there is one (a folder opens without a file).
/// `MARKO_INSTALL=<folder>` also installs the command-line tool there, as the menu item does.
/// `MARKO_SERVE=<log file>` opens nothing; with `MARKO_SOCKET=<path>` the app then waits for the
/// `marko` command-line tool and writes to the log what each request left open. A document the tool
/// waits for is typed into and its window closed. scripts/smoke-cli.sh ends that run; it ends
/// itself after a minute.
///
/// `MARKO_TRUST=ask` lets a folder without an answer be asked about, as outside a smoke run;
/// the picture is then of the window with the question on it.
///
/// To look at the result, also set `MARKO_SNAPSHOT=<png path>`, optionally with
/// `MARKO_APPEARANCE=light|dark`, `MARKO_CARET=<offset>[,<length>]` (the selection, scrolled
/// into view), `MARKO_SIZE=<width>x<height>` (the window's content size), `MARKO_ZOOM=<factor>`
/// and `MARKO_FULLWIDTH=1` (View > Full Width).
enum Smoke {
    private static let environment = ProcessInfo.processInfo.environment
    /// A measuring run (`MARKO_PERF`, see Perf.swift) keeps away from the user's settings, window
    /// frames and socket in the same way.
    static let isEnabled = environment["MARKO_SMOKE"] == "1" || Perf.isEnabled
    /// What a smoke run would have put in Open Recent, which it leaves alone.
    static var recents: [URL] = []
    /// Whether the app started as one that has a Dock icon (see main.swift).
    static var startedInDock = false
    /// A picture is of the frontmost app's window, and a measurement may ask for the front; any
    /// other run is an app of the kind that cannot have it (see `applicationWillFinishLaunching`).
    static let takesFront = Perf.isEnabled || environment["MARKO_SNAPSHOT"] != nil
    /// Whether this instance is the frontmost app, and whether it is of the kind that cannot be.
    static var front: String { "active=\(NSApp.isActive) background=\(NSApp.activationPolicy() == .prohibited)" }

    static let opensUntitled = environment["MARKO_UNTITLED"] == "1"
    private static let serveLog = environment["MARKO_SERVE"]
    private static var served = 0

    static func run() {
        let limit: UInt32 = serveLog == nil ? 20 : 60
        Thread.detachNewThread {
            sleep(limit)
            print("smoke: HARD TIMEOUT")
            exit(3)
        }
        if serveLog != nil { return log("started pid=\(getpid())") }
        guard let path = DocumentController.argument else { return awaitWindow(tries: 100, openedBy: "event") }
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, error in
            if let error { fail("open failed: \(error.localizedDescription)") }
            // A folder has a window and no document.
            awaitWindow(tries: 100, openedBy: "argument")
        }
    }

    private static func log(_ line: String) {
        guard let serveLog, let data = "serve: \(line)\n".data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: serveLog) {
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            FileManager.default.createFile(atPath: serveLog, contents: data)
        }
    }

    /// The command-line tool asked for something and these documents were opened for it. Once the
    /// windows have settled, the log gets every open document as name@caret line+text length, and
    /// the folders that have a window with the tree showing.
    static func served(_ request: Request, _ documents: [MarkdownDocument]) {
        served += 1
        let number = served
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let open = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }.filter { !$0.windowControllers.isEmpty }.map {
                let text = ($0.editor?.text ?? "") as NSString, caret = $0.editor?.textView.selectedRange().location ?? 0
                let line = text.substring(to: caret).components(separatedBy: "\n").count
                return "\($0.displayName ?? "")@\(line)+\(text.length)"
            }
            let controllers = DocumentWindowController.all.filter { $0.window?.isVisible == true }
            // What safe mode came to: the trusted folders, the documents that load remote images,
            // and how many windows have a question on them.
            let loading = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
                .filter { $0.editor?.loadsRemoteImages == true }.compactMap(\.displayName)
            let trusted = TrustStore.shared.trustedFolders.map { ($0 as NSString).lastPathComponent }
            log("trust=\(number) trusted=\(trusted.joined(separator: ",")) loading=\(loading.sorted().joined(separator: ",")) "
                + "questions=\(controllers.count { $0.window?.attachedSheet != nil })")
            let folders = controllers.filter(\.isSidebarVisible).compactMap { $0.rootURL?.lastPathComponent }
            log("front=\(number) \(front)")
            log("request=\(number) documents=\(open.sorted().joined(separator: ",")) folders=\(folders.sorted().joined(separator: ",")) windows=\(controllers.count)")
            guard request.wait else { return }
            // What someone does with a commit message: write it and close the window.
            let windows = documents.compactMap { $0.windowControllers.first?.window }
            // The keys go through the app's event queue a moment apart, as the keyboard's do: each
            // is an event of its own, at whose end the undo manager closes its group and the
            // document hears of the edit. MEASURED: keys handed straight to the window never tell
            // the document. A new file is saved at its first key, so the rest is typed into a
            // document that has just been saved.
            var left = windows.count
            for window in windows {
                typing.append((window, {
                    left -= 1
                    guard left == 0 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        log("closing=\(number)")
                        windows.forEach { $0.performClose(nil) }
                    }
                }))
                if typing.count == 1 { type("smoke edit\r") }
            }
        }
    }

    /// The windows waiting to be typed into, one after the other: MEASURED, a key in the app's
    /// queue goes to the key window, whatever window it names.
    private static var typing: [(window: NSWindow, then: () -> Void)] = []

    private static func type(_ text: Substring) {
        guard let window = typing.first?.window else { return }
        // A key that is still in the queue goes to the window that is the key one when it is
        // taken out. MEASURED on a loaded machine: the Return typed last came out after the
        // next window had been made key and was typed there, so nothing goes on before it has.
        guard NSApp.nextEvent(matching: [.keyDown, .keyUp], until: nil, inMode: .default, dequeue: false) == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { type(text) }
            return
        }
        guard let character = text.first else {
            typing.removeFirst().then()
            return type("smoke edit\r")
        }
        window.makeKey()
        press(String(character), character == "\r" ? 36 : 0, in: window, posted: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { type(text.dropFirst()) }
    }

    private static func awaitWindow(tries: Int, openedBy: String) {
        if let controller = DocumentWindowController.all.first(where: { $0.window?.isVisible == true }) {
            report(controller, openedBy: openedBy)
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { awaitWindow(tries: tries - 1, openedBy: openedBy) }
        } else {
            fail("no window was opened")
        }
    }

    /// A window that shows a folder and no file has neither document nor editor.
    private static func report(_ controller: DocumentWindowController, openedBy: String) {
        guard let window = controller.window else { fail("no window") }
        let document = controller.document as? MarkdownDocument, editor = document?.editor
        let url = document?.fileURL
        arrange(window, editor)
        let toggle = {
            if environment["MARKO_SIDEBAR"] == "1" { controller.toggleFiles(nil) }
            if let path = environment["MARKO_RENAME"] { controller.sidebar.rename(at: URL(fileURLWithPath: path)) }
        }
        var untyped: String?
        // The app the user is in, which gets the front back when the picture is taken.
        var previous: NSRunningApplication?
        if environment["MARKO_SNAPSHOT"] != nil {
            previous = NSWorkspace.shared.frontmostApplication
            // Only the key window draws its caret and the accent-coloured selection.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // MEASURED: keys the user pressed in that half second were typed into the document
            // and saved when the app ended; a fixture of the tests gained two empty lines that
            // way. Nothing from the keyboard or the mouse reaches a window being photographed,
            // which a key put in the queue here shows: `keysIgnored`.
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in nil }
            untyped = editor?.text ?? ""
            press("x", 7, in: window, posted: true)
            // The sidebar once the window is key, as it is when Command-B is pressed. MEASURED: a
            // text view that gives the keyboard to the tree in a window that is not key yet shows
            // its caret all the same once the window is, and where the caret was before the tree
            // took its room: the pictures had a caret the app never shows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { toggle() }
        } else {
            toggle()
        }
        // Layout, the reveal nudge and drawing settle over a few run-loop turns; for a picture, after the sidebar has opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + (untyped == nil ? 0.5 : 0.65)) {
            if let untyped { print("smoke: keysIgnored=\((editor?.text ?? "") == untyped)") }
            print("smoke: file=\(url?.path ?? (document == nil ? "none" : "untitled"))")
            print("smoke: title=\(window.title)")
            print("smoke: windows=\(DocumentWindowController.all.count) documents=\(NSDocumentController.shared.documents.count)")
            print("smoke: keyboard=\(controller.isSidebarVisible && window.firstResponder === controller.sidebar.outlineView ? "tree" : window.firstResponder === editor?.textView ? "text" : "other")")
            if let document, let editor {
                print("smoke: textLength=\((editor.text as NSString).length)")
                print("smoke: textLayoutManager=\(editor.textView.textLayoutManager != nil)")
                print("smoke: savesByteIdentical=\((try? document.data(ofType: document.fileType ?? "")) == (url.map { (try? Data(contentsOf: $0)) } ?? Data()))")
                print("smoke: selection=\(editor.textView.selectedRange().location)")
                print("smoke: documentURL=\(editor.documentURL == url)")
            }
            print("smoke: windowVisible=\(window.isVisible)")
            print("smoke: safeMode=\(editor.map { String($0.isInSafeMode) } ?? "none") loadsRemoteImages=\(editor?.loadsRemoteImages == true) "
                + "question=\(window.attachedSheet != nil)")
            print("smoke: menus=\(NSApp.mainMenu?.items.compactMap { $0.submenu?.title }.joined(separator: ",") ?? "")")
            let format = NSApp.mainMenu?.items.first { $0.submenu?.title == "Format" }?.submenu
            let table = format?.item(withTitle: "Table")?.submenu
            print("smoke: tableCommands=\(table?.items.count { !$0.isSeparatorItem } ?? 0)")
            print("smoke: formatCommands=\(format?.items.count { $0.action == #selector(EditorTextView.performFormatCommand(_:)) } ?? 0)")
            let view = NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu
            print("smoke: viewItems=\(view?.items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.isAlternate }.map(\.title).joined(separator: ",") ?? "")")
            // The window was on screen before the menus were made; it is in the Window menu all the same.
            print("smoke: windowMenu=\(NSApp.windowsMenu?.items.contains { $0.target === window } ?? false)")
            let file = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu
            print("smoke: openRecentItems=\(file?.items.count { $0.submenu?.items.contains { $0.action == #selector(NSDocumentController.clearRecentDocuments(_:)) } == true } ?? 0)")
            print("smoke: openedBy=\(openedBy)")
            print("smoke: startedInDock=\(startedInDock)")
            print("smoke: \(front)")
            print("smoke: icon=\(Bundle.main.url(forResource: "Marko", withExtension: "icns") != nil)")
            print("smoke: restorable=\(window.isRestorable && window.restorationClass != nil)")
            let recent = controller.rootURL ?? url
            print("smoke: recent=\(recents.contains { $0.standardizedFileURL.path == recent?.standardizedFileURL.path })")
            reportSidebar(controller, editor)
            let install = #selector(AppDelegate.installCommandLineTool(_:))
            print("smoke: installItem=\(NSApp.mainMenu?.items.first?.submenu?.items.contains { $0.action == install } ?? false)")
            if let folder = environment["MARKO_INSTALL"] {
                let result = CommandLineTool.install(in: folder)
                print("smoke: installed=\(result.isInstalled) \(result.output)")
            }
            if let link = environment["MARKO_LINK"], let editor {
                // What a Command-click on a link to `link` does; a Markdown file opens as a second document.
                editor.open(link)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
                print("smoke: documents=\(NSDocumentController.shared.documents.compactMap { $0.fileURL?.lastPathComponent }.sorted().joined(separator: ","))")
                // Two windows make one with two tabs, as Window > Merge All Windows does.
                window.mergeAllWindows(nil)
                window.tabGroup?.selectedWindow = window
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
                print("smoke: tabs=\(window.tabbedWindows?.count ?? 1) tabBar=\(window.tabGroup?.isTabBarVisible ?? false)")
            }
            let finish = {
                if let snapshot = environment["MARKO_SNAPSHOT"] {
                    let shown = (controller.document as? MarkdownDocument)?.editor?.textView ?? window.contentView
                    let source = shown.flatMap { write(window, $0, to: URL(fileURLWithPath: snapshot)) }
                    print("smoke: snapshot=\(source.map { "\(snapshot) (\($0))" } ?? "FAILED")")
                    let size = window.contentRect(forFrameRect: window.frame).size
                    print("smoke: shown=\(Int(size.width))x\(Int(size.height)) key=\(window.isKeyWindow)")
                }
                // The app does not quit under a question.
                if let question = window.attachedSheet { window.endSheet(question) }
                // MEASURED: when the frontmost app ends, the system chooses the next one, and
                // after a picture that was not the app that had been in front. The front is handed back
                // before the app ends.
                if let previous, NSApp.isActive {
                    NSApp.yieldActivation(to: previous)
                    previous.activate(from: .current)
                    let isBack = { NSWorkspace.shared.frontmostApplication == previous }
                    for _ in 0..<50 where !isBack() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
                    print("smoke: frontReturned=\(isBack())")
                }
                NSApp.terminate(nil)
            }
            guard let other = environment["MARKO_SWITCH"] else { return finish() }
            // What a click on that file in the tree does, straight after an edit.
            editor?.textView.insertText("smoke ", replacementRange: NSRange(location: 0, length: 0))
            controller.sidebar.opener(URL(fileURLWithPath: other), true)
            // The save, and the listings of the folders above the file, arrive over the next turns.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let shown = controller.document as? MarkdownDocument
                print("smoke: switched=\(shown?.fileURL?.lastPathComponent ?? "untitled")")
                print("smoke: sameWindow=\(shown?.editor?.textView.window === window) documentWindows=\(DocumentWindowController.all.count)")
                print("smoke: editKept=\(url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.hasPrefix("smoke ") == true)")
                reportSidebar(controller, shown?.editor)
                finish()
            }
        }
    }

    private static func reportSidebar(_ controller: DocumentWindowController, _ editor: EditorController?) {
        let outline = controller.sidebar.outlineView
        func name(_ row: Int) -> String? {
            guard row >= 0 else { return nil }
            return (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }
        print("smoke: sidebar=\(controller.isSidebarVisible)")
        print("smoke: root=\(controller.sidebar.rootURL?.path ?? "none")")
        print("smoke: tree=\((0..<outline.numberOfRows).compactMap(name).joined(separator: ","))")
        print("smoke: selected=\(name(outline.selectedRow) ?? "none")")
        // Where the text column is in the editor's part of the window.
        guard let editor else { return }
        let textView = editor.textView, pane = editor.view.frame.width
        print("smoke: scrolledBy=\(Int(editor.scrollView.contentView.bounds.minY + editor.scrollView.contentInsets.top))")
        let left = textView.columnLeft, right = pane - left - textView.columnWidth
        print("smoke: pane=\(Int(pane)) columnLeft=\(Int(left)) columnRight=\(Int(right)) columnCentred=\(abs(left - right) <= 1)")
    }

    /// A key going down and up in a window, as the keyboard sends it.
    /// `posted` puts it in the app's event queue instead of handing it to the window at once.
    static func press(_ characters: String, _ code: UInt16, in window: NSWindow, isARepeat: Bool = false, posted: Bool = false) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: isARepeat && type == .keyDown, keyCode: code)!
            if posted { NSApp.postEvent(event, atStart: false) } else { window.sendEvent(event) }
        }
    }

    private static func arrange(_ window: NSWindow, _ editor: EditorController?) {
        if let name = environment["MARKO_APPEARANCE"] {
            window.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        if let zoom = environment["MARKO_ZOOM"].flatMap(Double.init) { Theme.zoom = zoom }
        Theme.isFullWidth = environment["MARKO_FULLWIDTH"] == "1"
        if let size = environment["MARKO_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        if let editor, let caret = environment["MARKO_CARET"]?.split(separator: ",").compactMap({ Int($0) }), let location = caret.first {
            let textView = editor.textView, length = (textView.string as NSString).length
            let start = min(location, length)
            let selection = NSRange(location: start, length: min(caret.dropFirst().first ?? 0, length - start))
            textView.setSelectedRange(selection)
            editor.scrollToSelection()
        }
    }

    /// Writes the window server's picture of the window, titlebar included, which needs the Screen
    /// Recording permission. Without it the text view draws itself: the page without the window
    /// around it. (Drawing the whole window in-process leaves the scrolled text out.) Returns which it was.
    private static func write(_ window: NSWindow, _ textView: NSView, to url: URL) -> String? {
        try? FileManager.default.removeItem(at: url)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // A sheet is a window of its own, and its picture is the one with both: the window's leaves the sheet out.
        capture.arguments = ["-x", "-o", "-l", String((window.attachedSheet ?? window).windowNumber), url.path]
        if (try? capture.run()) != nil {
            capture.waitUntilExit()
            if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) { return "window" }
        }
        let visible = textView.visibleRect
        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: visible) else { return nil }
        textView.cacheDisplay(in: visible, to: bitmap)
        guard (try? bitmap.representation(using: .png, properties: [:])?.write(to: url)) != nil else { return nil }
        return "text view only"
    }

    private static func fail(_ message: String) -> Never {
        print("smoke: FAIL \(message)")
        exit(1)
    }
}
