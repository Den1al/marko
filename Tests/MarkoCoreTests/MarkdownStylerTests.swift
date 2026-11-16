import Foundation
import FixtureSupport
import Markdown
import Testing
@testable import MarkoCore

private func r(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }

@Suite struct InlineTokenTests {
    @Test func strongEmphasisAndStrikethroughRanges() {
        let s = Styled("a **b** _c_ ~~d~~ ~e~ __f__\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[0].tokens == [
            InlineToken(kind: .strong, range: r(2, 5), markerRanges: [r(2, 2), r(5, 2)], contentRange: r(4, 1)),
            InlineToken(kind: .emphasis, range: r(8, 3), markerRanges: [r(8, 1), r(10, 1)], contentRange: r(9, 1)),
            InlineToken(kind: .strikethrough, range: r(12, 5), markerRanges: [r(12, 2), r(15, 2)], contentRange: r(14, 1)),
            InlineToken(kind: .strikethrough, range: r(18, 3), markerRanges: [r(18, 1), r(20, 1)], contentRange: r(19, 1)),
            InlineToken(kind: .strong, range: r(22, 5), markerRanges: [r(22, 2), r(25, 2)], contentRange: r(24, 1)),
        ])
    }

    @Test func nestedDelimitersDoNotShareMarkers() {
        let s = Styled("***both*** ***a** b* **a *b*** _**x**_\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[0].tokens.map(s.describe) == [
            "* *|**both**", "** **|both",
            "* *|**a** b", "** **|a",
            "** **|a *b*", "* *|b",
            "_ _|**x**", "** **|x",
        ])
        // The outer emphasis owns the first and last asterisk, the strong the two inside.
        #expect(s.map.lines[0].tokens[0].markerRanges == [r(0, 1), r(9, 1)])
        #expect(s.map.lines[0].tokens[1].markerRanges == [r(1, 2), r(7, 2)])
    }

    @Test func codeSpanBacktickRunsAreCountedFromTheSource() {
        let s = Styled("`a` ``b ` c`` ``` d `` e ```\n")
        #expect(s.map.lines[0].tokens == [
            InlineToken(kind: .code, range: r(0, 3), markerRanges: [r(0, 1), r(2, 1)], contentRange: r(1, 1)),
            InlineToken(kind: .code, range: r(4, 9), markerRanges: [r(4, 2), r(11, 2)], contentRange: r(6, 5)),
            InlineToken(kind: .code, range: r(14, 14), markerRanges: [r(14, 3), r(25, 3)], contentRange: r(17, 8)),
        ])
    }

    @Test func inlineLinkHidesItsDestinationAndTitleAsOneMarker() {
        let s = Styled("x [text](http://u.v \"ti tle\") y\n")
        #expect(s.map.lines[0].tokens == [InlineToken(
            kind: .link, range: r(2, 27), markerRanges: [r(2, 1), r(7, 22)], contentRange: r(3, 4), destination: "http://u.v"
        )])
    }

    @Test func linkDestinationForms() {
        let s = Styled("[a](<u v> 'single') [b](u (paren)) [c](u) [d]() <http://auto.x>\n")
        let links = s.map.lines[0].tokens
        #expect(links.map(s.describe) == ["[ ](<u v> 'single')|a", "[ ](u (paren))|b", "[ ](u)|c", "[ ]()|d", "< >|http://auto.x"])
        #expect(links.map(\.destination) == ["u v", "u", "u", "", "http://auto.x"])
    }

    @Test func referenceLinksResolveTheirDestination() {
        let s = Styled("[full][ref] [collapsed][] [ref] ![img][ref]\n\n[ref]: http://r.x \"T\"\n[collapsed]: http://c.x\n")
        let tokens = s.map.lines[0].tokens
        #expect(tokens.map(s.describe) == ["[ ][ref]|full", "[ ][]|collapsed", "[ ]|ref", "![ ][ref]|img"])
        #expect(tokens.map(\.kind) == [.link, .link, .link, .image])
        #expect(tokens.map(\.destination) == ["http://r.x", "http://c.x", "http://r.x", "http://r.x"])
        #expect(s.map.lines[2...].allSatisfy { $0.kind == .source && $0.tokens.isEmpty }, "the definitions show as they are written")
    }

    @Test func imageCarriesItsSourceAndAltText() {
        let s = Styled("![alt text](img/a.png \"T\") end\n")
        #expect(s.map.lines[0].tokens == [InlineToken(
            kind: .image, range: r(0, 26), markerRanges: [r(0, 2), r(10, 16)], contentRange: r(2, 8), destination: "img/a.png"
        )])
    }

    @Test func tokensNestInsideLinksAndLinksInsideStrong() {
        let s = Styled("[a *b* `c`](u) **x [l](v) y** ![i **j**](w)\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[0].tokens.map(s.describe) == [
            "[ ](u)|a *b* `c`", "* *|b", "` `|c",
            "** **|x [l](v) y", "[ ](v)|l",
            "![ ](w)|i **j**", "** **|j",
        ])
    }

    @Test func escapesAndInlineHTMLAreTokensAndEntitiesDoNotShiftLaterOnes() {
        let s = Styled("\\*no\\* &amp; <b>raw</b> \\`x **b\\*** end  \nnext *e*\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[0].tokens.map(s.describe) == ["\\|*", "\\|*", "|<b>", "|</b>", "\\|`", "** **|b\\*", "\\|*"])
        #expect(s.map.lines[0].tokens.map(\.kind) == [.escape, .escape, .html, .html, .escape, .strong, .escape])
        #expect(s.map.lines[0].tokens[5].range == s.range(of: "**b\\***"))
        #expect(s.map.lines[1].tokens.map(s.describe) == ["* *|e"])
    }

    @Test func aBackslashIsAnEscapeOnlyBeforePunctuationOutsideCodeAndDestinations() {
        let s = Styled("a\\b \\\\* `c\\*` <http://x.y/\\*> [l\\]](u\\)v) <i a=\"\\*\"> \\\n# h \\#\n\n    code \\*\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.tokens(.escape).map { s.text($0.range) } == ["\\\\", "\\]", "\\#"])
        #expect(s.tokens(.escape).allSatisfy { $0.markerRanges == [NSRange(location: $0.range.location, length: 1)] })
        #expect(s.tokens(.emphasis).isEmpty && s.tokens(.link).count == 2)
    }

    @Test func emojiAndCJKBeforeATokenUseUTF16Offsets() {
        // 😀 is 4 UTF-8 bytes and 2 UTF-16 units; 日本 is 6 bytes and 2 units; é is 2 bytes and 1 unit.
        let s = Styled("😀日本é **b** `c`\n")
        #expect(s.map.lines[0].tokens == [
            InlineToken(kind: .strong, range: r(6, 5), markerRanges: [r(6, 2), r(9, 2)], contentRange: r(8, 1)),
            InlineToken(kind: .code, range: r(12, 3), markerRanges: [r(12, 1), r(14, 1)], contentRange: r(13, 1)),
        ])
    }

    @Test func nonASCIIFixtureRanges() throws {
        let s = try Styled(fixture: "non-ascii.md")
        #expect(s.inconsistentLines.isEmpty)

        let strong = s.tokens(.strong)
        #expect(strong.map(s.describe) == ["** **|太字", "** **|bold", "** **|bold"])
        #expect(strong[0].range == s.range(of: "**太字**"))
        #expect(strong[0].contentRange == s.range(of: "太字"))
        #expect(strong[1].range == s.range(of: "**bold**", occurrence: 0))
        // After RTL text.
        #expect(strong[2].range == s.range(of: "**bold**", occurrence: 1))

        #expect(s.tokens(.emphasis).map(\.range) == [s.range(of: "*斜体*"), s.range(of: "*emphasis*")])
        #expect(s.tokens(.code).map(s.describe) == ["` `|コード"])
        #expect(s.tokens(.code)[0].range == s.range(of: "`コード`"))
        #expect(s.tokens(.strikethrough).map(\.range) == [s.range(of: "~~删除线~~")])

        let link = try #require(s.tokens(.link).first)
        #expect(link.range == s.range(of: "[链接](https://example.com/路径)"))
        #expect(link.contentRange == s.range(of: "链接"))
        #expect(link.destination == "https://example.com/路径")

        // Emoji before a token inside a list item, and a token inside a quote after Hangul.
        #expect(s.line(containing: "絵文字").listMarkers.map(\.range) == [s.range(of: "- 絵").location].map { r($0, 1) })
        #expect(s.line(containing: "한국어").quoteDepth == 1)
        #expect(s.line(containing: "🗼").cells.map { s.text($0.contentRange) } == ["東京", "🗼"])
    }

    @Test func multiLineTokensAreSplitPerLine() {
        let s = Styled("a **bold\nstill** b [li\nnk](u) `co\nde` end\n")
        #expect(s.inconsistentLines.isEmpty)
        let whole = s.range(of: "**bold\nstill**")
        #expect(s.map.lines[0].tokens == [
            InlineToken(kind: .strong, range: whole, markerRanges: [r(2, 2)], contentRange: r(4, 4)),
        ])
        #expect(s.map.lines[1].tokens.map(s.describe) == ["**|still", "[|li"])
        #expect(s.map.lines[1].tokens[0].range == whole)
        #expect(s.map.lines[1].tokens[0].markerRanges == [s.range(of: "**", occurrence: 1)])
        #expect(s.map.lines[2].tokens.map(s.describe) == ["](u)|nk", "`|co"])
        #expect(s.map.lines[1].tokens[1].destination == "u" && s.map.lines[2].tokens[0].destination == "u")
        #expect(s.map.lines[3].tokens.map(s.describe) == ["`|de"])
        #expect(s.map.lines[3].tokens[0].range == s.range(of: "`co\nde`"))
    }

    @Test func multiLineTokensInQuotesAndListsSkipThePrefix() {
        let s = Styled("> q *em\n> more* `c\n> d` x\n\n- i **st\n  ill** y\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[0].tokens.map(s.describe) == ["*|em"])
        #expect(s.map.lines[1].tokens.map(s.describe) == ["*|more", "`|c"])
        #expect(s.map.lines[1].tokens[0].contentRange == s.range(of: "more"))
        #expect(s.map.lines[2].tokens.map(s.describe) == ["`|d"])
        #expect(s.map.lines[2].tokens[0].range == s.range(of: "`c\n> d`"))
        #expect(s.map.lines[5].tokens.map(s.describe) == ["**|ill"])
        #expect(s.map.lines[5].tokens[0].contentRange == s.range(of: "ill"))
    }

    /// cmark reports columns on continuation lines as if they had the first line's prefix.
    @Test func continuationLinesWithADifferentPrefixWidth() {
        let s = Styled("> a **x**\n>b **y**\n>    c **z**\n   lazy **l**\n\n- item\n      deep **w**\nlz **v**\n\n   lead **a**\nnext **b**\n")
        #expect(s.inconsistentLines.isEmpty)
        let strong = s.tokens(.strong)
        #expect(strong.map(s.describe) == Array(repeating: "** **|", count: 8).enumerated().map { $1 + ["x", "y", "z", "l", "w", "v", "a", "b"][$0] })
        for (token, letter) in zip(strong, ["x", "y", "z", "l", "w", "v", "a", "b"]) {
            #expect(token.range == s.range(of: "**\(letter)**"))
        }
        #expect(s.map.lines[3].quoteDepth == 1)
        #expect(s.map.lines[3].prefixRange.length == 0)
    }

    @Test func tokensInHeadings() {
        let s = Styled("## A *b* `c` ##\n\nSetext **x**\nsecond *y*\n===\n")
        #expect(s.map.lines[0].kind == .heading(level: 2))
        #expect(s.map.lines[0].headingMarkers == [r(0, 3), r(12, 3)])
        #expect(s.map.lines[0].tokens.map(s.describe) == ["* *|b", "` `|c"])
        #expect(s.map.lines[2].kind == .heading(level: 1))
        #expect(s.map.lines[2].tokens.map(\.range) == [s.range(of: "**x**")])
        #expect(s.map.lines[3].kind == .heading(level: 1))
        #expect(s.map.lines[3].tokens.map(\.range) == [s.range(of: "*y*")])
        #expect(s.map.lines[4].kind == .headingUnderline(level: 1))
    }

    /// The parser puts the end of a multi-line strikethrough on its first line, or gives it no range at all.
    @Test func multiLineStrikethrough() {
        let double = Styled("~~a\nb~~")
        #expect(double.inconsistentLines.isEmpty)
        #expect(double.map.lines[0].tokens == [
            InlineToken(kind: .strikethrough, range: r(0, 7), markerRanges: [r(0, 2)], contentRange: r(2, 1)),
        ])
        #expect(double.map.lines[1].tokens == [
            InlineToken(kind: .strikethrough, range: r(0, 7), markerRanges: [r(5, 2)], contentRange: r(4, 1)),
        ])

        let single = Styled("~c\nd~")
        #expect(single.inconsistentLines.isEmpty)
        #expect(single.map.lines.map { $0.tokens.map(single.describe) } == [["~|c"], ["~|d"]])

        let unranged = Styled("x **b** ~~a\nb~~ *c*")
        #expect(unranged.inconsistentLines.isEmpty)
        #expect(unranged.map.lines.map { $0.tokens.map(unranged.describe) } == [["** **|b", "~~|a"], ["~~|b", "* *|c"]])
        #expect(unranged.tokens(.strikethrough).map(\.range) == [r(8, 7), r(8, 7)])

        let nested = Styled("> ~~a *x*\n> b~~ c\n\n- y ~~**p**\n  q~~\n")
        #expect(nested.inconsistentLines.isEmpty)
        #expect(nested.map.lines[0].tokens.map(nested.describe) == ["~~|a *x*", "* *|x"])
        #expect(nested.map.lines[1].tokens.map(nested.describe) == ["~~|b"])
        #expect(nested.map.lines[1].tokens[0].range == nested.range(of: "~~a *x*\n> b~~"))
        #expect(nested.map.lines[3].tokens.map(nested.describe) == ["~~|**p**", "** **|p"])
        #expect(nested.map.lines[4].tokens.map(nested.describe) == ["~~|q"])
    }

    /// cmark keeps counting columns on the line of a backslash break.
    @Test func backslashHardBreaks() {
        let s = Styled("x *y* a\\\nb")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[0].tokens.map(\.range) == [r(2, 3)])
        #expect(s.map.lines[1].tokens.isEmpty)

        let after = Styled("a\\\n*b*")
        #expect(after.inconsistentLines.isEmpty)
        #expect(after.map.lines[1].tokens == [
            InlineToken(kind: .emphasis, range: r(3, 3), markerRanges: [r(3, 1), r(5, 1)], contentRange: r(4, 1)),
        ])

        let across = Styled("**a\\\nb**")
        #expect(across.inconsistentLines.isEmpty)
        #expect(across.map.lines.map { $0.tokens.map(across.describe) } == [["**|a\\"], ["**|b"]])
        #expect(across.tokens(.strong).map(\.range) == [r(0, 8), r(0, 8)])
    }

    /// Every line number after a backslash break is one short, and columns restart at a soft break.
    @Test func backslashBreaksFollowedByMoreLines() {
        let s = Styled("a\\\nb\\\n*c* d\\\n**e**\nf `g`  \n~h~ [i](j)\\\n![k](l)\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines.map { $0.tokens.map(s.describe) } == [
            [], [], ["* *|c"], ["** **|e"], ["` `|g"], ["~ ~|h", "[ ](j)|i"], ["![ ](l)|k"],
        ])
        for text in ["*c*", "**e**", "`g`", "~h~", "[i](j)", "![k](l)"] {
            #expect(s.map.lines.flatMap(\.tokens).contains { $0.range == s.range(of: text) }, "\(text)")
        }
    }

    @Test func backslashBreaksInsideQuotesAndLists() {
        let s = Styled("- a\\\n  b\n- c **d**\n\n> q\\\n> *r*\\\nlazy _s_\n\n1. t\\\n     `u`\r\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.text(s.map.lines[0].prefixRange) == "- " && s.map.lines[0].listMarkers.map { s.text($0.range) } == ["-"])
        #expect(s.map.lines[0].containers == [.listItem(markerLength: 1)] && s.map.lines[1].containers == [.listItem(markerLength: 1)])
        #expect(s.map.lines[2].tokens.map(\.range) == [s.range(of: "**d**")])
        #expect(s.text(s.map.lines[4].prefixRange) == "> ")
        #expect(s.map.lines[5].tokens.map(\.range) == [s.range(of: "*r*")])
        #expect(s.map.lines[6].tokens.map(\.range) == [s.range(of: "_s_")])
        #expect(s.map.lines[9].tokens.map(\.range) == [s.range(of: "`u`")])

        // cmark counts CRLF as one column.
        let crlf = Styled("a\\\r\n*b* é\\\r\n**c**\r\n")
        #expect(crlf.inconsistentLines.isEmpty)
        #expect(crlf.map.lines.map { $0.tokens.map(\.range) } == [[], [crlf.range(of: "*b*")], [crlf.range(of: "**c**")]])
    }

    /// swift-markdown gives text that ends in a stray "~" no range, so the closer cannot be found after it.
    @Test func delimitersAroundTextWithoutARange() {
        let s = Styled("*a~* _c_\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[0].tokens.map(\.range) == [r(0, 4), r(5, 3)])
    }

    /// cmark does not start a new line inside a link destination or title either.
    @Test func linkDestinationsAndTitlesAcrossLines() {
        let titled = Styled("[a](u\n\"t\")")
        #expect(titled.inconsistentLines.isEmpty)
        #expect(titled.map.lines[0].tokens == [
            InlineToken(kind: .link, range: r(0, 10), markerRanges: [r(0, 1), r(2, 3)], contentRange: r(1, 1), destination: "u"),
        ])
        #expect(titled.map.lines[1].tokens == [
            InlineToken(kind: .link, range: r(0, 10), markerRanges: [r(6, 4)], contentRange: r(6, 0), destination: "u"),
        ])

        for source in ["[a](u\n)", "[a](\nu)", "[a](u \"t\nt\")", "x [c](u\n) d", "![a](u\n\"t\") *z*"] {
            let s = Styled(source)
            #expect(s.inconsistentLines.isEmpty, "\(source)")
            let links = s.map.lines[0].tokens.filter { $0.destination == "u" }
            let start = source.hasPrefix("x") ? 2 : 0
            #expect(links.map(\.range) == [r(start, (source as NSString).range(of: ")").location + 1 - start)], "\(source)")
        }
        #expect(Styled("![a](u\n\"t\") *z*").map.lines[1].tokens.map(\.range) == [r(0, 11), r(12, 3)])

        let quoted = Styled("> [a](u\n> \"t\") **b**\n> *c*\n")
        #expect(quoted.inconsistentLines.isEmpty)
        #expect(quoted.map.lines.map { quoted.text($0.prefixRange) } == ["> ", "> ", "> "])
        #expect(quoted.map.lines[0].tokens.map(quoted.describe) == ["[ ](u|a"])
        #expect(quoted.map.lines[1].tokens.map(quoted.describe) == ["\"t\")|", "** **|b"])
        #expect(quoted.map.lines[2].tokens.map(\.range) == [quoted.range(of: "*c*")])

        // A soft break before the bracket, then one inside the destination.
        let both = Styled("[a\n](u\n) *x*\n_y_")
        #expect(both.inconsistentLines.isEmpty)
        #expect(both.map.lines[2].tokens.map(both.describe) == [")|", "* *|x"])
        #expect(both.map.lines[3].tokens.map(\.range) == [both.range(of: "_y_")])
    }

    /// cmark expands a tab to the next multiple of four columns and can use up only part of it.
    @Test func tabsInPrefixes() {
        let lazy = Styled("- > a\n\tb *c*\n")
        #expect(lazy.inconsistentLines.isEmpty)
        #expect(lazy.map.lines[0].containers == [.listItem(markerLength: 1), .quote] && lazy.text(lazy.map.lines[0].prefixRange) == "- > ")
        #expect(lazy.map.lines[1].containers == [.listItem(markerLength: 1), .quote])
        #expect(lazy.map.lines[1].tokens.map(\.range) == [r(9, 3)])

        let wide = Styled("* \ta *x*\n   b *c*\n")
        #expect(wide.inconsistentLines.isEmpty)
        #expect(wide.text(wide.map.lines[0].prefixRange) == "* \t")
        #expect(wide.map.lines.map { $0.tokens.map(\.range) } == [[wide.range(of: "*x*")], [wide.range(of: "*c*")]])

        let indented = Styled("- a\n\tb *c*\n\n1.\ta\n\tb `d`\n")
        #expect(indented.inconsistentLines.isEmpty)
        #expect(indented.map.lines[1].tokens.map(\.range) == [indented.range(of: "*c*")])
        #expect(indented.map.lines[4].tokens.map(\.range) == [indented.range(of: "`d`")])
    }
}

