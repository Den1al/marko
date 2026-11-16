// The floor for a launch on this machine: the least an AppKit app can do to show a text. One
// window with a TextKit 2 text view holding the file named as the argument; no menu, no document
// classes, no styling. Built by scripts/perf/perf.py with `swiftc -O` into build/perf/control
// (together with Sources/MarkoEditor/BuiltInDisplay.swift, which says where its window goes) and
// measured by `perf.py turns` exactly as Marko's launch is: the same marks, the same definition
// of the first frame (Perf.swift, `noteFrames`), the same way of starting it. What Marko's launch
// takes beyond this is Marko's; what this takes is AppKit's.
//
// With `MARKO_PERF=scroll`, `resize`, `typing` or `restyle` it goes on after its first frame and
// does what Perf.swift does for that scenario, in the same steps and with the same clock, on its
// stock text view with the file's text as plain text: the floor for a frame of scrolling, a step
// of a window resize, a key and Return, and (`restyle`) a key that moves the tab stops of every
// row in the window, which is what a key that widens a table's column asks of TextKit.
import AppKit

func epoch() -> Double {
    var time = timeval()
    gettimeofday(&time, nil)
    return Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
}

let processStart: Double = {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&name, 4, &info, &size, nil, 0)
    let time = info.kp_proc.p_starttime
    return Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
}()

func emit(_ metric: String, _ value: Double) {
    print("perf: \(metric) \(String(format: "%.3f", value))")
}

let environment = ProcessInfo.processInfo.environment
let scenario = environment["MARKO_PERF"] ?? "launch"
emit("launch.main", epoch() - processStart)
// Whatever happens, the process ends.
Thread.detachNewThread {
    sleep(environment["MARKO_PERF_TIMEOUT"].flatMap(UInt32.init) ?? 20)
    exit(3)
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

/// As `Perf.timed`: the work, layout, drawing and handing the frame over, and the four parts.
@MainActor func timed(_ window: NSWindow, _ work: () -> Void) -> [Double] {
    let start = now()
    work()
    let worked = now()
    window.layoutIfNeeded()
    let laidOut = now()
    window.displayIfNeeded()
    let drawn = now()
    CATransaction.flush()
    let end = now()
    return [end - start, worked - start, laidOut - worked, drawn - laidOut, end - drawn]
}

func emit(_ metric: String, _ values: [Double]) {
    print((["perf: \(metric)"] + values.map { String(format: "%.3f", $0) }).joined(separator: " "))
}

func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

@MainActor func press(_ characters: String, _ code: UInt16, in window: NSWindow) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        window.sendEvent(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
    }
}

/// The steps of Perf.swift's scenario of the same name, on the stock text view.
@MainActor func run(_ window: NSWindow, _ scroll: NSScrollView, _ textView: NSTextView) async {
    if environment["MARKO_PERF_ACTIVATE"] == "1" {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await pause(0.5)
    }
    window.makeFirstResponder(textView)
    let clip = scroll.contentView
    let place = (environment["MARKO_PERF_OFFSETS"] ?? "").split(separator: ",").first.flatMap { item -> (String, Int)? in
        let parts = item.split(separator: ":")
        return parts.count == 2 ? Int(parts[1]).map { (String(parts[0]), $0) } : nil
    }
    if let place {
        textView.setSelectedRange(NSRange(location: min(place.1, (textView.string as NSString).length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        await pause(0.6)
    }
    let phaseNames = ["work", "layout", "draw", "commit"]
    func report(_ name: String, _ times: [[Double]]) {
        emit(name, times.map { $0[0] })
        for (index, phase) in phaseNames.enumerated() { emit("\(name).\(phase)", times.map { $0[index + 1] }) }
    }
    switch scenario {
    case "scroll":
        var end: CGFloat { max(0, textView.frame.height - clip.bounds.height) }
        func sweep(_ name: String, frames: Int, to position: (Int) -> CGFloat) async {
            var times: [Double] = []
            for index in 1...frames {
                let y = position(index)
                if y == clip.bounds.minY { break }
                times.append(timed(window) {
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                    scroll.reflectScrolledClipView(clip)
                }[0])
                await pause((environment["MARKO_PERF_FRAME_GAP"].flatMap(Double.init) ?? 1) / 1000)
            }
            if !times.isEmpty { emit("scroll.\(name).frame", times) }
        }
        let frames = environment["MARKO_PERF_COUNT"].flatMap(Int.init) ?? 600, top = clip.bounds.minY
        await sweep("wheel", frames: frames) { min(top + CGFloat($0) * 40, end) }
        _ = timed(window) { clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top)) }
        await pause(0.3)
        await sweep("sweepDown", frames: frames / 2) { top + (end - top) * CGFloat($0) / CGFloat(frames / 2) }
        await sweep("sweepUp", frames: frames / 2) { top + (end - top) * CGFloat(frames / 2 - $0) / CGFloat(frames / 2) }
    case "resize":
        if let width = environment["MARKO_PERF_WIDTH"].flatMap(Double.init) {
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: width, height: window.frame.height), display: true)
            await pause(0.3)
        }
        let frame = window.frame
        var times: [Double] = []
        for index in 0..<(environment["MARKO_PERF_COUNT"].flatMap(Int.init) ?? 80) {
            let phase = index % 40, steps = phase < 20 ? phase + 1 : 39 - phase
            let width = frame.width - CGFloat(steps) * 20
            times.append(timed(window) { window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height), display: false) }[0])
            await pause(0.001)
        }
        emit("resize.step", times)
    case "typing", "restyle":
        let name = place?.0 ?? "top"
        var keys: [[Double]] = [], stops: CGFloat = 0
        for character in "The quick brown fox jumps over the lazy dog. " {
            keys.append(timed(window) {
                press(String(character), 0, in: window)
                guard scenario == "restyle", let layout = textView.textLayoutManager, let content = textView.textContentStorage,
                      let visible = layout.textViewportLayoutController.viewportRange, let storage = textView.textStorage else { return }
                // Every row in the window gets other tab stops, as when a column of a table has become wider.
                stops += 7
                let range = NSRange(location: content.offset(from: content.documentRange.location, to: visible.location),
                                    length: content.offset(from: visible.location, to: visible.endLocation))
                storage.addAttribute(.paragraphStyle, value: rowStyle(moved: stops), range: range)
            })
            await pause(0.03)
        }
        report("type.\(name).key", keys)
        await pause(0.6)
        var returns: [[Double]] = []
        for _ in 0..<9 {
            _ = timed(window) { press("x", 0, in: window) }
            returns.append(timed(window) { press("\r", 36, in: window) })
            await pause(0.6)
        }
        report("afterTyping.\(name).return", returns)
    default:
        break
    }
    exit(0)
}

