import Foundation
import Testing
@testable import MarkoCommand

@Suite struct CommandTests {
    private typealias Target = Command.Target

    /// Parses as if only the paths in `existing` named something.
    private func parse(_ arguments: String..., existing: Set<String> = []) throws -> Command {
        try Command(arguments, exists: existing.contains)
    }

    private func usageError(_ arguments: String...) -> String? {
        do {
            _ = try Command(arguments) { _ in false }
            return nil
        } catch {
            return error.message
        }
    }

    @Test func nothingAtAllOnlyBringsTheAppForward() throws {
        let command = try parse()
        #expect(command.action == .open && command.targets.isEmpty && !command.readsStandardInput && !command.wait && !command.newWindow)
    }

    @Test func pathsAreKeptAsTypedAndInOrder() throws {
        #expect(try parse("a.md", "../b c.md", "~/notes", "dir/").targets
            == [Target(path: "a.md"), Target(path: "../b c.md"), Target(path: "~/notes"), Target(path: "dir/")])
    }

    @Test func aLineComesAfterAColonOrBeforeThePathWithAPlus() throws {
        #expect(try parse("a.md:12", "+7", "b.md", "c.md").targets
            == [Target(path: "a.md", line: 12), Target(path: "b.md", line: 7), Target(path: "c.md")])
        #expect(try parse("+3", "a.md:9").targets == [Target(path: "a.md:9", line: 3)], "the plus form wins and the name stays whole")
        #expect(try parse("dir/a.md:0012").targets == [Target(path: "dir/a.md", line: 12)])
    }

    @Test func aColumnAfterTheLineIsDroppedAndANumberTooLongIsTheLastLine() throws {
        #expect(try parse("a.md:3:5", "dir/b.md:10:1").targets == [Target(path: "a.md", line: 3), Target(path: "dir/b.md", line: 10)])
        #expect(try parse("a.md:1:2:3").targets == [Target(path: "a.md:1", line: 2)], "two numbers at most")
        #expect(try parse("a.md:99999999999999999999999", "+99999999999999999999999", "b.md").targets
            == [Target(path: "a.md", line: .max), Target(path: "b.md", line: .max)])
    }

    @Test func aColonThatIsPartOfTheNameStaysInIt() throws {
        #expect(try parse("notes:2", existing: ["notes:2"]).targets == [Target(path: "notes:2")], "a file of that very name")
        #expect(try parse("a:b", "a.md:", ":3", "a.md:-3", "a.md:3x", "12:30 notes.md").targets.map(\.path)
            == ["a:b", "a.md:", ":3", "a.md:-3", "a.md:3x", "12:30 notes.md"])
        #expect(try parse("a.md:3:5", existing: ["a.md:3"]).targets == [Target(path: "a.md:3", line: 5)])
        #expect(try parse("+x", "+").targets == [Target(path: "+x"), Target(path: "+")], "a plus without a number is a name")
    }

    @Test func optionsHaveALongAndAShortFormAndMayBeAnywhere() throws {
        let long = try parse("--wait", "a.md", "--new-window"), short = try parse("a.md", "-w", "-n"), joined = try parse("-nw", "a.md")
        #expect(long == short && short == joined)
        #expect(long.wait && long.newWindow && long.targets == [Target(path: "a.md")] && long.action == .open)
        #expect(try [parse("--help"), parse("-h"), parse("--version"), parse("-v", "a.md")].map(\.action) == [.help, .help, .version, .version])
    }

    @Test func aLoneDashIsStandardInput() throws {
        let command = try parse("-", "-w")
        #expect(command.readsStandardInput && command.wait && command.targets.isEmpty)
        #expect(try parse("a.md", "-").readsStandardInput)
    }

    @Test func afterTwoDashesEverythingIsAPath() throws {
        let command = try parse("-w", "--", "-n", "--help", "-", "+4", "a.md:2")
        #expect(command.wait && !command.newWindow && command.action == .open && !command.readsStandardInput)
        #expect(command.targets == [Target(path: "-n"), Target(path: "--help"), Target(path: "-"), Target(path: "+4"), Target(path: "a.md", line: 2)])
    }

    @Test func trustAndSafeAnswerForWhatIsNamedAndExcludeEachOther() throws {
        #expect(try parse("notes").trust == nil, "nothing is said about trust unless asked")
        #expect(try parse("--trust", "docs").trust == true && parse("docs", "--trust", "a.md").targets.count == 2)
        #expect(try parse("--safe", "docs").trust == false && parse("--safe", "--safe", "-").trust == false)
        #expect(usageError("--trust", "--safe", "docs") == "--trust and --safe exclude each other")
        #expect(usageError("docs", "--safe", "--trust") == "--trust and --safe exclude each other")
        #expect(usageError("--trust") == "--trust needs a file or folder" && usageError("-n", "--safe") == "--safe needs a file or folder")
    }

    /// `marko *` in a folder that holds a file named "--trust" passes that name as if it had
    /// been typed. What a file is called must not trust the folders beside it.
    @Test func aFileNamedLikeTheOptionIsNotTheOption() throws {
        func refusal(_ arguments: String..., existing: Set<String>) -> String? {
            do {
                _ = try Command(arguments, exists: existing.contains)
                return nil
            } catch {
                return error.message
            }
        }
        let message = "--trust is also the name of a file here: write ./--trust for the file, or use the option from another folder"
        #expect(refusal("--trust", "a.md", "docs", "sub", existing: ["--trust", "a.md", "docs", "sub"]) == message)
        #expect(refusal("a.md", "--trust", existing: ["--trust", "a.md"]) == message && refusal("-n", "--trust", "docs", existing: ["--trust", "docs"]) == message)
        #expect(refusal("--safe", "docs", existing: ["--safe", "docs"])?.hasPrefix("--safe is also the name of a file here") == true)
        // Named as a file it is one, and where there is no such file the option is the option.
        let named = try parse("--", "--trust", "a.md", existing: ["--trust", "a.md"])
        #expect(named.trust == nil && named.targets == [Target(path: "--trust"), Target(path: "a.md")])
        #expect(try parse("./--trust", "a.md", existing: ["--trust", "./--trust", "a.md"]).trust == nil)
        #expect(try parse("--trust", "docs", existing: ["docs", "--safe"]).trust == true)
    }

    @Test func whatIsNotUnderstoodIsAnErrorThatNamesIt() {
        #expect(usageError("--bogus") == "unknown option --bogus")
        #expect(usageError("a.md", "-wx") == "unknown option -x")
        #expect(usageError("--wait=1") == "unknown option --wait=1")
        #expect(usageError("a.md", "+12") == "+12 needs a file after it")
        #expect(usageError("+12", "-w") == "+12 needs a file after it")
        #expect(usageError("-w", "a.md") == nil)
    }

    @Test func theUsageNamesEveryOption() {
        for option in ["--wait", "-w", "--new-window", "-n", "--help", "-h", "--version", "-v", "--trust", "--safe", "file:LINE", "+LINE"] {
            #expect(Command.usage.contains(option), "\(option)")
        }
    }
}