@Suite struct BlockStyleTests {
    @Test func kitchenSinkLineKinds() throws {
        let s = try Styled(fixture: "kitchen-sink.md")
        #expect(s.inconsistentLines.isEmpty)
        #expect((0..<6).map { s.map.lines[$0].kind } == (1...6).map { .heading(level: $0) })
        #expect(s.map.lines[5].headingMarkers.map(s.text) == ["###### ", " ######"])
        #expect(s.line(containing: "Setext heading 2").kind == .heading(level: 2))
        #expect(s.line(containing: "----------------").kind == .headingUnderline(level: 2))
        #expect(s.map.lines[6].kind == .blank)
        #expect(s.line(containing: "```swift").kind == .codeFence(language: "swift", isClosing: false))
        #expect(s.line(containing: "let answer").kind == .codeBody(language: "swift"))
        #expect(s.line(containing: "let answer").tokens.isEmpty)
        #expect(["---", "***\n\n___", "___"].map { s.line(containing: "\n\($0)\n", occurrence: 0).kind } == [.blank, .blank, .blank])
        #expect(s.map.lines.filter { $0.kind == .rule }.map { s.text($0.range) } == ["---\n", "***\n", "___\n"])
        // What is not rendered shows as the source it is. A definition with text directly below it
        // is one paragraph with that text for the parser, with ranges that fit neither, and stays plain.
        #expect(s.line(containing: "<div>").kind == .source && s.line(containing: "<div>").tokens.isEmpty)
        for text in ["[ref]: https", "[^1]: Footnote"] {
            #expect(s.line(containing: text).kind == .paragraph)
            #expect(s.line(containing: text).tokens.isEmpty)
        }
        #expect(s.line(containing: "Escapes:").tokens.allSatisfy { $0.kind == .escape })
    }

