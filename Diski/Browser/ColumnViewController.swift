import AppKit

final class ColumnTableView: NSTableView {
    weak var keyHandler: FileViewKeyHandling?
    var onBecomeFirstResponder: (() -> Void)?
    var onArrow: ((_ left: Bool) -> Bool)?
    private var lastTypeSelect: TimeInterval = 0

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let typing = ProcessInfo.processInfo.systemUptime - lastTypeSelect < 1.0
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty, event.keyCode == 123 || event.keyCode == 124 {
            if onArrow?(event.keyCode == 123) == true { return }
        }
        if keyHandler?.handleKeyDown(event, typeSelecting: typing) == true { return }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty, flags.isEmpty || flags == .shift,
           chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "." }) {
            lastTypeSelect = ProcessInfo.processInfo.systemUptime
        }
        super.keyDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, !field.isEditable { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

final class ColumnCellView: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let chevron = NSImageView()
    let tags = TagDotView()
    let loader = ItemImageLoader()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [icon, name, chevron, tags] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            tags.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 4),
            tags.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: tags.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem, dimmed: Bool) {
        objectValue = item
        name.stringValue = item.name
        name.isEditable = false
        chevron.isHidden = !item.isNavigable
        loader.load(item, into: icon, points: 17, thumbnails: false)
        icon.alphaValue = (dimmed || item.isHidden) ? 0.5 : 1
        let label = item.labelIndex
        tags.colors = label > 0 ? [TagColors.color(forLabel: label)] : []
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { chevron.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader.cancel()
    }
}

/// The last column when a file is selected: a big preview and key facts.
final class ColumnPreviewView: NSView {
    private let image = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let loader = ItemImageLoader()

