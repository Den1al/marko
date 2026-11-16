// Drives ONE Marko instance, by pid, the way a person would: Quartz mouse, wheel and key events
// sent to that process alone (CGEvent.postToPid, never the global event tap, so the pointer and
// the other apps are left alone), and reads back what is on screen through the accessibility
// tree, the window list and screencapture. See docs/development.md, "A normal launch,
// driven", for starting an instance that is safe to drive.
//
//   swiftc -O -o build/drive/drive scripts/drive/drive.swift   (scripts/drive/launch.sh does it)
//   build/drive/drive <pid> < commands          (one command a line, "#" starts a comment)
//   build/drive/drive watch <pid> <log>         (until the process ends: every window of it that
//                                                is not on the built-in display, 50 times a second)
//
// Points are screen points from the top left of the main display. Commands:
//   sleep <s> | idle <s> (wait until nobody touched keyboard or mouse for s) | wins | cap <png> [window title part]
//   front | hide | show (the instance never comes to the front by itself, see pin.m: `front` for what needs it,
//                        clicks and commands that act on a window, after `idle`, and `hide` straight after; `show` for a picture)
//   click <x> <y> [count] [mods] | rclick <x> <y> | move <x> <y> | drag <x1> <y1> <x2> <y2> [mods] [hold s] | wheel <x> <y> <dy> <times>
//   glide <x> <y> <dy> <times> (wheel steps one by one: by how many points a character in the window moved at each) | visible
//   key <code> [mods] | hold <code> <seconds> | type <text, \n \t \\ escaped> | mods are cmd,shift,opt,ctrl joined by "+"
//   text | sel | rect <loc> <len> | at <loc> [count] [mods] [dx] [dy] (click where character loc stands)
//   rat <loc> (right click there)
//   sweep <loc1> <loc2> [mods] [hold s] (drag from character to character)
//   find <role> [text] (frames of the elements) | hit <role> <text> [count] [mods] [right] (click its middle)
//   press|confirm|showmenu <role> [text] (the accessibility action, where no event can reach) | set <role> <value> | choose <row text>
//   ax [depth] [role to start from] | attrs <role> | focus | menu (the items of the menu that is open) | scrolled
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let builtIn: CGRect? = {
    var count: UInt32 = 0
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetActiveDisplayList(16, &displays, &count)
    return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }.map(CGDisplayBounds)
}()

struct Window { let id: Int, layer: Int, bounds: CGRect, name: String, alpha: Double }
func windows(of pid: pid_t) -> [Window] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid }.map {
        Window(id: $0[kCGWindowNumber as String] as? Int ?? 0, layer: $0[kCGWindowLayer as String] as? Int ?? 0,
               bounds: CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary) ?? .zero,
               name: $0[kCGWindowName as String] as? String ?? "", alpha: $0[kCGWindowAlpha as String] as? Double ?? 1)
    }
}
func isOnBuiltIn(_ window: Window) -> Bool {
    builtIn.map { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: window.bounds.minX + 2, y: window.bounds.minY + 2)) } ?? false
}

if arguments.count == 4, arguments[1] == "watch", let pid = pid_t(arguments[2]) {
    guard builtIn != nil else { fail("no built-in display") }
    var seen = 0, off = Set<String>()
    while kill(pid, 0) == 0 {
        for window in windows(of: pid) {
            seen += 1
            if !isOnBuiltIn(window) { off.insert("\"\(window.name)\" layer=\(window.layer) alpha=\(window.alpha) \(window.bounds)") }
        }
        usleep(20_000)
    }
    try? "positions=\(seen) offBuiltIn=\(off.count) \(off.sorted().joined(separator: "; "))\n".write(toFile: arguments[3], atomically: true, encoding: .utf8)
    exit(0)
}

guard arguments.count == 2, let pid = pid_t(arguments[1]), kill(pid, 0) == 0 else { fail("usage: drive <pid> < commands") }
guard builtIn != nil else { fail("no built-in display: nothing is shown") }
guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { fail("no permission to post events or read the accessibility tree") }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)

