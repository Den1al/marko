import AppKit
import MarkoEditor
import os

/// Self-terminating measurements: `MARKO_PERF=<scenario> Marko <file or folder>` does one kind of
/// work in the real app, writes `perf: <metric> <milliseconds>...` lines and exits. scripts/perf
/// runs these on a release build; scripts/perf/perf.py says what each number is. Like a smoke run it
/// keeps away from the user's settings, window frames and socket.
///
/// Scenarios: `launch` (process start to first frame, memory), `idle` (CPU once settled), `open`
/// (the same file opened again and again in the running app), `typing`, `scroll`, `resize`,
/// `switch` (files chosen in the tree), `folder` (the tree of a large folder), `serve` (answers
/// the `marko` tool, for the hand-off to a running app).
///
/// `MARKO_PERF_OUT=<file>` gets the lines instead of standard output (an app started through
/// `open` has none). `MARKO_PERF_OFFSETS=<name>:<offset>,...` are the places to type at,
/// `MARKO_PERF_PASTE=<file>` the text to paste, `MARKO_PERF_FILES=<path>:<path>` the files to
/// switch between, `MARKO_PERF_EXPAND=<name>,...` the folders to open in the tree ("*" is all of
/// them), `MARKO_PERF_COUNT` how often, `MARKO_PERF_GAP` the seconds between keys,
/// `MARKO_PERF_WIDTH` the width a resize starts from, `MARKO_PERF_FRAME_GAP` the milliseconds between scroll frames (1; 8 is what a 120 Hz display
/// leaves, and what scripts/perf/perf.py asks for),
/// `MARKO_PERF_PROFILE=1` only the steady part of a scenario, for a profiler to look at
/// (`MARKO_PERF_KEYS` the keys it types then),
/// `MARKO_PERF_POLICY=regular` an app with a Dock icon, `MARKO_PERF_ACTIVATE=1` the app brought
/// to the front once its first frame is there (keys in a background app take longer and drift;
/// scripts/perf/perf.py sets it for everything but launch and idle), `MARKO_PERF_TIMEOUT` the
/// seconds after which the run ends itself whatever happens (120).
///
/// A time "to the frame" ends when the window's layout and drawing are done and the transaction
/// is handed to the window server; what the window server does with it is not seen from here.
enum Perf {
    private static let environment = ProcessInfo.processInfo.environment
    private static let scenario = environment["MARKO_PERF"]
    static let isEnabled = scenario != nil
    static let isRegularApp = environment["MARKO_PERF_POLICY"] == "regular"
    private static let isProfile = environment["MARKO_PERF_PROFILE"] == "1"
    private static let gap = environment["MARKO_PERF_GAP"].flatMap(Double.init) ?? 0.03
    private static let signposter = OSSignposter(subsystem: "local.marko", category: .pointsOfInterest)

    /// Milliseconds from the start of the process to each named moment.
    private static var marks: [String: Double] = [:]
    /// How long the main run loop has been at work rather than waiting, and since when it is now.
    private static var busy = 0.0
    private static var awakeSince: Double?
    private static var served = 0

    private static func count(_ standard: Int) -> Int {
        environment["MARKO_PERF_COUNT"].flatMap(Int.init) ?? standard
    }

    // MARK: clocks

    /// Milliseconds on a clock that only runs forwards, for intervals.
    static func clock() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    /// Milliseconds since 1970, which a script outside the process can compare with its own.
    private static func epoch() -> Double {
        var time = timeval()
        gettimeofday(&time, nil)
        return Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
    }

