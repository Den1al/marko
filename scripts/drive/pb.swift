// Keeps a pasteboard of the user's as it is across a driven check that writes it (Copy Path
// writes the clipboard, the find bar the find pasteboard): every item with every type's data.
//
//   swiftc -O -o build/drive/pb scripts/drive/pb.swift
//   build/drive/pb save general|find <file>      (prints the change count and the items)
//   build/drive/pb restore general|find <file>   (then reads back and says whether it is the same)
//   build/drive/pb string general|find           (the plain string on it now, and the change count:
//                                                 one more than at `save` when only the check wrote it)
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3, ["general", "find"].contains(arguments[2]) else {
    FileHandle.standardError.write("usage: pb save|restore|string general|find [file]\n".data(using: .utf8)!)
    exit(2)
}
let board = arguments[2] == "find" ? NSPasteboard(name: .find) : NSPasteboard.general
/// Every item as its types and their data, in the items' order.
func contents() -> [[String: Data]] {
    (board.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
    }
}
switch arguments[1] {
case "save":
    let items = contents()
    try! PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0).write(to: URL(fileURLWithPath: arguments[3]))
    print("pb: saved \(items.count) items, \(items.map(\.count)) types, change count \(board.changeCount)")
case "restore":
    let saved = try! PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[3])), format: nil) as! [[String: Data]]
    board.clearContents()
    let written = board.writeObjects(saved.map { types in
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        return item
    })
    print("pb: restored \(saved.count) items written=\(written || saved.isEmpty) same=\(contents() == saved)")
default:
    print("pb: \(board.string(forType: .string).map { "\"\($0)\"" } ?? "no string"), change count \(board.changeCount)")
}
