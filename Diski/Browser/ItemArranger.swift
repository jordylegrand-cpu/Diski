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
        var list = options.showHidden ? items : items.filter { !$0.isHidden }
        let needle = options.filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            list = list.filter { matches($0.name, filter: needle) }
        }
        return sort(list, options: options)
    }

    static func matches(_ name: String, filter: String) -> Bool {
        name.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    static func sort(_ list: [FileItem], options: ArrangeOptions) -> [FileItem] {
        let asc = options.ascending
        let foldersFirst = options.foldersOnTop

        func folderOrder(_ a: FileItem, _ b: FileItem) -> Bool? {
            guard foldersFirst else { return nil }
            let fa = a.type == .directory, fb = b.type == .directory
            return fa == fb ? nil : fa
        }

        func byName(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
            NameSortKey.compare(a.sortKey, b.sortKey)
        }

        switch options.sortKey {
        case .name:
            return list.sorted { a, b in
                if let f = folderOrder(a, b) { return f }
                let r = byName(a, b)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        case .kind:
            let decorated = list.map { ($0, NameSortKey(FileKinds.kind(for: $0))) }
            return decorated.sorted { x, y in
                if let f = folderOrder(x.0, y.0) { return f }
                var r = NameSortKey.compare(x.1, y.1)
                if r == .orderedSame { r = byName(x.0, y.0); return r == .orderedAscending }
                return asc ? r == .orderedAscending : r == .orderedDescending
            }.map { $0.0 }
        case .modified, .created, .added, .size:
            let key = options.sortKey
            let decorated: [(FileItem, Double)] = list.map { item in
                switch key {
                case .modified: return (item, item.modified)
                case .created: return (item, item.created)
                case .added: return (item, item.added)
                default: return (item, Double(item.displaySize))
                }
            }
            return decorated.sorted { x, y in
                if let f = folderOrder(x.0, y.0) { return f }
                if x.1 == y.1 { return byName(x.0, y.0) == .orderedAscending }
                return asc ? x.1 < y.1 : x.1 > y.1
            }.map { $0.0 }
        }
    }
}
