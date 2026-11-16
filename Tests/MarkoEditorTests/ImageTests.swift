import AppKit
import FixtureSupport
import MarkoCore
import Testing
@testable import MarkoEditor

extension EditorTests {
    @Suite struct ImageTests {
        private let theme = Theme.standard
        private let fixture = Fixtures.url("images.md")
        private var source: String { try! MarkdownFile(data: Data(contentsOf: fixture)).text }

        private func picture(_ w: EditorWindow, at offset: Int) -> ShownImage? {
            w.displayAttributes(at: offset)[.picture] as? ShownImage
        }

        /// The picture's rectangle in text column coordinates.
        private func pictureRect(_ w: EditorWindow, at offset: Int) -> CGRect? {
            ((w.fragment(at: offset) as? BlockFragment)?.pictures.first?.rect).map { w.inColumn($0, ofFragmentAt: offset) }
        }

        // MARK: where images come from

        @Test func aRelativeImageRendersFromBesideTheDocument() throws {
            let w = EditorWindow(source, documentURL: fixture)
            defer { w.close() }
            let mark = w.offset(of: "![A lake")
            let shown = try #require(picture(w, at: mark))
            #expect(shown.image != nil && !shown.isMissing)
            #expect(shown.size == CGSize(width: 640, height: 360), "at its own size where the column is wider")
            let rect = try #require(pictureRect(w, at: mark))
            #expect(rect.minX == 0 && rect.size == shown.size)
            // It stands above the line of its source, which is as high as its small text: a caret
            // in front of the image is not as high as the picture.
            let line = w.characterRect(at: mark).offsetBy(dx: 0, dy: -w.textView.textContainerOrigin.y)
            #expect(line.height == theme.imageCaptionLineHeight && line.minY == rect.maxY)
            #expect(w.fragment(at: mark).textLineFragments.count == 1)
            let above = w.fragment(at: mark - 1).layoutFragmentFrame.maxY, below = w.fragment(at: w.offset(of: "In a line of text") - 1).layoutFragmentFrame
            #expect(rect.minY - above == theme.imageSpacingBefore && below.minY - rect.maxY == theme.imageCaptionLineHeight, "as much room above as below")
            #expect(w.textView.string == source && w.storageProblem == nil)

            // It is drawn, with rounded corners: the corner shows the page, the middle does not.
            let pixels = w.pixels()
            #expect(!pixels.isBackground(rect.midX, rect.midY))
            #expect(!pixels.isBackground(rect.minX + 2, rect.midY) && !pixels.isBackground(rect.maxX - 2, rect.midY))
            #expect(pixels.isBackground(rect.minX + 0.5, rect.minY + 0.5) && pixels.isBackground(rect.maxX - 0.5, rect.maxY - 0.5))
        }

        /// What the cache holds of an image goes when the image leaves the text, also when that
        /// is the first edit of a document (it was once only let go from the second on).
        @Test func anImageTypedAgainIsReadAgain() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let small = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { NSColor.red.setFill(); $0.fill(); return true }
            let png = try #require(small.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            try folder.add("p.png", png)
            let markup = "![a](p.png)"
            let w = EditorWindow("intro\n\n\(markup)\n\ntext\n", documentURL: folder["doc.md"])
            defer { w.close() }
            let mark = w.offset(of: markup), range = NSRange(location: mark, length: (markup as NSString).length)
            #expect(picture(w, at: mark)?.size == CGSize(width: 20, height: 20))
            for size in [CGSize(width: 640, height: 360), CGSize(width: 20, height: 20)] {
                w.textView.insertText("", replacementRange: range)
                w.pump()
                // The file is another picture by the time its name is typed again.
                try (size.width == 640 ? Data(contentsOf: Fixtures.url("images/pic.png")) : png).write(to: folder["p.png"])
                w.textView.insertText(markup, replacementRange: NSRange(location: mark, length: 0))
                w.pump()
                #expect(picture(w, at: mark)?.size == size)
            }
        }

