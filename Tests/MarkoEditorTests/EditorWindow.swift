import AppKit
import Testing
@testable import MarkoEditor

/// An editor in a real window that is ordered on screen but never activated, with probes into what
/// TextKit actually laid out.
struct EditorWindow {
    let editor = EditorController()
    let window: NSWindow

    init(_ text: String = "", size: NSSize = NSSize(width: 900, height: 600), documentURL: URL? = nil) {
        NSApplication.shared.setActivationPolicy(.accessory)
        WebStub.install()
        // A test never opens anything outside itself.
        editor.linkOpener = { _ in }
        editor.fileRevealer = { _ in }
        editor.documentURL = documentURL
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 120, y: 160), size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.moveToBuiltInDisplay()
        window.title = "Marko test (closes by itself)"
        window.contentView = editor.view
        window.makeFirstResponder(editor.textView)
        window.orderFrontRegardless()
        editor.text = text
        pump()
    }

    var textView: EditorTextView { editor.textView }
    var layout: NSTextLayoutManager { textView.textLayoutManager! }
    var content: NSTextContentStorage { textView.textContentStorage! }
    var length: Int { (textView.string as NSString).length }

    func close() { window.close() }

    func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func select(_ location: Int, length: Int = 0) {
        textView.setSelectedRange(NSRange(location: location, length: length))
    }

    static let backspace: Character = "\u{7F}"
    /// What Shift-Tab sends.
    static let backtab: Character = "\u{19}"

    /// Real key events through the window, one per run-loop turn. Return is "\r", Tab is "\t".
    func type(_ text: String) {
        let keyCodes: [Character: UInt16] = ["\r": 36, "\t": 48, Self.backtab: 48, Self.backspace: 51]
        for character in text {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: character == Self.backtab ? .shift : [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: String(character),
                    charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: keyCodes[character] ?? 0)!)
            }
            pump(0.005)
        }
    }

    /// A mouse-down event at `point` in text view coordinates, sent straight to the text view. Only for
    /// clicks the view uses up at once (a checkbox). An ordinary click makes NSTextView track the mouse
    /// until a mouse-up arrives, and posting one through NSApp stops the test process's main run loop
    /// some time later, which ends the whole run silently with exit code 0.
    func mouseDown(at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        textView.mouseDown(with: mouseEvent(.leftMouseDown, at: point, modifiers))
        pump()
    }

    /// The mouse moving to `point` in text view coordinates with `modifiers` held, as the view's tracking area reports it.
    func mouseMoved(to point: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        textView.mouseMoved(with: mouseEvent(.mouseMoved, at: point, modifiers))
        pump()
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: textView.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .mouseMoved ? 0 : 1)!
    }

    /// The first offset of `text` in the document.
    func offset(of text: String) -> Int {
        (textView.string as NSString).range(of: text).location
    }

    /// Chooses the Format menu item `title` as the menu would: validated first, then sent to the text view.
    /// Returns whether it was enabled and whether it had a checkmark.
    @discardableResult
    func chooseFormat(_ title: String, perform: Bool = true) -> (isEnabled: Bool, isOn: Bool) {
        let menu = EditorTextView.formatMenu()
        let item = menu.item(withTitle: title) ?? menu.item(withTitle: "Table")!.submenu!.item(withTitle: title)!
        let isEnabled = textView.validateUserInterfaceItem(item)
        if isEnabled, perform {
            textView.performFormatCommand(item)
            pump()
        }
        return (isEnabled, item.state == .on)
    }

    /// What an ordinary click at `point` in text view coordinates does to the selection: NSTextView
    /// resolves the point to an insertion index and proposes that to its delegate.
    func placeCaret(at point: NSPoint) {
        textView.clickPoint = point
        select(textView.characterIndexForInsertion(at: point))
        textView.clickPoint = nil
    }

    /// What a key bound to `command` does: the delegate is asked first, as for a real key.
    func command(_ command: Selector) {
        textView.doCommand(by: command)
    }

    func undoAll() {
        while textView.undoManager?.canUndo == true { textView.undoManager?.undo() }
        pump()
    }

    // MARK: probes

    /// As it shows once the window has come to it: what a nudge left for then is asked for first.
    func fragment(at offset: Int) -> NSTextLayoutFragment {
        editor.catchUp(in: [NSRange(location: 0, length: length)])
        layout.ensureLayout(for: layout.documentRange)
        if editor.refit(in: layout.documentRange) { layout.ensureLayout(for: layout.documentRange) }
        return layout.textLayoutFragment(for: content.location(content.documentRange.location, offsetBy: offset)!)!
    }

    /// The display paragraph holding `offset` and the offset's index in it.
    func displayParagraph(at offset: Int) -> (text: NSAttributedString, index: Int) {
        let paragraph = fragment(at: offset).textElement as! NSTextParagraph
        let start = content.offset(from: content.documentRange.location, to: paragraph.elementRange!.location)
        return (paragraph.attributedString, offset - start)
    }

    func displayAttributes(at offset: Int) -> [NSAttributedString.Key: Any] {
        let (text, index) = displayParagraph(at: offset)
        return text.attributes(at: index, effectiveRange: nil)
    }

    func displayFont(at offset: Int) -> NSFont {
        displayAttributes(at: offset)[.font] as! NSFont
    }

    func isHidden(_ offset: Int) -> Bool {
        displayFont(at: offset).pointSize < 1
    }

    /// Laid-out width of the first visual line of the paragraph holding `offset`.
    func lineWidth(at offset: Int) -> CGFloat {
        fragment(at: offset).textLineFragments[0].typographicBounds.width
    }

    /// Where the character at `offset` is drawn, in text view coordinates.
    func characterRect(at offset: Int) -> CGRect {
        let fragment = fragment(at: offset), index = displayParagraph(at: offset).index
        let line = fragment.textLineFragments.first { NSLocationInRange(index, $0.characterRange) }!
        let left = line.locationForCharacter(at: index).x, right = line.locationForCharacter(at: index + 1).x
        let origin = textView.textContainerOrigin, frame = fragment.layoutFragmentFrame, bounds = line.typographicBounds
        return CGRect(x: origin.x + frame.minX + bounds.minX + left, y: origin.y + frame.minY + bounds.minY,
                      width: right - left, height: bounds.height)
    }

    /// Where the caret stands at `offset`, in the text container's coordinates, as the layout manager tells the text view.
    func caretRect(at offset: Int) -> CGRect {
        editor.catchUp(in: [NSRange(location: 0, length: length)])
        layout.ensureLayout(for: layout.documentRange)
        var found = CGRect.null
        layout.enumerateTextSegments(in: NSTextRange(location: content.location(content.documentRange.location, offsetBy: offset)!),
                                     type: .standard, options: []) { _, frame, _, _ in
            found = frame
            return false
        }
        return found
    }

    /// Where the text column starts in the text container: at its left edge, or in the middle
    /// of one that is the wider page (a text with a table in a wide window).
    var columnOrigin: CGFloat { textView.columnLeft - textView.textContainerOrigin.x }

    /// Distance of the character at `offset` from the left edge of the text column.
    func columnX(at offset: Int) -> CGFloat {
        characterRect(at: offset).minX - textView.columnLeft
    }

    /// `rect`, given in the coordinates of the fragment at `offset`, in text column coordinates.
    func inColumn(_ rect: CGRect, ofFragmentAt offset: Int) -> CGRect {
        let frame = fragment(at: offset).layoutFragmentFrame
        return rect.offsetBy(dx: frame.minX - columnOrigin, dy: frame.minY)
    }

    /// What is wrong with the paragraphs on screen, without asking TextKit to lay anything out:
    /// one that the view draws from a layout TextKit no longer has (it was asked for again after
    /// the view's layout), one without a layout, or one that shows raw. Nil when the views draw
    /// TextKit's own paragraphs, laid out and rendered.
    /// The fragment a paragraph's view draws is read through `element`, a private accessor of
    /// AppKit's `_NSTextViewportElementView`; a system without it fails here by name.
    var paintProblem: String? {
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return "nothing is laid out for the window" }
        var current = Set<ObjectIdentifier>(), problem: String?
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            current.insert(ObjectIdentifier(fragment))
            let text = (fragment.textElement as? NSTextParagraph)?.attributedString
            if fragment.state != .layoutAvailable {
                problem = "\((text?.string ?? "").debugDescription) has no layout"
            } else if let text, text.length > 0, text.attribute(.glyphLift, at: 0, effectiveRange: nil) == nil {
                problem = "\(text.string.debugDescription) shows raw"
            }
            return problem == nil
        }
        if let problem { return problem }
        var views: [NSView] = [textView]
        var drawn = 0
        while let view = views.popLast() {
            views += view.subviews
            guard view.className == "_NSTextViewportElementView" else { continue }
            guard view.responds(to: NSSelectorFromString("element")), let fragment = view.value(forKey: "element") as? NSTextLayoutFragment else {
                return "a paragraph's view does not tell what it draws"
            }
            drawn += 1
            if !current.contains(ObjectIdentifier(fragment)) {
                return "\(((fragment.textElement as? NSTextParagraph)?.attributedString.string ?? "").debugDescription) is drawn from a layout that is gone"
            }
        }
        return drawn == 0 ? "no paragraph has a view" : nil
    }

    /// The text view as drawn, with a probe that tells painted pixels from the page background.
    func pixels() -> (isBackground: (_ columnX: CGFloat, _ columnY: CGFloat) -> Bool, color: (CGFloat, CGFloat) -> NSColor) {
        let bitmap = textView.bitmapImageRepForCachingDisplay(in: textView.bounds)!
        textView.cacheDisplay(in: textView.bounds, to: bitmap)
        // The pixels of a picture are made off the main thread when it is first drawn, and arrive through the run loop.
        for _ in 0..<400 where editor.isDecodingImages { pump(0.005) }
        pump(0.01)
        textView.cacheDisplay(in: textView.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / textView.bounds.width, origin = NSPoint(x: textView.columnLeft, y: textView.textContainerOrigin.y)
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor {
            bitmap.colorAt(x: Int((origin.x + x) * scale), y: Int((origin.y + y) * scale))!.usingColorSpace(.sRGB)!
        }
        let corner = bitmap.colorAt(x: 2, y: 2)!.usingColorSpace(.sRGB)!
        return ({ x, y in
            let c = color(x, y)
            return abs(c.redComponent - corner.redComponent) + abs(c.greenComponent - corner.greenComponent)
                + abs(c.blueComponent - corner.blueComponent) < 0.01
        }, color)
    }

    /// The storage must stay plain: nothing but the base font, colour and paragraph style that a
    /// plain-text NSTextView keeps on its text. Nil when that holds.
    var storageProblem: String? {
        let storage = textView.textStorage!, theme = Theme.standard
        var problem: String?
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, stop in
            let style = attributes[.paragraphStyle] as? NSParagraphStyle
            let isPlain = Set(attributes.keys).isSubset(of: [.font, .foregroundColor, .paragraphStyle])
                && attributes[.font] as? NSFont == theme.bodyFont && attributes[.foregroundColor] as? NSColor == theme.text
                && (style == nil || style == textView.defaultParagraphStyle)
            if !isPlain {
                problem = "\(range): \(attributes)"
                stop.pointee = true
            }
        }
        return problem
    }
}

