import AppKit
import Quartz

final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmstripItem")
    let loader = ItemImageLoader()
    private let icon = NSImageView()
    private let highlight = NSView()
    private(set) var file: FileItem?
    weak var controller: GalleryViewController?

    override func loadView() {
        let root = FilmstripItemView()
        root.owner = self
        // Finder's filmstrip selection: a plain gray rounded box, no ring.
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 7
        highlight.layer?.cornerCurve = .continuous
        highlight.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(highlight)
        root.addSubview(icon)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            highlight.topAnchor.constraint(equalTo: root.topAnchor),
            highlight.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            icon.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            icon.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        view = root
        imageView = icon
    }

    func configure(_ file: FileItem) {
        self.file = file
        // Finder's filmstrip thumbnails: Quick Look's icon-mode style, as in the icon view.
        loader.load(file, into: icon, points: 64, thumbnails: true, iconMode: true)
        updateSelection()
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    /// Resolved in the item's own appearance, and again when it changes.
    func updateSelection() {
        highlight.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.highlight.layer?.backgroundColor = self.isSelected ? NSColor.tertiaryLabelColor.cgColor : nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader.cancel()
        file = nil
    }
}

final class FilmstripItemView: NSView {
    weak var owner: FilmstripItem?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.updateSelection()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let file = owner?.file {
            owner?.controller?.pane?.open([file])
        }
    }
}

