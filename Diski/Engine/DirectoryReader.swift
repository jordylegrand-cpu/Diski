import Darwin
import Foundation

/// Reads directories with `getattrlistbulk(2)`: a single system call returns a
/// whole batch of entries together with all the attributes Diski displays.
/// This avoids the per-file `stat`/URL-resource round trips that make
/// `FileManager` listings slow on large folders.
enum DirectoryReader {
    struct ReadError: Error, LocalizedError {
        let path: String
        let code: Int32
        var errorDescription: String? {
            String(cString: strerror(code))
        }
        var isPermissionDenied: Bool { code == EACCES || code == EPERM }
    }

    // attrgroup_t bit values from <sys/attr.h>. Spelled out so the layout
    // below never depends on how the C macros are imported.
    private static let cmnName: attrgroup_t = 0x0000_0001
    private static let cmnObjType: attrgroup_t = 0x0000_0008
    private static let cmnCrTime: attrgroup_t = 0x0000_0200
    private static let cmnModTime: attrgroup_t = 0x0000_0400
    private static let cmnFndrInfo: attrgroup_t = 0x0000_4000
    private static let cmnAccessMask: attrgroup_t = 0x0002_0000
    private static let cmnFlags: attrgroup_t = 0x0004_0000
    private static let cmnFileID: attrgroup_t = 0x0200_0000
    private static let cmnAddedTime: attrgroup_t = 0x1000_0000
    private static let cmnError: attrgroup_t = 0x2000_0000
    private static let cmnReturnedAttrs: attrgroup_t = 0x8000_0000

    private static let dirEntryCount: attrgroup_t = 0x0000_0002
    private static let dirMountStatus: attrgroup_t = 0x0000_0004

    private static let fileTotalSize: attrgroup_t = 0x0000_0002
    private static let fileAllocSize: attrgroup_t = 0x0000_0004

    static let vREG: UInt32 = 1
    static let vDIR: UInt32 = 2
    static let vLNK: UInt32 = 5

    private static let bufferSize = 256 * 1024

    /// Reads all entries of `path` (hidden ones included; callers filter).
    static func read(path: String) throws -> [FileItem] {
        var result: [FileItem] = []
        try forEachEntry(inDirectory: path, detailed: true) { result.append($0) }
        return result
    }

