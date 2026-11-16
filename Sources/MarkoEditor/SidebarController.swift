import AppKit
import UniformTypeIdentifiers

/// The file tree beside the editor. It lists a folder as it is opened, one level at a time and off
/// the main thread, follows the disk, and does the file commands of its context menu. What a
/// chosen file does to the window's document is the app's business, through the closures.
public final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    final class Node {
        let entry: FileEntry
        /// nil until the folder has been listed.
        var children: [Node]?
        /// While a listing is on the way. There is never more than one, so none can overtake another.
        var isListing = false
        /// The folder changed, on disk or here, while it was being listed: it is listed once more.
        var isOutdated = false

        init(_ entry: FileEntry) { self.entry = entry }
    }

    public let outlineView: NSOutlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    /// The folder's name, beside the window buttons.
    let header = NSTextField(labelWithString: "")
    private var root: Node?
    private var watcher: FolderWatcher?
    /// The folders that are open, by path. The outline's own state does not survive a reload.
    private var expanded: Set<String> = []
    /// While the outline is rebuilt: what it expands and collapses then is not the user's doing.
    private var isReloading = false
    /// The file to select once the folders above it are listed.
    private var pendingReveal: URL?
    /// The new item whose name is to be edited once its row is there.
    private var pendingRename: URL?
    /// While a name is being edited, and the folders that changed on disk meanwhile: reloading
    /// their rows would end the editing, so they are listed again when it is over.
    private var isRenaming = false
    private var changedWhileRenaming: [Node] = []

    /// A Markdown file was chosen. `focus` says whether the editor should take the keyboard.
    public var opener: (_ url: URL, _ focus: Bool) -> Void = { _, _ in }
    /// A folder was dropped on the tree.
    public var folderOpener: (URL) -> Void = { _ in }
    /// Escape: the keyboard goes back to the text.
    public var leaver: () -> Void = {}
    /// A file that is not Markdown, double-clicked, opens in the app the system has for its
    /// type if it is of a kind that is only shown there (`FileTree.typeOpenedInItsApp`), and is
    /// shown in the Finder if not. The app is named here: left to choose, the system would take
    /// the one the file asks for.
    public var externalOpener: (_ file: URL, _ app: URL) -> Void = {
        NSWorkspace.shared.open([$0], withApplicationAt: $1, configuration: NSWorkspace.OpenConfiguration())
    }
    public var revealer: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// The file or folder at the first URL is now at the second; open documents follow.
    public var mover: (_ from: URL, _ to: URL) -> Void = { _, _ in }
    /// "Move to Trash" was chosen. The app saves the documents in question, calls `trash(_:)` and closes them.
    public lazy var trashHandler: (URL) -> Void = { [weak self] in _ = self?.trash($0) }
    /// Puts an item in the Trash. Tests put it somewhere of their own.
    public var trasher: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// Where "Copy Path" puts the path. Tests give it one of their own.
    public var pasteboard = NSPasteboard.general

    /// The folder the tree shows. Nothing is read and nothing is watched before this is set.
    public var rootURL: URL? {
        didSet {
            guard rootURL?.path != oldValue?.path else { return }
            root = rootURL.map { Node(FileEntry(url: URL(fileURLWithPath: $0.path, isDirectory: true), isDirectory: true)) }
            expanded = []
            watcher = root.map { root in
                FolderWatcher(root: root.entry.url) { [weak self] in self?.foldersChanged($0) }
            }
            header.stringValue = rootURL?.lastPathComponent ?? ""
            if isViewLoaded {
                updatePlaceholder()
                outlineView.reloadData()
            }
            if let root { load(root) }
            reveal(currentURL)
        }
    }

    /// The file the editor shows: selected, with the folders above it open.
    public var currentURL: URL? {
        didSet {
            guard currentURL?.path != oldValue?.path else { return }
            // The rows are restyled as they are: reloading one would end the editing of its name.
            if isViewLoaded {
                outlineView.enumerateAvailableRowViews { [self] view, row in
                    guard let node = outlineView.item(atRow: row) as? Node else { return }
                    (view.view(atColumn: 0) as? NSTableCellView)?.textField?.font = font(for: node.entry)
                }
            }
            reveal(currentURL)
        }
    }

    // MARK: view

    public override func loadView() {
        let theme = Theme.standard
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowHeight = theme.sidebarRowHeight
        outlineView.indentationPerLevel = theme.sidebarIndent
        outlineView.autoresizesOutlineColumn = false
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked)
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.registerForDraggedTypes([.fileURL])
        // A row dragged out is copied, linked to or named where it lands, and never moved or
        // deleted. Other apps are offered what they may ask of a file from the Finder short of
        // that: some take a drop only as "generic" (a terminal that types the path) or as a link.
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy, .generic, .link], forLocal: false)
        outlineView.setAccessibilityLabel("Files")
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        updatePlaceholder()

        view = NSView(frame: NSRect(x: 0, y: 0, width: theme.sidebarWidth, height: theme.windowSize.height))
        scrollView.frame = view.bounds
        // Behind the empty tree, which still takes the clicks: its menu is how a file gets there.
        view.addSubview(placeholder)
        view.addSubview(scrollView)
        header.font = theme.sidebarHeaderFont
        header.textColor = theme.sidebarHeaderText
        header.lineBreakMode = .byTruncatingMiddle
        header.allowsExpansionToolTips = true
        view.addSubview(header)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: theme.sidebarPlaceholderInset),
            placeholder.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -theme.sidebarPlaceholderInset),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        outlineView.reloadData()
        restoreExpansion(under: root)
        reveal(currentURL)
    }

    /// The folder's name goes beside the window buttons, which the tree's panel holds. Their place
    /// is read from the titlebar alone, which runs along the window's top edge. In full screen
    /// the titlebar is not in the window (it comes with the menu bar, see the window's
    /// presentation options): the tree starts at the top and the name is not shown. MEASURED:
    /// placed by the buttons all the same, it stood in the tree's first row.
    public override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window, let button = window.standardWindowButton(.zoomButton), let titlebar = button.superview else { return }
        header.isHidden = window.styleMask.contains(.fullScreen)
        let theme = Theme.standard, height = header.intrinsicContentSize.height
        let below = titlebar.isFlipped ? button.frame.midY : titlebar.bounds.maxY - button.frame.midY
        let place = view.convert(NSPoint(x: button.frame.maxX, y: window.frame.height - below), from: nil), left = place.x + theme.sidebarHeaderGap
        header.frame = NSRect(x: left, y: place.y - height / 2, width: max(view.bounds.maxX - theme.sidebarHeaderGap - left, 0), height: height)
    }

    /// Says why there is no tree: there is no folder, or nothing in it that the tree lists.
    private func updatePlaceholder() {
        let lines = root == nil ? ("No Folder", "Save the document to browse its folder")
            : root?.children?.isEmpty == true ? ("No Files", "Right-click to add a file") : nil
        placeholder.isHidden = lines == nil
        guard let lines else { return }
        let theme = Theme.standard, style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSMutableAttributedString(string: lines.0 + "\n", attributes: [
            .font: theme.sidebarPlaceholderFont, .foregroundColor: theme.sidebarPlaceholderText, .paragraphStyle: style,
        ])
        text.append(NSAttributedString(string: lines.1, attributes: [
            .font: theme.sidebarHintFont, .foregroundColor: theme.sidebarHintText, .paragraphStyle: style,
        ]))
        placeholder.attributedStringValue = text
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node ?? root)?.children?.count ?? 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node ?? root)!.children![index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let entry = (item as? Node)?.entry else { return false }
        return entry.isDirectory && !entry.isLocked
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let theme = Theme.standard, identifier = NSUserInterfaceItemIdentifier("row")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell ?? Self.makeCell(identifier)
        let entry = node.entry
        cell.imageView?.image = entry.isLocked ? Self.symbols.locked
            : entry.isDirectory ? Self.symbols.folder : entry.isMarkdown ? Self.symbols.markdown : Self.symbols.file
        cell.imageView?.contentTintColor = entry.isDirectory ? theme.sidebarFolderTint : entry.isMarkdown ? theme.accent : theme.sidebarOtherText
        cell.textField?.stringValue = entry.name
        cell.nameColor = (entry.isDirectory && !entry.isLocked) || entry.isMarkdown ? theme.sidebarMarkdownText : theme.sidebarOtherText
        // A folder that would open on nothing says why it does not open.
        cell.toolTip = entry.isLocked ? "You do not have permission to see what is in this folder." : nil
        cell.textField?.font = font(for: entry)
        cell.textField?.delegate = self
        return cell
    }

    /// The rows' symbols, shared by all rows. MEASURED: with one made for every row shown, a
    /// frame of scrolling a long tree took 13.6 ms instead of 6.2.
    private static let symbols: (folder: NSImage?, markdown: NSImage?, file: NSImage?, locked: NSImage?) = {
        let names = Theme.standard.sidebarSymbols
        func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        return (symbol(names.folder), symbol(names.markdown), symbol(names.file), symbol(names.locked))
    }()

    /// The file the editor shows is marked, and so is a link to it.
    private func font(for entry: FileEntry) -> NSFont {
        entry.filePath == currentURL?.path ? Theme.standard.sidebarCurrentFont : Theme.standard.sidebarFont
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> SidebarCell {
        let theme = Theme.standard
        let cell = SidebarCell(), image = NSImageView(), field = NSTextField(labelWithString: "")
        cell.identifier = identifier
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: theme.sidebarSymbolSize, weight: .regular)
        // The row is its name: the symbol's own description ("move" for a folder) would be read out with it.
        image.cell?.setAccessibilityElement(false)
        field.lineBreakMode = .byTruncatingMiddle
        // A name that is cut short shows whole under the pointer.
        field.allowsExpansionToolTips = true
        for subview in [image, field] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(subview)
        }
        cell.imageView = image
        cell.textField = field
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            image.widthAnchor.constraint(equalToConstant: theme.sidebarSymbolWidth),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: theme.sidebarSymbolGap),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: listing

    /// Lists a folder off the main thread and shows the result when it arrives. Asked for while
    /// the folder is being listed, it is listed again after that, once however often it was asked.
    func load(_ node: Node) {
        guard !node.isListing else {
            node.isOutdated = true
            return
        }
        node.isListing = true
        node.isOutdated = false
        let url = node.entry.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = FileTree.contents(of: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    node.isListing = false
                    if node.isOutdated { self?.load(node) } else { self?.show(entries, in: node) }
                }
            }
        }
    }

    /// Nodes of entries that are still there are kept, and with them what is listed below them.
    private func show(_ entries: [FileEntry], in node: Node) {
        // The folder may have left the tree while it was read.
        guard node === root || self.node(at: node.entry.url) === node else { return }
        if entries != node.children?.map(\.entry) {
            guard !isRenaming else { return changedWhileRenaming.append(node) }
            let known = Dictionary((node.children ?? []).map { ($0.entry, $0) }) { first, _ in first }
            setChildren(entries.map { known[$0] ?? Node($0) }, of: node)
        }
        continueReveal()
        continueRename()
    }

    private func setChildren(_ children: [Node], of node: Node) {
        // A listing on its way was read before this change and may not know of it.
        if node.isListing { node.isOutdated = true }
        node.children = children
        guard isViewLoaded else { return }
        if node === root { updatePlaceholder() }
        let selected = outlineView.item(atRow: outlineView.selectedRow) as? Node
        isReloading = true
        outlineView.reloadItem(node === root ? nil : node, reloadChildren: true)
        restoreExpansion(under: node)
        isReloading = false
        select(selected.flatMap { self.node(at: $0.entry.url) })
    }

    private func restoreExpansion(under node: Node?) {
        for child in node?.children ?? [] where child.entry.isDirectory && expanded.contains(child.entry.url.path) {
            expand(child)
        }
    }

    /// Opens a folder's row, lists the folder if that has not been done, and opens what was open in it.
    private func expand(_ node: Node) {
        expanded.insert(node.entry.url.path)
        let wasReloading = isReloading
        isReloading = true
        outlineView.expandItem(node)
        isReloading = wasReloading
        if node.children != nil { restoreExpansion(under: node) } else if !node.isListing { load(node) }
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading, let node = notification.userInfo?["NSObject"] as? Node else { return }
        expand(node)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading, let node = notification.userInfo?["NSObject"] as? Node else { return }
        expanded.remove(node.entry.url.path)
    }

    private func foldersChanged(_ folders: [URL]?) {
        guard let root else { return }
        if let folders {
            for folder in folders {
                if let node = node(at: folder), node.children != nil { load(node) }
            }
        } else {
            var listed = [root]
            while let node = listed.popLast() {
                guard let children = node.children else { continue }
                load(node)
                listed += children
            }
        }
    }

    /// The node for a file or folder, when the folders above it have been listed.
    func node(at url: URL) -> Node? {
        guard let root, let names = names(below: root, to: url) else { return nil }
        return names.reduce(root as Node?) { node, name in node?.children?.first { $0.entry.name == name } }
    }

    /// The names that lead from a folder's node down to `url`; nil when it is not in that folder.
    private func names(below node: Node, to url: URL) -> [String]? {
        let folder = node.entry.url.pathComponents, path = url.pathComponents
        return path.starts(with: folder) ? Array(path.dropFirst(folder.count)) : nil
    }

    // MARK: selection

    private func select(_ node: Node?) {
        let row = node.map(outlineView.row(forItem:)) ?? -1
        outlineView.selectRowIndexes(row >= 0 ? [row] : [], byExtendingSelection: false)
    }

    private func reveal(_ url: URL?) {
        pendingReveal = url
        continueReveal()
    }

    /// Opens the folders above the file to reveal, as far as they are listed; each listing that
    /// arrives carries on from here.
    private func continueReveal() {
        guard isViewLoaded, let url = pendingReveal, var node = root else { return }
        // A link to the file was chosen: the selection stays on it.
        if (outlineView.item(atRow: outlineView.selectedRow) as? Node)?.entry.filePath == url.path {
            pendingReveal = nil
            return
        }
        guard let names = names(below: node, to: url) else {
            pendingReveal = nil
            return
        }
        for name in names {
            if node !== root { expand(node) }
            guard let children = node.children else { return }
            guard let next = children.first(where: { $0.entry.name == name }) else {
                pendingReveal = nil
                return
            }
            node = next
        }
        pendingReveal = nil
        select(node)
        outlineView.scrollRowToVisible(outlineView.selectedRow)
    }

    private var clickedNode: Node? {
        outlineView.item(atRow: outlineView.clickedRow) as? Node
    }

    @objc private func clicked() {
        if let node = clickedNode { activate(node) }
    }

    @objc private func doubleClicked() {
        if let node = clickedNode { openExternally(node) }
    }

    /// A double click: a file the editor has no use for opens in the app the system has for it,
    /// or is shown in the Finder when opening it could run something.
    func openExternally(_ node: Node) {
        guard !node.entry.isDirectory, !node.entry.isMarkdown else { return }
        // Judged and opened as the file it is, not as the link that leads to it.
        let file = URL(fileURLWithPath: node.entry.filePath)
        if let app = FileTree.typeOpenedInItsApp(file).flatMap({ NSWorkspace.shared.urlForApplication(toOpen: $0) }) {
            externalOpener(file, app)
        } else {
            revealer(node.entry.url)
        }
    }

    /// Return on the selected row.
    func openSelection() {
        if let node = outlineView.item(atRow: outlineView.selectedRow) as? Node { activate(node) }
    }

    /// A click or Return: a folder opens or closes, a Markdown file goes to the editor, and any
    /// other file stays where it is.
    func activate(_ node: Node) {
        if node.entry.isDirectory {
            if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) } else { expand(node) }
        } else if node.entry.isMarkdown {
            opener(node.entry.url, true)
        }
    }

    // MARK: dragging a row out, dropping a folder

    /// A row is its file for the Finder and for a terminal, which types the path, its path for
    /// whatever takes only text, and a link for an editor of this app: what a file dragged
    /// from the Finder is (its URL and a string; the list of file names that older code reads,
    /// NSFilenamesPboardType, the pasteboard makes from the URL itself), and the tree's mark.
    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let url = (item as? Node)?.entry.url else { return nil }
        let written = NSPasteboardItem()
        written.setString(url.absoluteString, forType: .fileURL)
        written.setString(url.path, forType: .string)
        written.setString(url.path, forType: .treeItem)
        return written
    }

    /// A folder from elsewhere; one of this tree's own rows let go over the tree does nothing.
    private func droppedFolder(_ info: NSDraggingInfo) -> URL? {
        info.draggingSource as? NSOutlineView === outlineView ? nil : info.draggingPasteboard.folders.first
    }

    public func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard droppedFolder(info) != nil else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .generic
    }

    public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = droppedFolder(info) else { return false }
        folderOpener(folder)
        return true
    }

    // MARK: file commands

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard root != nil else { return }
        let hasItem = clickedNode != nil
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
        }
        menu.autoenablesItems = false
        add("New File", #selector(newFile))
        add("New Folder", #selector(newFolder))
        menu.addItem(.separator())
        add("Rename", #selector(renameClicked), enabled: hasItem)
        add("Move to Trash", #selector(trashClicked), enabled: hasItem)
        menu.addItem(.separator())
        add("Copy Path", #selector(copyPath))
        add("Copy Relative Path", #selector(copyRelativePath))
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(revealClicked))
        for item in menu.items where item.action == nil && !item.isSeparatorItem { item.isEnabled = false }
    }

    /// Where a new item goes: into the clicked folder, beside the clicked file, or into the root.
    private var clickedFolder: Node? {
        guard let node = clickedNode else { return root }
        return node.entry.isDirectory ? node : outlineView.parent(forItem: node) as? Node ?? root
    }

    @objc private func newFile() {
        guard let folder = clickedFolder else { return }
        create(in: folder, isDirectory: false)
    }

    @objc private func newFolder() {
        guard let folder = clickedFolder else { return }
        create(in: folder, isDirectory: true)
    }

    /// Makes "Untitled.md" or "Untitled Folder" in a folder and starts renaming it; a file also
    /// opens in the editor, which leaves the keyboard with the name.
    @discardableResult
    func create(in folder: Node, isDirectory: Bool) -> URL? {
        let url = FileTree.unusedName(isDirectory ? "Untitled Folder" : "Untitled", extension: isDirectory ? nil : "md", in: folder.entry.url)
        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            present(error)
            return nil
        }
        let node = Node(FileEntry(url: url, isDirectory: isDirectory))
        if folder !== root { expand(folder) }
        // A folder that has not been listed yet shows the new item, and edits its name, when its listing arrives.
        if let children = folder.children {
            setChildren((children + [node]).sorted { FileTree.precedes($0.entry, $1.entry) }, of: folder)
        }
        if !isDirectory { opener(url, false) }
        rename(at: url)
        return url
    }

    /// Starts editing the name of a file or folder in the tree, once its row is there.
    public func rename(at url: URL) {
        pendingRename = url
        continueRename()
    }

    private func continueRename() {
        guard let node = pendingRename.flatMap(node(at:)) else { return }
        pendingRename = nil
        rename(node)
    }

    @objc private func renameClicked() {
        if let node = clickedNode { rename(node) }
    }

    /// Makes the row's name editable, with the part before the extension selected.
    func rename(_ node: Node) {
        let row = outlineView.row(forItem: node)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell,
              let field = cell.textField else { return }
        select(node)
        outlineView.scrollRowToVisible(row)
        field.isEditable = true
        cell.colourName()
        guard view.window?.makeFirstResponder(field) == true else { return endRename(in: field) }
        isRenaming = true
        let stem = (node.entry.name as NSString).deletingPathExtension as NSString
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: node.entry.isDirectory ? (node.entry.name as NSString).length : stem.length)
    }

    /// Return renames and Escape gives up; either way the keyboard is back in the tree.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let isReturn = selector == #selector(insertNewline(_:))
        guard isReturn || selector == #selector(cancelOperation(_:)), let field = control as? NSTextField else { return false }
        let name = textView.string, node = outlineView.item(atRow: outlineView.row(for: field)) as? Node
        field.abortEditing()
        endRename(in: field)
        view.window?.makeFirstResponder(outlineView)
        if isReturn, let node { rename(node, to: name) }
        return true
    }

    /// The keyboard went elsewhere while a name was edited: the name stays as it was.
    public func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { endRename(in: field) }
    }

    private func endRename(in field: NSTextField) {
        field.isEditable = false
        (field.superview as? SidebarCell)?.colourName()
        if let node = outlineView.item(atRow: outlineView.row(for: field)) as? Node { field.stringValue = node.entry.name }
        isRenaming = false
        let changed = changedWhileRenaming
        changedWhileRenaming = []
        changed.forEach(load)
    }

    /// Renames the node's file or folder; open documents follow through `mover`. A name the tree
    /// does not list is refused like an empty one: the row would be gone.
    func rename(_ node: Node, to name: String) {
        let old = node.entry.url, name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node.entry.name, !name.contains("/"), !FileTree.isExcluded(name),
              let parent = outlineView.parent(forItem: node) as? Node ?? root else { return }
        let new = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: node.entry.isDirectory)
        do {
            try FileManager.default.moveItem(at: old, to: new)
        } catch {
            present(error)
            return
        }
        // The folders that were open below the old name are below the new one.
        expanded = Set(expanded.map { FileTree.path($0, movedFrom: old, to: new) ?? $0 })
        let renamed = Node(FileEntry(url: new, isDirectory: node.entry.isDirectory))
        setChildren(
            (parent.children ?? []).map { $0 === node ? renamed : $0 }.sorted { FileTree.precedes($0.entry, $1.entry) }, of: parent)
        select(renamed)
        mover(old, new)
    }

    @objc private func trashClicked() {
        if let url = clickedNode?.entry.url { trashHandler(url) }
    }

    /// Moves a file or folder to the Trash and takes it out of the tree. False when that failed.
    @discardableResult
    public func trash(_ url: URL) -> Bool {
        do {
            try trasher(url)
        } catch {
            present(error)
            return false
        }
        if let node = node(at: url), let parent = outlineView.parent(forItem: node) as? Node ?? root {
            setChildren((parent.children ?? []).filter { $0 !== node }, of: parent)
        }
        return true
    }

    @objc private func revealClicked() {
        if let url = (clickedNode ?? root)?.entry.url { revealer(url) }
    }

    @objc private func copyPath() {
        if let url = (clickedNode ?? root)?.entry.url { copy(url.path) }
    }

    /// The path from the tree's folder, which is "." itself.
    @objc private func copyRelativePath() {
        guard let root, let names = names(below: root, to: (clickedNode ?? root).entry.url) else { return }
        copy(names.isEmpty ? "." : names.joined(separator: "/"))
    }

    private func copy(_ path: String) {
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    private func present(_ error: Error) {
        guard let window = view.window else { return }
        presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
    }
}

