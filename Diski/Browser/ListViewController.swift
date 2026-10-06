import AppKit

enum ListColumn: String, CaseIterable {
    case name, modified, created, added, size, kind

    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .added: return "Date Added"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }

    var sortKey: SortKey {
        switch self {
        case .name: return .name
        case .modified: return .modified
        case .created: return .created
        case .added: return .added
        case .size: return .size
        case .kind: return .kind
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 420
        case .modified, .created, .added: return 168
        case .size: return 84
        case .kind: return 128
        }
    }

    var minWidth: CGFloat { self == .name ? 160 : 60 }
    var alignment: NSTextAlignment { self == .size ? .right : .left }

    init?(sortKey: SortKey) {
        switch sortKey {
        case .name: self = .name
        case .modified: self = .modified
        case .created: self = .created
        case .added: self = .added
        case .size: self = .size
        case .kind: self = .kind
        }
    }
}

/// Keyboard behavior shared by every view mode (Return, Space, Tab, ⌘↓...).
protocol FileViewKeyHandling: AnyObject {
    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool
}

final class FileOutlineView: NSOutlineView {
    weak var keyHandler: FileViewKeyHandling?
    private var lastTypeSelect: TimeInterval = 0

    override func keyDown(with event: NSEvent) {
        let typing = ProcessInfo.processInfo.systemUptime - lastTypeSelect < 1.0
        if keyHandler?.handleKeyDown(event, typeSelecting: typing) == true { return }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "." }) {
            lastTypeSelect = ProcessInfo.processInfo.systemUptime
        }
        super.keyDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        // Name fields only become first responder while renaming.
        if let field = responder as? NSTextField, !field.isEditable { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

// MARK: - Cells

final class NameCellView: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let tags = TagDotView()
    let loader = ItemImageLoader()
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.textColor = .labelColor
        name.cell?.truncatesLastVisibleLine = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tags.translatesAutoresizingMaskIntoConstraints = false
        tags.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(icon)
        addSubview(name)
        addSubview(tags)
        imageView = icon
        textField = name
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 26)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 26)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth, iconHeight,
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            tags.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 5),
            tags.centerYAnchor.constraint(equalTo: centerYAnchor),
            tags.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem, iconSize: CGFloat, dimmed: Bool) {
        objectValue = item
        iconWidth.constant = iconSize
        iconHeight.constant = iconSize
        name.stringValue = item.name
        name.isEditable = false
        name.toolTip = nil
        loader.load(item, into: icon, points: iconSize, thumbnails: Prefs.showThumbnailsInList)
        icon.alphaValue = (dimmed || item.isHidden) ? 0.5 : 1
        let label = item.labelIndex
        tags.colors = label > 0 ? [TagColors.color(forLabel: label)] : []
    }

    func beginEditing(delegate: NSTextFieldDelegate) {
        guard let window else { return }
        name.isEditable = true
        name.isSelectable = true
        name.delegate = delegate
        name.lineBreakMode = .byClipping
        window.makeFirstResponder(name)
        if let editor = name.currentEditor() {
            editor.selectedRange = NameCellView.editableRange(for: name.stringValue)
        }
    }

    func endEditing() {
        name.isEditable = false
        name.isSelectable = false
        name.lineBreakMode = .byTruncatingMiddle
    }

    /// Finder selects the name without its extension when renaming.
    static func editableRange(for name: String) -> NSRange {
        let ns = name as NSString
        let ext = ns.pathExtension
        if ext.isEmpty || ext.count > 8 || name.hasPrefix(".") && ns.range(of: ".", options: .backwards).location == 0 {
            return NSRange(location: 0, length: ns.length)
        }
        return NSRange(location: 0, length: ns.length - (ext as NSString).length - 1)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader.cancel()
    }
}

final class TextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - List view

final class ListViewController: FileViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                NSMenuDelegate, NSTextFieldDelegate, FileViewKeyHandling {
    let outlineView = FileOutlineView()
    private let scrollView = NSScrollView()
    private let contextMenu = NSMenu()
    private let headerMenu = NSMenu()

