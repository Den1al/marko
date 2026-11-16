import AppKit
import MarkoCore

public final class EditorTextView: NSTextView {
    /// A laid-out fragment near the top of the viewport and where it was, to hold it in place on screen.
    private var anchor: (offset: Int, y: CGFloat)?
    private var isOverOpenable = false
    /// Where the mouse went down, in view coordinates, while that click is placing the caret.
    var clickPoint: NSPoint?
    /// Asked first about every click, with the point in view coordinates; true means it used the click.
    var clickHandler: ((NSPoint, NSEvent.ModifierFlags) -> Bool)?
    /// Told where the mouse is, in view coordinates, or nil when it is not over the text; true means
    /// it is over something a click would open.
    var hoverHandler: ((NSPoint?, NSEvent.ModifierFlags) -> Bool)?
    /// Asked first about everything pasted or dropped; true means it made its own edit of it.
    var pasteHandler: ((NSPasteboard) -> Bool)?
    /// Runs a format command at the selection, or with `validate` only tells whether it applies
    /// there and whether the selection already has it.
    var formatCommandHandler: ((_ command: FormatCommand, _ validate: Bool) -> (isEnabled: Bool, isOn: Bool))?
    /// Asked first about typed text; true means it made its own edit of it.
    var typingHandler: ((String) -> Bool)?
    /// Runs a table command at the selection, or with `validate` only tells whether it applies there.
    var tableCommandHandler: ((_ command: TableCommand, _ validate: Bool) -> Bool)?
    /// Opens a folder that was dropped on the text.
    public var folderOpener: ((URL) -> Void)?
    /// Asked about a Markdown file that was dropped on the text; true means it opened the file,
    /// which is then not linked to.
    public var fileOpener: ((URL) -> Bool)?
    /// Called when the view's width, and with it the text column's, may have changed.
    var widthHandler: (() -> Void)?
    /// Called after every layout of the view: what is laid out for the window may be other text
    /// now. True when it had paragraphs of that text asked for again, which takes their layout away.
    var layoutHandler: (() -> Bool)?
    /// How often one layout of the view lays the text out again for what the handler asked for.
    static let layoutPassLimit = 4
    /// Called when an input method's composition has ended, committed or given up.
    var compositionEndHandler: (() -> Void)?

    /// Whether the text container is the whole page, from the padding at the window's left edge
    /// to that at its right, with the text column in its middle: the room for a table's grid
    /// that is wider than the column. The controller sets it once the text has a table, until
    /// another text is loaded. Before that the container is the column, and a window that only
    /// gets wider or narrower beside the column lays out no text again.
    /// MEASURED: 10.9 ms for every 20 points of such a resize before, with every line laid out
    /// and drawn again as it was.
    var runsOn = false {
        didSet { if runsOn != oldValue { setFrameSize(frame.size) } }
    }

    /// The width of the text column. The container is as wide, or wider where it runs on beside
    /// the column in a wide window.
    public var columnWidth: CGFloat { min(textContainer?.size.width ?? 0, Theme.standard.maximumTextWidth) }
    /// Where the text column starts in the view.
    public var columnLeft: CGFloat { textContainerInset.width + Theme.standard.columnOrigin(inContainer: textContainer?.size.width ?? 0) }

    /// The TextKit 2 objects are put together by hand, because the layout manager is one of the
    /// app's: it knows where the lines of a table's wrapping cells show (TableWrap.swift).
    public static func make() -> EditorTextView {
        let content = NSTextContentStorage(), layout = GridLayoutManager(), container = NSTextContainer(size: .zero)
        layout.textContainer = container
        content.addTextLayoutManager(layout)
        let view = EditorTextView(frame: .zero, textContainer: container)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.isGrammarCheckingEnabled = false
        // The window's title says which document; this says what the text area is.
        view.setAccessibilityLabel("Markdown text")
        view.applyTheme()
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // The view sizes the container itself: see setFrameSize.
        view.textContainer?.widthTracksTextView = false
        return view
    }

