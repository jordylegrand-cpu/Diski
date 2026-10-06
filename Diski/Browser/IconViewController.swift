import AppKit

/// Collection view with Finder-like keyboard handling and type-to-select.
final class FileCollectionView: NSCollectionView {
    weak var keyHandler: FileViewKeyHandling?
    var onTypeSelect: ((String) -> Void)?
    private var typed = ""
    private var lastTyped: TimeInterval = 0

    override func keyDown(with event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let typing = now - lastTyped < 1.0
        if keyHandler?.handleKeyDown(event, typeSelecting: typing) == true { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags.isEmpty, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "." || $0 == "-" || $0 == "_" }) {
            typed = typing ? typed + chars : chars
            lastTyped = now
            onTypeSelect?(typed)
            return
        }
        super.keyDown(with: event)
    }
}

/// Finder-style icon cell: icon with a soft highlight, name in a tinted capsule when selected.
final class IconItemView: NSView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let iconBackground = NSView()
    let nameBackground = NSView()
    weak var item: IconViewItem?
    private var iconSize: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [iconBackground, nameBackground, icon, name] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 8
        iconBackground.layer?.cornerCurve = .continuous
        nameBackground.wantsLayer = true
        nameBackground.layer?.cornerRadius = 5
        nameBackground.layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.alignment = .center
        name.font = .systemFont(ofSize: 12)
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.wraps = true
        name.cell?.truncatesLastVisibleLine = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconSize = icon.widthAnchor.constraint(equalToConstant: 64)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconSize,
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            iconBackground.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            iconBackground.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            iconBackground.widthAnchor.constraint(equalTo: icon.widthAnchor, constant: 10),
            iconBackground.heightAnchor.constraint(equalTo: icon.heightAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 7),
            name.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            name.centerXAnchor.constraint(equalTo: centerXAnchor),
            name.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8),
            nameBackground.leadingAnchor.constraint(equalTo: name.leadingAnchor, constant: -4),
            nameBackground.trailingAnchor.constraint(equalTo: name.trailingAnchor, constant: 4),
            nameBackground.topAnchor.constraint(equalTo: name.topAnchor, constant: -1),
            nameBackground.bottomAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIconSize(_ size: CGFloat) {
        iconSize.constant = size
    }

    func applySelection(_ selected: Bool, emphasized: Bool) {
        iconBackground.layer?.backgroundColor = selected ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
        let accent = emphasized ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor
        nameBackground.layer?.backgroundColor = selected ? accent.cgColor : NSColor.clear.cgColor
        name.textColor = selected && emphasized ? .white : .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { item?.openFromDoubleClick() }
    }
}

final class IconViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconViewItem")
    let loader = ItemImageLoader()
    weak var controller: IconViewController?
    private(set) var file: FileItem?

    var itemView: IconItemView { view as! IconItemView }

    override func loadView() {
        let view = IconItemView()
        view.item = self
        self.view = view
        imageView = view.icon
        textField = view.name
    }

    func configure(_ file: FileItem, iconSize: CGFloat, dimmed: Bool) {
        self.file = file
        itemView.setIconSize(iconSize)
        itemView.name.stringValue = file.name
        itemView.name.isEditable = false
        loader.load(file, into: itemView.icon, points: iconSize, thumbnails: true)
        itemView.icon.alphaValue = (dimmed || file.isHidden) ? 0.5 : 1
        updateSelectionAppearance()
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            itemView.iconBackground.layer?.backgroundColor = highlightState == .asDropTarget
                ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
                : (isSelected ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor)
        }
    }

    func updateSelectionAppearance() {
        let emphasized = view.window?.isKeyWindow == true && view.window?.firstResponder === collectionView
        itemView.applySelection(isSelected, emphasized: emphasized)
    }

    func openFromDoubleClick() {
        guard let file else { return }
        controller?.pane?.open([file], inNewTab: NSEvent.modifierFlags.contains(.command))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader.cancel()
        file = nil
    }
}