    @Test func kitchenSinkInlineTokens() throws {
        let s = try Styled(fixture: "kitchen-sink.md")
        #expect(s.line(containing: "A paragraph with").tokens.map(s.describe) == [
            "** **|strong", "__ __|strong", "* *|emphasis", "_ _|emphasis", "* *|**both**", "** **|both",
        ])
        #expect(s.line(containing: "~~strikethrough~~").tokens.map(s.describe) == [
            "~~ ~~|strikethrough", "` `|inline code", "`` ``|code with ` backtick",
        ])
        let links = s.line(containing: "An [inline link]").tokens
        #expect(links.map(s.describe) == ["[ ](https://example.com \"title\")|inline link", "[ ][ref]|reference link"])
        #expect(links.map(\.destination) == ["https://example.com", "https://example.com/ref"])
        #expect(s.line(containing: "an autolink").tokens.map(s.describe) == [
            "< >|https://example.com", "** **|bold with [a link](https://example.com) inside", "[ ](https://example.com)|a link",
        ])
        let image = try #require(s.line(containing: "![inline image]").tokens.first)
        #expect(image.kind == .image)
        #expect(image.range == s.range(of: "![inline image](images/pic.png \"Image title\")"))
        #expect(image.contentRange == s.range(of: "inline image"))
        #expect(image.destination == "images/pic.png")
        #expect(s.line(containing: "Text with an image").tokens.map(s.describe) == ["![ ](https://example.com/icon.png)|icon"])
    }

    @Test func listPrefixesMarkersAndDepth() throws {
        let s = try Styled(fixture: "kitchen-sink.md")
        func prefix(_ text: String) -> String { s.text(s.line(containing: text).prefixRange) }
        func markers(_ text: String) -> [String] { s.line(containing: text).listMarkers.map { s.text($0.range) } }

        #expect(prefix("bullet one") == "- ")
        #expect(prefix("nested bullet") == "  - ")
        #expect(prefix("nested ordered") == "    1. ")
        #expect(markers("nested ordered") == ["1."])
        #expect(s.line(containing: "nested ordered").listMarkers[0].isOrdered)
        #expect(s.line(containing: "nested ordered").listDepth == 3)
        #expect(markers("star bullet") == ["*"])
        #expect(!s.line(containing: "star bullet").listMarkers[0].isOrdered)
        #expect(prefix("continuation") == "   ")
        #expect(markers("continuation").isEmpty)
        #expect(s.line(containing: "continuation").listDepth == 1)

        let open = s.line(containing: "open task"), done = s.line(containing: "done task")
        #expect(s.text(open.prefixRange) == "- [ ] ")
        #expect(open.listMarkers[0].checkbox == .init(range: s.range(of: "[ ]"), isChecked: false))
        #expect(done.listMarkers[0].checkbox == .init(range: s.range(of: "[x]"), isChecked: true))
        #expect(done.tokens.map(s.describe) == ["** **|bold"])
        #expect(done.tokens[0].range == s.range(of: "**bold**"))
    }

    @Test func quotePrefixesAndDepth() throws {
        let s = try Styled(fixture: "nested-lists-quotes.md")
        #expect(s.inconsistentLines.isEmpty)
        func line(_ text: String) -> LineStyle { s.line(containing: text) }
        #expect(s.text(line("quote level three").prefixRange) == "> > > ")
        #expect(line("quote level three").containers == [.quote, .quote, .quote])
        #expect(line("lazy continuation").quoteDepth == 1)
        #expect(line("lazy continuation").prefixRange.length == 0)
        // A bare ">" line keeps the quote open.
        let bare = s.map.lines[18]
        #expect(s.text(bare.range) == ">\n" && bare.kind == .blank && bare.quoteDepth == 1 && bare.prefixRange.length == 1)

        #expect(line("nested in quote").containers == [.quote, .listItem(markerLength: 1), .listItem(markerLength: 1)])
        #expect(s.text(line("nested in quote").prefixRange) == ">   - ")
        #expect(line("ordered in quote").listMarkers.map { s.text($0.range) } == ["1."])
        #expect(line("code in quote").kind == .codeBody(language: nil))
        #expect(s.text(line("code in quote").prefixRange) == "> ")

        #expect(line("quote in list").containers == [.listItem(markerLength: 1), .quote])
        #expect(s.text(line("quote in list").prefixRange) == "- > ")
        #expect(s.text(line("second line").prefixRange) == "  > ")
        #expect(line("let x = 1").kind == .codeBody(language: "swift"))
        #expect(s.text(line("let x = 1").prefixRange) == "  ")
        #expect(line("Loose paragraph").listDepth == 2)
        #expect(s.text(line("Loose paragraph").prefixRange) == "    ")
        #expect(line("task inside ordered").listMarkers[0].checkbox?.isChecked == false)
    }

    @Test func tokensInsideQuotesAndLists() {
        let s = Styled("> q **b** [l](u)\n> > deep `c`\n\n1. one ~~s~~\n   - [x] task *e* ![i](p.png)\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[0].tokens.map(s.describe) == ["** **|b", "[ ](u)|l"])
        #expect(s.map.lines[0].tokens[0].range == r(4, 5))
        #expect(s.map.lines[1].tokens.map(\.range) == [s.range(of: "`c`")])
        #expect(s.map.lines[3].tokens.map(\.range) == [s.range(of: "~~s~~")])
        #expect(s.map.lines[4].tokens.map(\.range) == [s.range(of: "*e*"), s.range(of: "![i](p.png)")])
        #expect(s.map.lines[4].tokens[1].destination == "p.png")
        #expect(s.text(s.map.lines[4].prefixRange) == "   - [x] ")
    }

    /// swift-markdown runs a setext heading on to the end of the line after its underline.
    @Test(arguments: ["a\n===\nb\n", "a\r\n===\r\nb\r\n", "> a\n> ===\n> b\n", "- a\n  ===\n  b\n",
                      "a\n===\n<div>x</div>\n", "a\n===\n[r]: http://x.y\n", "a\n===\n\nb\n"])
    func setextUnderlineFollowedByAnotherLine(source: String) {
        let s = Styled(source)
        #expect(s.inconsistentLines.isEmpty)
        let third: LineStyle.Kind = source.contains("\n\n") ? .blank : source.contains("<div>") ? .source : .paragraph
        #expect(s.map.lines.prefix(3).map(\.kind) == [.heading(level: 1), .headingUnderline(level: 1), third])
        #expect(s.map.lines.allSatisfy { $0.headingMarkers.isEmpty })
    }

    @Test func multiLineSetextHeadingFollowedByText() {
        let s = Styled("a *b*\nc\n---\nd **e**\n")
        #expect(s.map.lines.map(\.kind) == [.heading(level: 2), .heading(level: 2), .headingUnderline(level: 2), .paragraph])
        #expect(s.map.lines[0].tokens.map(\.range) == [s.range(of: "*b*")])
        #expect(s.map.lines[3].tokens.map(\.range) == [s.range(of: "**e**")])
    }

    /// cmark-gfm misses these; the scanner reads the box from the source.
    @Test func taskItemsInsideAQuoteOrAnotherItem() {
        let s = Styled("> - [ ] t\n> - [x] **u**\n\n- 1. [X] v\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.text(s.map.lines[0].prefixRange) == "> - [ ] ")
        #expect(s.map.lines[0].listMarkers[0].checkbox == .init(range: r(4, 3), isChecked: false))
        #expect(s.text(s.map.lines[1].prefixRange) == "> - [x] ")
        #expect(s.map.lines[1].listMarkers[0].checkbox == .init(range: r(14, 3), isChecked: true))
        #expect(s.map.lines[1].tokens.map(\.range) == [s.range(of: "**u**")])
        #expect(s.map.lines[3].listMarkers.map { $0.checkbox?.isChecked } == [nil, true])
        // Outside a quote the parser and the scanner agree.
        #expect(Styled("- [ ] a").map.lines[0].listMarkers[0].checkbox != nil)
        #expect(Styled("1. [x] **g**").map.lines[0].listMarkers[0].checkbox?.isChecked == true)
        #expect(Styled("- [ ]").map.lines[0].listMarkers[0].checkbox == nil)
    }

    @Test func htmlBlocksAndDefinitionsAreSource() throws {
        let s = try Styled(fixture: "raw-html.md")
        for text in ["<div align", "  <img", "</div>", "<!-- a comment", "     over two lines", "<details>", "<br/>"] {
            #expect(s.line(containing: text).kind == .source, "\(text)")
        }
        #expect(s.line(containing: "Markdown **inside**").kind == .paragraph && s.tokens(.strong).count == 1)
        #expect(s.line(containing: "<kbd>Cmd</kbd>").tokens.map(s.describe) == ["|<kbd>", "|</kbd>", "|<kbd>", "|</kbd>", "|<span style=\"color: red\">", "|</span>"])
        let quoted = Styled("> <div>\n> x\n> </div>\n\n- [a]: /u\n")
        #expect(quoted.map.lines.map(\.kind) == [.source, .source, .source, .blank, .source])
        #expect(quoted.map.lines.map { quoted.text($0.prefixRange) } == ["> ", "> ", "> ", "", "- "])
    }

    @Test func aListIsAsWideAsItsLongestTypedMarker() {
        func lengths(_ source: String) -> [[LineStyle.Container]] { Styled(source).map.lines.map(\.containers) }
        #expect(lengths("1. a\n2. b\n") == [[.listItem(markerLength: 2)], [.listItem(markerLength: 2)]])
        #expect(lengths("9. a\n10. b\n") == [[.listItem(markerLength: 3)], [.listItem(markerLength: 3)]])
        // The parser counts on from the first number, whatever is typed.
        #expect(lengths("1. a\n2. b\n10. c\n") == Array(repeating: [.listItem(markerLength: 3)], count: 3))
        #expect(lengths("1. a\n\n   100. n\n2. b\n")[2...] == [[.listItem(markerLength: 2), .listItem(markerLength: 4)], [.listItem(markerLength: 2)]])
        #expect(lengths("> 1. a\n> 12) b\n")[0] == [.quote, .listItem(markerLength: 2)])
    }

    @Test func frontMatterIsSource() throws {
        func isSource(_ line: LineStyle) -> Bool {
            var plain = LineStyle(range: line.range)
            plain.kind = .source
            return line == plain
        }
        let s = Styled("---\ntitle: x\ntags: [a]\n---\n\n# h\n")
        #expect(s.map.lines.prefix(4).allSatisfy(isSource))
        #expect(s.map.lines[4].kind == .blank && s.map.lines[5].kind == .heading(level: 1))

        let fixture = try Styled(fixture: "front-matter.md")
        let closer = try #require(fixture.map.lines.dropFirst().firstIndex { fixture.text($0.range) == "---\n" })
        #expect(fixture.map.lines[...closer].allSatisfy(isSource))
        #expect(fixture.map.lines[(closer + 1)...].contains { $0.kind != .paragraph && $0.kind != .blank })

        #expect(Styled("---\na: *b*\n...\n*c*\n").map.lines.map { $0.tokens.count } == [0, 0, 0, 1])
        // Not front matter: unclosed, not on the first line, or not exactly "---".
        #expect(Styled("---\ntitle\n").map.lines[0].kind == .rule)
        #expect(Styled("\n---\na\n---\n").map.lines.map(\.kind) == [.blank, .rule, .heading(level: 2), .headingUnderline(level: 2)])
        #expect(Styled("----\na\n---\n").map.lines[0].kind == .rule)
    }

    @Test func fenceLinesSayWhetherTheyClose() {
        let kinds = Styled("```\na\n```\n```\nb\n```\n").map.lines.map(\.kind)
        #expect(kinds == [
            .codeFence(language: nil, isClosing: false), .codeBody(language: nil), .codeFence(language: nil, isClosing: true),
            .codeFence(language: nil, isClosing: false), .codeBody(language: nil), .codeFence(language: nil, isClosing: true),
        ])
    }

    @Test func twoListItemsOnOneLineAndWideMarkers() {
        let s = Styled("- 10) a\n\n*    wide\n\n-\n  empty first\n")
        #expect(s.map.lines[0].listMarkers.map { s.text($0.range) } == ["-", "10)"])
        #expect(s.map.lines[0].listMarkers.map(\.isOrdered) == [false, true])
        #expect(s.text(s.map.lines[0].prefixRange) == "- 10) ")
        #expect(s.text(s.map.lines[2].prefixRange) == "*    ")
        #expect(s.map.lines[4].kind == .blank && s.map.lines[4].listMarkers.count == 1)
        #expect(s.text(s.map.lines[5].prefixRange) == "  ")
    }

    @Test func indentedCodeHasItsIndentationAsPrefix() {
        let s = Styled("para\n\n    code\n      deeper\n\tTabbed\n\n>     quoted\n\n- item\n\n      in item\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect([2, 3, 4, 6, 10].map { s.map.lines[$0].kind } == Array(repeating: .codeBody(language: nil), count: 5))
        #expect([2, 3, 4, 6, 10].map { s.text(s.map.lines[$0].prefixRange) } == ["    ", "    ", "\t", ">     ", "      "])
    }

    @Test func aListItemKnowsTheLongestMarkerOfItsList() {
        let s = Styled("9. nine\n10. ten\n    - nested\n\n      more\n11. eleven\n\n- bullet\n")
        #expect(s.map.lines[0].containers == [.listItem(markerLength: 3)])
        #expect(s.map.lines[2].containers == [.listItem(markerLength: 3), .listItem(markerLength: 1)])
        #expect(s.map.lines[4].containers == [.listItem(markerLength: 3), .listItem(markerLength: 1)])
        #expect(s.map.lines[5].containers == [.listItem(markerLength: 3)])
        #expect(s.map.lines[7].containers == [.listItem(markerLength: 1)])
        #expect(s.map.lines[2].listDepth == 2 && s.map.lines[2].quoteDepth == 0)
    }

    @Test func fencedCodeFixture() throws {
        let s = try Styled(fixture: "fenced-code.md")
        let kinds = s.map.lines.map(\.kind)
        #expect(Array(kinds[0...5]) == [.codeFence(language: "swift", isClosing: false), .codeBody(language: "swift"), .codeBody(language: "swift"),
                                        .codeBody(language: "swift"), .codeFence(language: nil, isClosing: true), .blank])
        #expect(s.line(containing: "~~~python").kind == .codeFence(language: "python", isClosing: false))
        // A blank line and markdown inside a block are body.
        #expect(Array(kinds[11...15]) == [.codeFence(language: nil, isClosing: false), .codeBody(language: nil), .codeBody(language: nil),
                                          .codeBody(language: nil), .codeFence(language: nil, isClosing: true)])
        #expect(s.line(containing: "**not bold**").tokens.isEmpty)
        // Shorter fences inside a longer one are body.
        #expect(Array(kinds[17...21]) == [.codeFence(language: "markdown", isClosing: false), .codeBody(language: "markdown"), .codeBody(language: "markdown"),
                                          .codeBody(language: "markdown"), .codeFence(language: nil, isClosing: true)])
        #expect(s.line(containing: "``` js").kind == .codeFence(language: "js", isClosing: false))
        #expect(s.line(containing: "indented code block").kind == .codeBody(language: nil))
        #expect(s.text(s.line(containing: "indented code block").prefixRange) == "    ", "its indentation is a block marker")
        // The run of fence characters is recorded, also on a body line that only looks like a fence.
        #expect(s.text(s.line(containing: "~~~python").fenceMarker!) == "~~~")
        #expect(s.text(s.line(containing: "``` js").fenceMarker!) == "```")
        #expect(s.map.lines[17].fenceMarker?.length == 4 && s.map.lines[18].fenceMarker?.length == 3 && s.map.lines[19].fenceMarker == nil)
        #expect(s.line(containing: "indented code block").fenceMarker == nil)
        // The unclosed fence runs to the end.
        #expect(Array(kinds.suffix(2)) == [.codeFence(language: nil, isClosing: false), .codeBody(language: nil)])
    }

    @Test func crlfFixtureKeepsTerminatorsOutOfContent() throws {
        let s = try Styled(fixture: "crlf.md")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines.allSatisfy { s.text($0.range).hasSuffix("\r\n") })
        #expect(s.map.lines[0].headingMarkers == [r(0, 2)])
        #expect(s.tokens(.strong).map(\.range) == [s.range(of: "**bold**")])
        #expect(s.tokens(.code).map(\.range) == [s.range(of: "`code`")])
        #expect(s.line(containing: "| 1 | 2 |").cells.map { s.text($0.range) } == [" 1 ", " 2 "])
        #expect(s.map.lines.filter { $0.kind == .blank }.allSatisfy { $0.range.length == 2 })
    }

    @Test func everyFixtureIsConsistentAndInBounds() throws {
        for (name, source) in try fixtureSources() {
            let s = Styled(source)
            #expect(invariantViolations(s.map, source: source) == [], "\(name)")
            #expect(s.inconsistentLines.isEmpty, "\(name)")
            #expect(s.map.lines.count == SourceIndex(source).lineCount, "\(name)")
        }
    }
}

