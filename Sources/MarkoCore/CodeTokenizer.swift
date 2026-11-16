import Foundation

public struct CodeToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case comment, string, number, keyword
    }

    public var range: NSRange
    public var kind: Kind
}

/// A generic highlighter: comments, strings, numbers and keywords found with one regular expression
/// per language. It knows no grammar, so it is cheap and wrong in the usual regex-highlighter ways.
enum CodeTokenizer {
    /// Tokens of `code` in order, in UTF-16 offsets. An unknown language has none.
    static func tokens(in code: String, language: String) -> [CodeToken] {
        guard let grammar = grammars[language.lowercased()] else { return [] }
        let text = code as NSString
        var tokens: [CodeToken] = []
        grammar.regex.enumerateMatches(in: code, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            let kinds: [CodeToken.Kind] = [.comment, .string, .number]
            if let group = (1...3).first(where: { match.range(at: $0).location != NSNotFound }) {
                tokens.append(CodeToken(range: match.range, kind: kinds[group - 1]))
            } else {
                let word = text.substring(with: match.range)
                if grammar.keywords.contains(grammar.ignoresCase ? word.lowercased() : word) {
                    tokens.append(CodeToken(range: match.range, kind: .keyword))
                }
            }
        }
        return tokens
    }

    private struct Grammar: Sendable {
        let regex: NSRegularExpression
        let keywords: Set<String>
        let ignoresCase: Bool

        /// Groups 1 to 3 are comment, string and number; any other match is an identifier.
        init(comments: [String], strings: [String], keywords: String, ignoresCase: Bool = false) {
            func group(_ alternatives: [String]) -> String {
                "(" + (alternatives.isEmpty ? "(?!)" : alternatives.joined(separator: "|")) + ")"
            }
            let number = #"(\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)"#
            regex = try! NSRegularExpression(pattern: [group(comments), group(strings), number, #"[A-Za-z_][A-Za-z0-9_]*"#].joined(separator: "|"))
            self.keywords = Set(keywords.split(separator: " ").map(String.init))
            self.ignoresCase = ignoresCase
        }
    }

    private static let slashComments = [#"//[^\n]*"#, #"/\*[\s\S]*?(?:\*/|\z)"#]
    private static let hashComments = [#"#[^\n]*"#]
    private static let double = #""(?:\\.|[^"\\\n])*""#
    private static let single = #"'(?:\\.|[^'\\\n])*'"#
    private static let backtick = #"`[^`]*`"#
    private static let tripleDouble = #""{3}[\s\S]*?(?:"{3}|\z)"#
    private static let tripleSingle = #"'{3}[\s\S]*?(?:'{3}|\z)"#

    private static let grammars: [String: Grammar] = {
        let cLike = "auto break case char const continue default do double else enum extern float for goto if inline int long register return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL"
        let javaScript = "async await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while with yield"
        let table: [(names: String, grammar: Grammar)] = [
            ("swift", Grammar(comments: slashComments, strings: [tripleDouble, double], keywords: "actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in indirect init inout internal is lazy let mutating nil nonisolated nonmutating open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak unowned where while")),
            ("c h", Grammar(comments: slashComments, strings: [double, single], keywords: cLike)),
            ("cpp c++ cc hpp objc", Grammar(comments: slashComments, strings: [double, single], keywords: cLike + " alignas alignof and bitand bitor catch class concept constexpr consteval constinit co_await co_return co_yield decltype delete explicit export friend mutable namespace new noexcept not nullptr operator or override private protected public requires template this throw try typeid typename using virtual xor final")),
            ("java kotlin kt csharp cs c#", Grammar(comments: slashComments, strings: [tripleDouble, double, single], keywords: "abstract as async await base boolean break byte case catch char class companion const continue data default do double else enum extends false final finally float for foreach fun get if implements import in instanceof int interface internal is long namespace native new null object out override package private protected public readonly return sealed set short static string super switch synchronized this throw throws true try using val var virtual void volatile when while")),
            ("javascript js jsx mjs", Grammar(comments: slashComments, strings: [double, single, backtick], keywords: javaScript)),
            ("typescript ts tsx", Grammar(comments: slashComments, strings: [double, single, backtick], keywords: javaScript + " abstract any as boolean declare enum implements interface is keyof namespace never number private protected public readonly string type unknown")),
            ("go golang", Grammar(comments: slashComments, strings: [double, single, backtick], keywords: "break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var")),
            ("rust rs", Grammar(comments: slashComments, strings: [double], keywords: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while")),
            ("python py", Grammar(comments: hashComments, strings: [tripleDouble, tripleSingle, double, single], keywords: "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield")),
            ("ruby rb", Grammar(comments: hashComments, strings: [double, single], keywords: "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield")),
            ("bash sh shell zsh", Grammar(comments: hashComments, strings: [double, single], keywords: "if then else elif fi for while until do done case esac in function return break continue local export readonly declare unset exit")),
            ("yaml yml toml", Grammar(comments: hashComments, strings: [double, single], keywords: "true false null yes no on off")),
            ("json", Grammar(comments: [], strings: [double], keywords: "true false null")),
            ("sql", Grammar(comments: [#"--[^\n]*"#, slashComments[1]], strings: [single, double], keywords: "add all alter and as asc begin between by case check column commit constraint create cross database default delete desc distinct drop else end exists false foreign from full group having if in index inner insert into is join key left like limit not null offset on or order outer primary references right rollback select set table then true union unique update values view when where with", ignoresCase: true)),
        ]
        var grammars: [String: Grammar] = [:]
        for entry in table {
            for name in entry.names.split(separator: " ") { grammars[String(name)] = entry.grammar }
        }
        return grammars
    }()
}
