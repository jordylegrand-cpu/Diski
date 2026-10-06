import AppKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarDidSelect(path: String)
    func sidebarDidSelectTag(_ tag: String)
    func sidebarDidSelectRecents()
    func sidebarRequestsDrop(_ info: NSDraggingInfo, destination: String) -> Bool
    func sidebarDragOperation(_ info: NSDraggingInfo, destination: String) -> NSDragOperation
}

final class SidebarSection {
    let id: String
    let title: String
    var entries: [SidebarEntry] = []
    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

final class SidebarEntry {
    enum Kind: Equatable {
        case recents, favorite, home, iCloud, volume, airDrop, network, trash, tag(Int)
    }

    let kind: Kind
    let title: String
    let path: String?
    let image: NSImage?
    var volume: VolumeInfo?

    init(kind: Kind, title: String, path: String?, image: NSImage?, volume: VolumeInfo? = nil) {
        self.kind = kind
        self.title = title
        self.path = path
        self.image = image
        self.volume = volume
    }

}

/// Sidebar glyphs: plain SF Symbols; the source list sizes and tints them.
enum SidebarIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(symbol: String) -> NSImage? {
        if let cached = cache[symbol] { return cached }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let image { cache[symbol] = image }
        return image
    }

    static func image(forFolder path: String) -> NSImage? {
        let home = NSHomeDirectory()
        switch path {
        case "/Applications", home + "/Applications": return image(symbol: "square.stack.3d.up")
        case home + "/Desktop": return image(symbol: "menubar.dock.rectangle")
        case home + "/Documents": return image(symbol: "doc")
        case home + "/Downloads": return image(symbol: "arrow.down.circle")
        case home + "/Movies": return image(symbol: "film")
        case home + "/Music": return image(symbol: "music.note")
        case home + "/Pictures": return image(symbol: "photo")
        case home + "/Developer": return image(symbol: "hammer")
        case home + "/Library": return image(symbol: "building.columns")
        case home: return image(symbol: "house")
        case "/Applications/Utilities": return image(symbol: "wrench.and.screwdriver")
        case "/": return image(symbol: "internaldrive")
        default: return image(symbol: "folder")
        }
    }
}

