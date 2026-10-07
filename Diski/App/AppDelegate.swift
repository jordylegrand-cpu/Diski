import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controllers: [BrowserWindowController] = []
    private var pendingPaths: [String] = []
    private var launched = false
    private var dayObserver: NSObjectProtocol?

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        guard !isRunningTests else { return }
        FileOperationManager.shared.conflictPresenter = { source, existing, operation, completion in
            ConflictDialog.present(source: source, existing: existing, operation: operation, completion: completion)
        }
        // Opens Finder's "Copy" window by itself for operations that take a while.
        _ = ProgressWindowController.shared
        NSApp.servicesProvider = self
        _ = VolumeMonitor.shared
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            Formatters.refreshDayBoundaries()
        }

        if !pendingPaths.isEmpty {
            let paths = pendingPaths
            pendingPaths = []
            open(paths: paths)
        } else if controllers.isEmpty && (CIDriver.isEnabled || !restoreSession()) {
            let start = CIDriver.startPath ?? Prefs.newWindowPath
            let controller = makeWindow(path: FileManager.default.fileExists(atPath: start) ? start : NSHomeDirectory())
            controller.showWindow(nil)
        }
        CIDriver.run(app: self)
        NSApp.activate()
        // Registers the Services entries without holding up the first window (an IPC to pbs).
        DispatchQueue.main.async { NSUpdateDynamicServices() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        if !CIDriver.isEnabled { saveSession() }
    }

    // MARK: Session restore (windows, tabs, folders, view modes)

    private func saveSession() {
        var groups: [[[String: Any]]] = []
        var seen = Set<ObjectIdentifier>()
        for controller in controllers {
            guard let window = controller.window, window.isVisible || window.isMiniaturized,
                  !seen.contains(ObjectIdentifier(window)) else { continue }
            var group: [[String: Any]] = []
            for tab in window.tabbedWindows ?? [window] {
                seen.insert(ObjectIdentifier(tab))
                guard let browser = tab.windowController as? BrowserWindowController else { continue }
                group.append(["path": browser.activePane.displayedPath, "mode": browser.activePane.viewMode.rawValue])
            }
            if !group.isEmpty { groups.append(group) }
        }
        UserDefaults.standard.set(groups, forKey: "savedSession")
    }

    private func restoreSession() -> Bool {
        guard let groups = UserDefaults.standard.array(forKey: "savedSession") as? [[[String: Any]]], !groups.isEmpty else {
            return false
        }
        var restored = false
        for group in groups {
            var first: BrowserWindowController?
            for entry in group {
                guard let path = entry["path"] as? String, FileManager.default.fileExists(atPath: path) else { continue }
                let mode = (entry["mode"] as? Int).flatMap { ViewMode(rawValue: $0) }
                let controller = makeWindow(path: path, viewMode: mode)
                if let first, let window = first.window, let tab = controller.window {
                    window.addTabbedWindow(tab, ordered: .above)
                } else {
                    first = controller
                }
                controller.showWindow(nil)
                restored = true
            }
            first?.window?.makeKeyAndOrderFront(nil)
        }
        return restored
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Opening folders from Finder, the Dock and other apps

    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter { $0.isFileURL }.map { $0.path }
        if launched {
            open(paths: paths)
        } else {
            pendingPaths += paths
        }
    }

    private func open(paths: [String]) {
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let isFolder = isDirectory.boolValue && !FileKinds.isPackage(name: (path as NSString).lastPathComponent, finderFlags: 0)
            let folder = isFolder ? path : (path as NSString).deletingLastPathComponent
            let controller: BrowserWindowController
            if let current = keyController, controllers.count > 0 {
                controller = makeWindow(path: folder, viewMode: current.activePane.viewMode)
                if let window = current.window, let newWindow = controller.window {
                    window.addTabbedWindow(newWindow, ordered: .above)
                }
            } else {
                controller = makeWindow(path: folder)
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            if !isFolder { controller.activePane.selectSoon(path, rename: false) }
        }
    }

    /// Services menu: "Open in Diski".
    @objc func openInDiski(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var paths = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .map { $0.path }
        if paths.isEmpty, let text = pasteboard.string(forType: .string) {
            paths = text.split(separator: "\n").map { (String($0) as NSString).expandingTildeInPath }
        }
        open(paths: paths)
        NSApp.activate()
    }

    // MARK: Windows & tabs

    var keyController: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? controllers.last
    }

    @discardableResult
    func makeWindow(path: String, viewMode: ViewMode? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(path: path, viewMode: viewMode)
        controllers.append(controller)
        if let previous = keyController?.window, let window = controller.window, previous !== window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        }
        return controller
    }

    func windowControllerDidClose(_ controller: BrowserWindowController) {
        DispatchQueue.main.async {
            self.controllers.removeAll { $0 === controller }
        }
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = makeWindow(path: Prefs.newWindowPath)
        controller.window?.tabbingMode = .disallowed
        controller.showWindow(nil)
        controller.window?.tabbingMode = .automatic
    }

    @objc func newTab(_ sender: Any?) {
        guard let current = keyController else {
            newWindow(sender)
            return
        }
        openTab(path: current.activePane.displayedPath, from: current)
    }

    func openTab(path: String, from controller: BrowserWindowController) {
        let new = makeWindow(path: path, viewMode: controller.activePane.viewMode)
        guard let window = controller.window, let newWindow = new.window else { return }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
        new.activePane.content.focus()
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openAirDrop(_ sender: Any?) {
        Self.openAirDropWindow()
    }

    static func openAirDropWindow() {
        let candidates = [
            "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app",
            "/System/Library/CoreServices/AirDrop.app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        NSSound.beep()
    }

    @objc func connectToServer(_ sender: Any?) {
        ConnectToServer.present(on: NSApp.keyWindow)
    }

    @objc func showShortcuts(_ sender: Any?) {
        ShortcutsWindow.show()
    }

    @objc func openWebsite(_ sender: Any?) {
        if let url = URL(string: "https://github.com/jordylegrand-cpu/Diski") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Keyboard shortcuts window

/// Help › Diski Keyboard Shortcuts: a plain native window with the shortcuts
/// in a two-column grid.
enum ShortcutsWindow {
    private static var window: NSWindow?

    private static let groups: [(String, [(String, String)])] = [
        ("Navigate", [
            ("⌘[ / ⌘]", "Back / Forward"),
            ("⌘↑", "Enclosing folder"),
            ("⌘↓ or ⌘O", "Open"),
            ("⇧⌘G", "Go to Folder (with completion)"),
            ("⇧⌘H / ⇧⌘D / ⇧⌘O / ⌥⌘L", "Home / Desktop / Documents / Downloads"),
            ("Type letters", "Jump to a file by name"),
            ("⌘F", "Filter this folder instantly"),
        ]),
        ("Files", [
            ("Return", "Rename (configurable to Open)"),
            ("Space", "Quick Look"),
            ("⌘I", "Get Info"),
            ("⌘C / ⌘X / ⌘V", "Copy / Cut / Paste (cut really moves)"),
            ("⌥⌘V", "Move here"),
            ("⌥⌘C", "Copy path"),
            ("⌘D", "Duplicate (instant on APFS)"),
            ("⇧⌘N / ⌥⌘N", "New folder / New text file"),
            ("⌘⌫ / ⌥⌘⌫", "Move to Trash / Delete immediately"),
            ("⌘Z", "Undo copy, move, rename, trash"),
        ]),
        ("View", [
            ("⌘1 – ⌘4", "Icons, List, Columns, Gallery"),
            ("⌘J", "View Options"),
            ("⇧⌘.", "Show hidden files"),
            ("⌘\\", "Dual pane · F5 copy · F6 move to other pane"),
            ("Tab", "Switch pane"),
            ("⇧⌘P / ⌥⌘P / ⌃⌘S", "Preview / Path bar / Sidebar"),
            ("⌥⌘T", "Show / hide toolbar"),
            ("⌘T / ⌘N", "New tab / New window"),
        ]),
    ]

    static func show() {
        if window == nil {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 18
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 22, right: 22)
            for (title, entries) in groups {
                let heading = NSTextField(labelWithString: title)
                heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                let grid = NSGridView(views: entries.map { keys, meaning in
                    let key = NSTextField(labelWithString: keys)
                    key.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                    let text = NSTextField(labelWithString: meaning)
                    text.font = .systemFont(ofSize: 12)
                    text.textColor = .secondaryLabelColor
                    return [key, text]
                })
                grid.rowSpacing = 6
                grid.columnSpacing = 16
                grid.column(at: 0).width = 190
                grid.rowAlignment = .firstBaseline
                let group = NSStackView(views: [heading, grid])
                group.orientation = .vertical
                group.alignment = .leading
                group.spacing = 8
                stack.addArrangedSubview(group)
            }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: stack.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = stack
            window.title = "Diski Keyboard Shortcuts"
            window.isReleasedWhenClosed = false
            // Not a browser tab, and no line under the title bar (nothing scrolls under it).
            window.tabbingMode = .disallowed
            window.titlebarSeparatorStyle = .none
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - CI screenshot driver

/// Lets the CI workflow put the app into specific states before taking
/// screenshots, via launch arguments such as `-DiskiCIMode YES -DiskiCIViewMode 1`.
/// Inert unless `DiskiCIMode` is set.
@MainActor
enum CIDriver {
    private static var defaults: UserDefaults { .standard }
    static var isEnabled: Bool { defaults.bool(forKey: "DiskiCIMode") }
    static var startPath: String? { isEnabled ? defaults.string(forKey: "DiskiCIPath") : nil }

    static func run(app: AppDelegate) {
        guard isEnabled, let controller = app.controllers.first, let window = controller.window else { return }
        if let appearance = defaults.string(forKey: "DiskiCIAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let screen = window.screen ?? NSScreen.main {
            // The whole screen below the menu bar: the Dock is hidden on CI but
            // may still be sliding away when the first window opens.
            var frame = screen.frame
            frame.size.height = screen.visibleFrame.maxY - frame.minY
            window.setFrame(frame.insetBy(dx: 10, dy: 8), display: true)
        }
        if let raw = defaults.string(forKey: "DiskiCIViewMode"), let mode = Int(raw), let viewMode = ViewMode(rawValue: mode) {
            controller.activePane.setViewMode(viewMode)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let pane = controller.activePane!
            if let names = defaults.string(forKey: "DiskiCIExpand"), let list = pane.content as? ListViewController {
                for name in names.split(separator: ",").map(String.init) {
                    if let item = pane.items.first(where: { $0.name == name }) {
                        list.outlineView.expandItem(item)
                    }
                }
            }
            if let name = defaults.string(forKey: "DiskiCISelect") {
                let parts = name.split(separator: "/").map(String.init)
                if let first = parts.first, let item = pane.items.first(where: { $0.name == first }) {
                    pane.content.select([item], scroll: true)
                    if parts.count > 1, pane.viewMode == .columns {
                        // Column view: walk down by name.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            pane.content.focus()
                        }
                    }
                }
            }
            if defaults.bool(forKey: "DiskiCIDualPane") {
                controller.toggleDualPane(nil)
            }
            if let text = defaults.string(forKey: "DiskiCISearch") {
                pane.setSearchText(text)
            }
            if let spec = defaults.string(forKey: "DiskiCICopy") {
                let parts = spec.split(separator: "|").map(String.init)
                if parts.count == 2 {
                    FileOperationManager.shared.copy([URL(fileURLWithPath: parts[0])], to: URL(fileURLWithPath: parts[1]))
                }
            }
            if defaults.bool(forKey: "DiskiCIShowOperations") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { controller.showOperations(nil) }
            }
            pane.content.focus()
            if defaults.bool(forKey: "DiskiCIViewOptions") {
                controller.showViewOptions(nil)
            }
            if defaults.bool(forKey: "DiskiCIGetInfo") {
                pane.getInfo(nil)
            }
        }
    }
}
