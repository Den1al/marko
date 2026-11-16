import Foundation
import MarkoCore

/// A file read and parsed ahead of the editor that will show it, off the main thread: while the
/// app is still starting, the main thread has some 100 ms of AppKit's work to do before it gets
/// to the document. The parse is of one exact text and is only handed to an editor loading that text.
public nonisolated final class Preparse: Sendable {
    /// The file, by its real path.
    public let path: String
    private let queue = DispatchQueue(label: "local.marko.preparse", qos: .userInitiated)
    /// Written once on `queue` and only read through it.
    private nonisolated(unsafe) var parsed: (text: NSString, map: StyleMap)?

    public init(contentsOf url: URL) {
        let url = url.resolvingSymlinksInPath()
        path = url.path
        queue.async {
            // Only a regular file: a device or a pipe would be read without end.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return }
            guard let data = try? Data(contentsOf: url), let text = try? MarkdownFile(data: data).text else { return }
            self.parsed = (text as NSString, MarkdownStyler.style(text))
        }
    }

    /// The parse of `text`, waiting for it when it is still being made; nil when the file held
    /// something else, or could not be read.
    func map(of text: String) -> StyleMap? {
        queue.sync {
            // Unit by unit: two texts that are only equal as Unicode have different offsets.
            guard let parsed, parsed.text.isEqual(to: text) else { return nil }
            return parsed.map
        }
    }
}