/// The standard source-list cell (image and text, like AppKit's own
/// "Image & Text Table Cell View"): the outline view sets its font, row
/// height, symbol size and colors from the system sidebar settings.
final class SidebarCellView: NSTableCellView {
    let eject = NSButton()
    var onEject: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        eject.translatesAutoresizingMaskIntoConstraints = false
        eject.bezelStyle = .inline
        eject.isBordered = false
        eject.image = NSImage(systemSymbolName: "eject", accessibilityDescription: "Eject")
        eject.target = self
        eject.action = #selector(ejectClicked)
        eject.toolTip = "Eject"
        addSubview(icon)
        addSubview(label)
        addSubview(eject)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            eject.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            eject.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func ejectClicked() { onEject?() }
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var delegate: SidebarViewControllerDelegate?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var sections: [SidebarSection] = []
    private var isHighlighting = false
    private var highlightedPath: String?
    private var topEntries: [SidebarEntry] = []
    /// Stands for Recents in `highlight(path:)`.
    static let recentsMarker = "diski:recents"
    private let contextMenu = NSMenu()
    private static let favoriteDragType = NSPasteboard.PasteboardType("app.diski.sidebar-favorite")

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        // The system's sidebar sizes (System Settings › Appearance), exactly
        // like Finder's sidebar on the same Mac.
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = 0
        outlineView.autoresizesOutlineColumn = false
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes(PaneViewController.acceptedDragTypes + [Self.favoriteDragType])
        outlineView.setDraggingSourceOperationMask([.move, .generic], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Below the toolbar, like Finder's sidebar (no scroll edge line).
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: 600))
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        rebuild()
        for section in sections { outlineView.expandItem(section) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sourcesChanged), name: VolumeMonitor.didChange, object: nil)
        center.addObserver(self, selector: #selector(sourcesChanged), name: Prefs.didChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Model

    private var lastFavorites: [String] = []

    @objc private func sourcesChanged() {
        // Prefs changes are frequent; only rebuild when the sidebar content changed.
        if Prefs.favorites == lastFavorites && sections.count == 3 && volumesUnchanged() { return }
        let expanded = sections.filter { outlineView.isItemExpanded($0) }.map { $0.id }
        rebuild()
        for section in sections where expanded.contains(section.id) || expanded.isEmpty {
            outlineView.expandItem(section)
        }
        highlight(path: highlightedPath)
    }

    private var lastVolumes: [VolumeInfo] = []

    private func volumesUnchanged() -> Bool {
        VolumeMonitor.shared.volumes.map { $0.path } == lastVolumes.map { $0.path }
    }

    private func rebuild() {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        lastFavorites = Prefs.favorites
        lastVolumes = VolumeMonitor.shared.volumes

        // Like Finder: Recents above the sections, without a title.
        topEntries = [SidebarEntry(kind: .recents, title: "Recents", path: Self.recentsMarker,
                                   image: SidebarIcons.image(symbol: "clock"))]

        let favorites = SidebarSection(id: "favorites", title: "Favorites")
        for path in lastFavorites where fm.fileExists(atPath: path) {
            favorites.entries.append(SidebarEntry(kind: .favorite, title: fm.displayName(atPath: path), path: path,
                                                  image: SidebarIcons.image(forFolder: path)))
        }

        let locations = SidebarSection(id: "locations", title: "Locations")
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if fm.fileExists(atPath: iCloud) {
            locations.entries.append(SidebarEntry(kind: .iCloud, title: "iCloud Drive", path: iCloud,
                                                  image: SidebarIcons.image(symbol: "icloud")))
        }
        locations.entries.append(SidebarEntry(kind: .home, title: NSUserName(), path: home,
                                              image: SidebarIcons.image(symbol: "house")))
        let volumes = lastVolumes
        for volume in volumes where volume.isInternal {
            locations.entries.append(SidebarEntry(kind: .volume, title: volume.name, path: volume.path,
                                                  image: SidebarIcons.image(symbol: "internaldrive"),
                                                  volume: volume))
        }
        locations.entries.append(SidebarEntry(kind: .airDrop, title: "AirDrop", path: nil,
                                              image: SidebarIcons.image(symbol: "dot.radiowaves.left.and.right")))
        for volume in volumes where !volume.isInternal {
                        let symbol = volume.isLocal ? "externaldrive" : "server.rack"
            locations.entries.append(SidebarEntry(kind: .volume, title: volume.name, path: volume.path,
                                                  image: SidebarIcons.image(symbol: symbol), volume: volume))
        }
        locations.entries.append(SidebarEntry(kind: .network, title: "Network", path: "/Network",
                                              image: SidebarIcons.image(symbol: "network")))
        locations.entries.append(SidebarEntry(kind: .trash, title: "Trash", path: FileOperationManager.trashURL.path,
                                              image: SidebarIcons.image(symbol: "trash")))

        let tags = SidebarSection(id: "tags", title: "Tags")
        for index in TagColors.sidebarOrder {
            tags.entries.append(SidebarEntry(kind: .tag(index), title: TagColors.names[index], path: nil,
                                             image: PaneViewController.dotImage(TagColors.color(forLabel: index), size: 12)))
        }
        sections = [favorites, locations, tags]
        outlineView.reloadData()
    }

    // MARK: Highlighting the current location

    func highlight(path: String?) {
        highlightedPath = path
        guard isViewLoaded else { return }
        isHighlighting = true
        defer { isHighlighting = false }
        guard let path else {
            outlineView.deselectAll(nil)
            return
        }
        for entries in [topEntries] + sections.map({ $0.entries }) {
            if let entry = entries.first(where: { $0.path == path }) {
                let row = outlineView.row(forItem: entry)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
        }
        outlineView.deselectAll(nil)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let section = item as? SidebarSection { return section.entries.count }
        return item == nil ? topEntries.count + sections.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = item as? SidebarSection { return section.entries[index] }
        return index < topEntries.count ? topEntries[index] : sections[index - topEntries.count]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarEntry
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = section.title
            return cell
        }
        guard let entry = item as? SidebarEntry else { return nil }
        let id = NSUserInterfaceItemIdentifier("EntryCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? SidebarCellView ?? {
            let cell = SidebarCellView()
            cell.identifier = id
            return cell
        }()
        cell.textField?.stringValue = entry.title
        cell.imageView?.image = entry.image
        let ejectable = entry.volume.map { !$0.isRoot && ($0.isEjectable || $0.isRemovable || !$0.isLocal || !$0.isInternal) } ?? false
        cell.eject.isHidden = !ejectable
        cell.onEject = { [weak self] in
            guard let volume = entry.volume else { return }
            VolumeMonitor.shared.eject(volume) { error in
                if let error { self?.presentError(error) }
            }
        }
        if let volume = entry.volume, volume.totalCapacity > 0 {
            cell.toolTip = "\(Formatters.size(volume.availableCapacity)) available of \(Formatters.size(volume.totalCapacity))"
        } else {
            cell.toolTip = entry.path
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isHighlighting, let entry = outlineView.item(atRow: outlineView.selectedRow) as? SidebarEntry else { return }
        switch entry.kind {
        case .recents:
            highlightedPath = Self.recentsMarker
            delegate?.sidebarDidSelectRecents()
        case .airDrop:
            AppDelegate.openAirDropWindow()
            highlight(path: highlightedPath)
        case .tag(let index):
            delegate?.sidebarDidSelectTag(TagColors.names[index])
        default:
            if let path = entry.path {
                highlightedPath = path
                delegate?.sidebarDidSelect(path: path)
            }
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let entry = outlineView.item(atRow: row) as? SidebarEntry else { return }
        if let path = entry.path {
            let open = NSMenuItem(title: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "")
            open.representedObject = path
            open.target = self
            menu.addItem(open)
            let reveal = NSMenuItem(title: "Show in Enclosing Folder", action: #selector(showInEnclosingFolder(_:)), keyEquivalent: "")
            reveal.representedObject = path
            reveal.target = self
            menu.addItem(reveal)
        }
        if entry.kind == .favorite, let path = entry.path {
            menu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove from Sidebar", action: #selector(removeFavorite(_:)), keyEquivalent: "")
            remove.representedObject = path
            remove.target = self
            menu.addItem(remove)
        }
        if let volume = entry.volume, !volume.isRoot {
            menu.addItem(.separator())
            let eject = NSMenuItem(title: "Eject “\(volume.name)”", action: #selector(ejectVolume(_:)), keyEquivalent: "")
            eject.representedObject = volume.path
            eject.target = self
            menu.addItem(eject)
        }
        if entry.kind == .trash {
            menu.addItem(.separator())
            let empty = NSMenuItem(title: "Empty Trash…", action: #selector(PaneViewController.emptyTrash(_:)), keyEquivalent: "")
            menu.addItem(empty)
        }
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let controller = view.window?.windowController as? BrowserWindowController else { return }
        (NSApp.delegate as? AppDelegate)?.openTab(path: path, from: controller)
    }

    @objc private func showInEnclosingFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let controller = view.window?.windowController as? BrowserWindowController else { return }
        controller.activePane.navigate(to: (path as NSString).deletingLastPathComponent, select: [path])
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        Prefs.favorites = Prefs.favorites.filter { $0 != path }
    }

    @objc private func ejectVolume(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let volume = VolumeMonitor.shared.volumes.first(where: { $0.path == path }) else { return }
        VolumeMonitor.shared.eject(volume) { [weak self] error in
            if let error { self?.presentError(error) }
        }
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let entry = item as? SidebarEntry, entry.kind == .favorite, let path = entry.path else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        pasteboardItem.setString(path, forType: Self.favoriteDragType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        // Between rows in Favorites: add or reorder folders.
        if let section = item as? SidebarSection, section.id == "favorites", index != NSOutlineViewDropOnItemIndex {
            if pasteboard.availableType(from: [Self.favoriteDragType]) != nil { return .move }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            return folders.isEmpty ? [] : .link
        }
        // Onto a location: move/copy/trash into it.
        guard pasteboard.availableType(from: [Self.favoriteDragType]) == nil,
              let entry = item as? SidebarEntry, index == NSOutlineViewDropOnItemIndex, let path = entry.path else { return [] }
        if case .tag = entry.kind { return [] }
        return delegate?.sidebarDragOperation(info, destination: path) ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pasteboard = info.draggingPasteboard
        if let section = item as? SidebarSection, section.id == "favorites", index != NSOutlineViewDropOnItemIndex {
            var favorites = Prefs.favorites.filter { FileManager.default.fileExists(atPath: $0) }
            var insertAt = min(index, favorites.count)
            if let moving = pasteboard.string(forType: Self.favoriteDragType) {
                if let old = favorites.firstIndex(of: moving) {
                    favorites.remove(at: old)
                    if old < insertAt { insertAt -= 1 }
                }
                favorites.insert(moving, at: min(insertAt, favorites.count))
            } else {
                let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                for url in urls.reversed() where !favorites.contains(url.path) {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        favorites.insert(url.path, at: min(insertAt, favorites.count))
                    }
                }
            }
            Prefs.favorites = favorites
            return true
        }
        guard let entry = item as? SidebarEntry, let path = entry.path else { return false }
        return delegate?.sidebarRequestsDrop(info, destination: path) ?? false
    }
}
