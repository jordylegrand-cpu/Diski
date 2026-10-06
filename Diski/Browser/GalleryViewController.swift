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
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 7
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.borderWidth = 2.5
        highlight.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(highlight)
        root.addSubview(icon)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 1),
            highlight.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -1),
            highlight.topAnchor.constraint(equalTo: root.topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -1),
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 5),
            icon.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -5),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
            icon.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
        ])
        view = root
        imageView = icon
    }

    func configure(_ file: FileItem) {
        self.file = file
        loader.load(file, into: icon, points: 64, thumbnails: true)
        updateSelection()
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        highlight.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        highlight.layer?.backgroundColor = isSelected ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader.cancel()
        file = nil
    }
}

final class FilmstripItemView: NSView {
    weak var owner: FilmstripItem?

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
    private let previewContainer = NSView()
    private var preview: QLPreviewView?
    private let fallbackImage = NSImageView()
    private let strip = FileCollectionView()
    private let stripScroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let contextMenu = NSMenu()
    private var previewToken = 0

    override func loadView() {
        let root = NSView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        fallbackImage.translatesAutoresizingMaskIntoConstraints = false
        fallbackImage.imageScaling = .scaleProportionallyUpOrDown
        previewContainer.addSubview(fallbackImage)

        if let preview = QLPreviewView(frame: .zero, style: .normal) {
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.shouldCloseWithWindow = false
            preview.autostarts = false
            previewContainer.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 24),
                preview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -24),
                preview.topAnchor.constraint(equalTo: previewContainer.safeAreaLayoutGuide.topAnchor, constant: 16),
                preview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -12),
            ])
            self.preview = preview
        }

        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 54, height: 54)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
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

        root.addSubview(previewContainer)
        root.addSubview(stripScroll)
        NSLayoutConstraint.activate([
            previewContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewContainer.topAnchor.constraint(equalTo: root.topAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: stripScroll.topAnchor),
            fallbackImage.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            fallbackImage.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor, constant: 10),
            fallbackImage.widthAnchor.constraint(equalTo: previewContainer.widthAnchor, multiplier: 0.6),
            fallbackImage.heightAnchor.constraint(equalTo: previewContainer.heightAnchor, multiplier: 0.75),
            stripScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stripScroll.heightAnchor.constraint(equalToConstant: 70),
        ])
        view = root
    }

    override func willDeactivate() {
        preview?.previewItem = nil
        preview?.close()
    }

    override func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {
        guard isViewLoaded else { return }
        let selection = reset ? [] : selectedItems
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

    private func updatePreview() {
        previewToken += 1
        let token = previewToken
        let file = selectedItems.last
        // Debounce while arrowing quickly through the strip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, token == self.previewToken else { return }
            if let file {
                if let preview = self.preview {
                    preview.previewItem = file.url as NSURL
                    preview.isHidden = false
                    self.fallbackImage.isHidden = true
                } else {
                    self.fallbackImage.image = IconCache.shared.immediateIcon(for: file)
                    self.fallbackImage.isHidden = false
                }
            } else {
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
        strip.reloadData()
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
        field.currentEditor()?.selectedRange = NameCellView.editableRange(for: item.name)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        pane?.populateContextMenu(menu, for: selectedItems)
    }
}
