import AppKit
import MarkoCore

/// One quote level's bar on one line.
nonisolated struct QuoteBar: Hashable {
    /// From the column's left edge.
    var x: CGFloat
    /// The quote's first or last line, where the bar gets its rounded end.
    var isFirst: Bool
    var isLast: Bool
}

/// One line's part of the panel behind a code block.
nonisolated struct CodePanel: Hashable {
    /// From the column's left edge.
    var x: CGFloat
    /// How far the panel's closed top or bottom edge lies beyond the line's text; nil where the panel carries on.
    var top: CGFloat?
    var bottom: CGFloat?
}

/// How a table shows as a grid.
nonisolated struct TableGrid: Equatable {
    /// The column edges, from the text column's left edge: to the left of it, below zero, where
    /// a grid wider than the column stands in the middle of the page.
    var edges: [CGFloat]
    /// At the smaller size a table gets when it would not fit the window otherwise.
    var isCompact: Bool
    /// A table too wide for the window even then: its cells' text wraps in columns that share the room.
    var wraps = false
}

/// What all lines of a table are shown from, besides their own text: the table's lines in the
/// map, its columns' alignments and its grid, nil while it shows as source.
nonisolated struct TableLook: Equatable {
    var lines: Range<Int>
    var alignments: [ColumnAlignment]
    var grid: TableGrid?
}

/// One row's part of a table's grid.
nonisolated struct TableRow: Hashable {
    /// The column edges, from the text column's left edge.
    var edges: [CGFloat]
    /// The first and the last row close the grid with its rounded corners.
    var isHeader: Bool
    var isLast: Bool
    var isStriped: Bool
    /// In a grid whose cells wrap: where each cell's first line starts in the row's paragraph.
    /// Empty in a grid of single lines.
    var cellStarts: [Int] = []
    /// And how many lines the renderer counted for each cell, which it made the row high for.
    var lineCounts: [Int] = []
}

/// What is drawn where an image's attachment makes room for it.
nonisolated struct ShownImage {
    /// Nil while the image is loading or when it cannot be found.
    var image: ImageCache.Picture?
    var isMissing = false
    /// Not fetched, because the document is in safe mode: a click on it fetches.
    var isBlocked = false
    /// What a placeholder says: the image's description or file name.
    var label = ""
    /// The size it is drawn at, from the left end of its room.
    var size: CGSize
    /// How far its lower edge is below the line's baseline.
    var drop: CGFloat = 0
    /// Standing on top of its line, in the paragraph's spacing, instead of on the baseline.
    var isAboveLine = false
}

nonisolated extension NSAttributedString.Key {
    /// Display-paragraph attribute: the image (ShownImage) drawn by BlockFragment over the attachment
    /// character that stands for an image's "!".
    static let picture = NSAttributedString.Key("MarkoPicture")
    /// Display-paragraph attribute: a rounded fill (NSColor) behind the run, drawn by BlockFragment.
    static let inlineBackground = NSAttributedString.Key("MarkoInlineBackground")
    /// Display-paragraph attribute: the list depth (Int) of a bullet, on the invisible character that
    /// stands for it. BlockFragment draws the bullet's shape there.
    static let bullet = NSAttributedString.Key("MarkoBullet")
    /// Display-paragraph attribute: a hairline (NSColor) under the paragraph, drawn by BlockFragment.
    static let hairline = NSAttributedString.Key("MarkoHairline")
    /// Display-paragraph attribute: a hairline (NSColor) through the middle of the line, drawn by BlockFragment.
    static let rule = NSAttributedString.Key("MarkoRule")
    /// Display-paragraph attribute: the bars ([QuoteBar]) of the quotes the line is in, drawn by BlockFragment.
    static let quoteBars = NSAttributedString.Key("MarkoQuoteBars")
    /// Display-paragraph attribute: the line's part (CodePanel) of a code block's panel, drawn by BlockFragment.
    static let codePanel = NSAttributedString.Key("MarkoCodePanel")
    /// Display-paragraph attribute: the line's part (TableRow) of a table's grid, drawn by BlockFragment.
    static let tableRow = NSAttributedString.Key("MarkoTableRow")
    /// Display-paragraph attribute: how far (CGFloat) BlockFragment draws the text above where TextKit puts it.
    static let glyphLift = NSAttributedString.Key("MarkoGlyphLift")
}

