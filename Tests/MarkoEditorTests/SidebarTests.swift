import AppKit
import FixtureSupport
import Testing
@testable import MarkoApp
@testable import MarkoEditor

/// A folder of its own under the temporary directory. "a/b.md" makes the folder too; a name
/// ending in "/" is an empty folder. Every file holds its own path unless told otherwise.
struct TemporaryFolder {
    let url: URL

    init(_ paths: [String] = []) throws {
        // Resolved, because that is how the system reports what changes in it.
        url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("marko-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for path in paths { try add(path) }
    }

    @discardableResult
    func add(_ path: String, _ data: Data? = nil) throws -> URL {
        let item = self[path]
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data ?? Data(path.utf8)).write(to: item)
        }
        return item
    }

    subscript(path: String) -> URL {
        url.appendingPathComponent(path, isDirectory: path.hasSuffix("/"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Waits until `condition` holds, for at most five seconds. Listings come back from another thread
/// and the system reports changes on disk a moment after they happen; both arrive on the main
/// queue, which a test only frees by suspending (spinning the run loop does not).
@discardableResult
func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
    let end = Date(timeIntervalSinceNow: seconds)
    while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

func pause(_ seconds: TimeInterval) async {
    try? await Task.sleep(for: .seconds(seconds))
}

/// A sidebar in a window of its own, with nothing behind its closures but a record of the calls.
@MainActor final class SidebarWindow {
    let sidebar = SidebarController()
    let window: NSWindow
    var opened: [URL] = [], openedExternally: [URL] = [], openers: [URL] = [], revealed: [URL] = [], moved: [[URL]] = [], left = 0

    init(_ folder: TemporaryFolder?) {
        NSApplication.shared.setActivationPolicy(.accessory)
        window = NSWindow(
            contentRect: NSRect(x: 120, y: 160, width: 260, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.moveToBuiltInDisplay()
        window.title = "Marko test (closes by itself)"
        sidebar.opener = { [unowned self] url, _ in opened.append(url) }
        sidebar.externalOpener = { [unowned self] in
            openedExternally.append($0)
            openers.append($1)
        }
        sidebar.revealer = { [unowned self] in revealed.append($0) }
        sidebar.mover = { [unowned self] in moved.append([$0, $1]) }
        sidebar.leaver = { [unowned self] in left += 1 }
        sidebar.trasher = { _ in throw CocoaError(.featureUnsupported) }
        // Not the user's clipboard.
        sidebar.pasteboard = NSPasteboard.withUniqueName()
        window.contentView = sidebar.view
        window.makeFirstResponder(sidebar.outlineView)
        window.orderFrontRegardless()
        sidebar.rootURL = folder?.url
    }

    func close() {
        sidebar.pasteboard.releaseGlobally()
        sidebar.rootURL = nil
        window.close()
    }

    var outline: NSOutlineView { sidebar.outlineView }

    /// The rows as shown, each indented by two spaces per level.
    var rows: [String] {
        (0..<outline.numberOfRows).map { row in
            String(repeating: "  ", count: outline.level(forRow: row)) + (outline.item(atRow: row) as! SidebarController.Node).entry.name
        }
    }

    var selected: String? {
        (outline.item(atRow: outline.selectedRow) as? SidebarController.Node)?.entry.name
    }

    func node(_ path: String) -> SidebarController.Node? {
        sidebar.rootURL.flatMap { sidebar.node(at: $0.appendingPathComponent(path)) }
    }

    func cell(_ path: String) -> NSTableCellView? {
        node(path).map(outline.row(forItem:)).flatMap { $0 >= 0 ? outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView : nil }
    }

    /// The context menu as a right click on the row of `path` shows it, or on the empty area below the rows.
    func menu(on path: String?) -> NSMenu? {
        let row = path.map { outline.rect(ofRow: outline.row(forItem: node($0))) } ?? NSRect(x: 0, y: outline.bounds.maxY - 2, width: 40, height: 1)
        let menu = outline.menu(for: NSEvent.mouseEvent(
            with: .rightMouseDown, location: outline.convert(NSPoint(x: row.midX, y: row.midY), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        menu.map(sidebar.menuNeedsUpdate)
        return menu
    }

    /// What the row of `path` puts on the pasteboard of a drag.
    func drag(_ path: String) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects([sidebar.outlineView(outline, pasteboardWriterForItem: node(path)!)!])
        return pasteboard
    }

    func select(_ path: String) {
        outline.selectRowIndexes([outline.row(forItem: node(path))], byExtendingSelection: false)
    }

    static let keyCodes: [Character: UInt16] = [
        "\r": 36, "\u{1B}": 53, Character(UnicodeScalar(NSDownArrowFunctionKey)!): 125, Character(UnicodeScalar(NSUpArrowFunctionKey)!): 126,
        Character(UnicodeScalar(NSRightArrowFunctionKey)!): 124, Character(UnicodeScalar(NSLeftArrowFunctionKey)!): 123,
    ]
    static let down = String(UnicodeScalar(NSDownArrowFunctionKey)!), up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    static let right = String(UnicodeScalar(NSRightArrowFunctionKey)!), left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)

    /// Real key events through a window to whatever has the keyboard there.
    static func type(_ text: String, in window: NSWindow) {
        for character in text {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: keyCodes[character].map { $0 > 100 ? [.function, .numericPad] : [] } ?? [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false,
                    keyCode: keyCodes[character] ?? 0)!)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    func type(_ text: String) { Self.type(text, in: window) }
}

extension EditorTests {
    @Suite struct FileTreeTests {
        /// "/tmp" is a link to "/private/tmp" that Foundation leaves standing in a resolved path.
        @Test func aFolderTheSystemReachesThroughALinkIsListedAndWatchedUnderItsOwnName() async throws {
            let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
            let inside = tmp.appendingPathComponent("marko-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: inside) }
            try Data("a".utf8).write(to: inside.appendingPathComponent("a.md"))
            #expect(tmp.resolvingSymlinksInPath().path == "/tmp")
            let entry = FileTree.contents(of: tmp).first { $0.name == inside.lastPathComponent }
            #expect(entry?.isDirectory == true && entry?.url.path == inside.path && entry?.destination == nil && entry?.isLocked == false)
            #expect(FileTree.contents(of: inside).map(\.url.path) == [inside.path + "/a.md"])

            var changed: Set<String> = []
            let watcher = FolderWatcher(root: tmp) { folders in changed.formUnion(folders?.map(\.path) ?? []) }
            defer { withExtendedLifetime(watcher) {} }
            try Data("b".utf8).write(to: inside.appendingPathComponent("b.md"))
            #expect(await wait { changed.contains(inside.path) }, "a change is told by the path the tree has, not by \"/private/tmp\"")
        }

        @Test func aFolderListsFoldersFirstInTheFindersOrderWithoutHiddenFilesAndJunk() async throws {
            let folder = try TemporaryFolder([
                "b.md", "a10.md", "a2.md", "A1.MD", "notes.txt", "long.markdown", "Zeta/inner.md", "alpha/", "item 9/", "item 10/",
                ".git/config", ".hidden.md", ".DS_Store", ".build/x", "node_modules/pkg/index.js", "build/out.o", "b~.md", "old~",
            ])
            defer { folder.remove() }
            let entries = FileTree.contents(of: folder.url)
            #expect(entries.map(\.name) == ["alpha", "build", "item 9", "item 10", "Zeta", "A1.MD", "a2.md", "a10.md", "b.md", "long.markdown", "notes.txt"])
            #expect(entries.map(\.isDirectory) == [true, true, true, true, true, false, false, false, false, false, false], "a folder called build is a folder like any other")
            #expect(entries.filter(\.isMarkdown).map(\.name) == ["A1.MD", "a2.md", "a10.md", "b.md", "long.markdown"])
            #expect(entries.map(\.url.path) == entries.map { folder[$0.name].path }, "every URL is the folder's plus a name")
            #expect(FileTree.contents(of: folder["Zeta/"]).map(\.name) == ["inner.md"], "one level at a time")
            #expect(FileTree.contents(of: folder["missing/"]).isEmpty && FileTree.contents(of: folder["b.md"]).isEmpty)
        }

        @Test func aLinkToAFolderIsAFolderAndListsWhatItLeadsTo() throws {
            let folder = try TemporaryFolder(["dir/x.md", "dir/sub/y.md", "a.md"]), files = FileManager.default
            defer { folder.remove() }
            try files.createSymbolicLink(atPath: folder["dirlink"].path, withDestinationPath: "dir")
            try files.createSymbolicLink(atPath: folder["alink.md"].path, withDestinationPath: "a.md")
            try files.createSymbolicLink(atPath: folder["dir/loop"].path, withDestinationPath: "..")
            try files.createSymbolicLink(atPath: folder["broken"].path, withDestinationPath: "nowhere")

            let entries = FileTree.contents(of: folder.url)
            #expect(entries.map(\.name) == ["dir", "dirlink", "a.md", "alink.md", "broken"])
            #expect(entries.map(\.isDirectory) == [true, true, false, false, false])
            #expect(entries.map(\.destination) == [nil, folder["dir"].path, nil, folder["a.md"].path, nil])

            // Listed through the link, the entries keep the path they were reached by and know where they are.
            let linked = FileTree.contents(of: entries[1].url)
            #expect(linked.map(\.url.path) == ["loop", "sub", "x.md"].map { folder["dirlink"].path + "/" + $0 })
            #expect(linked.map(\.isDirectory) == [true, true, false])
            #expect(linked.map(\.filePath) == [folder.url.path, folder["dir/sub"].path, folder["dir/x.md"].path])
            // A loop is followed as far as it is opened and no further.
            #expect(FileTree.contents(of: linked[0].url).map(\.name) == entries.map(\.name))
        }

        @Test func newItemsGetANameNothingHas() async throws {
            let folder = try TemporaryFolder(["Untitled.md", "Untitled 2.md", "Untitled Folder/"])
            defer { folder.remove() }
            #expect(FileTree.unusedName("Untitled", extension: "md", in: folder.url).lastPathComponent == "Untitled 3.md")
            #expect(FileTree.unusedName("Untitled Folder", extension: nil, in: folder.url).lastPathComponent == "Untitled Folder 2")
            #expect(FileTree.unusedName("Other", extension: "md", in: folder.url).lastPathComponent == "Other.md")
        }

        @Test func pathsFollowARename() {
            let old = URL(fileURLWithPath: "/a/docs"), new = URL(fileURLWithPath: "/a/texts")
            #expect(FileTree.path("/a/docs", movedFrom: old, to: new) == "/a/texts")
            #expect(FileTree.path("/a/docs/x/y.md", movedFrom: old, to: new) == "/a/texts/x/y.md")
            #expect(FileTree.path("/a/docs2/y.md", movedFrom: old, to: new) == nil && FileTree.path("/a", movedFrom: old, to: new) == nil)
        }

        /// What matters is where the disk is read, which no clock is needed for; how long it takes
        /// is the performance tests' business.
        @Test func aFolderOfTenThousandFilesIsNeverListedOnTheCallingThread() async throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            try folder.add("wide/")
            for index in 0..<10_000 { FileManager.default.createFile(atPath: folder["wide/file \(index).md"].path, contents: nil) }
            for index in 0..<200 { try folder.add("deep/folder \(index)/note.md") }

            let entries = FileTree.contents(of: folder["wide/"])
            #expect(entries.count == 10_000 && entries[1].name == "file 1.md" && entries[9_999].name == "file 9999.md")

            let w = SidebarWindow(nil)
            defer { w.close() }
            w.sidebar.rootURL = folder.url
            let root = try #require(w.sidebar.node(at: folder.url))
            #expect(root.children == nil && root.isListing, "choosing a folder reads nothing itself")
            #expect(await wait { w.rows == ["deep", "wide"] })
            #expect(w.node("wide")?.children == nil && w.node("deep")?.children == nil, "nothing below the root is read until it is opened")

            let wide = try #require(w.node("wide"))
            w.sidebar.activate(wide)
            #expect(wide.children == nil && wide.isListing, "nor does opening a folder")
            #expect(await wait { w.outline.numberOfRows == 10_002 })
            #expect(w.rows[2] == "  file 0.md" && w.rows[10_001] == "  file 9999.md")
            #expect(w.node("deep")?.children == nil)
        }
    }

    @Suite struct SidebarTests {
        private let theme = Theme.standard

        @Test func foldersAreListedWhenTheyAreOpenedAndTheRowsShowWhatTheyAre() async throws {
            let folder = try TemporaryFolder(["README.md", "docs/guide.md", "docs/deep/x.md", "image.png", ".git/config"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(w.rows.isEmpty, "the listing comes from another thread")
            #expect(await wait { w.rows == ["docs", "image.png", "README.md"] })
            #expect(w.node("docs")?.children == nil && w.node("docs/guide.md") == nil)

            let docs = try #require(w.cell("docs")), image = try #require(w.cell("image.png")), readme = try #require(w.cell("README.md"))
            #expect(docs.imageView?.image != nil && image.imageView?.image != nil && readme.imageView?.image != nil)
            #expect(docs.accessibilityChildren()?.count == 1 && docs.accessibilityChildren()?.first as? NSCell === docs.textField?.cell, "a row is read as its name, not as its symbol's")
            #expect(docs.imageView?.image?.tiffRepresentation != readme.imageView?.image?.tiffRepresentation, "a folder and a file have different symbols")
            #expect(readme.textField?.textColor == theme.sidebarMarkdownText && image.textField?.textColor == theme.sidebarOtherText, "what is not Markdown is dimmed")
            // The system draws its own label colours in the accent colour on a selected row without
            // the keyboard; the theme's are left alone, and white on the row that has it.
            #expect(theme.sidebarMarkdownText != .labelColor && theme.sidebarOtherText != .tertiaryLabelColor)
            readme.backgroundStyle = .emphasized
            #expect(readme.textField?.textColor == theme.sidebarHighlightedText)
            readme.backgroundStyle = .normal
            #expect(readme.textField?.textColor == theme.sidebarMarkdownText)
            #expect(readme.textField?.allowsExpansionToolTips == true, "a name that is cut short shows whole under the pointer")
            #expect(w.sidebar.header.stringValue == folder.url.lastPathComponent && w.sidebar.header.font == theme.sidebarHeaderFont)
            #expect(readme.imageView?.contentTintColor == theme.accent && image.imageView?.contentTintColor == theme.sidebarOtherText)
            #expect(w.outline.style == .sourceList && w.outline.rowHeight == theme.sidebarRowHeight)

            w.sidebar.activate(w.node("docs")!)
            #expect(await wait { w.rows == ["docs", "  deep", "  guide.md", "image.png", "README.md"] })
            #expect(w.node("docs/deep")?.children == nil)
            w.sidebar.activate(w.node("docs")!)
            #expect(w.rows == ["docs", "image.png", "README.md"], "a second click closes the folder")
        }

        /// A window that says it is in full screen: a test's app cannot enter it.
        private final class Screenful: NSWindow {
            var isFull = false
            override var styleMask: NSWindow.StyleMask {
                get { isFull ? super.styleMask.union(.fullScreen) : super.styleMask }
                set { super.styleMask = newValue }
            }
        }

        /// The folder's name stands beside the window buttons, level with them, in the tree's
        /// panel. In full screen the titlebar is not in the window: the name is not shown.
        @Test func theFoldersNameIsBesideTheWindowButtonsAndNotShownInFullScreen() throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            NSApplication.shared.setActivationPolicy(.accessory)
            let window = Screenful(contentRect: NSRect(x: 0, y: 0, width: 260, height: 500),
                                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.moveToBuiltInDisplay()
            let sidebar = SidebarController()
            window.contentView = sidebar.view
            sidebar.rootURL = folder.url
            defer {
                sidebar.rootURL = nil
                window.close()
            }
            func layOut() {
                sidebar.view.needsLayout = true
                sidebar.view.layoutSubtreeIfNeeded()
            }
            layOut()
            let button = try #require(window.standardWindowButton(.zoomButton)), header = sidebar.header
            let lights = sidebar.view.convert(button.bounds, from: button), name = header.frame
            #expect(!header.isHidden && header.stringValue == folder.url.lastPathComponent)
            #expect(abs(name.midY - lights.midY) < 0.5 && abs(name.minX - lights.maxX - Theme.standard.sidebarHeaderGap) < 0.5, "\(name) beside \(lights)")
            #expect(name.maxX <= sidebar.view.bounds.maxX && sidebar.view.bounds.contains(name))

            window.isFull = true
            layOut()
            #expect(header.isHidden)
            window.isFull = false
            layOut()
            #expect(!header.isHidden && header.frame == name, "and back where it was after full screen")
        }

        @Test func aFolderThatMayNotBeReadSaysSoAndDoesNotOpen() async throws {
            let folder = try TemporaryFolder(["open/a.md", "locked/b.md"])
            defer {
                chmod(folder["locked/"].path, 0o755)
                folder.remove()
            }
            chmod(folder["locked/"].path, 0)
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows == ["locked", "open"] })
            let locked = try #require(w.cell("locked")), open = try #require(w.cell("open"))
            #expect(w.node("locked")?.entry.isLocked == true && w.node("open")?.entry.isLocked == false)
            #expect(locked.toolTip?.contains("permission") == true && open.toolTip == nil)
            #expect(locked.imageView?.image?.tiffRepresentation != open.imageView?.image?.tiffRepresentation && locked.textField?.textColor == theme.sidebarOtherText)
            #expect(!w.sidebar.outlineView(w.outline, isItemExpandable: w.node("locked")!) && w.sidebar.outlineView(w.outline, isItemExpandable: w.node("open")!))
        }

        @Test func aMarkdownFileOpensAnyOtherFileOnlyOnADoubleClick() async throws {
            let folder = try TemporaryFolder(["a.md", "b.markdown", "c.txt", "d/"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows.count == 4 })
            w.sidebar.activate(w.node("a.md")!)
            w.sidebar.activate(w.node("b.markdown")!)
            w.sidebar.activate(w.node("c.txt")!)
            #expect(w.opened == [folder["a.md"], folder["b.markdown"]], "a click on a file that is not Markdown does nothing")
            for name in ["a.md", "c.txt", "d"] { w.sidebar.openExternally(w.node(name)!) }
            #expect(w.openedExternally == [folder["c.txt"]] && w.opened.count == 2)
        }

        @Test func theArrowKeysMoveThroughTheTreeReturnOpensAndEscapeLeaves() async throws {
            let folder = try TemporaryFolder(["docs/guide.md", "a.md", "b.txt"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows.count == 3 })
            #expect(w.window.firstResponder === w.outline && w.selected == nil)
            w.type(SidebarWindow.down)
            #expect(w.selected == "docs")
            w.type(SidebarWindow.right)
            #expect(await wait { w.rows == ["docs", "  guide.md", "a.md", "b.txt"] }, "Right opens a folder and lists it")
            w.type(SidebarWindow.down + "\r")
            #expect(w.selected == "guide.md" && w.opened == [folder["docs/guide.md"]])
            w.type(SidebarWindow.down + SidebarWindow.down + "\r")
            #expect(w.selected == "b.txt" && w.opened.count == 1, "Return on a file that is not Markdown does nothing")
            w.type(SidebarWindow.up + SidebarWindow.up + SidebarWindow.up + "\r")
            #expect(w.selected == "docs" && w.rows == ["docs", "a.md", "b.txt"], "Return closes an open folder")
            w.type("\r")
            #expect(w.rows.count == 4 && w.opened.count == 1)
            #expect(w.left == 0)
            w.type("\u{1B}")
            #expect(w.left == 1)
        }

        @Test func theCurrentFileIsSelectedMarkedAndRevealedThroughClosedFolders() async throws {
            let folder = try TemporaryFolder(["a.md", "one/two/three/deep.md", "one/two/other.md", "one/x.md"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            w.sidebar.currentURL = folder["one/two/three/deep.md"]
            #expect(await wait { w.selected == "deep.md" })
            #expect(w.rows == ["one", "  two", "    three", "      deep.md", "    other.md", "  x.md", "a.md"])
            #expect(w.cell("one/two/three/deep.md")?.textField?.font == theme.sidebarCurrentFont)
            #expect(w.cell("a.md")?.textField?.font == theme.sidebarFont)

            w.sidebar.currentURL = folder["a.md"]
            #expect(w.selected == "a.md")
            #expect(w.cell("a.md")?.textField?.font == theme.sidebarCurrentFont && w.cell("one/two/three/deep.md")?.textField?.font == theme.sidebarFont)
            // A file outside the folder, and no file, leave the tree as it is.
            w.sidebar.currentURL = URL(fileURLWithPath: "/elsewhere/x.md")
            w.sidebar.currentURL = nil
            #expect(w.rows.count == 7 && w.selected == "a.md")
        }

        @Test func changesOnDiskShowUpByThemselvesAndOpenFoldersStayOpen() async throws {
            let folder = try TemporaryFolder(["a.md", "docs/guide.md", "docs/more/x.md", "other/y.md"])
            defer { folder.remove() }
            let w = SidebarWindow(folder), files = FileManager.default
            defer { w.close() }
            #expect(await wait { w.rows.count == 3 })
            w.sidebar.activate(w.node("docs")!)
            #expect(await wait { w.node("docs/more") != nil })
            w.sidebar.activate(w.node("docs/more")!)
            #expect(await wait { w.rows == ["docs", "  more", "    x.md", "  guide.md", "other", "a.md"] })
            w.select("docs/guide.md")
            // The watcher starts a moment after the folder is chosen.
            await pause(0.5)

            try folder.add("b.md")
            #expect(await wait { w.rows == ["docs", "  more", "    x.md", "  guide.md", "other", "a.md", "b.md"] }, "a new file appears")
            #expect(w.selected == "guide.md", "and the selection stays on its file")

            try files.moveItem(at: folder["a.md"], to: folder["renamed.md"])
            #expect(await wait { w.rows == ["docs", "  more", "    x.md", "  guide.md", "other", "b.md", "renamed.md"] }, "a renamed file moves")

            try folder.add("docs/more/new.md")
            try files.removeItem(at: folder["b.md"])
            #expect(await wait { w.rows == ["docs", "  more", "    new.md", "    x.md", "  guide.md", "other", "renamed.md"] }, "inside an open folder too")
            #expect(w.selected == "guide.md")

            // What changes in a folder that was never opened is read when it is opened.
            try folder.add("other/z.md")
            await pause(0.5)
            #expect(w.node("other")?.children == nil)

            try files.removeItem(at: folder["docs/more/"])
            #expect(await wait { w.rows == ["docs", "  guide.md", "other", "renamed.md"] }, "a deleted folder goes with everything in it")
            try files.createDirectory(at: folder["docs/more/"], withIntermediateDirectories: true)
            try folder.add("docs/more/again.md")
            #expect(await wait { w.rows == ["docs", "  more", "    again.md", "  guide.md", "other", "renamed.md"] }, "and is open again when it comes back")
        }

        @Test func theContextMenuHasTheFileCommands() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows.count == 1 })
            let menu = try #require(w.outline.menu)
            w.sidebar.menuNeedsUpdate(menu)
            #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
                "New File", "New Folder", "-", "Rename", "Move to Trash", "-", "Copy Path", "Copy Relative Path", "-", "Reveal in Finder",
            ])
            // No row was clicked: the commands that need one are off, the others act on the folder itself.
            #expect(menu.items.filter(\.isEnabled).map(\.title) == ["New File", "New Folder", "Copy Path", "Copy Relative Path", "Reveal in Finder"])
            let reveal = try #require(menu.item(withTitle: "Reveal in Finder"))
            _ = reveal.target?.perform(reveal.action)
            #expect(w.revealed.map(\.path) == [folder.url.path])

            w.sidebar.rootURL = nil
            w.sidebar.menuNeedsUpdate(menu)
            #expect(menu.items.isEmpty && w.rows.isEmpty, "without a folder there is nothing to command")
        }

        @Test func aNewFileIsMadeOpenedAndReadyToBeNamed() async throws {
            let folder = try TemporaryFolder(["a.md", "Untitled.md", "docs/x.md"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows.count == 3 })

            let made = try #require(w.sidebar.create(in: w.node("docs")!, isDirectory: false))
            #expect(made == folder["docs/Untitled.md"] && (try? Data(contentsOf: made))?.isEmpty == true)
            #expect(w.opened == [made], "the new file opens")
            // The folder had not been listed: the row is there, and its name is edited, once it is.
            #expect(await wait { w.rows == ["docs", "  Untitled.md", "  x.md", "a.md", "Untitled.md"] && w.window.firstResponder is NSTextView })
            #expect(w.selected == "Untitled.md")
            w.type("\u{1B}")

            let second = try #require(w.sidebar.create(in: w.node("docs")!, isDirectory: false))
            #expect(second == folder["docs/Untitled 2.md"])
            #expect(w.rows == ["docs", "  Untitled 2.md", "  Untitled.md", "  x.md", "a.md", "Untitled.md"], "in a listed folder the row is there at once")
            #expect(w.selected == "Untitled 2.md")
            let editor = try #require(w.window.firstResponder as? NSTextView, "the name is being edited")
            #expect(editor.string == "Untitled 2.md" && editor.selectedRange() == NSRange(location: 0, length: 10), "with the part before the extension selected")
            w.type("plan\r")
            #expect(await wait { w.rows == ["docs", "  plan.md", "  Untitled.md", "  x.md", "a.md", "Untitled.md"] })
            #expect(FileManager.default.fileExists(atPath: folder["docs/plan.md"].path) && !FileManager.default.fileExists(atPath: second.path))
            #expect(w.moved == [[second, folder["docs/plan.md"]]] && w.selected == "plan.md")
            #expect(w.window.firstResponder === w.outline)

            let directory = try #require(w.sidebar.create(in: w.sidebar.node(at: folder.url)!, isDirectory: true))
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
            #expect(w.rows.first == "docs" && w.rows.contains("Untitled Folder") && w.opened.count == 2, "a new folder is not opened in the editor")
            #expect(w.window.firstResponder is NSTextView)
            w.type("x\u{1B}")
            #expect(w.rows.contains("Untitled Folder"), "Escape keeps the name it was given")
            #expect(w.window.firstResponder === w.outline && w.left == 0, "and the keyboard is back in the tree")
            #expect(w.cell("Untitled Folder")?.textField?.isEditable == false)
        }

        @Test func renamingMovesTheFileAndKeepsOpenFoldersOpen() async throws {
            let folder = try TemporaryFolder(["a.md", "b.md", "docs/sub/x.md"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            w.sidebar.currentURL = folder["docs/sub/x.md"]
            #expect(await wait { w.selected == "x.md" })

            w.sidebar.rename(w.node("a.md")!, to: "zebra.md")
            #expect(w.rows == ["docs", "  sub", "    x.md", "b.md", "zebra.md"] && w.selected == "zebra.md")
            #expect((try? String(contentsOf: folder["zebra.md"], encoding: .utf8)) == "a.md")

            w.sidebar.rename(w.node("docs")!, to: "texts")
            #expect(await wait { w.rows == ["texts", "  sub", "    x.md", "b.md", "zebra.md"] }, "what was open in a renamed folder is open again")
            #expect(w.moved == [[folder["a.md"], folder["zebra.md"]], [folder["docs/"], folder["texts/"]]])

            // A name that is taken, empty, blank, a path or one the tree would not list changes
            // nothing; the first shows why.
            for name in ["b.md", "", "   ", ".secret", "x/y.md", "zebra.md", "draft~.md", "node_modules", " zebra.md "] {
                w.sidebar.rename(w.node("zebra.md")!, to: name)
            }
            #expect(w.rows.suffix(2) == ["b.md", "zebra.md"] && w.moved.count == 2)
            let sheet = try #require(w.window.attachedSheet, "the system's reason for the failed rename")
            w.window.endSheet(sheet)
            w.sidebar.rename(w.node("zebra.md")!, to: "  build.md\n")
            #expect(w.rows.suffix(2) == ["b.md", "build.md"] && w.moved.count == 3, "blanks around a name are not part of it")
            w.sidebar.rename(w.node("texts")!, to: "build")
            #expect(await wait { w.rows == ["build", "  sub", "    x.md", "b.md", "build.md"] }, "a folder may be called build")

            // Editing a name and leaving it without Return keeps the old one.
            w.sidebar.rename(w.node("b.md")!)
            #expect((w.window.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 1))
            w.type("other")
            w.window.makeFirstResponder(w.outline)
            #expect(w.cell("b.md")?.textField?.stringValue == "b.md" && FileManager.default.fileExists(atPath: folder["b.md"].path))
            #expect(w.cell("b.md")?.textField?.isEditable == false)
        }

        @Test func aNameBeingTypedSurvivesAChangeOnDisk() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows == ["a.md"] })
            await pause(0.5)

            let made = try #require(w.sidebar.create(in: w.sidebar.node(at: folder.url)!, isDirectory: false))
            w.type("half")
            let editor = try #require(w.window.firstResponder as? NSTextView)
            #expect(editor.string == "half.md")
            // Another program writes into the folder: the tree waits with it for the name.
            try folder.add("log.txt")
            await pause(1)
            #expect(w.window.firstResponder === editor && editor.string == "half.md" && w.rows == ["a.md", "Untitled.md"])
            w.type(" done\r")
            #expect(await wait { w.rows == ["a.md", "half done.md", "log.txt"] }, "and shows it once the name is given")
            #expect(w.moved == [[made, folder["half done.md"]]] && w.selected == "half done.md" && w.window.firstResponder === w.outline)

            // Given up with Escape, the change shows as well.
            w.sidebar.rename(w.node("a.md")!)
            try folder.add("more.txt")
            await pause(1)
            #expect(w.rows == ["a.md", "half done.md", "log.txt"])
            w.type("\u{1B}")
            #expect(await wait { w.rows == ["a.md", "half done.md", "log.txt", "more.txt"] })
        }

        @Test func aLinkedFolderOpensInTheTreeAndItsFilesOpen() async throws {
            let folder = try TemporaryFolder(["dir/x.md", "a.md"])
            defer { folder.remove() }
            try FileManager.default.createSymbolicLink(atPath: folder["notes"].path, withDestinationPath: "dir")
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows == ["dir", "notes", "a.md"] })
            w.sidebar.activate(w.node("notes")!)
            #expect(await wait { w.rows == ["dir", "notes", "  x.md", "a.md"] })
            w.sidebar.activate(w.node("notes/x.md")!)
            #expect(w.opened.map(\.path) == [folder["notes"].path + "/x.md"])
            // The window's file is marked where it was chosen, although the document goes by its real path.
            w.select("notes/x.md")
            w.sidebar.currentURL = folder["dir/x.md"]
            #expect(w.selected == "x.md" && w.outline.selectedRow == 2 && w.cell("notes/x.md")?.textField?.font == theme.sidebarCurrentFont)
        }

        @Test func aFolderThatChangesWhileItIsListedIsListedOnceMoreAndNeverTwiceAtOnce() async throws {
            let folder = try TemporaryFolder(["a.md"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            w.sidebar.trasher = { try FileManager.default.removeItem(at: $0) }
            let root = try #require(w.sidebar.node(at: folder.url))
            #expect(root.isListing && !root.isOutdated)
            #expect(await wait { w.rows == ["a.md"] } && !root.isListing)

            // Asked for again while it is read, however often: one more reading, after this one.
            w.sidebar.load(root)
            #expect(root.isListing && !root.isOutdated)
            w.sidebar.load(root)
            w.sidebar.load(root)
            #expect(root.isListing && root.isOutdated)
            try folder.add("b.md")
            #expect(await wait { !root.isListing } && !root.isOutdated && w.rows == ["a.md", "b.md"])

            // A change made here while the folder is read: that reading may not know of it and is not shown.
            w.sidebar.load(root)
            w.sidebar.trash(folder["a.md"])
            #expect(root.isOutdated && w.rows == ["b.md"])
            #expect(await wait { !root.isListing } && w.rows == ["b.md"])

            // Files that come and go in quick succession leave the tree as the folder is.
            await pause(0.5)
            for index in 0..<20 {
                try folder.add("f\(index).md")
                if index % 2 == 0 { try FileManager.default.removeItem(at: folder["f\(index).md"]) }
                await pause(0.02)
            }
            let expected = ["b.md"] + (0..<20).filter { $0 % 2 == 1 }.map { "f\($0).md" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            #expect(await wait { w.rows == expected && !root.isListing })
        }

        @Test func movingToTheTrashTakesTheRowAway() async throws {
            let folder = try TemporaryFolder(["a.md", "docs/x.md"]), trash = try TemporaryFolder()
            defer { [folder, trash].forEach { $0.remove() } }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows.count == 2 })
            #expect(!w.sidebar.trash(folder["a.md"]) && w.rows.count == 2, "a failure leaves the row")
            w.window.attachedSheet.map(w.window.endSheet)

            w.sidebar.trasher = { try FileManager.default.moveItem(at: $0, to: trash[$0.lastPathComponent]) }
            #expect(w.sidebar.trash(folder["a.md"]) && w.rows == ["docs"])
            #expect(FileManager.default.fileExists(atPath: trash["a.md"].path))
            #expect(w.sidebar.trash(folder["docs/"]) && w.rows.isEmpty)
        }

        @Test func aFolderDroppedOnTheTextOrTheTreeIsOpenedAndNotInserted() async throws {
            let folder = try TemporaryFolder(["a.md", "sub/"])
            defer { folder.remove() }
            func drag(_ url: URL, to window: NSWindow) -> Drop {
                let pasteboard = NSPasteboard.withUniqueName()
                pasteboard.clearContents()
                pasteboard.writeObjects([url.absoluteURL as NSURL])
                return Drop(pasteboard: pasteboard, location: NSPoint(x: 60, y: 60), window: window)
            }
            var opened: [String] = []
            let e = EditorWindow("text\n")
            defer { e.close() }
            e.textView.folderOpener = { opened.append($0.path) }
            #expect(e.textView.performDragOperation(drag(folder["sub/"], to: e.window)))
            #expect(opened == [folder["sub/"].path] && e.textView.string == "text\n")

            let w = SidebarWindow(folder)
            defer { w.close() }
            w.sidebar.folderOpener = { opened.append($0.path) }
            #expect(await wait { w.rows.count == 2 })
            let onTree = drag(folder["sub/"], to: w.window), file = drag(folder["a.md"], to: w.window)
            #expect(w.sidebar.outlineView(w.outline, validateDrop: onTree, proposedItem: w.node("a.md"), proposedChildIndex: 0) == .generic)
            #expect(w.sidebar.outlineView(w.outline, acceptDrop: onTree, item: nil, childIndex: -1) && opened.count == 2)
            #expect(w.sidebar.outlineView(w.outline, validateDrop: file, proposedItem: nil, proposedChildIndex: 0) == [], "only folders")
            #expect(!w.sidebar.outlineView(w.outline, acceptDrop: file, item: nil, childIndex: -1) && opened.count == 2)
        }

        @Test func theContextMenuCopiesThePathAndThePathFromTheFolder() async throws {
            let folder = try TemporaryFolder(["a.md", "my docs/guide one.md"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows.count == 2 })
            w.sidebar.activate(w.node("my docs")!)
            #expect(await wait { w.rows.count == 3 })
            func copied(_ title: String, on path: String?) throws -> String? {
                let item = try #require(w.menu(on: path)?.item(withTitle: title))
                #expect(item.isEnabled)
                w.sidebar.pasteboard.clearContents()
                _ = item.target?.perform(item.action)
                #expect(w.sidebar.pasteboard.pasteboardItems?.map(\.types) == [[.string]], "plain text and nothing else")
                return w.sidebar.pasteboard.string(forType: .string)
            }
            #expect(try copied("Copy Path", on: "my docs/guide one.md") == folder["my docs/guide one.md"].path)
            #expect(try copied("Copy Relative Path", on: "my docs/guide one.md") == "my docs/guide one.md")
            #expect(try copied("Copy Path", on: "my docs") == folder.url.path + "/my docs")
            #expect(try copied("Copy Relative Path", on: "my docs") == "my docs")
            #expect(try copied("Copy Relative Path", on: "a.md") == "a.md")
            // The empty area below the rows is the folder itself.
            #expect(try copied("Copy Path", on: nil) == folder.url.path)
            #expect(try copied("Copy Relative Path", on: nil) == ".")
        }

        /// Every file and folder below `url` with what it holds.
        private func contents(of url: URL) -> [String: Data?] {
            let paths = FileManager.default.enumerator(atPath: url.path)?.compactMap { $0 as? String } ?? []
            return Dictionary(uniqueKeysWithValues: paths.map { ($0, FileManager.default.contents(atPath: url.appendingPathComponent($0).path)) })
        }

        @Test func aRowDraggedOutIsItsFileAndItsPathAndIsNeverMoved() async throws {
            let folder = try TemporaryFolder(["a file.md", "sub/x.txt"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows.count == 2 })
            let before = contents(of: folder.url)
            for (path, url) in [("a file.md", folder["a file.md"]), ("sub", folder["sub/"])] {
                let dragged = w.drag(path)
                defer { dragged.releaseGlobally() }
                // What a file dragged from the Finder is, and the tree's mark.
                // The file's URL, the list of file names that the pasteboard makes from it for
                // older code (a terminal's), and the path as a string.
                let names = NSPasteboard.PasteboardType("NSFilenamesPboardType")
                #expect(Set(dragged.types ?? []).isSuperset(of: [.fileURL, names, .string]), "\(dragged.types ?? [])")
                #expect(dragged.propertyList(forType: names) as? [String] == [url.path])
                #expect(dragged.pasteboardItems?.count == 1 && dragged.files.map(\.path) == [url.path])
                #expect(dragged.files.first?.hasDirectoryPath == url.hasDirectoryPath)
                #expect(dragged.string(forType: .fileURL) == url.absoluteString && dragged.string(forType: .string) == url.path, "the path as it is, not escaped")
                #expect(dragged.isFromTree)
            }
            // Inside the app a row is copied; other apps may also take it as a link or as "generic",
            // as some terminals do. Nothing can move it or put it in the Trash.
            // A session nobody began, only to ask; it is never let go, which the system would complain of.
            let source = w.outline as NSDraggingSource, session = Unmanaged.passRetained(NSDraggingSession()).takeUnretainedValue()
            let outside = source.draggingSession(session, sourceOperationMaskFor: .outsideApplication)
            #expect(outside == [.copy, .generic, .link] && outside.isDisjoint(with: [.move, .delete]))
            #expect(source.draggingSession(session, sourceOperationMaskFor: .withinApplication) == .copy)

            // Let go over its own tree, a folder's row does not become the tree's folder.
            var opened = 0
            w.sidebar.folderOpener = { _ in opened += 1 }
            let dragged = w.drag("sub")
            defer { dragged.releaseGlobally() }
            let drop = Drop(pasteboard: dragged, location: NSPoint(x: 60, y: 60), window: w.window)
            drop.draggingSource = w.outline
            #expect(w.sidebar.outlineView(w.outline, validateDrop: drop, proposedItem: nil, proposedChildIndex: 0) == [])
            #expect(!w.sidebar.outlineView(w.outline, acceptDrop: drop, item: nil, childIndex: -1) && opened == 0)
            #expect(contents(of: folder.url) == before && w.rows == ["sub", "a file.md"], "nothing on disk has changed")
        }

        @Test func aRowDroppedOnTheTextBecomesALinkFromTheDocumentInOneStep() async throws {
            let folder = try TemporaryFolder(["notes/doc.md", "my docs/guide one.md", "img/pic.png", "sub/"])
            defer { folder.remove() }
            let w = SidebarWindow(folder)
            defer { w.close() }
            #expect(await wait { w.rows.count == 4 })
            for name in ["my docs", "img", "notes"] { w.sidebar.activate(w.node(name)!) }
            #expect(await wait { w.rows.count == 7 })
            let before = contents(of: folder.url)

            let e = EditorWindow("text\n\nend\n", documentURL: folder["notes/doc.md"])
            defer { e.close() }
            var opened = 0
            e.textView.folderOpener = { _ in opened += 1 }
            e.textView.fileOpener = { _ in
                opened += 1
                return true
            }
            func drop(_ path: String) -> String {
                e.undoAll()
                e.select(5)
                let dragged = w.drag(path)
                defer { dragged.releaseGlobally() }
                let origin = e.textView.textContainerOrigin, line = e.fragment(at: 5).layoutFragmentFrame
                let drop = Drop(pasteboard: dragged, location: e.textView.convert(NSPoint(x: origin.x + 1, y: origin.y + line.midY), to: nil), window: e.window)
                drop.draggingSource = w.outline
                #expect(e.textView.draggingEntered(drop).contains(.copy))
                #expect(e.textView.prepareForDragOperation(drop) && e.textView.performDragOperation(drop))
                e.pump()
                return e.textView.string
            }
            #expect(drop("my docs/guide one.md") == "text\n[guide one](../my%20docs/guide%20one.md)\nend\n")
            #expect(drop("img/pic.png") == "text\n![pic](../img/pic.png)\nend\n", "an image file is an image")
            #expect(drop("sub") == "text\n[sub](../sub)\nend\n", "a folder is linked to, not opened")
            #expect(drop("notes/doc.md") == "text\n[doc](doc.md)\nend\n")
            #expect(opened == 0)
            e.textView.undoManager?.undo()
            #expect(e.textView.string == "text\n\nend\n" && e.textView.undoManager?.canUndo == false, "one step")
            #expect(contents(of: folder.url) == before)
        }

        @Test func withoutAFolderThereIsOnlyAPlaceholder() {
            let w = SidebarWindow(nil)
            defer { w.close() }
            let placeholder = w.sidebar.view.subviews.compactMap { $0 as? NSTextField }.first
            #expect(placeholder?.isHidden == false && placeholder?.stringValue.hasPrefix("No Folder\n") == true && w.rows.isEmpty)
        }

        @Test func aFolderWithNothingToListSaysSoAndStillTakesTheClicks() async throws {
            let folder = try TemporaryFolder([".hidden.md", "node_modules/x.md"])
            defer { folder.remove() }
            let w = SidebarWindow(folder), view = w.sidebar.view
            defer { w.close() }
            let placeholder = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
            #expect(placeholder.isHidden, "nothing is said before the folder has been read")
            #expect(await wait { !placeholder.isHidden })
            #expect(placeholder.stringValue == "No Files\nRight-click to add a file" && w.rows.isEmpty)
            view.layoutSubtreeIfNeeded()
            let theme = Theme.standard
            let box = placeholder.alignmentRect(forFrame: placeholder.frame)
            #expect(box.minX == theme.sidebarPlaceholderInset && box.maxX == view.bounds.maxX - theme.sidebarPlaceholderInset, "wrapped to the panel")
            let style = placeholder.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            #expect(abs(box.midY - view.bounds.midY) <= 0.5 && style?.alignment == .center)
            // The words are behind the tree: a right click on them reaches its menu.
            let hit = try #require(view.hitTest(NSPoint(x: placeholder.frame.midX, y: placeholder.frame.midY)))
            #expect(hit === w.outline || hit.isDescendant(of: w.outline))

            // The first file takes the words away, and the last one going brings them back.
            let root = try #require(w.sidebar.node(at: folder.url))
            let made = try #require(w.sidebar.create(in: root, isDirectory: false))
            #expect(placeholder.isHidden && w.rows == ["Untitled.md"])
            w.sidebar.trasher = { try FileManager.default.removeItem(at: $0) }
            w.sidebar.trash(made)
            #expect(!placeholder.isHidden && w.rows.isEmpty)
        }
    }
}
