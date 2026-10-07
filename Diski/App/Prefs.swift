import AppKit

enum ViewMode: Int, CaseIterable {
    case icons = 0, list = 1, columns = 2, gallery = 3

    var title: String {
        switch self {
        case .icons: return "Icons"
        case .list: return "List"
        case .columns: return "Columns"
        case .gallery: return "Gallery"
        }
    }

    var symbol: String {
        switch self {
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .gallery: return "squares.below.rectangle"
        }
    }
}

enum SortKey: String, CaseIterable {
    case name, kind, modified, created, added, size

    var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .added: return "Date Added"
        case .size: return "Size"
        }
    }

    /// Dates and sizes read best newest/largest first.
    var defaultAscending: Bool {
        switch self {
        case .name, .kind: return true
        default: return false
        }
    }
}

enum RowDensity: Int, CaseIterable {
    case compact = 0, regular = 1, comfortable = 2

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .comfortable: return "Comfortable"
        }
    }

    // The list's row metrics (Finder's) live in ListViewController.swift
    // (RowDensity.listRowHeight).

    var iconSize: CGFloat {
        switch self {
        case .compact: return 16
        case .regular: return 24
        case .comfortable: return 32
        }
    }
}

/// User preferences (UserDefaults-backed). Posts `Prefs.didChange` (with the
/// setting's name under `changedKey`) when a write changes a value.
enum Prefs {
    static let didChange = Notification.Name("DiskiPrefsDidChange")
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            "showHiddenFiles": false,
            "foldersOnTop": true,
            "showFullPathInTitle": true,
            "calculateFolderSizes": true,
            "useClones": true,
            "copyStreams": 0,
            "returnKeyOpens": false,
            "defaultViewMode": ViewMode.list.rawValue,
            "showPathBar": true,
            "showStatusInfo": true,
            "showInspector": true,
            "rowDensity": RowDensity.comfortable.rawValue,
            "iconSize": 64.0,
            "sortKey": SortKey.name.rawValue,
            "sortAscending": true,
            "confirmEmptyTrash": true,
            "showThumbnailsInList": true,
            "listColumns": ["modified", "size", "kind"],
            "showOperationToasts": true,
            "terminalBundleID": "com.apple.Terminal",
        ])
    }

    /// `didChange` userInfo key: the name (String) of the setting that changed.
    static let changedKey = "key"

    private static func changed(_ key: String) {
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: [changedKey: key])
    }

    /// Writes `value` and posts `didChange`, only when the value really changes
    /// (a registered default counts as the current value).
    private static func store<T: Equatable>(_ value: T, forKey key: String, notify: Bool = true) {
        if let current = defaults.object(forKey: key) as? T, current == value { return }
        defaults.set(value, forKey: key)
        if notify { changed(key) }
    }

    static var showHiddenFiles: Bool {
        get { defaults.bool(forKey: "showHiddenFiles") }
        set { store(newValue, forKey: "showHiddenFiles") }
    }

    static var foldersOnTop: Bool {
        get { defaults.bool(forKey: "foldersOnTop") }
        set { store(newValue, forKey: "foldersOnTop") }
    }

    static var showFullPathInTitle: Bool {
        get { defaults.bool(forKey: "showFullPathInTitle") }
        set { store(newValue, forKey: "showFullPathInTitle") }
    }

    static var calculateFolderSizes: Bool {
        get { defaults.bool(forKey: "calculateFolderSizes") }
        set { store(newValue, forKey: "calculateFolderSizes") }
    }

    static var useClones: Bool {
        get { defaults.bool(forKey: "useClones") }
        set { store(newValue, forKey: "useClones") }
    }

    /// Parallel copy streams; 0 means automatic.
    static var copyStreams: Int {
        get {
            let value = defaults.integer(forKey: "copyStreams")
            return value > 0 ? value : max(4, min(8, ProcessInfo.processInfo.activeProcessorCount))
        }
        set { store(newValue, forKey: "copyStreams") }
    }

    static var copyStreamsSetting: Int {
        get { defaults.integer(forKey: "copyStreams") }
        set { store(newValue, forKey: "copyStreams") }
    }

    static var returnKeyOpens: Bool {
        get { defaults.bool(forKey: "returnKeyOpens") }
        set { store(newValue, forKey: "returnKeyOpens") }
    }

    static var defaultViewMode: ViewMode {
        get { ViewMode(rawValue: defaults.integer(forKey: "defaultViewMode")) ?? .list }
        set { store(newValue.rawValue, forKey: "defaultViewMode") }
    }

    static var showPathBar: Bool {
        get { defaults.bool(forKey: "showPathBar") }
        set { store(newValue, forKey: "showPathBar") }
    }

    static var showStatusInfo: Bool {
        get { defaults.bool(forKey: "showStatusInfo") }
        set { store(newValue, forKey: "showStatusInfo") }
    }

    static var showInspector: Bool {
        get { defaults.bool(forKey: "showInspector") }
        set { store(newValue, forKey: "showInspector", notify: false) }
    }

    static var rowDensity: RowDensity {
        get { RowDensity(rawValue: defaults.integer(forKey: "rowDensity")) ?? .comfortable }
        set { store(newValue.rawValue, forKey: "rowDensity") }
    }

    static var iconSize: CGFloat {
        get { CGFloat(defaults.double(forKey: "iconSize")) }
        set { store(Double(newValue), forKey: "iconSize") }
    }

    static var sortKey: SortKey {
        get { SortKey(rawValue: defaults.string(forKey: "sortKey") ?? "") ?? .name }
        set { store(newValue.rawValue, forKey: "sortKey", notify: false) }
    }

    static var sortAscending: Bool {
        get { defaults.bool(forKey: "sortAscending") }
        set { store(newValue, forKey: "sortAscending", notify: false) }
    }

    static var confirmEmptyTrash: Bool {
        get { defaults.bool(forKey: "confirmEmptyTrash") }
        set { store(newValue, forKey: "confirmEmptyTrash") }
    }

    static var showThumbnailsInList: Bool {
        get { defaults.bool(forKey: "showThumbnailsInList") }
        set { store(newValue, forKey: "showThumbnailsInList") }
    }

    static var showOperationToasts: Bool {
        get { defaults.bool(forKey: "showOperationToasts") }
        set { store(newValue, forKey: "showOperationToasts") }
    }

    static var listColumns: [String] {
        get { defaults.stringArray(forKey: "listColumns") ?? ["modified", "size", "kind"] }
        set { store(newValue, forKey: "listColumns") }
    }

    static var terminalBundleID: String {
        get { defaults.string(forKey: "terminalBundleID") ?? "com.apple.Terminal" }
        set { store(newValue, forKey: "terminalBundleID") }
    }

    static var newWindowPath: String {
        get { defaults.string(forKey: "newWindowPath") ?? NSHomeDirectory() }
        set { store(newValue, forKey: "newWindowPath") }
    }

    static var favorites: [String] {
        get {
            if let saved = defaults.stringArray(forKey: "favorites") { return saved }
            let home = NSHomeDirectory()
            var list = ["/Applications", home + "/Desktop", home + "/Documents", home + "/Downloads"]
            if FileManager.default.fileExists(atPath: home + "/Developer") { list.append(home + "/Developer") }
            return list
        }
        set { store(newValue, forKey: "favorites") }
    }

    static var recentFolders: [String] {
        get { defaults.stringArray(forKey: "recentFolders") ?? [] }
        set { store(Array(newValue.prefix(40)), forKey: "recentFolders", notify: false) }
    }

    static func noteVisited(_ path: String) {
        var list = recentFolders
        if list.first == path { return }
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        recentFolders = list
    }
}
