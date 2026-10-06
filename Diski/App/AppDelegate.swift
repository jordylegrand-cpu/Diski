import AppKit
import SwiftUI

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
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        _ = VolumeMonitor.shared
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            Formatters.refreshDayBoundaries()
        }

        if !pendingPaths.isEmpty {
            let paths = pendingPaths
            pendingPaths = []
            open(paths: paths)
        } else if controllers.isEmpty {
            let start = CIDriver.startPath ?? Prefs.newWindowPath
            let controller = makeWindow(path: FileManager.default.fileExists(atPath: start) ? start : NSHomeDirectory())
            controller.showWindow(nil)
        }
        CIDriver.run(app: self)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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

struct ShortcutsView: View {
    private let groups: [(String, [(String, String)])] = [
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
            ("⇧⌘.", "Show hidden files"),
            ("⌘\\", "Dual pane · F5 copy · F6 move to other pane"),
            ("Tab", "Switch pane"),
            ("⇧⌘P / ⌥⌘P / ⌥⌘S", "Preview / Path bar / Sidebar"),
            ("⌘T / ⌘N", "New tab / New window"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.0).font(.system(size: 13, weight: .semibold))
                        ForEach(group.1, id: \.0) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.0)
                                    .font(.system(size: 12, design: .rounded).weight(.medium))
                                    .frame(width: 190, alignment: .leading)
                                Text(entry.1)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .frame(width: 520, height: 560)
    }
}

enum ShortcutsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ShortcutsView()))
            window.title = "Diski Keyboard Shortcuts"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
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
            window.setFrame(screen.visibleFrame.insetBy(dx: 10, dy: 8), display: true)
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
        }
    }
}
