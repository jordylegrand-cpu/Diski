import Foundation

struct ArrangeOptions: Equatable {
    var sortKey: SortKey = .name
    var ascending = true
    var foldersOnTop = true
    var showHidden = false
    var filter = ""
}

/// Filters and sorts listings. Keys are computed once per item
/// (decorate-sort-undecorate) so sorting large folders stays in milliseconds.
enum ItemArranger {
    static func arrange(_ items: [FileItem], options: ArrangeOptions) -> [FileItem] {
        let needle = options.filter.trimmingCharacters(in: .whitespaces)
        let matcher = needle.isEmpty ? nil : NameMatcher(needle)
        let list: [FileItem]
        if options.showHidden && matcher == nil {
            list = items
        } else {
            list = items.filter { (options.showHidden || !$0.isHidden) && (matcher?.matches($0) ?? true) }
        }
        return sort(list, options: options)
    }

    static func matches(_ name: String, filter: String) -> Bool {
        NameMatcher(filter).matches(name)
    }

    static func sort(_ list: [FileItem], options: ArrangeOptions) -> [FileItem] {
        let count = list.count
        guard count > 1 else { return list }

        // Decorate once into flat arrays: comparisons then touch no objects,
        // no reference counts and no lazily cached properties.
        var isFolder = [Bool](repeating: false, count: count)
        var nameStart = [Int](repeating: 0, count: count)
        var nameLength = [Int](repeating: -1, count: count)   // -1: non-ASCII name
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count * 16)
        for (i, item) in list.enumerated() {
            isFolder[i] = options.foldersOnTop && item.type == .directory
            if let folded = item.sortKey.folded {
                nameStart[i] = bytes.count
                nameLength[i] = folded.count
                bytes.append(contentsOf: folded)
            }
        }
        var values: [Double] = []
        switch options.sortKey {
        case .name: break
        case .kind: values = kindRanks(of: list)
        case .modified: values = list.map { $0.modified }
        case .created: values = list.map { $0.created }
        case .added: values = list.map { $0.added }
        case .size: values = list.map { Double($0.displaySize) }
        }

        let byName = options.sortKey == .name, ascending = options.ascending
        var order = Array(0..<count)
        bytes.withUnsafeBufferPointer { (b: UnsafeBufferPointer<UInt8>) -> Void in
            func nameOrder(_ i: Int, _ j: Int) -> ComparisonResult {
                let li = nameLength[i], lj = nameLength[j]
                guard li >= 0, lj >= 0 else { return NameSortKey.compare(list[i].sortKey, list[j].sortKey) }
                let r = NameSortKey.compareFolded(UnsafeBufferPointer(rebasing: b[nameStart[i] ..< nameStart[i] + li]),
                                                  UnsafeBufferPointer(rebasing: b[nameStart[j] ..< nameStart[j] + lj]))
                if r != .orderedSame { return r }
                let a = list[i].name, c = list[j].name
                return a < c ? .orderedAscending : (a == c ? .orderedSame : .orderedDescending)
            }
            order.sort { i, j in
                if isFolder[i] != isFolder[j] { return isFolder[i] }
                // Kinds, dates and sizes first; equal ones by name, always A to Z.
                if !byName, values[i] != values[j] { return ascending ? values[i] < values[j] : values[i] > values[j] }
                let r = nameOrder(i, j)
                // Identical names (search results from different folders) keep their order.
                if r == .orderedSame { return i < j }
                return byName ? (ascending ? r == .orderedAscending : r == .orderedDescending) : r == .orderedAscending
            }
        }
        return order.map { list[$0] }
    }

    /// Each item's kind as its position in the natural order of the kinds
    /// present: one lookup per item, and the sort compares numbers.
    private static func kindRanks(of list: [FileItem]) -> [Double] {
        let kinds = list.map { FileKinds.kind(for: $0) }
        let ordered = Set(kinds).map { NameSortKey($0) }.sorted { NameSortKey.compare($0, $1) == .orderedAscending }
        var rank: [String: Double] = [:]
        var current = 0.0
        for (i, key) in ordered.enumerated() {
            // Kinds that compare equal share a rank, so their items fall back to the name.
            if i > 0 && NameSortKey.compare(ordered[i - 1], key) != .orderedSame { current += 1 }
            rank[key.name] = current
        }
        return kinds.map { rank[$0] ?? 0 }
    }
}

/// Case-, diacritic- and width-insensitive "name contains" test, as Finder
/// filters. For a pure-ASCII needle and name that folding is plain ASCII
/// lower-casing (no ASCII character has accented or wide forms), so those are
/// compared as bytes; anything else goes through Foundation.
struct NameMatcher {
    let needle: String
    /// The needle's lower-cased ASCII bytes, nil when it has other characters.
    private let folded: [UInt8]?

    init(_ needle: String) {
        self.needle = needle
        var bytes: [UInt8] = []
        bytes.reserveCapacity(needle.utf8.count)
        var ascii = true
        for b in needle.utf8 {
            if b >= 0x80 { ascii = false; break }
            bytes.append(NameMatcher.lower(b))
        }
        folded = ascii ? bytes : nil
    }

    @inline(__always)
    private static func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }

    func matches(_ item: FileItem) -> Bool {
        if let folded, let name = item.sortKey.folded { return NameMatcher.contains(name, folded) }
        return matches(item.name)
    }

    func matches(_ name: String) -> Bool {
        if let folded {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(name.utf8.count)
            var ascii = true
            for b in name.utf8 {
                if b >= 0x80 { ascii = false; break }
                bytes.append(NameMatcher.lower(b))
            }
            if ascii { return NameMatcher.contains(bytes, folded) }
        }
        return name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    /// The same test on a NUL-terminated name, without creating a String for ASCII names.
    func matches(cString name: UnsafePointer<CChar>) -> Bool {
        guard let folded else { return matches(String(cString: name)) }
        let length = strlen(name)
        var i = 0
        while i < length {
            if UInt8(bitPattern: name[i]) >= 0x80 { return matches(String(cString: name)) }
            i += 1
        }
        let n = folded.count
        guard n > 0, n <= length else { return false }
        var start = 0
        while start <= length - n {
            var k = 0
            while k < n && NameMatcher.lower(UInt8(bitPattern: name[start + k])) == folded[k] { k += 1 }
            if k == n { return true }
            start += 1
        }
        return false
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        let n = needle.count, h = haystack.count
        guard n > 0, n <= h else { return false }
        var start = 0
        while start <= h - n {
            var k = 0
            while k < n && haystack[start + k] == needle[k] { k += 1 }
            if k == n { return true }
            start += 1
        }
        return false
    }
}