/// Gallery: a large live Quick Look preview above a filmstrip of thumbnails.
final class GalleryViewController: FileViewController, NSCollectionViewDataSource, NSCollectionViewDelegate,
                                   NSMenuDelegate, FileViewKeyHandling {
    /// Holds the preview, fixed: like the other modes, the pane's top edge is
    /// a scroll view, so macOS draws no line under the toolbar.
    private let previewScroll = NSScrollView()
    private let previewContainer = NSView()
    private var preview: QLPreviewView?
    private let fallbackImage = NSImageView()
    private let strip = FileCollectionView()
    private let stripScroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let contextMenu = NSMenu()
    private var previewToken = 0
    /// The file the large preview shows; selecting it again does not reload it.
    private var previewedPath: String?
    private var draggedItems: [FileItem] = []

    override func loadView() {
        let root = NSView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        fallbackImage.translatesAutoresizingMaskIntoConstraints = false
        fallbackImage.imageScaling = .scaleProportionallyUpOrDown
        // A large image must never hold the window at its size.
        fallbackImage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fallbackImage.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewContainer.addSubview(fallbackImage)

        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.drawsBackground = false
        previewScroll.borderType = .noBorder
        previewScroll.hasVerticalScroller = false
        previewScroll.hasHorizontalScroller = false
        previewScroll.verticalScrollElasticity = .none
        previewScroll.horizontalScrollElasticity = .none
        previewScroll.automaticallyAdjustsContentInsets = false
        previewScroll.documentView = previewContainer

        // The same 24 pt margin above, beside and below the preview (with the
        // strip's 5 pt inset).
        if let preview = QLPreviewView(frame: .zero, style: .normal) {
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.autostarts = false
            previewContainer.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 24),
                preview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -24),
                preview.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 24),
                preview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -19),
            ])
            self.preview = preview
        }

        // Finder's filmstrip: 54 pt boxes 4 pt from the pane's edge and 5 pt from the path bar.
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 54, height: 54)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 5, left: 4, bottom: 5, right: 4)
        strip.collectionViewLayout = layout
        strip.isSelectable = true
        strip.allowsMultipleSelection = true
        strip.allowsEmptySelection = true
        strip.backgroundColors = [.clear]
        strip.dataSource = self
        strip.delegate = self
        strip.keyHandler = self
        strip.onTypeSelect = { [weak self] text in self?.typeSelect(text) }
        strip.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)
        strip.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        contextMenu.delegate = self
        strip.menu = contextMenu

        stripScroll.documentView = strip
        stripScroll.hasHorizontalScroller = true
        stripScroll.autohidesScrollers = true
        stripScroll.drawsBackground = false
        stripScroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(previewScroll)
        root.addSubview(stripScroll)
        NSLayoutConstraint.activate([
            previewScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: root.topAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: stripScroll.topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: previewScroll.contentView.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: previewScroll.contentView.trailingAnchor),
            previewContainer.topAnchor.constraint(equalTo: previewScroll.contentView.topAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: previewScroll.contentView.bottomAnchor),
            fallbackImage.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 24),
            fallbackImage.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -24),
            fallbackImage.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 24),
            fallbackImage.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -19),
            stripScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stripScroll.heightAnchor.constraint(equalToConstant: 64),
        ])
        view = root
    }

    override func willDeactivate() {
        previewedPath = nil
        preview?.previewItem = nil
        preview?.close()
    }

    override func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {
        guard isViewLoaded else { return }
        if reset || changes == nil || changes?.isInitialLoad == true {
            reloadStrip(previous: previous, reset: reset)
            return
        }
        let difference = items.difference(from: previous)
        if difference.count > 300 {
            reloadStrip(previous: previous, reset: false)
            return
        }
        // Only the thumbnails that came or went; the strip moves the selection along.
        var removed = Set<IndexPath>()
        var inserted = Set<IndexPath>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(IndexPath(item: offset, section: 0))
            case let .insert(offset, _, _): inserted.insert(IndexPath(item: offset, section: 0))
            }
        }
        if !removed.isEmpty || !inserted.isEmpty {
            strip.performBatchUpdates({
                if !removed.isEmpty { self.strip.deleteItems(at: removed) }
                if !inserted.isEmpty { self.strip.insertItems(at: inserted) }
            }, completionHandler: nil)
        }
        if let updated = changes?.updated, !updated.isEmpty {
            refresh(updated)
            // The shown file itself changed on disk.
            if let path = previewedPath, updated.contains(where: { $0.path == path }) { preview?.refreshPreviewItem() }
        }
        updatePreview()
        notifySelectionChanged()
    }

    /// Reloads the whole strip. The selection is read from the old list: the
    /// strip's index paths still refer to it.
    private func reloadStrip(previous: [FileItem], reset: Bool) {
        let selection: [FileItem] = reset ? []
            : strip.selectionIndexPaths.sorted().compactMap { $0.item < previous.count ? previous[$0.item] : nil }
        strip.reloadData()
        if !selection.isEmpty {
            select(selection, scroll: false)
        } else if let first = items.first, reset {
            select([first], scroll: true)
        } else {
            updatePreview()
        }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath)
        if let strip = item as? FilmstripItem, indexPath.item < items.count {
            strip.controller = self
            strip.configure(items[indexPath.item])
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updatePreview()
        notifySelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updatePreview()
        notifySelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        indexPath.item < items.count ? items[indexPath.item].url as NSURL : nil
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

    private func updatePreview() {
        previewToken += 1
        let token = previewToken
        let file = selectedItems.last
        // Debounce while arrowing quickly through the strip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, token == self.previewToken else { return }
            if let file {
                // Already shown: nothing to reload (changes on disk refresh it in itemsDidChange).
                guard file.path != self.previewedPath else { return }
                self.previewedPath = file.path
                if let preview = self.preview, !(file.isNavigable || file.type == .package) {
                    preview.previewItem = file.url as NSURL
                    preview.isHidden = false
                    self.fallbackImage.isHidden = true
                } else {
                    // Like Finder, folders and packages show just their big icon.
                    self.preview?.previewItem = nil
                    self.preview?.isHidden = true
                    self.fallbackImage.image = IconCache.shared.cachedItemIcon(path: file.path) ?? IconCache.shared.immediateIcon(for: file)
                    if IconCache.shared.needsItemIcon(file) {
                        IconCache.shared.loadItemIcon(for: file) { [weak self] icon in
                            guard let self, self.previewedPath == file.path else { return }
                            self.fallbackImage.image = icon
                        }
                    }
                    self.fallbackImage.isHidden = false
                }
            } else {
                self.previewedPath = nil
                self.preview?.previewItem = nil
                self.preview?.isHidden = true
                self.fallbackImage.isHidden = true
            }
        }
    }

    override var selectedItems: [FileItem] {
        strip.selectionIndexPaths.sorted().compactMap { $0.item < items.count ? items[$0.item] : nil }
    }

    override func select(_ files: [FileItem], scroll: Bool) {
        let wanted = Set(files.map { ObjectIdentifier($0) })
        var paths = Set<IndexPath>()
        for (index, item) in items.enumerated() where wanted.contains(ObjectIdentifier(item)) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        strip.selectionIndexPaths = paths
        if scroll, !paths.isEmpty { strip.scrollToItems(at: paths, scrollPosition: .centeredHorizontally) }
        updatePreview()
        notifySelectionChanged()
    }

    override func selectAllItems() { strip.selectAll(nil) }
    override func deselectAllItems() { strip.deselectAll(nil) }

    override func focus() {
        view.window?.makeFirstResponder(strip)
    }

    override func refresh(_ files: [FileItem]) {
        var paths = Set<IndexPath>()
        let wanted = Set(files.map { ObjectIdentifier($0) })
        for (index, item) in items.enumerated() where wanted.contains(ObjectIdentifier(item)) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        if !paths.isEmpty { strip.reloadItems(at: paths) }
    }

    override func iconScreenRect(for file: FileItem) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(previewContainer.convert(previewContainer.bounds, to: nil))
    }

    private func typeSelect(_ text: String) {
        if let match = items.first(where: { $0.name.range(of: text, options: [.caseInsensitive, .anchored]) != nil }) {
            select([match], scroll: true)
        }
    }

    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool {
        pane?.handleKeyDown(event, typeSelecting: typeSelecting) ?? false
    }

    override func beginRename(_ item: FileItem) {
        // The gallery has no inline name field; rename in place with a small sheet.
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(item.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            _ = self?.pane?.commitRename(item, to: field.stringValue)
        }
        // The field has an editor only once the sheet is up: then select the
        // name without its extension, like Finder.
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NameCellView.editableRange(for: item.name)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        pane?.populateContextMenu(menu, for: selectedItems)
    }
}