    /// Streams entries to `body`. When `detailed` is false only the name, type
    /// and sizes are parsed (used by recursive size calculation and copying).
    static func forEachEntry(inDirectory rawPath: String, detailed: Bool, _ body: (FileItem) throws -> Void) throws {
        let path = normalized(rawPath)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ReadError(path: path, code: errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
        request.commonattr = cmnReturnedAttrs | cmnError | cmnName | cmnObjType | cmnFlags | cmnFileID
            | (detailed ? (cmnCrTime | cmnModTime | cmnFndrInfo | cmnAccessMask | cmnAddedTime) : 0)
        request.dirattr = detailed ? (dirEntryCount | dirMountStatus) : dirMountStatus
        request.fileattr = fileTotalSize | fileAllocSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadError(path: path, code: errno)
            }
            if count == 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let item = parse(entry: entry, parentPath: path, detailed: detailed) {
                    try body(item)
                }
                entry = entry.advanced(by: length)
            }
        }
    }

    /// A lightweight entry handed to `forEachRawEntry`. `name` is only valid
    /// during the callback; no Swift objects are created for plain files.
    struct RawEntry {
        let name: UnsafePointer<CChar>
        let objectType: UInt32
        let size: Int64
        let isMountPoint: Bool

        var isDirectory: Bool { objectType == DirectoryReader.vDIR }
        var isSymlink: Bool { objectType == DirectoryReader.vLNK }
        var isRegularFile: Bool { objectType == DirectoryReader.vREG }
        var nameString: String { String(cString: name) }
    }

    /// The fastest possible listing: name, type, size and mount status only.
    /// Used by recursive size calculation and the copy engine's tree scan.
    static func forEachRawEntry(inDirectory rawPath: String, _ body: (RawEntry) -> Void) throws {
        let path = normalized(rawPath)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ReadError(path: path, code: errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = 5
        request.commonattr = cmnReturnedAttrs | cmnError | cmnName | cmnObjType
        request.dirattr = dirMountStatus
        request.fileattr = fileTotalSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadError(path: path, code: errno)
            }
            if count == 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry.advanced(by: 4)
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field = field.advanced(by: MemoryLayout<attribute_set_t>.size)
                var failed = false
                if returned.commonattr & cmnError != 0 {
                    failed = field.loadUnaligned(as: UInt32.self) != 0
                    field = field.advanced(by: 4)
                }
                var namePointer: UnsafePointer<CChar>?
                if returned.commonattr & cmnName != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    namePointer = field.advanced(by: Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    field = field.advanced(by: MemoryLayout<attrreference_t>.size)
                }
                var objectType: UInt32 = 0
                if returned.commonattr & cmnObjType != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field = field.advanced(by: 4)
                }
                var isMount = false
                if returned.dirattr & dirMountStatus != 0 {
                    isMount = field.loadUnaligned(as: UInt32.self) & 0x1 != 0
                    field = field.advanced(by: 4)
                }
                var size: Int64 = 0
                if returned.fileattr & fileTotalSize != 0 {
                    size = field.loadUnaligned(as: Int64.self)
                    field = field.advanced(by: 8)
                }
                if let namePointer, !failed || objectType != 0 {
                    body(RawEntry(name: namePointer, objectType: objectType, size: size, isMountPoint: isMount))
                }
                entry = entry.advanced(by: length)
            }
        }
    }

    static func normalized(_ path: String) -> String {
        if path.count > 1 && path.hasSuffix("/") { return String(path.dropLast()) }
        return path.isEmpty ? "/" : path
    }

    private static func parse(entry: UnsafeRawPointer, parentPath: String, detailed: Bool) -> FileItem? {
        var field = entry.advanced(by: MemoryLayout<UInt32>.size) // skip length
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field = field.advanced(by: MemoryLayout<attribute_set_t>.size)

        if returned.commonattr & cmnError != 0 {
            // Entries that failed are skipped; their name may be unreadable.
            let error = field.loadUnaligned(as: UInt32.self)
            field = field.advanced(by: 4)
            if error != 0 && returned.commonattr & cmnName == 0 { return nil }
        }

        var name = ""
        if returned.commonattr & cmnName != 0 {
            let ref = field.loadUnaligned(as: attrreference_t.self)
            let namePointer = field.advanced(by: Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            name = String(cString: namePointer)
            field = field.advanced(by: MemoryLayout<attrreference_t>.size)
        }
        if name.isEmpty || name == "." || name == ".." { return nil }

        var objType: UInt32 = 0
        if returned.commonattr & cmnObjType != 0 {
            objType = field.loadUnaligned(as: UInt32.self)
            field = field.advanced(by: 4)
        }
        var created = 0.0
        if returned.commonattr & cmnCrTime != 0 {
            created = seconds(field.loadUnaligned(as: timespec.self))
            field = field.advanced(by: MemoryLayout<timespec>.size)
        }
        var modified = 0.0
        if returned.commonattr & cmnModTime != 0 {
            modified = seconds(field.loadUnaligned(as: timespec.self))
            field = field.advanced(by: MemoryLayout<timespec>.size)
        }
        var finderFlags: UInt16 = 0
        if returned.commonattr & cmnFndrInfo != 0 {
            // Finder flags live at offset 8 of FileInfo/FolderInfo, big-endian.
            let hi = UInt16(field.load(fromByteOffset: 8, as: UInt8.self))
            let lo = UInt16(field.load(fromByteOffset: 9, as: UInt8.self))
            finderFlags = hi << 8 | lo
            field = field.advanced(by: 32)
        }
        var mode: UInt32 = 0
        if returned.commonattr & cmnAccessMask != 0 {
            mode = field.loadUnaligned(as: UInt32.self)
            field = field.advanced(by: 4)
        }
        var bsdFlags: UInt32 = 0
        if returned.commonattr & cmnFlags != 0 {
            bsdFlags = field.loadUnaligned(as: UInt32.self)
            field = field.advanced(by: 4)
        }
        var fileID: UInt64 = 0
        if returned.commonattr & cmnFileID != 0 {
            fileID = field.loadUnaligned(as: UInt64.self)
            field = field.advanced(by: 8)
        }
        var added = 0.0
        if returned.commonattr & cmnAddedTime != 0 {
            added = seconds(field.loadUnaligned(as: timespec.self))
            field = field.advanced(by: MemoryLayout<timespec>.size)
        }

        var childCount: Int32 = -1
        var isMountPoint = false
        if returned.dirattr & dirEntryCount != 0 {
            childCount = Int32(truncatingIfNeeded: field.loadUnaligned(as: UInt32.self))
            field = field.advanced(by: 4)
        }
        if returned.dirattr & dirMountStatus != 0 {
            let status = field.loadUnaligned(as: UInt32.self)
            isMountPoint = status & 0x1 != 0 // DIR_MNTSTATUS_MNTPOINT
            field = field.advanced(by: 4)
        }

        var size: Int64 = -1
        var allocSize: Int64 = 0
        if returned.fileattr & fileTotalSize != 0 {
            size = field.loadUnaligned(as: Int64.self)
            field = field.advanced(by: 8)
        }
        if returned.fileattr & fileAllocSize != 0 {
            allocSize = field.loadUnaligned(as: Int64.self)
            field = field.advanced(by: 8)
        }

        var type: EntryType
        var linkIsDirectory = false
        switch objType {
        case vREG:
            type = .file
        case vDIR:
            type = detailed && FileKinds.isPackage(name: name, finderFlags: finderFlags) ? .package : .directory
        case vLNK:
            type = .symlink
            if detailed {
                var st = stat()
                let full = parentPath == "/" ? "/" + name : parentPath + "/" + name
                if stat(full, &st) == 0 { linkIsDirectory = (st.st_mode & S_IFMT) == S_IFDIR }
            }
            if size < 0 { size = 0 }
        default:
            type = .other
        }
        if type == .directory { size = -1 }

        return FileItem(name: name, parentPath: parentPath, type: type, fileID: fileID, size: size,
                        allocatedSize: allocSize, created: created, modified: modified, added: added,
                        finderFlags: finderFlags, bsdFlags: bsdFlags, mode: mode, childCount: childCount,
                        isMountPoint: isMountPoint, linkTargetIsDirectory: linkIsDirectory)
    }

    @inline(__always)
    private static func seconds(_ ts: timespec) -> Double {
        Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }
}
