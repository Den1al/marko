// What scripts/perf/perf.py cannot do from Python. Built by it with `swiftc -O` into build/perf/helper.
//
//   helper window <app> [--file <path>] [--document] [--isolated] [--arg <argument>]... [--env <NAME=value>]...
//       Starts a new instance of an editor in the background, without bringing it to the front,
//       and prints how long it took until the window server had a window of it on screen:
//       "visible=<ms> quiet=<ms until its processes stopped working> memoryMB=<footprint of the
//       instance and its child processes at least three seconds after the window>".
//       The file is handed over as a document to open (--document) or as the last argument. The
//       instance is then ended, by its pid. Unless --isolated says that the instance shares
//       nothing with one that is running (a data folder of its own), an editor that is already
//       running is left alone: "skipped".
//
//   helper sample <report> <seconds> -- <command> <argument>...
//       Runs the command with /usr/bin/sample watching it from its first instruction: the process
//       is made stopped and continued once the sampler is attached.
import AppKit
import Darwin

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("helper: \(message)\n".utf8))
    exit(2)
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

/// The process and everything it started that still runs.
func family(of root: pid_t) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var parents: [pid_t: pid_t] = [:]
    for pid in pids.prefix(max(count, 0)) where pid > 0 {
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 { parents[pid] = pid_t(info.pbi_ppid) }
    }
    var found: Set<pid_t> = [root], grew = true
    while grew {
        grew = false
        for (pid, parent) in parents where found.contains(parent) && !found.contains(pid) {
            found.insert(pid)
            grew = true
        }
    }
    return found.filter { $0 == root || parents[$0] != nil }
}

func footprint(of pid: pid_t) -> Double {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? Double(usage.ri_phys_footprint) / 1_048_576 : 0
}

/// Processor time the processes have used so far, in milliseconds.
func processorTime(of pids: [pid_t]) -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return pids.reduce(0) { total, pid in
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return total }
        return total + Double(usage.ri_user_time + usage.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }
}

/// Whether the window server shows an ordinary window of the process.
func hasWindow(_ pid: pid_t) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { window in
        guard let owner = window[kCGWindowOwnerPID as String] as? Int, pid_t(owner) == pid,
              window[kCGWindowLayer as String] as? Int == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
        return width >= 300 && height >= 200
    }
}

func window(_ arguments: [String]) {
    var app: String?, file: String?, asDocument = false, isIsolated = false, extra: [String] = [], environment: [String: String] = [:]
    var rest = arguments[...]
    while let argument = rest.popFirst() {
        switch argument {
        case "--file": file = rest.popFirst()
        case "--document": asDocument = true
        case "--isolated": isIsolated = true
        case "--arg": rest.popFirst().map { extra.append($0) }
        case "--env":
            let pair = (rest.popFirst() ?? "").split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { environment[pair[0]] = pair[1] }
        default: app = argument
        }
    }
    guard let app else { fail("no app") }
    let url = URL(fileURLWithPath: app)
    if !isIsolated, let identifier = Bundle(url: url)?.bundleIdentifier,
       !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
        print("skipped: \(identifier) is already running and is left alone")
        return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = true
    configuration.environment = environment
    var started: NSRunningApplication?, problem: Error?
    let done = DispatchSemaphore(value: 0)
    let start = now()
    if asDocument, let file {
        NSWorkspace.shared.open([URL(fileURLWithPath: file)], withApplicationAt: url, configuration: configuration) {
            (started, problem) = ($0, $1)
            done.signal()
        }
    } else {
        configuration.arguments = extra + (file.map { [$0] } ?? [])
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) {
            (started, problem) = ($0, $1)
            done.signal()
        }
    }
    // The window may be there before the system says the app has started.
    var visible: Double?
    var pid: pid_t?
    let deadline = start + 60_000
    while visible == nil, now() < deadline {
        if pid == nil, done.wait(timeout: .now()) == .success {
            guard let started else { fail("cannot start \(app): \(problem?.localizedDescription ?? "")") }
            pid = started.processIdentifier
        }
        if let pid, hasWindow(pid) { visible = now() - start }
        // One that ends without a window has declined to run beside the instance that is open.
        if let pid, visible == nil, kill(pid, 0) != 0 {
            print("skipped: the new instance ended by itself without showing a window")
            return
        }
        usleep(1000)
    }
    guard let pid else { fail("\(app) did not start") }
    var members = family(of: pid)
    if let visible {
        // A window on screen is not yet an editor that can be used: an empty window counts. The
        // other moment that can be told from outside is when its processes stop working, which is
        // the start of the first half second in which they use less than a tenth of one core.
        var quiet: Double?
        var last = processorTime(of: members), calm = 0
        while quiet == nil, now() - start < visible + 20_000 {
            usleep(100_000)
            members = family(of: pid)
            let used = processorTime(of: members)
            calm = used - last < 10 ? calm + 1 : 0
            last = used
            if calm == 5 { quiet = now() - start - 500 }
        }
        let rest = visible + 3000 - (now() - start)
        if rest > 0 { usleep(UInt32(rest * 1000)) }
        members = family(of: pid)
        print(String(format: "visible=%.1f quiet=%.1f memoryMB=%.1f processes=%d", visible, quiet ?? -1,
                     members.map(footprint).reduce(0, +), members.count))
    } else {
        print("no window within a minute")
    }
    // Only what was started here is ended: asked first, then killed, by pid.
    started?.terminate()
    let patience = now() + 3000
    while kill(pid, 0) == 0, now() < patience { usleep(20_000) }
    for member in members where kill(member, 0) == 0 { kill(member, SIGKILL) }
}

func sample(_ arguments: [String]) {
    guard arguments.count > 3, arguments[2] == "--" else { fail("usage: helper sample <report> <seconds> -- <command>...") }
    let command = Array(arguments[3...])
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED))
    var pid: pid_t = 0
    let argv = command.map { strdup($0) } + [nil]
    guard posix_spawn(&pid, command[0], nil, &attributes, argv, environ) == 0 else { fail("cannot start \(command[0])") }
    let sampler = Process()
    sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    sampler.arguments = [String(pid), arguments[1], "1", "-mayDie", "-file", arguments[0]]
    sampler.standardOutput = FileHandle.nullDevice
    sampler.standardError = FileHandle.nullDevice
    do { try sampler.run() } catch {
        kill(pid, SIGKILL)
        fail("cannot run sample")
    }
    // Time for the sampler to attach; until then every sample is the stopped process at `_dyld_start`.
    usleep(700_000)
    kill(pid, SIGCONT)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    sampler.waitUntilExit()
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "window": window(Array(arguments.dropFirst()))
case "sample": sample(Array(arguments.dropFirst()))
default: fail("usage: helper window|sample ...")
}