    /// Takes the base attributes of all text from the theme. They change with the zoom.
    func applyTheme() {
        let theme = Theme.standard
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = theme.bodyLineHeight
        style.maximumLineHeight = theme.bodyLineHeight
        defaultParagraphStyle = style
        font = theme.bodyFont
        textColor = theme.text
        backgroundColor = theme.background
        insertionPointColor = theme.accent
        selectedTextAttributes = [.backgroundColor: theme.selection]
        typingAttributes[.paragraphStyle] = style
        if let textStorage, textStorage.length > 0 {
            textStorage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: textStorage.length))
        }
        // The column is as wide as the theme says at this zoom.
        setFrameSize(frame.size)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if clickHandler?(point, event.modifierFlags) == true { return }
        clickPoint = point
        super.mouseDown(with: event)
        clickPoint = nil
    }

    // MARK: hovering

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.inVisibleRect) }) {
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(at: convert(event.locationInWindow, from: nil), event.modifierFlags)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isOverOpenable = hoverHandler?(nil, []) == true
    }

    /// Command pressed or released while the mouse rests on a link.
    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        hover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), event.modifierFlags)
    }

    private func hover(at point: NSPoint, _ modifiers: NSEvent.ModifierFlags) {
        let wasOpenable = isOverOpenable
        isOverOpenable = hoverHandler?(visibleRect.contains(point) ? point : nil, modifiers) == true
        if isOverOpenable {
            NSCursor.pointingHand.set()
        } else if wasOpenable {
            NSCursor.iBeam.set()
        }
    }

    // MARK: pasting and dropping

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL]
    }

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    /// Measured: without this the view in its window is registered for no drag at all.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDragTypeRegistration()
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        // What comes from a file tree is there to be linked to, a folder and a Markdown file too.
        if pasteboard.isFromTree { return super.performDragOperation(sender) }
        if let folderOpener, let folder = pasteboard.folders.first {
            folderOpener(folder)
            return true
        }
        if let fileOpener, let file = pasteboard.files.first(where: MarkdownFile.isMarkdown), fileOpener(file) { return true }
        return super.performDragOperation(sender)
    }

    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        pasteHandler?(pboard) == true || super.readSelection(from: pboard, type: type)
    }

    // MARK: format commands

    // Command-B belongs to the sidebar, as in a code editor.
    private static let formatItems: [(title: String, key: String, modifiers: NSEvent.ModifierFlags, command: FormatCommand)?] = [
        ("Bold", "b", [.command, .shift], .bold), ("Italic", "i", .command, .italic),
        ("Strikethrough", "x", [.command, .shift], .strikethrough), ("Inline Code", "c", [.command, .shift], .code),
        ("Link", "k", .command, .link), ("Image", "i", [.command, .shift], .image),
        nil,
    ] + (1...6).map { ("Heading \($0)", "\($0)", .command, .heading($0)) } + [
        ("Paragraph", "0", .command, .paragraph),
        ("Increase Heading Level", "=", [.command, .control], .increaseHeading),
        ("Decrease Heading Level", "-", [.command, .control], .decreaseHeading),
        nil,
        ("Bullet List", "u", [.command, .option], .bulletList), ("Ordered List", "o", [.command, .option], .orderedList),
        ("Task List", "x", [.command, .option], .taskList), ("Quote", "b", [.command, .option], .quote),
        ("Code Block", "c", [.command, .option], .codeBlock), ("Horizontal Rule", "-", [.command, .option], .rule),
        nil,
        ("Insert Table", "t", [.command, .option], .table),
    ]

    /// The Format menu. Each command item's tag is its place in `formatItems`.
    public static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        for (tag, entry) in formatItems.enumerated() {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = menu.addItem(withTitle: entry.title, action: #selector(performFormatCommand(_:)), keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = entry.modifiers
            item.tag = tag
        }
        menu.addItem(withTitle: "Table", action: nil, keyEquivalent: "").submenu = tableMenu()
        return menu
    }

    @objc public func performFormatCommand(_ sender: NSMenuItem) {
        guard let command = Self.formatItems[sender.tag]?.command else { return }
        _ = formatCommandHandler?(command, false)
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        // Text an input method commits replaces its marked text and is left alone.
        if let text = string as? String, !hasMarkedText(), typingHandler?(text) == true { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    // A composition that is given up ends here with nothing left of it, and without the
    // textDidChange that a commit sends.
    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if wasComposing, !hasMarkedText() { compositionEndHandler?() }
    }

    public override func unmarkText() {
        let wasComposing = hasMarkedText()
        super.unmarkText()
        if wasComposing { compositionEndHandler?() }
    }

    // MARK: table commands

    private static let tableCommands: [(title: String, command: TableCommand)] = [
        ("Insert Row Above", .insertRowAbove), ("Insert Row Below", .insertRowBelow),
        ("Insert Column Left", .insertColumnLeft), ("Insert Column Right", .insertColumnRight),
        ("Delete Row", .deleteRow), ("Delete Column", .deleteColumn),
        ("Align Left", .alignLeft), ("Align Center", .alignCenter), ("Align Right", .alignRight), ("No Alignment", .alignNone),
    ]

    /// The table commands as a menu, for the menu bar and for the context menu. Each item's tag is
    /// its command's place in `tableCommands`.
    public static func tableMenu() -> NSMenu {
        let menu = NSMenu(title: "Table")
        for (tag, entry) in tableCommands.enumerated() {
            if entry.command == .deleteRow || entry.command == .alignLeft { menu.addItem(.separator()) }
            menu.addItem(withTitle: entry.title, action: #selector(performTableCommand(_:)), keyEquivalent: "").tag = tag
        }
        return menu
    }

    @objc public func performTableCommand(_ sender: NSMenuItem) {
        _ = tableCommandHandler?(Self.tableCommands[sender.tag].command, false)
    }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(performTableCommand(_:)):
            return Self.tableCommands.indices.contains(item.tag) && tableCommandHandler?(Self.tableCommands[item.tag].command, true) == true
        case #selector(performFormatCommand(_:)):
            guard Self.formatItems.indices.contains(item.tag), let command = Self.formatItems[item.tag]?.command,
                  let state = formatCommandHandler?(command, true) else { return false }
            (item as? NSMenuItem)?.state = state.isOn ? .on : .off
            return state.isEnabled
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, TableCommand.allCases.contains(where: { tableCommandHandler?($0, true) == true }) else { return menu }
        let item = NSMenuItem(title: "Table", action: nil, keyEquivalent: "")
        item.submenu = Self.tableMenu()
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item, at: 0)
        return menu
    }

    /// The offset in the text that a click at `point`, in view coordinates, puts the caret at in a
    /// table row whose cells wrap; nil anywhere else.
    func wrappedOffset(at point: NSPoint) -> Int? {
        let origin = textContainerOrigin, target = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let (row, start) = (textLayoutManager as? GridLayoutManager)?.wrappedRow(at: target) else { return nil }
        return row.characterIndex(at: target, forInsertion: true).map { start + $0 }
    }

    /// The view's own lookup takes a paragraph's lines to stand below one another.
    public override func characterIndexForInsertion(at point: NSPoint) -> Int {
        wrappedOffset(at: point) ?? super.characterIndexForInsertion(at: point)
    }

    /// The page has more room below the text than above it.
    public override var textContainerOrigin: NSPoint {
        NSPoint(x: super.textContainerOrigin.x, y: Theme.standard.pagePadding.height)
    }

    public override func layout() {
        super.layout()
        // MEASURED: a paragraph that is asked for again after the layout has none any more, and
        // nothing lays it out before the frame is drawn: the view draws the paragraph it had,
        // without its text once that is released. The first letter typed into an empty document
        // was not there until the second, and rows that came into the window behind a nudge
        // showed as they were.
        var passes = 0
        while passes < Self.layoutPassLimit, layoutHandler?() == true {
            super.layout()
            passes += 1
        }
        captureAnchor()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        // Where the view is scrolled to now: a view that gets shorter may be scrolled back to fit.
        let oldHeight = frame.height, top = enclosingScrollView?.contentView.bounds.minY
        super.setFrameSize(newSize)
        let theme = Theme.standard
        // The text column stands in the middle of a view that is wider than the maximum text
        // width. The container is that column, or the whole page between the paddings, which is
        // room for a wide table; the paragraph styles then keep everything else in the column.
        let padding = theme.pagePadding.width
        let column = max(0, min(newSize.width - 2 * padding, theme.maximumTextWidth))
        let width = runsOn ? max(column, newSize.width - 2 * padding) : column
        let inset = ((newSize.width - width) / 2).rounded(.down)
        if textContainerInset.width != inset {
            // The inset is the same above and below the text; `textContainerOrigin` moves the text up in it.
            textContainerInset = NSSize(width: inset, height: (theme.pagePadding.height + theme.pageBottomPadding) / 2)
        }
        if let textContainer, textContainer.size.width != width {
            textContainer.size = NSSize(width: width, height: textContainer.size.height)
        }
        if newSize.height != oldHeight, let top { holdAnchor(scrolledTo: top) }
        widthHandler?()
    }

    /// MEASURED: NSTextView ends a live resize, which showing or hiding the sidebar is too, by
    /// scrolling the first character it showed to the very top of the clip view, under the
    /// titlebar and without the page's padding. The anchor has held the text in place all along.
    public override func viewDidEndLiveResize() {
        let clipView = enclosingScrollView?.contentView, bounds = clipView?.bounds
        super.viewDidEndLiveResize()
        guard let clipView, let bounds, clipView.bounds.origin != bounds.origin else { return }
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    // MARK: scroll anchoring
    //
    // TextKit 2 replaces estimated heights above the viewport with real ones as it scrolls up, which
    // moves everything below, including what is on screen. One laid-out fragment is kept fixed instead.

    /// The paragraph that was at the top of the window when the text was last laid out, by its
    /// place in the text, and how far the window is scrolled past that paragraph's top.
    var topParagraph: (offset: Int, past: CGFloat)? {
        guard let anchor, let clipView = enclosingScrollView?.contentView else { return nil }
        return (anchor.offset, clipView.bounds.minY - textContainerOrigin.y - anchor.y)
    }

    private func captureAnchor() {
        guard let textLayoutManager, let textContentStorage,
              let fragment = textLayoutManager.textLayoutFragment(
                for: CGPoint(x: 1, y: visibleRect.minY - textContainerOrigin.y + 1)) else { return }
        let offset = textContentStorage.offset(from: textContentStorage.documentRange.location, to: fragment.rangeInElement.location)
        anchor = (offset, fragment.layoutFragmentFrame.minY)
    }

    /// `top` is where the view was scrolled to before its height changed.
    private func holdAnchor(scrolledTo top: CGFloat) {
        guard let anchor, let clipView = enclosingScrollView?.contentView, let textLayoutManager, let textContentStorage,
              let location = textContentStorage.location(textContentStorage.documentRange.location, offsetBy: anchor.offset),
              let frame = textLayoutManager.textLayoutFragment(for: location)?.layoutFragmentFrame else { return }
        let delta = frame.minY - anchor.y
        // A zero frame means the anchor's layout was just discarded; there is nothing to measure against.
        // isEmpty would be wrong here: a blank line's fragment has no width.
        guard frame != .zero, abs(delta) > 0.5, abs(anchor.y - top) < 2 * clipView.bounds.height else { return }
        self.anchor = (anchor.offset, frame.minY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: top + delta))
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }
}
