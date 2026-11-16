import Foundation
import Testing
@testable import MarkoCore

@Suite struct CodeTokenizerTests {
    /// Tokens as "kind:text".
    private func tokens(_ code: String, _ language: String) -> [String] {
        CodeTokenizer.tokens(in: code, language: language).map { "\($0.kind):\((code as NSString).substring(with: $0.range))" }
    }

    @Test func comments() {
        #expect(tokens("x // to the end\ny", "swift") == ["comment:// to the end"])
        #expect(tokens("a /* over\ntwo lines */ b", "c") == ["comment:/* over\ntwo lines */"])
        #expect(tokens("a /* never closed\nb", "js") == ["comment:/* never closed\nb"])
        #expect(tokens("x = 1  # note", "python") == ["number:1", "comment:# note"])
        #expect(tokens("SELECT 1 -- note", "sql") == ["keyword:SELECT", "number:1", "comment:-- note"])
    }

    @Test func strings() {
        #expect(tokens(#"print("a \" b", 'c')"#, "python") == [#"string:"a \" b""#, "string:'c'"])
        #expect(tokens("x = \"\"\"doc\nstring\"\"\" + 1", "python") == ["string:\"\"\"doc\nstring\"\"\"", "number:1"])
        #expect(tokens("a = `tpl ${x}`", "js") == ["string:`tpl ${x}`"])
        #expect(tokens(#""// not a comment""#, "swift") == [#"string:"// not a comment""#])
        #expect(tokens("// \"not a string\"", "swift") == ["comment:// \"not a string\""])
        #expect(tokens("fn f<'a>(x: &'a str)", "rust") == ["keyword:fn"], "lifetimes are not strings")
        #expect(tokens("\"oops\nlet", "swift") == ["keyword:let"], "a string ends with its line")
    }

    @Test func numbers() {
        #expect(tokens("a = 42 + 3.14 - 0xFF * 1e9 + 1_000", "swift") == ["number:42", "number:3.14", "number:0xFF", "number:1e9", "number:1_000"])
        #expect(tokens("x1 = y2z", "swift") == [], "digits inside identifiers are not numbers")
    }

    @Test func keywords() {
        #expect(tokens("func greet(_ name: String) -> String { return name }", "swift") == ["keyword:func", "keyword:return"])
        #expect(tokens("def f(x):\n    return x", "py") == ["keyword:def", "keyword:return"])
        #expect(tokens("const n = null;", "JS") == ["keyword:const", "keyword:null"], "language names ignore case")
        #expect(tokens("select Name from t", "sql") == ["keyword:select", "keyword:from"], "and so do SQL keywords")
        #expect(tokens("returned letter", "swift") == [], "only whole words")
        #expect(tokens(#"{"a": true, "b": [1, null]}"#, "json") == [#"string:"a""#, "keyword:true", #"string:"b""#, "number:1", "keyword:null"])
    }

    @Test func anUnknownLanguageHasNoTokens() {
        #expect(tokens("let x = 1 // c", "klingon") == [])
        #expect(tokens("", "swift") == [])
    }

    @Test func rangesAreUTF16Offsets() {
        let code = "let s = \"日本語 🎉\" // ok"
        let found = CodeTokenizer.tokens(in: code, language: "swift")
        #expect(found.map(\.range) == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 8), NSRange(location: 17, length: 5)])
    }

    // MARK: in the style map

    @Test func codeBodyLinesCarryTheirTokens() {
        let styled = Styled("```swift\nlet a = 1 /* one\ntwo */ var b\n```\nlet c\n")
        let first = styled.line(containing: "let a"), second = styled.line(containing: "two")
        #expect(first.codeTokens.map { "\($0.kind):\(styled.text($0.range))" } == ["keyword:let", "number:1", "comment:/* one\n"])
        #expect(second.codeTokens.map { "\($0.kind):\(styled.text($0.range))" } == ["comment:two */", "keyword:var"])
        #expect(styled.line(containing: "```swift").codeTokens.isEmpty)
        #expect(styled.line(containing: "let c").codeTokens.isEmpty, "outside the block")
        #expect(invariantViolations(styled.map, source: styled.source as String).isEmpty)
    }

    @Test func blockPrefixesAreNotCode() {
        let styled = Styled("> ```js\n> const a = `x\n> y` // c\n> ```\n\n- ```py\n  def f(): # c\n  ```\n")
        #expect(styled.line(containing: "const").codeTokens.map { styled.text($0.range) } == ["const", "`x\n"])
        #expect(styled.line(containing: "y`").codeTokens.map { styled.text($0.range) } == ["y`", "// c"])
        #expect(styled.line(containing: "def").codeTokens.map { styled.text($0.range) } == ["def", "# c"])
    }

    @Test func blocksWithoutAKnownLanguageHaveNoTokens() {
        let styled = Styled("```\nlet a = 1\n```\n\n    let b = 2\n\n```nope\nlet c = 3\n```\n")
        #expect(styled.map.lines.allSatisfy { $0.codeTokens.isEmpty })
    }

    @Test func aChangeInOneLineShowsInTheDiffOfTheLinesItRecolours() {
        let old = MarkdownStyler.style("```c\na\nb\nc\n```\nend\n")
        let new = MarkdownStyler.style("```c\n/*a\nb\nc\n```\nend\n")
        #expect(new.diff(from: old).new == 1..<4)
    }
}
