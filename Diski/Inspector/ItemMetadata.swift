import AppKit
import CoreServices

/// Spotlight facts and permissions shown by the preview pane and Info windows.
struct ItemMetadata {
    var lastOpened: Date?
    var dimensions: String?
    var duration: String?
    var version: String?
    var whereFrom: String?
    var tags: [String] = []

    /// Reads Spotlight metadata and tags. Call off the main thread.
    static func load(_ url: URL) -> ItemMetadata {
        var result = ItemMetadata()
        result.tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return result }
        result.lastOpened = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        if let width = MDItemCopyAttribute(item, kMDItemPixelWidth) as? Int,
           let height = MDItemCopyAttribute(item, kMDItemPixelHeight) as? Int {
            result.dimensions = "\(width) × \(height)"
        }
        if let seconds = MDItemCopyAttribute(item, kMDItemDurationSeconds) as? Double, seconds > 0 {
            let total = Int(seconds.rounded())
            result.duration = total >= 3600
                ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60)
        }
        result.version = MDItemCopyAttribute(item, kMDItemVersion) as? String
        if let origins = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], let first = origins.first {
            result.whereFrom = first
        }
        return result
    }

    /// "rwxr-xr-x".
    static func permissions(_ mode: UInt32) -> String {
        let chars = ["r", "w", "x"]
        var result = ""
        for shift in stride(from: 6, through: 0, by: -3) {
            for (bit, char) in chars.enumerated() {
                result += (mode >> UInt32(shift)) & (4 >> UInt32(bit)) != 0 ? char : "-"
            }
        }
        return result
    }

    /// Finder's privilege names for one class (owner, group, everyone).
    static func privilege(_ mode: UInt32, shift: UInt32) -> String {
        let read = (mode >> shift) & 4 != 0
        let write = (mode >> shift) & 2 != 0
        switch (read, write) {
        case (true, true): return "Read & Write"
        case (true, false): return "Read only"
        case (false, true): return "Write only (Drop Box)"
        case (false, false): return "No Access"
        }
    }

    /// "Macintosh HD ▸ Users ▸ jace ▸ Desktop".
    static func displayPath(_ path: String) -> String {
        let parts = FileManager.default.componentsToDisplay(forPath: path) ?? path.split(separator: "/").map(String.init)
        return parts.joined(separator: " ▸ ")
    }
}

/// Writes tags and the Finder flags shown with checkboxes.
enum ItemAttributes {
    static func setTags(_ tags: [String], on urls: [URL]) {
        for url in urls {
            try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        reloadParents(of: urls)
    }

    static func setLocked(_ locked: Bool, on url: URL) throws {
        var values = URLResourceValues()
        values.isUserImmutable = locked
        var target = url
        try target.setResourceValues(values)
        reloadParents(of: [url])
    }

    static func setHiddenExtension(_ hidden: Bool, on url: URL) throws {
        var values = URLResourceValues()
        values.hasHiddenExtension = hidden
        var target = url
        try target.setResourceValues(values)
        reloadParents(of: [url])
    }

    static func reloadParents(of urls: [URL]) {
        let parents = Set(urls.map { DirectoryReader.normalized($0.deletingLastPathComponent().path) })
        DirectoryStore.shared.reload(paths: parents)
    }
}
