import AppKit
import FixtureSupport
import MarkoEditor
import Testing

extension EditorTests {
    @Suite struct RoundTripTests {
        @Test func everyFixtureSavesByteIdentical() throws {
            #expect(Fixtures.all.count >= 13)
            for url in Fixtures.all {
                let original = try Data(contentsOf: url)
                var file = try MarkdownFile(data: original)
                #expect(file.data == original, "\(url.lastPathComponent) decode/encode")

                let editor = EditorController()
                editor.text = file.text
                file.text = editor.text
                #expect(file.data == original, "\(url.lastPathComponent) through the text storage")
            }
        }

        @Test func bomIsKeptOutOfTheTextAndWrittenBack() throws {
            let file = try MarkdownFile(data: Fixtures.data("bom.md"))
            #expect(file.hasBOM)
            #expect(file.text.unicodeScalars.first != "\u{FEFF}")
            #expect(try !MarkdownFile(data: Fixtures.data("lf.md")).hasBOM)
            #expect(MarkdownFile(text: "a", hasBOM: true).data == Data([0xEF, 0xBB, 0xBF, 0x61]))
        }

        @Test func lineEndingsAreUntouched() throws {
            let text = try MarkdownFile(data: Fixtures.data("crlf.md")).text
            #expect(text.utf16.contains(0x0D))
            let mixed = Data("a\r\nb\nc\rd".utf8)
            #expect(try MarkdownFile(data: mixed).data == mixed)
        }

        @Test func emptyFileIsEmptyText() throws {
            let file = try MarkdownFile(data: Data())
            #expect(file == MarkdownFile(text: "", hasBOM: false))
            #expect(file.data.isEmpty)
        }

        /// Replaces one character in the middle of each fixture through the text view's editing path.
        @Test func singleEditChangesOnlyTheEditedBytes() throws {
            let replacement = "Xé"
            for url in Fixtures.all {
                let original = try Data(contentsOf: url)
                var file = try MarkdownFile(data: original)
                let source = file.text as NSString
                let target = source.rangeOfComposedCharacterSequence(at: source.length / 2)
                let bomLength = file.hasBOM ? 3 : 0
                let start = bomLength + source.substring(to: target.location).utf8.count
                let end = start + source.substring(with: target).utf8.count

                let editor = EditorController()
                editor.text = file.text
                editor.textView.insertText(replacement, replacementRange: target)
                file.text = editor.text

                let expected = original[..<start] + Data(replacement.utf8) + original[end...]
                #expect(file.data == expected, "\(url.lastPathComponent)")
                #expect(file.data != original)
            }
        }

        @Test(arguments: [
            [0x63, 0x61, 0x66, 0xE9, 0x0A],             // Latin-1
            [0xFF, 0xFE, 0x61, 0x00],                   // UTF-16 LE with BOM
            [0xEF, 0xBB, 0xBF, 0x61, 0xC3],             // UTF-8 BOM, truncated sequence
            [0x61, 0xED, 0xA0, 0x80],                   // encoded surrogate
        ] as [[UInt8]])
        func nonUTF8DataFailsToRead(bytes: [UInt8]) {
            #expect(throws: CocoaError.self) { try MarkdownFile(data: Data(bytes)) }
        }
    }
}
