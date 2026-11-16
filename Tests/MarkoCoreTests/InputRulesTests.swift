import Foundation
import Testing
@testable import MarkoCore

@Suite struct InputRulesTests {
    typealias Rule = (String, StyleMap, NSRange) -> TextEdit?

    /// Applies `rule` to `marked`, where "¦" stands for the caret or, twice, for the ends of the
    /// selection, and returns the result in the same notation, or nil when the rule leaves the key alone.
    private func apply(_ rule: Rule, _ marked: String) -> String? {
        let parts = marked.components(separatedBy: "¦")
        let text = parts.joined()
        let selection = NSRange(location: (parts[0] as NSString).length, length: parts.count > 2 ? (parts[1] as NSString).length : 0)
        guard let edit = rule(text, MarkdownStyler.style(text), selection) else { return nil }
        let result = NSMutableString(string: (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement))
        if edit.selection.length > 0 { result.insert("¦", at: NSMaxRange(edit.selection)) }
        result.insert("¦", at: edit.selection.location)
        return result as String
    }

    private let newline: Rule = { InputRules.newline(in: $0, map: $1, selection: $2) }
    private let backspace: Rule = { InputRules.deleteBackward(in: $0, map: $1, selection: $2) }
    private let delete: Rule = { InputRules.deleteForward(in: $0, map: $1, selection: $2) }
    private let indent: Rule = { InputRules.indent(in: $0, map: $1, selection: $2) }
    private let outdent: Rule = { InputRules.outdent(in: $0, map: $1, selection: $2) }
    private func closing(_ bracket: String) -> Rule { { InputRules.closingBracket(bracket, in: $0, map: $1, selection: $2) } }

    // MARK: Return

    @Test func returnContinuesListItems() {
        #expect(apply(newline, "- one¦\n") == "- one\n- ¦\n")
        #expect(apply(newline, "* one¦") == "* one\n* ¦")
        #expect(apply(newline, "- on¦e\n") == "- on\n- ¦e\n")
        #expect(apply(newline, "- a\n  - nested¦\n") == "- a\n  - nested\n  - ¦\n")
        #expect(apply(newline, "- a\n  continued¦\n") == "- a\n  continued\n  ¦\n")
        #expect(apply(newline, "-\tone¦\n") == "-\tone\n-\t¦\n")
    }

    @Test func returnIncrementsOrderedNumbers() {
        #expect(apply(newline, "1. one¦\n") == "1. one\n2. ¦\n")
        #expect(apply(newline, "9) nine¦\n") == "9) nine\n10) ¦\n")
        #expect(apply(newline, "- a\n\n  41. x¦\n") == "- a\n\n  41. x\n  42. ¦\n")
    }

    @Test func returnContinuesTasksUnchecked() {
        #expect(apply(newline, "- [x] done¦\n") == "- [x] done\n- [ ] ¦\n")
        #expect(apply(newline, "1. [ ] todo¦\n") == "1. [ ] todo\n2. [ ] ¦\n")
    }

    @Test func returnContinuesQuotes() {
        #expect(apply(newline, "> quote¦\n") == "> quote\n> ¦\n")
        #expect(apply(newline, "> > deep¦\n") == "> > deep\n> > ¦\n")
        #expect(apply(newline, "> - item¦\n") == "> - item\n> - ¦\n")
        #expect(apply(newline, "- > quoted¦\n") == "- > quoted\n  > ¦\n")
        #expect(apply(newline, "> # Title¦\n") == "> # Title\n> ¦\n")
    }

    @Test func returnOnAnEmptyItemLeavesTheList() {
        #expect(apply(newline, "- one\n- ¦\n") == "- one\n\n¦\n")
        #expect(apply(newline, "- ¦") == "¦")
        #expect(apply(newline, "1. one\n2. ¦") == "1. one\n\n¦")
        #expect(apply(newline, "- [ ] one\n- [ ] ¦\n") == "- [ ] one\n\n¦\n")
        #expect(apply(newline, "- a\n  - b\n  - ¦\n") == "- a\n  - b\n- ¦\n", "a nested item moves out one level")
        #expect(apply(newline, "> - a\n> - ¦\n") == "> - a\n>\n> ¦\n", "and stays in its quote")
    }

    @Test func returnOnAnEmptyQuoteLineLeavesTheQuote() {
        #expect(apply(newline, "> quote\n> ¦\n") == "> quote\n\n¦\n")
        #expect(apply(newline, "> > deep\n> > ¦\n") == "> > deep\n>\n> ¦\n")
        #expect(apply(newline, "> ¦") == "¦")
    }

    @Test func returnLeavesOrdinaryLinesAlone() {
        #expect(apply(newline, "plain¦\n") == nil)
        #expect(apply(newline, "# Title¦\n") == nil)
        #expect(apply(newline, "```\ncode¦\n```\n") == nil)
        #expect(apply(newline, "text\n¦") == nil, "the empty last line is not in the map")
    }

