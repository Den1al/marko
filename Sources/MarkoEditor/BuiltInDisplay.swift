import AppKit

// Where every window goes that is not the user's: those of the tests, of smoke, snapshot and
// measuring runs, and of scripts/perf/control (which is compiled with this file). On a Mac with
// an external display such windows stay on the Mac's own, out of the way of whoever is working
// on the other. Nothing in a normal launch calls this.

public extension NSScreen {
    /// The Mac's own display, whichever display is the main one; nil on a Mac without one or with its lid closed.
    static var builtIn: NSScreen? {
        screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } == true
        }
    }
}

public extension NSWindow {
    /// Puts the window's top left corner at the top left of the built-in display, below the menu
    /// bar; a window wider than that display hangs over its right edge. Without a built-in
    /// display the window stays where it is, and the answer is false.
    @discardableResult func moveToBuiltInDisplay() -> Bool {
        guard let visible = NSScreen.builtIn?.visibleFrame else { return false }
        setFrameTopLeftPoint(NSPoint(x: visible.minX, y: visible.maxY))
        return true
    }
}
