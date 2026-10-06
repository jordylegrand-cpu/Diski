import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [NSWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let controller = SkeletonWindowController()
        windowControllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

final class SkeletonWindowController: NSWindowController, NSToolbarDelegate {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = NSHomeDirectory()
        window.toolbarStyle = .unified
        super.init(window: window)

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: PlaceholderViewController(text: "Sidebar"))
        let content = NSSplitViewItem(viewController: PlaceholderViewController(text: "Content"))
        let inspector = NSSplitViewItem(inspectorWithViewController: PlaceholderViewController(text: "Inspector"))
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(content)
        split.addSplitViewItem(inspector)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 720))

        let toolbar = NSToolbar(identifier: "Skeleton")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private let navID = NSToolbarItem.Identifier("nav")
    private let modeID = NSToolbarItem.Identifier("mode")
    private let searchID = NSToolbarItem.Identifier("search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, navID, .flexibleSpace, modeID, searchID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case navID:
            let images = ["chevron.left", "chevron.right"].compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            let group = NSToolbarItemGroup(itemIdentifier: navID, images: images, selectionMode: .momentary, labels: ["Back", "Forward"], target: nil, action: nil)
            group.isNavigational = true
            return group
        case modeID:
            let images = ["square.grid.2x2", "list.bullet", "rectangle.split.3x1", "squares.below.rectangle"].compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            let group = NSToolbarItemGroup(itemIdentifier: modeID, images: images, selectionMode: .selectOne, labels: ["Icons", "List", "Columns", "Gallery"], target: nil, action: nil)
            group.selectedIndex = 1
            return group
        case searchID:
            let item = NSSearchToolbarItem(itemIdentifier: searchID)
            item.preferredWidthForSearchField = 240
            return item
        default:
            return nil
        }
    }
}

final class PlaceholderViewController: NSViewController {
    private let text: String
    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        view = container
    }
}
