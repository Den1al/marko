import Foundation

/// Tells whether a path leads off this Mac, without going there.
public nonisolated enum NetworkVolume {
    /// What `path` would be read from when that is not a disk of this Mac: the server and share of
    /// a network volume, or the place where the system would mount one the moment it is touched.
    /// Nil for a path that stays on local disks, whether or not anything is there.
    ///
    /// The path is followed one name at a time, links included, and each step is first looked up
    /// in the kernel's list of what is mounted. Nothing at or below a mount that is not local is
    /// ever asked about, so no server is contacted and nothing is mounted by the question.
    /// Names are compared without regard to case, as the disks that hold mount points do: a path
    /// on a disk that tells "Share" from "share" may be taken for remote when it is not, never
    /// the other way round.
    public static func source(ofPath path: String) -> String? {
        source(ofPath: path, mounts: mounted())
    }

    typealias Mount = (point: String, source: String, isLocal: Bool)

    static func source(ofPath path: String, mounts: [Mount]) -> String? {
        guard mounts.contains(where: { !$0.isLocal }) else { return nil }
        let mounts = mounts.map { (point: $0.point.lowercased(), source: $0.source, isLocal: $0.isLocal) }
        var names = Array(path.split(separator: "/").map(String.init).reversed())
        var reached = "", links = 0
        while let name = names.popLast() {
            if name == "." { continue }
            if name == ".." {
                reached = (reached as NSString).deletingLastPathComponent
                if reached == "/" { reached = "" }
                continue
            }
            let next = reached + "/" + name, folded = next.lowercased()
            // The longest mount point at or above the name is what it is on.
            let mount = mounts.filter { $0.point == "/" || folded == $0.point || folded.hasPrefix($0.point + "/") }.max { $0.point.count < $1.point.count }
            if let mount, !mount.isLocal { return mount.source }
            var status = Darwin.stat()
            // What is not there is on the disk that would hold it.
            guard lstat(next, &status) == 0 else { return nil }
            guard status.st_mode & S_IFMT == S_IFLNK else {
                reached = next
                continue
            }
            links += 1
            // A loop of links leads nowhere.
            guard links <= Int(MAXSYMLINKS), let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next) else { return nil }
            if target.hasPrefix("/") { reached = "" }
            names += target.split(separator: "/").map(String.init).reversed()
        }
        return nil
    }

    /// What is mounted, from the kernel's own list: asking for it touches no volume.
    private static func mounted() -> [Mount] {
        var list = Array(repeating: Darwin.statfs(), count: Int(max(getfsstat(nil, 0, MNT_NOWAIT), 0)))
        let count = getfsstat(&list, Int32(list.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT)
        return list.prefix(Int(max(count, 0))).map { mount in
            func text<T>(_ field: T) -> String {
                withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            let point = text(mount.f_mntonname), type = text(mount.f_fstypename)
            // The automounter's own places are local to the kernel and are where a server gets mounted.
            let isLocal = mount.f_flags & UInt32(MNT_LOCAL) != 0 && type != "autofs"
            return (point, type == "autofs" ? point : text(mount.f_mntfromname), isLocal)
        }
    }
}
