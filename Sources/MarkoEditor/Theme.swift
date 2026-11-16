import AppKit
import Synchronization

/// Every visual constant of the editor. Colours are dynamic, so the one value follows the system appearance.
public nonisolated struct Theme: Sendable {
    public static let standard = Theme()

    // MARK: view settings

    /// Posted when `zoom`, `showsWordCount` or `isFullWidth` changes; every editor follows. The app keeps them between launches.
    public static let didChange = Notification.Name("MarkoThemeDidChange")
    public static let zoomSteps: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    private static let settings = Mutex((zoom: CGFloat(1), showsWordCount: true, isFullWidth: false))

    /// The factor on every size of the page: text, spacing and the column's width.
    public static var zoom: CGFloat {
        get { settings.withLock { $0.zoom } }
        set {
            let zoom = min(max(newValue, zoomSteps[0]), zoomSteps[zoomSteps.count - 1])
            guard settings.withLock({ $0.zoom != zoom }) else { return }
            settings.withLock { $0.zoom = zoom }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    public static var showsWordCount: Bool {
        get { settings.withLock { $0.showsWordCount } }
        set {
            guard settings.withLock({ $0.showsWordCount != newValue }) else { return }
            settings.withLock { $0.showsWordCount = newValue }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Whether the text column is as wide as the window lets it be, instead of a width that reads well.
    public static var isFullWidth: Bool {
        get { settings.withLock { $0.isFullWidth } }
        set {
            guard settings.withLock({ $0.isFullWidth != newValue }) else { return }
            settings.withLock { $0.isFullWidth = newValue }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private var scale: CGFloat { Self.zoom }

    // MARK: page

    /// Content size of a new document window, and the smallest it can be resized to.
    public let windowSize = NSSize(width: 880, height: 900)
    public let minimumWindowSize = NSSize(width: 360, height: 240)
    /// How far to the right a new window opens of one that is exactly where it would be.
    public let windowCascadeStep: CGFloat = 28
    /// The widest the text column gets.
    var maximumTextWidth: CGFloat { Self.isFullWidth ? .greatestFiniteMagnitude : (780 * scale).rounded() }
    /// Where the text column starts in a text container of `width`: it stands in the middle of
    /// one that is wider than it, which is the page of a text with a table.
    func columnOrigin(inContainer width: CGFloat) -> CGFloat { max(0, ((width - maximumTextWidth) / 2).rounded(.down)) }
    /// Minimum space between the text column and the window edge, and the space above the text.
    let pagePadding = NSSize(width: 44, height: 40)
    /// The space below the text's end: enough to write there well clear of the window's edge.
    let pageBottomPadding: CGFloat = 160
    /// Height of the fade below the titlebar, where scrolled text disappears under it.
    let titlebarFadeHeight: CGFloat = 14
    let titleSize: CGFloat = 12
    /// Room left and right of the title in the titlebar; the window buttons are on the left.
    let titleInset: CGFloat = 80

    // MARK: colours

    public let background = dynamic(0xFCFCFB, 0x1D1E21)
    let text = dynamic(0x2A2C30, 0xDADCE0)
    let mutedText = dynamic(0x6F737A, 0x989CA4)
    /// Revealed syntax characters and other always-visible source markers.
    let marker = dynamic(0x9FA3AA, 0x6E727A)
    let hairline = dynamic(0xE2E3E5, 0x36383D)
    /// Fills behind code are translucent, because the selection is drawn underneath them.
    let codeBackground = overlay(0.065, 0.1)
    let accent = NSColor.controlAccentColor
    let link = tintedAccent((.black, 0.22), (.white, 0.42))
    /// Bullets and list numbers.
    let listMarker = dynamic(0x6A6E76, 0x8A8E96)
    let uncheckedBox = dynamic(0x9A9EA6, 0x777B83)
    let quoteText = dynamic(0x5C6068, 0xA9ADB5)
    let quoteBar = tintedAccent((.white, 0.45), (.white, 0.3))
    let codePanel = overlay(0.03, 0.04)
    /// Translucent like the code fills: the selection shows through a header or a striped row.
    let tableHeader = overlay(0.045, 0.07)
    let tableStripe = overlay(0.022, 0.035)
    /// A hairline around an image, so that one with the page's colour at its edge still has a shape.
    let imageBorder = overlay(0.08, 0.1)
    let codeComment = dynamic(0x9A9EA6, 0x858A93)
    let codeString = dynamic(0x2F7F58, 0x9ECE9A)
    let codeNumber = dynamic(0xB8621B, 0xF0A871)
    let codeKeyword = dynamic(0x9B3FBF, 0xC792EA)
    let selection = NSColor(name: nil) { appearance in
        NSColor.controlAccentColor.withAlphaComponent(isDark(appearance) ? 0.38 : 0.24)
    }

    // MARK: typography

    var bodySize: CGFloat { 16 * scale }
    var bodyLineHeight: CGFloat { (26 * scale).rounded() }
    /// How far the glyphs of a line of fixed height are drawn above where TextKit sets them,
    /// which is at the foot of the line: half of the height the font leaves spare.
    func glyphLift(of font: NSFont, lineHeight: CGFloat) -> CGFloat {
        max(0, ((lineHeight - (font.ascender - font.descender + font.leading)) / 2).rounded())
    }
    /// A blank source line is the gap between blocks, so it is shorter than a line of text.
    var blankLineHeight: CGFloat { (14 * scale).rounded() }
    /// Hidden syntax keeps its characters; at this size they take no visible width.
    let hiddenSize: CGFloat = 0.01

    /// By level. The last level is also muted.
    var headingSizes: [CGFloat] { [30, 24, 20, 18, 16, 14].map { $0 * scale } }
    let headingLineHeightMultiple: CGFloat = 1.3
    /// By level, like the sizes. More than the room below, so that a heading belongs to what follows it.
    var headingSpacingsBefore: [CGFloat] { [22, 22, 14, 14, 14, 14].map { ($0 * scale).rounded() } }
    var headingSpacingAfter: CGFloat { (2 * scale).rounded() }
    /// Levels up to this one get a hairline underneath.
    let ruledHeadingLevel = 2
    let hairlineWidth: CGFloat = 1
    /// Distance from the heading's last line to its hairline, and from the hairline to what follows.
    var hairlineGap: CGFloat { (5 * scale).rounded() }
    /// Size of a setext heading's underline characters while they are revealed, in the room of the hairline.
    var underlineFontSize: CGFloat { 11 * scale }

    var codeBlockFontSize: CGFloat { 14 * scale }
    var codeBlockLineHeight: CGFloat { (21 * scale).rounded() }
    /// Size of inline code relative to the text around it.
    let inlineCodeScale: CGFloat = 0.88
    var inlineCodeCornerRadius: CGFloat { 4 * scale }
    /// The room between the edge of the inline code background and its glyphs, which each hidden
    /// backtick takes up, and how much shorter than the line the background is.
    var inlineCodePadding: NSSize { NSSize(width: 3 * scale, height: 3 * scale) }

    // MARK: blocks

    /// How far each list level moves its content right; the marker hangs in this space.
    var listIndent: CGFloat { (26 * scale).rounded() }
    /// The character that stands for a bullet marker, by list depth; deeper lists use the last one.
    /// BlockFragment draws them as a disc, a ring and a square, which no font does well at text size.
    let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
    var bulletSize: CGFloat { 5.5 * scale }
    var bulletLineWidth: CGFloat { 1.25 * scale }
    /// What stands between a bullet and its text: an en space.
    let bulletGap = "\u{2002}"
    /// Point size of the checkbox symbol.
    var checkboxSize: CGFloat { 15 * scale }
    let checkboxSymbols = (unchecked: "square", checked: "checkmark.square.fill")
    let checkboxWeight = NSFont.Weight.medium
    /// The tick in a checked box, which is filled with the accent colour.
    let checkmark = NSColor.white
    /// How far each quote level moves its content right; the bar is at the left of this space.
    var quoteIndent: CGFloat { (18 * scale).rounded() }
    var quoteBarWidth: CGFloat { (3 * scale).rounded() }

    var codePanelCornerRadius: CGFloat { 7 * scale }
    /// Space between the panel's border and the code, left and right.
    var codePanelPadding: CGFloat { (14 * scale).rounded() }
    /// Space above and below a code block that has no fence lines to provide it.
    var codePanelInset: CGFloat { (8 * scale).rounded() }
    /// Space between the panel and the lines before and after it.
    var codePanelMargin: CGFloat { (4 * scale).rounded() }
    /// How far the continuation of a wrapped line of code is indented: about two characters.
    var codeWrapIndent: CGFloat { (17 * scale).rounded() }
    var fenceFontSize: CGFloat { 11 * scale }
    var fenceLineHeight: CGFloat { (24 * scale).rounded() }

    var ruleLineHeight: CGFloat { (26 * scale).rounded() }

    /// Space between a cell's border and its text.
    var tableCellPadding: NSSize { tableCellPadding(isCompact: false) }
    /// A table too wide for the window at the normal size is tried with smaller text and less padding.
    func tableCellPadding(isCompact: Bool) -> NSSize { NSSize(width: ((isCompact ? 6 : 12) * scale).rounded(), height: (5 * scale).rounded()) }
    var compactTableSize: CGFloat { 13 * scale }
    /// The least a column's text is given, so an empty column is still a place to click.
    var tableMinimumCellWidth: CGFloat { (24 * scale).rounded() }
    /// The least a column whose text wraps is given while the window has the room: some ten characters.
    var tableWrappingCellWidth: CGFloat { (72 * scale).rounded() }
    var tableCornerRadius: CGFloat { 7 * scale }
    /// Space between the grid and the lines before and after it.
    var tableMargin: CGFloat { (4 * scale).rounded() }

    let imageCornerRadius: CGFloat = 6
    /// The most of a small picture's height that a corner rounds off.
    let imageCornerFraction: CGFloat = 0.25
    let imagePlaceholderSymbols = (loading: "photo", missing: "photo.badge.exclamationmark", blocked: "shield")
    let imagePlaceholderSymbolWeight = NSFont.Weight.regular
    /// The most of a small placeholder's height that its symbol takes.
    let imagePlaceholderSymbolFraction: CGFloat = 0.6
    /// A placeholder at least this many times as high as its symbol has room for a label under it.
    let imagePlaceholderLabelRoom: CGFloat = 3
    /// What stands for an image that is loading or cannot be found: on a line of its own, and (a
    /// square) inside a line of text.
    var imagePlaceholderSize: NSSize { NSSize(width: (300 * scale).rounded(), height: (120 * scale).rounded()) }
    var inlineImagePlaceholderSize: CGFloat { (18 * scale).rounded() }
    var imagePlaceholderSymbolSize: CGFloat { 22 * scale }
    /// The line under an image on a line of its own, where its source shows while the selection touches it.
    var imageCaptionLineHeight: CGFloat { (18 * scale).rounded() }
    /// Above such an image: as much as its source line takes below it, so that it stands in the
    /// middle of the room it has.
    var imageSpacingBefore: CGFloat { imageCaptionLineHeight }

    /// The room kept above and below a selection that is scrolled into view: two lines of text.
    var scrollMargin: CGFloat { 2 * bodyLineHeight }

    // MARK: sidebar

    /// The file tree's width in a new window, and how far it can be dragged.
    public let sidebarWidth: CGFloat = 230
    public let sidebarWidthRange: ClosedRange<CGFloat> = 170...460
    let sidebarRowHeight: CGFloat = 26
    let sidebarIndent: CGFloat = 14
    let sidebarSymbols = (folder: "folder", markdown: "doc.text", file: "doc", locked: "lock")
    let sidebarSymbolSize: CGFloat = 13
    /// Between a row's symbol and its name; the symbols differ in width and are centred in a box this wide.
    let sidebarSymbolWidth: CGFloat = 20
    let sidebarSymbolGap: CGFloat = 5
    let sidebarFolderTint = NSColor.secondaryLabelColor
    /// Markdown files are what the tree is for; everything else stands back. The values are the
    /// system's label colours, but not those colours themselves. MEASURED: the selected row of a
    /// tree without the keyboard draws a system label colour in the accent colour, which is dim on
    /// the dark panel (3.2:1).
    let sidebarMarkdownText = overlay(1, 1)
    let sidebarOtherText = overlay(0.29, 0.25)
    /// A name on the highlight of the row that has the keyboard.
    let sidebarHighlightedText = NSColor.alternateSelectedControlTextColor
    var sidebarFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
    /// The name of the file the editor shows.
    var sidebarCurrentFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }
    /// The folder's name at the head of the panel.
    var sidebarHeaderFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold) }
    let sidebarHeaderText = NSColor.secondaryLabelColor
    /// Between the window buttons and the folder's name, and between the name and the panel's edge.
    let sidebarHeaderGap: CGFloat = 12
    /// What the panel says in place of a tree it does not have: a title and, smaller below it,
    /// what to do. Kept clear of the panel's edges by the inset.
    let sidebarPlaceholderText = NSColor.secondaryLabelColor
    let sidebarHintText = NSColor.tertiaryLabelColor
    var sidebarPlaceholderFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize, weight: .medium) }
    var sidebarHintFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }
    let sidebarPlaceholderInset: CGFloat = 20
    /// How long changes on disk are collected before the tree looks at them.
    let sidebarRefreshDelay: TimeInterval = 0.2

    // MARK: status

    /// The line under the app's name in the About panel.
    public var aboutFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }
    public let aboutText = NSColor.secondaryLabelColor

    let statusSize: CGFloat = 11
    /// From the window's corner to the readout's capsule.
    let statusInset = NSSize(width: 12, height: 10)
    /// Between the capsule's edge and its text.
    let statusPadding = NSSize(width: 8, height: 3)
    /// Between the mark of safe mode and the word count.
    let statusGap: CGFloat = 5
    let safeModeSymbol = "shield.lefthalf.filled"
    /// How many characters of a folder's path the question about trust and the menus show; a
    /// longer one is cut in the middle.
    public let shownPathLength = 72
    /// The folder's path under the question about trust: one line as wide as the sheet's text,
    /// in the type of a path and not of the question.
    public var promptPathFont: NSFont { .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) }
    public let promptPathWidth: CGFloat = 220
    /// Translucent, so text scrolling under the readout stays visible but does not fight with it.
    let statusBackground = dynamic(0xFCFCFB, 0x1D1E21, alpha: 0.85)

    // NSFont is not Sendable, so the fonts are made on demand; AppKit caches them.
    var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    var hiddenFont: NSFont { .systemFont(ofSize: hiddenSize) }
    /// For the hidden backticks of inline code: each is as wide as the background's padding.
    var inlineCodeEdgeFont: NSFont { codeFont(size: inlineCodePadding.width / codeFont(size: 1).maximumAdvancement.width) }
    var tableHeaderFont: NSFont { tableFont(isHeader: true, isCompact: false) }
    /// Digits of equal width, so the figures of a column line up.
    func tableFont(isHeader: Bool, isCompact: Bool) -> NSFont {
        .monospacedDigitSystemFont(ofSize: isCompact ? compactTableSize : bodySize, weight: isHeader ? .semibold : .regular)
    }
    /// The source of an image, under it.
    var captionFont: NSFont { codeFont(size: fenceFontSize) }
    var placeholderFont: NSFont { .systemFont(ofSize: statusSize * scale) }
    var statusFont: NSFont { .systemFont(ofSize: statusSize) }
    var titleFont: NSFont { .systemFont(ofSize: titleSize, weight: .medium) }
    /// A folder's window without a file: the folder's name, and under it what to do.
    var emptyPageNameFont: NSFont { .systemFont(ofSize: 22, weight: .semibold) }
    var emptyPageHintFont: NSFont { .systemFont(ofSize: 13) }
    let emptyPageGap: CGFloat = 8
    var underlineFont: NSFont { codeFont(size: underlineFontSize) }
    /// The height of a setext underline line, hidden or revealed: a hairline with its gaps.
    var underlineLineHeight: CGFloat { hairlineWidth + 2 * hairlineGap }

    /// Digits of equal width, so the numbers of an ordered list line up.
    var orderedMarkerFont: NSFont { .monospacedDigitSystemFont(ofSize: bodySize, weight: .regular) }

    func headingFont(level: Int) -> NSFont {
        .systemFont(ofSize: headingSizes[min(max(level, 1), headingSizes.count) - 1], weight: level <= ruledHeadingLevel ? .bold : .semibold)
    }

    func codeFont(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Black over the light background or white over the dark one, at the given opacity.
    private static func overlay(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        }
    }

    /// The system accent colour mixed with another, given as (colour, fraction) for light and for
    /// dark: as it comes it is too pale for text on the light page and too dim on the dark one.
    private static func tintedAccent(_ light: (NSColor, CGFloat), _ dark: (NSColor, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let (other, fraction) = isDark(appearance) ? dark : light
            var accent = NSColor.controlAccentColor
            appearance.performAsCurrentDrawingAppearance { accent = accent.usingColorSpace(.sRGB) ?? accent }
            return accent.blended(withFraction: fraction, of: other) ?? accent
        }
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = isDark(appearance) ? dark : light
            return NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
    }
}