@Suite struct TableStyleTests {
    @Test func cellRangesPipesAndAlignments() throws {
        let s = try Styled(fixture: "tables.md")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.tables.map(\.lines) == [0..<5, 8..<12, 13..<16, 17..<21])
        #expect(s.map.tables[0].alignments == [.left, .center, .right, .none])
        #expect(s.map.tables[1].alignments == [.none, .none])
        #expect(s.map.table(atLine: 4) == s.map.tables[0])
        #expect(s.map.table(atLine: 5) == nil)
        #expect(s.map.table(atLine: 20) == s.map.tables[3])
        #expect(s.map.table(atLine: 21) == nil)

        let header = s.map.lines[0]
        #expect(header.kind == .tableRow(isHeader: true))
        #expect(header.cells.map { s.text($0.range) } == [" Left ", " Center ", " Right ", " Default "])
        #expect(header.cells.map { s.text($0.contentRange) } == ["Left", "Center", "Right", "Default"])
        #expect(header.cells[0] == TableCell(range: r(1, 6), contentRange: r(2, 4)))
        #expect(header.pipes == [0, 7, 16, 24, 34])
        #expect(s.map.lines[1].kind == .tableDelimiter(alignments: [.left, .center, .right, .none]))
        #expect(s.map.lines[1].cells.isEmpty)
        #expect(s.map.lines[2].kind == .tableRow(isHeader: false))

