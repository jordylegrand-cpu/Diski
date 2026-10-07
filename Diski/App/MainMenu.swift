import AppKit

/// The menu bar, built in code. Shortcuts follow Finder wherever Finder has one.
@MainActor
enum MainMenu {
    private static func key(_ scalar: Int) -> String {
        String(Character(UnicodeScalar(UInt32(scalar))!))
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0,
                            represented: Any? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        item.representedObject = represented
        item.target = target
        menu.addItem(item)
        return item
    }

    static func build() -> NSMenu {
        let main = NSMenu()

        // Diski
        let app = NSMenu(title: "Diski")
        add(app, "About Diski", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(app, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
        app.addItem(.separator())
        add(app, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        app.addItem(.separator())
        add(app, "Hide Diski", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Diski", #selector(NSApplication.terminate(_:)), "q")
        main.addItem(submenu(app))

        // File
        let file = NSMenu(title: "File")
        add(file, "New Window", #selector(AppDelegate.newWindow(_:)), "n")
        add(file, "New Tab", #selector(AppDelegate.newTab(_:)), "t")
        add(file, "New Folder", #selector(PaneViewController.newFolder(_:)), "n", [.command, .shift])
        add(file, "New Folder with Selection", #selector(PaneViewController.newFolderWithSelection(_:)), "n", [.command, .control])
        add(file, "New Text File", #selector(PaneViewController.newFile(_:)), "n", [.command, .option])
        file.addItem(.separator())
        add(file, "Open", #selector(PaneViewController.openSelection(_:)), "o")
        add(file, "Open in New Tab", #selector(PaneViewController.openInNewTab(_:)), "o", [.command, .control])
        add(file, "Open in Terminal", #selector(PaneViewController.openInTerminal(_:)), "t", [.command, .control, .option])
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        file.addItem(.separator())
        add(file, "Get Info", #selector(PaneViewController.getInfo(_:)), "i")
        add(file, "Rename", #selector(PaneViewController.renameSelection(_:)))
        add(file, "Compress", #selector(PaneViewController.compress(_:)))
        add(file, "Duplicate", #selector(PaneViewController.duplicateSelection(_:)), "d")
        add(file, "Make Alias", #selector(PaneViewController.makeAlias(_:)), "a", [.command, .control])
        add(file, "Make Symbolic Link", #selector(PaneViewController.makeSymbolicLink(_:)))
        add(file, "Quick Look", #selector(PaneViewController.quickLook(_:)), "y")
        add(file, "Show Original", #selector(PaneViewController.showOriginal(_:)), "r")
        add(file, "Show in Enclosing Folder", #selector(PaneViewController.showInEnclosingFolder(_:)))
        add(file, "Reveal in Finder", #selector(PaneViewController.revealInFinder(_:)))
        add(file, "Add to Sidebar", #selector(PaneViewController.addToSidebar(_:)), "t", [.command, .control])
        file.addItem(.separator())
        add(file, "Move to Trash", #selector(PaneViewController.moveToTrash(_:)), "\u{8}")
        add(file, "Delete Immediately…", #selector(PaneViewController.deleteImmediately(_:)), "\u{8}", [.command, .option]).isAlternate = true
        add(file, "Put Back", #selector(PaneViewController.putBackSelection(_:)))
        add(file, "Eject", #selector(PaneViewController.eject(_:)), "e")
        file.addItem(.separator())
        add(file, "Find", #selector(BrowserWindowController.focusSearch(_:)), "f")
        let tags = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        let tagsMenu = NSMenu(title: "Tags")
        for index in TagColors.sidebarOrder {
            let item = add(tagsMenu, TagColors.names[index], #selector(PaneViewController.applyTag(_:)), tag: index)
            item.image = PaneViewController.dotImage(TagColors.color(forLabel: index))
        }
        tags.submenu = tagsMenu
        file.addItem(tags)
        main.addItem(submenu(file))

        // Edit
        let edit = NSMenu(title: "Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(PaneViewController.cut(_:)), "x")
        // Like Finder, the ⌥ variants replace their primary only while ⌥ is held.
        // Each alternate must directly follow its primary.
        add(edit, "Copy", #selector(PaneViewController.copy(_:)), "c")
        add(edit, "Copy Path", #selector(PaneViewController.copyPath(_:)), "c", [.command, .option]).isAlternate = true
        add(edit, "Paste", #selector(PaneViewController.paste(_:)), "v")
        add(edit, "Move Item Here", #selector(PaneViewController.moveItemHere(_:)), "v", [.command, .option]).isAlternate = true
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Empty Trash…", #selector(PaneViewController.emptyTrash(_:)), "\u{8}", [.command, .shift])
        main.addItem(submenu(edit))

        // View
        let view = NSMenu(title: "View")
        for mode in ViewMode.allCases {
            add(view, "as \(mode.title)", #selector(PaneViewController.switchViewMode(_:)), "\(mode.rawValue + 1)", tag: mode.rawValue)
        }
        view.addItem(.separator())
        let sort = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Sort By")
        for (index, key) in SortKey.allCases.enumerated() {
            add(sortMenu, key.title, #selector(PaneViewController.sortBy(_:)), "\(index + 1)", [.command, .control, .option],
                represented: key.rawValue)
        }
        sortMenu.addItem(.separator())
        add(sortMenu, "Keep Folders on Top", #selector(PaneViewController.toggleFoldersOnTop(_:)))
        sort.submenu = sortMenu
        view.addItem(sort)
        add(view, "Show Hidden Files", #selector(PaneViewController.toggleHiddenFiles(_:)), ".", [.command, .shift])
        add(view, "Show View Options", #selector(BrowserWindowController.showViewOptions(_:)), "j")
        view.addItem(.separator())
        add(view, "Show Tab Bar", #selector(NSWindow.toggleTabBar(_:)), "t", [.command, .shift])
        add(view, "Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift])
        add(view, "Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        add(view, "Hide Preview", #selector(BrowserWindowController.togglePreviewPane(_:)), "p", [.command, .shift])
        add(view, "Hide Path Bar", #selector(BrowserWindowController.togglePathBar(_:)), "p", [.command, .option])
        add(view, "Hide Item Info", #selector(BrowserWindowController.toggleStatusInfo(_:)), "/")
        view.addItem(.separator())
        add(view, "Open Second Pane", #selector(BrowserWindowController.toggleDualPane(_:)), "\\")
        add(view, "Copy to Other Pane", #selector(BrowserWindowController.copyToOtherPane(_:)), key(NSF5FunctionKey), [])
        add(view, "Move to Other Pane", #selector(BrowserWindowController.moveToOtherPane(_:)), key(NSF6FunctionKey), [])
        view.addItem(.separator())
        // NSWindow validates this item and switches it between Show and Hide.
        add(view, "Hide Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])
        add(view, "Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        main.addItem(submenu(view))

        // Go
        let go = NSMenu(title: "Go")
        add(go, "Back", #selector(PaneViewController.goBack(_:)), "[")
        add(go, "Forward", #selector(PaneViewController.goForward(_:)), "]")
        add(go, "Enclosing Folder", #selector(PaneViewController.goToEnclosingFolder(_:)), key(NSUpArrowFunctionKey))
        go.addItem(.separator())
        let home = NSHomeDirectory()
        let places: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Documents", home + "/Documents", "o", [.command, .shift]),
            ("Desktop", home + "/Desktop", "d", [.command, .shift]),
            ("Downloads", home + "/Downloads", "l", [.command, .option]),
            ("Home", home, "h", [.command, .shift]),
            ("Computer", "/", "c", [.command, .shift]),
            ("Network", "/Network", "k", [.command, .shift]),
            ("iCloud Drive", home + "/Library/Mobile Documents/com~apple~CloudDocs", "i", [.command, .shift]),
            ("Applications", "/Applications", "a", [.command, .shift]),
            ("Utilities", "/Applications/Utilities", "u", [.command, .shift]),
            ("Library", home + "/Library", "", []),
            ("Trash", home + "/.Trash", "", []),
        ]
        for (title, path, key, modifiers) in places {
            add(go, title, #selector(PaneViewController.goToPath(_:)), key, modifiers, represented: path)
        }
        add(go, "AirDrop", #selector(AppDelegate.openAirDrop(_:)), "r", [.command, .shift])
        go.addItem(.separator())
        let recent = NSMenuItem(title: "Recent Folders", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Recent Folders")
        recentMenu.delegate = RecentFoldersMenuDelegate.shared
        recent.submenu = recentMenu
        go.addItem(recent)
        go.addItem(.separator())
        add(go, "Go to Folder…", #selector(BrowserWindowController.showGoToFolder(_:)), "g", [.command, .shift])
        add(go, "Connect to Server…", #selector(AppDelegate.connectToServer(_:)), "k")
        main.addItem(submenu(go))

        // Window
        let window = NSMenu(title: "Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift])
        add(window, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control])
        add(window, "Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)))
        add(window, "Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)))
        window.addItem(.separator())
        add(window, "File Operations", #selector(BrowserWindowController.showOperations(_:)), "o", [.command, .option])
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window
        main.addItem(submenu(window))

        // Help
        let help = NSMenu(title: "Help")
        add(help, "Diski Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/", [.command, .shift])
        add(help, "Diski on GitHub", #selector(AppDelegate.openWebsite(_:)))
        NSApp.helpMenu = help
        main.addItem(submenu(help))
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Fills Go › Recent Folders on demand.
final class RecentFoldersMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentFoldersMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fm = FileManager.default
        for path in Prefs.recentFolders.prefix(20) where fm.fileExists(atPath: path) {
            let item = NSMenuItem(title: fm.displayName(atPath: path), action: #selector(PaneViewController.goToPath(_:)), keyEquivalent: "")
            item.representedObject = path
            item.toolTip = path
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Recent Folders", action: nil, keyEquivalent: "").isEnabled = false
        }
    }
}
