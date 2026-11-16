import Foundation

/// The on-disk form of a document: strict UTF-8, with an optional BOM that is kept out of the text.
public nonisolated struct MarkdownFile: Equatable, Sendable {
    public var text: String
    public var hasBOM: Bool

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    public init(text: String = "", hasBOM: Bool = false) {
        self.text = text
        self.hasBOM = hasBOM
    }

    public init(data: Data) throws {
        hasBOM = data.starts(with: Self.bom)
        guard let text = String(validating: hasBOM ? data.dropFirst(Self.bom.count) : data, as: UTF8.self) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    /// Whether a file is one this app edits, by its name.
    public static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    public var data: Data {
        Data((hasBOM ? Self.bom : []) + text.utf8)
    }
}
