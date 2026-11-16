import AppKit
import FixtureSupport
import MarkoCommand
import Testing
@testable import MarkoApp
@testable import MarkoEditor

/// Counts the connections made to a port of this Mac that nothing else knows: what a part of
/// the system that does not load through `URLSession` would reach if it fetched anything.
private nonisolated final class Listener {
    private let socket: Int32
    let port: UInt16

    init() {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(socket, $0, length)
                _ = getsockname(socket, $0, &length)
            }
        }
        listen(socket, 16)
        _ = fcntl(socket, F_SETFL, O_NONBLOCK)
        self.socket = socket
        port = UInt16(bigEndian: address.sin_port)
    }

    /// How many connections have arrived since the last time this was asked.
    func connections() -> Int {
        var count = 0
        while case let connection = accept(socket, nil, nil), connection >= 0 {
            count += 1
            close(connection)
        }
        return count
    }

    deinit { close(socket) }
}

extension EditorTests {
    /// Safe mode and folder trust: nothing is fetched for a document unless its folder is
    /// trusted or the user asked for that document. `WebStub` stands where the network would
    /// be and tells what was asked of it, which in safe mode must be nothing.
    @Suite struct SafeModeTests {
        private let theme = Theme.standard
        private let folder: TemporaryFolder
        private let files = FileManager.default

        init() throws {
            NSApplication.shared.setActivationPolicy(.accessory)
            WebStub.install()
            // Every test starts with nothing trusted and nothing asked about.
            TrustStore.shared = TrustStore()
            DocumentWindowController.asksAboutTrust = false
            folder = try TemporaryFolder()
        }

        private func picture(_ w: EditorWindow, at offset: Int) -> ShownImage? {
            w.displayAttributes(at: offset)[.picture] as? ShownImage
        }

        /// A host no other test asks for, so that what the stub saw is this test's.
        private func uniqueHost(_ name: String = "images") -> String {
            "\(name)-\(UUID().uuidString.lowercased()).marko.test"
        }

        /// Long enough for a request that was started to reach the stub.
        private func settle() async throws {
            try await Task.sleep(for: .milliseconds(300))
        }

        private func closeAll() {
            for document in NSDocumentController.shared.documents { document.close() }
            for controller in DocumentWindowController.all { controller.window?.close() }
            folder.remove()
        }

        /// A store that keeps its answers in a file of the test's folder, as the app's keeps them
        /// in the user's settings: a second one made for the same file is the app started again.
        private func keptStore() -> TrustStore {
            TrustStore(defaults: UserDefaults(suiteName: folder["settings"].path))
        }

        // MARK: the store

        @Test func nothingIsTrustedUntilTheUserSaysSoAndTrustCoversTheFoldersBelow() throws {
            defer { folder.remove() }
            let store = TrustStore()
            let project = try folder.add("project/docs/deep/a.md").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try folder.add("projectile/b.md")
            #expect(!store.isTrusted(project) && !store.isDecided(project) && store.trustedFolders.isEmpty)
            #expect(!store.allowsRemoteImages(for: folder["project/docs/deep/a.md"]) && !store.allowsRemoteImages(for: nil))

            store.trust(project)
            #expect(store.isTrusted(project) && store.isDecided(project) && store.trustedFolders == [project.path])
            #expect(store.isTrusted(folder["project/docs/"]) && store.allowsRemoteImages(for: folder["project/docs/deep/a.md"]))
            #expect(store.isDecided(folder["project/docs/"]), "a folder inside a trusted one is not asked about")
            // By whole names: a folder whose name only starts the same is another folder, and
            // neither the folder above nor the disk is trusted with it.
            #expect(!store.isTrusted(folder["projectile/"]) && !store.allowsRemoteImages(for: folder["projectile/b.md"]))
            #expect(!store.isTrusted(folder.url) && !store.isTrusted(URL(fileURLWithPath: "/")) && !store.isTrusted(URL(fileURLWithPath: NSHomeDirectory())))
            #expect(!store.isDecided(folder.url))
        }

        @Test func theWholeDiskCannotBeTrustedAndTrustingAFolderInTheHomeFolderDoesNotTrustIt() throws {
            defer { folder.remove() }
            let store = TrustStore(), root = URL(fileURLWithPath: "/")
            #expect(!TrustStore.canBeTrusted(root) && TrustStore.canBeTrusted(folder.url))
            // Nor a folder at the top of the disk, nor the home or the temporary folder or one
            // above them, under any of their names: with one of those trusted, a document that
            // was downloaded would load its images.
            let home = NSHomeDirectory(), temporary = NSTemporaryDirectory(), download = URL(fileURLWithPath: home + "/Downloads/x.md")
            let wide = ["/", "/..", "/Users", "/Volumes", "/private", "/private/var", "/var", "/tmp", "/private/tmp", "/System", "/Library", home, home + "/",
                        (home as NSString).deletingLastPathComponent, "/System/Volumes/Data/Users", "/System/Volumes/Data" + home, temporary,
                        temporary + "/..", "/private" + temporary, "/var/folders", "/private/var/folders"]
            for path in wide {
                #expect(!TrustStore.canBeTrusted(URL(fileURLWithPath: path)), "\(path)")
                store.trust(URL(fileURLWithPath: path))
            }
            #expect(store.trustedFolders.isEmpty && !store.isTrusted(folder.url) && !store.isTrusted(root))
            #expect(!store.allowsRemoteImages(for: download) && !store.allowsRemoteImages(for: folder["x.md"]))
            // What was kept is read with the same care: such an entry, or one that is no path, trusts nothing.
            let defaults = try #require(UserDefaults(suiteName: folder["settings"].path))
            var entries = ["": 2, "relative": 2, folder.url.path + "/gone": 2]
            for path in wide { entries[path] = 2 }
            defaults.set(entries, forKey: "TrustedFolders")
            let kept = TrustStore(defaults: defaults)
            #expect(kept.trustedFolders.isEmpty && !kept.isTrusted(folder.url) && !kept.isTrusted(URL(fileURLWithPath: NSHomeDirectory())) && !kept.allowsRemoteImages(for: download))
            // A folder of the home folder that is trusted trusts neither the home folder nor its other folders.
            let parent = try folder.add("home/notes/a.md").deletingLastPathComponent().deletingLastPathComponent()
            try folder.add("home/other/b.md")
            store.trust(folder["home/notes/"])
            #expect(!store.isTrusted(parent) && !store.isTrusted(folder["home/other/"]) && store.isTrusted(folder["home/notes/a.md"]))
        }