// MARK: accessibility

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func frame(_ element: AXUIElement) -> CGRect {
    var origin = CGPoint.zero, size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
    if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    return CGRect(origin: origin, size: size)
}
func short(_ rect: CGRect) -> String { "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))" }
func escaped(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") }
func describe(_ element: AXUIElement) -> String {
    var line = string(element, kAXRoleAttribute)
    let subrole = string(element, kAXSubroleAttribute)
    if !subrole.isEmpty { line += "/\(subrole)" }
    for (label, name) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute)] {
        let text = string(element, name)
        if !text.isEmpty { line += " \(label)=\"\(escaped(text))\"" }
    }
    if let value = attribute(element, kAXValueAttribute) {
        let text = "\(value)"
        line += " value=\"\(escaped(String(text.prefix(60))))\(text.count > 60 ? "…(\(text.count))" : "")\""
    }
    if let enabled = attribute(element, kAXEnabledAttribute) as? Bool, !enabled { line += " disabled" }
    if let mark = attribute(element, "AXMenuItemMarkChar") as? String, !mark.isEmpty { line += " mark=\(mark)" }
    return line + " " + short(frame(element))
}
/// Never into the Apple menu: its items are the system's and act outside the process ("About
/// This Mac", Recent Items, which open other apps), though they hang in this process's tree.
func walk(_ element: AXUIElement, depth: Int = 0, limit: Int = 40, _ visit: (AXUIElement, Int) -> Bool) {
    if string(element, kAXRoleAttribute) == "AXMenuBarItem", string(element, kAXTitleAttribute) == "Apple" { return }
    guard visit(element, depth), depth < limit else { return }
    for child in children(element) { walk(child, depth: depth + 1, limit: limit, visit) }
}
func matches(_ element: AXUIElement, _ role: String, _ text: String?) -> Bool {
    guard string(element, kAXRoleAttribute) == role || string(element, kAXSubroleAttribute) == role else { return false }
    guard let text else { return true }
    let own = [kAXTitleAttribute, kAXDescriptionAttribute].map { string(element, $0) } + [(attribute(element, kAXValueAttribute)).map { "\($0)" } ?? ""]
    return own.contains { $0 == text } || own.contains { $0.contains(text) } && role != "AXMenuItem" || children(element).contains { string($0, kAXRoleAttribute) == "AXStaticText" && "\(attribute($0, kAXValueAttribute) ?? "" as CFString)".contains(text) }
        || children(element).contains { c in children(c).contains { "\(attribute($0, kAXValueAttribute) ?? "" as CFString)".contains(text) } }
}
func all(_ role: String, _ text: String? = nil) -> [AXUIElement] {
    var found: [AXUIElement] = []
    walk(app) { element, _ in
        if matches(element, role, text) { found.append(element) }
        return true
    }
    return found
}
/// The text of the frontmost window, else of any.
func textArea() -> AXUIElement? {
    for root in [attribute(app, kAXFocusedWindowAttribute), attribute(app, kAXMainWindowAttribute), app as CFTypeRef].compactMap({ $0 }) {
        var found: AXUIElement?
        walk(root as! AXUIElement) { element, _ in
            if found == nil, string(element, kAXRoleAttribute) == "AXTextArea" { found = element }
            return found == nil
        }
        if let found { return found }
    }
    return nil
}
func rect(_ area: AXUIElement, _ location: Int, _ length: Int) -> CGRect? {
    var range = CFRange(location: location, length: length), value: CFTypeRef?, rect = CGRect.zero
    guard let parameter = AXValueCreate(.cfRange, &range),
          AXUIElementCopyParameterizedAttributeValue(area, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
          let value else { return nil }
    AXValueGetValue(value as! AXValue, .cgRect, &rect)
    return rect
}
func selection(_ area: AXUIElement) -> CFRange {
    var range = CFRange()
    if let value = attribute(area, kAXSelectedTextRangeAttribute) { AXValueGetValue(value as! AXValue, .cfRange, &range) }
    return range
}

// MARK: events

func flags(_ names: String?) -> CGEventFlags {
    var flags = CGEventFlags()
    for name in (names ?? "").split(separator: "+") {
        switch name {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: break
        }
    }
    return flags
}
/// MEASURED: an event sent to a process has no window, and AppKit drops a click without one. The
/// window's number is in fields 51, 91 and 92, and the place inside it (from its top left) is set
/// by this function of CoreGraphics, which is not in its headers.
let setWindowLocation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation").map {
    unsafeBitCast($0, to: (@convention(c) (CGEvent, CGPoint) -> Void).self)
}
func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }
/// Names the window the event is for: the process's frontmost one under the point (the window list is front to back).
/// While the button is down that is the window it went down in, also beyond its edges.
var held: Window?
func aim(_ event: CGEvent, at point: CGPoint) {
    guard let window = held ?? windows(of: pid).first(where: { $0.bounds.contains(point) }) else { return }
    for field in [51, 91, 92] as [UInt32] { event.setIntegerValueField(CGEventField(rawValue: field)!, value: Int64(window.id)) }
    setWindowLocation?(event, CGPoint(x: point.x - window.bounds.minX, y: point.y - window.bounds.minY))
}
func wheel(_ point: CGPoint, _ delta: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.location = point
    aim(event, at: point)
    event.postToPid(pid)
}
func visibleRange(_ area: AXUIElement) -> CFRange {
    var range = CFRange()
    if let value = attribute(area, kAXVisibleCharacterRangeAttribute) { AXValueGetValue(value as! AXValue, .cfRange, &range) }
    return range
}
func mouse(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton = .left, clicks: Int = 1, _ modifiers: CGEventFlags = []) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
    event.flags = modifiers
    aim(event, at: point)
    event.postToPid(pid)
}
func click(_ point: CGPoint, count: Int = 1, _ modifiers: CGEventFlags = [], right: Bool = false) {
    for number in 1...count {
        mouse(right ? .rightMouseDown : .leftMouseDown, point, button: right ? .right : .left, clicks: number, modifiers)
        pause(0.04)
        mouse(right ? .rightMouseUp : .leftMouseUp, point, button: right ? .right : .left, clicks: number, modifiers)
        pause(0.06)
    }
}
func drag(_ from: CGPoint, _ to: CGPoint, _ modifiers: CGEventFlags = [], hold: Double = 0) {
    mouse(.leftMouseDown, from, modifiers)
    held = windows(of: pid).first { $0.bounds.contains(from) }
    defer { held = nil }
    pause(0.15)
    for step in 1...12 {
        let part = CGFloat(step) / 12
        mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * part, y: from.y + (to.y - from.y) * part), modifiers)
        pause(0.03)
    }
    // Held at the far end, as when waiting for the view to scroll under the pointer.
    for _ in 0..<Int(hold / 0.05) {
        mouse(.leftMouseDragged, to, modifiers)
        pause(0.05)
    }
    mouse(.leftMouseUp, to, modifiers)
}
func key(_ code: Int, _ modifiers: CGEventFlags = [], characters: String? = nil) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        event.flags = modifiers
        if let characters { event.keyboardSetUnicodeString(stringLength: characters.utf16.count, unicodeString: Array(characters.utf16)) }
        event.postToPid(pid)
        pause(0.012)
    }
}