    /// When the system made the process, before any of its code ran.
    private static let processStart: Double = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&name, 4, &info, &size, nil, 0)
        let time = info.kp_proc.p_starttime
        return Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
    }()

    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func processorTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func milliseconds(_ time: timeval) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000 }
        return milliseconds(usage.ru_utime) + milliseconds(usage.ru_stime)
    }

    // MARK: output

    private static func emit(_ line: String) {
        let data = Data("perf: \(line)\n".utf8)
        guard let path = environment["MARKO_PERF_OUT"] else { return FileHandle.standardOutput.write(data) }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    private static func emit(_ metric: String, _ values: [Double]) {
        emit(([metric] + values.map { String(format: "%.3f", $0) }).joined(separator: " "))
    }

    private static func fail(_ message: String) -> Never {
        emit("FAIL \(message)")
        exit(1)
    }

    /// Notes when the process first got to `name`; an Instruments trace shows the same moments.
    static func mark(_ name: StaticString) {
        guard isEnabled, marks["\(name)"] == nil else { return }
        marks["\(name)"] = epoch() - processStart
        signposter.emitEvent(name)
    }

    // MARK: watching the run loop

    /// Called first thing in main.swift.
    static func start() {
        guard isEnabled else { return }
        mark("main")
        emit("pid", [Double(getpid())])
        awakeSince = clock()
        // After Core Animation's own observer, which commits the turn's drawing.
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated {
                guard activity == .beforeWaiting else { return awakeSince = clock() }
                if let since = awakeSince { busy += clock() - since }
                awakeSince = nil
                noteFrames()
                // The first time the run loop has nothing left to do after launching: from here keys are taken.
                if marks["didFinishLaunching"] != nil { mark("idle") }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let limit = environment["MARKO_PERF_TIMEOUT"].flatMap(UInt32.init) ?? 120
        Thread.detachNewThread {
            sleep(limit)
            FileHandle.standardError.write(Data("perf: HARD TIMEOUT\n".utf8))
            exit(3)
        }
    }

    private static func busyTime() -> Double {
        busy + (awakeSince.map { clock() - $0 } ?? 0)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// How long the main thread works during the next `seconds`: what an edit leaves to be done later.
    private static func busy(during seconds: Double) async -> Double {
        let before = busyTime()
        await pause(seconds)
        return busyTime() - before
    }

    /// A window, and the document it shows: none in the window of a folder until a file is chosen.
    private typealias Shown = (controller: DocumentWindowController, window: NSWindow, document: MarkdownDocument?)

    private static var shown: Shown? {
        for window in NSApplication.shared.windows where window.isVisible {
            if let controller = window.windowController as? DocumentWindowController {
                return (controller, window, controller.document as? MarkdownDocument)
            }
        }
        return nil
    }

    /// The first frame is the first turn of the run loop that ends with a document's window on
    /// screen and a paragraph of its text drawn: the views of the paragraphs have their pictures.
    /// The window of a folder has no text; its first frame is the first turn that ends with it on screen.
    /// Called at the end of every turn of the run loop, and where a window is handed to the
    /// window server by hand (`DocumentWindowController.showWindow`).
    static func noteFrames() {
        guard isEnabled, marks["firstFrame"] == nil || marks["pictures"] == nil || marks["treeShown"] == nil, let shown else { return }
        if let editor = shown.document?.editor {
            let textView = editor.textView
            let hasText = textView.subviews.contains { $0.subviews.contains { $0.layer?.contents != nil } }
            let isEmpty = editor.text.isEmpty && textView.textLayoutManager?.textViewportLayoutController.viewportRange != nil
            if hasText || isEmpty { mark("firstFrame") }
            // Pictures get their pixels after the frame that makes room for them; a turn that ends
            // with none on its way has drawn them all.
            if marks["firstFrame"] != nil, !editor.isDecodingImages { mark("pictures") }
        } else if shown.document == nil {
            mark("firstFrame")
            mark("pictures")
        }
        // Asking a window without a tree for its tree would make one.
        if shown.controller.isSidebarVisible, shown.controller.sidebar.outlineView.numberOfRows > 0 { mark("treeShown") }
    }

    /// The parts of the last `timed`: the work itself, layout, drawing, and handing the frame over.
    private static var phases = [0.0, 0.0, 0.0, 0.0]
    private static let phaseNames = ["work", "layout", "draw", "commit"]

    /// What `work` costs up to the frame that shows it.
    private static func timed(_ window: NSWindow, _ work: () -> Void) -> Double {
        let start = clock()
        work()
        let worked = clock()
        window.layoutIfNeeded()
        let laidOut = clock()
        window.displayIfNeeded()
        let drawn = clock()
        CATransaction.flush()
        let end = clock()
        phases = [worked - start, laidOut - worked, drawn - laidOut, end - drawn]
        return end - start
    }

    // MARK: scenarios

    static func run() {
        mark("didFinishLaunching")
        Task {
            if scenario == "serve" {
                while true { await pause(1) }
            }
            while marks["firstFrame"] == nil { await pause(0.001) }
            guard let shown else { fail("no document window") }
            if environment["MARKO_PERF_ACTIVATE"] == "1" {
                NSApp.activate(ignoringOtherApps: true)
                shown.window.makeKeyAndOrderFront(nil)
                await pause(0.5)
            }
            while marks["pictures"] == nil { await pause(0.001) }
            for name in ["main", "willFinishLaunching", "didFinishLaunching", "openRequest", "firstFrame", "pictures", "treeShown", "idle"] {
                if let mark = marks[name] { emit("launch.\(name)", [mark]) }
            }
            emit("launch.firstFrameEpoch", [processStart + (marks["firstFrame"] ?? 0)])
            switch scenario {
            case "launch":
                await pause(1)
                emit("footprintMB", [footprint()])
            case "idle":
                await pause(5)
                let before = processorTime(), start = clock()
                await pause(10)
                emit("idle.cpuPercent", [(processorTime() - before) / (clock() - start) * 100])
                emit("idle.footprintMB", [footprint()])
            case "switch": await switchFiles(shown.controller, shown.window)
            case "folder": await browse(shown.controller, shown.window)
            default:
                guard let document = shown.document, let editor = document.editor else { fail("no document in the window") }
                switch scenario {
                case "open": await reopen(document)
                case "typing": await type(shown.window, editor)
                case "scroll": await scroll(shown.window, editor)
                case "resize": await resize(shown.window, editor)
                default: fail("unknown scenario \(scenario ?? "")")
                }
            }
            exit(0)
        }
    }

    /// The `marko` tool's request has been answered. In a `serve` run, which stands for an app
    /// that is already running, this is where the hand-off ends: the documents are on screen.
    static func served(_ documents: [MarkdownDocument], since started: Double) {
        guard scenario == "serve" else { return }
        documents.compactMap { $0.windowControllers.first?.window }.forEach { _ = timed($0) {} }
        emit("handoff.open", [clock() - started])
        emit("handoff.frameEpoch", [epoch()])
        served += 1
        if served == count(.max) { exit(0) }
    }

    /// A file opened in an app that is running, the way the tool and the tree open one: read,
    /// editor and window made, shown.
    private static func reopen(_ first: MarkdownDocument) async {
        guard let url = first.fileURL else { fail("the document has no file") }
        first.close()
        await pause(0.3)
        for _ in 0..<count(10) {
            let start = clock()
            guard let document = try? MarkdownDocument.document(at: url) else { fail("cannot read \(url.path)") }
            let read = clock()
            document.makeWindowControllers()
            let made = clock()
            guard let window = document.windowControllers.first?.window else { fail("no window") }
            let show = timed(window) { document.showWindows() }
            emit("open.read", [read - start])
            emit("open.editor", [made - read])
            emit("open.show", [show])
            emit("open.total", [clock() - start])
            // The pictures in view get their pixels after that frame; in a document without any this is the same moment.
            while document.editor?.isDecodingImages == true { await pause(0.001) }
            _ = timed(window) {}
            emit("open.pictures", [clock() - start])
            emit("open.after", [await busy(during: 0.3)])
            emit("open.footprintMB", [footprint()])
            document.close()
            await pause(0.1)
        }
    }

    private static var offsets: [(name: String, offset: Int)] {
        (environment["MARKO_PERF_OFFSETS"] ?? "").split(separator: ",").compactMap { item in
            let parts = item.split(separator: ":")
            return parts.count == 2 ? Int(parts[1]).map { (String(parts[0]), $0) } : nil
        }
    }

    private static func type(_ window: NSWindow, _ editor: EditorController) async {
        let textView = editor.textView
        window.makeFirstResponder(textView)
        func key(_ characters: String, _ code: UInt16 = 0, isARepeat: Bool = false) -> Double {
            timed(window) { Smoke.press(characters, code, in: window, isARepeat: isARepeat) }
        }
        func place(_ offset: Int) async {
            textView.setSelectedRange(NSRange(location: min(offset, (textView.string as NSString).length), length: 0))
            editor.scrollToSelection()
            await pause(0.6)
        }
        let commands: [(name: String, characters: String, code: UInt16)] = [
            ("return", "\r", 36), ("tab", "\t", 48), ("left", "\u{F702}", 123), ("right", "\u{F703}", 124),
            ("up", "\u{F700}", 126), ("down", "\u{F701}", 125),
        ]
        for (name, offset) in offsets {
            await place(offset)
            if isProfile {
                // Typing with a pause after every few words, as someone writing does.
                // `MARKO_PERF_KEYS`: other keys to look at, "\r" being Return.
                for _ in 0..<count(20) {
                    for character in environment["MARKO_PERF_KEYS"] ?? "steady typing here " {
                        _ = key(String(character), character == "\r" ? 36 : 0)
                        await pause(gap)
                    }
                    await pause(0.4)
                }
                continue
            }
            var keys: [Double] = [], after: [Double] = [], parts: [[Double]] = [[], [], [], []]
            for character in "The quick brown fox jumps over the lazy dog. " {
                keys.append(key(String(character)))
                for index in parts.indices { parts[index].append(phases[index]) }
                after.append(await busy(during: gap))
            }
            emit("type.\(name).key", keys)
            for index in parts.indices { emit("type.\(name).key.\(phaseNames[index])", parts[index]) }
            emit("type.\(name).after", after)
            // In a large document this is where the text is parsed again.
            emit("type.\(name).pause", [await busy(during: 0.6)])
            keys = []
            for _ in 0..<30 {
                keys.append(key("\u{7F}", 51, isARepeat: true))
                await pause(gap)
            }
            emit("backspace.\(name).key", keys)
            await pause(0.6)
            for command in commands {
                // The key by itself, and straight after a character, when a large document's map is behind.
                var alone: [Double] = [], afterTyping: [Double] = [], parts: [[Double]] = [[], [], [], []]
                for _ in 0..<3 {
                    alone.append(key(command.characters, command.code))
                    await pause(0.1)
                    _ = key("x")
                    afterTyping.append(key(command.characters, command.code))
                    for index in parts.indices { parts[index].append(phases[index]) }
                    await pause(0.6)
                }
                emit("command.\(name).\(command.name)", alone)
                emit("afterTyping.\(name).\(command.name)", afterTyping)
                for index in parts.indices { emit("afterTyping.\(name).\(command.name).\(phaseNames[index])", parts[index]) }
            }
        }
        guard !isProfile, let first = offsets.first?.offset, let path = environment["MARKO_PERF_PASTE"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // A pasteboard of its own: the user's clipboard is left alone.
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        func step(_ name: String, _ work: () -> Void) async {
            emit(name, [timed(window, work)])
            emit("\(name).after", [await busy(during: 1)])
        }
        // MEASURED: without real events the undo manager never closes the group it opened for the
        // first key, so one undo would take back everything since the launch. Each edit here is
        // made a group of its own, which is what a paste or a delete is when a person does it.
        let undo = textView.undoManager
        while (undo?.groupingLevel ?? 0) > 0 { undo?.endUndoGrouping() }
        undo?.groupsByEvent = false
        func edit(_ work: () -> Void) {
            undo?.beginUndoGrouping()
            work()
            undo?.endUndoGrouping()
        }
        for _ in 0..<count(3) {
            await place(first)
            let length = (textView.string as NSString).length
            await step("paste") { edit { _ = textView.readSelection(from: pasteboard, type: .string) } }
            if (textView.string as NSString).length != length + (text as NSString).length { fail("nothing was pasted") }
            await step("paste.undo") { undo?.undo() }
            if (textView.string as NSString).length != length { fail("the paste was not undone") }
            await step("selectAll") { textView.selectAll(nil) }
            await step("selectAll.delete") { edit { Smoke.press("\u{7F}", 51, in: window) } }
            if !textView.string.isEmpty { fail("the text was not deleted") }
            await step("selectAll.delete.undo") { undo?.undo() }
            if (textView.string as NSString).length != length { fail("the deletion was not undone") }
        }
        pasteboard.releaseGlobally()
    }

    /// Scrolls as a wheel does, a few lines per frame, and as a dragged scroller does, the whole
    /// document in a few hundred jumps, down and up again. Each value is one frame's work.
    private static func scroll(_ window: NSWindow, _ editor: EditorController) async {
        let clip = editor.scrollView.contentView, textView = editor.textView
        var end: CGFloat { max(0, textView.frame.height - clip.bounds.height) }
        func frame(at y: CGFloat) -> Double {
            timed(window) {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                editor.scrollView.reflectScrolledClipView(clip)
            }
        }
        func run(_ name: String, frames: Int, to position: (Int) -> CGFloat) async {
            var times: [Double] = [], background = 0, slowInBackground = 0
            let before = busyTime()
            for index in 1...frames {
                // A short document ends before the frames do.
                let y = position(index)
                if y == clip.bounds.minY { break }
                times.append(frame(at: y))
                // MEASURED: the system does not always let the app come to the front, or stay
                // there, while the Mac is in use, and frames made in the background are slower.
                if !NSApp.isActive {
                    background += 1
                    if times[times.count - 1] > 8.33 { slowInBackground += 1 }
                }
                // Whatever the frame left for later gets its turn, as it does between real frames.
                // `MARKO_PERF_FRAME_GAP` (ms) makes the pause as long as a display leaves between frames.
                await pause((environment["MARKO_PERF_FRAME_GAP"].flatMap(Double.init) ?? 1) / 1000)
            }
            guard !times.isEmpty else { return }
            emit("scroll.\(name).frame", times)
            emit("scroll.\(name).backgroundFrames", [Double(background)])
            emit("scroll.\(name).backgroundFramesOver8ms", [Double(slowInBackground)])
            emit("scroll.\(name).busyPerFrame", [(busyTime() - before) / Double(times.count)])
        }
        let frames = count(600), top = clip.bounds.minY
        await run("wheel", frames: isProfile ? frames * 5 : frames) { min(top + CGFloat($0) * 40, end) }
        guard !isProfile else { return }
        _ = frame(at: top)
        await pause(0.3)
        await run("sweepDown", frames: frames / 2) { top + (end - top) * CGFloat($0) / CGFloat(frames / 2) }
        await run("sweepUp", frames: frames / 2) { top + (end - top) * CGFloat(frames / 2 - $0) / CGFloat(frames / 2) }
        emit("scroll.height", [textView.frame.height])
    }

    /// The window made narrower and wider again in steps, as a drag of its edge does.
    private static func resize(_ window: NSWindow, _ editor: EditorController) async {
        if let offset = offsets.first?.offset {
            editor.textView.setSelectedRange(NSRange(location: offset, length: 0))
            editor.scrollToSelection()
            await pause(0.5)
        }
        // `MARKO_PERF_WIDTH`: the width to start from; from 1,300 points on only the margins change.
        if let width = environment["MARKO_PERF_WIDTH"].flatMap(Double.init) {
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: width, height: window.frame.height), display: true)
            await pause(0.3)
        }
        let frame = window.frame
        var times: [Double] = []
        for index in 0..<count(80) {
            let phase = index % 40, steps = phase < 20 ? phase + 1 : 39 - phase
            let width = frame.width - CGFloat(steps) * 20
            times.append(timed(window) { window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height), display: false) })
            await pause(0.001)
        }
        emit("resize.step", times)
    }

    private static func switchFiles(_ controller: DocumentWindowController, _ window: NSWindow) async {
        let files = (environment["MARKO_PERF_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        guard !files.isEmpty else { fail("MARKO_PERF_FILES is not set") }
        await pause(0.5)
        for index in 0..<count(20) {
            let url = files[index % files.count]
            let time = timed(window) { controller.open(url) }
            guard (controller.document as? MarkdownDocument)?.fileURL?.path == url.resolvingSymlinksInPath().path else {
                fail("\(url.lastPathComponent) was not shown")
            }
            emit("switch.\(url.deletingPathExtension().lastPathComponent)", [time])
            emit("switch.after", [await busy(during: 0.2)])
        }
    }

    /// The tree of a folder: its first listing, then folders opened in it. `wall` is from the
    /// click to the frame with the folder's rows, `busy` the main thread's part of that.
    private static func browse(_ controller: DocumentWindowController, _ window: NSWindow) async {
        guard controller.isSidebarVisible else { fail("the window has no tree") }
        let outline = controller.sidebar.outlineView
        while marks["treeShown"] == nil { await pause(0.001) }
        emit("folder.treeShown", [marks["treeShown"] ?? 0])
        emit("folder.rows", [Double(outline.numberOfRows)])
        await pause(0.5)
        func name(_ row: Int) -> String? {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }
        /// Opens the folders and waits until no more rows arrive.
        func expand(_ items: [Any], as label: String) async {
            let rows = outline.numberOfRows, before = busyTime(), start = clock()
            let click = timed(window) { items.forEach(outline.expandItem) }
            var seen = rows, changed = start
            // Until the first rows have come, and then until no more do.
            while (seen == rows || clock() - changed < 400), clock() - start < 20_000 {
                await pause(0.001)
                if outline.numberOfRows != seen {
                    seen = outline.numberOfRows
                    _ = timed(window) {}
                    changed = clock()
                }
            }
            emit("folder.expand.\(label).click", [click])
            emit("folder.expand.\(label).wall", [changed - start])
            emit("folder.expand.\(label).busy", [busyTime() - before])
            emit("folder.expand.\(label).rows", [Double(seen - rows)])
        }
        // The root's rows, before any of them is opened and the rows below move.
        let top = (0..<outline.numberOfRows).compactMap { row in outline.item(atRow: row).map { (name: name(row), item: $0) } }
        for wanted in (environment["MARKO_PERF_EXPAND"] ?? "").split(separator: ",").map(String.init) where wanted != "*" {
            guard let item = top.first(where: { $0.name == wanted })?.item else { fail("no folder \(wanted) in the tree") }
            await expand([item], as: wanted)
        }
        guard environment["MARKO_PERF_EXPAND"]?.contains("*") == true else { return }
        await expand(top.map(\.item).filter { outline.isExpandable($0) && !outline.isItemExpanded($0) }, as: "all")
        // Through the whole tree with every folder open.
        guard let clip = outline.enclosingScrollView?.contentView else { return }
        var times: [Double] = []
        let end = max(0, outline.frame.height - clip.bounds.height), start = clip.bounds.minY
        for index in 1...200 {
            times.append(timed(window) {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: start + (end - start) * CGFloat(index) / 200))
                outline.enclosingScrollView?.reflectScrolledClipView(clip)
            })
            await pause(0.001)
        }
        emit("folder.scroll.frame", times)
        emit("folder.footprintMB", [footprint()])
    }
}
