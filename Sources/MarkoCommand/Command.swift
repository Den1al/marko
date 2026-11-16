/// What `marko` was asked for on its command line, before any path is looked at.
public struct Command: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case open, help, version }

    /// A path as it was typed, and the line to put the caret on.
    public struct Target: Equatable, Sendable {
        public var path: String
        public var line: Int?

        public init(path: String, line: Int? = nil) {
            self.path = path
            self.line = line
        }
    }

    public struct UsageError: Error, Equatable {
        public let message: String
    }

    public var action = Action.open
    public var targets: [Target] = []
    public var readsStandardInput = false
    public var wait = false
    public var newWindow = false
    /// `--trust` (true) or `--safe` (false).
    public var trust: Bool?

    public static let usage = """
        usage: marko [options] [file | file:LINE[:COLUMN] | +LINE file | folder | -] ...

          marko                 bring Marko to the front, starting it if need be
          marko notes.md        open a file; one that does not exist yet is made when it is first saved
          marko notes.md:12     open it with the caret on line 12 (also: marko +12 notes.md)
          marko folder          open a folder: the file tree, and no file until one is chosen
          marko -               open what is piped in as a new document

          -w, --wait            return only when the documents have been closed (EDITOR="marko --wait")
          -n, --new-window      always open a new window: not in an empty one, not the folder's own
              --trust           trust the folders named, without being asked; the files named load
                                the images they link to on the web until Marko quits
              --safe            open the folders named in safe mode, without being asked, and stop
                                trusting them; the files named load no remote images
                                (neither is taken in a folder that holds a file of that name)
          -h, --help            show this
          -v, --version         show the version
        """

    /// `exists` says whether a path names something: "notes:2" is a file of that name if there is
    /// one, and line 2 of "notes" otherwise.
    public init(_ arguments: [String], exists: (String) -> Bool) throws(UsageError) {
        var line: Int?, optionsEnded = false
        for argument in arguments {
            if optionsEnded || !argument.hasPrefix("-") {
                if !optionsEnded, argument.hasPrefix("+"), let number = Self.number(argument.dropFirst()) {
                    line = number
                } else {
                    targets.append(Self.target(argument, line: line, exists: exists))
                    line = nil
                }
            } else if argument == "-" {
                readsStandardInput = true
            } else if argument == "--" {
                optionsEnded = true
            } else if argument.hasPrefix("--") {
                // A file of that very name is what `marko *` passes for it: a folder is not
                // trusted because of what a file in it is called.
                if ["--trust", "--safe"].contains(argument), exists(argument) {
                    throw UsageError(message: "\(argument) is also the name of a file here: write ./\(argument) for the file, or use the option from another folder")
                }
                try set(argument.dropFirst(2), as: argument)
            } else {
                for flag in argument.dropFirst() {
                    guard let name = ["w": "wait", "n": "new-window", "h": "help", "v": "version"][flag] else {
                        throw UsageError(message: "unknown option -\(flag)")
                    }
                    try set(name[...], as: argument)
                }
            }
        }
        if let line { throw UsageError(message: "+\(line) needs a file after it") }
        if let trust, action == .open, targets.isEmpty, !readsStandardInput { throw UsageError(message: "\(trust ? "--trust" : "--safe") needs a file or folder") }
    }

    private mutating func set(_ option: Substring, as argument: String) throws(UsageError) {
        switch option {
        case "wait": wait = true
        case "new-window": newWindow = true
        case "trust", "safe":
            guard trust == nil || trust == (option == "trust") else { throw UsageError(message: "--trust and --safe exclude each other") }
            trust = option == "trust"
        case "help": action = .help
        case "version": action = .version
        default: throw UsageError(message: "unknown option \(argument)")
        }
    }

    private static func target(_ argument: String, line: Int?, exists: (String) -> Bool) -> Target {
        guard line == nil, !exists(argument), let (path, number) = numbered(argument) else { return Target(path: argument, line: line) }
        // "name:3:5" as compilers and grep print it: line 3, and the column is dropped.
        if !exists(path), let (file, first) = numbered(path) { return Target(path: file, line: first) }
        return Target(path: path, line: number)
    }

    /// "name:12" taken apart.
    private static func numbered(_ argument: String) -> (path: String, number: Int)? {
        guard let colon = argument.lastIndex(of: ":"), colon != argument.startIndex,
              let number = number(argument[argument.index(after: colon)...]) else { return nil }
        return (String(argument[..<colon]), number)
    }

    /// A number too long to be one is the largest there is: past the last line, which is the last line.
    private static func number(_ text: Substring) -> Int? {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber } ? Int(text) ?? .max : nil
    }
}