    @Test func returnKeepsTheDocumentsLineEnding() {
        #expect(apply(newline, "- a¦\r\n- b\r\n") == "- a\r\n- ¦\r\n- b\r\n")
        #expect(apply(newline, "- a\r\n- ¦\r\n") == "- a\r\n\r\n¦\r\n")
        #expect(apply(newline, "a\r\n- b¦") == "a\r\n- b\r\n- ¦", "a last line without an ending takes the one above")
        #expect(apply(newline, "a¦\r\nb\r\n") == "a\r\n¦\r\nb\r\n", "also where Return has no rule")
        #expect(apply(newline, "```¦\r\n") == "```\r\n¦\r\n```\r\n")
        #expect(apply(backspace, "- a\r\n- ¦b\r\n") == "- a\r\n\r\n¦b\r\n")
        let text = "```\r\nx\r\n"
        #expect(InputRules.newline(in: text, map: MarkdownStyler.style(text), selection: NSRange(location: 4, length: 0)) == nil,
                "between CR and LF")
    }

    @Test func returnAfterAnOpeningFenceClosesIt() {
        #expect(apply(newline, "```swift¦") == "```swift\n¦\n```")
        #expect(apply(newline, "intro\n\n~~~~¦\n\nrest **b**\n") == "intro\n\n~~~~\n¦\n~~~~\n\nrest **b**\n")
        #expect(apply(newline, "> ```¦\n") == "> ```\n> ¦\n> ```\n")
        #expect(apply(newline, "- ```js¦\n") == "- ```js\n  ¦\n  ```\n")
    }

    @Test func returnAfterAFenceThatHasItsClosingOneAddsNothing() {
        #expect(apply(newline, "```swift¦\nlet x\n```\n") == nil)
        #expect(apply(newline, "```¦\n```\n") == nil)
        #expect(apply(newline, "```\ncode\n```¦\n") == nil, "a closing fence")
        #expect(apply(newline, "``¦`swift\ncode\n") == nil, "not at the end of the line")
    }

    @Test func aFenceThatSwallowedALaterBlocksOpeningIsClosed() {
        #expect(apply(newline, "```¦\n\ntext\n\n```swift\nlet x\n```\n") == "```\n¦\n```\n\ntext\n\n```swift\nlet x\n```\n")
        #expect(apply(newline, "````md¦\n```swift\nlet x\n```\n````\n") == nil, "a shorter fence inside is content")
    }

    @Test func aClosingFenceTypedAboveTheOneThatWasAddedTypesOverIt() {
        #expect(apply(newline, "```swift\nlet x = 1\n```¦\n```") == "```swift\nlet x = 1\n```\n¦")
        #expect(apply(newline, "```\nx\n```¦\n```\n\ntext\n\n~~~js\ny\n~~~\n") == "```\nx\n```\n¦\n\ntext\n\n~~~js\ny\n~~~\n")
        #expect(apply(newline, "```\nx\n```¦\n```\n\n```js\ny\n```\n") == "```\nx\n```\n¦\n\n```js\ny\n```\n", "it had swallowed the next block's opening")
        #expect(apply(newline, "> ```\n> x\n> ```¦\n> ```\n") == "> ```\n> x\n> ```\n> ¦\n")
        #expect(apply(newline, "- ```\n  x\n  ```¦\n  ```\n") == "- ```\n  x\n  ```\n  ¦\n")
        // A block that follows directly and is closed is the user's.
        #expect(apply(newline, "```\nx\n```¦\n```\ny\n```\n") == nil)
        #expect(apply(newline, "```\nx\n```¦\n```js\ny\n") == nil, "a fence with a language is no closing fence")
        #expect(apply(newline, "```\nx\n```¦\n````\n") == nil, "another fence")
        #expect(apply(newline, "```\nx\n``¦`\n```\n") == nil, "not at the end of the line")
    }

    @Test func returnInsideCodeInAContainerKeepsTheContainer() {
        #expect(apply(newline, "> ```\n> code¦\n> ```\n") == "> ```\n> code\n> ¦\n> ```\n")
        #expect(apply(newline, "> ```\n> ¦\n> ```\n") == "> ```\n> \n> ¦\n> ```\n", "an empty code line does not leave the quote")
    }

    // MARK: Backspace

    @Test func backspaceRemovesTheInnermostMarker() {
        #expect(apply(backspace, "- ¦item\n") == "¦item\n")
        #expect(apply(backspace, "12. ¦item\n") == "¦item\n")
        #expect(apply(backspace, "> ¦quote\n") == "¦quote\n")
        #expect(apply(backspace, "> > ¦deep\n") == "> ¦deep\n")
        #expect(apply(backspace, "> - ¦item\n") == "> ¦item\n")
        #expect(apply(backspace, "- > ¦quoted\n") == "- ¦quoted\n")
        #expect(apply(backspace, "  - ¦stray indentation\n") == "¦stray indentation\n")
        #expect(apply(backspace, "para\n> ¦quote\n") == "para\n\n¦quote\n", "a quote after a paragraph is not a line of it")
        #expect(apply(backspace, "- item\n> ¦quote\n") == "- item\n\n¦quote\n")
        #expect(apply(backspace, "- a\n  > ¦q\n") == "- a\n\n  ¦q\n")
    }

    @Test func backspaceRemovesTheIndentationOfIndentedCode() {
        #expect(apply(backspace, "    ¦code\n") == "¦code\n")
        #expect(apply(backspace, ">     ¦code\n") == "> ¦code\n")
        #expect(apply(newline, "    code¦\n") == "    code\n    ¦\n")
    }

    @Test func backspaceTurnsATaskIntoABulletFirst() {
        #expect(apply(backspace, "- [ ] ¦task\n") == "- ¦task\n")
        #expect(apply(backspace, "1. [x] ¦task\n") == "1. ¦task\n")
    }

    @Test func backspaceMovesANestedItemOut() {
        #expect(apply(backspace, "- a\n  - ¦b\n") == "- a\n- ¦b\n")
        #expect(apply(backspace, "1. a\n   - ¦b\n") == "1. a\n- ¦b\n")
    }

    @Test func backspaceKeepsTheTextOutOfAParagraphAbove() {
        #expect(apply(backspace, "- a\n- ¦b\n") == "- a\n\n¦b\n", "without the blank line b would continue a")
        #expect(apply(backspace, "> - a\n> - ¦b\n") == "> - a\n>\n> ¦b\n")
        #expect(apply(backspace, "# T\n- ¦b\n") == "# T\n¦b\n")
    }

    @Test func backspaceJoinsTheLinesOfAParagraph() {
        #expect(apply(backspace, "> one\n> ¦two\n") == "> one¦two\n")
        #expect(apply(backspace, "- one\n  ¦two\n") == "- one¦two\n")
        #expect(apply(backspace, "> one\r\n> ¦two\r\n") == "> one¦two\r\n")
        #expect(apply(backspace, "- one\n\n  ¦loose\n") == "- one\n\n¦loose\n")
    }

    @Test func backspaceElsewhereIsOrdinary() {
        #expect(apply(backspace, "- i¦tem\n") == nil)
        #expect(apply(backspace, "¦plain\n") == nil)
        #expect(apply(backspace, "plain\n¦more\n") == nil)
        let text = "- item\n"
        #expect(InputRules.deleteBackward(in: text, map: MarkdownStyler.style(text), selection: NSRange(location: 2, length: 3)) == nil)
    }

    // MARK: forward Delete

    @Test func deleteAtTheEndOfALineJoinsItWithTheContentOfTheNext() {
        #expect(apply(delete, "- alpha¦\n- beta\n") == "- alpha¦beta\n")
        #expect(apply(delete, "> one¦\r\n> two\r\n") == "> one¦two\r\n")
        #expect(apply(delete, "para¦\n  - [ ] task\n") == "para¦task\n")
        #expect(apply(delete, "- ¦\n- beta\n") == "- ¦beta\n")
        #expect(apply(delete, "- al¦pha\n- beta\n") == nil)
        #expect(apply(delete, "alpha¦\nbeta\n") == nil)
        #expect(apply(delete, "¦\n- beta\n") == nil, "an empty line just goes")
        #expect(apply(delete, "- last¦") == nil)
    }

    // MARK: Tab

    @Test func tabNestsAnItemUnderTheOneBefore() {
        #expect(apply(indent, "- a\n- ¦b\n") == "- a\n  - ¦b\n")
        #expect(apply(indent, "1. a\n2. b¦\n") == "1. a\n   1. b¦\n", "only a list that starts with 1 begins below text")
        #expect(apply(indent, "- [ ] a\n- [ ] ¦b\n") == "- [ ] a\n  - [ ] ¦b\n")
        #expect(apply(indent, "> - a\n> - ¦b\n") == "> - a\n>   - ¦b\n")
        #expect(apply(indent, "- a\n  - x\n- ¦b\n") == "- a\n  - x\n  - ¦b\n", "past the children of the item before")
    }

    @Test func tabTakesTheItemsChildrenAlong() {
        #expect(apply(indent, "- a\n- ¦b\n  - c\n\n  text\n- d\n") == "- a\n  - ¦b\n    - c\n\n    text\n- d\n")
        #expect(apply(outdent, "- a\n  - ¦b\n    - c\n    text\n  - d\n") == "- a\n- ¦b\n  - c\n  text\n  - d\n")
    }

    @Test func tabMovesEveryItemTheSelectionReaches() {
        func apply(_ rule: Rule, _ text: String, from: String, to: String) -> (text: String, selected: String)? {
            let source = text as NSString, start = source.range(of: from).location
            let selection = NSRange(location: start, length: NSMaxRange(source.range(of: to)) - start)
            guard let edit = rule(text, MarkdownStyler.style(text), selection) else { return nil }
            let result = source.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
            return (result as String, result.substring(with: edit.selection))
        }
        let list = "- one\n- two\n- three\n- four\n"
        let nested = apply(indent, list, from: "two", to: "thr")
        #expect(nested?.text == "- one\n  - two\n  - three\n- four\n" && nested?.selected == "two\n  - thr", "one step for both, the selection on the same text")
        let back = apply(outdent, "- one\n  - two\n  - three\n- four\n", from: "wo", to: "three")
        #expect(back?.text == list && back?.selected == "wo\n- three")
        // What is nested in a selected item goes along; the item after the selection stays.
        #expect(apply(indent, "1. a\n2. b\n   - x\n3. c\n4. d\n", from: "b", to: "c")?.text == "1. a\n   1. b\n      - x\n   2. c\n4. d\n")
        #expect(apply(indent, "> - a\n> - b\n> - c\n", from: "b", to: "c")?.text == "> - a\n>   - b\n>   - c\n")
        // A selection that ends at the start of an item does not take that item.
        #expect(apply(indent, list, from: "two", to: "two\n")?.text == "- one\n  - two\n- three\n- four\n")
        // The selection runs on into text that is no item beside the first: only the items move.
        #expect(apply(indent, "- a\n- b\n\ntext\n", from: "b", to: "text")?.text == "- a\n  - b\n\ntext\n")
    }

    @Test func tabDoesNothingWhereAnItemHasNothingToNestUnder() {
        // And is no tab in the item's text, nor in place of what is selected.
        #expect(apply(indent, "- ¦a\n") == "- ¦a\n")
        #expect(apply(indent, "- a¦\n") == "- a¦\n")
        #expect(apply(indent, "- a\n  - ¦b\n") == "- a\n  - ¦b\n")
        #expect(apply(indent, "- a\n  continued¦\n") == "- a\n  continued¦\n")
        #expect(apply(indent, "- ¦one¦\n") == "- ¦one¦\n")
        #expect(apply(indent, "plain¦\n") == nil)
    }

    @Test func shiftTabMovesAnItemOut() {
        #expect(apply(outdent, "- a\n  - ¦b\n") == "- a\n- ¦b\n")
        #expect(apply(outdent, "- a\n  - b¦\n") == "- a\n- b¦\n")
        #expect(apply(outdent, "1. a\n   - b¦\n") == "1. a\n- b¦\n")
        #expect(apply(outdent, "> - a\n>   - ¦b\n") == "> - a\n> - ¦b\n")
        #expect(apply(outdent, "- a\n  - b\n    - ¦c\n") == "- a\n  - b\n  - ¦c\n")
        #expect(apply(outdent, "- a\n  - b\n  - ¦\n") == "- a\n  - b\n- ¦\n", "an empty item")
        #expect(apply(outdent, "- [ ] a\n  - [ ] b¦\n- [ ] c\n") == "- [ ] a\n- [ ] b¦\n- [ ] c\n")
        #expect(apply(outdent, "plain¦\n") == nil)
        #expect(apply(outdent, "> quote¦\n") == nil)
    }

    @Test func tabAndShiftTabWorkFromAnyLineOfTheItem() {
        #expect(apply(outdent, "- a\n  - b\n    more¦\n") == "- a\n- b\n  more¦\n")
        #expect(apply(indent, "- a\n- b\n  mo¦re\n") == "- a\n  - b\n    mo¦re\n")
        #expect(apply(outdent, "- a\n  - b\n\n    second ¦paragraph\n") == "- a\n- b\n\n  second ¦paragraph\n")
    }

    /// Shift-Tab on an empty item that has no parent leaves the list, as a second Return does.
    @Test func shiftTabOnAnEmptyItemWithoutAParentLeavesTheListAsReturnDoes() {
        for list in ["- one\n- ¦\n", "- ¦", "1. one\n2. ¦", "- [ ] one\n- [ ] ¦\n", "> - a\n> - ¦\n", "- one\n-¦\n"] {
            let left = apply(outdent, list)
            #expect(left != nil && left == apply(newline, list), "\(list.debugDescription)")
        }
        #expect(apply(outdent, "- one\n- ¦\n") == "- one\n\n¦\n")
        // An item with text stays in its list: the key is for its level.
        #expect(apply(outdent, "- ¦a\n") == nil)
        #expect(apply(outdent, "- one\n- two¦\n") == nil)
        #expect(apply(outdent, "- a\n  more¦\n") == nil)
        #expect(apply(outdent, "- ¦\n- b¦\n") == nil, "and so do several")
    }

    /// Tab on an empty item leaves a marker alone on its line below the text of the item before.
    /// The parser reads "-" there as that text's underline and any other marker as more of the
    /// text; the keys still take it for the item it is about to be.
    @Test func anEmptyItemNestedBelowTextIsStillAnItemForTheKeys() {
        #expect(apply(indent, "- one\n- ¦") == "- one\n  - ¦")
        #expect(MarkdownStyler.style("- one\n  - ").lines[1].kind == .headingUnderline(level: 2))
        #expect(apply(outdent, "- one\n  - ¦") == "- one\n- ¦")
        #expect(apply(outdent, "- one\n  -¦") == "- one\n-¦")
        #expect(apply(outdent, "* one\n  * ¦\n") == "* one\n* ¦\n")
        #expect(apply(outdent, "> - one\n>   - ¦\n") == "> - one\n> - ¦\n")
        #expect(apply(indent, "1. one\n2. ¦") == "1. one\n   1. ¦")
        #expect(apply(outdent, "1. one\n   1. ¦") == "1. one\n2. ¦")
        #expect(apply(outdent, "- one\n  - two\n    - ¦") == "- one\n  - two\n  - ¦")
        // Text that only looks so is left alone.
        #expect(apply(outdent, "- one\n  - x¦") == "- one\n- x¦")
        #expect(apply(outdent, "one\n-¦\n") == nil)
    }

    @Test func aNumberedItemThatMovesTakesTheNumberOfItsNewPlace() {
        #expect(apply(indent, "1. a\n   1. x\n2. b¦\n") == "1. a\n   1. x\n   2. b¦\n")
        #expect(apply(indent, "1. a\n   1. x\n      - deep\n2. b¦\n") == "1. a\n   1. x\n      - deep\n   2. b¦\n")
        #expect(apply(indent, "1. a\n   - x\n2. b¦\n") == "1. a\n   - x\n   1. b¦\n")
        #expect(apply(indent, "9. a\n10. b¦\n") == "9. a\n   1. b¦\n")
        #expect(apply(outdent, "1. a\n   1. b\n   2. c¦\n") == "1. a\n   1. b\n2. c¦\n")
        #expect(apply(outdent, "1. a\n   1. ¦b\n   2. c¦\n") == "1. a\n2. ¦b\n3. c¦\n")
        #expect(apply(outdent, "- a\n\n  3. b¦\n") == "- a\n\n3. b¦\n", "under a bullet it keeps its number")
        #expect(apply(indent, "1) a\n2) b¦\n") == "1) a\n   1) b¦\n")
    }

    @Test func whatIsNestedInAnItemFollowsItsTextWhenItsNumberGetsLongerOrShorter() {
        let nine = (1...9).map { "\($0). a\n" }.joined()
        #expect(apply(outdent, nine + "   1. b¦\n      - c\n") == nine + "10. b¦\n    - c\n")
        #expect(apply(indent, nine + "10. b¦\n    - c\n") == nine + "   1. b¦\n      - c\n", "and back")
        let text = nine + "10. b\n    - c\n"
        #expect(MarkdownStyler.style(text).lines.suffix(2).map(\.listDepth) == [1, 2], "still nested")
        let many = (1...99).map { "\($0). a\n" }.joined()
        #expect(apply(outdent, many + "    1. b¦\n       - c\n\n         d\n") == many + "100. b¦\n     - c\n\n       d\n")
    }

    @Test func returnAndBackspaceTakeAMarkerAloneBelowTextForAnEmptyItem() {
        #expect(apply(newline, "- one\n  - ¦") == "- one\n- ¦")
        #expect(apply(newline, "- one\n  -¦") == "- one\n-¦")
        #expect(apply(newline, "- one\n  - two\n  - ¦") == "- one\n  - two\n- ¦", "as every later nested item does")
        #expect(apply(newline, "1. one\n   1. ¦\n") == "1. one\n2. ¦\n")
        #expect(apply(newline, "> - one\n>   - ¦\n") == "> - one\n> - ¦\n")
        #expect(apply(backspace, "- one\n  - ¦") == "- one\n- ¦")
        #expect(apply(backspace, "- one\n  - two\n  - ¦") == "- one\n  - two\n- ¦")
        #expect(apply(backspace, "- one\n  -¦") == nil, "the marker itself goes by the plain key")
        #expect(apply(newline, "one\n- ¦\n") == nil, "not in a list")
    }

    @Test func tabAndShiftTabMoveEachSelectedItemByItself() {
        #expect(apply(outdent, "- a\n  - ¦b\n- c¦\n") == "- a\n- ¦b\n- c¦\n", "the one that has a parent")
        #expect(apply(indent, "- a\n  - ¦b\n- c¦\n") == "- a\n  - ¦b\n  - c¦\n", "the one that has an item to go under")
        #expect(apply(outdent, "- a\n  - ¦b\n    - c\n  - d¦\n  - e\n") == "- a\n- ¦b\n  - c\n- d¦\n  - e\n", "what is nested in a selected item goes with it, once")
        #expect(apply(outdent, "- a\n  - b\n    - ¦c\n  - d\n    - e¦\n") == "- a\n  - b\n  - ¦c\n- d\n  - e¦\n")
        #expect(apply(indent, "- a\n- ¦b\n\n- c¦\n") == "- a\n  - ¦b\n\n  - c¦\n", "across a blank line")
    }

    // MARK: code

    /// Return after a line that opens a block (a Python `def`, say) indents the next line.
    @Test func returnBehindALineThatOpensABlockIndentsTheNext() {
        #expect(apply(newline, "```python\ndef f():¦\n```\n") == "```python\ndef f():\n    ¦\n```\n")
        #expect(apply(newline, "```py\nif x:  ¦\n```\n") == "```py\nif x:  \n    ¦\n```\n")
        #expect(apply(newline, "```yaml\nkey:¦\n```\n") == "```yaml\nkey:\n    ¦\n```\n")
        #expect(apply(newline, "```js\nfunction f() {¦\n```\n") == "```js\nfunction f() {\n    ¦\n```\n")
        #expect(apply(newline, "```\nfoo(a,¦\n```\n") == "```\nfoo(a,\n    ¦\n```\n", "a bracket left open, in any language")
        #expect(apply(newline, "```\nx = [¦\n```\n") == "```\nx = [\n    ¦\n```\n")
        #expect(apply(newline, "```js\n} else {¦\n```\n") == "```js\n} else {\n    ¦\n```\n")
        #expect(apply(newline, "~~~Python\nclass A:¦\n~~~\n") == "~~~Python\nclass A:\n    ¦\n~~~\n")
        // Only what stands before the caret counts.
        #expect(apply(newline, "```js\nif (a) {¦ b() }\n```\n") == "```js\nif (a) {\n    ¦ b() }\n```\n")
    }

    @Test func returnInCodeKeepsTheLinesIndentation() {
        #expect(apply(newline, "```python\ndef f():\n    x = 1¦\n```\n") == "```python\ndef f():\n    x = 1\n    ¦\n```\n")
        #expect(apply(newline, "```python\ndef f():\n    if x:¦\n```\n") == "```python\ndef f():\n    if x:\n        ¦\n```\n")
        #expect(apply(newline, "```\n\tx¦\n```\n") == "```\n\tx\n\t¦\n```\n")
        #expect(apply(newline, "```\n    ¦\n```\n") == "```\n    \n    ¦\n```\n", "a line of blanks")
        #expect(apply(newline, "```\n  ab¦cd\n```\n") == "```\n  ab\n  ¦cd\n```\n")
        #expect(apply(newline, "```\n  a¦bc¦d\n```\n") == "```\n  a\n  ¦d\n```\n", "in place of a selection")
        #expect(apply(newline, "```\r\n  x¦\r\n```\r\n") == "```\r\n  x\r\n  ¦\r\n```\r\n")
    }

    @Test func returnInCodeWithoutIndentationIsThePlainKey() {
        #expect(apply(newline, "```\ncode¦\n```\n") == nil)
        #expect(apply(newline, "```js\ncase 1:¦\n```\n") == nil, "a colon opens nothing in JavaScript")
        #expect(apply(newline, "```\nlabel:¦\n```\n") == nil, "nor without a language")
        #expect(apply(newline, "```js\nf(x)¦\n```\n") == nil, "the bracket is closed")
        #expect(apply(newline, "```js\nf(x) }¦\n```\n") == nil)
        #expect(apply(newline, "```python\nprint(\"(:\")¦\n```\n") == nil, "in a string")
        #expect(apply(newline, "```python\nx = 1  # see f(¦\n```\n") == nil, "in a comment")
        #expect(apply(newline, "text:¦\n") == nil, "not code")
    }

    @Test func aCommentBehindTheColonDoesNotHideIt() {
        #expect(apply(newline, "```python\ndef f():  # note¦\n```\n") == "```python\ndef f():  # note\n    ¦\n```\n")
    }

    @Test func theIndentUnitFollowsTheBlock() {
        #expect(apply(newline, "```js\nif (a) {\n  b()\n  if (c) {¦\n```\n") == "```js\nif (a) {\n  b()\n  if (c) {\n    ¦\n```\n", "two spaces")
        #expect(apply(newline, "```go\nfunc f() {\n\tx()\n\tif y {¦\n```\n") == "```go\nfunc f() {\n\tx()\n\tif y {\n\t\t¦\n```\n", "tabs")
        #expect(apply(newline, "```go\nfunc f() {¦\n\tx()\n}\n```\n") == "```go\nfunc f() {\n\t¦\n\tx()\n}\n```\n")
        #expect(apply(indent, "```js\nif (a) {\n  b()\n¦c()\n```\n") == "```js\nif (a) {\n  b()\n  ¦c()\n```\n")
        // An excerpt that is indented as a whole: the step between its lines counts.
        #expect(apply(newline, "```py\n        def f(self):\n            if x:¦\n```\n") == "```py\n        def f(self):\n            if x:\n                ¦\n```\n")
        #expect(apply(backspace, "```\n        a\n            ¦b\n```\n") == "```\n        a\n        ¦b\n```\n")
        #expect(apply(outdent, "```\n        a\n            b¦\n```\n") == "```\n        a\n        b¦\n```\n")
        #expect(apply(indent, "```\n      a\n        b\n      ¦c\n```\n") == "```\n      a\n        b\n        ¦c\n```\n")
        // Another block's indentation says nothing.
        #expect(apply(newline, "```\n  a\n```\n\n```python\nif x:¦\n```\n") == "```\n  a\n```\n\n```python\nif x:\n    ¦\n```\n")
    }

    @Test func codeInListsQuotesAndIndentedBlocksKeepsItsMarkers() {
        #expect(apply(newline, "- ```py\n  def f():¦\n  ```\n") == "- ```py\n  def f():\n      ¦\n  ```\n")
        #expect(apply(newline, "> ```python\n> if x:¦\n> ```\n") == "> ```python\n> if x:\n>     ¦\n> ```\n")
        #expect(apply(newline, "> ```\n>   x¦\n> ```\n") == "> ```\n>   x\n>   ¦\n> ```\n")
        #expect(apply(newline, "text\n\n    if (x) {¦\n") == "text\n\n    if (x) {\n        ¦\n", "indented code")
        #expect(apply(newline, "text\n\n    a\n      b¦\n") == "text\n\n    a\n      b\n      ¦\n")
        #expect(apply(newline, "1. item\n\n       code {¦\n") == "1. item\n\n       code {\n           ¦\n")
        #expect(apply(indent, "- ```\n  ¦x\n  ```\n") == "- ```\n      ¦x\n  ```\n", "Tab indents the code, not the item")
        #expect(apply(outdent, "- a\n  - ```\n    ¦x\n    ```\n") == "- a\n  - ```\n    ¦x\n    ```\n", "and Shift-Tab leaves the item where it is")
        #expect(apply(backspace, "> ```\n>     ¦x\n> ```\n") == "> ```\n> ¦x\n> ```\n")
    }

    @Test func theFenceRulesComeFirst() {
        #expect(apply(newline, "```python¦") == "```python\n¦\n```")
        #expect(apply(newline, "- ```js¦\n") == "- ```js\n  ¦\n  ```\n")
        #expect(apply(newline, "```\n  x {\n```¦\n```") == "```\n  x {\n```\n¦")
        #expect(apply(newline, "```python\nif x:\n```¦\n") == nil)
    }

    @Test func tabInCodeIndentsByOneUnit() {
        #expect(apply(indent, "```\n¦x\n```\n") == "```\n    ¦x\n```\n")
        #expect(apply(indent, "```\nx = ¦1\n```\n") == "```\nx = \(String(repeating: " ", count: 4))¦1\n```\n")
        #expect(apply(indent, "```\na ¦b¦ c\n```\n") == "```\na     ¦ c\n```\n", "in place of a selection inside the line")
        #expect(apply(indent, "```\n\ta\n¦b\n```\n") == "```\n\ta\n\t¦b\n```\n")
        #expect(apply(indent, "```\n¦a\n\n  b\nc¦\n```\n") == "```\n¦  a\n\n    b\n  c¦\n```\n", "every line of the selection that has text")
        #expect(apply(indent, "```\na¦\nb\n¦c\n```\n") == "```\n    a¦\n    b\n¦c\n```\n", "not a line the selection only ends in front of")
    }

    @Test func aSelectionFromAboveTheCodeIndentsItsLinesOfCode() {
        #expect(apply(indent, "¦```py\na\nb¦\n```\n") == "¦```py\n    a\n    b¦\n```\n", "from the fence")
        #expect(apply(indent, "te¦xt\n\n```\na\n```\nmo¦re\n") == "te¦xt\n\n```\n    a\n```\nmo¦re\n", "from text above to text below")
        #expect(apply(outdent, "¦```\n    a\n    b¦\n```\n") == "¦```\na\nb¦\n```\n")
        #expect(apply(indent, "¦text\nmore¦\n") == nil, "no code in it")
        #expect(apply(indent, "- a\n- ¦b\n\n  ```\n  c¦\n  ```\n") == "- a\n  - ¦b\n\n    ```\n    c¦\n    ```\n", "in a list the item moves with its code")
    }

    @Test func linesPastedIntoCodeInAListOrQuoteStayInIt() {
        func paste(_ pasted: String, _ marked: String) -> String? { apply({ InputRules.paste(pasted, in: $0, map: $1, selection: $2) }, marked) }
        let block = "- a\n  ```py\n  def f():\n      ¦\n  ```"
        let result = paste("if a:\n        b = [\n    1]\n}", block)
        #expect(result == "- a\n  ```py\n  def f():\n      if a:\n          b = [\n      1]\n  }¦\n  ```")
        let map = MarkdownStyler.style(result!.replacingOccurrences(of: "¦", with: ""))
        #expect(map.lines.allSatisfy { $0.listDepth == 1 } && map.lines.last?.kind == .codeFence(language: nil, isClosing: true))
        #expect(paste("x\r\ny\n", "> ```\n> ¦\n> ```\n") == "> ```\n> x\r\n> y\n> ¦\n> ```\n")
        #expect(paste("x\ny", "text\n\n    a¦b\n") == "text\n\n    ax\n    y¦b\n", "indented code")
        #expect(paste("x\ny", "- ```\n  a¦bc¦d\n  ```\n") == "- ```\n  ax\n  y¦d\n  ```\n", "in place of a selection")
        #expect(paste("x\ny", "```\n¦\n```\n") == nil, "nothing to add")
        #expect(paste("xy", "- ```\n  ¦\n  ```\n") == nil, "one line")
        #expect(paste("x\ny", "- a¦\n") == nil, "not code")
    }

    @Test func shiftTabInCodeTakesOneUnitFromEveryLine() {
        #expect(apply(outdent, "```\n    x¦\n```\n") == "```\nx¦\n```\n")
        #expect(apply(outdent, "```\n    a\n        ¦x\n```\n") == "```\n    a\n    ¦x\n```\n")
        #expect(apply(outdent, "```\n  a\n   ¦ b\n```\n") == "```\n  a\n ¦ b\n```\n", "the caret keeps its text")
        #expect(apply(outdent, "```\n    a\n  b¦\n```\n") == "```\n    a\nb¦\n```\n", "less than a unit goes whole")
        #expect(apply(outdent, "```\n\t\tx¦\n```\n") == "```\n\tx¦\n```\n")
        #expect(apply(outdent, "```\n¦    a\n        b\nc\n    d¦\n```\n") == "```\n¦a\n    b\nc\nd¦\n```\n")
        #expect(apply(outdent, "```\nx¦\n```\n") == "```\nx¦\n```\n", "nothing to take, and nothing else happens")
    }

    @Test func backspaceInLeadingBlanksTakesOneUnit() {
        #expect(apply(backspace, "```\n    a\n        ¦b\n```\n") == "```\n    a\n    ¦b\n```\n")
        #expect(apply(backspace, "```\n    a\n      ¦b\n```\n") == "```\n    a\n    ¦b\n```\n", "back to a whole level")
        #expect(apply(backspace, "```\n    a\n    ¦    b\n```\n") == "```\n    a\n¦    b\n```\n")
        #expect(apply(backspace, "```\n  a\n    ¦\n```\n") == "```\n  a\n  ¦\n```\n")
        #expect(apply(backspace, "```\n\ta\n\t\t¦b\n```\n") == "```\n\ta\n\t¦b\n```\n")
        #expect(apply(backspace, "text\n\n    a\n        ¦b\n") == "text\n\n    a\n    ¦b\n", "indented code")
        #expect(apply(backspace, "```\n    a ¦b\n```\n") == nil, "behind text it is the plain key")
        #expect(apply(backspace, "```\n¦a\n```\n") == nil)
        #expect(apply(backspace, "text\n  ¦more\n") == nil, "not code")
    }

    @Test func aClosingBracketOnALineOfBlanksStandsOneLevelOut() {
        #expect(apply(closing("}"), "```js\nif (a) {\n    b()\n    ¦\n```\n") == "```js\nif (a) {\n    b()\n}¦\n```\n")
        #expect(apply(closing("]"), "```\nx = [\n  1,\n    ¦\n```\n") == "```\nx = [\n  1,\n  ]¦\n```\n")
        #expect(apply(closing(")"), "```go\nf(\n\ta,\n\t¦\n```\n") == "```go\nf(\n\ta,\n)¦\n```\n")
        #expect(apply(closing("}"), "- ```\n  a {\n      ¦\n  ```\n") == "- ```\n  a {\n  }¦\n  ```\n")
        #expect(apply(closing("}"), "```\n    x ¦\n```\n") == nil, "text before it")
        #expect(apply(closing("}"), "```\n    ¦x\n```\n") == nil, "text behind it")
        #expect(apply(closing("}"), "```\n¦\n```\n") == nil, "nothing to take")
        #expect(apply(closing(">"), "```\n    ¦\n```\n") == nil)
        #expect(apply(closing("}"), "    ¦\n") == nil, "not code")
        #expect(apply(closing("}"), "```\n   ¦ \n```\n") == "```\n}¦ \n```\n")
    }

    // MARK: stale maps

    @Test func aMapThatDoesNotMatchTheTextGivesNoEdit() {
        let stale = MarkdownStyler.style("- item\n")
        let text = "x- item\n- two\n"
        for rule in [newline, backspace, delete, indent, outdent, closing("}")] {
            #expect(rule(text, stale, NSRange(location: 3, length: 0)) == nil)
            #expect(rule(text, stale, NSRange(location: 12, length: 0)) == nil)
        }
        #expect(newline("", StyleMap(), NSRange(location: 0, length: 0)) == nil)
        // The caret's line matches, the lines after it are past the end of the text.
        #expect(newline("```\n", MarkdownStyler.style("```\nbody\n```\nmore text here\n"), NSRange(location: 3, length: 0)) == nil)
    }

    @Test func returnReplacesASelection() {
        let text = "- one two\n"
        let edit = InputRules.newline(in: text, map: MarkdownStyler.style(text), selection: NSRange(location: 5, length: 4))
        #expect(edit == TextEdit(range: NSRange(location: 5, length: 4), replacement: "\n- ", selection: NSRange(location: 8, length: 0)))
    }
}