@Suite struct RequestTests {
    private let folder: URL
    private let files = FileManager.default

    init() throws {
        folder = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("marko-command-tests-\(UUID().uuidString)")
        try files.createDirectory(at: folder.appendingPathComponent("docs/deep"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("docs/a.md"))
    }

    private func item(_ path: String, line: Int? = nil, in directory: String? = nil) throws -> Request.Item {
        try Request.Item(Command.Target(path: path, line: line), in: directory ?? folder.path)
    }

    @Test func aPathIsTakenFromTheFolderItWasTypedIn() throws {
        defer { try? files.removeItem(at: folder) }
        let a = folder.path + "/docs/a.md"
        #expect(try item("docs/a.md", line: 4) == Request.Item(path: a, line: 4))
        #expect(try item("a.md", in: folder.path + "/docs").path == a)
        #expect(try item("../a.md", in: folder.path + "/docs/deep").path == a)
        #expect(try item("./docs/../docs//a.md").path == a)
        #expect(try item(a, in: "/usr").path == a, "an absolute path is itself")
        #expect(try [item("docs/"), item("docs")].map(\.path) == [folder.path + "/docs", folder.path + "/docs"])
        #expect(try item(".").path == folder.path)
    }

    @Test func aTildeIsTheHomeFolder() throws {
        defer { try? files.removeItem(at: folder) }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        #expect(try item("~").path == home)
        #expect(try item("~/").path == home)
    }

    @Test func linksAreFollowedSoOneFileHasOnePath() throws {
        defer { try? files.removeItem(at: folder) }
        try files.createSymbolicLink(atPath: folder.path + "/link.md", withDestinationPath: "docs/a.md")
        try files.createSymbolicLink(atPath: folder.path + "/shortcut", withDestinationPath: "docs")
        #expect(try item("link.md").path == folder.path + "/docs/a.md")
        #expect(try item("shortcut/a.md").path == folder.path + "/docs/a.md")
        #expect(try item("shortcut").path == folder.path + "/docs")
        #expect(try item("shortcut/new.md").path == folder.path + "/docs/new.md", "also for a file that is not there yet")
    }

    /// "/tmp", "/var" and "/etc" are links to folders in "/private", and Foundation gives a path
    /// that leads there back as the link: what counts is what the link leads to.
    @Test func aFolderOrFileReachedThroughALinkTheSystemKeepsIsOpened() throws {
        defer { try? files.removeItem(at: folder) }
        #expect(try ["/tmp", "/var", "/etc", "/private/tmp", "/tmp/"].map { try item($0).path } == ["/tmp", "/var", "/etc", "/tmp", "/tmp"])
        try files.createSymbolicLink(atPath: folder.path + "/scratch", withDestinationPath: "/tmp")
        #expect(try item("scratch").path == "/tmp", "also through a link of the user's")
        let inside = "/tmp/marko-command-tests-\(UUID().uuidString)"
        try files.createDirectory(atPath: inside, withIntermediateDirectories: false)
        defer { try? files.removeItem(atPath: inside) }
        files.createFile(atPath: inside + "/a.md", contents: Data("a".utf8))
        #expect(try [item(inside), item("/private" + inside + "/a.md"), item(inside + "/new.md")].map(\.path) == [inside, inside + "/a.md", inside + "/new.md"])
        // What a link leads to still has to be a file or a folder.
        try files.createSymbolicLink(atPath: folder.path + "/nothing", withDestinationPath: "/dev/null")
        #expect(throws: Request.PathError(message: "nothing: neither a file nor a folder; text is piped in with \"marko -\"")) { try item("nothing") }
    }

    @Test func aFileNeedNotExistButItsFolderMust() throws {
        defer { try? files.removeItem(at: folder) }
        #expect(try item("docs/new.md", line: 2) == Request.Item(path: folder.path + "/docs/new.md", line: 2))
        #expect(throws: Request.PathError(message: "nowhere/new.md: there is no folder \(folder.path)/nowhere to make it in")) {
            try item("nowhere/new.md")
        }
        #expect(throws: Request.PathError.self) { try item("docs/a.md/new.md") }
    }