        @Test func thePicturesOwnPixelsAreDrawnOnceTheyAreMade() throws {
            let w = EditorWindow(source, documentURL: fixture)
            defer { w.close() }
            let mark = w.offset(of: "![A lake")
            let rect = try #require(pictureRect(w, at: mark)), shown = try #require(picture(w, at: mark))
            // The image drawn straight into a bitmap like the one the view is captured in, which
            // is how the view drew it before its pixels were made ahead; not what its room is filled with.
            let image = try #require(NSImage(contentsOf: Fixtures.url("images/pic.png")))
            let direct = try #require(w.textView.bitmapImageRepForCachingDisplay(in: CGRect(origin: .zero, size: rect.size)))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: direct)
            image.draw(in: CGRect(origin: .zero, size: rect.size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
                abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
            }
            let pixels = w.pixels(), scale = CGFloat(direct.pixelsWide) / rect.width
            #expect(!w.editor.isDecodingImages)
            for (x, y) in [(0.5, 0.5), (0.25, 0.25), (0.75, 0.3), (0.1, 0.8)] {
                let expected = try #require(direct.colorAt(x: Int(rect.width * x * scale), y: Int(rect.height * y * scale))?.usingColorSpace(.sRGB))
                let drawn = pixels.color(rect.minX + rect.width * x, rect.minY + rect.height * y)
                #expect(difference(drawn, expected) < 0.02, "at \(x), \(y): \(drawn) for \(expected)")
            }
            let room = Theme.standard.codePanel.usingColorSpace(.sRGB)!
            #expect(difference(pixels.color(rect.midX, rect.midY), room) > 0.1)
            // The line was laid out once, at the picture's size: nothing moved when the pixels came.
            #expect(picture(w, at: mark)?.size == shown.size && pictureRect(w, at: mark) == rect)
        }

        @Test func aPictureScaledToANarrowColumnOrAListIsDrawnToo() throws {
            let w = EditorWindow(source, size: NSSize(width: 520, height: 900), documentURL: fixture)
            defer { w.close() }
            let pixels = w.pixels()
            let page = pixels.color(2, 2), room = Theme.standard.codePanel.usingColorSpace(.sRGB)!
            func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
                abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
            }
            // The two that are in the window; what is below it has no surface to be drawn on.
            for name in ["![A lake", "![In a list"] {
                let mark = w.offset(of: name)
                let rect = try #require(pictureRect(w, at: mark)), shown = try #require(picture(w, at: mark))
                #expect(shown.size.width < 640, "\(name) is scaled down")
                #expect(rect.midY + w.textView.textContainerOrigin.y < w.textView.visibleRect.maxY, "\(name) is in view")
                let drawn = pixels.color(rect.midX, rect.midY)
                // Neither the page nor the room that is filled while the pixels are made (the page seen through its tint).
                #expect(difference(drawn, page) > 0.1 && difference(drawn, room) > 0.1, "\(name): \(drawn)")
            }
            #expect(!w.editor.isDecodingImages)
        }