/// Typographic width of `text` on one line, measured outside the text view.
func referenceWidth(_ text: NSAttributedString) -> CGFloat {
    CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)
}

/// Answers every web request of the test process itself, so that no test reaches the network:
/// the bytes registered for a URL, or "not found". It also tells what was asked for, which is
/// how a test proves that nothing was.
nonisolated final class WebStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [URL: Data] = [:]
    /// The hosts whose requests are never answered: they are under way until they are cancelled.
    nonisolated(unsafe) static var heldHosts: Set<String> = []
    /// What a response says besides its bytes; one that has any may also be kept by a cache.
    nonisolated(unsafe) static var headers: [URL: [String: String]] = [:]
    /// The editor's own session takes the stub from `ImageCache.protocolClasses`; registered as
    /// well, it answers whatever else in the process asks the shared loader.
    private static let installed: Void = {
        URLProtocol.registerClass(WebStub.self)
        ImageCache.protocolClasses = [WebStub.self]
    }()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: [URL] = [], stopped: [URL] = [], cookies: [(URL, String?)] = []

    static func install() { installed }

    /// Every address the system's loader was asked for at `host`, before anything is sent
    /// anywhere, or at a host that `host` starts with: what a name being typed passes through.
    static func requests(to host: String) -> [URL] {
        lock.withLock { asked.filter { url in url.host.map { !$0.isEmpty && host.hasPrefix($0) } == true } }
    }

    /// The "Cookie" header of each request for `url` that was answered, in order.
    static func cookies(sentTo url: URL) -> [String?] {
        lock.withLock { cookies.filter { $0.0 == url }.map(\.1) }
    }

    /// The requests to `host` that were given up or finished.
    static func ended(at host: String) -> [URL] {
        lock.withLock { stopped.filter { $0.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard ["http", "https"].contains(request.url?.scheme) else { return false }
        if let url = request.url { lock.withLock { asked.append(url) } }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, !Self.heldHosts.contains(url.host ?? "") else { return }
        Self.lock.withLock { Self.cookies.append((url, request.value(forHTTPHeaderField: "Cookie"))) }
        let data = Self.responses[url], headers = Self.headers[url]
        let response = HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: headers == nil ? .notAllowed : .allowed)
        client?.urlProtocol(self, didLoad: data ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if let url = request.url { Self.lock.withLock { Self.stopped.append(url) } }
    }
}
