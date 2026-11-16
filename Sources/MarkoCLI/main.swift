import Foundation
import MarkoCommand

// The `marko` command: hands what it is asked to open to the running Marko through its socket,
// starting the app first when it is not running. It lives in Marko.app/Contents/Helpers.

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("marko: \(message)\n".utf8))
    exit(status)
}

let command: Command
do {
    command = try Command(Array(CommandLine.arguments.dropFirst()), exists: FileManager.default.fileExists)
} catch {
    fail("\(error.message)\n\(Command.usage)", status: 2)
}
if command.action == .help {
    print(Command.usage)
    exit(0)
}

// The app is found from where this file really is, whatever link started it.
guard let tool = Bundle.main.executableURL?.resolvingSymlinksInPath() else { fail("cannot tell where it is installed") }
let app = tool.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard app.pathExtension == "app" else { fail("\(tool.path) is not inside Marko.app") }
if command.action == .version {
    let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    print("marko \(info?["CFBundleShortVersionString"] as? String ?? "unknown")")
    exit(0)
}

var request = Request()
request.wait = command.wait
request.newWindow = command.newWindow
request.trust = command.trust
do {
    request.items = try command.targets.map { target throws(Request.PathError) in
        try Request.Item(target, in: FileManager.default.currentDirectoryPath)
    }
} catch {
    fail(error.message)
}
if command.readsStandardInput {
    // As with a file: what is not UTF-8 is not opened, rather than opened as something else.
    guard let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) else {
        fail("the piped text is not UTF-8")
    }
    request.text = text
}

let environment = ProcessInfo.processInfo.environment
let socket = Channel.socketPath(environment: environment)

/// Starts the app by running its executable, which is where it has its first window 130 ms
/// sooner than through /usr/bin/open (MEASURED: LaunchServices takes 80 ms to make the process
/// and the process 50 ms longer to reach `main`). What LaunchServices would see to is seen to
/// here: the app is in a session of its own, without this terminal, the shell's files and
/// folder, and outlives both; it gets the environment an app gets, not the shell's; and what
/// it may read is the user's to grant to Marko, not to the terminal (the system calls this
/// disclaiming responsibility; where it cannot be had, the app starts without).
func start(_ app: URL, with variables: [String: String]) {
    guard let executable = Bundle(url: app)?.executableURL else { fail("cannot start \(app.path)") }
    let inherited = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "__CF_USER_TEXT_ENCODING"]
    var all = environment.filter { inherited.contains($0.key) }
    all["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    all.merge(variables) { $1 }
    var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    if let disclaim = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
        _ = unsafeBitCast(disclaim, to: Disclaim.self)(&attributes, 1)
    }
    posix_spawn_file_actions_init(&actions)
    for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
    }
    posix_spawn_file_actions_addchdir(&actions, "/")
    let arguments = [strdup(executable.path), nil], variables = all.map { strdup("\($0)=\($1)") } + [nil]
    let status = posix_spawn(nil, executable.path, &actions, &attributes, arguments, variables)
    if status != 0 { fail("cannot start \(app.path): \(String(cString: strerror(status)))") }
}

var connection = Channel.connect(to: socket)
if connection == nil {
    // Of several tools started at once one starts the app; the others wait here and find it listening.
    let lock = open(socket + ".launch", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    flock(lock, LOCK_EX)
    connection = Channel.connect(to: socket)
    if connection == nil {
        // A socket of its own means an instance of its own: how the tests run one. It gets the
        // tool's MARKO_ variables, which say what it is to check. An app started for the user
        // gets none: one left in the shell must not turn the user's Marko into a test run.
        var variables = environment["MARKO_SOCKET"] == nil ? [:] : environment.filter { $0.key.hasPrefix("MARKO_") }
        // Started to open something, the app does not make an empty document first.
        if request.opensSomething { variables["MARKO_CLI"] = "1" }
        // Told its first file, it reads and parses it at once and shows it before anything else,
        // instead of when the request arrives. A file wanted at a line is shown there, by the request.
        var isFolder: ObjCBool = false
        // Not with `--trust` or `--safe`, which the request brings: the file must not be shown before them.
        if let first = request.items.first, first.line == nil, request.trust == nil, FileManager.default.fileExists(atPath: first.path, isDirectory: &isFolder), !isFolder.boolValue {
            variables["MARKO_FILE"] = first.path
        }
        start(app, with: variables)
        let deadline = Date(timeIntervalSinceNow: 20)
        while connection == nil, Date() < deadline {
            usleep(2000)
            connection = Channel.connect(to: socket)
        }
    }
    close(lock)
}
guard let connection else { fail("Marko did not start") }

do {
    try Channel.send(request, on: connection)
} catch {
    fail("cannot reach Marko: \(error.localizedDescription)")
}

// The answer comes in lines; the connection closes when there is nothing more to wait for.
var pending = "", acknowledged = false, closed = false, failed = false
let handle = FileHandle(fileDescriptor: connection)
while case let data = handle.availableData, !data.isEmpty {
    pending += String(decoding: data, as: UTF8.self)
    while let end = pending.firstIndex(of: "\n") {
        let line = String(pending[..<end])
        pending.removeSubrange(...end)
        if line == Channel.acknowledgement {
            acknowledged = true
        } else if line == Channel.closed {
            closed = true
        } else {
            failed = true
            FileHandle.standardError.write(Data("marko: \(line)\n".utf8))
        }
    }
}
if !acknowledged { fail("Marko went away before it answered") }
// Whoever waits for the text, git for one, must not take what was there so far for finished.
if command.wait, !closed { fail("Marko went away while waiting") }
exit(failed ? 1 : 0)
