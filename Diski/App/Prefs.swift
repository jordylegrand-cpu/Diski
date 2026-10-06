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

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 22
        case .regular: return 26
        case .comfortable: return 30
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .compact: return 16
        case .regular: return 20
        case .comfortable: return 26
        }
    }
}

/// User preferences (UserDefaults-backed). Posts `Prefs.didChange` on writes.
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

    private static func changed() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static var showHiddenFiles: Bool {
        get { defaults.bool(forKey: "showHiddenFiles") }
        set { defaults.set(newValue, forKey: "showHiddenFiles"); changed() }
    }

    static var foldersOnTop: Bool {
        get { defaults.bool(forKey: "foldersOnTop") }
        set { defaults.set(newValue, forKey: "foldersOnTop"); changed() }
    }

    static var showFullPathInTitle: Bool {
        get { defaults.bool(forKey: "showFullPathInTitle") }
        set { defaults.set(newValue, forKey: "showFullPathInTitle"); changed() }
    }

    static var calculateFolderSizes: Bool {
        get { defaults.bool(forKey: "calculateFolderSizes") }
        set { defaults.set(newValue, forKey: "calculateFolderSizes"); changed() }
    }

    static var useClones: Bool {
        get { defaults.bool(forKey: "useClones") }
        set { defaults.set(newValue, forKey: "useClones"); changed() }
    }

    /// Parallel copy streams; 0 means automatic.
    static var copyStreams: Int {
        get {
            let value = defaults.integer(forKey: "copyStreams")
            return value > 0 ? value : max(4, min(8, ProcessInfo.processInfo.activeProcessorCount))
        }
        set { defaults.set(newValue, forKey: "copyStreams"); changed() }
    }

    static var copyStreamsSetting: Int {
        get { defaults.integer(forKey: "copyStreams") }
        set { defaults.set(newValue, forKey: "copyStreams"); changed() }
    }

    static var returnKeyOpens: Bool {
        get { defaults.bool(forKey: "returnKeyOpens") }
        set { defaults.set(newValue, forKey: "returnKeyOpens"); changed() }
    }

    static var defaultViewMode: ViewMode {
        get { ViewMode(rawValue: defaults.integer(forKey: "defaultViewMode")) ?? .list }
        set { defaults.set(newValue.rawValue, forKey: "defaultViewMode"); changed() }
    }

    static var showPathBar: Bool {
        get { defaults.bool(forKey: "showPathBar") }
        set { defaults.set(newValue, forKey: "showPathBar"); changed() }
    }

    static var showStatusInfo: Bool {
        get { defaults.bool(forKey: "showStatusInfo") }
        set { defaults.set(newValue, forKey: "showStatusInfo"); changed() }
    }

    static var showInspector: Bool {
        get { defaults.bool(forKey: "showInspector") }
        set { defaults.set(newValue, forKey: "showInspector") }
    }

    static var rowDensity: RowDensity {
        get { RowDensity(rawValue: defaults.integer(forKey: "rowDensity")) ?? .comfortable }
        set { defaults.set(newValue.rawValue, forKey: "rowDensity"); changed() }
    }

    static var iconSize: CGFloat {
        get { CGFloat(defaults.double(forKey: "iconSize")) }
        set { defaults.set(Double(newValue), forKey: "iconSize"); changed() }
    }

    static var sortKey: SortKey {
        get { SortKey(rawValue: defaults.string(forKey: "sortKey") ?? "") ?? .name }
        set { defaults.set(newValue.rawValue, forKey: "sortKey") }
    }

    static var sortAscending: Bool {
        get { defaults.bool(forKey: "sortAscending") }
        set { defaults.set(newValue, forKey: "sortAscending") }
    }

    static var confirmEmptyTrash: Bool {
        get { defaults.bool(forKey: "confirmEmptyTrash") }
        set { defaults.set(newValue, forKey: "confirmEmptyTrash"); changed() }
    }

    static var showThumbnailsInList: Bool {
        get { defaults.bool(forKey: "showThumbnailsInList") }
        set { defaults.set(newValue, forKey: "showThumbnailsInList"); changed() }
    }

    static var showOperationToasts: Bool {
        get { defaults.bool(forKey: "showOperationToasts") }
        set { defaults.set(newValue, forKey: "showOperationToasts"); changed() }
    }

    static var listColumns: [String] {
        get { defaults.stringArray(forKey: "listColumns") ?? ["modified", "size", "kind"] }
        set { defaults.set(newValue, forKey: "listColumns"); changed() }
    }

    static var terminalBundleID: String {
        get { defaults.string(forKey: "terminalBundleID") ?? "com.apple.Terminal" }
        set { defaults.set(newValue, forKey: "terminalBundleID"); changed() }
    }

    static var newWindowPath: String {
        get { defaults.string(forKey: "newWindowPath") ?? NSHomeDirectory() }
        set { defaults.set(newValue, forKey: "newWindowPath"); changed() }
    }

    static var favorites: [String] {
        get {
            if let saved = defaults.stringArray(forKey: "favorites") { return saved }
            let home = NSHomeDirectory()
            var list = ["/Applications", home + "/Desktop", home + "/Documents", home + "/Downloads"]
            if FileManager.default.fileExists(atPath: home + "/Developer") { list.append(home + "/Developer") }
            return list
        }
        set { defaults.set(newValue, forKey: "favorites"); changed() }
    }

    static var recentFolders: [String] {
        get { defaults.stringArray(forKey: "recentFolders") ?? [] }
        set { defaults.set(Array(newValue.prefix(40)), forKey: "recentFolders") }
    }

    static func noteVisited(_ path: String) {
        var list = recentFolders
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        recentFolders = list
    }
}