/// A row's symbol and name. The name is white on the highlight of the row that has the keyboard
/// and keeps its own colour everywhere else, also while it is edited, on the field's own background.
final class SidebarCell: NSTableCellView {
    var nameColor = Theme.standard.sidebarMarkdownText {
        didSet { colourName() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { colourName() }
    }

    func colourName() {
        let isHighlighted = backgroundStyle == .emphasized && textField?.isEditable != true
        textField?.textColor = isHighlighted ? Theme.standard.sidebarHighlightedText : nameColor
    }
}

/// Return opens the selected row and Escape gives the keyboard back, which a table view has no notion of.
private final class SidebarOutlineView: NSOutlineView {
    override func keyDown(with event: NSEvent) {
        guard let sidebar = delegate as? SidebarController else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: sidebar.openSelection()
        case 53: sidebar.leaver()
        default: super.keyDown(with: event)
        }
    }
}

extension NSPasteboard {
    /// The files and folders on the pasteboard, as a drag from the Finder carries them.
    var files: [URL] {
        readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    var folders: [URL] { files.filter(\.hasDirectoryPath) }

    /// Whether this is a row dragged out of a file tree of this app.
    var isFromTree: Bool { availableType(from: [.treeItem]) != nil }
}

extension NSPasteboard.PasteboardType {
    /// Marks a row of a file tree, so that an editor links to what it would otherwise open.
    static let treeItem = NSPasteboard.PasteboardType("local.marko.tree-item")
}
