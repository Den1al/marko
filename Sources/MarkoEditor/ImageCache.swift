import AppKit

/// The images a document shows. A file's size is read when it is first asked for, so that its
/// line is laid out once; an image on the web arrives later, announced by `didLoad`. The pixels
/// of either are made off the main thread when the image is first drawn, announced by `didDecode`.
final class ImageCache {
    enum Entry {
        case loading, missing
        /// Not fetched, because the document may not: it would come from this host or network volume.
        case blocked(String)
        case image(Picture)
    }

    /// An image whose size is known.
    final class Picture {
        /// In points, as the image itself has it.
        let size: CGSize
        fileprivate let source: Source
        fileprivate weak var cache: ImageCache?
        /// Its pixels could not be made; they are not asked for again.
        fileprivate var isBroken = false

        fileprivate init(size: CGSize, source: Source, cache: ImageCache) {
            self.size = size
            self.source = source
            self.cache = cache
        }

        /// See `ImageCache.pixels(of:width:height:)`.
        func pixels(width: Int, height: Int) -> CGImage? {
            cache?.pixels(of: self, width: width, height: height)
        }
    }

    fileprivate enum Source: Sendable {
        case file(URL)
        case data(Data)
    }

    /// How much memory the pictures made may take together; the one drawn longest ago goes first.
    /// One picture as wide as the column is 1,560 pixels wide on a 2x screen, about 7 MB.
    var pixelBudget = 64 << 20

    /// The most that is downloaded or read from a file for one image; a larger one is missing.
    nonisolated static let byteLimit = 32 << 20
    /// The most pixels an image may have: making them takes four bytes for each, however small
    /// the file and however small it is shown. A larger one is missing.
    var pixelLimit = 64_000_000

    /// The document's file, which relative paths start from. A document never saved has none, and
    /// its relative images are missing until it is.
    var documentURL: URL? {
        didSet { if documentURL != oldValue { forget() } }
    }
    /// Whether the document may fetch images from the web and read them from network volumes:
    /// `TrustStore` says, through the editor. Until it does, nothing leaves this Mac for an
    /// image: no request is made, no name is looked up and no network volume is touched.
    var allowsRemote = false {
        didSet {
            guard allowsRemote != oldValue else { return }
            downloads.values.forEach { $0.cancel() }
            downloads = [:]
            // Only what the answer changes is asked about again; the files of this Mac stay as they are.
            entries = entries.filter { url, entry in
                if case .blocked = entry { return false }
                return allowsRemote || Self.remoteSource(of: url) == nil
            }
        }
    }
    /// Called when an image that was loading has arrived or failed.
    var didLoad: (() -> Void)?
    /// Called when the pixels of a picture are there, for what shows it to be drawn again.
    var didDecode: ((Picture, CGImage) -> Void)?

    private var entries: [URL: Entry] = [:]
    private var downloads: [URL: Task<Void, Never>] = [:]
    /// The pictures made, the one used longest ago first.
    private var bitmaps: [(picture: Picture, pixels: CGImage)] = []
    /// The pictures whose pixels are being made. Every one that goes in comes out again when its
    /// pixels arrive or fail, whatever happened to the cache meanwhile, so `forget` leaves it alone:
    /// the block that makes the pixels holds its picture until then.
    private var decoding: Set<ObjectIdentifier> = []
    /// The size a picture was last asked for while it was being made at another, as at every
    /// step of a window being resized. It is made at that size next.
    private var wanted: [ObjectIdentifier: (width: Int, height: Int)] = [:]
    /// Where each destination asked about points. MEASURED: working that out takes 65 µs, and
    /// every line with a picture asks whenever it is rendered: 4 ms of each step of a window
    /// being resized over a document with 200 of them.
    private var urls: [String: URL?] = [:]
    /// One picture is made at a time, so that many large ones do not take all the memory at once.
    private static let decoder = DispatchQueue(label: "local.marko.images", qos: .userInitiated)

    /// What is being fetched for a document that is closed is given up.
    isolated deinit {
        downloads.values.forEach { $0.cancel() }
    }

    var isEmpty: Bool { entries.isEmpty }
    /// Whether pixels are still on their way.
    var isDecoding: Bool { !decoding.isEmpty }
    /// How many pictures are made and kept.
    var pixelCount: Int { bitmaps.count }