/// A row of a table as Marko sets it: one tab stop for each column, a line as high as a row, never wrapped.
func rowStyle(moved: CGFloat = 0) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.tabStops = [10, 70, 70 + moved + 150, 70 + moved + 250, 70 + moved + 330, 70 + moved + 420].map { NSTextTab(textAlignment: .left, location: $0) }
    style.minimumLineHeight = 38
    style.maximumLineHeight = 38
    style.lineBreakMode = .byClipping
    return style
}

let path = CommandLine.arguments.last { !$0.hasPrefix("-") } ?? ""
guard CommandLine.arguments.count > 1, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: control <file>\n".utf8))
    exit(2)
}

final class Delegate: NSObject, NSApplicationDelegate {
    let text: String
    var window: NSWindow?
    var isRunning = false

    init(text: String) {
        self.text = text
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        emit("launch.willFinishLaunching", epoch() - processStart)
        // As Marko's measured launches: in the background, without a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { exit(2) }
        precondition(textView.textLayoutManager != nil, "not TextKit 2")
        textView.font = .systemFont(ofSize: 16)
        textView.string = text
        if scenario == "restyle", let storage = textView.textStorage {
            // The file's table as rows of tabbed text.
            storage.mutableString.replaceOccurrences(of: "| ", with: "\t", range: NSRange(location: 0, length: storage.length))
            storage.addAttribute(.paragraphStyle, value: rowStyle(), range: NSRange(location: 0, length: storage.length))
        }
        window.contentView = scroll
        window.moveToBuiltInDisplay()
        window.orderFrontRegardless()
        self.window = window
        emit("launch.windowShown", epoch() - processStart)

        func noteFrame() {
            guard window.isVisible, textView.subviews.contains(where: { $0.subviews.contains { $0.layer?.contents != nil } }) else { return }
            let frame = epoch()
            emit("launch.firstFrame", frame - processStart)
            emit("launch.firstFrameEpoch", frame)
            guard scenario != "launch" else { exit(0) }
            if !self.isRunning { Task { await run(window, scroll, textView) } }
            self.isRunning = true
        }
        // As Marko does for the file it is started with: the window is drawn and handed to the
        // window server at once, not at the end of the launch. Without the variable the frame
        // goes out when AppKit sends it by itself.
        if ProcessInfo.processInfo.environment["MARKO_CONTROL_FLUSH"] == "1" {
            window.displayIfNeeded()
            CATransaction.flush()
            noteFrame()
        }
        // After Core Animation's own observer, which commits the turn's drawing.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { noteFrame() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        emit("launch.didFinishLaunching", epoch() - processStart)
    }
}

let delegate = Delegate(text: text)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
