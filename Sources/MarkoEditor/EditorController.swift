import AppKit
import MarkoCore
import UniformTypeIdentifiers

public final class EditorController: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    /// The editor's whole view: the scrolling text with the word count over its corner.
    public let view = NSView()
    public let textView = EditorTextView.make()
    public let scrollView = NSScrollView()

    /// UTF-16 length up to which an edit that needs a parse of the whole text gets it at once;
    /// longer documents wait for a pause in typing then. Most edits need none: `MarkdownStyler.restyle`.
    static let synchronousParseLimit = 100_000
    /// In a longer document than that, the UTF-16 length up to which the blocks around an edit are
    /// parsed by themselves; a longer part (one list, fence or paragraph of that size) waits for
    /// the pause like an edit that needs the whole text. MEASURED: a list of 24,000 units (980
    /// items) is 10 ms of every key in it, 12 ms to the frame; mixed text costs half of that. Up
    /// to `synchronousParseLimit` a part is never refused: the whole text would cost more.
    static let partParseLimit = 25_000
    static let parseDelay: TimeInterval = 0.25
    /// How long the text is left alone before its words are counted.
    static let wordCountDelay: TimeInterval = 0.3
    /// How many windows' worth of text `scrollToSelection` goes through to reach a selection
    /// that TextKit's guesses of heights did not lead it to.
    static let scrollStepLimit = 200
    /// How many reveal changes are nudged one by one.
    static let separateNudgeLimit = 200

    /// The document's file, which relative image and link paths start from; nil until it is saved.
    public var documentURL: URL? {
        didSet {
            renderer.images.documentURL = documentURL
            // What was chosen for a document without a file goes with it to the file it is saved in.
            if let documentURL, let choice = choiceWithoutFile {
                choiceWithoutFile = nil
                TrustStore.shared.setAllowsRemoteImages(choice, for: documentURL)
            }
            trustDidChange()
            nudge(renderer.pictureRanges())
        }
    }
    /// Whether this document fetches the images it links to from the web. It does when its folder
    /// is trusted; setting this is the user's choice for this one document, until the app quits.
    /// `TrustStore` holds both; only a document without a file keeps the choice here.
    public var loadsRemoteImages: Bool {
        get { renderer.images.allowsRemote }
        set {
            if let documentURL { TrustStore.shared.setAllowsRemoteImages(newValue, for: documentURL) } else { choiceWithoutFile = newValue }
            trustDidChange()
        }
    }
    private var choiceWithoutFile: Bool?
    /// Whether the document is in safe mode, which its mark shows: it is not in a trusted folder,
    /// or is kept from loading in one.
    public var isInSafeMode: Bool { !safeMode.isHidden }

    /// Asks the store again what this document may fetch. Images that may no longer be fetched
    /// are let go of, also half fetched, and show as blocked; those that now may be are fetched.
    @objc private func trustDidChange() {
        let store = TrustStore.shared
        let loads = documentURL.map { store.allowsRemoteImages(for: $0) } ?? choiceWithoutFile ?? false
        let isTrusted = loads && documentURL.map(store.isTrusted) == true
        if safeMode.isHidden != isTrusted {
            safeMode.isHidden = isTrusted
            placeStatus()
        }
        safeMode.toolTip = loads ? "Safe mode. The images this document links to on the web are loaded until Marko quits."
            : "Safe mode. Images on the web are not loaded: click one, or choose View > Load Remote Images. File > Trust This Folder ends safe mode for the folder."
        safeMode.setAccessibilityHelp(safeMode.toolTip)
        guard loads != renderer.images.allowsRemote else { return }
        renderer.images.allowsRemote = loads
        nudge(renderer.pictureRanges())
    }
    /// Whether the document has changes that are not saved, which the title shows. A window whose
    /// document saves itself does not know.
    public var isEdited: Bool {
        get { titlebar.isEdited }
        set { titlebar.isEdited = newValue }
    }
    /// Opens what a Command-clicked link points at when that is a web or mail address or a Markdown file.
    public var linkOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Shows any other linked file in the Finder. It is never opened: it could be a program, and a
    /// document from somewhere else must not be able to run one with a click.
    public var fileRevealer: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    private let renderer = ParagraphRenderer()
    /// Whether the pixels of a picture are still being made.
    public var isDecodingImages: Bool { renderer.images.isDecoding }
    let wordCount = NSTextField(labelWithString: "")
    /// The mark of safe mode, in front of the word count; it shows whether or not the count does.
    let safeMode = NSImageView()
    private let status = Capsule()
    let footer = Footer()
    let titlebar = Titlebar()
    /// The lines of the map whose styles changed in parses that textDidChange or undo has not yet turned into a nudge.
    private var changedLines: Range<Int>?
    /// The text that edits have made since the map was last up to date with it.
    private var unparsed: NSRange?
    /// The edit that was last asked about (`shouldChangeTextIn`): what it replaces with what, how
    /// long the text is before it, and how the table that it starts in shows then; see `didParse`.
    private var asked: (range: NSRange, replacement: String?, length: Int, look: TableLook?)?
    /// The text that undo or redo has put back and `didUndoOrRedo` has not looked at yet.
    private var restored: NSRange?
    /// What the reveal selection currently reveals; see ParagraphRenderer.revealedRanges.
    private var revealed: Set<NSRange> = []
    private var isLoading = false
    /// While `perform` makes its edit.
    private var isPerforming = false
    /// The x that Up and Down keep to, and the selection the last of them left; see `moveVertically`.
    private var keptColumn: (x: CGFloat, selection: NSRange)?
    /// The selection, while its start is the end that the keys move. MEASURED: the text view's
    /// selection affinity does not tell (it follows the last move's direction).
    private var movingStart: NSRange?
    /// What the text view's next move selects instead of where it goes itself; see `select(head:anchor:)`.
    private var destination: NSRange?
    private var parseTimer: Timer?
    private var wordCountTimer: Timer?
    /// How many counts have been started; a count that is not the latest is dropped.
    private var wordCounts = 0
    /// A parse made ahead for the text that is loaded next; see `Preparse`.
    public var preparse: Preparse?

    /// MEASURED: what a TextKit 2 text view leaves behind when it goes (a stock one too): its text
    /// storage and layout manager keep each other alive, and with them the views of the
    /// paragraphs that were on screen. A window that had shown 300 files held 300 texts and 3,300
    /// paragraph views, about 0.4 MB per file. Taken apart here, in this order, all of it goes;
    /// the other way round the paragraph views stay.
    isolated deinit {
        for container in textView.subviews { container.subviews.forEach { $0.removeFromSuperview() } }
        if let layout = textView.textLayoutManager { textView.textContentStorage?.removeTextLayoutManager(layout) }
    }

    public override init() {
        super.init()
        let theme = Theme.standard
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        scrollView.documentView = textView
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.width, .height]
        view.addSubview(scrollView)

        wordCount.font = theme.statusFont
        wordCount.textColor = theme.mutedText
        wordCount.isHidden = !Theme.showsWordCount
        status.isHidden = true
        safeMode.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: theme.statusSize, weight: theme.imagePlaceholderSymbolWeight)
        safeMode.contentTintColor = theme.mutedText
        // An image view without an image is nothing to accessibility, and stays so when it gets one.
        safeMode.setAccessibilityElement(true)
        safeMode.setAccessibilityRole(.image)
        safeMode.setAccessibilityLabel("Safe mode")
        let readout = NSStackView(views: [safeMode, wordCount])
        readout.spacing = theme.statusGap
        readout.setHuggingPriority(.required, for: .horizontal)
        status.addSubview(readout)
        for subview in [readout, status, footer, titlebar] { subview.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(footer)
        view.addSubview(status)
        view.addSubview(titlebar)
        NSLayoutConstraint.activate([
            titlebar.topAnchor.constraint(equalTo: view.topAnchor),
            titlebar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: theme.titlebarFadeHeight),
            titlebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.topAnchor.constraint(equalTo: status.topAnchor, constant: -theme.titlebarFadeHeight),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -theme.statusInset.width),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -theme.statusInset.height),
            readout.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: theme.statusPadding.width),
            readout.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -theme.statusPadding.width),
            readout.topAnchor.constraint(equalTo: status.topAnchor, constant: theme.statusPadding.height),
            readout.bottomAnchor.constraint(equalTo: status.bottomAnchor, constant: -theme.statusPadding.height),
        ])

        textView.delegate = self
        textView.clickHandler = { [weak self] in self?.click(at: $0, $1) ?? false }
        textView.hoverHandler = { [weak self] in self?.hover(at: $0, $1) ?? false }
        textView.typingHandler = { [weak self] in self?.editTyping($0) ?? false }
        textView.pasteHandler = { [weak self] in self?.paste($0) ?? false }
        textView.formatCommandHandler = { [weak self] in self?.format($0, validate: $1) ?? (false, false) }
        renderer.images.didLoad = { [weak self] in self.map { $0.nudge($0.renderer.pictureRanges()) } }
        // A picture's pixels have arrived: the lines in view that drew its room without them show it.
        renderer.images.didDecode = { [weak self] picture, pixels in
            guard let self, !renderer.isStale else { return }
            let width = CGFloat(pixels.width) / (textView.window?.backingScaleFactor ?? 1)
            nudge(viewport.flatMap { self.renderer.ranges(showing: picture, width: width, in: $0) })
        }
        textView.tableCommandHandler = { [weak self] in self?.editTable($0, validate: $1) ?? false }
        textView.widthHandler = { [weak self] in self?.updateColumnWidth() }
        textView.layoutHandler = { [weak self] in self?.catchUpViewport() ?? false }
        // MEASURED: a composition that is given up sends no textDidChange. What it restyled while
        // it lasted (a fence it opened makes code of everything below) stayed as it was laid out
        // then, until the next edit.
        textView.compositionEndHandler = { [weak self] in self?.restyleChangedLines() }
        textView.textStorage?.delegate = self
        textView.textContentStorage?.delegate = renderer
        textView.textLayoutManager?.delegate = renderer
        (textView.textLayoutManager as? GridLayoutManager)?.hasWrappedRows = { [weak self] in self?.renderer.hasWrappedRows == true }
        (textView.textLayoutManager as? GridLayoutManager)?.columnOrigin = { [weak self] in self?.renderer.columnOrigin ?? 0 }
        countWords()

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(willSwitchToTextKit1),
            name: NSTextView.willSwitchToNSLayoutManagerNotification, object: textView)
        // Undo and redo send no textDidChange. The view's undo manager is only known once it is in a
        // window, and a document window supplies its own, so these observe every manager and filter.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.addObserver(self, selector: #selector(didUndoOrRedo), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(themeDidChange), name: Theme.didChange, object: nil)
        center.addObserver(self, selector: #selector(trustDidChange), name: TrustStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(fontsDidChange), name: NSFont.fontSetChangedNotification, object: nil)
        trustDidChange()
    }

    /// The exact document source. Setting it replaces the content and clears undo.
    public var text: String {
        get { textView.string }
        set {
            parseTimer?.invalidate()
            // A file an image points at may have appeared or changed since it was last read.
            renderer.images.forget()
            isLoading = true
            textView.string = newValue
            isLoading = false
            textView.runsOn = !renderer.map.tables.isEmpty
            preparse = nil
            changedLines = nil
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            // Text typed into an empty document takes these, and would get the system's line height.
            textView.typingAttributes[.paragraphStyle] = textView.defaultParagraphStyle
            refreshReveal()
        }
    }

    // MARK: parsing

    public func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Reveal and restyle nudges are attribute-only edits and must not reparse.
        guard editedMask.contains(.editedCharacters) else { return }
        renderer.revealSelection = Self.shifted(renderer.revealSelection, editAt: editedRange.location, delta: delta)
        unparsed = unparsed.map { NSUnionRange(Self.shifted($0, editAt: editedRange.location, delta: delta), editedRange) } ?? editedRange
        renderer.shiftRendered(editAt: editedRange.location, replacing: editedRange.length - delta, delta: delta)
        if let undo = textView.undoManager, undo.isUndoing || undo.isRedoing {
            restored = restored.map { NSUnionRange(Self.shifted($0, editAt: editedRange.location, delta: delta), editedRange) } ?? editedRange
        }
        // Only of the text as it was just before this edit: an edit that was asked about and not
        // made leaves one behind, and undo and redo do not ask.
        let count = renderer.map.lines.count, edit = asked.flatMap { $0.length == textStorage.length - delta ? $0 : nil }, grid = edit?.look
        asked = nil
        // MEASURED: the storage reports a typed character as its whole line. What was asked about
        // says which part of the line it is, when it is this edit: the same change in length, on
        // the same lines, with its text where it was to go. `restyle` parses a list item alone
        // only for an edit that keeps clear of its markers.
        var edited = editedRange
        if let edit, let replacement = edit.replacement as NSString?, replacement.length - edit.range.length == delta,
           textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true {
            let exact = NSRange(location: edit.range.location, length: replacement.length), text = textStorage.mutableString
            if NSMaxRange(exact) <= text.length, text.lineRange(for: exact) == text.lineRange(for: editedRange),
               text.substring(with: exact) == replacement as String { edited = exact }
        }
        if isLoading {
            reparse()
        } else if !renderer.isStale, let diff = MarkdownStyler.restyle(
            &renderer.map, in: textStorage.mutableString, editedRange: edited, changeInLength: delta,
            limit: textStorage.length > Self.synchronousParseLimit ? Self.partParseLimit : .max) {
            assert(renderer.map == MarkdownStyler.style(textStorage.string), "the parts parsed differ from the whole")
            didParse(diff, lineCountBefore: count, gridBefore: grid)
        } else if textStorage.length <= Self.synchronousParseLimit {
            reparse(gridBefore: grid)
        } else {
            renderer.isStale = true
            parseTimer?.invalidate()
            parseTimer = Timer.scheduledTimer(
                timeInterval: Self.parseDelay, target: self, selector: #selector(parseTimerFired), userInfo: nil, repeats: false)
        }
    }

    /// Keeps a frozen reveal selection on the same text through an edit: offsets up to the edit stay,
    /// and a range ending at the edit grows over inserted text.
    private static func shifted(_ range: NSRange, editAt location: Int, delta: Int) -> NSRange {
        let start = range.location <= location ? range.location : max(location, range.location + delta)
        let end = NSMaxRange(range) < location ? NSMaxRange(range) : max(location, NSMaxRange(range) + delta)
        return NSRange(location: start, length: max(start, end) - start)
    }

    /// Parses the whole text.
    private func reparse(gridBefore: TableLook? = nil) {
        let old = renderer.map
        let source = textView.string
        renderer.map = (isLoading ? preparse?.map(of: source) : nil) ?? MarkdownStyler.style(source)
        renderer.isStale = false
        // A text that is loaded is laid out anew; there is nothing to restyle.
        didParse(isLoading ? nil : renderer.map.diff(from: old), lineCountBefore: old.lines.count, gridBefore: gridBefore)
    }

    /// The map is up to date again; `diff` is what the parse changed in it, which had `count`
    /// lines before. `gridBefore` is how the table that the edit started in showed until now.
    private func didParse(_ diff: LineDiff?, lineCountBefore count: Int, gridBefore: TableLook? = nil) {
        if let edited = unparsed {
            renderer.keepWidths(editing: edited, changing: diff?.changed ?? 0..<0, lineCountBefore: count)
            unparsed = nil
        }
        let gridNow = gridBefore.flatMap { renderer.look(ofTableAt: $0.lines.lowerBound, in: textView.string as NSString) }
        if var diff, !(diff.old.isEmpty && diff.new.isEmpty) {
            let moved = diff.new.upperBound - diff.old.upperBound
            // A change inside a table that left its columns where they were, or that shows as
            // source before and after: the other rows show as before. MEASURED: nudging all
            // 2,000 rows of a table for a key in one was 10 ms.
            if let gridNow, gridNow == gridBefore, diff.old == gridNow.lines, diff.new == gridNow.lines { diff.new = diff.changed }
            // Lines changed before are where they were, or moved with the lines below this change.
            changedLines = changedLines.map {
                min($0.lowerBound, diff.new.lowerBound)..<max($0.upperBound + moved, diff.new.upperBound)
            } ?? diff.new
        } else if let gridBefore, gridNow != gridBefore {
            // Other text of the same length in a cell changes no style, but it can move the columns.
            changedLines = changedLines.map { min($0.lowerBound, gridBefore.lines.lowerBound)..<max($0.upperBound, gridBefore.lines.upperBound) }
                ?? gridBefore.lines
        }
        renderer.forgetUnusedImages()
        if let storage = textView.textStorage {
            revealed = renderer.revealedRanges(for: renderer.revealSelection, in: storage.mutableString)
        }
        wordCountTimer?.invalidate()
        wordCountTimer = Timer.scheduledTimer(
            timeInterval: isLoading ? 0 : Self.wordCountDelay, target: self, selector: #selector(countWords), userInfo: nil, repeats: false)
    }

    @objc private func parseTimerFired() {
        // Nothing is restyled and the selection is left alone while an input method is composing.
        // The commit is an edit and starts the timer again; a cancelled composition is caught by this one.
        guard !textView.hasMarkedText() else {
            parseTimer = Timer.scheduledTimer(
                timeInterval: Self.parseDelay, target: self, selector: #selector(parseTimerFired), userInfo: nil, repeats: false)
            return
        }
        reparse()
        restyleChangedLines()
        // Paragraphs first shown while the map was stale were rendered raw and are in no diff.
        nudge(viewport)
        // Nothing kept the caret out of the markers while the map was behind.
        textView.setSelectedRange(textView.selectedRange())
    }

    /// Typing in a large document leaves the map behind the text until it pauses. Anything that
    /// reads the map on the user's behalf first brings it up to date with this, and must leave the
    /// map alone when it is still stale afterwards: that is while an input method is composing.
    private func parseIfPending() {
        if parseTimer?.isValid == true, !textView.hasMarkedText() { parseTimer?.fire() }
    }

    /// Counting is a pass over the whole text (4 ms for 100,000 characters, and the first Japanese
    /// or Chinese word loads a dictionary for some 90 ms), so it waits for a pause in the typing
    /// and is done off the main thread.
    @objc private func countWords() {
        wordCounts += 1
        let text = textView.string, round = wordCounts
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var count = 0
            let source = text as NSString
            source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in
                count += 1
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, round == self.wordCounts else { return }
                    self.wordCount.stringValue = "\(count.formatted()) \(count == 1 ? "word" : "words")"
                    self.placeStatus()
                }
            }
        }
    }

    /// The word count floats beside the text where the page's margin has room for it. In a narrower
    /// window it would lie on the text, so the foot of the window is kept clear for it instead;
    /// and so in any window whose text has a table, which may stand in the margin.
    private func placeStatus() {
        // Nothing is shown before the first count, which is after the window's first frame; the
        // mark's picture is only made then.
        let isCounted = !wordCount.stringValue.isEmpty
        wordCount.isHidden = !Theme.showsWordCount
        if isCounted, !safeMode.isHidden, safeMode.image == nil {
            safeMode.image = NSImage(systemSymbolName: Theme.standard.safeModeSymbol, accessibilityDescription: "Safe mode")
        }
        status.isHidden = !isCounted || wordCount.isHidden && safeMode.isHidden
        footer.isHidden = status.isHidden
            || textView.textContainerInset.width >= status.fittingSize.width + 2 * Theme.standard.statusInset.width
    }

    // MARK: restyling

    public func textDidChange(_ notification: Notification) {
        restyleChangedLines()
        // The text view only brings the caret to the window's edge; the line being written gets room.
        // An edit of ours need not be where the caret is, and scrolls for itself.
        if !isPerforming { scrollToSelection() }
    }

    @objc private func didUndoOrRedo(_ notification: Notification) {
        guard notification.object as? UndoManager === textView.undoManager else { return }
        // MEASURED: text that undo puts back comes with the attributes it was taken out with,
        // which after a zoom are the old size's font and line height.
        if let range = restored, let storage = textView.textStorage, let font = textView.font, let style = textView.defaultParagraphStyle {
            let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            var same = NSRange()
            if range.length > 0, storage.attribute(.font, at: range.location, longestEffectiveRange: &same, in: range) as? NSFont != font
                || NSMaxRange(same) < NSMaxRange(range) {
                storage.addAttributes([.font: font, .paragraphStyle: style], range: range)
            }
        }
        restored = nil
        restyleChangedLines()
    }

    /// Every edit but undo and redo asks here first, while the map and the text still agree.
    public func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        let text = textView.string as NSString
        asked = (range, replacementString, text.length, renderer.map.lineIndex(containing: range.location).flatMap { renderer.look(ofTableAt: $0, in: text) })
        return true
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        refreshReveal()
    }

    /// An edit can restyle lines it did not touch (a fence, a multi-line token); TextKit only asks
    /// again for the edited paragraph, so the rest of the changed span is nudged here.
    private func restyleChangedLines() {
        // Not while the edit is still being processed: a container of another width lays everything
        // out anew. And not back again while this text lasts: MEASURED, 100 ms in a 600 KB text
        // when undoing the deletion of everything brought its tables back.
        if !renderer.isStale, !renderer.map.tables.isEmpty { textView.runsOn = true }
        if let changed = changedLines {
            changedLines = nil
            let lines = renderer.map.lines
            if !lines.isEmpty {
                // One line more on each side: quote bars and code panels end by looking at their neighbours.
                let first = min(max(changed.lowerBound - 1, 0), lines.count - 1), last = min(changed.upperBound, lines.count - 1)
                nudge([NSUnionRange(lines[first].range, lines[last].range)])
            }
        }
        refreshReveal()
    }

    /// Markers stay as they are while an input method is composing; the commit's textDidChange catches up.
    private func refreshReveal() {
        guard !textView.hasMarkedText() else { return }
        let selection = textView.selectedRange(), text = textView.string as NSString
        let now = renderer.revealedRanges(for: selection, in: text)
        let changed = now.symmetricDifference(revealed)
        renderer.revealSelection = selection
        revealed = now
        // A selection over much of a long document changes thousands of tokens at once; one nudge
        // over all of them is cheaper than one for each.
        if changed.count > Self.separateNudgeLimit, let first = changed.min(by: { $0.location < $1.location }) {
            nudge([changed.reduce(first, NSUnionRange)].map { renderer.restyleRange(for: $0, in: text) })
        } else if !changed.isEmpty {
            nudge(changed.map { renderer.restyleRange(for: $0, in: text) })
        }
    }

    /// A table shows as a grid only while the window is wide enough for it.
    private func updateColumnWidth() {
        placeStatus()
        // The container is the column, or wider than it in a window that has room beside the column.
        guard let room = textView.textContainer?.size.width else { return }
        let width = textView.columnWidth
        guard width != renderer.columnWidth || room != renderer.tableRoom else { return }
        parseIfPending()
        // A picture is at most as wide as the column.
        let pictures = width != renderer.columnWidth ? renderer.pictureRanges() : []
        // MEASURED: a paragraph on screen is only drawn again when its lines or the bounds it draws
        // in change. A heading's rule ends at the column's edge; around a heading that wraps and
        // shows its markers the bounds reach past that edge and stay as they are while it moves,
        // and the rule kept the length of an earlier width. So every paragraph in view is drawn
        // again, but not asked for again: what a paragraph is made of does not depend on the
        // column's width, pictures and tables apart, which are nudged below. MEASURED: asking
        // for them (a nudge of everything in view) was 1.7 ms of every step of a resize.
        if width != renderer.columnWidth {
            for container in textView.subviews { container.subviews.forEach { $0.needsDisplay = true } }
        }
        // Where the container is wider than the column, every paragraph says where the column is in it.
        let wasWider = renderer.tableRoom > renderer.columnWidth, origin = renderer.columnOrigin
        let top = textView.topParagraph
        let changing = renderer.tablesChangingDisplay(room: room, column: width, in: textView.string as NSString)
        guard !renderer.isStale else { return }
        let all = (room > width) != wasWider || renderer.columnOrigin != origin ? [NSRange(location: 0, length: textView.string.utf16.count)] : []
        nudge(all + changing + pictures)
        guard !changing.isEmpty else { return }
        // The caret may be in the delimiter row of a table that has just become a grid.
        textView.setSelectedRange(textView.selectedRange())
        // Rows whose cells wrap anew are of other heights, those that are not laid out by a
        // guess. MEASURED: a window narrowed while it showed the end of a long table was left
        // scrolled to below the text's end. The paragraph at its top is put back there by its
        // place in the text.
        if let top { scroll(toTop: top) }
    }

    /// A font was installed or removed: an icon font may be there now for characters that had none.
    @objc private func fontsDidChange() {
        IconFont.reload()
        renderer.forgetMeasurements()
        nudge([NSRange(location: 0, length: textView.string.utf16.count)])
    }

    /// The zoom, the column's width or the word count's visibility changed.
    @objc private func themeDidChange() {
        placeStatus()
        guard textView.font != Theme.standard.bodyFont else {
            // The column is as wide as the theme says now, which the view finds out with its
            // size; every line then wraps anew, and the text at the top of the window stays there.
            let before = place, width = textView.columnWidth
            textView.setFrameSize(textView.frame.size)
            if textView.columnWidth != width { place = before }
            return
        }
        renderer.forgetMeasurements()
        // The paragraph at the top of the view is looked up before every size changes and put back
        // there afterwards, from a fresh layout of that paragraph. MEASURED: left to find its place
        // again by the old scroll offset, TextKit once never came back from
        // `-[NSTextLayoutManager ensureLayoutForBounds:]` inside `NSTextView.layout` (a view
        // scrolled to the end of a text at zoom 1, then zoom 2), with memory growing without end.
        let before = place
        textView.applyTheme()
        textView.setSelectedRange(textView.selectedRange())
        place = before
    }

    /// What is laid out in and around the visible part of the text; empty before any layout.
    private var viewport: [NSRange] {
        guard let visible = textView.textLayoutManager?.textViewportLayoutController.viewportRange,
              let content = textView.textContentStorage else { return [] }
        let start = content.offset(from: content.documentRange.location, to: visible.location)
        return [NSRange(location: start, length: content.offset(from: visible.location, to: visible.endLocation))]
    }

    /// Makes TextKit ask the renderer again for the paragraphs in `ranges`. This is the only refresh
    /// that works: invalidating layout re-lays-out the cached paragraphs without asking.
    ///
    /// Only what is laid out for the window is asked for now. The rest of what TextKit has
    /// paragraphs of waits in `renderer.behind` until the window comes to it (`catchUp`, after
    /// every layout of the text view), so nothing is ever shown as it was before the nudge.
    /// MEASURED: asking for all 2,000 rows of a table at once made TextKit lay out some 190 of
    /// them again, estimate the height of everything above the caret anew and find its place
    /// again, 11 ms of a 27 ms key. And a nudge that took the layout away from the paragraph at
    /// the top of the window together with what is above it once left TextKit estimating without
    /// end in `-[NSTextLayoutManager ensureLayoutForBounds:]`; nothing outside the window's own
    /// paragraphs is touched any more.
    private func nudge(_ ranges: some Sequence<NSRange>) {
        let source = textView.string as NSString
        for range in ranges {
            let location = min(range.location, source.length)
            renderer.fallBehind(source.paragraphRange(for: NSRange(location: location, length: min(range.length, source.length - location))))
        }
        catchUp(in: viewport)
    }

    /// Asks again for the paragraphs in `ranges` that a nudge left for later. True when there were any.
    @discardableResult
    func catchUp(in ranges: [NSRange]) -> Bool {
        guard !renderer.behind.isEmpty, let content = textView.textContentStorage, let storage = content.textStorage else { return false }
        let source = storage.string as NSString
        let due = ranges.flatMap { renderer.behind.rangeView(of: $0.location..<NSMaxRange($0)) }.map {
            source.paragraphRange(for: NSRange(location: $0.lowerBound, length: $0.count))
        }
        guard !due.isEmpty else { return false }
        content.performEditingTransaction {
            for range in due {
                renderer.behind.remove(integersIn: range.location..<NSMaxRange(range))
                storage.edited(.editedAttributes, range: range, changeInLength: 0)
            }
        }
        return true
    }

    /// `catchUp` and `refit` for what has just been laid out for the window. MEASURED: not from
    /// `nudge`. Looking through the window's paragraphs while none of them is laid out (a zoom
    /// change on its way) left the old ones on screen for a frame.
    @discardableResult
    private func catchUpViewport() -> Bool {
        let wasBehind = catchUp(in: viewport)
        guard let shown = textView.textLayoutManager?.textViewportLayoutController.viewportRange else { return wasBehind }
        return refit(in: shown) || wasBehind
    }

    /// A row of wrapping cells is as high as the lines the renderer counted for its cells. One
    /// that TextKit broke into other lines is rendered again with the lines it has, before it
    /// is drawn. True when a row laid out in `range` was.
    @discardableResult
    func refit(in range: NSTextRange) -> Bool {
        guard renderer.hasWrappedRows, let layout = textView.textLayoutManager, let content = textView.textContentStorage else { return false }
        var misfits: [NSRange] = []
        layout.enumerateTextLayoutFragments(from: range.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(range.endLocation) == .orderedAscending else { return false }
            if fragment.state == .layoutAvailable, let block = fragment as? BlockFragment, let row = block.wrappedRow, block.cellLineCounts != row.lineCounts,
               let text = (fragment.textElement as? NSTextParagraph)?.attributedString,
               renderer.correct(lineCounts: block.cellLineCounts, of: row, showing: text.string) {
                misfits.append(NSRange(location: content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location), length: text.length))
            }
            return true
        }
        misfits.forEach(renderer.fallBehind)
        catchUp(in: misfits)
        return !misfits.isEmpty
    }

    // MARK: editing

    /// Every edit that is not plain typing goes through here, so it is undoable in one step like typing.
    /// An edit that changes no text only moves the selection.
    func perform(_ edit: TextEdit) {
        if edit.range.length > 0 || !edit.replacement.isEmpty {
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            isPerforming = true
            textView.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            isPerforming = false
        }
        let before = textView.selectedRange()
        textView.setSelectedRange(edit.selection)
        if textView.selectedRange() != before { scrollToSelection() }
    }

    /// Scrolls the selection into view with some room above and below it. Heights outside the
    /// viewport are estimates until they are laid out, pictures included, so one scroll can miss
    /// and is repeated until the selection is where it should be.
    public func scrollToSelection() {
        let selection = textView.selectedRange()
        guard let layout = textView.textLayoutManager, let content = textView.textContentStorage,
              let start = content.location(content.documentRange.location, offsetBy: selection.location),
              let end = content.location(start, offsetBy: selection.length), let range = NSTextRange(location: start, end: end) else { return }
        func scroll() {
            for _ in 0..<20 {
                layout.ensureLayout(for: range)
                var found = CGRect.null
                layout.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
                    found = found.union(frame)
                    return true
                }
                guard !found.isNull else { return textView.scrollRangeToVisible(selection) }
                let origin = textView.textContainerOrigin, visible = textView.visibleRect
                let target = found.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: -Theme.standard.scrollMargin)
                    .intersection(textView.bounds)
                if visible.minY <= target.minY, target.maxY <= visible.maxY { return }
                textView.scrollToVisible(NSRect(x: visible.minX, y: target.minY, width: visible.width, height: target.height))
                layout.textViewportLayoutController.layoutViewport()
                catchUpViewport()
                // As far as the text goes, or a selection higher than the window.
                if textView.visibleRect == visible { return }
            }
        }
        scroll()
        guard renderer.hasWrappedRows else { return }
        step(to: start)
        scroll()
    }

    /// MEASURED: where TextKit's guesses of heights are far off (a text of short lines above a
    /// table of wrapping cells, whose rows it guesses by those lines), the place it gives for
    /// text far away and the text it then lays out at that place are not the same, and a scroll
    /// by that place ends with the text out of the window; laying out what is between, or
    /// having TextKit move the window's part of the text there, did not hold either. What
    /// does: going there by what is laid out, a window's worth at a time, the paragraph at the
    /// window's far edge to its near edge. Only for a text with such rows (the callers see to
    /// it): every scroll that puts the window where nothing is laid out is a chance for the
    /// layout that does not return.
    private func step(to location: NSTextLocation) {
        guard let layout = textView.textLayoutManager else { return }
        let clipView = scrollView.contentView, origin = textView.textContainerOrigin.y
        for _ in 0..<Self.scrollStepLimit {
            guard let shown = layout.textViewportLayoutController.viewportRange, !shown.contains(location),
                  shown.endLocation.compare(location) != .orderedSame else { break }
            let isBelow = shown.endLocation.compare(location) == .orderedAscending
            var edge: CGRect?
            layout.enumerateTextLayoutFragments(from: isBelow ? shown.endLocation : shown.location, options: isBelow ? .reverse : []) {
                edge = $0.layoutFragmentFrame
                return false
            }
            guard let edge else { break }
            // A paragraph higher than the window is passed whole.
            let top = isBelow ? (edge.minY + origin > clipView.bounds.minY + 0.5 ? edge.minY : edge.maxY) + origin
                : (edge.maxY + origin < clipView.bounds.maxY - 0.5 ? edge.maxY : edge.minY) + origin - clipView.bounds.height
            let target = clipView.constrainBoundsRect(clipView.bounds.offsetBy(dx: 0, dy: top - clipView.bounds.minY)).origin
            // As far as the view goes.
            if abs(target.y - clipView.bounds.minY) < 0.5 { break }
            clipView.scroll(to: target)
            scrollView.reflectScrolledClipView(clipView)
            layout.textViewportLayoutController.layoutViewport()
            catchUpViewport()
        }
    }

    /// Where the user is in a text: the selection, and a paragraph at the top of the scroll
    /// view with how far the view is scrolled past that paragraph's top.
    public struct Place {
        var selection: NSRange
        var top: (offset: Int, past: CGFloat)?
    }

    /// Setting it puts a text that has just been loaded back where it was left. Heights outside
    /// the viewport are estimates, so the scroll is repeated until the paragraph is where it was.
    public var place: Place {
        get {
            // The first paragraph that is laid out for the window, which is at its top or just
            // above it. MEASURED: asking for the paragraph at a position instead makes TextKit
            // estimate where that is when the layout there is gone (straight after an edit above
            // the window), and that estimate is what once did not end.
            let clip = scrollView.contentView.bounds.minY - textView.textContainerOrigin.y
            guard let layout = textView.textLayoutManager, let content = textView.textContentStorage,
                  let start = layout.textViewportLayoutController.viewportRange?.location,
                  let frame = layout.textLayoutFragment(for: start)?.layoutFragmentFrame, frame != .zero else {
                return Place(selection: textView.selectedRange(), top: nil)
            }
            return Place(selection: textView.selectedRange(), top: (content.offset(from: content.documentRange.location, to: start), clip - frame.minY))
        }
        set {
            let length = (textView.string as NSString).length, start = min(newValue.selection.location, length)
            textView.setSelectedRange(NSRange(location: start, length: min(newValue.selection.length, length - start)))
            if let top = newValue.top { scroll(toTop: top) }
        }
    }

    /// Puts a paragraph where it was at the top of the scroll view, from a layout of that
    /// paragraph by its place in the text, and by steps of what is laid out where that misses
    /// (`step`): nothing here goes by an estimated height.
    private func scroll(toTop top: (offset: Int, past: CGFloat)) {
        guard let layout = textView.textLayoutManager, let content = textView.textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: min(top.offset, (textView.string as NSString).length)) else { return }
        let clipView = scrollView.contentView
        func scroll() {
            for _ in 0..<20 {
                layout.ensureLayout(for: NSTextRange(location: location))
                guard let frame = layout.textLayoutFragment(for: location)?.layoutFragmentFrame, frame != .zero else { return }
                let target = clipView.constrainBoundsRect(
                    clipView.bounds.offsetBy(dx: 0, dy: frame.minY + textView.textContainerOrigin.y + top.past - clipView.bounds.minY)).origin
                if abs(target.y - clipView.bounds.minY) < 0.5 { return }
                clipView.scroll(to: target)
                scrollView.reflectScrolledClipView(clipView)
                layout.textViewportLayoutController.layoutViewport()
                catchUpViewport()
            }
        }
        scroll()
        guard renderer.hasWrappedRows else { return }
        step(to: location)
        scroll()
    }

    /// Whether `location` is in a table that shows as a grid. A table that shows as its source is
    /// edited as source: the keys keep their usual meaning there.
    private func showsGrid(at location: Int) -> Bool {
        renderer.map.lineIndex(containing: location).map {
            renderer.grid(ofTableAt: $0, in: textView.string as NSString) != nil
        } ?? false
    }

    private func editTyping(_ typed: String) -> Bool {
        let text = textView.string, selection = textView.selectedRange()
        // Not on every character of a large document: there only a pipe or a marker typed over a
        // selection is worth a parse.
        if typed == "|" || selection.length > 0 && FormatCommands.wrappingMarkers.contains(typed) { parseIfPending() }
        guard !renderer.isStale else { return false }
        let pipe = typed == "|" && showsGrid(at: selection.location)
            ? TableEdits.pipe(in: text, map: renderer.map, selection: selection) : nil
        guard let edit = FormatCommands.wrap(typed, in: text, map: renderer.map, selection: selection) ?? pipe
                ?? TableEdits.textBelow(typed, in: text, map: renderer.map, selection: selection)
                ?? InputRules.closingBracket(typed, in: text, map: renderer.map, selection: selection) else { return false }
        perform(edit)
        return true
    }

    /// Validating a menu item is not worth a parse: while the map is behind the text every command
    /// is offered, unless an input method is composing, and finds out when it is chosen.
    private func format(_ command: FormatCommand, validate: Bool) -> (isEnabled: Bool, isOn: Bool) {
        if validate, renderer.isStale { return (!textView.hasMarkedText(), false) }
        parseIfPending()
        let text = textView.string, selection = textView.selectedRange()
        let edit = textView.hasMarkedText() || renderer.isStale ? nil : FormatCommands.edit(command, in: text, map: renderer.map, selection: selection)
        if validate {
            return (edit != nil, FormatCommands.isOn(command, in: text, map: renderer.map, selection: selection))
        }
        if let edit { perform(edit) }
        return (edit != nil, false)
    }

    /// Image files pasted or dropped become images with a path from the document to the file, and
    /// whatever is dragged here from a file tree becomes a link, a folder too; a URL pasted over a
    /// selection makes it a link.
    private func paste(_ pasteboard: NSPasteboard) -> Bool {
        let selection = textView.selectedRange()
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        let images = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        let files = pasteboard.isFromTree ? pasteboard.files : images
        if !files.isEmpty {
            let markup = files.map { file in
                let path = ImageCache.path(to: file, from: documentURL), name = file.deletingPathExtension().lastPathComponent
                return images.contains(file) ? FormatCommands.imageMarkup(alt: name, path: path)
                    : FormatCommands.linkMarkup(text: file.hasDirectoryPath ? file.lastPathComponent : name, path: path)
            }.joined(separator: "\n")
            perform(TextEdit(range: selection, replacement: markup,
                             selection: NSRange(location: selection.location + (markup as NSString).length, length: 0)))
            return true
        }
        // Only a link pasted over a selection and lines pasted into code are anything but the text itself.
        guard let pasted = pasteboard.string(forType: .string), selection.length > 0 || pasted.utf16.contains(0x0A) else { return false }
        parseIfPending()
        let text = textView.string
        guard let edit = (selection.length > 0 ? FormatCommands.link(pasting: pasted, in: text, map: renderer.map, selection: selection) : nil)
                ?? InputRules.paste(pasted, in: text, map: renderer.map, selection: selection) else { return false }
        perform(edit)
        return true
    }

    private func editTable(_ command: TableCommand, validate: Bool) -> Bool {
        if validate, renderer.isStale { return !textView.hasMarkedText() }
        parseIfPending()
        guard !renderer.isStale, !textView.hasMarkedText(),
              let edit = TableEdits.edit(command, in: textView.string, map: renderer.map, selection: textView.selectedRange()) else {
            return false
        }
        if !validate { perform(edit) }
        return true
    }

    /// Up and Down, with or without Shift. The text view's own move does, except between the rows
    /// of a grid, where the delimiter row is stepped over, and in and around a table whose
    /// cells wrap: a row's lines there are not below one another in the order of the text, which
    /// is how the text view takes them. Once a text has such a table, the x to keep to through
    /// a run of these keys, which the text view otherwise remembers itself, is kept here.
    private func moveVertically(down: Bool, extending: Bool) -> Bool {
        guard renderer.hasWrappedRows else { return !extending && moveInTable(down: down) }
        let selection = textView.selectedRange()
        var (head, anchor) = ends(of: selection, extending: extending, backward: !down)
        guard let x = keptColumn.flatMap({ $0.selection == selection ? $0.x : nil }) ?? caretRect(at: head)?.minX else { return false }
        if !extending, moveInTable(down: down) {
            keptColumn = (x, textView.selectedRange())
            return true
        }
        var target = wrappedDestination(from: head, down: down, x: x)
        if target == nil {
            let from = head
            switch (down, extending) {
            case (true, false): textView.moveDown(nil)
            case (false, false): textView.moveUp(nil)
            case (true, true): textView.moveDownAndModifySelection(nil)
            case (false, true): textView.moveUpAndModifySelection(nil)
            }
            let now = textView.selectedRange()
            head = extending && now.location == anchor ? NSMaxRange(now) : now.location
            // The text view has landed on the right line, by an x of its own; in a row whose
            // cells wrap, on a line of whichever cell comes first or last in the text.
            if head != from, let row = wrappedRow(at: head) {
                let frame = row.row.layoutFragmentFrame
                target = row.row.characterIndex(at: CGPoint(x: x, y: down ? frame.minY + 1 : frame.maxY - 1), forInsertion: true).map { row.start + $0 }
            } else {
                // MEASURED: a caret that leaves a heading hides the heading's marker, and until
                // the window's text is laid out again the lines below it stand where the heading
                // had the height of its text alone: the line below was reported inside the
                // heading, and Down from a heading came back to it.
                textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
                if let landed = caretRect(at: head), let before = caretRect(at: from), landed.midY != before.midY {
                    let origin = textView.textContainerOrigin
                    target = textView.characterIndexForInsertion(at: NSPoint(x: x + origin.x, y: landed.midY + origin.y))
                }
            }
        }
        if let target { select(head: target, anchor: extending ? anchor : target) }
        scrollToSelection()
        keptColumn = (x, textView.selectedRange())
        return true
    }

    /// The end of `selection` that a key moves and the end that stays: of a selection being
    /// extended, the end that has moved so far moves on; any other is left from its start
    /// backwards and from its end forwards.
    private func ends(of selection: NSRange, extending: Bool, backward: Bool) -> (head: Int, anchor: Int) {
        let startMoves = extending ? selection.length > 0 && movingStart == selection : backward
        return startMoves ? (selection.location, NSMaxRange(selection)) : (NSMaxRange(selection), selection.location)
    }

    /// Selects from `anchor` to `head`, the end that the keys with Shift move from then on.
    /// MEASURED: a selection that is set has its start as the end that stays, whatever affinity
    /// it is given; only the text view's own moves make the start the end that moves. So where
    /// that is the start, the text view makes one move backwards from the anchor, and is told
    /// where that goes when it asks (`willChangeSelection`).
    private func select(head: Int, anchor: Int) {
        guard head < anchor else { return textView.setSelectedRange(NSRange(location: anchor, length: head - anchor)) }
        textView.setSelectedRange(NSRange(location: anchor, length: 0))
        destination = NSRange(location: head, length: anchor - head)
        textView.moveBackwardAndModifySelection(nil)
        destination = nil
    }

    /// Left and Right by one character, or with `toLineEnd` to the start or the end of the line,
    /// with or without Shift, while the end that moves is in a table row whose cells wrap.
    /// MEASURED: the text view's own moves do not get through such a row. They go by where the
    /// characters of a line stand, and what is hidden there stands in one place: with Shift, the
    /// selection's end went to and fro between the end of a cell and the start of the row's last
    /// one, and the caret stayed behind the "<" of a "<br>" that was alone in its cell; and a
    /// line is to them the row's, from before the pipe of its cell. Here the keys go by the text,
    /// and a line is the line of a cell. By words the text view's own moves do get through.
    private func moveInWrappedRow(toLineEnd: Bool = false, forward: Bool, extending: Bool) -> Bool {
        let selection = textView.selectedRange(), text = textView.string as NSString
        let (head, anchor) = ends(of: selection, extending: extending, backward: !forward)
        guard let index = renderer.map.lineIndex(containing: head), renderer.grid(ofTableAt: index, in: text)?.wraps == true else { return false }
        var target = head
        if toLineEnd {
            guard let row = wrappedRow(at: head), let caret = caretRect(at: head),
                  let box = row.row.cellBoxes(holding: head - row.start)?.boxes.first(where: { $0.maxY > caret.midY }),
                  let found = row.row.characterIndex(at: CGPoint(x: forward ? box.maxX : box.minX, y: box.midY), forInsertion: true) else { return false }
            target = row.start + found
        } else if selection.length == 0 || extending {
            // Without Shift a selection is only left, at the end the key points to.
            target = forward ? (head < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: head)) : head)
                : (head > 0 ? text.rangeOfComposedCharacterSequence(at: head - 1).location : head)
        }
        select(head: target, anchor: extending ? anchor : target)
        if extending { textView.scrollRangeToVisible(NSRange(location: target, length: 0)) } else { scrollToSelection() }
        return true
    }

    /// Up and Down between the rows of a grid of single lines step over the hidden delimiter row
    /// and stay in the column. A selection moves from its start or its end, as it does in text.
    private func moveInTable(down: Bool) -> Bool {
        let selection = textView.selectedRange(), map = renderer.map
        let from = down ? NSMaxRange(selection) : selection.location
        guard let index = map.lineIndex(containing: from), index == map.lineIndex(containing: selection.location),
              case .tableRow = map.lines[index].kind, let table = map.table(atLine: index),
              renderer.grid(ofTableAt: index, in: textView.string as NSString)?.wraps == false else { return false }
        guard let target = row(nextTo: index, down: down, in: table), let here = lineFragment(at: from),
              let there = lineFragment(at: map.lines[target].range.location) else { return false }
        let x = here.line.locationForCharacter(at: from - here.start).x
        let found = there.start + there.line.characterIndex(for: CGPoint(x: x, y: there.line.typographicBounds.height / 2))
        let column = max(map.lines[index].pipes.count { $0 < from } - 1, 0)
        textView.setSelectedRange(NSRange(location: clamped(found, toColumn: column, ofLineAt: target), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// Where Up or Down takes a caret at `from` in a row whose cells wrap: to the next line of
    /// its cell, then to the nearest line of the same column in the row above or below, and
    /// without one out of the table, each time to what is nearest to `x` there. Nil anywhere else.
    private func wrappedDestination(from: Int, down: Bool, x: CGFloat) -> Int? {
        let map = renderer.map
        guard let index = map.lineIndex(containing: from), let table = map.table(atLine: index), let here = wrappedRow(at: from),
              let caret = caretRect(at: from), let cell = here.row.cellBoxes(holding: from - here.start),
              let line = cell.boxes.firstIndex(where: { $0.maxY > caret.midY }) else { return nil }
        if cell.boxes.indices.contains(line + (down ? 1 : -1)) {
            return here.row.characterIndex(at: CGPoint(x: x, y: cell.boxes[line + (down ? 1 : -1)].midY), forInsertion: true).map { here.start + $0 }
        }
        // In a row too short to have the column, its last cell.
        if let target = row(nextTo: index, down: down, in: table), let there = wrappedRow(at: map.lines[target].range.location),
           let boxes = there.row.cellBoxes(holding: 0, inColumn: cell.column)?.boxes, let nearest = down ? boxes.first : boxes.last {
            return there.row.characterIndex(at: CGPoint(x: x, y: nearest.midY), forInsertion: true).map { there.start + $0 }
        }
        let frame = here.row.layoutFragmentFrame, origin = textView.textContainerOrigin
        return textView.characterIndexForInsertion(at: NSPoint(x: x + origin.x, y: (down ? frame.maxY + 1 : frame.minY - 1) + origin.y))
    }

    /// The line of the row below or above the row at line `index` of `table`, past the delimiter
    /// row; nil from the table's last or first row.
    private func row(nextTo index: Int, down: Bool, in table: TableStyle) -> Int? {
        let step = down ? 1 : -1, next = index + step == table.lines.lowerBound + 1 ? index + 2 * step : index + step
        return table.lines.contains(next) ? next : nil
    }

    /// The row of a grid with wrapping cells that holds `offset`, laid out as it shows now, and where it starts in the text.
    private func wrappedRow(at offset: Int) -> (row: BlockFragment, start: Int)? {
        guard let layout = textView.textLayoutManager, let content = textView.textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        catchUp(in: [(textView.string as NSString).paragraphRange(for: NSRange(location: offset, length: 0))])
        layout.ensureLayout(for: NSTextRange(location: location))
        guard let row = layout.textLayoutFragment(for: location) as? BlockFragment, row.wrappedRow != nil else { return nil }
        return (row, content.offset(from: content.documentRange.location, to: row.rangeInElement.location))
    }

    /// Where the caret stands at `offset`, in the text container's coordinates.
    private func caretRect(at offset: Int) -> CGRect? {
        guard let layout = textView.textLayoutManager, let content = textView.textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        var found: CGRect?
        layout.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: []) { _, frame, _, _ in
            found = frame
            return false
        }
        return found
    }

    /// The offset nearest to `offset` in the cell of `column` in the table row at line `index`; in
    /// a row too short to have that cell, the row's end.
    private func clamped(_ offset: Int, toColumn column: Int, ofLineAt index: Int) -> Int {
        let line = renderer.map.lines[index]
        guard column < line.cells.count else { return line.cells.last.map { NSMaxRange($0.range) } ?? offset }
        return min(max(offset, line.cells[column].range.location), NSMaxRange(line.cells[column].range))
    }

    /// A click in a grid row is in the column it is over. The text system alone gives the empty
    /// part of a cell to whichever neighbour's text is nearer, because the pipe between them is
    /// one wide tab.
    private func clickedOffset(_ offset: Int, at point: NSPoint) -> Int {
        guard let index = renderer.map.lineIndex(containing: offset), case .tableRow = renderer.map.lines[index].kind,
              let grid = renderer.grid(ofTableAt: index, in: textView.string as NSString),
              let row = lineFragment(at: renderer.map.lines[index].range.location) else { return offset }
        // Where the cells wrap, the column and the line in it are both found from the point.
        if grid.wraps { return textView.wrappedOffset(at: point) ?? offset }
        let edges = grid.edges
        let x = point.x - textView.textContainerOrigin.x
        // Looked up in the row itself, which may be wider than the text column.
        let bounds = row.line.typographicBounds
        let found = row.start + row.line.characterIndex(for: CGPoint(x: x - row.frame.minX - bounds.minX, y: bounds.height / 2))
        return clamped(found, toColumn: max(edges.dropLast().count { $0 <= point.x - textView.columnLeft } - 1, 0), ofLineAt: index)
    }

    /// The first laid-out line of the paragraph that holds `offset`, with its fragment's frame and offset.
    private func lineFragment(at offset: Int) -> (line: NSTextLineFragment, frame: CGRect, start: Int)? {
        guard let layout = textView.textLayoutManager, let content = textView.textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let fragment = layout.textLayoutFragment(for: location), let line = fragment.textLineFragments.first else { return nil }
        return (line, fragment.layoutFragmentFrame, content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location))
    }

    /// The start of the line at `index` that the caret cannot stand in: its block markers and, in a
    /// row of a grid, the leading pipe.
    private func hiddenLead(ofLineAt index: Int) -> NSRange {
        let line = renderer.map.lines[index], text = textView.string as NSString
        // Where the cells wrap, the blanks in front of the first cell's text are hidden with the pipe.
        if let lead = renderer.cellLeads(ofLineAt: index, in: text)?.first { return lead }
        guard case .tableRow = line.kind, let pipe = line.pipes.first, renderer.grid(ofTableAt: index, in: text) != nil else { return line.prefixRange }
        return NSRange(location: line.range.location, length: pipe + 1 - line.range.location)
    }

    /// The pipe that closes the row of a grid at line `index`. The caret does not go behind it:
    /// text there would be outside the table's cells.
    private func closingPipe(ofLineAt index: Int) -> Int? {
        let line = renderer.map.lines[index]
        guard case .tableRow = line.kind, line.pipes.count > 1, line.cells.count < line.pipes.count,
              renderer.grid(ofTableAt: index, in: textView.string as NSString) != nil else { return nil }
        return line.pipes.last
    }

    /// The hidden start of its line that the caret stands directly behind.
    private var prefixBeforeCaret: NSRange? {
        let caret = textView.selectedRange()
        guard caret.length == 0, let index = renderer.map.lineIndex(containing: caret.location) else { return nil }
        let prefix = hiddenLead(ofLineAt: index)
        return prefix.length > 0 && caret.location == NSMaxRange(prefix) ? prefix : nil
    }

    /// Whether a delete key does nothing but delete, told from the text alone. In a large document
    /// the map is behind the text while a key repeats, and a parse for every repeat would make a
    /// held Backspace crawl. The rules for these keys only act at the start of a line's content,
    /// where nothing but block markers stands before the caret, at its end, or beside a pipe or
    /// the backslash that escapes one.
    private func deletesPlainly(_ selector: Selector) -> Bool {
        let selection = textView.selectedRange(), text = textView.string as NSString
        guard !textView.hasMarkedText() else { return false }
        let start = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let end = text.lineContentEnd(at: selection.location)
        func isPipe(_ offset: Int) -> Bool { offset < end && [0x7C, 0x5C].contains(text.character(at: offset)) }
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)),
             #selector(NSResponder.deleteWordBackward(_:)):
            if selection.length > 0 { return true }
            guard selection.location > start, !isPipe(selection.location - 1), !isPipe(selection.location) else { return false }
            let markers = CharacterSet(charactersIn: " \t>-*+.)[]xX0123456789")
            return text.substring(with: NSRange(location: start, length: selection.location - start)).unicodeScalars
                .contains { !markers.contains($0) }
        case #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordForward(_:)),
             #selector(NSResponder.deleteToEndOfLine(_:)), #selector(NSResponder.deleteToEndOfParagraph(_:)):
            return selection.length > 0 || selection.location < end && !isPipe(selection.location) && !isPipe(selection.location + 1)
        default:
            return false
        }
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if renderer.isStale, deletesPlainly(selector) { return false }
        parseIfPending()
        guard !renderer.isStale else { return false }
        typealias Rule = (String, StyleMap, NSRange) -> TextEdit?
        let rule: Rule
        // What the key does in a table that shows as a grid, which comes first.
        var tableRule: Rule?
        let deleteBackward: Rule = {
            TableEdits.separatorDelete(forward: false, in: $0, map: $1, selection: $2) ?? InputRules.deleteBackward(in: $0, map: $1, selection: $2)
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): (tableRule, rule) = (TableEdits.newline, InputRules.newline)
        case #selector(NSResponder.insertTab(_:)): (tableRule, rule) = (TableEdits.nextCell, InputRules.indent)
        case #selector(NSResponder.insertBacktab(_:)): (tableRule, rule) = (TableEdits.previousCell, InputRules.outdent)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)),
             #selector(NSResponder.deleteWordBackward(_:)):
            // Where the cells wrap, the blanks in front of a cell's text are hidden with the pipe
            // before them: Backspace does as little there as behind the pipe itself.
            let caret = textView.selectedRange(), text = textView.string as NSString
            if caret.length == 0, caret.location > 0, text.character(at: caret.location - 1) == 0x20,
               let index = renderer.map.lineIndex(containing: caret.location),
               renderer.cellLeads(ofLineAt: index, in: text)?.contains(where: { NSMaxRange($0) == caret.location }) == true { return true }
            (tableRule, rule) = (TableEdits.deleteBackward, deleteBackward)
        case #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordForward(_:)),
             #selector(NSResponder.deleteToEndOfLine(_:)), #selector(NSResponder.deleteToEndOfParagraph(_:)):
            (tableRule, rule) = (TableEdits.deleteForward, {
                TableEdits.separatorDelete(forward: true, in: $0, map: $1, selection: $2) ?? InputRules.deleteForward(in: $0, map: $1, selection: $2)
            })
        case #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteToBeginningOfParagraph(_:)):
            let caret = textView.selectedRange()
            guard caret.length == 0, !textView.hasMarkedText(), prefixBeforeCaret == nil,
                  let index = renderer.map.lineIndex(containing: caret.location),
                  renderer.map.lines[index].prefixRange.length > 0 else {
                (tableRule, rule) = (TableEdits.deleteBackward, deleteBackward)
                break
            }
            // The command's own idea of the beginning, which is the start of a wrapped line too, but not past the markers.
            textView.doCommand(by: selector == #selector(NSResponder.deleteToBeginningOfLine(_:))
                ? #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:))
                : #selector(NSResponder.moveToBeginningOfParagraphAndModifySelection(_:)))
            let start = max(textView.selectedRange().location, NSMaxRange(renderer.map.lines[index].prefixRange))
            perform(TextEdit(range: NSRange(location: start, length: caret.location - start), replacement: "",
                             selection: NSRange(location: start, length: 0)))
            return true
        case #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)):
            // Behind hidden markers the caret is already at the beginning.
            return moveInWrappedRow(toLineEnd: true, forward: false, extending: false) || prefixBeforeCaret != nil
        case #selector(NSResponder.moveToBeginningOfParagraph(_:)):
            return prefixBeforeCaret != nil
        case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)):
            return moveInWrappedRow(toLineEnd: true, forward: true, extending: false)
        case #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)), #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)):
            return moveInWrappedRow(toLineEnd: true, forward: false, extending: true)
        case #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)), #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)):
            return moveInWrappedRow(toLineEnd: true, forward: true, extending: true)
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveBackward(_:)),
             #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordBackward(_:)):
            // Leftwards the hidden markers are skipped: the next stop is the end of the line above.
            guard let prefix = prefixBeforeCaret, prefix.location > 0 else {
                let byWord = [#selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordBackward(_:))].contains(selector)
                return !byWord && moveInWrappedRow(forward: false, extending: false)
            }
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).lineContentEnd(at: prefix.location - 1), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
            return true
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)),
             #selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveWordForward(_:)):
            // Rightwards from the end of a grid row's last cell the next stop is the line below.
            let caret = textView.selectedRange()
            guard caret.length == 0, let index = renderer.map.lineIndex(containing: caret.location),
                  closingPipe(ofLineAt: index) == caret.location else {
                let byWord = [#selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveWordForward(_:))].contains(selector)
                return !byWord && moveInWrappedRow(forward: true, extending: false)
            }
            textView.setSelectedRange(NSRange(location: NSMaxRange(renderer.map.lines[index].range), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
            return true
        case #selector(NSResponder.moveLeftAndModifySelection(_:)), #selector(NSResponder.moveBackwardAndModifySelection(_:)):
            return moveInWrappedRow(forward: false, extending: true)
        case #selector(NSResponder.moveRightAndModifySelection(_:)), #selector(NSResponder.moveForwardAndModifySelection(_:)):
            return moveInWrappedRow(forward: true, extending: true)
        case #selector(NSResponder.moveUp(_:)): return moveVertically(down: false, extending: false)
        case #selector(NSResponder.moveDown(_:)): return moveVertically(down: true, extending: false)
        case #selector(NSResponder.moveUpAndModifySelection(_:)): return moveVertically(down: false, extending: true)
        case #selector(NSResponder.moveDownAndModifySelection(_:)): return moveVertically(down: true, extending: true)
        default: return false
        }
        guard !textView.hasMarkedText() else { return false }
        let text = textView.string, selection = textView.selectedRange()
        let inGrid = tableRule.flatMap { showsGrid(at: selection.location) ? $0(text, renderer.map, selection) : nil }
        guard let edit = inGrid ?? rule(text, renderer.map, selection) else { return false }
        perform(edit)
        return true
    }

    // MARK: links

    /// The paragraph laid out at `point`, in view coordinates: its fragment, its offset in the text
    /// and the point in the fragment's own coordinates.
    private func fragment(at point: NSPoint) -> (fragment: NSTextLayoutFragment, start: Int, local: CGPoint)? {
        guard let layout = textView.textLayoutManager, let content = textView.textContentStorage else { return nil }
        let origin = textView.textContainerOrigin, target = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = layout.textLayoutFragment(for: target) else { return nil }
        let frame = fragment.layoutFragmentFrame
        return (fragment, content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location),
                CGPoint(x: target.x - frame.minX, y: target.y - frame.minY))
    }

    /// The link whose text is drawn at `point`, in view coordinates.
    private func link(at point: NSPoint) -> InlineToken? {
        guard !renderer.isStale, let (fragment, start, local) = fragment(at: point), let index = renderer.map.lineIndex(startingAt: start) else { return nil }
        let offset: Int
        if let row = fragment as? BlockFragment, row.wrappedRow != nil {
            // A row whose cells wrap looks its lines up by column.
            let frame = row.layoutFragmentFrame
            guard let found = row.characterIndex(at: CGPoint(x: local.x + frame.minX, y: local.y + frame.minY), forInsertion: false) else { return nil }
            offset = start + found
        } else {
            guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(local) }) else { return nil }
            let bounds = line.typographicBounds
            offset = start + line.characterIndex(for: CGPoint(x: local.x - bounds.minX, y: local.y - bounds.minY))
        }
        return renderer.map.lines[index].tokens.last { $0.kind == .link && NSLocationInRange(offset, $0.contentRange) }
    }

    /// With Command held a click opens the link under it; any other click may be on a checkbox.
    private func click(at point: NSPoint, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        parseIfPending()
        guard !renderer.isStale else { return false }
        guard modifiers.contains(.command) else { return toggleCheckbox(at: point) || loadBlockedImage(at: point) }
        guard let destination = link(at: point)?.destination else { return false }
        open(destination)
        return true
    }

    /// A click on an image that safe mode blocked loads the images of this document.
    private func loadBlockedImage(at point: NSPoint) -> Bool {
        guard let (fragment, _, local) = fragment(at: point), let block = fragment as? BlockFragment,
              block.pictures.contains(where: { $0.picture.isBlocked && $0.rect.contains(local) }) else { return false }
        loadsRemoteImages = true
        return true
    }

    /// While Command is held the link under the mouse is underlined, as the thing a click opens.
    private func hover(at point: NSPoint?, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        let link = modifiers.contains(.command) ? point.flatMap(link(at:))?.range : nil
        if link != renderer.hoveredLink {
            let changed = [renderer.hoveredLink, link].compactMap { $0 }
            renderer.hoveredLink = link
            nudge(changed.map { renderer.restyleRange(for: $0, in: textView.string as NSString) })
        }
        return link != nil
    }

    /// Follows a link: "#anchor" goes to that heading of this document; anything else is for `linkOpener`.
    public func open(_ destination: String) {
        if destination.hasPrefix("#") {
            parseIfPending()
            guard !renderer.isStale,
                  let index = renderer.map.headingLine(forAnchor: String(destination.dropFirst()), in: textView.string) else { return }
            let line = renderer.map.lines[index]
            textView.setSelectedRange(NSRange(location: NSMaxRange(line.headingMarkers.first ?? line.prefixRange), length: 0))
            // Into view first, which lays out what is around it; then up to the top of the window, as
            // far as the text's end allows.
            scrollToSelection()
            guard let fragment = lineFragment(at: line.range.location) else { return }
            textView.scroll(NSPoint(x: 0, y: fragment.frame.minY + textView.textContainerOrigin.y - Theme.standard.pagePadding.height))
        } else if let url = ImageCache.url(for: destination, relativeTo: documentURL) {
            if url.isFileURL {
                (["md", "markdown"].contains(url.pathExtension.lowercased()) ? linkOpener : fileRevealer)(url)
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                linkOpener(url)
            }
        }
    }

    /// A click on a task's checkbox checks or unchecks it in the source.
    private func toggleCheckbox(at point: NSPoint) -> Bool {
        guard let (fragment, start, local) = fragment(at: point), let line = fragment.textLineFragments.first,
              let index = renderer.map.lineIndex(startingAt: start) else { return false }
        let bounds = line.typographicBounds
        for marker in renderer.map.lines[index].listMarkers {
            guard let box = marker.checkbox else { continue }
            let left = line.locationForCharacter(at: box.range.location - start).x
            let right = line.locationForCharacter(at: box.range.location - start + 1).x
            guard CGRect(x: bounds.minX + left, y: bounds.minY, width: right - left, height: bounds.height).contains(local) else { continue }
            perform(TextEdit(
                range: NSRange(location: box.range.location + 1, length: 1), replacement: box.isChecked ? " " : "x",
                selection: textView.selectedRange()))
            return true
        }
        return false
    }

    // MARK: selection

    public func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange
    ) -> NSRange {
        let selection = snapped(destination ?? new, from: old)
        // The end that moves is the start when the end has stayed where it was.
        if selection != old {
            movingStart = selection.length > 0 && NSMaxRange(selection) == NSMaxRange(old) ? selection : nil
        }
        return selection
    }

    /// Block markers are hidden, so the caret never rests among them: it lands behind them. A
    /// selection takes the markers whole or not at all. In a table that shows as a grid the same
    /// goes for the leading pipe of a row and for the delimiter row, which the caret steps over
    /// and a selection takes whole; and the caret stays in front of the pipe that closes a row.
    /// Where the cells of a grid wrap, the same goes for the pipe in front of every cell with
    /// the blanks behind it.
    private func snapped(_ new: NSRange, from old: NSRange) -> NSRange {
        // Only typing moves the selection while the map is behind, and it never puts it among markers.
        guard !renderer.isStale else { return new }
        let map = renderer.map
        let text = textView.string as NSString
        func lead(holding location: Int) -> NSRange? {
            guard let index = map.lineIndex(containing: location) else { return nil }
            let lead = hiddenLead(ofLineAt: index)
            if location > lead.location, location < NSMaxRange(lead) { return lead }
            // Where the cells wrap, the pipe in front of a cell and the blanks behind it are
            // hidden: one stop before them, at the end of the cell before, and one behind.
            return renderer.cellLeads(ofLineAt: index, in: text)?.first { location > $0.location && location < NSMaxRange($0) }
        }
        func caret(_ location: Int) -> NSRange {
            guard let index = map.lineIndex(containing: location) else { return NSRange(location: location, length: 0) }
            var stop = max(location, NSMaxRange(hiddenLead(ofLineAt: index)))
            if let lead = lead(holding: stop) { stop = stop < old.location ? lead.location : NSMaxRange(lead) }
            let end = text.lineContentEnd(at: map.lines[index].range.location)
            // Not from the empty line after the text's last line break, which belongs to no line.
            if let pipe = closingPipe(ofLineAt: index), stop <= end { stop = min(stop, pipe) }
            return NSRange(location: stop, length: 0)
        }
        /// The stops on either side of the hidden delimiter row that holds `location`: the end of
        /// the header row, and the start of the line below, or the row's own end when it ends the text.
        func delimiterStops(around location: Int) -> (above: Int, below: Int, endsText: Bool)? {
            guard let index = map.lineIndex(containing: location), case .tableDelimiter = map.lines[index].kind,
                  renderer.grid(ofTableAt: index, in: text) != nil else { return nil }
            let row = map.lines[index].range, end = text.lineContentEnd(at: row.location)
            return location <= end ? (text.lineContentEnd(at: row.location - 1), NSMaxRange(row), NSMaxRange(row) == end) : nil
        }
        if new.length == 0 {
            let location = self.textView.clickPoint.map { clickedOffset(new.location, at: $0) } ?? new.location
            guard let stops = delimiterStops(around: location) else { return caret(location) }
            // The end of a row that ends the text is still in the row, which is no place for the caret.
            return caret(location < old.location || stops.endsText ? stops.above : stops.below)
        }
        var start = new.location, end = NSMaxRange(new)
        if let stops = delimiterStops(around: start) { start = start < old.location || stops.endsText ? stops.above : stops.below }
        if let stops = delimiterStops(around: end) { end = end < NSMaxRange(old) ? stops.above : stops.below }
        if let lead = lead(holding: start) { start = start < old.location ? lead.location : NSMaxRange(lead) }
        if let lead = lead(holding: end) { end = end < NSMaxRange(old) ? lead.location : NSMaxRange(lead) }
        return start < end ? NSRange(location: start, length: end - start) : caret(start)
    }

    // MARK: spelling

    public func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        value != 0 && renderer.suppressesSpelling(in: affectedCharRange, of: textView.string as NSString) ? 0 : value
    }

    @objc private func willSwitchToTextKit1(_ notification: Notification) {
        assertionFailure("EditorTextView fell back to TextKit 1; something touched layoutManager or a TextKit 1-only API")
    }
}