    /// Arranged children of expanded folders, by folder path.
    private var childCache: [String: [FileItem]] = [:]
    private var expanded: [String: FileItem] = [:]
    private var renamingItem: FileItem?
    private var draggedItems: [FileItem] = []
    private var isApplyingSort = false
    /// Flat search results: no disclosure triangles.
    var isFlat = false

    private static let nameCellID = NSUserInterfaceItemIdentifier("NameCell")
    private static let textCellID = NSUserInterfaceItemIdentifier("TextCell")

    override func loadView() {
        let density = Prefs.rowDensity
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.allowsTypeSelect = true
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = false
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = density.rowHeight
        outlineView.intercellSpacing = NSSize(width: 6, height: 4)
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.keyHandler = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        outlineView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        outlineView.registerForDraggedTypes(PaneViewController.acceptedDragTypes)
        outlineView.draggingDestinationFeedbackStyle = .regular

        contextMenu.delegate = self
        outlineView.menu = contextMenu
        headerMenu.delegate = self

        buildColumns()
        outlineView.autosaveName = "DiskiListColumns"
        outlineView.autosaveTableColumns = true

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        view = scrollView

        NotificationCenter.default.addObserver(self, selector: #selector(directoryDidUpdate(_:)),
                                               name: DirectoryStore.didUpdate, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for path in expanded.keys { DirectoryStore.shared.endWatching(path) }
    }

    private func buildColumns() {
        for column in outlineView.tableColumns { outlineView.removeTableColumn(column) }
        var columns: [ListColumn] = [.name]
        columns += Prefs.listColumns.compactMap { ListColumn(rawValue: $0) }.filter { $0 != .name }
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minWidth
            tableColumn.maxWidth = column == .name ? 4000 : 600
            tableColumn.headerCell.alignment = column.alignment
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue,
                                                                   ascending: column.sortKey.defaultAscending)
            tableColumn.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            outlineView.addTableColumn(tableColumn)
            if column == .name { outlineView.outlineTableColumn = tableColumn }
        }
        outlineView.headerView?.menu = headerMenu
        syncSortIndicator()
    }

    func syncSortIndicator() {
        guard let options = pane?.arrangeOptions else { return }
        isApplyingSort = true
        outlineView.sortDescriptors = [NSSortDescriptor(key: options.sortKey.rawValue, ascending: options.ascending)]
        isApplyingSort = false
    }

    // MARK: Display

    override func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {
        guard isViewLoaded else { return }
        if reset {
            collapseAllWatching()
            outlineView.reloadData()
            outlineView.scrollRowToVisible(0)
            syncSortIndicator()
            return
        }
        if let changes, !changes.isInitialLoad {
            applyDiff(old: previous, new: items, parent: nil)
            for item in changes.updated where outlineView.row(forItem: item) >= 0 {
                outlineView.reloadItem(item, reloadChildren: false)
            }
            return
        }
        // Re-sorted or re-filtered: rebuild everything, keep selection and expansion.
        let selection = selectedItems
        childCache.removeAll()
        outlineView.reloadData()
        select(selection, scroll: false)
        syncSortIndicator()
    }

    private func collapseAllWatching() {
        for path in expanded.keys { DirectoryStore.shared.endWatching(path) }
        expanded.removeAll()
        childCache.removeAll()
    }

    private func applyDiff(old: [FileItem], new: [FileItem], parent: FileItem?) {
        let difference = new.difference(from: old)
        if difference.count > 400 {
            let selection = selectedItems
            outlineView.reloadItem(parent, reloadChildren: true)
            select(selection, scroll: false)
            return
        }
        var removed = IndexSet()
        var inserted = IndexSet()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        guard !removed.isEmpty || !inserted.isEmpty else { return }
        outlineView.beginUpdates()
        if !removed.isEmpty { outlineView.removeItems(at: removed, inParent: parent, withAnimation: .effectFade) }
        if !inserted.isEmpty { outlineView.insertItems(at: inserted, inParent: parent, withAnimation: .effectFade) }
        outlineView.endUpdates()
        pane?.viewSelectionDidChange(self)
    }

    @objc private func directoryDidUpdate(_ notification: Notification) {
        guard let listing = notification.object as? DirectoryStore.Listing,
              let old = childCache[listing.path],
              let folder = expanded[listing.path],
              let pane else { return }
        let new = pane.arrange(listing.items)
        childCache[listing.path] = new
        applyDiff(old: old, new: new, parent: folder)
        if let changes = notification.userInfo?["changes"] as? DirectoryStore.Changes {
            for item in changes.updated where outlineView.row(forItem: item) >= 0 {
                outlineView.reloadItem(item, reloadChildren: false)
            }
        }
    }

    private func children(of folder: FileItem) -> [FileItem] {
        if let cached = childCache[folder.path] { return cached }
        let listing = DirectoryStore.shared.loadNow(folder.path)
        let arranged = pane?.arrange(listing.items) ?? listing.items
        childCache[folder.path] = arranged
        return arranged
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let folder = item as? FileItem { return children(of: folder).count }
        return items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let folder = item as? FileItem { return children(of: folder)[index] }
        return items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard !isFlat, let file = item as? FileItem else { return false }
        return file.isNavigable && file.childCount != 0
    }

    // MARK: Expansion

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? FileItem else { return }
        if expanded[item.path] == nil {
            expanded[item.path] = item
            DirectoryStore.shared.beginWatching(item.path)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? FileItem else { return }
        let prefix = item.path + "/"
        for path in Array(expanded.keys) where path == item.path || path.hasPrefix(prefix) {
            expanded.removeValue(forKey: path)
            childCache.removeValue(forKey: path)
            DirectoryStore.shared.endWatching(path)
        }
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FileItem, let tableColumn,
              let column = ListColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        if column == .name {
            let cell = outlineView.makeView(withIdentifier: Self.nameCellID, owner: self) as? NameCellView
                ?? { let c = NameCellView(); c.identifier = Self.nameCellID; return c }()
            cell.configure(item, iconSize: Prefs.rowDensity.iconSize, dimmed: pane?.isCut(item) ?? false)
            if pane?.isSearchResults == true { cell.name.toolTip = item.path }
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: Self.textCellID, owner: self) as? TextCellView
            ?? { let c = TextCellView(); c.identifier = Self.textCellID; return c }()
        cell.label.alignment = column.alignment
        cell.label.stringValue = text(for: item, column: column)
        return cell
    }

    private func text(for item: FileItem, column: ListColumn) -> String {
        switch column {
        case .name: return item.name
        case .modified: return Formatters.listDate(item.modified)
        case .created: return Formatters.listDate(item.created)
        case .added: return item.added > 0 ? Formatters.listDate(item.added) : "--"
        case .kind: return FileKinds.kind(for: item)
        case .size:
            let size = item.displaySize
            if size >= 0 { return Formatters.size(size) }
            if item.type == .directory || item.type == .package { requestSize(for: item) }
            return "--"
        }
    }

    private func requestSize(for item: FileItem) {
        guard Prefs.calculateFolderSizes, !isFlat || item.type == .package else { return }
        if let cached = FolderSizer.shared.cached(item.path) {
            item.computedFolderSize = cached.bytes
            return
        }
        guard !FolderSizer.shared.isComputing(item.path) else { return }
        FolderSizer.shared.size(of: item.path) { [weak self, weak item] result in
            guard let self, let item else { return }
            item.computedFolderSize = result.bytes
            self.reloadSizeCell(for: item)
        }
    }

    private func reloadSizeCell(for item: FileItem) {
        let row = outlineView.row(forItem: item)
        let column = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.size.rawValue))
        guard row >= 0, column >= 0 else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        if pane?.arrangeOptions.sortKey == .size { pane?.scheduleResort() }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier.rawValue == ListColumn.name.rawValue else { return nil }
        return (item as? FileItem)?.name
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        notifySelectionChanged()
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSort, let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key, let sortKey = SortKey(rawValue: key) else { return }
        pane?.setSort(sortKey, ascending: descriptor.ascending)
    }

    // MARK: Selection API

    override var selectedItems: [FileItem] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileItem }
    }

    override func select(_ items: [FileItem], scroll: Bool) {
        var rows = IndexSet()
        for item in items {
            let row = outlineView.row(forItem: item)
            if row >= 0 { rows.insert(row) }
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { outlineView.scrollRowToVisible(first) }
    }

    override func selectAllItems() { outlineView.selectAll(nil) }
    override func deselectAllItems() { outlineView.deselectAll(nil) }

    override func focus() {
        view.window?.makeFirstResponder(outlineView)
    }

    override func refresh(_ items: [FileItem]) {
        for item in items where outlineView.row(forItem: item) >= 0 {
            outlineView.reloadItem(item, reloadChildren: false)
        }
    }

    override func appearanceSettingsDidChange() {
        outlineView.rowHeight = Prefs.rowDensity.rowHeight
        let current = outlineView.tableColumns.compactMap { ListColumn(rawValue: $0.identifier.rawValue) }.filter { $0 != .name }
        let wanted = Prefs.listColumns.compactMap { ListColumn(rawValue: $0) }
        if Set(current) != Set(wanted) {
            buildColumns()
        }
        let selection = selectedItems
        outlineView.reloadData()
        select(selection, scroll: false)
    }

    override func iconScreenRect(for item: FileItem) -> NSRect? {
        let row = outlineView.row(forItem: item)
        guard row >= 0, let window = view.window,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView else { return nil }
        let rect = cell.icon.convert(cell.icon.bounds, to: nil)
        return window.convertToScreen(rect)
    }

    // MARK: Opening

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileItem else { return }
        let inNewTab = NSEvent.modifierFlags.contains(.command)
        pane?.open([item], inNewTab: inNewTab)
    }

    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool {
        pane?.handleKeyDown(event, typeSelecting: typeSelecting) ?? false
    }

    // MARK: Rename

    override func beginRename(_ item: FileItem) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        let column = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.name.rawValue))
        guard column >= 0,
              let cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView else { return }
        renamingItem = item
        cell.beginEditing(delegate: self)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let item = renamingItem else { return }
        renamingItem = nil
        let newName = field.stringValue
        (field.superview as? NameCellView)?.endEditing()
        view.window?.makeFirstResponder(outlineView)
        if newName != item.name {
            if pane?.commitRename(item, to: newName) != true { field.stringValue = item.name }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let item = renamingItem,
           let field = control as? NSTextField {
            renamingItem = nil
            field.abortEditing()
            field.stringValue = item.name
            (field.superview as? NameCellView)?.endEditing()
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerMenu {
            buildHeaderMenu()
            return
        }
        menu.removeAllItems()
        let row = outlineView.clickedRow
        var targets: [FileItem] = []
        if row >= 0, let item = outlineView.item(atRow: row) as? FileItem {
            if outlineView.selectedRowIndexes.contains(row) {
                targets = selectedItems
            } else {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                targets = [item]
            }
        }
        pane?.populateContextMenu(menu, for: targets)
    }

    private func buildHeaderMenu() {
        headerMenu.removeAllItems()
        let visible = Set(outlineView.tableColumns.map { $0.identifier.rawValue })
        for column in ListColumn.allCases where column != .name {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = visible.contains(column.rawValue) ? .on : .off
            headerMenu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = ListColumn(rawValue: raw) else { return }
        var columns = Prefs.listColumns
        if let index = columns.firstIndex(of: raw) {
            columns.remove(at: index)
            if let tableColumn = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw)) {
                outlineView.removeTableColumn(tableColumn)
            }
        } else {
            columns.append(raw)
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(raw))
            tableColumn.title = column.title
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minWidth
            tableColumn.headerCell.alignment = column.alignment
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue,
                                                                   ascending: column.sortKey.defaultAscending)
            tableColumn.resizingMask = .userResizingMask
            outlineView.addTableColumn(tableColumn)
        }
        Prefs.listColumns = columns
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileItem)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        self.draggedItems = draggedItems.compactMap { $0 as? FileItem }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .delete {
            pane?.trash(draggedItems.map { $0.url })
        }
        draggedItems = []
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let pane else { return [] }
        var target = item as? FileItem
        if let candidate = target, !candidate.isNavigable {
            target = outlineView.parent(forItem: candidate) as? FileItem
        }
        if pane.isSearchResults && target == nil { return [] }
        let destination = target?.path ?? directoryPath
        let operation = pane.dragOperation(for: info, destination: destination)
        if operation.isEmpty { return [] }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let destination = (item as? FileItem)?.path ?? directoryPath
        return pane?.performDrop(info, destination: destination) ?? false
    }
}
