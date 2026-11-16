import AppKit
import FixtureSupport
import MarkoCore
import Testing
@testable import MarkoApp
@testable import MarkoEditor

extension EditorTests {
    /// The parse made ahead of the editor, off the main thread, while the app starts. It must be
    /// the parse the editor would have made itself, and must never be taken for another text.
    @Suite struct PreparseTests {
        /// What the editor shows of each line: the display text and where each font begins.
        private func display(_ w: EditorWindow) -> [String] {
            let text = w.textView.string as NSString
            var lines: [String] = [], start = 0
            while start < text.length {
                let shown = w.displayParagraph(at: start).text
                var fonts: [String] = []
                shown.enumerateAttribute(.font, in: NSRange(location: 0, length: shown.length)) { font, range, _ in
                    let font = font as? NSFont
                    fonts.append("\(range.location):\(font?.fontName ?? "-")/\(font?.pointSize ?? 0)")
                }
                lines.append(shown.string + " " + fonts.joined(separator: ","))
                start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            }
            return lines
        }

        @Test func isTheParseOfTheFileForEveryFixture() throws {
            #expect(Fixtures.all.count >= 13)
            for url in Fixtures.all {
                let text = try MarkdownFile(data: Data(contentsOf: url)).text, ahead = Preparse(contentsOf: url)
                #expect(ahead.path == url.resolvingSymlinksInPath().path)
                #expect(ahead.map(of: text) == MarkdownStyler.style(text), "\(url.lastPathComponent)")
                #expect(ahead.map(of: text + "\n") == nil && ahead.map(of: "") == nil, "\(url.lastPathComponent): another text")
            }
        }

        @Test func isNotTakenForATextThatIsOnlyEqualAsUnicode() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let composed = "caf\u{E9} *x*\n", decomposed = "cafe\u{301} *x*\n"
            #expect(composed == decomposed && composed.utf16.count != decomposed.utf16.count)
            let ahead = Preparse(contentsOf: try folder.add("a.md", Data(composed.utf8)))
            #expect(ahead.map(of: composed) == MarkdownStyler.style(composed) && ahead.map(of: decomposed) == nil)
        }

        @Test func isNothingForAFileThatCannotBeRead() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            #expect(Preparse(contentsOf: folder["missing.md"]).map(of: "") == nil)
            #expect(Preparse(contentsOf: folder.url).map(of: "") == nil, "a folder")
            // Only a regular file is read: a device or a pipe has no end.
            #expect(Preparse(contentsOf: URL(fileURLWithPath: "/dev/null")).map(of: "") == nil, "a device")
            #expect(Preparse(contentsOf: try folder.add("binary.md", Data([0xFF, 0xFE, 0x00]))).map(of: "") == nil)
        }

        @Test func anEditorShowsTheSameWithItAndWithoutIt() throws {
            for name in ["kitchen-sink.md", "tables.md", "crlf.md", "bom.md", "reference-links.md"] {
                let url = Fixtures.url(name), text = try MarkdownFile(data: Data(contentsOf: url)).text
                let plain = EditorWindow(text), ahead = EditorWindow()
                defer { plain.close(); ahead.close() }
                ahead.editor.preparse = Preparse(contentsOf: url)
                ahead.editor.text = text
                ahead.pump()
                #expect(ahead.editor.preparse == nil, "it is for one load")
                #expect(ahead.textView.string == text && display(ahead) == display(plain), "\(name)")
                #expect(ahead.storageProblem == nil)
            }
        }

        @Test func anEditorLoadingAnotherTextThanTheFileHeldParsesItself() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            // The same length, so only the comparison of the texts tells them apart.
            let onDisk = "# Title\n\n**bold** and `code`\n", loaded = "Title A\n\n- item and *more*..\n"
            #expect(onDisk.utf16.count == loaded.utf16.count)
            let plain = EditorWindow(loaded), ahead = EditorWindow()
            defer { plain.close(); ahead.close() }
            ahead.editor.preparse = Preparse(contentsOf: try folder.add("a.md", Data(onDisk.utf8)))
            ahead.editor.text = loaded
            ahead.pump()
            let other = EditorWindow(onDisk)
            defer { other.close() }
            #expect(display(ahead) == display(plain) && display(ahead) != display(other))
        }

        @Test func aDocumentTakesOnlyTheParseOfItsOwnFile() throws {
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let a = try folder.add("a.md", Data("# A\n".utf8)), b = try folder.add("b.md", Data("# B\n".utf8))
            defer { for document in NSDocumentController.shared.documents { document.close() } }

            MarkdownDocument.preparse = Preparse(contentsOf: a)
            let other = try MarkdownDocument.document(at: b)
            #expect(other.makeEditor().text == "# B\n" && MarkdownDocument.preparse == nil, "the next editor made uses it or drops it")

            MarkdownDocument.preparse = Preparse(contentsOf: a)
            let own = try MarkdownDocument.document(at: a)
            #expect(own.makeEditor().text == "# A\n" && MarkdownDocument.preparse == nil && own.editor?.preparse == nil)
        }
    }
}
