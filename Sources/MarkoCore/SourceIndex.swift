import Foundation

/// Line table over the UTF-16 view of a source string. Lines end at LF, CRLF or a lone CR, which is
/// how cmark numbers them; a trailing terminator does not open another line.
struct SourceIndex: Sendable {
    let utf16: [UInt16]
    private var starts: [Int] = []
    private var contentEnds: [Int] = []
    private var isASCII: [Bool] = []

    init(_ source: String) {
        utf16 = Array(source.utf16)
        var i = 0, start = 0, ascii = true
        while i < utf16.count {
            let unit = utf16[i]
            if unit == 0x0A || unit == 0x0D {
                starts.append(start)
                contentEnds.append(i)
                isASCII.append(ascii)
                i += unit == 0x0D && i + 1 < utf16.count && utf16[i + 1] == 0x0A ? 2 : 1
                start = i
                ascii = true
            } else {
                // cmark turns NUL into U+FFFD, so it is not one byte wide either.
                if unit >= 0x80 || unit == 0 { ascii = false }
                i += 1
            }
        }
        if start < utf16.count {
            starts.append(start)
            contentEnds.append(utf16.count)
            isASCII.append(ascii)
        }
    }

    var lineCount: Int { starts.count }

    /// The line including its terminator. `line` is 0-based.
    func lineRange(_ line: Int) -> NSRange {
        let end = line + 1 < starts.count ? starts[line + 1] : utf16.count
        return NSRange(location: starts[line], length: end - starts[line])
    }

    /// The line without its terminator. `line` is 0-based.
    func contentRange(_ line: Int) -> NSRange {
        NSRange(location: starts[line], length: contentEnds[line] - starts[line])
    }

    /// UTF-8 length of the line without its terminator, the unit cmark counts columns in. `line` is 0-based.
    func utf8Length(_ line: Int) -> Int {
        let start = starts[line], end = contentEnds[line]
        if isASCII[line] { return end - start }
        var bytes = 0, i = start
        while i < end { (bytes, i) = advance(bytes, i, end) }
        return bytes
    }

    /// Converts a cmark position (1-based line, 1-based UTF-8 column) to a UTF-16 offset.
    /// Returns nil when the position is outside the line or falls inside a scalar.
    func offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= starts.count, column >= 1 else { return nil }
        let start = starts[line - 1], end = contentEnds[line - 1]
        if isASCII[line - 1] {
            return start + column - 1 <= end ? start + column - 1 : nil
        }
        var bytes = 0, i = start
        while bytes < column - 1, i < end { (bytes, i) = advance(bytes, i, end) }
        return bytes == column - 1 ? i : nil
    }

    /// Steps over the scalar at `i`, adding its UTF-8 length to `bytes`.
    private func advance(_ bytes: Int, _ i: Int, _ end: Int) -> (bytes: Int, i: Int) {
        let unit = utf16[i]
        if unit >= 0xD800, unit < 0xDC00, i + 1 < end, utf16[i + 1] >= 0xDC00, utf16[i + 1] < 0xE000 {
            return (bytes + 4, i + 2)
        }
        return (bytes + (unit == 0 ? 3 : unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3), i + 1)
    }

    /// 0-based index of the line whose range (terminator included) contains `offset`.
    func lineIndex(containing offset: Int) -> Int? {
        guard offset >= 0, offset < utf16.count else { return nil }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
