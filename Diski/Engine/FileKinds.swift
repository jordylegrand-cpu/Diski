import Foundation
import UniformTypeIdentifiers

/// Thread-safe, cached answers to "what is this file?" questions.
/// Launch Services lookups are slow; everything here is cached per extension.
enum FileKinds {
    private static let lock = NSLock()
    private static var packageByExt: [String: Bool] = [:]
    private static var kindByKey: [String: String] = [:]
    private static var typeByKey: [String: UTType] = [:]

    /// Directories that Finder presents as a single file.
    static func isPackage(name: String, finderFlags: UInt16) -> Bool {
        if finderFlags & 0x2000 != 0 { return true } // kHasBundle
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty else { return false }
        lock.lock()
        if let cached = packageByExt[ext] { lock.unlock(); return cached }
        lock.unlock()
        let isPackage = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        lock.lock()
        packageByExt[ext] = isPackage
        lock.unlock()
        return isPackage
    }

    /// The content type for an item (cached per extension).
    static func type(for item: FileItem) -> UTType {
        switch item.type {
        case .directory:
            return item.isMountPoint ? .volume : .folder
        case .symlink:
            return .symbolicLink
        case .other:
            return .item
        case .file, .package:
            if item.isAlias { return .aliasFile }
            let key = (item.type == .package ? "/" : "") + item.ext
            lock.lock()
            if let cached = typeByKey[key] { lock.unlock(); return cached }
            lock.unlock()
            var type: UTType
            if item.ext.isEmpty {
                type = item.type == .package ? .package : ((item.mode & 0o111) != 0 ? .unixExecutable : .data)
            } else if item.type == .package {
                type = UTType(filenameExtension: item.ext, conformingTo: .directory) ?? .package
            } else {
                type = UTType(filenameExtension: item.ext) ?? .data
            }
            lock.lock()
            typeByKey[key] = type
            lock.unlock()
            return type
        }
    }

    /// Finder-style "Kind" description ("Folder", "JPEG image", "Application", ...).
    static func kind(for item: FileItem) -> String {
        switch item.type {
        case .directory:
            return item.isMountPoint ? "Volume" : "Folder"
        case .symlink:
            return "Alias"
        case .other:
            return "Special File"
        case .file, .package:
            if item.isAlias { return "Alias" }
            let executable = item.ext.isEmpty && item.type == .file && (item.mode & 0o111) != 0
            let key = (item.type == .package ? "/" : "") + item.ext + (executable ? "+x" : "")
            lock.lock()
            if let cached = kindByKey[key] { lock.unlock(); return cached }
            lock.unlock()
            var kind: String
            if executable {
                kind = "Unix executable"
            } else if item.ext.isEmpty {
                kind = item.type == .package ? "Package" : "Document"
            } else {
                let type = Self.type(for: item)
                if let description = type.localizedDescription, !type.isDynamic {
                    kind = description.prefix(1).uppercased() + description.dropFirst()
                } else {
                    kind = item.type == .package ? "Package" : "\(item.ext.uppercased()) file"
                }
            }
            lock.lock()
            kindByKey[key] = kind
            lock.unlock()
            return kind
        }
    }

    static func isImage(_ item: FileItem) -> Bool { item.type == .file && type(for: item).conforms(to: .image) }
    static func isMovie(_ item: FileItem) -> Bool { item.type == .file && type(for: item).conforms(to: .audiovisualContent) }

    /// Items worth asking Quick Look for a real thumbnail.
    static func wantsThumbnail(_ item: FileItem) -> Bool {
        guard item.type == .file, item.size > 0 else { return false }
        let t = type(for: item)
        return t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .pdf)
            || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet)
            || t.identifier == "com.apple.iwork.pages.sffpages" || t.conforms(to: .threeDContent)
    }
}