        // No outer pipes, tight cells, short and long rows.
        #expect(s.line(containing: "one | 1").cells.map { s.text($0.contentRange) } == ["one", "1"])
        #expect(s.line(containing: "one | 1").pipes.count == 1)
        #expect(s.line(containing: "|x|y|").cells.map { s.text($0.range) } == ["x", "y"])
        #expect(s.line(containing: "only one").cells.count == 1)
        #expect(s.line(containing: "extra").cells.map { s.text($0.contentRange) } == ["a", "b", "c", "extra"])
        #expect(s.line(containing: "| | trailing").cells.map { s.text($0.contentRange) } == ["escaped \\| pipe", "~~strike~~", "", "trailing"])
    }

    @Test func tokensInsideCells() throws {
        let s = try Styled(fixture: "tables.md")
        let row = s.line(containing: "| **bold** |")
        #expect(row.tokens.map(s.describe) == ["** **|bold", "* *|em", "` `|code", "[ ](https://example.com)|link"])
        #expect(row.tokens.map(\.range) == [s.range(of: "**bold**"), s.range(of: "*em*"), s.range(of: "`code`"),
                                            s.range(of: "[link](https://example.com)")])
        #expect(row.tokens[3].destination == "https://example.com")
        #expect(s.line(containing: "~~strike~~").tokens.filter { $0.kind == .strikethrough }.map(\.range) == [s.range(of: "~~strike~~")])
    }

    /// cmark drops the backslash of "\|" before parsing a cell, so its columns after one are short.
    @Test func escapedPipesDoNotSplitCellsOrShiftTokens() {
        let s = Styled("| a \\| *b* \\| **c** | `d \\| e` 日本 *f* |\n|---|---|\n| \\| | [x \\| y](u) |\n")
        #expect(s.inconsistentLines.isEmpty)
        let header = s.map.lines[0]
        #expect(header.cells.map { s.text($0.contentRange) } == ["a \\| *b* \\| **c**", "`d \\| e` 日本 *f*"])
        #expect(header.pipes.count == 3)
        #expect(header.tokens.map(s.describe) == ["\\||", "* *|b", "\\||", "** **|c", "` `|d \\| e", "* *|f"])
        #expect(header.tokens.filter { $0.kind != .escape }.map(\.range)
            == [s.range(of: "*b*"), s.range(of: "**c**"), s.range(of: "`d \\| e`"), s.range(of: "*f*")])
        let body = s.map.lines[2]
        #expect(body.cells.map { s.text($0.contentRange) } == ["\\|", "[x \\| y](u)"])
        #expect(body.tokens.map(s.describe) == ["\\||", "[ ](u)|x \\| y", "\\||"])
    }

    /// swift-markdown starts such a table at the paragraph and gives the paragraph no ranges.
    @Test func headerRowThatEndsAParagraph() {
        let s = Styled("para *p*\na | *b*\n|---|---|\n| *c* | d |\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.tables == [TableStyle(lines: 1..<4, alignments: [.none, .none])])
        #expect(s.map.lines.map(\.kind) == [.paragraph, .tableRow(isHeader: true), .tableDelimiter(alignments: [.none, .none]),
                                            .tableRow(isHeader: false)])
        #expect(s.map.lines[1].cells.map { s.text($0.contentRange) } == ["a", "*b*"])
        #expect(s.map.lines[1].tokens.map(\.range) == [s.range(of: "*b*")])
        #expect(s.map.lines[2].cells.isEmpty)
        #expect(s.map.lines[3].tokens.map(\.range) == [s.range(of: "*c*")])

        let indented = Styled("> para\n> more\n>   _a_ | *b*\n> |---|---|\n")
        #expect(indented.inconsistentLines.isEmpty)
        #expect(indented.map.tables.map(\.lines) == [2..<4])
        #expect(indented.map.lines[2].tokens.map(\.range) == [indented.range(of: "_a_"), indented.range(of: "*b*")])
        #expect(indented.map.lines[3].kind == .tableDelimiter(alignments: [.none, .none]))
    }

    /// cmark measures a body row from the table's column, whatever the row's own indentation.
    @Test func bodyRowsIndentedDifferentlyFromTheTable() {
        let s = Styled("| a | b |\n|---|---|\n  *x* | `y`  ")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[2].kind == .tableRow(isHeader: false))
        #expect(s.map.lines[2].cells.map { s.text($0.contentRange) } == ["*x*", "`y`"])
        #expect(s.map.lines[2].tokens.map(\.kind) == [.emphasis, .code])
        #expect(s.map.lines[2].tokens.map(\.range) == [r(22, 3), r(28, 3)])

        for source in ["| a | b |\n|---|---|\n  | *x* | `y` |", "> | a | b |\n> |---|---|\n>   *x* | `y`",
                       "  | a | b |\n  |---|---|\n| *x* | `y` |", "   a | b\n   --|--\n*x* | `y`", "- a | b\n  --|--\n   *x* | `y`"] {
            let s = Styled(source)
            #expect(s.inconsistentLines.isEmpty, "\(source)")
            #expect(s.map.lines[2].tokens.map(\.range) == [s.range(of: "*x*"), s.range(of: "`y`")], "\(source)")
        }
    }

    /// A table never keeps a row that is not one: the whole table falls back to plain lines.
    @Test func tableWithAnInconsistentLineIsPlain() {
        let parsed = "| a | b |\n|---|---|\n| *c* | d |\n\nend *e*\n"
        let badRow = Styled(parsed.replacingOccurrences(of: "*c*", with: "c**"), document: Document(parsing: parsed))
        #expect(badRow.map.tables.isEmpty)
        #expect(badRow.map.lines.prefix(3).allSatisfy { $0 == LineStyle(range: $0.range) })
        #expect(badRow.map.lines[4].tokens.count == 1)

        let badDelimiter = Styled(parsed.replacingOccurrences(of: "|---|---|", with: "|xxx|---|"), document: Document(parsing: parsed))
        #expect(badDelimiter.inconsistentLines == [0, 1, 2])
        #expect(badDelimiter.map.tables.isEmpty)
        #expect(invariantViolations(badDelimiter.map, source: badDelimiter.source as String) == [])
    }

    @Test func tableInsideAQuoteAndAList() {
        let s = Styled("> | q | **t** |\n> |--:|---|\n> | 😀 `c` | *e* |\n\n- | a | b |\n  |---|---|\n  | ~~x~~ | y |\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.tables.map(\.lines) == [0..<3, 4..<7])
        #expect(s.map.tables[0].alignments == [.right, .none])
        #expect(s.text(s.map.lines[0].prefixRange) == "> ")
        #expect(s.map.lines[0].pipes.first == 2)
        #expect(s.map.lines[2].cells.map { s.text($0.contentRange) } == ["😀 `c`", "*e*"])
        #expect(s.map.lines[2].tokens.map(\.range) == [s.range(of: "`c`"), s.range(of: "*e*")])
        #expect(s.map.lines[1].kind == .tableDelimiter(alignments: [.right, .none]) && s.map.lines[1].quoteDepth == 1)
        #expect(s.text(s.map.lines[4].prefixRange) == "- ")
        #expect(s.map.lines[6].tokens.map(\.range) == [s.range(of: "~~x~~")])
        #expect(s.text(s.map.lines[6].prefixRange) == "  ")
    }
}

