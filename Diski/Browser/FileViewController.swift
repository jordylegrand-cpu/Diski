import AppKit

/// Base class for the four view modes (icons, list, columns, gallery).
/// The pane owns navigation, arranging and file actions; view modes only
/// display items and report selection.
class FileViewController: NSViewController {
    weak var pane: PaneViewController?
    private(set) var items: [FileItem] = []
    private(set) var directoryPath = ""

    /// Shows `items` (already arranged) for `directory`. When `changes` is
    /// non-nil the view may animate the difference; `reset` scrolls to the top.
    func display(items newItems: [FileItem], directory: String, changes: DirectoryStore.Changes?, reset: Bool) {
        let previous = items
        items = newItems
        directoryPath = directory
        itemsDidChange(from: previous, changes: changes, reset: reset)
    }

    /// Subclass hook.
    func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {}

    var selectedItems: [FileItem] { [] }
    func select(_ items: [FileItem], scroll: Bool) {}
    func selectAllItems() {}
    func deselectAllItems() {}
    func beginRename(_ item: FileItem) {}
    func focus() {}
    /// Items whose attributes changed (folder sizes, icons): refresh their cells.
    func refresh(_ items: [FileItem]) {}
    func appearanceSettingsDidChange() {}
    /// The folder new items and pastes go into (the focused column in column view).
    var targetDirectory: String { directoryPath }
    /// Screen rect of an item's icon, for Quick Look zoom animations.
    func iconScreenRect(for item: FileItem) -> NSRect? { nil }
    /// Called before the view mode is replaced.
    func willDeactivate() {}

    func notifySelectionChanged() {
        pane?.viewSelectionDidChange(self)
    }
}

// MARK: - Shared cell helpers

/// Loads the best available image for an item into an image view: the type
/// icon immediately, then the item's own icon or a Quick Look thumbnail.
final class ItemImageLoader {
    private(set) weak var item: FileItem?
    private var thumbnailToken: String?

    func load(_ item: FileItem, into imageView: NSImageView, points: CGFloat, thumbnails: Bool) {
        cancel()
        self.item = item
        if thumbnails, FileKinds.wantsThumbnail(item) {
            if let cached = ThumbnailCache.shared.cached(for: item, points: points) {
                imageView.image = cached
                return
            }
        }
        if let icon = IconCache.shared.cachedItemIcon(path: item.path) {
            imageView.image = icon
        } else {
            imageView.image = IconCache.shared.immediateIcon(for: item)
            if IconCache.shared.needsItemIcon(item) {
                IconCache.shared.loadItemIcon(for: item) { [weak self, weak imageView] icon in
                    guard let self, self.item === item else { return }
                    imageView?.image = icon
                }
            }
        }
        if thumbnails, FileKinds.wantsThumbnail(item), !ThumbnailCache.shared.hasFailed(item, points: points) {
            let scale = imageView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            thumbnailToken = ThumbnailCache.shared.request(for: item, points: points, scale: scale) { [weak self, weak imageView] image in
                guard let self, self.item === item, let image else { return }
                self.thumbnailToken = nil
                imageView?.image = image
            }
        }
    }

    func cancel() {
        if let token = thumbnailToken {
            ThumbnailCache.shared.cancel(token)
            thumbnailToken = nil
        }
        item = nil
    }
}

/// Finder tag colors by legacy label index (1...7).
enum TagColors {
    static let names = ["", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]
    static let sidebarOrder = [6, 7, 5, 2, 4, 3, 1] // Red, Orange, Yellow, Green, Blue, Purple, Gray

    static func color(forLabel index: Int) -> NSColor {
        switch index {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return .clear
        }
    }

    static func color(forTagName name: String) -> NSColor? {
        guard let index = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }), index > 0 else {
            return nil
        }
        return color(forLabel: index)
    }
}

/// A small filled circle used for tag dots.
final class TagDotView: NSView {
    var colors: [NSColor] = [] {
        didSet {
            isHidden = colors.isEmpty
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: colors.isEmpty ? 0 : CGFloat(colors.count - 1) * 5 + 10, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, color) in colors.enumerated().reversed() {
            let rect = NSRect(x: CGFloat(i) * 5 + 0.5, y: (bounds.height - 9) / 2, width: 9, height: 9)
            let path = NSBezierPath(ovalIn: rect)
            color.setFill()
            path.fill()
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
