import Foundation

/// Which folders the user trusts, and with that the one answer to whether a document may fetch
/// what it links to from the network. Anything without a decision is not trusted: a document
/// opens in safe mode, where nothing is fetched on its behalf.
///
/// Trust is for the folder that was at a path when the user said so, and covers the folders
/// below it, except a folder there that was answered with "safe" later: the nearest answer
/// above a document is the one that holds. A folder that is moved leaves its trust behind, and
/// another folder made where a trusted one was does not inherit it.
public final class TrustStore {
    /// The store every editor and window asks. Kept in memory only, until the app itself puts
    /// one here that keeps the user's answers: not a smoke run, and not the tests.
    public static var shared = TrustStore()
    /// Posted after any change, by the store that changed.
    public static let didChange = Notification.Name("MarkoTrustDidChange")

    private let defaults: UserDefaults?
    private let trustedKey = "TrustedFolders", safeKey = "SafeFolders"
    /// The trusted folders by path, each with the number the disk had for the folder then.
    private var trusted: [String: UInt64]
    /// The folders that were answered with "safe": they are not asked about again, and a
    /// trusted folder above one does not cover it.
    private var safe: Set<String>
    /// What was chosen for single documents since the app started, by path. Never kept.
    private var choices: [String: Bool] = [:]

    /// With `defaults` the answers about folders are kept there; without, they end with the store.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        // What is kept is only believed as far as `trust` would have written it.
        let kept = defaults?.dictionary(forKey: trustedKey)?.compactMapValues { ($0 as? NSNumber)?.uint64Value } ?? [:]
        trusted = kept.filter { Self.canBeTrusted($0.key) }
        safe = Set(defaults?.stringArray(forKey: safeKey) ?? [])
    }

    /// The path trust goes by: whole, with links followed and without "." and "..".
    public static func path(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Where files arrive that the user did not ask for by name: downloads, attachments, what
    /// other apps put down for a moment.
    private static let arrivals = [NSHomeDirectory(), NSTemporaryDirectory()].map { path(of: URL(fileURLWithPath: $0)) }

    /// Not every folder can be trusted: the disk, a folder at its top ("/Users", "/Volumes",
    /// "/tmp"), and the home and temporary folders or one above them would be the same as having
    /// no safe mode.
    private static func canBeTrusted(_ path: String) -> Bool {
        path.hasPrefix("/") && path.split(separator: "/").count > 1 && !arrivals.contains { covers(path, $0) }
    }

    public static func canBeTrusted(_ folder: URL) -> Bool {
        canBeTrusted(path(of: folder))
    }

    /// Whether `folder` is `path` or a folder above it, by whole names: "/a/b" is not above "/a/bc".
    private static func covers(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    /// The number the disk has for the folder at `path`, which another folder there has not.
    private static func identity(of path: String) -> UInt64? {
        var status = Darwin.stat()
        return stat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR ? UInt64(status.st_ino) : nil
    }

    /// Whether the folder that was trusted at `path` is still the one there.
    private func isStillThere(_ path: String) -> Bool {
        trusted[path] == Self.identity(of: path)
    }

    /// The trusted folders that are still where they were, in order.
    public var trustedFolders: [String] { trusted.keys.filter(isStillThere).sorted() }

    /// Whether a file or folder is in a trusted folder, or is one, with no folder answered
    /// "safe" in between. The folders are in memory; the disk is asked about the names of `url`
    /// (its links are followed) and about a trusted folder above it, and about nothing while
    /// nothing is trusted.
    public func isTrusted(_ url: URL) -> Bool {
        guard !trusted.isEmpty else { return false }
        let path = Self.path(of: url)
        guard let folder = trusted.keys.filter({ Self.covers($0, path) && isStillThere($0) }).max(by: { $0.count < $1.count }) else { return false }
        // Without regard to case, which a disk may not tell apart: "safe" for too much is safe.
        let folded = path.lowercased()
        return !safe.contains { $0.count >= folder.count && Self.covers($0.lowercased(), folded) }
    }

    /// Whether the user has answered for this folder, either way. One that has no answer is asked about.
    public func isDecided(_ folder: URL) -> Bool {
        isTrusted(folder) || safe.contains(Self.path(of: folder))
    }

    /// The one gate: whether the document at `url` may fetch what it links to. A choice made for
    /// that document since the app started comes first, then its folder's trust. A document
    /// without a file has neither.
    public func allowsRemoteImages(for url: URL?) -> Bool {
        // Nothing is asked of the disk while nothing is trusted and nothing was chosen.
        guard let url, !(trusted.isEmpty && choices.isEmpty) else { return false }
        return choices[Self.path(of: url)] ?? isTrusted(url)
    }

    /// Lets one document fetch or not until the app quits, whatever its folder says. The next
    /// answer about a folder it is in is also the answer for it.
    public func setAllowsRemoteImages(_ allows: Bool, for url: URL) {
        choices[Self.path(of: url)] = allows
        didChange()
    }

    /// An answer about a folder is the answer for everything below it: what was answered
    /// there before is forgotten, by `trust` and by `stopTrusting`.
    private func forgetAnswers(below path: String) {
        trusted = trusted.filter { !Self.covers(path, $0.key) }
        safe = safe.filter { !Self.covers(path, $0) }
    }

    public func trust(_ folder: URL) {
        let path = Self.path(of: folder)
        guard Self.canBeTrusted(path), let identity = Self.identity(of: path) else { return }
        forgetAnswers(below: path)
        trusted[path] = identity
        // What was chosen for single documents in it gives way to the folder's answer.
        choices = choices.filter { !Self.covers(path, $0.key) }
        save()
    }

    /// Answers "safe" for a folder, which takes the trust away from it and from what is below
    /// it. A trusted folder above it stays trusted, for everything else in it.
    public func stopTrusting(_ folder: URL) {
        let path = Self.path(of: folder)
        // Only trust that is taken away takes the documents' own choices with it: declining to
        // trust a folder that was not trusted changes nothing for a document in it.
        if isTrusted(folder) || trusted.keys.contains(where: { Self.covers(path, $0) }) {
            choices = choices.filter { !Self.covers(path, $0.key) }
        }
        forgetAnswers(below: path)
        safe.insert(path)
        save()
    }

    /// Forgets every trusted folder. Each stays answered: it is not asked about again.
    public func stopTrustingAll() {
        safe.formUnion(trusted.keys)
        trusted = [:]
        choices = [:]
        save()
    }

    private func save() {
        defaults?.set(trusted.mapValues { NSNumber(value: $0) }, forKey: trustedKey)
        defaults?.set(safe.sorted(), forKey: safeKey)
        didChange()
    }

    private func didChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
