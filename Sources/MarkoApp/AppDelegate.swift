import AppKit
import MarkoEditor

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let zoomKey = "Zoom", wordCountKey = "ShowsWordCount", fullWidthKey = "FullWidth", sidebarWidthKey = "SidebarWidth"
    /// Whether `applicationDidFinishLaunching` has been reached.
    private(set) static var hasLaunched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Perf.mark("willFinishLaunching")
        if Smoke.isEnabled {
            Smoke.startedInDock = NSApp.activationPolicy() == .regular
            // Nor does it come to the front, which only a picture or a measurement needs. MEASURED:
            // AppKit asks for the front at every launch that is not LaunchServices' own in the
            // background (`finishLaunching` for the file named as argument, and the first Apple
            // event), and the window server gave it to 557 of 3,303 accessory instances that
            // were counted, with the user's keys going there while each lived. An app of the
            // background kind is refused even when it asks with `ignoringOtherApps` (0 of 3,
            // against 3 of 3); its windows show all the same.
            if !Perf.isRegularApp { NSApp.setActivationPolicy(Smoke.takesFront ? .accessory : .prohibited) }
        } else {
            // The view settings are the same in every window and are kept between launches.
            if defaults.object(forKey: zoomKey) != nil { Theme.zoom = defaults.double(forKey: zoomKey) }
            if defaults.object(forKey: wordCountKey) != nil { Theme.showsWordCount = defaults.bool(forKey: wordCountKey) }
            Theme.isFullWidth = defaults.bool(forKey: fullWidthKey)
            if defaults.object(forKey: sidebarWidthKey) != nil {
                let range = Theme.standard.sidebarWidthRange
                DocumentWindowController.sidebarWidth = min(max(defaults.double(forKey: sidebarWidthKey), range.lowerBound), range.upperBound)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(saveViewSettings), name: Theme.didChange, object: nil)
        }
        // The first window is drawn and sent to the screen the moment it is shown, and the file
        // the app was started for is shown before anything else is done: see `showWindow`.
        // Not for a picture of the window (scripts/snapshot.sh), which is then given another size
        // and appearance. MEASURED: text that is drawn, and drawn again after either changed,
        // differs by a level at the edges of its letters from text drawn once, as after any
        // resize; a picture is of a window drawn once, so that two of them can be compared.
        DocumentWindowController.showsAtOnce = ProcessInfo.processInfo.environment["MARKO_SNAPSHOT"] == nil
        showLaunchDocument()
        MainMenu.install()
        // A smoke run only answers the command-line tool on a socket of its own, never on the user's.
        if !Smoke.isEnabled || ProcessInfo.processInfo.environment["MARKO_SOCKET"] != nil { CommandServer.start() }
    }

    /// Opens the file the app was started for: the one the `marko` tool names in MARKO_FILE,
    /// Markdown whatever it is called, or a Markdown file given as the app's argument. MEASURED:
    /// AppKit gets to its argument only after the menus and the rest of its launching, 25 to
    /// 50 ms later, and then finds the file open; the tool's request finds it open as well.
    /// Anything else, and a file that cannot be read, is left to them, who say what is wrong.
    private func showLaunchDocument() {
        let named = ProcessInfo.processInfo.environment["MARKO_FILE"]
        guard let path = named ?? DocumentController.argument else { return }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard named != nil || MarkdownFile.isMarkdown(url), let document = try? MarkdownDocument.document(at: url) else { return }
        document.makeWindowControllers()
        document.showWindows()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.hasLaunched = true
        DocumentWindowController.showsAtOnce = false
        if Perf.isEnabled { Perf.run() } else if Smoke.isEnabled { Smoke.run() }
    }

    /// Not at a launch by the command-line tool, whose request is the first window. MEASURED: the
    /// launch asks this before `applicationDidFinishLaunching`; a later click on the Dock icon asks again.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        Smoke.isEnabled ? Smoke.opensUntitled : Self.hasLaunched || ProcessInfo.processInfo.environment["MARKO_CLI"] == nil
    }

    /// MEASURED: by now AppKit has saved the documents that know of unsaved changes, and it asks
    /// no more. A document that holds text its change count has not heard of is written here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let missed = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
            .filter { $0.hasUnwrittenText && !$0.hasUnautosavedChanges }
        guard !missed.isEmpty else { return .terminateNow }
        var left = missed.count, failed = false
        for document in missed {
            document.updateChangeCount(.changeDone)
            document.autosave(withImplicitCancellability: false) { error in
                if let error {
                    failed = true
                    document.presentError(error)
                }
                left -= 1
                if left == 0 { sender.reply(toApplicationShouldTerminate: !failed) }
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !Smoke.isEnabled { defaults.set(Double(DocumentWindowController.sidebarWidth), forKey: sidebarWidthKey) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc private func saveViewSettings() {
        defaults.set(Theme.zoom, forKey: zoomKey)
        defaults.set(Theme.showsWordCount, forKey: wordCountKey)
        defaults.set(Theme.isFullWidth, forKey: fullWidthKey)
    }

    // MARK: menu actions

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(string: "A Markdown editor that shows what you write.", attributes: [
            .font: Theme.standard.aboutFont, .foregroundColor: Theme.standard.aboutText,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        let question = NSAlert()
        question.messageText = "Install the “marko” command line tool?"
        question.informativeText = "A link to it is placed in ~/.local/bin, or in /usr/local/bin if that folder cannot be used. "
            + "After that, “marko notes.md” or “marko folder” in a terminal opens it in Marko."
        question.addButton(withTitle: "Install")
        question.addButton(withTitle: "Cancel")
        guard question.runModal() == .alertFirstButtonReturn else { return }
        let (isInstalled, output) = CommandLineTool.install()
        let result = NSAlert()
        result.alertStyle = isInstalled ? .informational : .warning
        result.messageText = isInstalled ? "The command line tool is installed." : "The command line tool could not be installed."
        result.informativeText = CommandLineTool.abbreviated(output)
        result.runModal()
    }

    /// File > Trusted Folders: the list to look through, where choosing a folder takes its trust away.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let folders = TrustStore.shared.trustedFolders
        menu.addItem(withTitle: folders.isEmpty ? "No Trusted Folders" : "Stop Trusting:", action: nil, keyEquivalent: "")
        for folder in folders {
            let item = menu.addItem(withTitle: (folder as NSString).abbreviatingWithTildeInPath.onOneLine, action: #selector(stopTrustingFolder(_:)), keyEquivalent: "")
            item.representedObject = folder
            item.target = self
        }
        guard !folders.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Stop Trusting All Folders", action: #selector(stopTrustingAllFolders(_:)), keyEquivalent: "").target = self
    }

    @objc func stopTrustingFolder(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? String { TrustStore.shared.stopTrusting(URL(fileURLWithPath: folder, isDirectory: true)) }
    }

    @objc func stopTrustingAllFolders(_ sender: Any?) {
        TrustStore.shared.stopTrustingAll()
    }

    private func zoomStep(_ direction: Int) -> CGFloat? {
        let steps = Theme.zoomSteps
        // The step nearest to the current zoom, then one on.
        guard let current = steps.indices.min(by: { abs(steps[$0] - Theme.zoom) < abs(steps[$1] - Theme.zoom) }),
              steps.indices.contains(current + direction) else { return nil }
        return steps[current + direction]
    }

    @objc func increaseZoom(_ sender: Any?) {
        if let zoom = zoomStep(1) { Theme.zoom = zoom }
    }

    @objc func decreaseZoom(_ sender: Any?) {
        if let zoom = zoomStep(-1) { Theme.zoom = zoom }
    }

    @objc func resetZoom(_ sender: Any?) {
        Theme.zoom = 1
    }

    @objc func toggleWordCount(_ sender: Any?) {
        Theme.showsWordCount.toggle()
    }

    @objc func toggleFullWidth(_ sender: Any?) {
        Theme.isFullWidth.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(increaseZoom(_:)): return zoomStep(1) != nil
        case #selector(decreaseZoom(_:)): return zoomStep(-1) != nil
        case #selector(resetZoom(_:)): return Theme.zoom != 1
        case #selector(toggleWordCount(_:)):
            item.title = Theme.showsWordCount ? "Hide Word Count" : "Show Word Count"
            return true
        case #selector(toggleFullWidth(_:)):
            item.state = Theme.isFullWidth ? .on : .off
            return true
        default: return true
        }
    }
}