    /// Where a link or image destination points: a URL with a scheme as it is, a path from the root
    /// or the home directory, or a path beside the document. Nil when there is nothing to start from.
    static func url(for destination: String, relativeTo document: URL?) -> URL? {
        let destination = destination.trimmingCharacters(in: .whitespaces)
        // "//host/path" is an address on the web, as it is in a browser, and not a file of this Mac.
        if destination.hasPrefix("//") { return URL(string: "https:" + destination) }
        // One letter before a colon is a drive, not a scheme.
        if let url = URL(string: destination), let scheme = url.scheme, scheme.count > 1 { return url }
        let encoded = destination.prefix { $0 != "#" }
        let path = encoded.removingPercentEncoding ?? String(encoded)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") || path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return document.map { URL(fileURLWithPath: path, relativeTo: $0.deletingLastPathComponent()).standardizedFileURL }
    }

    /// The destination to write for `file` in a document at `document`: the path from one to the
    /// other, or the whole path while the document has no place yet.
    static func path(to file: URL, from document: URL?) -> String {
        guard let base = document?.deletingLastPathComponent().standardizedFileURL.pathComponents else { return file.path }
        let target = file.standardizedFileURL.pathComponents
        let shared = zip(base, target).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: base.count - shared) + target[shared...]).joined(separator: "/")
    }

    func entry(for destination: String) -> Entry {
        let known = urls[destination] ?? Self.url(for: destination, relativeTo: documentURL)
        urls[destination] = .some(known)
        guard let url = known else { return .missing }
        if let entry = entries[url] { return entry }
        if !allowsRemote, let source = Self.remoteSource(of: url) {
            entries[url] = .blocked(source)
        } else if url.isFileURL {
            // Only a regular file: a device or a pipe would be read without end. And not a huge
            // one, wherever it is: MEASURED, an 8 GB file took 2.4 s here and 3.4 GB of memory.
            let file = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let isImage = file?.isRegularFile == true && file?.fileSize.map { $0 <= Self.byteLimit } == true
            // MEASURED: 0.4 ms for a 2.3 MB file, which is mapped and not decoded here.
            entries[url] = (isImage ? NSImage(contentsOf: url) : nil).flatMap { picture($0, .file(url)) } ?? .missing
        } else if let secure = Self.secure(url) {
            entries[url] = .loading
            downloads[url] = Task { [weak self] in
                let data = await Self.download(secure)
                guard let self, !Task.isCancelled, case .loading = entries[url] else { return }
                entries[url] = data.flatMap { data in NSImage(data: data).flatMap { self.picture($0, .data(data)) } } ?? .missing
                downloads[url] = nil
                didLoad?()
            }
        } else {
            entries[url] = .missing
        }
        return entries[url] ?? .missing
    }

    /// The sizes are read from the head of the file; nothing is decoded for them. An image
    /// drawn from a description (PDF, SVG) has no pixels of its own and is made at the size shown.
    private func picture(_ image: NSImage, _ source: Source) -> Entry? {
        let fits = image.representations.allSatisfy { $0.pixelsWide * $0.pixelsHigh <= pixelLimit }
        return fits && image.isValid && image.size.width > 0 && image.size.height > 0 ? .image(Picture(size: image.size, source: source, cache: self)) : nil
    }

    /// The picture as `width` by `height` pixels in the screen's colours, which is what a
    /// fragment that draws it needs: drawing it then copies pixels. If it is not made yet it is
    /// made now, off the main thread, and announced by `didDecode`; until then this gives the
    /// picture at another size if there is one, as while a window is resized.
    /// MEASURED: drawn from the file's own pixels, each picture that scrolled into view was
    /// decoded and scaled on the main thread, 60% of its time while scrolling through pictures.
    fileprivate func pixels(of picture: Picture, width: Int, height: Int) -> CGImage? {
        var other: CGImage?
        for index in bitmaps.indices.reversed() where bitmaps[index].picture === picture {
            let pixels = bitmaps[index].pixels
            guard pixels.width == width, pixels.height == height else {
                other = other ?? pixels
                continue
            }
            bitmaps.append(bitmaps.remove(at: index))
            return pixels
        }
        let id = ObjectIdentifier(picture)
        guard !picture.isBroken, width > 0, height > 0 else { return other }
        guard decoding.insert(id).inserted else {
            wanted[id] = (width, height)
            return other
        }
        let source = picture.source, space = (NSScreen.main ?? NSScreen.screens.first)?.colorSpace?.cgColorSpace
        Self.decoder.async {
            let pixels = autoreleasepool { Self.pixels(of: source, width: width, height: height, space: space) }
            // Through the run loop, not the main queue: it is served in every mode, also while the window is resized.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.decoding.remove(id)
                    let next = self.wanted.removeValue(forKey: id)
                    guard let pixels else { return picture.isBroken = true }
                    self.bitmaps.append((picture, pixels))
                    var total = self.bitmaps.reduce(0) { $0 + $1.pixels.bytesPerRow * $1.pixels.height }
                    while total > self.pixelBudget, self.bitmaps.count > 1 {
                        let dropped = self.bitmaps.removeFirst().pixels
                        total -= dropped.bytesPerRow * dropped.height
                    }
                    self.didDecode?(picture, pixels)
                    if let next, next != (width, height) { _ = self.pixels(of: picture, width: next.width, height: next.height) }
                }
            }
        }
        return other
    }

    /// The image drawn `width` by `height` pixels, as the text view would draw it.
    private nonisolated static func pixels(of source: Source, width: Int, height: Int, space: CGColorSpace?) -> CGImage? {
        let image = switch source {
        case .file(let url): NSImage(contentsOf: url)
        case .data(let data): NSImage(data: data)
        }
        func bitmap(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        // Not every colour space can be drawn into.
        guard let image, image.isValid,
              let context = space.flatMap(bitmap) ?? CGColorSpace(name: CGColorSpace.displayP3).flatMap(bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Sizes have changed: every picture is made again when it is next shown.
    func forgetPixels() {
        bitmaps = []
    }

    /// Where an image would come from when that is not this Mac: the host of a web address or of a
    /// "file://host/" one, or the network volume its path leads onto. Nil for a file of this Mac,
    /// and for an address that is never fetched at all (any scheme but http and https).
    static func remoteSource(of url: URL) -> String? {
        guard url.isFileURL else { return secure(url).map { $0.host ?? "" } }
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { return host }
        return NetworkVolume.source(ofPath: url.path)
    }

    /// The address to fetch a web image from. The system refuses to load over plain http, so such
    /// an address is tried over https; nil for anything that is not on the web.
    private static func secure(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(parts.scheme?.lowercased()) else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    /// What answers an image request before the system's own loader does: nothing in the app. The
    /// tests put their stub here, before the first image is asked for.
    nonisolated(unsafe) static var protocolClasses: [AnyClass] = []

    /// What images are fetched with, made at the first request: a server learns the address and
    /// the time, and nothing it could know the reader by the next time. No cookie is kept or
    /// sent, no password is looked up in the keychain, and no answer is kept in a cache; redirects
    /// are followed as the system's shared loader follows them.
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }()

    /// What a successful response holds, up to the limit; nil for anything else.
    private nonisolated static func download(_ url: URL) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              response.expectedContentLength <= byteLimit else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteLimit { return nil }
            }
        } catch {
            return nil
        }
        return data
    }

    /// Lets go of every image whose destination is not among `destinations`, and stops loading it.
    /// The pixels made of it stay until newer ones push them out of `pixelBudget`.
    func keep(_ destinations: Set<String>) {
        // Asked after every parse, and nearly always with nothing to let go of: every destination
        // that was asked about (`urls` has them all) is still wanted. MEASURED: making the URLs of
        // 200 images again was 13 ms of every key.
        guard !urls.keys.allSatisfy(destinations.contains) else { return }
        urls = urls.filter { destinations.contains($0.key) }
        let urls = Set(destinations.compactMap { Self.url(for: $0, relativeTo: documentURL) })
        for url in entries.keys where !urls.contains(url) {
            entries[url] = nil
            downloads.removeValue(forKey: url)?.cancel()
        }
    }

    /// Reads every image again when it is next asked for: a file may have appeared or changed.
    func forget() {
        entries = [:]
        urls = [:]
        bitmaps = []
        wanted = [:]
        downloads.values.forEach { $0.cancel() }
        downloads = [:]
    }
}
