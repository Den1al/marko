// A window that takes drops the way a terminal does, to see what a row dragged out of Marko's
// file tree offers another app: it logs the operations the drag's source allows, the types on
// the drag's pasteboard and what it reads from them. On the built-in display only; it ends by itself.
//
//   swiftc -O -o build/drive/drop scripts/drive/drop.swift
//   build/drive/drop <x> <y> <seconds> [copy|generic|link]   (the window's top left corner, in points from
//                                                             the built-in display's; the one operation
//                                                             it accepts, as terminals differ in that;
//                                                             without it the first of copy, generic, link
//                                                             that is offered)
import AppKit

let fileNames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
func say(_ line: String) {
    print("drop: " + line)
    fflush(stdout)
}
func names(_ mask: NSDragOperation) -> String {
    let all: [(NSDragOperation, String)] = [(.copy, "copy"), (.link, "link"), (.generic, "generic"), (.private, "private"), (.move, "move"), (.delete, "delete")]
    return mask == .every ? "every" : all.filter { mask.contains($0.0) }.map(\.1).joined(separator: "+") + " (\(mask.rawValue))"
}

final class Target: NSView {
    var wanted: NSDragOperation?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSAttributedString(string: "Marko drop test (closes by itself)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            .draw(at: NSPoint(x: 12, y: bounds.midY - 8))
    }

    private func answer(_ info: NSDraggingInfo) -> NSDragOperation {
        let offered = info.draggingSourceOperationMask
        if let wanted { return offered.contains(wanted) ? wanted : [] }
        return [.copy, .generic, .link].first { offered.contains($0) } ?? []
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        say("entered offered=\(names(info.draggingSourceOperationMask)) answer=\(names(answer(info))) types=\((info.draggingPasteboard.types ?? []).map(\.rawValue))")
        return answer(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { answer(info) }
    override func draggingExited(_ info: NSDraggingInfo?) { say("exited") }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let board = info.draggingPasteboard
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).map(\.path)
        say("performed offered=\(names(info.draggingSourceOperationMask)) urls=\(urls) fileNames=\(board.propertyList(forType: fileNames) as? [String] ?? []) string=\(board.string(forType: .string) ?? "none")")
        return true
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 4, let x = Double(arguments[1]), let y = Double(arguments[2]), let life = Double(arguments[3]),
      let display = NSScreen.screens.first(where: { screen in
          (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } == true
      })?.frame else {
    FileHandle.standardError.write("usage: drop <x> <y> <seconds> [copy|generic|link]; needs the built-in display\n".data(using: .utf8)!)
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Marko drop test"
window.level = .floating
let target = Target(frame: window.contentView!.bounds)
target.wanted = arguments.count > 4 ? ["copy": NSDragOperation.copy, "generic": .generic, "link": .link][arguments[4]] : nil
// What Terminal's views register for: file names, URLs and text.
target.registerForDraggedTypes([fileNames, .fileURL, .URL, .string])
window.contentView = target
window.setFrameTopLeftPoint(NSPoint(x: display.minX + x, y: display.maxY - y))
// Never anywhere but on the built-in display: checked before the window is shown.
guard display.contains(window.frame) else {
    FileHandle.standardError.write("drop: \(window.frame) is not on the built-in display \(display)\n".data(using: .utf8)!)
    exit(1)
}
window.orderFrontRegardless()
say("window #\(window.windowNumber) frame=\(window.frame) pid=\(ProcessInfo.processInfo.processIdentifier)")
Timer.scheduledTimer(withTimeInterval: life, repeats: false) { _ in exit(0) }
app.run()