        @Test func aFolderAnsweredSafeInsideATrustedOneStaysSafeAndTheTrustedOneStaysTrusted() throws {
            defer { folder.remove() }
            let work = try folder.add("Work/notes/a.md").deletingLastPathComponent().deletingLastPathComponent()
            let cloned = try folder.add("Work/Cloned/repo/docs/z.md").deletingLastPathComponent().deletingLastPathComponent()
            try folder.add("Work/Cloned/other/y.md")
            let store = keptStore()
            store.trust(work)
            #expect(store.allowsRemoteImages(for: folder["Work/Cloned/repo/docs/z.md"]) && store.isDecided(cloned))
            store.stopTrusting(cloned)
            #expect(!store.isTrusted(cloned) && store.isDecided(cloned) && !store.allowsRemoteImages(for: folder["Work/Cloned/repo/docs/z.md"]))
            #expect(!store.isTrusted(folder["Work/Cloned/repo/docs/"]) && !store.isDecided(folder["Work/Cloned/repo/docs/"]), "a folder in it is asked about")
            #expect(store.isTrusted(work) && store.isDecided(work) && store.trustedFolders == [work.path], "the folder above keeps its trust")
            #expect(store.allowsRemoteImages(for: folder["Work/notes/a.md"]) && store.allowsRemoteImages(for: folder["Work/Cloned/other/y.md"]))
            // Under another spelling, through a link, and for a file that is not there yet.
            try files.createSymbolicLink(atPath: folder["Work/notes/in"].path, withDestinationPath: "../CLONED/REPO")
            for path in ["work/cloned/REPO/docs/z.md", "Work/notes/in/docs/z.md", "Work/Cloned/repo/new.md", "Work/CLONED/Repo/new/new.md", "Work/notes/../Cloned/repo/docs/z.md"] {
                #expect(!store.allowsRemoteImages(for: folder[path]), "\(path)")
            }
            let relaunched = keptStore()
            #expect(relaunched.isTrusted(folder["Work/notes/a.md"]) && !relaunched.isTrusted(folder["Work/Cloned/repo/docs/z.md"]), "both answers are kept")
            // The nearest answer holds: a folder trusted inside the safe one is trusted, and
            // the answer for a folder is the answer for all that is in it, either way.
            store.trust(folder["Work/Cloned/repo/docs/"])
            #expect(store.isTrusted(folder["Work/Cloned/repo/docs/z.md"]) && !store.isTrusted(folder["Work/Cloned/repo/new.md"]))
            store.stopTrusting(cloned)
            #expect(!store.isTrusted(folder["Work/Cloned/repo/docs/z.md"]) && store.trustedFolders == [work.path])
            store.trust(work)
            #expect(store.isTrusted(folder["Work/Cloned/repo/docs/z.md"]), "trusting the folder above again is for the folders in it")
            store.stopTrusting(work)
            #expect(store.trustedFolders.isEmpty && !store.isTrusted(folder["Work/notes/a.md"]) && store.isDecided(work))
        }

        @Test func bothAnswersAreKeptAcrossARelaunchAndASafeAnswerIsNotAskedAgain() throws {
            defer { folder.remove() }
            let trusted = try folder.add("trusted/a.md").deletingLastPathComponent(), safe = try folder.add("safe/b.md").deletingLastPathComponent()
            let undecided = try folder.add("undecided/c.md").deletingLastPathComponent()
            let store = keptStore()
            store.trust(trusted)
            store.stopTrusting(safe)
            #expect(store.isDecided(safe) && !store.isTrusted(safe) && !store.isDecided(undecided))

            let relaunched = keptStore()
            #expect(relaunched.trustedFolders == [trusted.path] && relaunched.isTrusted(folder["trusted/a.md"]))
            #expect(relaunched.isDecided(safe) && !relaunched.isTrusted(safe), "the answer “safe” is remembered")
            #expect(!relaunched.isDecided(undecided))
            // The answer can be changed, and the list cleared: each folder stays answered.
            relaunched.trust(safe)
            #expect(keptStore().trustedFolders == [safe.path, trusted.path])
            relaunched.stopTrustingAll()
            let cleared = keptStore()
            #expect(cleared.trustedFolders.isEmpty && !cleared.isTrusted(trusted) && cleared.isDecided(trusted) && cleared.isDecided(safe))
        }

        @Test func aFolderIsTheSameFolderThroughALinkAndThroughDotDot() throws {
            defer { folder.remove() }
            let real = try folder.add("real/sub/a.md").deletingLastPathComponent().deletingLastPathComponent()
            try files.createSymbolicLink(atPath: folder["link"].path, withDestinationPath: "real")
            let store = keptStore()
            store.trust(folder["link"])
            #expect(store.trustedFolders == [real.path], "kept as the folder it is")
            #expect(store.isTrusted(real) && store.isTrusted(folder["link/sub/a.md"]) && store.isTrusted(folder["real/sub/../sub/a.md"]))
            #expect(store.isTrusted(URL(fileURLWithPath: folder.url.path + "/other/../real/./sub")))
            #expect(keptStore().isTrusted(folder["link/sub/"]))
            store.stopTrusting(URL(fileURLWithPath: folder.url.path + "/real/sub/.."))
            #expect(!store.isTrusted(real) && !store.isTrusted(folder["link"]) && store.isDecided(folder["link"]))

            // A link inside a trusted folder that leads out of it is not in it.
            try folder.add("outside/evil.md")
            store.trust(real)
            try files.createSymbolicLink(atPath: folder["real/out"].path, withDestinationPath: "../outside")
            #expect(!store.isTrusted(folder["real/out/evil.md"]) && !store.allowsRemoteImages(for: folder["real/out/evil.md"]))
        }

        @Test func aFolderThatIsMovedOrDeletedLeavesNoTrustBehind() throws {
            defer { folder.remove() }
            let old = try folder.add("old/a.md").deletingLastPathComponent()
            let store = keptStore()
            store.trust(old)
            // Moved: the folder is not trusted where it is now, and nothing is where it was.
            try files.moveItem(at: old, to: folder["moved"])
            #expect(!store.isTrusted(folder["moved/a.md"]) && !store.isTrusted(old) && store.trustedFolders.isEmpty)
            // Another folder made later, somewhere else or in the very place, is not the one that was trusted.
            try folder.add("new/a.md")
            #expect(!store.isTrusted(folder["new/a.md"]) && !store.isDecided(folder["new/"]))
            try folder.add("old/a.md")
            #expect(!store.isTrusted(folder["old/a.md"]) && !store.isDecided(old), "it is asked about like any new folder")
            #expect(!keptStore().isTrusted(folder["old/a.md"]) && keptStore().trustedFolders.isEmpty)
            // Deleted and made again likewise; a file where the folder was is no folder.
            store.trust(old)
            #expect(store.isTrusted(folder["old/a.md"]))
            try files.removeItem(at: old)
            #expect(!store.isTrusted(old))
            try folder.add("old")
            #expect(!store.isTrusted(old) && !store.isTrusted(folder["old/a.md"]))
        }

        @Test func aChoiceForOneDocumentIsForThatDocumentAndEndsWithTheApp() throws {
            defer { folder.remove() }
            let a = try folder.add("a.md"), b = try folder.add("b.md"), store = keptStore()
            store.setAllowsRemoteImages(true, for: a)
            #expect(store.allowsRemoteImages(for: a) && !store.allowsRemoteImages(for: b))
            #expect(!store.isTrusted(a) && store.trustedFolders.isEmpty && !store.isDecided(folder.url), "nothing is trusted by it")
            #expect(!keptStore().allowsRemoteImages(for: a), "the app started again knows nothing of it")
            // Inside a trusted folder one document can be kept from loading; the next answer about the folder is for it too.
            store.trust(folder.url)
            #expect(store.allowsRemoteImages(for: b))
            store.setAllowsRemoteImages(false, for: b)
            #expect(!store.allowsRemoteImages(for: b) && store.allowsRemoteImages(for: a))
            store.setAllowsRemoteImages(true, for: a)
            store.stopTrusting(folder.url)
            #expect(!store.allowsRemoteImages(for: a) && !store.allowsRemoteImages(for: b), "stopping to trust the folder takes the choice back")
            // Saying "safe" for a folder that was not trusted takes no trust away, and no choice.
            store.setAllowsRemoteImages(true, for: a)
            store.stopTrusting(folder.url)
            #expect(store.allowsRemoteImages(for: a) && !store.allowsRemoteImages(for: b))
        }

        // MARK: what is blocked