@Suite struct InconsistencyTests {
    /// The document was parsed from different text of the same shape, so one of its ranges points at
    /// characters that are not markers.
    @Test func corruptedRangeYieldsAPlainLine() {
        let parsed = "> a **bold** b\n\nnext *em* `c`\n"
        let source = "> a bold**** b\n\nnext *em* `c`\n"
        let s = Styled(source, document: Document(parsing: parsed))
        #expect(s.inconsistentLines == [0])
        #expect(s.map.lines[0] == LineStyle(range: r(0, 15)))
        #expect(s.map.lines[0].kind == .paragraph && s.map.lines[0].containers.isEmpty && s.map.lines[0].prefixRange.length == 0)
        // Lines whose ranges still check out keep their styling.
        #expect(s.map.lines[2].tokens.map(s.describe) == ["* *|em", "` `|c"])
        #expect(invariantViolations(s.map, source: source) == [])
    }

    @Test func eachTokenKindIsVerifiedAgainstTheSource() {
        let parsed = "x **s** *e* ~~d~~ `c` [l](u) ![i](v) <http://a.b>\n"
        for (index, replacement) in [(2, "_"), (8, "x"), (12, "x"), (18, "x"), (22, "("), (29, "x"), (37, "x")] {
            var units = Array(parsed.utf16)
            units[index] = replacement.utf16.first!
            let source = String(utf16CodeUnits: units, count: units.count)
            let s = Styled(source, document: Document(parsing: parsed))
            #expect(s.inconsistentLines == [0], "\(source)")
            #expect(s.map.lines == [LineStyle(range: r(0, parsed.utf16.count))], "\(source)")
        }
    }

