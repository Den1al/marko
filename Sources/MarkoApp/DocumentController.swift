import AppKit
import MarkoEditor

/// The shared document controller. Everything the app is asked to open comes through here (the
/// Open panel, Open Recent, the Dock, the command line), and a folder among it gets a window with
/// the file tree instead of a document.
final class DocumentController: NSDocumentController {
    /// The file or folder named on the command line: the argument that is neither a "-default"
    /// nor the value after one. AppKit opens it by itself while the app launches.
    static var argument: String? {
        let arguments = CommandLine.arguments
        return arguments.indices.dropFirst().first { !arguments[$0].hasPrefix("-") && !arguments[$0 - 1].hasPrefix("-") }.map { arguments[$0] }
    }

    /// How many windows of the last run AppKit is putting back right now. Each of them is its
    /// own again: a document reopened for one must not go into an empty window that came back
    /// before it, whose place and tree it would then have.
    static var restoring = 0

    override class func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) {
        restoring += 1
        super.restoreWindow(withIdentifier: identifier, state: state) { window, error in
            restoring -= 1
            completionHandler(window, error)
        }
    }

    /// A smoke or measuring run shares the app's name with the user's own Marko, and with it the
    /// Open Recent list: it only remembers what it would have noted there.
    override func noteNewRecentDocumentURL(_ url: URL) {
        if Smoke.isEnabled { Smoke.recents.append(url) } else { super.noteNewRecentDocumentURL(url) }
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?, completionHandler: @escaping (Int) -> Void) {
        openPanel.canChooseDirectories = true
        super.beginOpenPanel(openPanel, forTypes: inTypes, completionHandler: completionHandler)
    }

    override func openDocument(
        withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        Perf.mark("openRequest")
        // Documents go by the file itself, not by a link to it: MEASURED, AppKit refuses to open a
        // link ("symbolic link format") and cannot save a document whose URL is one.
        let url = url.resolvingSymlinksInPath()
        // Asked with links followed: "/tmp", "/var" and "/etc" stay links in a resolved path.
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            // While the app is starting AppKit takes a while to get from here to reading the file,
            // which is parsed meanwhile (the first one asked for; `makeEditor` takes it or drops it).
            // MEASURED: 44 ms of a launch with 600 KB from the Finder. Not in an app that runs:
            // there the main thread reads at once, and the second parse would only compete with it.
            if !AppDelegate.hasLaunched, MarkdownDocument.preparse == nil, document(for: url) == nil {
                MarkdownDocument.preparse = Preparse(contentsOf: url)
            }
            return super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
        }
        DocumentWindowController.openFolder(url)
        noteNewRecentDocumentURL(url)
        completionHandler(nil, false, nil)
    }
}
