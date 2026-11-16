import AppKit
import MarkoEditor

enum MainMenu {
    static func install() {
        let main = NSMenu()
        let windowMenu = window()
        let helpMenu = NSMenu(title: "Help")
        for menu in [app(), file(), edit(), EditorTextView.formatMenu(), view(), windowMenu, helpMenu] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    private static func app() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu()
        menu.add("About \(name)", #selector(AppDelegate.showAbout(_:)))
        menu.addItem(.separator())
        menu.add("Install Command Line Tool…", #selector(AppDelegate.installCommandLineTool(_:)))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.add("Services").submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.add("Hide \(name)", #selector(NSApplication.hide(_:)), "h")
        menu.add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        menu.add("Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.add("Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func file() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.add("New", #selector(NSDocumentController.newDocument(_:)), "n")
        menu.add("Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        // "Open Recent" is AppKit's own: MEASURED, it puts one behind "Open…" as the app launches,
        // whether or not the menu has one already, and fills only its own.
        menu.addItem(.separator())
        menu.add("Close", #selector(NSWindow.performClose(_:)), "w")
        menu.add("Save…", #selector(NSDocument.save(_:)), "s")
        menu.add("Duplicate", #selector(NSDocument.duplicate(_:)), "S")
        // With Option held, as in every app whose documents save themselves.
        menu.add("Save As…", #selector(NSDocument.saveAs(_:)), "S", [.command, .option]).isAlternate = true
        menu.add("Rename…", #selector(NSDocument.rename(_:)))
        menu.add("Move To…", #selector(NSDocument.move(_:)))
        menu.addItem(.separator())
        menu.add("Revert To Saved", #selector(NSDocument.revertToSaved(_:)))
        menu.add("Browse All Versions…", #selector(NSDocument.browseVersions(_:)))
        menu.addItem(.separator())
        menu.add("Trust This Folder…", #selector(DocumentWindowController.toggleFolderTrust(_:)))
        // Filled when it opens: see `AppDelegate.menuNeedsUpdate`.
        let trusted = NSMenu(title: "Trusted Folders")
        trusted.delegate = NSApp.delegate as? NSMenuDelegate
        menu.add("Trusted Folders").submenu = trusted
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.add("Undo", Selector(("undo:")), "z")
        menu.add("Redo", Selector(("redo:")), "Z")
        menu.addItem(.separator())
        menu.add("Cut", #selector(NSText.cut(_:)), "x")
        menu.add("Copy", #selector(NSText.copy(_:)), "c")
        menu.add("Paste", #selector(NSText.paste(_:)), "v")
        menu.add("Delete", #selector(NSText.delete(_:)))
        menu.add("Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        func finder(_ title: String, _ action: NSTextFinder.Action, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            find.add(title, #selector(NSTextView.performTextFinderAction(_:)), key, modifiers).tag = action.rawValue
        }
        finder("Find…", .showFindInterface, "f")
        finder("Find and Replace…", .showReplaceInterface, "f", [.command, .option])
        finder("Find Next", .nextMatch, "g")
        finder("Find Previous", .previousMatch, "G")
        finder("Use Selection for Find", .setSearchString, "e")
        find.add("Jump to Selection", #selector(NSTextView.centerSelectionInVisibleArea(_:)), "j")
        menu.add("Find").submenu = find
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.add("Actual Size", #selector(AppDelegate.resetZoom(_:)), "0", [.command, .control])
        menu.add("Zoom In", #selector(AppDelegate.increaseZoom(_:)), "+")
        menu.add("Zoom Out", #selector(AppDelegate.decreaseZoom(_:)), "-")
        menu.add("Full Width", #selector(AppDelegate.toggleFullWidth(_:)))
        menu.addItem(.separator())
        menu.add("Show Sidebar", #selector(DocumentWindowController.toggleFiles(_:)), "b")
        menu.add("Hide Word Count", #selector(AppDelegate.toggleWordCount(_:)))
        menu.add("Load Remote Images", #selector(DocumentWindowController.toggleRemoteImages(_:)))
        menu.addItem(.separator())
        menu.add("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:)))
        menu.add("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift])
        menu.add("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        menu.add("Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        // MEASURED: AppKit adds none of its tab items to a menu made in code, here or in View.
        menu.add("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift])
        menu.add("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", .control)
        menu.add("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)))
        menu.add("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)))
        menu.addItem(.separator())
        menu.add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }
}

private extension NSMenu {
    /// An uppercase key implies Shift, as AppKit defines for key equivalents.
    @discardableResult
    func add(_ title: String, _ action: Selector? = nil, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