        @Test func aFileOpenedOnItsOwnFetchesNothingAndShowsWhatWasBlocked() async throws {
            defer { folder.remove() }
            let host = uniqueHost()
            let text = "before\n\n![A lake](https://\(host)/lake.png)\n\nin a line ![x](https://\(host)/dot.png) of text\n"
            let w = EditorWindow(text, documentURL: try folder.add("single.md"))
            defer { w.close() }
            let mark = w.offset(of: "![A lake"), inline = w.offset(of: "![x")
            let blocked = try #require(picture(w, at: mark))
            #expect(blocked.image == nil && blocked.isBlocked && !blocked.isMissing)
            #expect(blocked.label == "Remote image blocked\n\(host)", "it says what was blocked, and from where")
            #expect(blocked.size == theme.imagePlaceholderSize, "as large as an image that is loading: nothing moves but the image arriving")
            #expect(picture(w, at: inline)?.isBlocked == true)
            #expect(w.editor.isInSafeMode && !w.editor.loadsRemoteImages && !w.editor.safeMode.isHidden)
            #expect(await wait { w.editor.safeMode.image?.accessibilityDescription == "Safe mode" } && w.editor.safeMode.toolTip?.hasPrefix("Safe mode.") == true)
            #expect(w.editor.safeMode.superview?.superview?.isHidden == false, "the mark shows with the word count")
            // The mark can be pointed at and read out; the rest of the readout is the text behind it to a click.
            let shield = w.editor.safeMode, count = w.editor.wordCount
            #expect(shield.isAccessibilityElement() && shield.accessibilityRole() == .image && shield.accessibilityLabel() == "Safe mode")
            #expect(shield.accessibilityHelp() == shield.toolTip)
            w.window.contentView?.layoutSubtreeIfNeeded()
            let onMark = shield.convert(NSPoint(x: shield.bounds.midX, y: shield.bounds.midY), to: nil)
            let onCount = count.convert(NSPoint(x: count.bounds.midX, y: count.bounds.midY), to: nil)
            #expect(w.window.contentView?.hitTest(onMark) === shield && w.window.contentView?.hitTest(onCount) is EditorTextView)
            let rect = w.inColumn(try #require((w.fragment(at: mark) as? BlockFragment)?.pictures.first?.rect), ofFragmentAt: mark)
            #expect(!w.pixels().isBackground(rect.midX, rect.midY - 8), "the placeholder is drawn")
            try await settle()
            #expect(WebStub.requests(to: host).isEmpty, "nothing was asked of the network")
            #expect(w.textView.string == text && w.storageProblem == nil)
        }

        @Test func everyFormOfARemoteAddressIsBlockedWithoutARequest() async throws {
            defer { folder.remove() }
            let host = uniqueHost("forms")
            let cache = ImageCache()
            cache.documentURL = try folder.add("doc.md")
            let blocked = ["http://\(host)/a.png", "https://\(host)/a.png", "HTTPS://\(host)/b.png", "Http://\(host):8080/c.png",
                           "//\(host)/d.png", "  //\(host)/e.png", "file://\(host)/share/f.png", "FILE://\(host)/g.png", "https://user:pw@\(host)/h.png"]
            for destination in blocked {
                guard case .blocked(let source) = cache.entry(for: destination) else {
                    Issue.record("\(destination) is not blocked")
                    continue
                }
                #expect(source == host, "\(destination)")
            }
            // Any other scheme is never fetched at all, in safe mode or out of it.
            let never = ["ftp://\(host)/a.png", "smb://\(host)/share/a.png", "afp://\(host)/a.png", "nfs://\(host)/a.png", "webdav://\(host)/a.png",
                         "data:image/png;base64,iVBORw0KGgo=", "javascript:fetch('https://\(host)')", "x-marko://\(host)/a.png"]
            for allows in [false, true] {
                cache.allowsRemote = allows
                for destination in never {
                    guard case .missing = cache.entry(for: destination) else {
                        Issue.record("\(destination) is not simply missing")
                        continue
                    }
                }
            }
            cache.allowsRemote = false
            // A file of this Mac is read as ever, also named as a "file:" address without a host or on this host.
            let image = try folder.add("pic.png", Fixtures.data("images/pic.png"))
            for destination in ["pic.png", image.path, image.absoluteString, "file://localhost\(image.path)"] {
                guard case .image = cache.entry(for: destination) else {
                    Issue.record("\(destination) is not shown")
                    continue
                }
            }
            try await settle()
            #expect(WebStub.requests(to: host).isEmpty, "nothing was asked of the network")
        }

        /// A file named as an image is read to learn its size, and its pixels are made when it
        /// is drawn: neither for one that would take seconds or gigabytes, wherever it is.
        @Test func anImageTooLargeToReadOrToMakeIsMissingWhereverItIs() async throws {
            defer { folder.remove() }
            let data = try Fixtures.data("images/pic.png"), cache = ImageCache()
            cache.documentURL = try folder.add("docs/doc.md")
            func isShown(_ destination: String, in cache: ImageCache) -> Bool {
                if case .image = cache.entry(for: destination) { true } else { false }
            }
            // The picture with nothing after it, up to a size: the disk keeps no room for the nothing.
            for (name, size) in [("fits.png", ImageCache.byteLimit), ("large.png", ImageCache.byteLimit + 1), ("huge.png", 8 << 30)] {
                let handle = try FileHandle(forWritingTo: try folder.add(name, data))
                try handle.truncate(atOffset: UInt64(size))
                try handle.close()
            }
            let started = Date()
            #expect(isShown("../fits.png", in: cache) && !isShown("../large.png", in: cache) && !isShown(folder["huge.png"].path, in: cache))
            try files.createSymbolicLink(atPath: folder["docs/link.png"].path, withDestinationPath: "../huge.png")
            #expect(!isShown("link.png", in: cache) && !isShown(folder["huge.png"].absoluteString, in: cache))
            #expect(Date().timeIntervalSince(started) < 1, "none of the large ones was read")

            // By pixels: the file can be small and the picture it unpacks to enormous.
            try folder.add("docs/pic.png", data)
            let strict = ImageCache()
            strict.documentURL = cache.documentURL
            strict.pixelLimit = 640 * 360 - 1
            #expect(isShown("pic.png", in: cache) && !isShown("pic.png", in: strict))
            strict.pixelLimit = 640 * 360
            strict.forget()
            #expect(isShown("pic.png", in: strict))
            // One from the web likewise.
            let url = try #require(URL(string: "https://\(uniqueHost("large"))/pic.png"))
            WebStub.responses[url] = data
            defer { WebStub.responses[url] = nil }
            strict.pixelLimit = 640 * 360 - 1
            strict.allowsRemote = true
            _ = strict.entry(for: url.absoluteString)
            #expect(await wait { if case .missing = strict.entry(for: url.absoluteString) { true } else { false } })
        }

        @Test func aPathIsFollowedToTheVolumeItIsOnWithoutGoingThere() throws {
            defer { folder.remove() }
            try folder.add("local/pic.png")
            try folder.add("Volumes/")
            // Where the folder really is, as the kernel names what is mounted.
            let root = try #require(folder.url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            // As if a server were mounted in the test's folder, and the automounter had a place there.
            let mounts: [NetworkVolume.Mount] = [
                ("/", "/dev/disk1", true), (root + "/Volumes/share", "//guest@nas.marko.test/share", false), (root + "/net", root + "/net", false),
            ]
            func source(_ path: String) -> String? { NetworkVolume.source(ofPath: root + "/" + path, mounts: mounts) }
            #expect(source("local/pic.png") == nil && source("local/missing.png") == nil && source("Volumes/other/x.png") == nil)
            #expect(source("Volumes/share") == "//guest@nas.marko.test/share" && source("Volumes/share/deep/x.png") == "//guest@nas.marko.test/share")
            #expect(source("Volumes/sharefoo/x.png") == nil, "by whole names")
            // In any spelling: the disk that holds a mount point does not tell them apart.
            try files.createSymbolicLink(atPath: root + "/local/shout.png", withDestinationPath: root + "/VOLUMES/Share/x.png")
            for path in ["Volumes/SHARE/x.png", "VOLUMES/share", "volumes/Share/deep/x.png", "local/shout.png", "local/../volumes/SHARE/x.png"] {
                #expect(source(path) == "//guest@nas.marko.test/share", "\(path)")
            }
            #expect(source("NET/attacker.marko.test/x.png") == root + "/net" && source("Volumes/SHAREFOO/x.png") == nil)
            #expect(source("net/attacker.marko.test/x.png") == root + "/net")
            #expect(source("local/../Volumes/share/x.png") != nil && source("local/./../net/host/x.png") != nil)
            // Through links, to a folder or to the file itself, relative or whole, one after another.
            try files.createSymbolicLink(atPath: root + "/local/remote.png", withDestinationPath: "../Volumes/share/x.png")
            try files.createSymbolicLink(atPath: root + "/local/dir", withDestinationPath: root + "/net/host")
            try files.createSymbolicLink(atPath: root + "/local/hop", withDestinationPath: "dir/sub")
            try files.createSymbolicLink(atPath: root + "/local/loop", withDestinationPath: "loop")
            try files.createSymbolicLink(atPath: root + "/local/near.png", withDestinationPath: "pic.png")
            #expect(source("local/remote.png") == "//guest@nas.marko.test/share" && source("local/dir/x.png") == root + "/net")
            #expect(source("local/hop/x.png") == root + "/net")
            #expect(source("local/loop/x.png") == nil && source("local/near.png") == nil)
            #expect(NetworkVolume.source(ofPath: root + "/Volumes/share/x.png", mounts: [("/", "/dev/disk1", true)]) == nil, "nothing is mounted there")

            // On the Mac the tests run on, as it is: the automounter's place for home folders, where there is one.
            // The cache blocks an image there, also behind a link, and the tree does not follow the link.
            let automounted = "/System/Volumes/Data/home"
            guard NetworkVolume.source(ofPath: automounted + "/x.png") != nil else { return }
            try files.createSymbolicLink(atPath: root + "/local/away.png", withDestinationPath: automounted + "/someone/x.png")
            try files.createSymbolicLink(atPath: root + "/local/awaydir", withDestinationPath: automounted)
            let cache = ImageCache()
            cache.documentURL = folder["local/doc.md"]
            try files.createSymbolicLink(atPath: root + "/local/AWAYDIR2", withDestinationPath: "/system/volumes/DATA/Home")
            for destination in ["away.png", automounted + "/someone/x.png", "awaydir/someone/x.png", "/home/someone/x.png",
                                "/System/Volumes/Data/HOME/someone/x.png", "/system/volumes/data/home/x.png", "/HOME/someone/x.png", "AWAYDIR2/someone/x.png"] {
                guard case .blocked(let source) = cache.entry(for: destination) else {
                    Issue.record("\(destination) is not blocked")
                    continue
                }
                #expect(source == automounted)
            }
            let listed = FileTree.contents(of: folder["local/"])
            #expect(listed.first { $0.name == "awaydir" }.map { !$0.isDirectory && $0.destination == nil } == true, "listed as a file, not followed")
            #expect(listed.first { $0.name == "AWAYDIR2" }.map { !$0.isDirectory && $0.destination == nil } == true, "in any spelling")
            #expect(listed.first { $0.name == "dir" }.map { !$0.isDirectory } == true)
            #expect(listed.first { $0.name == "near.png" }?.destination == folder["local/pic.png"].path, "a link that stays here is followed as ever")
        }

        @Test func anAddressTypedOrPastedInSafeModeIsNotFetchedAtAnyLetter() async throws {
            defer { folder.remove() }
            let host = uniqueHost("typed")
            let w = EditorWindow("", documentURL: try folder.add("typing.md"))
            defer { w.close() }
            let typed = "![t](https://\(host)/typed.png) "
            w.type(typed)
            #expect(w.textView.string.contains("](https://\(host)/typed.png)"))
            #expect(picture(w, at: 0)?.isBlocked == true)
            // Pasted, from a pasteboard of the test's own.
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString("\n\n![p](http://\(host)/pasted.png)\n", forType: .string)
            w.select(w.length)
            #expect(w.textView.readSelection(from: pasteboard, type: .string))
            w.pump()
            #expect(picture(w, at: w.offset(of: "![p"))?.isBlocked == true)
            // And in a document that has no file yet.
            let untitled = EditorWindow()
            defer { untitled.close() }
            untitled.type("![u](//\(host)/untitled.png) ")
            #expect(picture(untitled, at: 0)?.isBlocked == true && untitled.editor.isInSafeMode)
            try await settle()
            #expect(WebStub.requests(to: host).isEmpty, "nothing was asked of the network, at any letter")
            #expect(w.storageProblem == nil)
        }

        // MARK: what trust allows

        @Test func aDocumentInATrustedFolderOrBelowItFetchesItsImages() async throws {
            defer { folder.remove() }
            let host = uniqueHost("trusted"), url = try #require(URL(string: "https://\(host)/lake.png"))
            WebStub.responses[url] = try Fixtures.data("images/pic.png")
            defer { WebStub.responses[url] = nil }
            let text = "![Lake](\(url.absoluteString))\n\nafter\n"
            TrustStore.shared.trust(folder.url)
            for path in ["top.md", "docs/deep/below.md"] {
                let w = EditorWindow(text, documentURL: try folder.add(path))
                defer { w.close() }
                #expect(!w.editor.isInSafeMode && w.editor.loadsRemoteImages && w.editor.safeMode.isHidden)
                #expect(await wait { picture(w, at: 0)?.image != nil }, "\(path)")
                #expect(picture(w, at: 0)?.size == CGSize(width: 640, height: 360))
            }
            #expect(WebStub.requests(to: host).count >= 2)
            // A document beside the folder is not in it.
            let outside = try TemporaryFolder(["o.md"])
            defer { outside.remove() }
            let w = EditorWindow("![Other](https://\(host)/other.png)\n", documentURL: outside["o.md"])
            defer { w.close() }
            #expect(picture(w, at: 0)?.isBlocked == true && w.editor.isInSafeMode)
            try await settle()
            #expect(!WebStub.requests(to: host).contains { $0.lastPathComponent == "other.png" })
        }

        @Test func trustingAndNoLongerTrustingAFolderReachesEveryOpenDocumentAtOnce() async throws {
            defer { folder.remove() }
            let host = uniqueHost("live"), slow = uniqueHost("slow")
            let url = try #require(URL(string: "https://\(host)/lake.png"))
            WebStub.responses[url] = try Fixtures.data("images/pic.png")
            WebStub.heldHosts.insert(slow)
            defer {
                WebStub.responses[url] = nil
                WebStub.heldHosts.remove(slow)
            }
            let text = "![Lake](\(url.absoluteString))\n\n![Slow](https://\(slow)/never.png)\n\nafter\n"
            let first = EditorWindow(text, documentURL: try folder.add("one.md")), second = EditorWindow(text, documentURL: try folder.add("sub/two.md"))
            defer {
                first.close()
                second.close()
            }
            let slowMark = first.offset(of: "![Slow")
            let height = first.fragment(at: slowMark).layoutFragmentFrame
            #expect(picture(first, at: 0)?.isBlocked == true && picture(second, at: 0)?.isBlocked == true)
            try await settle()
            #expect(WebStub.requests(to: host).isEmpty && WebStub.requests(to: slow).isEmpty)

            TrustStore.shared.trust(folder.url)
            for w in [first, second] {
                #expect(!w.editor.isInSafeMode && w.editor.safeMode.isHidden)
                #expect(await wait { picture(w, at: 0)?.image != nil }, "the image is fetched in a window that was open")
                let loading = try #require(picture(w, at: slowMark))
                #expect(loading.image == nil && !loading.isBlocked && !loading.isMissing, "and the other one is on its way")
            }
            #expect(await wait { WebStub.requests(to: slow).count >= 2 })
            #expect(first.fragment(at: slowMark).layoutFragmentFrame.size == height.size, "a placeholder is as large blocked as loading")

            TrustStore.shared.stopTrusting(folder.url)
            for w in [first, second] {
                #expect(picture(w, at: 0)?.isBlocked == true && picture(w, at: slowMark)?.isBlocked == true, "both show as blocked again")
                #expect(w.editor.isInSafeMode && !w.editor.safeMode.isHidden && !w.editor.loadsRemoteImages)
            }
            #expect(await wait { WebStub.ended(at: slow).count >= 2 }, "what was being fetched is given up")
            let before = WebStub.requests(to: host).count + WebStub.requests(to: slow).count
            try await settle()
            #expect(WebStub.requests(to: host).count + WebStub.requests(to: slow).count == before, "and nothing is fetched any more")
            #expect(first.textView.string == text && first.storageProblem == nil)
        }

        @Test func aClickOnABlockedImageLoadsThatDocumentsImagesAndNoOthers() async throws {
            defer { folder.remove() }
            let host = uniqueHost("click"), url = try #require(URL(string: "https://\(host)/lake.png"))
            WebStub.responses[url] = try Fixtures.data("images/pic.png")
            defer { WebStub.responses[url] = nil }
            let text = "before\n\n![Lake](\(url.absoluteString))\n\nafter\n"
            let a = try folder.add("a.md"), b = try folder.add("b.md")
            let w = EditorWindow(text, documentURL: a), other = EditorWindow(text, documentURL: b)
            defer {
                w.close()
                other.close()
            }
            let mark = w.offset(of: "![Lake")
            let fragment = w.fragment(at: mark), rect = try #require((fragment as? BlockFragment)?.pictures.first?.rect)
            let origin = w.textView.textContainerOrigin, frame = fragment.layoutFragmentFrame
            let middle = NSPoint(x: origin.x + frame.minX + rect.midX, y: origin.y + frame.minY + rect.midY)
            w.select(0)
            // Beside the placeholder a click is the text view's own.
            #expect(w.textView.clickHandler?(NSPoint(x: origin.x + frame.minX + rect.maxX + 30, y: middle.y), []) == false)
            #expect(!w.editor.loadsRemoteImages)

            w.mouseDown(at: middle)
            #expect(w.editor.loadsRemoteImages && w.editor.isInSafeMode, "loaded, and still in safe mode: the folder is not trusted")
            #expect(w.textView.selectedRange() == NSRange(location: 0, length: 0), "the click is not a click into the text")
            #expect(await wait { picture(w, at: mark)?.image != nil })
            #expect(picture(other, at: mark)?.isBlocked == true && !other.editor.loadsRemoteImages, "the other document stays as it was")
            #expect(TrustStore.shared.trustedFolders.isEmpty && !TrustStore.shared.isDecided(folder.url))

            // The document closed and opened again has its images until the app quits; the app started again has not.
            let again = EditorWindow(text, documentURL: a)
            defer { again.close() }
            #expect(again.editor.loadsRemoteImages)
            TrustStore.shared = TrustStore()
            let relaunched = EditorWindow(text, documentURL: a)
            defer { relaunched.close() }
            #expect(!relaunched.editor.loadsRemoteImages && picture(relaunched, at: mark)?.isBlocked == true)
        }

        /// The caret in the image's own source, which then shows beside the placeholder: the click
        /// loads the images and is no click into that text, and the text is as it was.
        @Test func aClickOnABlockedImageWithTheCaretInItsSourceChangesNoText() async throws {
            defer { folder.remove() }
            let host = uniqueHost("caret"), url = try #require(URL(string: "https://\(host)/lake.png"))
            WebStub.responses[url] = try Fixtures.data("images/pic.png")
            defer { WebStub.responses[url] = nil }
            let text = "before\n\n![Lake](\(url.absoluteString))\n\nafter\n"
            let w = EditorWindow(text, documentURL: try folder.add("a.md"))
            defer { w.close() }
            let mark = w.offset(of: "![Lake"), caret = NSRange(location: w.offset(of: "lake.png"), length: 0)
            w.select(caret.location)
            let fragment = w.fragment(at: mark), rect = try #require((fragment as? BlockFragment)?.pictures.first { $0.picture.isBlocked }?.rect)
            let origin = w.textView.textContainerOrigin, frame = fragment.layoutFragmentFrame

            w.mouseDown(at: NSPoint(x: origin.x + frame.minX + rect.midX, y: origin.y + frame.minY + rect.midY))
            #expect(w.editor.loadsRemoteImages)
            #expect(w.textView.string == text && w.textView.selectedRange() == caret && w.storageProblem == nil)
            #expect(await wait { picture(w, at: mark)?.image != nil })
            #expect(w.textView.string == text && w.textView.selectedRange() == caret)
        }

        @Test func aDocumentWithoutAFileKeepsItsChoiceWhenItIsSaved() async throws {
            defer { folder.remove() }
            let host = uniqueHost("untitled"), url = try #require(URL(string: "https://\(host)/lake.png"))
            WebStub.responses[url] = try Fixtures.data("images/pic.png")
            defer { WebStub.responses[url] = nil }
            let w = EditorWindow("![Lake](\(url.absoluteString))\n")
            defer { w.close() }
            #expect(picture(w, at: 0)?.isBlocked == true)
            w.editor.loadsRemoteImages = true
            #expect(await wait { picture(w, at: 0)?.image != nil })
            let saved = try folder.add("saved.md")
            w.editor.documentURL = saved
            #expect(w.editor.loadsRemoteImages && TrustStore.shared.allowsRemoteImages(for: saved))
            #expect(await wait { picture(w, at: 0)?.image != nil })
            let next = EditorWindow()
            defer { next.close() }
            #expect(!next.editor.loadsRemoteImages, "another new document starts in safe mode")
        }

        @Test func whatIsBeingFetchedIsGivenUpWhenItsDocumentGoes() async throws {
            defer { folder.remove() }
            let slow = uniqueHost("closing")
            WebStub.heldHosts.insert(slow)
            defer { WebStub.heldHosts.remove(slow) }
            var cache: ImageCache? = ImageCache()
            cache?.allowsRemote = true
            guard case .loading = cache?.entry(for: "https://\(slow)/never.png") else {
                Issue.record("a web image loads where it may")
                return
            }
            #expect(await wait { !WebStub.requests(to: slow).isEmpty } && WebStub.ended(at: slow).isEmpty)
            cache = nil
            #expect(await wait { !WebStub.ended(at: slow).isEmpty })
        }

        /// An SVG file can name things on the web: other images, style sheets, entities. The
        /// system's decoder is given the file as it is, so this asks the system itself, with a
        /// port of this Mac that only this file names.
        /// A server that is asked for an image learns the address and the time, and nothing it
        /// could know the reader by the next time: what it sets is not kept, in memory or on disk.
        @Test func anImageRequestKeepsNoCookieAndNoCopyOfTheAnswer() async throws {
            defer { closeAll() }
            let url = try #require(URL(string: "https://\(uniqueHost())/pic.png"))
            WebStub.responses[url] = try Fixtures.data("images/pic.png")
            WebStub.headers[url] = ["Set-Cookie": "reader=1; Path=/; Max-Age=3600", "Cache-Control": "max-age=3600", "Content-Type": "image/png"]
            defer {
                WebStub.responses[url] = nil
                WebStub.headers[url] = nil
                HTTPCookieStorage.shared.cookies(for: url)?.forEach(HTTPCookieStorage.shared.deleteCookie)
                URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
            }
            let cache = ImageCache()
            cache.allowsRemote = true
            func isShown() -> Bool {
                if case .image = cache.entry(for: url.absoluteString) { true } else { false }
            }
            #expect(await wait { isShown() })
            // Asked again, as by the next document that shows it.
            cache.forget()
            #expect(await wait { isShown() })
            try await settle()
            #expect(WebStub.cookies(sentTo: url) == [nil, nil], "asked twice, and what the first answer set did not come back")
            #expect(HTTPCookieStorage.shared.cookies(for: url)?.isEmpty != false, "nor is it kept for anything else that asks")
            #expect(URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil, "and the answer is in no cache")
            let configuration = ImageCache.session.configuration
            #expect(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies && configuration.urlCredentialStorage == nil)
            #expect(configuration.urlCache == nil)
        }

        @Test func anImageFileThatNamesThingsOnTheWebFetchesNoneOfThem() async throws {
            defer { folder.remove() }
            let listener = Listener(), base = "http://127.0.0.1:\(listener.port)"
            let svg = """
                <?xml version="1.0"?>
                <?xml-stylesheet href="\(base)/style.css" type="text/css"?>
                <!DOCTYPE svg [ <!ENTITY entity SYSTEM "\(base)/entity"> ]>
                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" height="40">
                <style>@import url("\(base)/import.css"); rect { fill: url(\(base)/fill) }</style>
                <image href="\(base)/a.png" width="20" height="20"/>
                <image xlink:href="\(base)/b.png" width="20" height="20"/>
                <use xlink:href="\(base)/c.svg#x"/>
                <text>&entity;</text>
                <rect width="10" height="10"/>
                </svg>
                """
            try folder.add("art.svg", Data(svg.utf8))
            let w = EditorWindow("![art](art.svg)\n\nafter\n", documentURL: try folder.add("doc.md"))
            defer { w.close() }
            #expect(picture(w, at: 0)?.image != nil, "the file is an image")
            _ = w.pixels()
            try await settle()
            #expect(listener.connections() == 0, "showing it connected to nothing")
            // The listener does hear what connects to it.
            let probe = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(probe) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = listener.port.bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(connected == 0 && listener.connections() == 1)
        }

        // MARK: the question and the menus

        private func sheet(_ controller: DocumentWindowController?) -> NSWindow? {
            controller?.window?.attachedSheet
        }

        private func window(of url: URL) -> DocumentWindowController? {
            DocumentWindowController.all.first { $0.rootURL?.path == url.path }
        }

        @Test func aFolderIsAskedAboutOnceOnASheetAfterItsWindowIsOnScreen() async throws {
            defer { closeAll() }
            DocumentWindowController.asksAboutTrust = true
            defer { DocumentWindowController.asksAboutTrust = false }
            let project = try folder.add("project/docs/a.md").deletingLastPathComponent().deletingLastPathComponent()

            DocumentWindowController.openFolder(project)
            let controller = try #require(window(of: project)), window = try #require(controller.window)
            #expect(window.isVisible && window.attachedSheet == nil, "the window is there first, with no question on it")
            #expect(window.screen == NSScreen.builtIn || NSScreen.builtIn == nil)
            #expect(await wait { window.attachedSheet != nil })
            let question = try #require(window.attachedSheet)
            #expect(question.isSheet && question.sheetParent === window)
            let texts = (question.contentView?.descendants ?? []).compactMap { ($0 as? NSTextField)?.stringValue }
            #expect(texts.contains("Do you trust the authors of the files in this folder?"))
            #expect(texts.contains("Documents in this folder and its subfolders will load images from the web. Those servers see when you open a document, "
                + "and your IP address. Safe mode loads nothing from the network."), "it says what trust allows")
            #expect(texts.contains { $0.hasSuffix("/project") && !$0.contains(" ") }, "and for which folder: \(texts)")
            let buttons = (question.contentView?.descendants ?? []).compactMap { $0 as? NSButton }
            #expect(Set(buttons.filter { !$0.title.isEmpty }.map(\.title)) == ["Open in Safe Mode", "Trust Folder"])
            // The button that stands for Escape is no third answer to step to or to hear.
            let hidden = try #require(buttons.first { $0.title.isEmpty })
            #expect(!hidden.isAccessibilityElement() && hidden.cell?.isAccessibilityElement() == false && hidden.refusesFirstResponder)
            func named(_ element: Any) -> [String] {
                let object = element as? NSAccessibilityProtocol, children = (object?.accessibilityChildren() ?? []).flatMap(named)
                let isButton = object?.isAccessibilityElement() == true && object?.accessibilityRole() == .button
                return (isButton ? [object?.accessibilityTitle() ?? ""] : []) + children
            }
            #expect(Set(named(question)) == ["Open in Safe Mode", "Trust Folder"], "\(named(question))")
            #expect(question.defaultButtonCell?.title == "Open in Safe Mode", "Return is safe mode")
            #expect(!TrustStore.shared.isDecided(project) && !TrustStore.shared.isTrusted(project), "safe until answered")

