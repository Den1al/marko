import Foundation
import Testing
@testable import MarkoCore

@Suite struct FormatCommandsTests {
    /// Splits `marked`, where "¦" stands for the caret or, twice, for the ends of the selection.
    private func parse(_ marked: String) -> (text: String, selection: NSRange) {
        let parts = marked.components(separatedBy: "¦")
        return (parts.joined(), NSRange(location: (parts[0] as NSString).length, length: parts.count > 2 ? (parts[1] as NSString).length : 0))
    }

    private func mark(_ text: String, _ selection: NSRange) -> String {
        let result = NSMutableString(string: text)
        if selection.length > 0 { result.insert("¦", at: NSMaxRange(selection)) }
        result.insert("¦", at: selection.location)
        return result as String
    }

    private func apply(_ rule: (String, StyleMap, NSRange) -> TextEdit?, _ marked: String) -> String? {
        let (text, selection) = parse(marked)
        guard let edit = rule(text, MarkdownStyler.style(text), selection) else { return nil }
        return mark((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    private func apply(_ command: FormatCommand, _ marked: String) -> String? {
        apply({ FormatCommands.edit(command, in: $0, map: $1, selection: $2) }, marked)
    }

    private func isOn(_ command: FormatCommand, _ marked: String) -> Bool {
        let (text, selection) = parse(marked)
        return FormatCommands.isOn(command, in: text, map: MarkdownStyler.style(text), selection: selection)
    }

    /// The command gives `result`, is then on, and applied again gives `marked` back.
    private func expectToggle(_ command: FormatCommand, _ marked: String, _ result: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!isOn(command, marked), sourceLocation: sourceLocation)
        #expect(apply(command, marked) == result, sourceLocation: sourceLocation)
        #expect(isOn(command, result), sourceLocation: sourceLocation)
        #expect(apply(command, result) == marked, sourceLocation: sourceLocation)
    }

    // MARK: inline

    @Test func inlineCommandsWrapTheSelectionAndToggleOff() {
        expectToggle(.bold, "a ¦word¦ b\n", "a **¦word¦** b\n")
        expectToggle(.italic, "a ¦word¦ b\n", "a *¦word¦* b\n")
        expectToggle(.strikethrough, "a ¦word¦ b\n", "a ~~¦word¦~~ b\n")
        expectToggle(.code, "a ¦word¦ b\n", "a `¦word¦` b\n")
        expectToggle(.bold, "¦two words¦", "**¦two words¦**")
        expectToggle(.bold, "- item ¦x¦\n", "- item **¦x¦**\n")
        expectToggle(.bold, "| a | ¦b¦ |\n|---|---|\n", "| a | **¦b¦** |\n|---|---|\n")
        expectToggle(.italic, "# ¦Title¦\n", "# *¦Title¦*\n")
        expectToggle(.bold, "caf¦é 🙂 ü¦\n", "caf**¦é 🙂 ü¦**\n")
    }

    @Test func inlineCommandsTakeTheWordAtTheCaret() {
        expectToggle(.bold, "a wo¦rd b\n", "a **wo¦rd** b\n")
        expectToggle(.italic, "¦word\n", "*¦word*\n")
        expectToggle(.code, "word¦", "`word¦`")
        expectToggle(.strikethrough, "a wörd¦ b", "a ~~wörd¦~~ b")
    }

    @Test func inlineCommandsWithNothingToWrapMakeAnEmptyPair() {
        expectEmptyPair(.bold, "a ¦ b\n", "a **¦** b\n")
        expectEmptyPair(.italic, "¦", "*¦*")
        expectEmptyPair(.strikethrough, "a\n\n¦\n", "a\n\n~~¦~~\n")
        expectEmptyPair(.code, "a ¦", "a `¦`")
        #expect(apply(.italic, "a **¦** b") == "a ***¦*** b", "inside an empty bold pair italic is added, not taken from it")
        #expect(apply(.italic, "a ***¦*** b") == "a **¦** b")
        #expect(apply(.bold, "a ***¦*** b") == "a *¦* b")
        expectEmptyPair(.bold, "¦", "**¦**")
        #expect(apply(.code, "```\n`¦`\n```") == nil)
    }

    private func expectEmptyPair(_ command: FormatCommand, _ marked: String, _ result: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(apply(command, marked) == result, sourceLocation: sourceLocation)
        #expect(apply(command, result) == marked, sourceLocation: sourceLocation)
    }

    @Test func aSelectionIsTrimmedAndMaySpanTheLinesOfAParagraph() {
        #expect(apply(.bold, "a¦ word ¦b\n") == "a **¦word¦** b\n")
        #expect(apply(.bold, "¦one\ntwo\n¦") == "**¦one\ntwo¦**\n")
        #expect(apply(.bold, "**¦one\ntwo¦**\n") == "¦one\ntwo¦\n")
        #expect(apply(.bold, "> **one\n> t¦wo**\n") == "> one\n> t¦wo\n", "every line's markers go")
        #expect(apply(.bold, "¦one\n\ntwo¦\n") == nil, "not across blocks")
        #expect(apply(.bold, "a¦  ¦b") == nil)
    }

    @Test func inlineCommandsDoNotSpanBlocksOrCells() {
        for command in [FormatCommand.bold, .italic, .strikethrough, .code] {
            #expect(apply(command, "- ¦one\n- two¦\n") == nil, "two list items")
            #expect(apply(command, "- a ¦one\n  - two¦\n") == nil, "an item and one nested in it")
            #expect(apply(command, "# ¦one\ntext¦\n") == nil, "a heading and a paragraph")
            #expect(apply(command, "¦text\n- item¦\n") == nil)
            #expect(apply(command, "> ¦one\ntwo¦\n") != nil, "a lazy line is the same paragraph")
            #expect(apply(command, "| a | b |\n|---|---|\n| ¦c | d¦ |\n") == nil, "two cells")
            #expect(apply(command, "| a | b |\n|---|---|\n¦| c¦ | d |\n") == nil, "a cell and the pipe before it")
        }
        #expect(apply(.bold, "- ¦one\n  two¦\n") == "- **¦one\n  two¦**\n", "the lines of one item's paragraph")
        #expect(wrap("*", "- ¦one\n- two¦\n") == nil && wrap("*", "| ¦a | b¦ |\n|---|---|\n") == nil)
    }

    @Test func aSelectedLineIsMarkedBehindItsOwnMarkers() {
        #expect(apply(.bold, "¦# Title¦\n\ntext\n") == "# **¦Title¦**\n\ntext\n")
        #expect(apply(.code, "¦## Title\n¦") == "## `¦Title¦`\n", "as a triple click selects it")
        #expect(apply(.italic, "¦### Title ###¦\n") == "### *¦Title¦* ###\n")
        #expect(apply(.strikethrough, "¦- item¦\n") == "- ~~¦item¦~~\n")
        #expect(apply(.bold, "¦> - [ ] task¦\n") == "> - [ ] **¦task¦**\n")
        #expect(apply(.link, "¦# Title¦\n") == "# [Title](¦)\n")
        #expect(isOn(.bold, "¦# **Title**¦\n") && apply(.bold, "¦# **Title**¦\n") == "¦# Title¦\n", "and is on when all of that is")
        #expect(wrap("_", "¦# Title¦\n") == "# _¦Title¦_\n")
        #expect(paste("https://x.y", "¦# Title¦\n") == "# [Title](https://x.y)¦\n")
        #expect(MarkdownStyler.style("# **Title**\n").lines[0].kind == .heading(level: 1))
    }

    @Test func markersDoNotGoIntoCodeSpansOrDestinations() {
        for command in [FormatCommand.bold, .italic, .strikethrough] {
            #expect(apply(command, "a `co¦de` b\n") == nil, "\(command)")
            #expect(apply(command, "a `¦code¦` b\n") == nil)
            #expect(apply(command, "a ¦b `co¦de` c\n") == nil, "half of a code span")
            #expect(apply(command, "a [link](http://exa¦mple.com) b\n") == nil)
            #expect(apply(command, "a [link](http://example.com \"ti¦tle\") b\n") == nil)
            #expect(apply(command, "a ![alt](pic¦.png) b\n") == nil)
            #expect(apply(command, "a [li¦nk][ref] b\n\n[ref]: http://x.y\n") != nil, "a link's text takes them")
        }
        #expect(apply(.link, "a `co¦de` b\n") == nil && apply(.image, "a `¦code¦` b\n") == nil)
        #expect(apply(.bold, "see <http://exa¦mple.com>\n") == nil)
        #expect(apply(.code, "a [link](http://exa¦mple.com) b\n") == nil)
        #expect(apply(.bold, "a ¦`code`¦ b\n") == "a **¦`code`¦** b\n", "around the whole span")
        #expect(apply(.bold, "a ¦[link](http://example.com)¦ b\n") == "a **¦[link](http://example.com)¦** b\n")
        #expect(apply(.bold, "a `code`¦ b\n") == "a `code`**¦** b\n")
        #expect(apply(.code, "a `co¦de` b\n") == "a co¦de b\n", "what is on still goes off")
        for typed in ["_", "*", "~", "`"] {
            #expect(wrap(typed, "[a](http://¦my¦_site.com/path)\n") == nil, "a typed marker replaces the selection there")
            #expect(wrap(typed, "a `¦word¦` b\n") == nil)
        }
        #expect(paste("https://x.y", "a `¦code¦ here` b\n") == nil)
        #expect(paste("https://x.y", "<http://¦old¦.example>\n") == nil)
    }

    @Test func togglingOffKeepsTheSelectionOnItsText() {
        #expect(apply(.bold, "a **wo¦rd** b") == "a wo¦rd b")
        #expect(apply(.bold, "a ¦**word**¦ b") == "a ¦word¦ b")
        #expect(apply(.bold, "a *¦*word** b") == "a ¦word b")
        #expect(apply(.italic, "***¦both¦***") == "**¦both¦**")
        #expect(apply(.bold, "__¦x¦__") == "¦x¦")
        #expect(apply(.code, "``a ` ¦b``") == "a ` ¦b")
    }

    @Test func inlineCommandsDoNotApplyInCode() {
        for command in [FormatCommand.bold, .italic, .strikethrough, .code, .link, .image] {
            #expect(apply(command, "```\nco¦de\n```\n") == nil)
            #expect(apply(command, "```¦\ncode\n```\n") == nil)
            #expect(apply(command, "    inden¦ted\n") == nil)
        }
    }

    @Test func linkWrapsTheSelectionWithTheCaretInTheURL() {
        #expect(apply(.link, "see ¦this page¦ now") == "see [this page](¦) now")
        #expect(apply(.link, "see th¦is now") == "see [this](¦) now")
        #expect(apply(.link, "see ¦ now") == "see [¦]() now")
        #expect(apply(.link, "see [this page](¦) now") == "see this page¦ now")
        #expect(apply(.link, "see [th¦is](https://example.com \"t\") now") == "see th¦is now")
        #expect(apply(.link, "see [¦]() now") == "see ¦ now")
        #expect(apply(.link, "<https://exa¦mple.com>") == "https://exa¦mple.com")
        #expect(isOn(.link, "see [th¦is](u) now") && !isOn(.link, "see th¦is now"))
        #expect(apply(.link, "¦one\ntwo¦\n") == nil)
    }

    @Test func imageWrapsTheDescriptionWithTheCaretInTheURL() {
        #expect(apply(.image, "a ¦cat¦ b") == "a ![cat](¦) b")
        #expect(apply(.image, "¦") == "![](¦)")
        #expect(apply(.image, "![](¦)") == "¦")
        #expect(apply(.image, "a ![c¦at](cat.png) b") == "a c¦at b")
        #expect(isOn(.image, "![c¦at](cat.png)"))
    }

    // MARK: headings

    @Test func headingCommandsSetTheLevelAndToggleOff() {
        expectToggle(.heading(1), "Tit¦le\n", "# Tit¦le\n")
        expectToggle(.heading(3), "¦Title", "### ¦Title")
        expectToggle(.heading(2), "¦", "## ¦")
        expectToggle(.heading(2), "a\n¦", "a\n## ¦")
        expectToggle(.heading(2), "- it¦em\n", "- ## it¦em\n")
        expectToggle(.heading(4), "> quo¦te\n", "> #### quo¦te\n")
        #expect(apply(.heading(2), "# Tit¦le\n") == "## Tit¦le\n")
        #expect(apply(.heading(1), "###### Tit¦le ######\n") == "# Tit¦le ######\n")
        #expect(apply(.paragraph, "## Tit¦le ##\n") == "Tit¦le\n")
        #expect(apply(.paragraph, "Tit¦le\n") == nil)
        #expect(isOn(.paragraph, "Tit¦le\n") && !isOn(.paragraph, "# Tit¦le\n"))
        #expect(apply(.heading(2), "¦one\n\ntwo¦\n") == "## ¦one\n\n## two¦\n")
        #expect(apply(.heading(2), "## ¦one\n\n## two¦\n") == "¦one\n\ntwo¦\n")
    }

    @Test func headingAndCodeBlockDoNotApplyBehindACheckbox() {
        for command in [FormatCommand.heading(1), .increaseHeading, .codeBlock] {
            #expect(apply(command, "- [ ] ta¦sk\n") == nil, "\(command)")
            #expect(apply(command, "> 1. [x] ta¦sk\n") == nil)
        }
        #expect(apply(.heading(2), "- [ ] task\n  mo¦re\n") == "- [ ] task\n  ## mo¦re\n", "a later line of the item is text like any")
        #expect(apply(.bulletList, "- [ ] ta¦sk\n") == "- ta¦sk\n", "the list commands still do")
    }

    @Test func codeBlockNeedsLinesThatOneFenceCanHold() {
        #expect(apply(.codeBlock, "- ¦one\n- two¦\n") == nil, "two list items")
        #expect(apply(.codeBlock, "- ¦one\n\ntext¦\n") == nil, "an item and text outside it")
        #expect(apply(.codeBlock, "> ¦one\n\ntwo¦\n") == nil)
        expectToggle(.codeBlock, "¦text\n- item¦\n", "```\n¦text\n- item¦\n```\n")
        expectToggle(.codeBlock, "- ¦one\n  two¦\n", "- ```\n  ¦one\n  two¦\n  ```\n")
        expectToggle(.codeBlock, "- ¦one\n  - two¦\n", "- ```\n  ¦one\n  - two¦\n  ```\n")
    }

    @Test func headingCommandsLeaveCodeTablesAndRulesAlone() {
        #expect(apply(.heading(1), "```\nco¦de\n```\n") == nil)
        #expect(apply(.heading(1), "| ¦a |\n|---|\n") == nil)
        #expect(apply(.heading(1), "---¦\n") == nil)
        #expect(apply(.heading(2), "two ¦lines\nof heading\n===\n") == nil, "a heading of two lines cannot be written with #")
    }

    @Test func aSetextHeadingIsConvertedByLosingItsUnderline() {
        #expect(apply(.heading(2), "Tit¦le\n=====\n\npara\n") == "## Tit¦le\n\npara\n")
        #expect(apply(.heading(3), "Tit¦le\n---") == "### Tit¦le", "an underline that ends the text")
        #expect(isOn(.heading(1), "Tit¦le\n=====\n") && !isOn(.heading(2), "Tit¦le\n=====\n") && isOn(.heading(2), "Title\n--¦-\n"))
        #expect(apply(.heading(1), "Tit¦le\n=====\n") == "Tit¦le\n", "the level it has: off, like any heading")
        #expect(apply(.paragraph, "Tit¦le\n-----\n\npara\n") == "Tit¦le\n\npara\n")
        #expect(apply(.paragraph, "Tit¦le\n-----\npara\n") == "Tit¦le\n\npara\n", "the text below stays a paragraph of its own")
        #expect(apply(.decreaseHeading, "Tit¦le\n=====\n") == "## Tit¦le\n")
        #expect(apply(.increaseHeading, "Tit¦le\n-----\n") == "# Tit¦le\n")
        // From the underline, alone or with its heading; in a quote the underline's marker goes with it.
        #expect(apply(.heading(2), "Title\n==¦===\ntext\n") == "## Title¦\ntext\n")
        #expect(apply(.heading(2), "¦Title\n=====¦\n") == "## ¦Title¦\n")
        #expect(apply(.heading(3), "> Tit¦le\n> ===\n> more\n") == "> ### Tit¦le\n> more\n")
        #expect(apply(.heading(1), "# a¦\n\nTitle\n---\n\ntext¦\n") == "# a¦\n\n# Title\n\n# text¦\n")
    }

    @Test func headingLevelGoesUpAndDown() {
        #expect(apply(.increaseHeading, "te¦xt") == "###### te¦xt")
        #expect(apply(.increaseHeading, "### te¦xt") == "## te¦xt")
        #expect(apply(.increaseHeading, "# te¦xt") == nil)
        #expect(apply(.decreaseHeading, "# te¦xt") == "## te¦xt")
        #expect(apply(.decreaseHeading, "###### te¦xt") == "te¦xt")
        #expect(apply(.decreaseHeading, "te¦xt") == nil)
    }

    // MARK: lists

    @Test func listCommandsToggleMarkers() {
        expectToggle(.bulletList, "it¦em\n", "- it¦em\n")
        expectToggle(.orderedList, "it¦em\n", "1. it¦em\n")
        expectToggle(.taskList, "it¦em\n", "- [ ] it¦em\n")
        expectToggle(.bulletList, "¦", "- ¦")
        expectToggle(.taskList, "a\n\n¦\n", "a\n\n- [ ] ¦\n")
        expectToggle(.bulletList, "¦one\ntwo\nthree¦\n", "- ¦one\n- two\n- three¦\n")
        expectToggle(.orderedList, "¦one\ntwo\n\nthree¦\n", "1. ¦one\n2. two\n\n3. three¦\n")
        expectToggle(.bulletList, "> it¦em\n", "> - it¦em\n")
    }

    @Test func listCommandsConvertBetweenKinds() {
        #expect(apply(.orderedList, "- ¦one\n- two¦\n") == "1. ¦one\n2. two¦\n")
        #expect(apply(.bulletList, "1. ¦one\n2. two¦\n") == "- ¦one\n- two¦\n")
        #expect(apply(.taskList, "* on¦e\n") == "* [ ] on¦e\n")
        #expect(apply(.bulletList, "* [x] on¦e\n") == "* on¦e\n")
        #expect(apply(.taskList, "- [x] ¦one\n- two¦\n") == "- [x] ¦one\n- [ ] two¦\n", "a mixed selection becomes all tasks")
        #expect(apply(.orderedList, "- a\n  - ne¦sted\n") == "- a\n  1. ne¦sted\n")
        #expect(isOn(.taskList, "- [ ] a¦") && !isOn(.bulletList, "- [ ] a¦") && isOn(.orderedList, "3) a¦"))
    }

    @Test func removingAMarkerBelowAParagraphKeepsTheTextApart() {
        #expect(apply(.bulletList, "- one\n- tw¦o\n") == "- one\n\ntw¦o\n")
        #expect(apply(.bulletList, "> - one\n> - tw¦o\n") == "> - one\n>\n> tw¦o\n")
        #expect(apply(.quote, "> one\n> tw¦o\n") == "> one\n\ntw¦o\n")
    }

    @Test func anEmptyItemBelowAParagraphGetsABlankLineBefore() {
        // "-" directly under a paragraph underlines it as a heading, and "1." there is text.
        for (command, marker) in [(FormatCommand.bulletList, "- "), (.orderedList, "1. "), (.taskList, "- [ ] ")] {
            #expect(apply(command, "a\n¦") == "a\n\n\(marker)¦")
            #expect(apply(command, "one\n¦\nthree\n") == "one\n\n\(marker)¦\nthree\n")
            #expect(apply(command, "> a\n> ¦\n") == "> a\n>\n> \(marker)¦\n")
            #expect(isOn(command, "a\n\n\(marker)¦") && apply(command, "a\n\n\(marker)¦") == "a\n\n¦", "and toggles off")
        }
        #expect(apply(.bulletList, "a\n¦b\n") == "a\n- ¦b\n", "an item with text starts where it is")
    }

    @Test func itemsBelowAnOrderedItemThatLosesItsNumberStayAList() {
        #expect(apply(.orderedList, "1. a\n2. b¦\n3. c\n") == "1. a\n\nb¦\n\n3. c\n")
        #expect(apply(.orderedList, "> 1. a¦\n> 2. b\n") == "> a¦\n>\n> 2. b\n")
        #expect(apply(.orderedList, "1. a\n2. b¦\n\n3. c\n") == "1. a\n\nb¦\n\n3. c\n", "already apart")
        #expect(apply(.orderedList, "1. a\n2. b¦\n") == "1. a\n\nb¦\n")
        let map = MarkdownStyler.style("1. a\n\nb\n\n3. c\n")
        #expect(map.lines[4].listMarkers.count == 1)
    }

    @Test func quoteStaysInsideTheListItemOfItsLine() {
        expectToggle(.quote, "- a\n  - nes¦ted\n", "- a\n  > - nes¦ted\n")
        #expect(apply(.quote, "- a\n  co¦nt\n") == "- a\n  > co¦nt\n")
        #expect(apply(.quote, "- a\n  ¦- one\n\n  - two¦\n") == "- a\n  > ¦- one\n  >\n  > - two¦\n")
        #expect(apply(.quote, "¦- a\n  cont¦\n") == "> ¦- a\n>   cont¦\n", "one column for all lines")
        let map = MarkdownStyler.style("- a\n  > - nested\n")
        #expect(map.lines[1].containers == [.listItem(markerLength: 1), .quote, .listItem(markerLength: 1)])
    }

    @Test func listCommandsDoNotApplyToCodeOrTables() {
        #expect(apply(.bulletList, "```\nco¦de\n```\n") == nil)
        #expect(apply(.taskList, "| ¦a |\n|---|\n") == nil)
        #expect(apply(.orderedList, "¦text\n\n```\ncode\n```¦\n") == nil)
    }

    // MARK: quotes, code, rules, tables

    @Test func quoteTogglesOnEveryLine() {
        expectToggle(.quote, "te¦xt\n", "> te¦xt\n")
        expectToggle(.quote, "¦", "> ¦")
        expectToggle(.quote, "¦one\n\ntwo¦\n", "> ¦one\n>\n> two¦\n")
        expectToggle(.quote, "- it¦em\n", "> - it¦em\n")
        expectToggle(.quote, "¦```\ncode\n```¦\n", "> ¦```\n> code\n> ```¦\n")
        #expect(apply(.quote, "> > de¦ep\n") == "> de¦ep\n")
        #expect(apply(.quote, ">te¦xt\n") == "te¦xt\n")
    }

    @Test func codeBlockWrapsTheSelectedLinesAndUnwrapsThem() {
        expectToggle(.codeBlock, "co¦de\n", "```\nco¦de\n```\n")
        expectToggle(.codeBlock, "¦", "```\n¦\n```")
        expectToggle(.codeBlock, "a\n\n¦\n", "a\n\n```\n¦\n```\n")
        expectToggle(.codeBlock, "¦one\ntwo¦\nthree\n", "```\n¦one\ntwo¦\n```\nthree\n")
        expectToggle(.codeBlock, "> co¦de\n", "> ```\n> co¦de\n> ```\n")
        expectToggle(.codeBlock, "- co¦de\n", "- ```\n  co¦de\n  ```\n")
        expectToggle(.codeBlock, "co¦de\r\nnext\r\n", "```\r\nco¦de\r\n```\r\nnext\r\n")
        #expect(apply(.codeBlock, "```swift\nlet a¦ = 1\n```\n") == "let a¦ = 1\n")
        #expect(apply(.codeBlock, "```\ncode\n```¦") == "code¦")
        #expect(apply(.codeBlock, "```\nunclo¦sed\n") == "unclo¦sed\n")
        #expect(apply(.codeBlock, "    inden¦ted\n") == nil)
    }

    @Test func ruleGoesOnItsOwnLineWithTheCaretBelow() {
        #expect(apply(.rule, "¦") == "---\n¦")
        #expect(apply(.rule, "te¦xt") == "text\n\n---\n¦")
        #expect(apply(.rule, "te¦xt\nmore\n") == "text\n\n---\n¦\nmore\n")
        #expect(apply(.rule, "text\n¦\n") == "text\n\n---\n¦\n", "below a paragraph a blank line keeps it from being a heading underline")
        #expect(apply(.rule, "text\n\n¦\n") == "text\n\n---\n¦\n")
        #expect(apply(.rule, "> te¦xt\n") == "> text\n>\n> ---\n> ¦\n")
        #expect(apply(.rule, "a\r\n¦") == "a\r\n\r\n---\r\n¦")
        #expect(apply(.rule, "```\nco¦de\n```\n") == nil)
        for result in ["---\n", "text\n\n---\n", "text\n\n---\n\nmore\n"] {
            #expect(MarkdownStyler.style(result).lines.contains { $0.kind == .rule })
        }
    }

    @Test func insertTableMakesARegularTableWithTheCaretInItsFirstCell() throws {
        let cases = ["¦": "| ¦  |   |   |\n|---|---|---|\n|   |   |   |\n|   |   |   |",
                     "te¦xt\nmore\n": "text\n\n| ¦  |   |   |\n|---|---|---|\n|   |   |   |\n|   |   |   |\n\nmore\n",
                     "text\n\n¦\n\nmore\n": "text\n\n| ¦  |   |   |\n|---|---|---|\n|   |   |   |\n|   |   |   |\n\nmore\n"]
        for (marked, expected) in cases {
            let result = try #require(apply(.table, marked))
            #expect(result == expected)
            let text = parse(result).text, map = MarkdownStyler.style(text)
            let table = try #require(map.tables.first)
            #expect(table.lines.count == 4 && table.alignments.count == 3 && map.isRegular(table))
        }
        #expect(apply(.table, "| ¦a |\n|---|\n") == nil)
    }

    // MARK: typing and pasting

    private func wrap(_ typed: String, _ marked: String) -> String? {
        apply({ FormatCommands.wrap(typed, in: $0, map: $1, selection: $2) }, marked)
    }

    private func paste(_ pasted: String, _ marked: String) -> String? {
        apply({ FormatCommands.link(pasting: pasted, in: $0, map: $1, selection: $2) }, marked)
    }

    @Test func aTypedMarkerGoesAroundTheSelection() {
        #expect(wrap("*", "a ¦word¦ b") == "a *¦word¦* b")
        #expect(wrap("*", "a *¦word¦* b") == "a **¦word¦** b")
        #expect(wrap("`", "a ¦word¦ b") == "a `¦word¦` b")
        #expect(wrap("_", "a ¦word¦ b") == "a _¦word¦_ b")
        #expect(wrap("~", "a ¦word¦ b") == "a ~¦word¦~ b")
        #expect(wrap("*", "¦word here\n¦next\n") == "*¦word here¦*\nnext\n", "a line selected with its break")
        #expect(wrap("*", "a ¦ b") == nil, "a caret just types")
        #expect(wrap("x", "a ¦word¦ b") == nil)
        #expect(wrap("(", "a ¦word¦ b") == nil)
        #expect(wrap("*", "```\n¦code¦\n```") == nil)
    }

    @Test func aURLPastedOverASelectionMakesALink() {
        #expect(paste("https://example.com/a?b=c", "see ¦this page¦ now") == "see [this page](https://example.com/a?b=c)¦ now")
        #expect(paste(" mailto:a@b.c\n", "¦mail¦") == "[mail](mailto:a@b.c)¦")
        #expect(paste("https://example.com", "see ¦ now") == nil, "no selection: a plain paste")
        #expect(paste("not a url", "see ¦this¦ now") == nil)
        #expect(paste("https://a.b two words", "see ¦this¦ now") == nil)
        #expect(paste("https://new.example", "[text](¦https://old.example¦)") == nil, "a URL replaces a URL")
        #expect(paste("https://new.example", "¦https://old.example¦") == nil)
        #expect(paste("https://example.com", "```\n¦code¦\n```") == nil)
    }

    @Test func imageMarkupEscapesWhatWouldEndIt() {
        #expect(FormatCommands.imageMarkup(alt: "a cat", path: "images/cat.png") == "![a cat](images/cat.png)")
        #expect(FormatCommands.imageMarkup(alt: "x]y", path: "my pics/a (1).png") == "![x\\]y](my%20pics/a%20%281%29.png)")
        #expect(FormatCommands.imageMarkup(alt: "shot #1", path: "shot #1.png") == "![shot #1](shot%20%231.png)")
        #expect(FormatCommands.imageMarkup(alt: "a%20b", path: "a%20b.png") == "![a%20b](a%2520b.png)")
        #expect(FormatCommands.linkMarkup(text: "x]y", path: "my docs/a (1).md") == "[x\\]y](my%20docs/a%20%281%29.md)")
        let map = MarkdownStyler.style(FormatCommands.imageMarkup(alt: "x]y", path: "my pics/a (1).png"))
        #expect(map.lines[0].tokens.first?.destination == "my%20pics/a%20%281%29.png")
    }

    @Test func theMarkupOfAFileWithAnyNameIsOneLinkToThatFile() {
        for name in ["open[only", "we]ird [x]", "tick`s", "tail\\", "amp&lt;", "a*b* _c_", "<tag>", "q?:'\"é (1) #2 50%"] {
            let path = "../\(name).md", markup = FormatCommands.linkMarkup(text: name, path: path) as NSString
            let tokens = MarkdownStyler.style(markup as String).lines[0].tokens
            #expect(tokens.first?.kind == .link && tokens.first?.range == NSRange(location: 0, length: markup.length), "\(markup)")
            #expect(tokens.first?.destination?.removingPercentEncoding == path, "\(markup)")
            // What shows is the name: nothing in it is markup but the backslashes that escape.
            #expect(tokens.dropFirst().allSatisfy { $0.kind == .escape }, "\(markup)")
            let shown = tokens.first.map { markup.substring(with: $0.contentRange) } ?? ""
            #expect(shown.count - tokens.count + 1 == name.count, "\(markup)")
        }
    }

    // MARK: robustness

    @Test func aMapOlderThanTheTextGivesNoEdit() {
        let map = MarkdownStyler.style("old text\n")
        #expect(FormatCommands.edit(.bold, in: "new longer text\n", map: map, selection: NSRange(location: 2, length: 3)) == nil)
        #expect(FormatCommands.edit(.heading(1), in: "", map: map, selection: NSRange(location: 0, length: 0)) == nil)
    }

    /// Every command at every caret and over a few selections of a mixed document: the edit stays
    /// inside the text and leaves the selection inside the result.
    @Test func everyCommandEverywhereStaysInBounds() {
        let text = "# Title\n\npara **bold** and `code` [l](u)\n- item\n  - [ ] task\n> quote\n\n```swift\nlet a = 1\n```\n\n| a | b |\n|---|---|\n| c | d |\n\nSetext\n===\n\n---\nlast"
        let map = MarkdownStyler.style(text), length = (text as NSString).length
        let commands: [FormatCommand] = [.bold, .italic, .strikethrough, .code, .link, .image, .paragraph, .increaseHeading,
                                         .decreaseHeading, .bulletList, .orderedList, .taskList, .quote, .codeBlock, .rule, .table]
                                         + (1...6).map(FormatCommand.heading)
        for command in commands {
            for location in 0...length {
                for extent in [0, 1, 7, 40] where location + extent <= length {
                    let selection = NSRange(location: location, length: extent)
                    guard let edit = FormatCommands.edit(command, in: text, map: map, selection: selection) else { continue }
                    #expect(NSMaxRange(edit.range) <= length)
                    let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
                    #expect(NSMaxRange(edit.selection) <= result.length, "\(command) at \(selection)")
                }
            }
        }
    }
}

@Suite struct AnchorTests {
    @Test func anAnchorIsTheHeadingsTextAsGitHubWritesIt() {
        let text = "# Top\n\n## The *second* part\ntext\n### Émile's `code` & more!\n\n## Top\n\nSetext heading\n---\n> # In a quote [link](u)\n"
        let map = MarkdownStyler.style(text)
        func line(_ anchor: String) -> Int? { map.headingLine(forAnchor: anchor, in: text) }
        #expect(line("top") == 0)
        #expect(line("the-second-part") == 2)
        #expect(line("The-Second-Part") == 2, "case does not matter")
        #expect(line("émiles-code--more") == 4)
        #expect(line("%C3%A9miles-code--more") == 4, "percent-encoded as a URL has it")
        #expect(line("top-1") == 6, "a repeated heading is numbered")
        #expect(line("setext-heading") == 8)
        #expect(line("in-a-quote-link") == 10)
        #expect(line("missing") == nil && line("") == nil && line("text") == nil)
    }
}
