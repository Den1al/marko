import Foundation

/// The Unix socket between the command-line tool and the running app. The tool connects and writes
/// a `Request` as one line; the app answers in lines, "ok" when everything has been read
/// (its windows follow) and before that one line for each thing that could not be, and closes
/// the connection when the tool may return. A tool that waits for documents to close is told "closed" first, so a connection
/// that just ends is the app having gone away.
public enum Channel {
    public static let acknowledgement = "ok"
    public static let closed = "closed"

    /// The socket of the user's Marko, in the user's own temporary folder, which no other user can
    /// reach. `MARKO_SOCKET` names another one, for an instance that is to be left alone by the rest.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["MARKO_SOCKET"] { return path }
        var folder = [CChar](repeating: 0, count: Int(PATH_MAX))
        confstr(_CS_DARWIN_USER_TEMP_DIR, &folder, folder.count)
        return String(decoding: folder.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) + "local.marko.socket"
    }

    /// A connection to the app listening at `path`, or nil when none is.
    public static func connect(to path: String) -> Int32? {
        let descriptor = stream()
        guard withAddress(of: path, { Darwin.connect(descriptor, $0, $1) }) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// A socket listening at `path`, or nil when another instance already is. The socket belongs
    /// to whoever holds the lock beside it, which a process keeps until it ends: of several
    /// instances starting at once exactly one listens. A socket file that an instance left behind
    /// is replaced; anything else at the path is left alone.
    public static func listen(at path: String) -> Int32? {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return nil }
        let lock = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return nil }
        var status = stat()
        let descriptor = stream()
        guard flock(lock, LOCK_EX | LOCK_NB) == 0,
              lstat(path, &status) != 0 || (status.st_mode & S_IFMT == S_IFSOCK && unlink(path) == 0),
              withAddress(of: path, { bind(descriptor, $0, $1) }) == 0, Darwin.listen(descriptor, 16) == 0 else {
            close(descriptor)
            close(lock)
            return nil
        }
        return descriptor
    }

    /// The next connection, waiting for one. A request that takes longer than `readTimeout` to
    /// arrive is given up, so a client that says nothing does not keep a thread for ever.
    public static func accept(on listener: Int32) -> Int32? {
        var descriptor: Int32
        repeat {
            descriptor = Darwin.accept(listener, nil, nil)
        } while descriptor < 0 && (errno == EINTR || errno == ECONNABORTED)
        guard descriptor >= 0 else { return nil }
        ignoreBrokenPipe(descriptor)
        var timeout = timeval(tv_sec: readTimeout, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return descriptor
    }

    static let readTimeout = 2
    /// Piped text may be long, but a request is not read without end.
    static let requestLimit = 64 << 20
    /// What ends a request: its JSON holds no line break.
    private static let lineBreak = UInt8(ascii: "\n")

    /// Writes a request as one line. The writing side is closed after it, which is what ended a
    /// request for an app built before the line break did, and such an app may be the one running.
    public static func send(_ request: Request, on connection: Int32) throws {
        try FileHandle(fileDescriptor: connection).write(contentsOf: JSONEncoder().encode(request) + [lineBreak])
        shutdown(connection, SHUT_WR)
    }

    /// The request written to an accepted connection, or nil when none arrives whole: reading
    /// stops at the line break, at the limit, or when nothing has come for `readTimeout`.
    /// MEASURED: the end of the tool's writing must not be what ends the request. A `read` that
    /// starts waiting at the moment the other end calls `shutdown` is sometimes not woken by it
    /// (macOS 26: 6 of 200,000 in one process, 3 of 100 cold starts by five tools on a loaded
    /// machine) and only returns when the time is up, and the tool was then told nothing.
    public static func receive(on connection: Int32) -> Request? {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1 << 16)
        while data.last != lineBreak, data.count <= requestLimit {
            let count = read(connection, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[..<count])
        }
        return try? JSONDecoder().decode(Request.self, from: data)
    }

    private static func stream() -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        ignoreBrokenPipe(descriptor)
        return descriptor
    }

    /// Writing to a tool that was interrupted fails instead of killing the app.
    private static func ignoreBrokenPipe(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func withAddress(of path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
