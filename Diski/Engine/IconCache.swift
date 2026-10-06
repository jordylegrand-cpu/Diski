import AppKit
import UniformTypeIdentifiers

/// Icons are resolved in two tiers:
/// 1. an immediate, type-based icon (cached per content type, instant), and
/// 2. for items with their own artwork (apps, custom icons, special folders,
///    volumes, aliases) a per-item icon fetched in the background.
final class IconCache {
    static let shared = IconCache()

    private let typeIcons = NSCache<NSString, NSImage>()
    private let itemIcons = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.diski.icons"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    private var waiting: [String: [(NSImage) -> Void]] = [:]
    private let home = NSHomeDirectory()

    private init() {
        itemIcons.countLimit = 4000
    }

    lazy var genericFolder: NSImage = NSWorkspace.shared.icon(for: .folder)

    /// An icon that can be drawn right away.
    func immediateIcon(for item: FileItem) -> NSImage {
        if let icon = itemIcons.object(forKey: item.path as NSString) { return icon }
        if item.type == .directory && !item.isMountPoint { return genericFolder }
        return icon(for: FileKinds.type(for: item))
    }

    func icon(for type: UTType) -> NSImage {
        let key = type.identifier as NSString
        if let icon = typeIcons.object(forKey: key) { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        typeIcons.setObject(icon, forKey: key)
        return icon
    }

    func cachedItemIcon(path: String) -> NSImage? {
        itemIcons.object(forKey: path as NSString)
    }

    /// Whether the item has artwork of its own that differs from its type icon.
    func needsItemIcon(_ item: FileItem) -> Bool {
        switch item.type {
        case .package, .symlink:
            return true
        case .directory:
            return item.hasCustomIcon || item.isMountPoint || isSpecialLocation(item)
        case .file:
            return item.hasCustomIcon || item.isAlias
        case .other:
            return false
        }
    }

    private func isSpecialLocation(_ item: FileItem) -> Bool {
        let parent = item.parentPath
        return parent == home || parent == "/" || parent == "/Users" || parent == "/Applications"
            || parent == "/Volumes" || parent.hasSuffix("/Library/Mobile Documents")
            || item.name == "Developer" || item.name == "Utilities"
    }

    /// Loads the item's own icon in the background; `completion` runs on the main thread.
    func loadItemIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        loadItemIcon(path: item.path, completion: completion)
    }

    func loadItemIcon(path: String, completion: @escaping (NSImage) -> Void) {
        if let icon = itemIcons.object(forKey: path as NSString) {
            completion(icon)
            return
        }
        if waiting[path] != nil {
            waiting[path]?.append(completion)
            return
        }
        waiting[path] = [completion]
        queue.addOperation { [weak self] in
            let icon = NSWorkspace.shared.icon(forFile: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.itemIcons.setObject(icon, forKey: path as NSString)
                let callbacks = self.waiting.removeValue(forKey: path) ?? []
                for callback in callbacks { callback(icon) }
            }
        }
    }

    /// Drops cached artwork for a path (after renames, icon changes, ...).
    func invalidate(path: String) {
        itemIcons.removeObject(forKey: path as NSString)
    }
}