    private func refusal(_ path: String, in directory: String? = nil) -> String? {
        do {
            _ = try item(path, in: directory)
            return nil
        } catch {
            return (error as? Request.PathError)?.message
        }
    }

    @Test func whatTheAppCouldNotOpenIsRefusedWithAReason() throws {
        defer { try? files.removeItem(at: folder) }
        #expect(refusal("") == "an empty path names nothing to open")
        #expect(refusal("x.md", in: "") == "x.md: the current folder no longer exists", "a relative path typed in a folder that was deleted")
        #expect(try item(folder.path + "/docs/a.md", in: "").path == folder.path + "/docs/a.md", "a whole path needs no folder")
        // A device or a pipe, such as the shell's <(command), is not the same thing in the app.
        #expect(refusal("/dev/null") == "/dev/null: neither a file nor a folder; text is piped in with \"marko -\"")

        let locked = folder.path + "/locked"
        try files.createDirectory(atPath: locked, withIntermediateDirectories: true)
        files.createFile(atPath: locked + "/x.md", contents: Data("x".utf8))
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        #expect(refusal("locked/x.md") == "locked/x.md: the folder \(locked) may not be read", "not a new empty document of that name")
        #expect(refusal("locked") == "locked: the folder may not be read")
    }

    @Test func aRequestSurvivesTheTripAsJSON() throws {
        defer { try? files.removeItem(at: folder) }
        var request = Request()
        #expect(!request.opensSomething)
        request.items = [Request.Item(path: "/a b/é.md", line: 3), Request.Item(path: "/dir")]
        request.text = "# piped\n"
        request.wait = true
        request.newWindow = true
        #expect(try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request)) == request)
        request.trust = false
        #expect(try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request)).trust == false)
        #expect(try JSONDecoder().decode(Request.self, from: Data(#"{"items":[],"wait":false,"newWindow":false}"#.utf8)).trust == nil, "a tool that says nothing leaves trust alone")
        #expect(request.opensSomething)
    }
}

@Suite struct ChannelTests {
    @Test func theSocketIsInTheUsersTemporaryFolderUnlessNamed() {
        let path = Channel.socketPath(environment: ["TMPDIR": "/elsewhere"])
        #expect(path.hasSuffix("/local.marko.socket") && path.hasPrefix("/") && !path.hasPrefix("/elsewhere"))
        #expect(path.utf8.count < 104, "it fits a socket address")
        #expect(Channel.socketPath(environment: ["MARKO_SOCKET": "/tmp/x"]) == "/tmp/x")
    }

    @Test func whatIsWrittenAtOneEndArrivesAtTheOtherAndOnlyOneListens() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("marko-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("socket").path

        #expect(Channel.connect(to: path) == nil, "nobody is listening yet")
        let listener = try #require(Channel.listen(at: path))

        let client = try #require(Channel.connect(to: path)), server = try #require(Channel.accept(on: listener))
        let near = FileHandle(fileDescriptor: client, closeOnDealloc: true), far = FileHandle(fileDescriptor: server, closeOnDealloc: true)
        try near.write(contentsOf: Data("request".utf8))
        shutdown(client, SHUT_WR)
        #expect(try far.readToEnd() == Data("request".utf8))
        try far.write(contentsOf: Data("ok\n".utf8))
        shutdown(server, SHUT_WR)
        #expect(try near.readToEnd() == Data("ok\n".utf8))
        #expect(throws: (any Error).self, "writing after the end is an error, not a signal that ends the app") { try far.write(contentsOf: Data("late".utf8)) }
        #expect(Channel.listen(at: path) == nil, "a second instance leaves the first one's socket alone")
        #expect(Channel.listen(at: String(repeating: "x", count: 200)) == nil, "a path too long for a socket")
    }

