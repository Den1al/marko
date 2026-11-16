import AppKit
import MarkoEditor

Perf.start()
// The file the app was started for is read and parsed while AppKit starts. The `marko` tool
// names it in MARKO_FILE, since its request only arrives when the app has finished launching.
if let path = ProcessInfo.processInfo.environment["MARKO_FILE"] ?? DocumentController.argument {
    MarkdownDocument.preparse = Preparse(contentsOf: URL(fileURLWithPath: path))
}
if Smoke.isEnabled {
    // MEASURED: the windows kept at Quit are in one place per app, whatever instance writes them,
    // and an instance that does not keep its windows empties that place when it quits. A smoke or
    // measuring run neither restores the user's windows nor takes them away.
    UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    // Nor does it read or change the folders the user trusts: its answers end with it. It only
    // asks about a folder when it is run to show the question.
    DocumentWindowController.asksAboutTrust = ProcessInfo.processInfo.environment["MARKO_TRUST"] == "ask"
    // Nor is it in the Dock, not even while it starts. MEASURED: an app is put there when
    // NSApplication is made, before it can become an accessory, and every smoke run showed a
    // second Marko beside the user's for a moment (28 in one scripts/smoke.sh). The system reads
    // what kind of app this is from the bundle's own dictionary, which is set here first. Not
    // in a measuring run, which starts the way it was measured.
    if !Perf.isEnabled, let info = CFBundleGetInfoDictionary(CFBundleGetMainBundle()) {
        (info as NSDictionary as? NSMutableDictionary)?["LSUIElement"] = true
    }
} else {
    DocumentWindowController.keepsWindowFrames = true
    // The folders the user trusts are kept, and one without an answer is asked about.
    TrustStore.shared = TrustStore(defaults: .standard)
    DocumentWindowController.asksAboutTrust = true
    // The windows that were open at Quit come back with the app. MEASURED: the system's default
    // ("Close windows when quitting an application") restores nothing, and a folder window with
    // its file, caret and tree was gone after every relaunch. This only fills in for a setting the
    // user has not made: the system's own, once set either way, comes first.
    UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": true])
}
// The first document controller made is the shared one.
_ = DocumentController()
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