final class IconViewController: FileViewController, NSCollectionViewDataSource, NSCollectionViewDelegate,
                                NSMenuDelegate, NSTextFieldDelegate, FileViewKeyHandling {
    let collectionView = FileCollectionView()
    private let scrollView = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let contextMenu = NSMenu()
    private var renamingItem: FileItem?
    private var draggedItems: [FileItem] = []

    override func loadView() {
        configureLayout()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.keyHandler = self
        collectionView.onTypeSelect = { [weak self] text in self?.typeSelect(text) }
        collectionView.register(IconViewItem.self, forItemWithIdentifier: IconViewItem.identifier)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        collectionView.registerForDraggedTypes(PaneViewController.acceptedDragTypes)
        contextMenu.delegate = self
        collectionView.menu = contextMenu

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        view = scrollView

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureLayout() {
        let size = Prefs.iconSize
        layout.itemSize = NSSize(width: max(size + 44, 96), height: size + 50)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 14, left: 16, bottom: 20, right: 16)
    }

    @objc private func windowKeyChanged() {
        refreshSelectionAppearance()
    }

    private func refreshSelectionAppearance() {
        for case let item as IconViewItem in collectionView.visibleItems() {
            item.updateSelectionAppearance()
        }
    }

    // MARK: Display

    override func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {
        guard isViewLoaded else { return }
        if reset || changes == nil || changes?.isInitialLoad == true {
            let selection = reset ? [] : selectedItems
            collectionView.reloadData()
            if reset { collectionView.scroll(.zero) } else { select(selection, scroll: false) }
            return
        }
        let difference = items.difference(from: previous)
        if difference.count > 300 {
            let selection = selectedItems
            collectionView.reloadData()
            select(selection, scroll: false)
            return
        }
        var removed = Set<IndexPath>()
        var inserted = Set<IndexPath>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(IndexPath(item: offset, section: 0))
            case let .insert(offset, _, _): inserted.insert(IndexPath(item: offset, section: 0))
            }
        }
        collectionView.animator().performBatchUpdates({
            if !removed.isEmpty { collectionView.deleteItems(at: removed) }
            if !inserted.isEmpty { collectionView.insertItems(at: inserted) }
        }, completionHandler: nil)
        if let updated = changes?.updated, !updated.isEmpty { refresh(updated) }
        notifySelectionChanged()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconViewItem.identifier, for: indexPath)
        if let iconItem = item as? IconViewItem, indexPath.item < items.count {
            iconItem.controller = self
            let file = items[indexPath.item]
            iconItem.configure(file, iconSize: Prefs.iconSize, dimmed: pane?.isCut(file) ?? false)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        notifySelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        notifySelectionChanged()
    }

    // MARK: Selection API

    override var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap { $0.item < items.count ? items[$0.item] : nil }
    }

    override func select(_ files: [FileItem], scroll: Bool) {
        var paths = Set<IndexPath>()
        let wanted = Set(files.map { ObjectIdentifier($0) })
        for (index, item) in items.enumerated() where wanted.contains(ObjectIdentifier(item)) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        collectionView.selectionIndexPaths = paths
        if scroll, !paths.isEmpty {
            collectionView.scrollToItems(at: paths, scrollPosition: .nearestHorizontalEdge)
        }
        refreshSelectionAppearance()
        notifySelectionChanged()
    }

    override func selectAllItems() { collectionView.selectAll(nil) }
    override func deselectAllItems() { collectionView.deselectAll(nil) }

    override func focus() {
        view.window?.makeFirstResponder(collectionView)
        refreshSelectionAppearance()
    }

    override func refresh(_ files: [FileItem]) {
        var paths = Set<IndexPath>()
        let wanted = Set(files.map { ObjectIdentifier($0) })
        for (index, item) in items.enumerated() where wanted.contains(ObjectIdentifier(item)) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        if !paths.isEmpty { collectionView.reloadItems(at: paths) }
    }

    override func appearanceSettingsDidChange() {
        configureLayout()
        layout.invalidateLayout()
        let selection = selectedItems
        collectionView.reloadData()
        select(selection, scroll: false)
    }

    override func iconScreenRect(for file: FileItem) -> NSRect? {
        guard let index = items.firstIndex(where: { $0 === file }),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? IconViewItem,
              let window = view.window else { return nil }
        let icon = item.itemView.icon
        return window.convertToScreen(icon.convert(icon.bounds, to: nil))
    }

    private func typeSelect(_ text: String) {
        guard let match = items.first(where: { $0.name.range(of: text, options: [.caseInsensitive, .anchored]) != nil }) else {
            return
        }
        select([match], scroll: true)
    }

    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool {
        pane?.handleKeyDown(event, typeSelecting: typeSelecting) ?? false
    }

    // MARK: Rename

    override func beginRename(_ file: FileItem) {
        guard let index = items.firstIndex(where: { $0 === file }) else { return }
        let path = IndexPath(item: index, section: 0)
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.item(at: path) as? IconViewItem, let window = view.window else { return }
        renamingItem = file
        let field = item.itemView.name
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        item.itemView.applySelection(false, emphasized: false)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NameCellView.editableRange(for: field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let file = renamingItem else { return }
        renamingItem = nil
        field.isEditable = false
        field.isSelectable = false
        let newName = field.stringValue
        view.window?.makeFirstResponder(collectionView)
        if newName != file.name, pane?.commitRename(file, to: newName) != true {
            field.stringValue = file.name
        }
        refreshSelectionAppearance()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let file = renamingItem,
           let field = control as? NSTextField {
            renamingItem = nil
            field.abortEditing()
            field.stringValue = file.name
            field.isEditable = false
            view.window?.makeFirstResponder(collectionView)
            refreshSelectionAppearance()
            return true
        }
        return false
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var targets: [FileItem] = []
        if let event = NSApp.currentEvent {
            let point = collectionView.convert(event.locationInWindow, from: nil)
            if let path = collectionView.indexPathForItem(at: point), path.item < items.count {
                if collectionView.selectionIndexPaths.contains(path) {
                    targets = selectedItems
                } else {
                    select([items[path.item]], scroll: false)
                    targets = [items[path.item]]
                }
            }
        }
        pane?.populateContextMenu(menu, for: targets)
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < items.count else { return nil }
        return items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        draggedItems = indexPaths.compactMap { $0.item < items.count ? items[$0.item] : nil }
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        if operation == .delete { pane?.trash(draggedItems.map { $0.url }) }
        draggedItems = []
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let pane else { return [] }
        let index = proposedDropIndexPath.pointee.item
        var destination = directoryPath
        if proposedDropOperation.pointee == .on, index < items.count, items[index].isNavigable {
            destination = items[index].path
        } else {
            proposedDropOperation.pointee = .before
        }
        if pane.isSearchResults && destination == directoryPath { return [] }
        return pane.dragOperation(for: draggingInfo, destination: destination)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        var destination = directoryPath
        if dropOperation == .on, indexPath.item < items.count, items[indexPath.item].isNavigable {
            destination = items[indexPath.item].path
        }
        return pane?.performDrop(draggingInfo, destination: destination) ?? false
    }
}