    @Test func aSocketLeftBehindIsReplacedAndAnythingElseIsLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("marko-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // What an instance that is gone leaves: a socket file nobody listens on.
        let path = folder.appendingPathComponent("socket").path, gone = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(Channel.withAddress(of: path) { bind(gone, $0, $1) } == 0)
        close(gone)
        #expect(FileManager.default.fileExists(atPath: path) && Channel.connect(to: path) == nil)
        let listener = try #require(Channel.listen(at: path))
        defer { close(listener) }
        let client = try #require(Channel.connect(to: path))
        close(client)

        // `MARKO_SOCKET` naming a file by mistake does not cost the file.
        let file = folder.appendingPathComponent("notes.md")
        try Data("keep".utf8).write(to: file)
        #expect(Channel.listen(at: file.path) == nil)
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
    }

    /// A listener in a folder of its own, with one connection made to it: the tool's end and the app's.
    private func connection() throws -> (client: Int32, server: Int32, cleanUp: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("marko-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let listener = try #require(Channel.listen(at: folder.appendingPathComponent("socket").path))
        let client = try #require(Channel.connect(to: folder.appendingPathComponent("socket").path)), server = try #require(Channel.accept(on: listener))
        return (client, server, {
            [client, server, listener].forEach { close($0) }
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private var request: Request {
        var request = Request()
        request.items = [Request.Item(path: "/a b/é.md", line: 3)]
        request.text = "# piped\n\nwith lines\n"
        return request
    }

    @Test func aRequestSentIsTheRequestReceived() throws {
        let (client, server, cleanUp) = try connection()
        defer { cleanUp() }
        try Channel.send(request, on: client)
        #expect(Channel.receive(on: server) == request)
    }

    /// The interleaving that lost requests: the app is already reading when the tool closes its
    /// writing side, and is not woken by that. Here the tool never closes it at all.
    @Test func aRequestEndsAtItsLineBreakNotWhenTheToolStopsWriting() throws {
        let (client, server, cleanUp) = try connection()
        defer { cleanUp() }
        try FileHandle(fileDescriptor: client).write(contentsOf: JSONEncoder().encode(request) + Data("\n".utf8))
        let started = Date()
        #expect(Channel.receive(on: server) == request)
        #expect(Date().timeIntervalSince(started) < Double(Channel.readTimeout) / 2, "it did not wait for the end of the connection")
    }

    @Test func aRequestLongerThanTheSocketHoldsArrivesInPieces() throws {
        let (client, server, cleanUp) = try connection()
        defer { cleanUp() }
        var piped = request
        piped.text = String(repeating: "a line of piped text\n", count: 200_000)
        let long = piped
        // The app reads while the tool is still writing.
        let sender = Thread { try? Channel.send(long, on: client) }
        sender.start()
        #expect(Channel.receive(on: server) == long)
    }

    @Test func aToolFromBeforeTheLineBreakIsStillUnderstood() throws {
        let (client, server, cleanUp) = try connection()
        defer { cleanUp() }
        try FileHandle(fileDescriptor: client).write(contentsOf: JSONEncoder().encode(request))
        shutdown(client, SHUT_WR)
        #expect(Channel.receive(on: server) == request)
    }

    /// Such a tool's request whose end the app is not woken for is taken when the time is up.
    @Test func aWholeRequestWithoutAnEndIsTakenWhenNothingMoreComes() throws {
        let (client, server, cleanUp) = try connection()
        defer { cleanUp() }
        try FileHandle(fileDescriptor: client).write(contentsOf: JSONEncoder().encode(request))
        #expect(Channel.receive(on: server) == request)
    }

    @Test func aRequestCutShortIsNone() throws {
        let (client, server, cleanUp) = try connection()
        defer { cleanUp() }
        try FileHandle(fileDescriptor: client).write(contentsOf: JSONEncoder().encode(request).dropLast(5))
        shutdown(client, SHUT_WR)
        #expect(Channel.receive(on: server) == nil)
    }

    @Test func aClientThatSaysNothingIsNotWaitedForForEver() throws {
        let (_, server, cleanUp) = try connection()
        defer { cleanUp() }
        // The client neither writes nor closes: reading gives up instead of holding its thread.
        #expect(Channel.receive(on: server) == nil)
    }
}