    @Test func rangesBeyondTheSourceAreIgnored() {
        let document = Document(parsing: "# Title\n\npara **b** with a long tail\n\n- item `c`\n\n| a | b |\n|---|---|\n| *c* | d |\n")
        for source in ["", "x", "# T\n", "# Title\n\npara **b", "😀\n\n😀\n\n😀\n\n😀\n😀\n😀\n"] {
            let s = Styled(source, document: document)
            #expect(invariantViolations(s.map, source: source) == [], "\(source.debugDescription)")
            #expect(s.map.lines.count == SourceIndex(source).lineCount)
        }
    }

    @Test func multiLineCorruptionMarksEveryLineOfTheToken() {
        let parsed = "a **bo\nld** b\nlast *e*\n"
        let source = "a **bo\nld__ b\nlast *e*\n"
        let s = Styled(source, document: Document(parsing: parsed))
        #expect(s.inconsistentLines == [0, 1])
        #expect(s.map.lines[0].tokens.isEmpty && s.map.lines[1].tokens.isEmpty)
        #expect(s.map.lines[2].tokens.map(s.describe) == ["* *|e"])
    }
}

@Suite struct RobustnessTests {
    /// Typing a fixture one scalar at a time: every intermediate text must style without a crash and
    /// with every range inside the text.
    @Test func everyPrefixOfEveryFixture() throws {
        var styled = 0
        for (name, source) in try fixtureSources() {
            let scalars = Array(source.unicodeScalars)
            for length in 0...scalars.count {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[..<length])
                let prefix = String(view)
                let map = MarkdownStyler.style(prefix)
                let problems = invariantViolations(map, source: prefix)
                #expect(problems.isEmpty, "\(name) prefix \(length): \(problems.prefix(3))")
                #expect(map.lines.count == SourceIndex(prefix).lineCount, "\(name) prefix \(length)")
                styled += 1
            }
        }
        #expect(styled > 4000)
    }

    /// A stale or unrelated document must never produce a range outside the text it is applied to.
    @Test func everyFixtureDocumentAgainstEveryOtherFixture() throws {
        let fixtures = try fixtureSources()
        for (parsedName, parsed) in fixtures {
            let document = Document(parsing: parsed)
            for (name, source) in fixtures {
                for text in [source, String(source.prefix(source.count / 2)), String(source.dropFirst(source.count / 3))] {
                    let problems = invariantViolations(MarkdownStyler.style(source: text, document: document), source: text)
                    #expect(problems.isEmpty, "\(parsedName) applied to \(name): \(problems.prefix(3))")
                }
            }
        }
    }

    @Test func oddInputs() {
        let inputs = [
            "", "\n", "\r", "\r\n\r\n", " ", "\t", ">", "> ", "-", "- ", "1.", "#", "|", "||", "|\n|-|\n|", "`", "``", "*", "**", "[", "![", "[]()", "<>",
            "\u{0}**a**\u{0}", "a\u{2029}**b**", "\u{FEFF}# x", "- - - a", "> > > > > > > > x", "\t\t- a\n\t\tb",
            "a\\\n", "a\\\n\\\n*", "~~a\n", "~~a\n~", "[a](u\n", "[a](u\n\"", "- >\t", "\t>\t-\tx", "-\t[ ]\t", "> - [x]", "x\n| a |\n|-|", "x\n|-|\n",
            "---\n", "---\n---", "---\n...\n", "---\n| a |\n|-|\n---\n", "a\n===\n===\n", "a\n=\n\tb",
            "| \\", "| a |\n|-|\n| \\| |\n", "```", "~~~\n", "    code", "- [ ]", "- [x]\n", "1. [ ] **", "a\n===", "a\n-", "* * *", "\\", "😀", "**😀**",
            String(repeating: "> ", count: 60) + "x", String(repeating: "- ", count: 60) + "x", String(repeating: "*", count: 200),
            String(repeating: "[", count: 100) + String(repeating: "]", count: 100),
        ]
        for input in inputs {
            let map = MarkdownStyler.style(input)
            #expect(invariantViolations(map, source: input) == [], "\(input.debugDescription)")
        }
    }

    @Test func nulAndTokensAfterIt() {
        // cmark replaces NUL by U+FFFD, three bytes wide.
        let s = Styled("a\u{0}b **c**\n")
        #expect(s.inconsistentLines.isEmpty)
        #expect(s.map.lines[0].tokens.map(\.range) == [r(4, 5)])
    }
}