// MARK: commands

func number(_ words: [Substring], _ index: Int) -> Double? { words.indices.contains(index) ? Double(words[index]) : nil }
while let line = readLine() {
    let words = line.split(separator: " ", omittingEmptySubsequences: true)
    guard let command = words.first, !command.hasPrefix("#") else { continue }
    func value(_ index: Int) -> Double {
        guard let value = number(words, index) else { fail("\(line): argument \(index) is missing") }
        return value
    }
    func point(_ index: Int) -> CGPoint { CGPoint(x: value(index), y: value(index + 1)) }
    func word(_ index: Int) -> String? { words.indices.contains(index) ? String(words[index]) : nil }
    func area() -> AXUIElement {
        guard let area = textArea() else { fail("\(line): no text area") }
        return area
    }
    func place(_ location: Int) -> CGPoint {
        guard let rect = rect(area(), location, 1) ?? rect(area(), location, 0) else { fail("\(line): no place for \(location)") }
        return CGPoint(x: rect.minX, y: rect.midY)
    }
    switch command {
    case "sleep": pause(value(1))
    case "idle":
        var waited = 0.0
        while CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) < value(1) {
            pause(0.5)
            waited += 0.5
            if waited > 600 { fail("idle: the user was at the Mac for ten minutes") }
        }
    case "front":
        print("front: asked=\(AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success)")
    case "hide", "show":
        // Hiding is how the front goes back to the app the user was in; shown again, the instance is not in front.
        print("\(command): asked=\(AXUIElementSetAttributeValue(app, kAXHiddenAttribute as CFString, command == "hide" ? kCFBooleanTrue : kCFBooleanFalse) == .success)")
    case "wins":
        // Asked of the instance: what NSWorkspace says is what it was when this process first asked.
        let front = attribute(app, kAXFrontmostAttribute) as? Bool ?? false
        print("wins: frontmost=\(front) " + windows(of: pid).map { "#\($0.id) layer=\($0.layer) \"\($0.name)\" \(short($0.bounds)) builtIn=\(isOnBuiltIn($0))" }.joined(separator: " | "))
    case "cap":
        let part = word(2)
        guard let window = windows(of: pid).first(where: { part == nil ? $0.layer == 0 : $0.name.contains(part!) }) ?? windows(of: pid).first else { print("cap: no window"); continue }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.id), String(words[1])]
        try? capture.run()
        capture.waitUntilExit()
        print("cap: \(words[1]) window #\(window.id) status=\(capture.terminationStatus)")
    case "click": click(point(1), count: Int(number(words, 3) ?? 1), flags(word(4)))
    case "move": mouse(.mouseMoved, point(1))
    case "rclick": click(point(1), right: true)
    case "drag": drag(point(1), point(3), flags(word(5)), hold: number(words, 6) ?? 0)
    case "wheel":
        for _ in 0..<Int(value(4)) {
            wheel(point(1), Int32(value(3)))
            pause(0.016)
        }
    case "glide":
        // One wheel step at a time; how far a character in the middle of the window moved each time.
        var moves: [Int: Int] = [:]
        for _ in 0..<Int(value(4)) {
            let visible = visibleRange(area()), tracked = visible.location + visible.length / 2
            guard let before = rect(area(), tracked, 1) else { continue }
            wheel(point(1), Int32(value(3)))
            pause(0.03)
            guard let after = rect(area(), tracked, 1) else { continue }
            moves[Int((after.minY - before.minY).rounded()), default: 0] += 1
        }
        let visible = visibleRange(area())
        print("glide: moves(points: steps)=\(moves.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")) visible=\(visible.location),\(visible.length)")
    case "visible":
        let visible = visibleRange(area())
        print("visible: \(visible.location),\(visible.length)")
    case "key": key(Int(value(1)), flags(word(2)))
    case "hold":
        // A key held down: the first key-down, then repeats as the keyboard sends them, then up.
        for (index, down) in ([true] + Array(repeating: true, count: Int(value(2) / 0.08)) + [false]).enumerated() {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(value(1)), keyDown: down) else { break }
            if down, index > 0 { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event.postToPid(pid)
            pause(index == 0 ? 0.5 : 0.08)
        }
    case "type":
        let text = line.drop { $0 == " " }.dropFirst(5)
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            var typed = character
            if character == "\\", let next = characters.popFirst() { typed = next == "n" ? "\n" : next == "t" ? "\t" : next }
            if typed == "\n" { key(36) } else if typed == "\t" { key(48) } else { key(0, characters: String(typed)) }
        }
    case "text": print("text: \"\(escaped(string(area(), kAXValueAttribute)))\"")
    case "sel":
        let range = selection(area())
        print("sel: \(range.location),\(range.length) \"\(escaped(String(string(area(), kAXSelectedTextAttribute).prefix(200))))\"")
    case "rect": print("rect: \(rect(area(), Int(value(1)), Int(value(2))).map(short) ?? "none")")
    case "at":
        let at = place(Int(value(1)))
        click(CGPoint(x: at.x + (number(words, 4) ?? 0), y: at.y + (number(words, 5) ?? 0)), count: Int(number(words, 2) ?? 1), flags(word(3)))
    case "rat": click(place(Int(value(1))), right: true)
    case "sweep": drag(place(Int(value(1))), place(Int(value(2))), flags(word(3)), hold: number(words, 4) ?? 0)
    case "find":
        let found = all(String(words[1]), words.count > 2 ? words[2...].joined(separator: " ") : nil)
        print("find: \(found.count)" + found.prefix(40).map { "\n  " + describe($0) }.joined())
    case "hit":
        guard let element = all(String(words[1]), word(2)).first else { print("hit: no \(words[1]) \(word(2) ?? "")"); continue }
        let box = frame(element)
        click(CGPoint(x: box.midX, y: box.midY), count: Int(number(words, 3) ?? 1), flags(word(4)), right: word(5) == "right")
        print("hit: \(describe(element))")
    case "press", "confirm", "showmenu":
        // For what events sent to the process cannot reach (the system's Open and Save panels are drawn by another process).
        guard let element = all(String(words[1]), words.count > 2 ? words[2...].joined(separator: " ") : nil).first else { print("\(command): no \(words[1])"); continue }
        let action = command == "press" ? kAXPressAction : command == "confirm" ? kAXConfirmAction : kAXShowMenuAction
        print("\(command): \(AXUIElementPerformAction(element, action as CFString) == .success) \(describe(element))")
    case "choose":
        // Selects a row, as a click on it would.
        guard let row = all("AXRow", words[1...].joined(separator: " ")).first else { print("choose: no row"); continue }
        print("choose: \(AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success)")
    case "set":
        guard let element = all(String(words[1])).first else { print("set: no \(words[1])"); continue }
        print("set: \(AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, words[2...].joined(separator: " ") as CFString) == .success)")
    case "ax":
        let limit = Int(number(words, 1) ?? 6)
        for root in word(2).map({ all($0) }) ?? [app] {
            walk(root, limit: limit) { element, depth in
                print(String(repeating: "  ", count: depth) + describe(element))
                return true
            }
        }
    case "attrs":
        guard let element = all(String(words[1])).first else { print("attrs: no \(words[1])"); continue }
        var names: CFArray?, parameterized: CFArray?, actions: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        AXUIElementCopyParameterizedAttributeNames(element, &parameterized)
        AXUIElementCopyActionNames(element, &actions)
        print("attrs: \((names as? [String] ?? []).joined(separator: " "))\nparameterized: \((parameterized as? [String] ?? []).joined(separator: " "))\nactions: \((actions as? [String] ?? []).joined(separator: " "))")
        for name in ["AXRoleDescription", "AXNumberOfCharacters", "AXInsertionPointLineNumber", "AXPlaceholderValue", "AXFocused"] {
            print("  \(name)=\(attribute(element, name).map { "\($0)" } ?? "none")")
        }
    case "focus":
        print("focus: " + ((attribute(app, kAXFocusedUIElementAttribute)).map { describe($0 as! AXUIElement) } ?? "none"))
    case "menu":
        // The menus that are open outside the menu bar, with the items that are on screen.
        walk(app) { element, depth in
            let role = string(element, kAXRoleAttribute)
            if role == "AXMenuItem", frame(element).height > 0 { print("menu: " + describe(element)) }
            return role != "AXMenuBar"
        }
    case "scrolled":
        let bars = all("AXScrollBar").map { "\(attribute($0, kAXValueAttribute) ?? "?" as CFString)" }
        print("scrolled: \(bars.joined(separator: ","))")
    default: fail("unknown command: \(line)")
    }
}
