import CoreServices
import Foundation
import UniformTypeIdentifiers

/// A file or folder as the sidebar lists it.
public nonisolated struct FileEntry: Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    /// Where the item really is, when it is a symbolic link or in a folder reached through one.
    public let destination: String?
    /// A folder that may not be read: it is listed, and cannot be opened.
    public let isLocked: Bool

    public init(url: URL, isDirectory: Bool, destination: String? = nil, isLocked: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.destination = destination
        self.isLocked = isLocked
    }

    public var name: String { url.lastPathComponent }
    /// The file this is, which a document of it goes by: a link is the file it leads to.
    public var filePath: String { destination ?? url.path }
    public var isMarkdown: Bool { !isDirectory && MarkdownFile.isMarkdown(url) }
}

public nonisolated enum FileTree {
    /// The type of a file that a double click opens in the app the system has for that type:
    /// only what such an app merely shows or plays (pictures, sound, film, PDF, plain text). Nil
    /// for anything else, which could be run or acted on by being opened (an app, a script, a
    /// ".command", ".terminal" or ".webloc" file, a configuration profile, a page with scripts, a
    /// playlist of addresses to fetch) and is shown in the Finder instead. `file` is the file
    /// itself: a link is opened as what it leads to, whatever it is called, so one that was not
    /// followed is not opened either. The app is found for the type, never for the file, which
    /// can name an app of its own choosing (the "Open With" attribute).
    public static func typeOpenedInItsApp(_ file: URL) -> UTType? {
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let type = UTType(filenameExtension: file.pathExtension),
              [.image, .audiovisualContent, .pdf, .plainText].contains(where: type.conforms),
              ![.script, .executable, .xml, .playlist].contains(where: type.conforms) else { return nil }
        return type
    }

    /// Hidden files, the one folder that is never worth browsing, and the backups ("name~.md",
    /// "name~") that editors keep beside a file.
    static func isExcluded(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "node_modules" || (name as NSString).deletingPathExtension.hasSuffix("~")
    }

    /// What one folder holds, not what the folders in it hold: folders first, each group in the
    /// Finder's order. Reads the disk, so it is called off the main thread. A link to a folder is a
    /// folder, listed where it leads when it is opened; a loop of links is only ever followed one
    /// opened folder at a time.
    public static func contents(of folder: URL) -> [FileEntry] {
        let home = folder.resolvingSymlinksInPath()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)) ?? []
        // Each name is read from its URL once: MEASURED, read again in every comparison of the
        // sort it was 50 ms of the 120 ms that 5,000 files then took.
        return urls.compactMap { url -> (name: String, entry: FileEntry)? in
            let name = url.lastPathComponent
            guard !isExcluded(name) else { return nil }
            var values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // MEASURED: without the hint Foundation asks the disk about every name, which was 95%
            // of the time to list 5,000 files.
            var real = home.appendingPathComponent(name, isDirectory: values?.isDirectory == true)
            // A link that leads onto a network volume is not followed: listing a folder contacts
            // no server. It is listed as a file, and is opened where it leads only when it is chosen.
            if values?.isSymbolicLink == true, NetworkVolume.source(ofPath: real.path) == nil {
                real = real.resolvingSymlinksInPath()
                values = try? real.resourceValues(forKeys: [.isDirectoryKey])
            }
            let isDirectory = values?.isDirectory == true
            // Every URL is the folder's plus a name, so paths compare equal however the folder was reached.
            let entry = folder.appendingPathComponent(name, isDirectory: isDirectory)
            let isLocked = isDirectory && !FileManager.default.isReadableFile(atPath: real.path)
            return (name, FileEntry(url: entry, isDirectory: isDirectory, destination: real.path == entry.path ? nil : real.path, isLocked: isLocked))
        }.sorted { precedes(($0.name, $0.entry.isDirectory), ($1.name, $1.entry.isDirectory)) }.map(\.entry)
    }

    public static func precedes(_ a: FileEntry, _ b: FileEntry) -> Bool {
        precedes((a.name, a.isDirectory), (b.name, b.isDirectory))
    }

    private static func precedes(_ a: (name: String, isDirectory: Bool), _ b: (name: String, isDirectory: Bool)) -> Bool {
        a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Where a path is after the item at `old` was renamed to `new`; nil when it is neither that
    /// item nor inside it.
    public static func path(_ path: String, movedFrom old: URL, to new: URL) -> String? {
        isPath(path, atOrInside: old) ? new.path + path.dropFirst(old.path.count) : nil
    }

    public static func isPath(_ path: String, atOrInside url: URL) -> Bool {
        path == url.path || path.hasPrefix(url.path + "/")
    }

    /// A name for a new item in `folder` that nothing there has: "Untitled.md", "Untitled 2.md", ...
    public static func unusedName(_ stem: String, extension ext: String?, in folder: URL) -> URL {
        for number in 1... {
            let name = (number == 1 ? stem : "\(stem) \(number)") + (ext.map { ".\($0)" } ?? "")
            let url = folder.appendingPathComponent(name, isDirectory: ext == nil)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        fatalError("unreachable")
    }
}

/// Tells which folders under a root had their contents change, a moment after they did.
public final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let root: URL
    /// The root as the system reports it, with symbolic links resolved.
    private let realRoot: String
    /// Called with the folders that changed, or nil when anything under the root may have.
    private let handler: ([URL]?) -> Void

    public init(root: URL, handler: @escaping ([URL]?) -> Void) {
        self.root = root
        self.handler = handler
        realRoot = realpath(root.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? root.path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [realRoot] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Theme.standard.sidebarRefreshDelay, FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
        let everything = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        let isWhole = (0..<count).contains { flags[$0] & everything != 0 }
        // The stream delivers on the main queue, where the watcher lives.
        nonisolated(unsafe) let pointer = info
        MainActor.assumeIsolated {
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(pointer).takeUnretainedValue()
            watcher.handler(isWhole ? nil : paths.map(watcher.url))
        }
    }

    /// The system's path for a folder under the root, as the URL the tree has for it.
    private func url(for path: String) -> URL {
        guard path.hasPrefix(realRoot) else { return root }
        let rest = path.dropFirst(realRoot.count).trimmingCharacters(in: ["/"])
        return rest.isEmpty ? root : root.appendingPathComponent(rest, isDirectory: true)
    }
}