/// Draws the decoration that text attributes cannot, behind normally laid-out text. What to draw is
/// read from the display paragraph, so ParagraphRenderer stays the only place that decides it.
/// All rectangles are in the fragment's own coordinates.
nonisolated final class BlockFragment: NSTextLayoutFragment {
    private let theme = Theme.standard

    private func attribute<Value>(_ key: NSAttributedString.Key) -> Value? {
        guard let paragraph = (textElement as? NSTextParagraph)?.attributedString, paragraph.length > 0 else { return nil }
        return paragraph.attribute(key, at: 0, effectiveRange: nil) as? Value
    }

    /// The paragraph's own lines. The document's last paragraph also carries the empty line after its terminator.
    private var lines: [NSTextLineFragment] {
        textLineFragments.filter { $0.characterRange.length > 0 }
    }

    /// The width of the text container. In a window wider than the text column it is the whole
    /// page with the column in its middle, which is room for a wide table's grid.
    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// The text container's left edge, which is what a paragraph style's indents are from.
    private var containerLeft: CGFloat { -layoutFragmentFrame.minX }

    /// The text column, as high as the paragraph's own lines and spacing.
    private var column: CGRect {
        let width = min(containerWidth, theme.maximumTextWidth)
        let extra = textLineFragments.last.flatMap { $0.characterRange.length == 0 && textLineFragments.count > 1 ? $0 : nil }
        return CGRect(x: containerLeft + theme.columnOrigin(inContainer: containerWidth), y: 0, width: width,
                      height: extra?.typographicBounds.minY ?? layoutFragmentFrame.height)
    }

    /// How high the paragraph is without the empty line behind the text's last line break.
    var ownHeight: CGFloat { column.height }

    /// The column from where the paragraph's own lines start, past list and quote indentation.
    private var indentedColumn: CGRect {
        let left = containerLeft + ((attribute(.paragraphStyle) as NSParagraphStyle?)?.headIndent ?? 0)
        return CGRect(x: left, y: 0, width: column.maxX - left, height: column.height)
    }

    var hairlineRect: CGRect? {
        guard attribute(.hairline) as NSColor? != nil, let last = lines.last else { return nil }
        let y = (last.typographicBounds.maxY + theme.hairlineGap).rounded()
        return CGRect(x: indentedColumn.minX, y: y, width: indentedColumn.width, height: theme.hairlineWidth)
    }

    var ruleRect: CGRect? {
        guard attribute(.rule) as NSColor? != nil, let line = lines.first else { return nil }
        let y = (line.typographicBounds.midY - theme.hairlineWidth / 2).rounded()
        return CGRect(x: indentedColumn.minX, y: y, width: indentedColumn.width, height: theme.hairlineWidth)
    }

    var quoteBarRects: [CGRect] {
        (attribute(.quoteBars) as [QuoteBar]? ?? []).map {
            CGRect(x: column.minX + $0.x, y: 0, width: theme.quoteBarWidth, height: column.height)
        }
    }

    var codePanelRect: CGRect? {
        guard let panel: CodePanel = attribute(.codePanel), let first = lines.first, let last = lines.last else {
            return nil
        }
        let top = panel.top.map { first.typographicBounds.minY - $0 } ?? 0
        let bottom = panel.bottom.map { last.typographicBounds.maxY + $0 } ?? column.height
        return CGRect(x: column.minX + panel.x, y: top, width: column.width - panel.x, height: bottom - top)
    }

    /// The row's cells with their padding. Rows meet without a gap. In a grid of single lines that
    /// is the row's line; where the cells wrap, the padding above and below the cell with the most lines.
    var tableRowRect: CGRect? {
        guard let row: TableRow = attribute(.tableRow), let left = row.edges.first, let right = row.edges.last,
              let line = lines.first else { return nil }
        var (top, bottom) = (line.typographicBounds.minY, line.typographicBounds.maxY)
        if !row.cellStarts.isEmpty {
            let padding = theme.tableCellPadding.height
            top = row.isHeader ? theme.tableMargin : 0
            bottom = (cellLines.map(\.box.maxY).max() ?? top + padding) + padding
        }
        return CGRect(x: column.minX + left, y: top, width: right - left, height: bottom - top)
    }

    // MARK: a row whose cells wrap
    //
    // See TableWrap.swift. The text system has broken each cell's lines and put them at the
    // cell's place from left to right, but one below the other through all cells, most of them
    // without a height. Where each line shows in the grid is worked out here, and whatever asks
    // for a line by its place is answered from that.

    /// The row's part of a grid whose cells wrap; nil for every other paragraph.
    var wrappedRow: TableRow? {
        guard let row: TableRow = attribute(.tableRow), !row.cellStarts.isEmpty else { return nil }
        return row
    }

    /// The lines of a row whose cells wrap, each with the cell it is in and the box it shows in,
    /// in the fragment's coordinates: a cell's lines below one another from the cell's padding down.
    private var cellLines: [(line: NSTextLineFragment, cell: Int, box: CGRect)] {
        guard let row = wrappedRow else { return [] }
        let top = theme.tableCellPadding.height + (row.isHeader ? theme.tableMargin : 0), height = theme.bodyLineHeight
        var counts = [Int](repeating: 0, count: row.cellStarts.count)
        return lines.map { line in
            let cell = row.cellStarts.lastIndex { $0 <= line.characterRange.location } ?? 0, bounds = line.typographicBounds
            defer { counts[cell] += 1 }
            return (line, cell, CGRect(x: bounds.minX, y: top + CGFloat(counts[cell]) * height, width: bounds.width, height: height))
        }
    }

    /// Whether the row is as high as its cell with the most lines needs: the renderer made it
    /// so from the lines it counted for each cell.
    var fitsItsCells: Bool {
        guard let row = tableRowRect, wrappedRow != nil else { return true }
        return abs(row.maxY + (wrappedRow?.isLast == true ? theme.tableMargin : 0) - column.height) < 0.5
    }

    /// How many lines each cell of a row of wrapping cells was laid out with.
    var cellLineCounts: [Int] {
        cellLines.reduce(into: [Int](repeating: 0, count: wrappedRow?.cellStarts.count ?? 0)) { $0[$1.cell] += 1 }
    }

    /// The box a line of the paragraph shows in, in the fragment's coordinates.
    private func box(of line: NSTextLineFragment) -> CGRect {
        cellLines.first { $0.line === line }?.box ?? line.typographicBounds
    }

    /// What the fragment's coordinates are from, in the text container's.
    private var origin: CGPoint { layoutFragmentFrame.origin }

    /// The line of the cell under `point`, in the container's coordinates, with its box in the
    /// fragment's: of that cell's lines the one at the point's height, or the nearest.
    func cellLine(at point: CGPoint) -> (line: NSTextLineFragment, box: CGRect)? {
        guard let row = wrappedRow else { return nil }
        let x = point.x - origin.x - column.minX
        let cell = min(max(row.edges.dropLast().count { $0 <= x } - 1, 0), row.cellStarts.count - 1)
        let own = cellLines.filter { $0.cell == cell }
        return (own.first { point.y - origin.y < $0.box.maxY } ?? own.last).map { ($0.line, $0.box) }
    }

    /// Where the characters in `range` of the paragraph show, which are all on one line, in the
    /// container's coordinates: the line's height, from the first of them to the last, or with
    /// `fromEdge` and `toEdge` from and to the cell's borders, as a selection that goes on beyond
    /// the line shows: sideways, and from a cell's first line up and from its last line down to
    /// the row's, so that cells that are selected whole are filled whole. An empty range is a
    /// caret's place.
    func cellSegment(_ range: NSRange, fromEdge: Bool = false, toEdge: Bool = false) -> CGRect? {
        // The empty line behind the text's last line break is in no cell.
        guard let row = wrappedRow,
              let line = textLineFragments.first(where: { range.location < NSMaxRange($0.characterRange) }) ?? textLineFragments.last else { return nil }
        let all = cellLines, shown = all.first { $0.line === line }, box = shown?.box ?? line.typographicBounds
        let text = (textElement as? NSTextParagraph)?.attributedString.string as NSString?, end = NSMaxRange(line.characterRange)
        /// MEASURED: a character without width that follows a blank at a line's end is reported
        /// at the line's start. What is hidden stands where the next character that shows does.
        func x(_ index: Int) -> CGFloat {
            var index = min(index, end)
            while index < end, let text, [0x2060, 0x200C].contains(text.character(at: index)) { index += 1 }
            return box.minX + line.locationForCharacter(at: index).x
        }
        var (left, right, top, bottom) = (x(range.location), x(NSMaxRange(range)), box.minY, box.maxY)
        if let cell = shown?.cell, cell + 1 < row.edges.count, let whole = tableRowRect {
            if fromEdge {
                left = column.minX + row.edges[cell] + theme.hairlineWidth
                if all.first(where: { $0.cell == cell })?.line === line { top = whole.minY }
            }
            if toEdge {
                right = column.minX + row.edges[cell + 1]
                if all.last(where: { $0.cell == cell })?.line === line { bottom = whole.maxY }
            }
        }
        return CGRect(x: left, y: top, width: max(right - left, 0), height: bottom - top).offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The column that the character at `index` of the paragraph is in and, top to bottom, the
    /// boxes of the lines of the cell in `column`, or else in that one, in the container's coordinates.
    func cellBoxes(holding index: Int, inColumn column: Int? = nil) -> (column: Int, boxes: [CGRect])? {
        let all = cellLines
        guard let own = all.first(where: { index < NSMaxRange($0.line.characterRange) }) ?? all.last else { return nil }
        let column = min(column ?? own.cell, (wrappedRow?.cellStarts.count ?? 1) - 1)
        return (column, all.filter { $0.cell == column }.map { $0.box.offsetBy(dx: origin.x, dy: origin.y) })
    }

    /// The index in the paragraph of the character under `point`, in the container's coordinates,
    /// nil where no line is; or with `forInsertion` of the caret position nearest to the point in
    /// the cell it is over, never behind the character that ends a line and never among the
    /// hidden blanks a cell starts with. A line that ends by wrapping has no place behind its
    /// last character either, which is the blank it wraps at: that place is the start of the
    /// next line, and shows there.
    func characterIndex(at point: CGPoint, forInsertion: Bool) -> Int? {
        guard let (line, box) = cellLine(at: point), let text = (textElement as? NSTextParagraph)?.attributedString.string as NSString? else { return nil }
        let local = CGPoint(x: point.x - origin.x - box.minX, y: line.typographicBounds.height / 2)
        var index = line.characterIndex(for: local)
        guard forInsertion else { return box.offsetBy(dx: origin.x, dy: origin.y).contains(point) ? index : nil }
        let start = line.characterRange.location, end = NSMaxRange(line.characterRange)
        if index < end, line.fractionOfDistanceThroughGlyph(for: local) > 0.5 { index += 1 }
        if index == end, index > start, end < text.length || [0x0A, 0x0D].contains(text.character(at: index - 1)) {
            index = text.rangeOfComposedCharacterSequence(at: index - 1).location
            if index > start, text.character(at: index) == 0x0A, text.character(at: index - 1) == 0x0D { index -= 1 }
        }
        while index < end, text.character(at: index) == 0x2060 { index += 1 }
        return index
    }

    /// The bullets of the list items that start on this line, with their list depth.
    var bullets: [(rect: CGRect, depth: Int)] {
        guard let paragraph = (textElement as? NSTextParagraph)?.attributedString, let line = lines.first else { return [] }
        var result: [(CGRect, Int)] = []
        paragraph.enumerateAttribute(.bullet, in: line.characterRange) { value, range, _ in
            guard let depth = value as? Int else { return }
            let left = line.locationForCharacter(at: range.location).x, right = line.locationForCharacter(at: NSMaxRange(range)).x
            let bounds = box(of: line), size = theme.bulletSize
            // Centred on the lowercase letters of the text beside it, which stands at the foot of its line's own box.
            let y = bounds.maxY - line.typographicBounds.height + line.glyphOrigin.y - theme.bodyFont.xHeight / 2 - (attribute(.glyphLift) ?? 0)
            result.append((CGRect(x: bounds.minX + (left + right - size) / 2, y: y - size / 2, width: size, height: size), depth))
        }
        return result
    }

    /// The images on this paragraph's lines, each standing on its line's baseline or on top of the line.
    var pictures: [(rect: CGRect, picture: ShownImage)] {
        guard let paragraph = (textElement as? NSTextParagraph)?.attributedString else { return [] }
        var result: [(CGRect, ShownImage)] = []
        paragraph.enumerateAttribute(.picture, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
            guard let picture = value as? ShownImage,
                  let line = lines.first(where: { NSLocationInRange(range.location, $0.characterRange) }) else { return }
            let bounds = line.typographicBounds
            let bottom = picture.isAboveLine ? bounds.minY : bounds.minY + line.glyphOrigin.y - (attribute(.glyphLift) ?? 0) + picture.drop
            let left = picture.isAboveLine ? indentedColumn.minX : bounds.minX + line.locationForCharacter(at: range.location).x
            result.append((CGRect(x: left, y: bottom - picture.size.height, width: picture.size.width, height: picture.size.height), picture))
        }
        return result
    }

    /// From the end of what can be selected on this paragraph's lines, which is the column's edge
    /// or a grid's, to the container's. The selection is drawn underneath the text and runs on
    /// from a line's end to the container's edge; here the page covers it.
    private var besideText: CGRect {
        let start = tableRowRect?.maxX ?? column.maxX
        return CGRect(x: start, y: 0, width: max(0, containerLeft + containerWidth - start), height: layoutFragmentFrame.height)
    }

    /// And from the container's edge to where it starts: the column's edge, or that of a grid
    /// that begins further left. A line that is selected whole is highlighted from the container's edge.
    private var beforeText: CGRect {
        let end = min(tableRowRect?.minX ?? column.minX, column.minX)
        return CGRect(x: containerLeft, y: 0, width: max(0, end - containerLeft), height: layoutFragmentFrame.height)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(column).union(besideText).union(beforeText).union(codePanelRect ?? .null).union(tableRowRect ?? .null)
            .insetBy(dx: 0, dy: -(theme.hairlineGap + theme.hairlineWidth))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        func placed(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: point.x, dy: point.y) }

        context.setFillColor(theme.background.cgColor)
        context.fill(placed(besideText))
        context.fill(placed(beforeText))

        if let rect = codePanelRect, let panel: CodePanel = attribute(.codePanel) {
            drawOpenEnded(placed(rect), radius: theme.codePanelCornerRadius, closedTop: panel.top != nil, closedBottom: panel.bottom != nil,
                          fill: theme.codePanel, stroke: theme.hairline, in: context)
        }
        if let rect = tableRowRect, let row: TableRow = attribute(.tableRow) {
            let slice = placed(rect), width = theme.hairlineWidth
            drawOpenEnded(slice, radius: theme.tableCornerRadius, closedTop: row.isHeader, closedBottom: row.isLast,
                          fill: row.isHeader ? theme.tableHeader : row.isStriped ? theme.tableStripe : nil, stroke: theme.hairline, in: context)
            context.setFillColor(theme.hairline.cgColor)
            for edge in row.edges.dropFirst().dropLast() {
                context.fill(CGRect(x: point.x + column.minX + edge, y: slice.minY, width: width, height: slice.height))
            }
            if !row.isLast { context.fill(CGRect(x: slice.minX, y: slice.maxY - width, width: slice.width, height: width)) }
        }
        for (rect, bar) in zip(quoteBarRects, attribute(.quoteBars) as [QuoteBar]? ?? []) {
            drawOpenEnded(placed(rect), radius: theme.quoteBarWidth / 2, closedTop: bar.isFirst, closedBottom: bar.isLast,
                          fill: theme.quoteBar, stroke: nil, in: context)
        }
        drawInlineBackgrounds(at: point, in: context)
        for (rect, picture) in pictures { draw(picture, in: placed(rect), context) }
        context.setFillColor(theme.listMarker.cgColor)
        context.setStrokeColor(theme.listMarker.cgColor)
        context.setLineWidth(theme.bulletLineWidth)
        for (rect, depth) in bullets {
            switch depth {
            case 1: context.fillEllipse(in: placed(rect))
            case 2: context.strokeEllipse(in: placed(rect).insetBy(dx: theme.bulletLineWidth / 2, dy: theme.bulletLineWidth / 2))
            default: context.fill(placed(rect).insetBy(dx: theme.bulletLineWidth / 2, dy: theme.bulletLineWidth / 2))
            }
        }
        for (rect, key) in [(hairlineRect, NSAttributedString.Key.hairline), (ruleRect, .rule)] {
            guard let rect, let color: NSColor = attribute(key) else { continue }
            context.setFillColor(color.cgColor)
            context.fill(placed(rect))
        }
        // MEASURED: a paragraph that shows raw until its parse (a large text, a quarter of a
        // second) is body text in a body line. Without the lift it stood 3 pt lower, and moved up
        // with the parse.
        let lift: CGFloat = attribute(.glyphLift) ?? theme.glyphLift(of: theme.bodyFont, lineHeight: theme.bodyLineHeight)
        guard wrappedRow != nil else { return super.draw(at: CGPoint(x: point.x, y: point.y - lift), in: context) }
        // Each line where it shows in the grid. The text stands at the foot of a line's own box, however high that is.
        // `EditorController.refit` has such a row rendered again before it is drawn.
        assert(fitsItsCells, "a row whose cells wrap is not as high as its tallest cell: the renderer counted other lines than were laid out")
        // Nothing of a line shows further below its box than the cell's padding. MEASURED: a line
        // without a height draws a spelling mark 18 pt below where it belongs (16 pt text), in
        // the line below or under the row. Marks are not set in such a row
        // (`suppressesSpelling`), but those set while the table showed on single lines stay.
        let surface = renderingSurfaceBounds
        for (line, _, box) in cellLines {
            context.saveGState()
            context.clip(to: placed(CGRect(x: surface.minX, y: surface.minY, width: surface.width, height: box.maxY + theme.tableCellPadding.height - surface.minY)))
            line.draw(at: CGPoint(x: point.x + box.minX, y: point.y + box.maxY - line.typographicBounds.height - lift), in: context)
            context.restoreGState()
        }
    }

    /// A rounded rectangle of which this fragment shows one slice: an end that is not closed runs on
    /// past the slice, where the neighbouring fragment draws its own.
    private func drawOpenEnded(
        _ slice: CGRect, radius: CGFloat, closedTop: Bool, closedBottom: Bool, fill: NSColor?, stroke: NSColor?, in context: CGContext
    ) {
        var shape = slice
        if !closedTop { shape = shape.insetBy(dx: 0, dy: -radius).offsetBy(dx: 0, dy: -radius) }
        if !closedBottom { shape.size.height += 2 * radius }
        context.saveGState()
        context.clip(to: slice)
        // MEASURED: a fill in the clear colour is still blended over the whole slice, a fifth
        // of the time it takes to draw a table row.
        if let fill {
            context.setFillColor(fill.cgColor)
            context.addPath(CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        if let stroke {
            let inset = theme.hairlineWidth / 2
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(theme.hairlineWidth)
            context.addPath(CGPath(roundedRect: shape.insetBy(dx: inset, dy: inset), cornerWidth: radius - inset,
                                   cornerHeight: radius - inset, transform: nil))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func draw(_ picture: ShownImage, in rect: CGRect, _ context: CGContext) {
        let radius = min(theme.imageCornerRadius, rect.height * theme.imageCornerFraction), inset = theme.hairlineWidth / 2
        let border = CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil)
        context.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer {
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
        }
        context.setLineWidth(theme.hairlineWidth)
        if let image = picture.image {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            // Fragments are drawn on the main thread, where the pictures are kept.
            let device = rect.applying(context.userSpaceToDeviceSpaceTransform)
            let (width, height) = (Int(device.width.rounded()), Int(device.height.rounded()))
            if let pixels = MainActor.assumeIsolated({ image.pixels(width: width, height: height) }) {
                context.saveGState()
                context.interpolationQuality = .high
                // The fragment's coordinates run downwards and an image's upwards.
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(pixels, in: CGRect(origin: .zero, size: rect.size))
                context.restoreGState()
            } else {
                // Its room, until its pixels are made.
                context.setFillColor(theme.codePanel.cgColor)
                context.fill(rect)
            }
            context.setStrokeColor(theme.imageBorder.cgColor)
            context.addPath(border)
            context.strokePath()
            return
        }
        context.setFillColor(theme.codePanel.cgColor)
        context.setStrokeColor(theme.hairline.cgColor)
        context.addPath(border)
        context.drawPath(using: .fillStroke)

        // The symbol, and under it the label where there is room for one.
        let label = NSAttributedString(string: picture.label, attributes: [
            .font: theme.placeholderFont, .foregroundColor: theme.mutedText,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.lineBreakMode = .byTruncatingMiddle
                return style
            }(),
        ])
        let hasLabel = rect.height > theme.imagePlaceholderLabelRoom * theme.imagePlaceholderSymbolSize && !picture.label.isEmpty
        let labelHeight = hasLabel ? label.size().height.rounded(.up) : 0
        let pointSize = min(theme.imagePlaceholderSymbolSize, rect.height * theme.imagePlaceholderSymbolFraction)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: theme.imagePlaceholderSymbolWeight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [theme.marker]))
        let names = theme.imagePlaceholderSymbols
        guard let symbol = (NSImage(systemSymbolName: picture.isBlocked ? names.blocked : picture.isMissing ? names.missing : names.loading, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: names.loading, accessibilityDescription: nil))?.withSymbolConfiguration(configuration) else { return }
        let gap = labelHeight > 0 ? theme.hairlineGap : 0
        let top = rect.midY - (symbol.size.height + gap + labelHeight) / 2
        symbol.draw(in: CGRect(x: rect.midX - symbol.size.width / 2, y: top, width: symbol.size.width, height: symbol.size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if labelHeight > 0 {
            label.draw(in: CGRect(x: rect.minX, y: top + symbol.size.height + gap, width: rect.width, height: labelHeight)
                .insetBy(dx: theme.codePanelPadding, dy: 0))
        }
    }

    private func drawInlineBackgrounds(at point: CGPoint, in context: CGContext) {
        guard let paragraph = (textElement as? NSTextParagraph)?.attributedString else { return }
        let inset = theme.inlineCodePadding.height, radius = theme.inlineCodeCornerRadius
        paragraph.enumerateAttribute(.inlineBackground, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            context.setFillColor(color.cgColor)
            for line in textLineFragments {
                let part = NSIntersectionRange(range, line.characterRange)
                guard part.length > 0 else { continue }
                let bounds = box(of: line)
                let start = line.locationForCharacter(at: part.location).x
                let end = line.locationForCharacter(at: NSMaxRange(part)).x
                let rect = CGRect(x: point.x + bounds.minX + start, y: point.y + bounds.minY + inset,
                                  width: end - start, height: bounds.height - 2 * inset)
                // An end where the run goes on on another line is cut square.
                var shape = rect
                if part.location > range.location {
                    shape.origin.x -= radius
                    shape.size.width += radius
                }
                if NSMaxRange(part) < NSMaxRange(range) { shape.size.width += radius }
                context.saveGState()
                context.clip(to: rect)
                context.addPath(CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
                context.restoreGState()
            }
        }
    }
}
