import Foundation

/// What the command-line tool hands to the app: one JSON object per connection.
public struct Request: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        /// Absolute, with links followed.
        public var path: String
        public var line: Int?

        public init(path: String, line: Int? = nil) {
            self.path = path
            self.line = line
        }
    }

    public struct PathError: Error, Equatable {
        public let message: String
    }

    public var items: [Item] = []
    /// The text of a new document, as piped into `marko -`.
    public var text: String?
    public var wait = false
    public var newWindow = false
    /// `--trust` or `--safe`: the answer for the folders named, and whether the files named and
    /// the piped text load remote images, until the app quits. Nil leaves both as they are.
    public var trust: Bool?

    public init() {}

    /// Whether there is anything to open; without, the tool only brings the app forward.
    public var opensSomething: Bool { !items.isEmpty || text != nil }
}

extension Request.Item {
    /// The file or folder a path means when it is typed in `directory`: "~" is the home folder and
    /// links are followed, so one file is one document whatever it was called. The file need not
    /// exist yet, the folder it is in must. What the app could not open as the tool sees it is
    /// refused here: a pipe or device such as the shell's "<(command)", which is only this
    /// process's to read, and anything in a folder that may not be read.
    public init(_ target: Command.Target, in directory: String) throws(Request.PathError) {
        func refuse(_ reason: String) -> Request.PathError {
            Request.PathError(message: target.path.isEmpty ? reason : "\(target.path): \(reason)")
        }
        let typed = (target.path as NSString).expandingTildeInPath
        guard !typed.isEmpty else { throw refuse("an empty path names nothing to open") }
        guard typed.hasPrefix("/") || !directory.isEmpty else { throw refuse("the current folder no longer exists") }
        let url = URL(fileURLWithPath: typed, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL
        let files = FileManager.default
        var isFolder: ObjCBool = false
        if files.fileExists(atPath: url.path, isDirectory: &isFolder) {
            let path = url.resolvingSymlinksInPath().path
            // Asked with links followed: "/tmp", "/var" and "/etc" are links to folders that
            // Foundation leaves standing in a path it has resolved.
            var status = stat()
            guard stat(path, &status) == 0, [S_IFREG, S_IFDIR].contains(status.st_mode & S_IFMT) else {
                throw refuse("neither a file nor a folder; text is piped in with \"marko -\"")
            }
            guard !isFolder.boolValue || files.isReadableFile(atPath: path) else { throw refuse("the folder may not be read") }
            self.init(path: path, line: target.line)
            return
        }
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard files.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw refuse("there is no folder \(folder.path) to make it in")
        }
        guard files.isExecutableFile(atPath: folder.path) else { throw refuse("the folder \(folder.path) may not be read") }
        self.init(path: folder.appendingPathComponent(url.lastPathComponent).path, line: target.line)
    }
}