        @Test func picturesAreLetGoWhenTheyTakeMoreThanTheirBudget() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marko-pictures-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let cache = ImageCache()
            var pictures: [ImageCache.Picture] = []
            for index in 0..<4 {
                let file = folder.appendingPathComponent("\(index).png")
                try Fixtures.data("images/pic.png").write(to: file)
                guard case .image(let picture) = cache.entry(for: file.path) else {
                    Issue.record("no image")
                    return
                }
                #expect(picture.size == CGSize(width: 640, height: 360))
                pictures.append(picture)
            }
            func made(_ picture: ImageCache.Picture, width: Int = 320) -> CGImage? {
                for _ in 0..<400 where picture.pixels(width: width, height: 180)?.width != width {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
                }
                return picture.pixels(width: width, height: 180)
            }
            // Asked for at another size while it is being made, as at every step of a resize:
            // that size is made next, without being asked for again.
            #expect(pictures[1].pixels(width: 100, height: 56) == nil && pictures[1].pixels(width: 120, height: 68) == nil)
            for _ in 0..<400 where cache.isDecoding { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
            #expect(cache.pixelCount == 2 && pictures[1].pixels(width: 120, height: 68)?.width == 120)
            #expect(pictures[1].pixels(width: 100, height: 56)?.width == 100 && !cache.isDecoding)
            // At the size asked for.
            let first = try #require(made(pictures[0]))
            #expect(first.width == 320 && first.height == 180)
            // At another size the one that is there serves until the right one is made.
            #expect(pictures[0].pixels(width: 300, height: 180) === first)
            #expect(made(pictures[0], width: 300)?.width == 300 && cache.pixelCount == 4)
            // Room for two of them.
            cache.pixelBudget = 2 * first.bytesPerRow * first.height
            for picture in pictures.dropFirst() { #expect(made(picture) != nil) }
            #expect(cache.pixelCount == 2 && !cache.isDecoding)
            // The ones used longest ago went, and are made again when they are asked for.
            #expect(pictures[3].pixels(width: 320, height: 180) != nil && pictures[2].pixels(width: 320, height: 180) != nil)
            #expect(pictures[0].pixels(width: 320, height: 180) == nil)
            #expect(made(pictures[0]) != nil && cache.pixelCount == 2)
            cache.forget()
            #expect(cache.pixelCount == 0)
        }

        @Test func anImageOnTheFirstLineOfTheTextHasItsRoomInTheLine() throws {
            // The first paragraph gets no spacing before it, which is where a picture stands otherwise.
            let w = EditorWindow("![first](images/pic.png)\n\ntext\n", documentURL: fixture)
            defer { w.close() }
            w.select(w.length)
            let rect = try #require(pictureRect(w, at: 0)), frame = w.fragment(at: 0).layoutFragmentFrame
            // Lifted with the line's text, but inside what the fragment draws.
            #expect(rect.minY > -theme.hairlineGap && rect.height == 360 && frame.height >= 360 + theme.imageCaptionLineHeight)
            #expect(w.fragment(at: 0).textLineFragments.count == 2, "the source is on a line below the picture")
            #expect(!w.pixels().isBackground(rect.midX, rect.midY))
            #expect(w.fragment(at: w.offset(of: "text")).layoutFragmentFrame.minY == frame.maxY + theme.blankLineHeight)
        }

        @Test func anImageIsScaledDownToTheColumnAndFollowsItsWidth() throws {
            let w = EditorWindow(source, size: NSSize(width: 500, height: 600), documentURL: fixture)
            defer { w.close() }
            let mark = w.offset(of: "![A lake"), column = w.textView.columnWidth
            #expect(column == 500 - 2 * theme.pagePadding.width)
            #expect(picture(w, at: mark)?.size == CGSize(width: column, height: (360 * column / 640).rounded()))
            // In a list the room is what is left beside the indent.
            let nested = w.offset(of: "![In a list")
            #expect(picture(w, at: nested)?.size.width == column - theme.listIndent)
            #expect(pictureRect(w, at: nested)?.minX == theme.listIndent)

            w.window.setContentSize(NSSize(width: 900, height: 600))
            w.pump()
            #expect(picture(w, at: mark)?.size == CGSize(width: 640, height: 360))
            #expect(w.textView.textLayoutManager != nil)
        }

        @Test func destinationsResolveAgainstTheDocument() {
            let document = URL(fileURLWithPath: "/notes/a/doc.md")
            func url(_ destination: String, _ base: URL? = document) -> String? {
                ImageCache.url(for: destination, relativeTo: base)?.absoluteString
            }
            #expect(url("pic.png") == "file:///notes/a/pic.png")
            #expect(url("images/pic.png") == "file:///notes/a/images/pic.png")
            #expect(url("../b/pic.png") == "file:///notes/b/pic.png")
            #expect(url("my%20pics/a%20%281%29.png") == "file:///notes/a/my%20pics/a%20(1).png")
            #expect(url("/abs/pic.png") == "file:///abs/pic.png")
            #expect(url("/abs/pic.png", nil) == "file:///abs/pic.png", "an absolute path needs no document")
            #expect(url("file:///abs/pic.png", nil) == "file:///abs/pic.png")
            #expect(url("https://example.com/a.png?x=1", nil) == "https://example.com/a.png?x=1")
            #expect(url("other.md#section") == "file:///notes/a/other.md")
            #expect(url("pic.png", nil) == nil, "a relative path has nothing to start from in a document never saved")
            #expect(url("", nil) == nil && url("#top") == nil)
            #expect(url("~/pic.png", nil) == URL(fileURLWithPath: NSHomeDirectory() + "/pic.png").absoluteString)

            #expect(ImageCache.path(to: URL(fileURLWithPath: "/notes/a/images/pic.png"), from: document) == "images/pic.png")
            #expect(ImageCache.path(to: URL(fileURLWithPath: "/notes/b/pic.png"), from: document) == "../b/pic.png")
            #expect(ImageCache.path(to: URL(fileURLWithPath: "/notes/a/pic.png"), from: nil) == "/notes/a/pic.png")
        }

        @Test func absolutePathsAndFileURLsRender() throws {
            let file = Fixtures.url("images/pic.png")
            let encoded = file.path.replacingOccurrences(of: " ", with: "%20")
            let w = EditorWindow("![a](\(encoded))\n\n![b](\(file.absoluteString))\n")
            defer { w.close() }
            #expect(picture(w, at: 0)?.image != nil)
            #expect(picture(w, at: w.offset(of: "![b"))?.image != nil)
        }

        @Test func anUnsavedDocumentShowsAPlaceholderUntilItHasAPlace() throws {
            let w = EditorWindow("before\n\n![A lake](images/pic.png)\n\nafter\n")
            defer { w.close() }
            let mark = w.offset(of: "![")
            let placeholder = try #require(picture(w, at: mark))
            #expect(placeholder.image == nil && placeholder.isMissing && placeholder.label == "A lake")
            #expect(placeholder.size == theme.imagePlaceholderSize)
            let rect = try #require(pictureRect(w, at: mark))
            #expect(!w.pixels().isBackground(rect.midX, rect.midY - 8), "the placeholder is drawn")

            // Saving gives the relative path somewhere to start from.
            w.editor.documentURL = fixture
            w.pump()
            #expect(picture(w, at: mark)?.image != nil)
            #expect(w.textView.string == "before\n\n![A lake](images/pic.png)\n\nafter\n" && w.storageProblem == nil)
        }

        @Test func aMissingFileShowsAPlaceholderNamedAfterTheFile() throws {
            let w = EditorWindow("![](images/nowhere.png) and ![](also-gone.png) in a line\n", documentURL: fixture)
            defer { w.close() }
            let block = try #require(picture(w, at: 0))
            #expect(block.image == nil && block.isMissing && block.label == "nowhere.png")
            // Inside a line of text the placeholder is small and the line keeps its height.
            #expect(block.size == CGSize(width: theme.inlineImagePlaceholderSize, height: theme.inlineImagePlaceholderSize))
            #expect(w.fragment(at: 0).textLineFragments[0].typographicBounds.height == theme.bodyLineHeight)
        }

        /// Asynchronous, because the answer comes in on the main actor, which a test that only pumps the run loop never yields.
        @Test func anImageFromTheWebArrivesLaterAndReplacesItsPlaceholder() async throws {
            let url = URL(string: "https://images.marko.test/lake.png")!
            WebStub.responses[url] = try Fixtures.data("images/pic.png")
            let text = "![Remote](\(url.absoluteString))\n\n![Gone](https://images.marko.test/gone.png)\n\nafter\n"
            let w = EditorWindow(text)
            defer { w.close() }
            w.editor.loadsRemoteImages = true
            w.pump()
            let gone = w.offset(of: "![Gone")
            let loading = try #require(picture(w, at: 0))
            #expect(loading.image == nil && !loading.isMissing, "loading is not missing")

            for _ in 0..<100 where picture(w, at: 0)?.image == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(picture(w, at: 0)?.size == CGSize(width: 640, height: 360), "the line was rendered again when the image arrived")
            for _ in 0..<100 where picture(w, at: gone)?.isMissing != true { try await Task.sleep(for: .milliseconds(20)) }
            #expect(picture(w, at: gone)?.isMissing == true, "a failed request ends as missing")
            #expect(w.textView.string == text && w.storageProblem == nil)
        }

        // MARK: the source of an image

        @Test func theCaretMovesThroughAnImagesSourceWithoutAnythingMoving() throws {
            let w = EditorWindow(source, documentURL: fixture)
            defer { w.close() }
            let token = (source as NSString).range(of: "![A lake at dusk](images/pic.png)")
            let below = w.offset(of: "In a line of text"), last = w.offset(of: "[Back to")
            w.select(0)
            w.pump()
            let frames = [token.location, below, last].map { w.fragment(at: $0).layoutFragmentFrame }
            #expect(frames[0].height > 360)
            #expect(w.displayAttributes(at: token.location + 3)[.foregroundColor] as? NSColor == .clear, "the source is laid out but not shown")

            for offset in token.location...NSMaxRange(token) {
                w.select(offset)
                w.pump(0.01)
                #expect(w.textView.selectedRange().location == offset, "every offset is a caret stop")
                #expect([token.location, below, last].map { w.fragment(at: $0).layoutFragmentFrame } == frames, "caret at \(offset)")
                #expect(picture(w, at: token.location)?.image != nil, "the picture stays while its source shows")
                #expect(w.displayAttributes(at: token.location + 3)[.foregroundColor] as? NSColor == theme.marker)
            }
            // The source shows on its own line under the picture.
            let pictureRect = try #require(pictureRect(w, at: token.location))
            #expect(w.characterRect(at: token.location + 1).minY - w.textView.textContainerOrigin.y >= pictureRect.maxY)

            w.select(below + 4)
            w.pump()
            #expect([token.location, below, last].map { w.fragment(at: $0).layoutFragmentFrame } == frames)
            #expect(w.displayAttributes(at: token.location + 3)[.foregroundColor] as? NSColor == .clear)
            #expect(w.textView.string == source && w.storageProblem == nil)
        }

        @Test func arrowKeysCrossAnImageOneOffsetAtATime() {
            let text = "a\n\n![x](images/dot.png)\n\nb ![y](images/dot.png) c\n"
            let w = EditorWindow(text, documentURL: fixture)
            defer { w.close() }
            w.select(0)
            for expected in 1...w.length {
                w.command(#selector(NSResponder.moveRight(_:)))
                w.pump(0.005)
                #expect(w.textView.selectedRange() == NSRange(location: expected, length: 0))
            }
        }

        @Test func anImageInALineOfTextHidesItsSourceLikeAnyMarker() throws {
            let w = EditorWindow(source, documentURL: fixture)
            defer { w.close() }
            let mark = w.offset(of: "![a small picture")
            w.select(0)
            w.pump()
            #expect(picture(w, at: mark)?.size == CGSize(width: 20, height: 20))
            #expect(w.isHidden(mark + 1) && w.isHidden(mark + 5) && w.isHidden(w.offset(of: "images/dot.png)")))
            #expect(w.fragment(at: mark).textLineFragments[0].typographicBounds.height == theme.bodyLineHeight, "a small picture keeps the line's height")

            w.select(mark + 4)
            w.pump()
            #expect(!w.isHidden(mark + 1) && w.displayAttributes(at: mark + 5)[.foregroundColor] as? NSColor == theme.marker)
            #expect(picture(w, at: mark)?.image != nil)

            // The second one is the text of a link: the picture is there and the link's own syntax is hidden.
            let linked = w.offset(of: "[![dot")
            #expect(w.isHidden(linked) && picture(w, at: linked + 1)?.image != nil && w.isHidden(w.offset(of: "](https://example.com)")))
        }

        @Test func anImageInATableCellStaysSource() {
            let w = EditorWindow(source, documentURL: fixture)
            defer { w.close() }
            let cell = w.offset(of: "![cell")
            #expect(picture(w, at: cell) == nil && !w.isHidden(cell + 1))
            #expect(w.displayParagraph(at: cell).text.string.contains("![cell](images/dot.png)"))
        }

        @Test func spellingIsNotMarkedInAnImagesSource() {
            let w = EditorWindow("![descripton wrnog](images/pic.png) wrnog\n", documentURL: fixture)
            defer { w.close() }
            let delegate = w.editor as NSTextViewDelegate
            #expect(delegate.textView?(w.textView, shouldSetSpellingState: 1, range: NSRange(location: 2, length: 10)) == 0)
            #expect(delegate.textView?(w.textView, shouldSetSpellingState: 1, range: NSRange(location: 36, length: 5)) == 1)
        }

        // MARK: dropping and pasting image files

        private func pasteboard(_ urls: [URL]) -> NSPasteboard {
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            pasteboard.writeObjects(urls.map { $0.absoluteURL as NSURL })
            return pasteboard
        }

        @Test func aPastedImageFileBecomesAnImageWithARelativePath() {
            let w = EditorWindow("text\n", documentURL: fixture)
            defer { w.close() }
            w.select(5)
            let files = pasteboard([Fixtures.url("images/pic.png")])
            defer { files.releaseGlobally() }
            #expect(w.textView.readSelection(from: files, type: .fileURL))
            w.pump()
            #expect(w.textView.string == "text\n![pic](images/pic.png)")
            #expect(picture(w, at: 5)?.image != nil, "and it shows at once")
            w.undoAll()
            #expect(w.textView.string == "text\n")
        }

        @Test func anUnsavedDocumentGetsTheWholePathAndOtherFilesAreNotImages() {
            let w = EditorWindow("")
            defer { w.close() }
            let file = Fixtures.url("images/pic.png")
            let files = pasteboard([file]), other = pasteboard([Fixtures.url("lf.md")])
            defer {
                files.releaseGlobally()
                other.releaseGlobally()
            }
            #expect(w.editor.textView.pasteHandler?(other) == false, "a file that is not an image is left to the text view")
            #expect(w.textView.string == "")
            #expect(w.textView.readSelection(from: files, type: .fileURL))
            #expect(w.textView.string == FormatCommands.imageMarkup(alt: "pic", path: file.path))
            w.pump()
            #expect(picture(w, at: 0)?.image != nil)
        }

        @Test func aDroppedImageFileGoesWhereItIsDropped() throws {
            let w = EditorWindow("first line\n\nsecond line\n", documentURL: fixture)
            defer { w.close() }
            w.select(0)
            let files = pasteboard([Fixtures.url("images/pic.png"), Fixtures.url("images/dot.png")])
            defer { files.releaseGlobally() }
            #expect(w.textView.registeredDraggedTypes.contains(.fileURL))
            // On the empty line between the two.
            let origin = w.textView.textContainerOrigin, line = w.fragment(at: 11).layoutFragmentFrame
            let drop = Drop(pasteboard: files, location: w.textView.convert(NSPoint(x: origin.x + 1, y: origin.y + line.midY), to: nil), window: w.window)
            #expect(w.textView.draggingEntered(drop) != [])
            #expect(w.textView.prepareForDragOperation(drop))
            #expect(w.textView.performDragOperation(drop))
            w.pump()
            #expect(w.textView.string == "first line\n![pic](images/pic.png)\n![dot](images/dot.png)\nsecond line\n")
        }
    }
}

/// A drag that carries `pasteboard` to `location` in the window, as AppKit hands it to a destination.
final class Drop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = [.copy, .generic]
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    var draggingSource: Any?
    let draggingSequenceNumber = 1
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight = NSSpringLoadingHighlight.none

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