    init(item: FileItem) {
        super.init(frame: .zero)
        let stack = NSStackView(views: [image, title, subtitle, info])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        title.maximumNumberOfLines = 3
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.alignment = .center
        addSubview(stack)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 180),
            image.heightAnchor.constraint(equalToConstant: 180),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            info.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        title.stringValue = item.name
        let size = item.displaySize >= 0 ? " – " + Formatters.size(item.displaySize) : ""
        subtitle.stringValue = FileKinds.kind(for: item) + size
        info.stringValue = "Created \(Formatters.longDate(item.createdDate))\nModified \(Formatters.longDate(item.modifiedDate))"
        loader.load(item, into: image, points: 180, thumbnails: true)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Finder's column view: one column per folder from the volume root down,
/// with a preview column when a file is selected.
final class ColumnViewController: FileViewController, NSTableViewDataSource, NSTableViewDelegate,
                                  NSMenuDelegate, NSTextFieldDelegate, FileViewKeyHandling {
    final class Column {
        let path: String
        var items: [FileItem]
        let scroll = NSScrollView()
        let table = ColumnTableView()
        let separator = NSBox()
        var widthConstraint: NSLayoutConstraint?

        init(path: String, items: [FileItem]) {
            self.path = path
            self.items = items
        }
    }

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var columns: [Column] = []
    private var preview: NSView?
    private(set) var activeColumn = 0
    private var isSyncing = false
    private var renamingItem: FileItem?
    private let contextMenu = NSMenu()
    private var draggedItems: [FileItem] = []
    private static let cellID = NSUserInterfaceItemIdentifier("ColumnCell")
    private let columnWidth: CGFloat = 236

    override func loadView() {
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.distribution = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: clip.widthAnchor),
        ])
        contextMenu.delegate = self
        view = scrollView
        NotificationCenter.default.addObserver(self, selector: #selector(directoryDidUpdate(_:)),
                                               name: DirectoryStore.didUpdate, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for column in columns { DirectoryStore.shared.endWatching(column.path) }
    }

    override func willDeactivate() {
        for column in columns { DirectoryStore.shared.endWatching(column.path) }
        columns.removeAll()
    }

    /// The deepest folder shown (window title, path bar).
    var deepestPath: String { columns.last?.path ?? directoryPath }

    override var targetDirectory: String {
        guard activeColumn < columns.count else { return deepestPath }
        return columns[activeColumn].path
    }

    // MARK: Building

    override func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {
        guard isViewLoaded else { return }
        if reset || columns.isEmpty || !columns.contains(where: { $0.path == directoryPath }) {
            rebuild(to: directoryPath)
        } else if changes == nil {
            // Sort or visibility changed: re-arrange every column.
            for column in columns {
                let listing = DirectoryStore.shared.listing(for: column.path)
                replaceItems(of: column, with: pane?.arrange(listing.items) ?? listing.items)
            }
        }
    }

    private func rebuild(to path: String) {
        isSyncing = true
        defer { isSyncing = false }
        for column in columns {
            DirectoryStore.shared.endWatching(column.path)
            column.scroll.removeFromSuperview()
            column.separator.removeFromSuperview()
        }
        columns.removeAll()
        removePreview()

        let root = VolumeMonitor.shared.volume(containing: path)?.path ?? "/"
        var chain: [String] = []
        var current = path
        while true {
            chain.insert(current, at: 0)
            if current == root || current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        for (index, directory) in chain.enumerated() {
            let arranged: [FileItem]
            if directory == path {
                arranged = items
            } else {
                let listing = DirectoryStore.shared.loadNow(directory)
                arranged = pane?.arrange(listing.items) ?? listing.items
            }
            let column = addColumn(path: directory, items: arranged)
            if index + 1 < chain.count, let row = column.items.firstIndex(where: { $0.path == chain[index + 1] }) {
                column.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                column.table.scrollRowToVisible(row)
            }
        }
        activeColumn = max(0, columns.count - 1)
        scrollToEnd(animated: false)
    }

    @discardableResult
    private func addColumn(path: String, items: [FileItem]) -> Column {
        let column = Column(path: path, items: items)
        let table = column.table
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.keyHandler = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.menu = contextMenu
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        table.registerForDraggedTypes(PaneViewController.acceptedDragTypes)
        table.onBecomeFirstResponder = { [weak self, weak column] in
            guard let self, let column, let index = self.columns.firstIndex(where: { $0 === column }) else { return }
            if self.activeColumn != index {
                self.activeColumn = index
                self.notifySelectionChanged()
            }
        }
        table.onArrow = { [weak self, weak column] left in
            guard let self, let column, let index = self.columns.firstIndex(where: { $0 === column }) else { return false }
            return self.handleArrow(left: left, from: index)
        }

        column.scroll.documentView = table
        column.scroll.hasVerticalScroller = true
        column.scroll.autohidesScrollers = true
        column.scroll.drawsBackground = false
        column.scroll.borderType = .noBorder
        column.scroll.translatesAutoresizingMaskIntoConstraints = false
        column.separator.boxType = .separator
        column.separator.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(column.scroll)
        stack.addArrangedSubview(column.separator)
        let width = column.scroll.widthAnchor.constraint(equalToConstant: columnWidth)
        width.isActive = true
        column.widthConstraint = width
        NSLayoutConstraint.activate([
            column.scroll.heightAnchor.constraint(equalTo: stack.heightAnchor),
            column.separator.heightAnchor.constraint(equalTo: stack.heightAnchor),
            column.separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        columns.append(column)
        DirectoryStore.shared.beginWatching(path)
        table.reloadData()
        return column
    }

    private func removeColumns(after index: Int) {
        removePreview()
        while columns.count > index + 1 {
            let column = columns.removeLast()
            DirectoryStore.shared.endWatching(column.path)
            column.scroll.removeFromSuperview()
            column.separator.removeFromSuperview()
        }
    }

    private func removePreview() {
        preview?.removeFromSuperview()
        preview = nil
    }

    private func showPreview(for item: FileItem) {
        let view = ColumnPreviewView(item: item)
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 280),
            view.heightAnchor.constraint(equalTo: stack.heightAnchor),
        ])
        preview = view
    }

    private func scrollToEnd(animated: Bool) {
        view.layoutSubtreeIfNeeded()
        let width = stack.fittingSize.width
        let visible = scrollView.contentView.bounds.width
        let x = max(0, width - visible)
        let point = NSPoint(x: x, y: 0)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(point)
            }
        } else {
            scrollView.contentView.scroll(to: point)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func replaceItems(of column: Column, with newItems: [FileItem]) {
        let selected = column.table.selectedRowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
        column.items = newItems
        isSyncing = true
        column.table.reloadData()
        var rows = IndexSet()
        for item in selected {
            if let row = newItems.firstIndex(where: { $0 === item }) { rows.insert(row) }
        }
        column.table.selectRowIndexes(rows, byExtendingSelection: false)
        isSyncing = false
        // A folder whose column is open may have disappeared.
        if let index = columns.firstIndex(where: { $0 === column }), rows.isEmpty, index < columns.count - 1 {
            removeColumns(after: index)
            columnsDidChange()
        }
    }

    @objc private func directoryDidUpdate(_ notification: Notification) {
        guard let listing = notification.object as? DirectoryStore.Listing,
              let column = columns.first(where: { $0.path == listing.path }) else { return }
        replaceItems(of: column, with: pane?.arrange(listing.items) ?? listing.items)
    }

    private func columnInfo(for tableView: NSTableView) -> (Int, Column)? {
        guard let index = columns.firstIndex(where: { $0.table === tableView }) else { return nil }
        return (index, columns[index])
    }

    private func columnsDidChange() {
        pane?.adoptColumnLocation(deepestPath)
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        columnInfo(for: tableView)?.1.items.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let (_, column) = columnInfo(for: tableView), row < column.items.count else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? ColumnCellView
            ?? { let c = ColumnCellView(); c.identifier = Self.cellID; return c }()
        let item = column.items[row]
        cell.configure(item, dimmed: pane?.isCut(item) ?? false)
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard let (_, column) = columnInfo(for: tableView), row < column.items.count else { return nil }
        return column.items[row].name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing, let table = notification.object as? NSTableView, let (index, column) = columnInfo(for: table) else { return }
        activeColumn = index
        let selected = table.selectedRowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
        removeColumns(after: index)
        if selected.count == 1 {
            let item = selected[0]
            if item.isNavigable {
                var path = item.path
                if item.type == .symlink { path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
                let listing = DirectoryStore.shared.loadNow(path)
                addColumn(path: path, items: pane?.arrange(listing.items) ?? listing.items)
            } else {
                showPreview(for: item)
            }
        }
        scrollToEnd(animated: true)
        columnsDidChange()
        notifySelectionChanged()
    }

    private func handleArrow(left: Bool, from index: Int) -> Bool {
        if left {
            guard index > 0 else { return true }
            let previous = columns[index - 1]
            view.window?.makeFirstResponder(previous.table)
            activeColumn = index - 1
            // Collapse back to the folder selected in the previous column.
            isSyncing = true
            columns[index].table.deselectAll(nil)
            isSyncing = false
            removePreview()
            notifySelectionChanged()
            return true
        }
        guard index + 1 < columns.count else { return true }
        let next = columns[index + 1]
        view.window?.makeFirstResponder(next.table)
        if next.table.selectedRow < 0, !next.items.isEmpty {
            next.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        activeColumn = index + 1
        notifySelectionChanged()
        return true
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        guard let (_, column) = columnInfo(for: sender), sender.clickedRow >= 0, sender.clickedRow < column.items.count else { return }
        let item = column.items[sender.clickedRow]
        if item.isNavigable {
            pane?.navigate(to: item.path)
        } else {
            pane?.open([item])
        }
    }

    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool {
        pane?.handleKeyDown(event, typeSelecting: typeSelecting) ?? false
    }

    // MARK: Selection API

    override var selectedItems: [FileItem] {
        guard activeColumn < columns.count else { return [] }
        let column = columns[activeColumn]
        return column.table.selectedRowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
    }

    override func select(_ files: [FileItem], scroll: Bool) {
        guard let column = columns.last else { return }
        var rows = IndexSet()
        for file in files {
            if let row = column.items.firstIndex(where: { $0 === file }) { rows.insert(row) }
        }
        activeColumn = columns.count - 1
        column.table.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { column.table.scrollRowToVisible(first) }
    }

    override func selectAllItems() {
        guard activeColumn < columns.count else { return }
        columns[activeColumn].table.selectAll(nil)
    }

    override func deselectAllItems() {
        guard activeColumn < columns.count else { return }
        columns[activeColumn].table.deselectAll(nil)
    }

    override func focus() {
        guard activeColumn < columns.count else { return }
        view.window?.makeFirstResponder(columns[activeColumn].table)
    }

    override func refresh(_ files: [FileItem]) {
        let wanted = Set(files.map { ObjectIdentifier($0) })
        for column in columns {
            var rows = IndexSet()
            for (row, item) in column.items.enumerated() where wanted.contains(ObjectIdentifier(item)) { rows.insert(row) }
            if !rows.isEmpty { column.table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
        }
    }

    override func appearanceSettingsDidChange() {
        for column in columns { column.table.reloadData() }
    }

    override func iconScreenRect(for file: FileItem) -> NSRect? {
        for column in columns {
            guard let row = column.items.firstIndex(where: { $0 === file }),
                  let cell = column.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ColumnCellView,
                  let window = view.window else { continue }
            return window.convertToScreen(cell.icon.convert(cell.icon.bounds, to: nil))
        }
        return nil
    }

    // MARK: Rename

    override func beginRename(_ file: FileItem) {
        for column in columns {
            guard let row = column.items.firstIndex(where: { $0 === file }) else { continue }
            column.table.scrollRowToVisible(row)
            guard let cell = column.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ColumnCellView,
                  let window = view.window else { return }
            renamingItem = file
            cell.name.isEditable = true
            cell.name.isSelectable = true
            cell.name.delegate = self
            window.makeFirstResponder(cell.name)
            cell.name.currentEditor()?.selectedRange = NameCellView.editableRange(for: file.name)
            return
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let file = renamingItem else { return }
        renamingItem = nil
        field.isEditable = false
        field.isSelectable = false
        focus()
        if field.stringValue != file.name, pane?.commitRename(file, to: field.stringValue) != true {
            field.stringValue = file.name
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let file = renamingItem,
           let field = control as? NSTextField {
            renamingItem = nil
            field.abortEditing()
            field.stringValue = file.name
            field.isEditable = false
            focus()
            return true
        }
        return false
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var targets: [FileItem] = []
        for (index, column) in columns.enumerated() {
            let row = column.table.clickedRow
            guard row >= 0, row < column.items.count else { continue }
            activeColumn = index
            if column.table.selectedRowIndexes.contains(row) {
                targets = column.table.selectedRowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
            } else {
                column.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                targets = [column.items[row]]
            }
            break
        }
        pane?.populateContextMenu(menu, for: targets)
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let (_, column) = columnInfo(for: tableView), row < column.items.count else { return nil }
        return column.items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard let (_, column) = columnInfo(for: tableView) else { return }
        draggedItems = rowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .delete { pane?.trash(draggedItems.map { $0.url }) }
        draggedItems = []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let pane, let (_, column) = columnInfo(for: tableView) else { return [] }
        var destination = column.path
        if dropOperation == .on, row < column.items.count, column.items[row].isNavigable {
            destination = column.items[row].path
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return pane.dragOperation(for: info, destination: destination)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let (_, column) = columnInfo(for: tableView) else { return false }
        var destination = column.path
        if dropOperation == .on, row >= 0, row < column.items.count, column.items[row].isNavigable {
            destination = column.items[row].path
        }
        return pane?.performDrop(info, destination: destination) ?? false
    }
}
