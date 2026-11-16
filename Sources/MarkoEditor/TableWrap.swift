import AppKit

// A WIDE TABLE'S CELLS WRAP. Its row stays one paragraph of the text. In the paragraph that is
// shown, every pipe between two cells is a line separator (U+2028, the same length), so each
// cell starts a line of its own, and each cell's part of the paragraph has a paragraph style of
// its own that indents its lines to its column (ParagraphRenderer.wrapCells). TextKit breaks and
// places the lines horizontally. Vertically it puts them below one another, cell after cell;
// every line but the row's first is given no height and that one the height of the cell with
// the most lines, so that the paragraph is as high as that cell (also to TextKit while it is not
// laid out), and BlockFragment draws every line where it belongs in the grid. What the text
// system then asks about lines by their place is answered here.
//
// This rests on behaviour that is observed, not documented (OSCanaryTests). The other way to
// do it, a text container that places the lines, is not used. MEASURED in an app built for
// macOS 26: a container that is not a simple rectangle takes away TextKit's estimates of the
// height of text that is not laid out (the view is as high as what has been scrolled through,
// 790 points for 3,000 paragraphs), and a line with an attachment grows by 3 points. An app
// built for macOS 13 behaves differently there.

/// The two places where TextKit 2 takes a paragraph's lines to stand below one another: finding the
/// line under a point, which is how the mouse selects, and telling where a caret or a selection is.
nonisolated final class GridLayoutManager: NSTextLayoutManager {
    /// Whether any table of the text shows with wrapping cells. Until one does, selections are left alone.
    var hasWrappedRows: (@MainActor () -> Bool)?

    /// Where the text column starts in the container, which is the wider page for a text with a table.
    var columnOrigin: (@MainActor () -> CGFloat)?

    /// The row whose cells wrap at `point`, in the container's coordinates, with its offset in the
    /// text. The empty line behind the text's last line break, which is laid out with the last
    /// row, is not the row's.
    func wrappedRow(at point: CGPoint) -> (fragment: BlockFragment, start: Int)? {
        guard let hasWrappedRows, MainActor.assumeIsolated({ hasWrappedRows() }), let content = textContentManager else { return nil }
        var found: BlockFragment?
        enumerateTextLayoutFragments(from: textLayoutFragment(for: CGPoint(x: 0, y: point.y))?.rangeInElement.location, options: []) {
            let frame = $0.layoutFragmentFrame
            if frame.minY <= point.y, point.y < frame.maxY {
                found = $0 as? BlockFragment
                return false
            }
            // A table's hidden delimiter row lies on the top edge of the row below it.
            return frame.height < 1 && frame.minY <= point.y
        }
        guard let found, found.wrappedRow != nil, point.y - found.layoutFragmentFrame.minY < found.ownHeight else { return nil }
        return (found, content.offset(from: content.documentRange.location, to: found.rangeInElement.location))
    }

    override func lineFragmentRange(for point: CGPoint, inContainerAt location: any NSTextLocation) -> NSTextRange? {
        guard let (row, _) = wrappedRow(at: point), let line = row.cellLine(at: point)?.line, let content = textContentManager,
              let start = content.location(row.rangeInElement.location, offsetBy: line.characterRange.location),
              let end = content.location(start, offsetBy: line.characterRange.length) else {
            return super.lineFragmentRange(for: point, inContainerAt: location)
        }
        return NSTextRange(location: start, end: end)
    }

    /// TextKit reports every caret and every piece of a selection in such a row where it has the
    /// line itself, and MEASURED: as if the line started at the row's left edge. Each piece is
    /// one line's; where it shows is read from that line in its cell. The range, which the text
    /// view does not ask for, is what tells the line.
    /// The empty line behind the text's last line break, and that of a text without any, is laid
    /// out by TextKit at the container's left edge whatever the paragraphs say: MEASURED, with
    /// the selection there it has the text view's typing attributes, which are the storage's.
    /// Where the column starts further in, the caret of that line is reported there.
    override func enumerateTextSegments(
        in textRange: NSTextRange, type: NSTextLayoutManager.SegmentType, options: NSTextLayoutManager.SegmentOptions = [],
        using block: (NSTextRange?, CGRect, CGFloat, NSTextContainer) -> Bool
    ) {
        let wraps = hasWrappedRows.map { isWrapping in MainActor.assumeIsolated { isWrapping() } } ?? false
        let origin = columnOrigin.map { origin in MainActor.assumeIsolated { origin() } } ?? 0
        guard wraps || origin > 0, let content = textContentManager else {
            return super.enumerateTextSegments(in: textRange, type: type, options: options, using: block)
        }
        let end = content.documentRange.endLocation
        let text = (content as? NSTextContentStorage)?.textStorage?.mutableString
        let endsWithEmptyLine = text.map { $0.length == 0 || CharacterSet.newlines.contains(UnicodeScalar($0.character(at: $0.length - 1)) ?? " ") } ?? false
        super.enumerateTextSegments(in: textRange, type: type, options: options.subtracting(.rangeNotRequired)) { range, rect, baseline, container in
            if origin > 0, endsWithEmptyLine, let range, range.isEmpty, range.location.compare(end) == .orderedSame {
                return block(range, rect.offsetBy(dx: origin - rect.minX, dy: 0), baseline, container)
            }
            guard wraps, let range, let row = textLayoutFragment(for: range.location) as? BlockFragment, row.wrappedRow != nil else {
                return block(range, rect, baseline, container)
            }
            let start = content.offset(from: row.rangeInElement.location, to: range.location)
            // A selection that goes on beyond a line is highlighted up to the cell's border, and
            // so is one that takes the row from its very start or to its very end.
            let isSelection = type == .selection
            let segment = row.cellSegment(
                NSRange(location: start, length: content.offset(from: range.location, to: range.endLocation)),
                fromEdge: isSelection && (start == 0 || textRange.location.compare(range.location) == .orderedAscending),
                toEdge: isSelection && (range.endLocation.compare(textRange.endLocation) == .orderedAscending
                    || range.endLocation.compare(row.rangeInElement.endLocation) == .orderedSame))
            return block(range, segment ?? rect, baseline, container)
        }
    }
}
