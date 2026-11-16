import AppKit

/// Covers the part of the view under a transparent titlebar and shows the window's title there,
/// small and centred. Below it the page colour fades out, so scrolled text slides under it.
final class Titlebar: NSView {
    private var observation: NSKeyValueObservation?
    var isEdited = false {
        didSet { needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        observation = window?.observe(\.title) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    /// The window's title, marked while the document has changes that are not saved.
    var title: String {
        guard let window else { return "" }
        return isEdited ? "\(window.title) — Edited" : window.title
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = Theme.standard
        let (fade, band) = bounds.divided(atDistance: theme.titlebarFadeHeight, from: .minYEdge)
        theme.background.setFill()
        band.fill()
        NSGradient(starting: theme.background.withAlphaComponent(0), ending: theme.background)?.draw(in: fade, angle: 90)

        // A hidden title is the window asking for this one instead of the system's beside the buttons.
        // A tab bar shows the titles itself.
        guard let window, window.titleVisibility == .hidden, window.tabGroup?.isTabBarVisible != true else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [.font: theme.titleFont, .foregroundColor: theme.mutedText, .paragraphStyle: style]
        let title = NSAttributedString(string: title, attributes: attributes)
        let size = title.size()
        guard size.height <= band.height else { return }
        // Level with the window buttons, which are not in the middle of a titlebar as high as a
        // toolbar's; clear of them on the left, and by as much on the right to stay centred.
        let middle = window.standardWindowButton(.closeButton).map { convert($0.bounds, from: $0).midY } ?? band.midY
        let room = NSRect(x: 0, y: middle - size.height / 2, width: bounds.width, height: size.height).insetBy(dx: theme.titleInset, dy: 0)
        // The name alone is centred and the mark of unsaved changes hangs to its right: the name
        // stays where it is when the first key brings the mark and a save takes it away. A title
        // too long for that is centred whole and cut in its middle.
        let left = (room.midX - NSAttributedString(string: window.title, attributes: attributes).size().width / 2).rounded()
        if left >= room.minX, left + size.width <= room.maxX {
            title.draw(at: NSPoint(x: left, y: room.minY))
        } else {
            title.draw(in: room)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Covers the foot of the view where the word count is, in a window too narrow for it to sit
/// beside the text: the text fades out above the readout instead of running under it.
final class Footer: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let theme = Theme.standard
        let (fade, band) = bounds.divided(atDistance: theme.titlebarFadeHeight, from: .maxYEdge)
        theme.background.setFill()
        band.fill()
        NSGradient(starting: theme.background, ending: theme.background.withAlphaComponent(0))?.draw(in: fade, angle: 90)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What a folder's window shows where the text would be while no file is chosen: the folder's
/// name and what to do next, in the middle of the page.
public final class EmptyPage: NSView {
    private let folder: String
    // True with the sidebar hidden too, where it says how to get it back.
    private let hint = "Select a file in the sidebar (⌘B), or press ⌘N for a new note"

    public init(folder: String) {
        self.folder = folder
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override func draw(_ dirtyRect: NSRect) {
        let theme = Theme.standard
        theme.background.setFill()
        bounds.fill()
        // A long name is cut in the middle; the hint is a sentence and goes onto a second line.
        let centred = NSMutableParagraphStyle(), cut = NSMutableParagraphStyle()
        centred.alignment = .center
        cut.alignment = .center
        cut.lineBreakMode = .byTruncatingMiddle
        let name = NSAttributedString(string: folder, attributes: [
            .font: theme.emptyPageNameFont, .foregroundColor: theme.mutedText, .paragraphStyle: cut,
        ])
        let hint = NSAttributedString(string: hint, attributes: [
            .font: theme.emptyPageHintFont, .foregroundColor: theme.mutedText, .paragraphStyle: centred,
        ])
        let column = bounds.insetBy(dx: theme.pagePadding.width, dy: 0)
        let nameHeight = name.size().height
        let hintHeight = ceil(hint.boundingRect(with: NSSize(width: column.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height)
        let top = bounds.midY + (nameHeight + theme.emptyPageGap + hintHeight) / 2
        name.draw(in: NSRect(x: column.minX, y: top - nameHeight, width: column.width, height: nameHeight))
        hint.draw(in: NSRect(x: column.minX, y: top - nameHeight - theme.emptyPageGap - hintHeight, width: column.width, height: hintHeight))
    }

    // What is drawn is text to accessibility too.
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityValue() -> Any? { "\(folder). \(hint)" }
}

/// The rounded backing of the word count. A click on it is a click on the text behind it,
/// except on the mark of safe mode, which is there to be pointed at.
final class Capsule: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.standard.statusBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) as? NSImageView }
}