            // Opened again while the question is there: the same window, and one question.
            DocumentWindowController.openFolder(project)
            try await Task.sleep(for: .milliseconds(100))
            #expect(DocumentWindowController.all.count { $0.rootURL?.path == project.path } == 1 && window.attachedSheet === question)

            // Escape is safe mode too: the key reaches the button that stands for it.
            let escape = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: question.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            #expect(question.performKeyEquivalent(with: escape))
            #expect(await wait { window.attachedSheet == nil })
            #expect(TrustStore.shared.isDecided(project) && !TrustStore.shared.isTrusted(project))

            // Answered, it is not asked about again, nor is a folder inside a trusted one.
            DocumentWindowController.openFolder(project)
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.attachedSheet == nil, "the answer “safe” is remembered")
            let other = try folder.add("other/sub/b.md").deletingLastPathComponent().deletingLastPathComponent()
            DocumentWindowController.openFolder(other, inNewWindow: true)
            let second = try #require(self.window(of: other))
            #expect(await wait { sheet(second) != nil })
            let asked = try #require(sheet(second))
            second.window?.endSheet(asked, returnCode: .alertSecondButtonReturn)
            #expect(await wait { TrustStore.shared.isTrusted(other) }, "Trust Folder trusts it")
            DocumentWindowController.openFolder(folder["other/sub/"], inNewWindow: true)
            try await Task.sleep(for: .milliseconds(200))
            #expect(sheet(self.window(of: folder["other/sub/"])) == nil && self.window(of: folder["other/sub/"]) != nil)
        }

        @Test func anAnswerFromElsewhereTakesTheQuestionAwayAndStands() async throws {
            defer { closeAll() }
            DocumentWindowController.asksAboutTrust = true
            defer { DocumentWindowController.asksAboutTrust = false }
            let project = try folder.add("project/a.md").deletingLastPathComponent()
            let other = try folder.add("other/b.md").deletingLastPathComponent()
            DocumentWindowController.openFolder(project)
            let window = try #require(self.window(of: project)?.window)
            #expect(await wait { window.attachedSheet != nil })

            // An answer for another folder leaves the question where it is.
            TrustStore.shared.trust(other)
            try await Task.sleep(for: .milliseconds(100))
            #expect(window.attachedSheet != nil)
            // `marko --trust` on the folder that is being asked about.
            _ = CommandServer.open(request([Request.Item(path: project.path)], trust: true))
            #expect(await wait { window.attachedSheet == nil })
            try await Task.sleep(for: .milliseconds(100))
            #expect(TrustStore.shared.isTrusted(project), "the question did not answer “safe” on its way out")

            // The menu's question about a folder that has an answer goes the same way.
            TrustStore.shared.stopTrusting(project)
            self.window(of: project)?.toggleFolderTrust(nil)
            #expect(await wait { window.attachedSheet != nil })
            TrustStore.shared.trust(project)
            #expect(await wait { window.attachedSheet == nil })
            try await Task.sleep(for: .milliseconds(100))
            #expect(TrustStore.shared.isTrusted(project))
        }

        @Test func theNameOfAFolderAddsNothingToTheQuestion() async throws {
            defer { closeAll() }
            DocumentWindowController.asksAboutTrust = true
            defer { DocumentWindowController.asksAboutTrust = false }
            let name = "notes” is already trusted by your administrator.\n\nChoose Trust Folder to continue. “x\u{202E}y\u{2028}z\tw"
            let project = try folder.add(name + "/a.md").deletingLastPathComponent()
            DocumentWindowController.openFolder(project)
            let window = try #require(self.window(of: project)?.window)
            #expect(await wait { window.attachedSheet != nil })
            let question = try #require(window.attachedSheet)
            let fields = (question.contentView?.descendants ?? []).compactMap { $0 as? NSTextField }, texts = fields.map(\.stringValue)
            // The name is in no sentence of the question: it is the end of the path under it,
            // which is one line cut in the middle, with nothing in it that is not drawn.
            let hidden = CharacterSet.controlCharacters.union(.newlines)
            #expect(texts.count == 3 && texts.allSatisfy { $0.unicodeScalars.allSatisfy { !hidden.contains($0) } }, "\(texts)")
            let path = try #require(fields.first { $0.stringValue.hasSuffix("z w") })
            #expect(path.stringValue.count == theme.shownPathLength + 1 && path.stringValue.contains("…") && !path.stringValue.contains("administrator"))
            #expect(path.lineBreakMode == .byTruncatingMiddle && path.font == theme.promptPathFont && path.frame.width == theme.promptPathWidth)
            #expect(path.frame.height < 2 * path.fittingSize.height && texts.filter { $0.contains("Trust Folder") }.count == 1)
            #expect(texts.contains { $0.hasPrefix("Documents in this folder") && $0.hasSuffix("Safe mode loads nothing from the network.") })
            #expect(question.defaultButtonCell?.title == "Open in Safe Mode")
            window.endSheet(question, returnCode: .alertSecondButtonReturn)
            #expect(await wait { TrustStore.shared.isTrusted(project) })
            // The list of trusted folders shows it the same way.
            let list = NSMenu()
            AppDelegate().menuNeedsUpdate(list)
            #expect(list.items.count == 4 && list.items.allSatisfy { $0.title.unicodeScalars.allSatisfy { !hidden.contains($0) } && $0.title.count <= theme.shownPathLength + 1 })
            #expect("a\nb\u{202E}c\u{0}d é".onOneLine == "a b c d é" && "short/path".onOneLine == "short/path")
        }

        @Test func noFolderIsAskedAboutUnlessTheAppSaysSoAndAFileIsNeverAskedAbout() async throws {
            defer { closeAll() }
            let project = try folder.add("project/a.md").deletingLastPathComponent()
            DocumentWindowController.openFolder(project)
            try await Task.sleep(for: .milliseconds(200))
            #expect(sheet(window(of: project)) == nil && !TrustStore.shared.isDecided(project), "not in the tests or a smoke run")

            DocumentWindowController.asksAboutTrust = true
            defer { DocumentWindowController.asksAboutTrust = false }
            let single = try folder.add("single/b.md")
            let opened = CommandServer.open(request([Request.Item(path: single.path)]))
            let document = try #require(opened.documents.first), editor = try #require(document.editor)
            try await Task.sleep(for: .milliseconds(200))
            #expect(document.windowControllers.first?.window?.attachedSheet == nil, "a file on its own opens in safe mode without a question")
            #expect(editor.isInSafeMode && !editor.loadsRemoteImages)
        }

        private func request(_ items: [Request.Item] = [], text: String? = nil, trust: Bool? = nil) -> Request {
            var request = Request()
            request.items = items
            request.text = text
            request.trust = trust
            return request
        }

        @Test func theToolsTrustAndSafeOptionsAnswerWithoutAQuestion() async throws {
            defer { closeAll() }
            DocumentWindowController.asksAboutTrust = true
            defer { DocumentWindowController.asksAboutTrust = false }
            let host = uniqueHost("tool")
            let trusted = try folder.add("trusted/a.md", Data("![x](https://\(host)/trusted.png)\n".utf8)).deletingLastPathComponent()
            let safe = try folder.add("safe/b.md").deletingLastPathComponent()
            let single = try folder.add("single/c.md", Data("![x](https://\(host)/single.png)\n".utf8))
            let quiet = try folder.add("trusted/quiet.md", Data("![x](https://\(host)/quiet.png)\n".utf8))

            _ = CommandServer.open(request([Request.Item(path: trusted.path)], trust: true))
            _ = CommandServer.open(request([Request.Item(path: safe.path)], trust: false))
            try await Task.sleep(for: .milliseconds(200))
            #expect(sheet(window(of: trusted)) == nil && sheet(window(of: safe)) == nil && window(of: trusted) != nil && window(of: safe) != nil)
            #expect(TrustStore.shared.isTrusted(trusted) && TrustStore.shared.isDecided(safe) && !TrustStore.shared.isTrusted(safe))
            // `--safe` on a folder that is trusted takes the trust away.
            _ = CommandServer.open(request([Request.Item(path: trusted.path)], trust: false))
            #expect(!TrustStore.shared.isTrusted(trusted) && TrustStore.shared.isDecided(trusted))
            TrustStore.shared.trust(trusted)

            // A folder that is too much to trust is opened in safe mode, with no question, and the tool is told.
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            let wide = CommandServer.open(request([Request.Item(path: temporary.path)], trust: true))
            #expect(wide.problems == ["\(temporary.path): too much to trust, opened in safe mode"] && window(of: temporary) != nil)
            try await Task.sleep(for: .milliseconds(200))
            #expect(sheet(window(of: temporary)) == nil && TrustStore.shared.trustedFolders == [trusted.path] && !TrustStore.shared.isTrusted(single))

            // For a file they are about that document, until the app quits, and trust no folder.
            let loading = try #require(CommandServer.open(request([Request.Item(path: single.path)], trust: true)).documents.first)
            #expect(loading.editor?.loadsRemoteImages == true && loading.editor?.isInSafeMode == true)
            #expect(!TrustStore.shared.isTrusted(single) && !TrustStore.shared.isDecided(single.deletingLastPathComponent()))
            #expect(await wait { !WebStub.requests(to: host).filter { $0.lastPathComponent == "single.png" }.isEmpty })
            let blocked = try #require(CommandServer.open(request([Request.Item(path: quiet.path)], trust: false)).documents.first)
            #expect(blocked.editor?.loadsRemoteImages == false, "a file of a trusted folder can be opened safe")
            let piped = try #require(CommandServer.open(request(text: "![x](https://\(host)/piped.png)\n", trust: true)).documents.first)
            #expect(piped.editor?.loadsRemoteImages == true)
            let plain = try #require(CommandServer.open(request(text: "![x](https://\(host)/plain.png)\n")).documents.first)
            #expect(plain.editor?.loadsRemoteImages == false)
            try await settle()
            let fetched = Set(WebStub.requests(to: host).map(\.lastPathComponent))
            #expect(fetched == ["single.png", "piped.png"], "only what was asked for was fetched: \(fetched)")
        }

        @Test func theMenusTrustAFolderStopTrustingItAndLoadOneDocumentsImages() async throws {
            defer { closeAll() }
            let file = try folder.add("project/a.md", Data("text\n".utf8)), project = file.deletingLastPathComponent()
            let controller = DocumentWindowController()
            controller.show(try MarkdownDocument.document(at: file))
            controller.window?.orderFrontRegardless()
            let editor = try #require((controller.document as? MarkdownDocument)?.editor)
            let trust = NSMenuItem(title: "", action: #selector(DocumentWindowController.toggleFolderTrust(_:)), keyEquivalent: "")
            let load = NSMenuItem(title: "", action: #selector(DocumentWindowController.toggleRemoteImages(_:)), keyEquivalent: "")

            #expect(controller.validateMenuItem(trust) && trust.title == "Trust This Folder…")
            #expect(controller.validateMenuItem(load) && load.state == .off)
            // Load Remote Images is this document's, and shows whether it does.
            controller.toggleRemoteImages(nil)
            #expect(editor.loadsRemoteImages && editor.isInSafeMode && controller.validateMenuItem(load) && load.state == .on)
            controller.toggleRemoteImages(nil)
            #expect(!editor.loadsRemoteImages && controller.validateMenuItem(load) && load.state == .off)

            // Looking at the question and declining leaves the document as it was: images that
            // were asked for stay.
            controller.toggleRemoteImages(nil)
            controller.toggleFolderTrust(nil)
            controller.window?.endSheet(try #require(controller.window?.attachedSheet), returnCode: .alertFirstButtonReturn)
            #expect(await wait { TrustStore.shared.isDecided(project) })
            #expect(editor.loadsRemoteImages && editor.isInSafeMode && !TrustStore.shared.isTrusted(project))
            controller.toggleRemoteImages(nil)
            #expect(!editor.loadsRemoteImages)

            // Trust This Folder asks, as opening a folder does, about the folder the file is in.
            controller.toggleFolderTrust(nil)
            let question = try #require(controller.window?.attachedSheet)
            #expect(!TrustStore.shared.isTrusted(project))
            controller.window?.endSheet(question, returnCode: .alertSecondButtonReturn)
            #expect(await wait { TrustStore.shared.isTrusted(project) })
            #expect(editor.loadsRemoteImages && !editor.isInSafeMode, "the open document follows at once")
            #expect(controller.validateMenuItem(trust) && trust.title == "Stop Trusting This Folder")
            #expect(controller.validateMenuItem(load) && load.state == .on)

            // File > Trusted Folders lists them; choosing one, or the last item, takes the trust away.
            let app = AppDelegate(), list = NSMenu()
            app.menuNeedsUpdate(list)
            #expect(list.items.map(\.title).first == "Stop Trusting:" && list.items.last?.title == "Stop Trusting All Folders")
            let entry = try #require(list.items.first { $0.representedObject as? String == project.path })
            #expect(entry.title.hasSuffix("/project") && entry.action == #selector(AppDelegate.stopTrustingFolder(_:)))
            app.stopTrustingFolder(entry)
            #expect(!TrustStore.shared.isTrusted(project) && editor.isInSafeMode && !editor.loadsRemoteImages)
            app.menuNeedsUpdate(list)
            #expect(list.items.map(\.title) == ["No Trusted Folders"])

            controller.toggleFolderTrust(nil)
            let again = try #require(controller.window?.attachedSheet)
            controller.window?.endSheet(again, returnCode: .alertSecondButtonReturn)
            #expect(await wait { TrustStore.shared.isTrusted(project) })
            controller.toggleFolderTrust(nil)
            #expect(!TrustStore.shared.isTrusted(project) && controller.window?.attachedSheet == nil, "Stop Trusting This Folder asks nothing")
            // Where the trust comes from a folder above, Stop Trusting This Folder is about
            // this folder: the one above stays trusted and listed.
            TrustStore.shared.trust(folder.url)
            #expect(controller.validateMenuItem(trust) && trust.title == "Stop Trusting This Folder" && !editor.isInSafeMode)
            controller.toggleFolderTrust(nil)
            #expect(!TrustStore.shared.isTrusted(project) && editor.isInSafeMode && TrustStore.shared.trustedFolders == [folder.url.path])
            #expect(controller.validateMenuItem(trust) && trust.title == "Trust This Folder…")
            TrustStore.shared.trust(project)
            app.stopTrustingAllFolders(nil)
            #expect(TrustStore.shared.trustedFolders.isEmpty && editor.isInSafeMode)

            // A document without a file has no folder to trust, and can still load its images.
            let untitled = DocumentWindowController()
            untitled.show(.untitled())
            #expect(!untitled.validateMenuItem(trust) && untitled.validateMenuItem(load))
        }

        // MARK: other ways out

        @Test func aDoubleClickInTheTreeOpensOnlyWhatIsMerelyShownAndRevealsTheRest() async throws {
            defer { folder.remove() }
            let shown = ["photo.png", "scan.pdf", "notes.txt", "film.mp4", "data.csv", "song.mp3"]
            // A list of addresses is fetched by the player that opens it.
            let revealed = ["list.m3u8", "list.m3u", "list.pls", "radio.asx", "run.command", "setup.sh", "tool.py", "site.webloc", "theme.terminal", "page.html", "drawing.svg",
                            "profile.mobileconfig", "macro.workflow", "installer.pkg", "archive.zip", "bare", "script.scpt", "x.inetloc", "a.jar"]
            let tree = try TemporaryFolder(shown + revealed)
            defer { tree.remove() }
            // A link is what it leads to, whatever it is called.
            try files.createSymbolicLink(atPath: tree["holiday.png"].path, withDestinationPath: "run.command")
            let w = SidebarWindow(tree)
            defer { w.close() }
            #expect(await wait { w.rows.count == shown.count + revealed.count + 1 })
            for name in shown + revealed + ["holiday.png"] { w.sidebar.openExternally(try #require(w.node(name), "\(name)")) }
            #expect(Set(w.openedExternally.map(\.lastPathComponent)) == Set(shown))
            #expect(Set(w.revealed.map(\.lastPathComponent)) == Set(revealed + ["holiday.png"]))
            for name in shown { #expect(FileTree.typeOpenedInItsApp(tree[name]) != nil, "\(name)") }
            #expect(FileTree.typeOpenedInItsApp(tree["holiday.png"]) == nil && FileTree.typeOpenedInItsApp(tree["missing.png"]) == nil)
        }

        /// A file can carry the name of the app that is to open it (Get Info > Open With), and
        /// keeps it through an archive or a disk image. The system honours it for whoever
        /// opens the file without naming an app; nothing is opened in this test.
        @Test func aFileThatNamesAnAppOfItsOwnIsOpenedInTheAppForItsTypeAllTheSame() async throws {
            defer { folder.remove() }
            let tree = try TemporaryFolder(["plain.txt"])
            defer { tree.remove() }
            let file = try tree.add("notes.txt", Data("#!/bin/sh\n".utf8)), terminal = "/System/Applications/Utilities/Terminal.app"
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let wish = try PropertyListSerialization.data(
                fromPropertyList: ["bundleidentifier": "com.apple.Terminal", "path": terminal, "version": 0], format: .binary, options: 0)
            #expect(wish.withUnsafeBytes { setxattr(file.path, "com.apple.LaunchServices.OpenWith", $0.baseAddress, $0.count, 0, 0) } == 0)
            let usual = try #require(NSWorkspace.shared.urlForApplication(toOpen: tree["plain.txt"]))
            #expect(NSWorkspace.shared.urlForApplication(toOpen: file)?.path == terminal && usual.path != terminal, "the system would do as the file asks")

            let w = SidebarWindow(tree)
            defer { w.close() }
            #expect(await wait { w.rows.count == 2 })
            w.sidebar.openExternally(try #require(w.node("notes.txt")))
            #expect(w.openedExternally == [file] && w.openers == [usual] && w.revealed.isEmpty, "opened in \(w.openers)")
        }

        @Test func aCommandClickOnALinkOnlyEverOpensWebAndMailAddressesAndMarkdownFiles() throws {
            defer { folder.remove() }
            let w = EditorWindow(documentURL: URL(fileURLWithPath: "/tmp/marko-test/doc.md"))
            defer { w.close() }
            var opened: [String] = [], revealed: [String] = []
            w.editor.linkOpener = { opened.append($0.absoluteString) }
            w.editor.fileRevealer = { revealed.append($0.path) }
            for destination in ["//example.com/page", "smb://server/share", "afp://server", "file://server/share/run.command", "x-apple.systempreferences:x",
                                "shortcuts://run-shortcut?name=x", "applescript://com.apple.scripteditor?action=new", "data:text/html,x",
                                "vscode://file/x", "facetime:x", "help:runscript=x"] {
                w.editor.open(destination)
            }
            #expect(opened == ["https://example.com/page"], "an address without a scheme is a web address, as in a browser")
            #expect(revealed == ["/share/run.command"], "a file is shown, never opened")
        }
    }
}

private extension NSView {
    /// Every view below this one.
    var descendants: [NSView] { subviews.flatMap { [$0] + $0.descendants } }
}
