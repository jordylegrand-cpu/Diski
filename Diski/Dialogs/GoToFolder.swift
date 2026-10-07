import AppKit

/// "Go to Folder" (⇧⌘G) with live path completion and fuzzy matching on
/// recently visited folders.
final class GoToFolderModel {
    var text: String {
        didSet { recompute() }
    }
    private(set) var suggestions: [String] = []
    var selected = 0
    var onChange: (() -> Void)?
    /// The folder last listed and its subfolders' names (hidden ones too),
    /// sorted: typing more of a name only filters them.
    private var cachedParent: String?
    private var cachedNames: [(name: String, lower: [UInt8])] = []
    private var listings: [String: [(name: String, lower: [UInt8])]] = [:]
    private var listingWork: DispatchWorkItem?
    private var generation = 0
    private var recentPaths: [String] = []
    private var recentBytes: [[UInt8]] = []
    private var recentLowercase: [String] = []
    private static let listingQueue = DispatchQueue(label: "app.diski.folder-completion", qos: .userInitiated)

    deinit { listingWork?.cancel() }

    init(start: String) {
        let home = NSHomeDirectory()
        if start.hasPrefix(home) {
            text = "~" + start.dropFirst(home.count) + "/"
        } else {
            text = start == "/" ? "/" : start + "/"
        }
        recompute()
    }

    var expanded: String {
        (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    func recompute() {
        generation += 1
        listingWork?.cancel()
        let request = generation
        let raw = text.trimmingCharacters(in: .whitespaces)
        var results: [String] = []
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let path = (raw as NSString).expandingTildeInPath
            let parent: String
            let prefix: String
            if raw.hasSuffix("/") {
                parent = path
                prefix = ""
            } else {
                parent = (path as NSString).deletingLastPathComponent
                prefix = (path as NSString).lastPathComponent.lowercased()
            }
            // The folder is read and sorted once, not on every keystroke.
            let directory = parent.isEmpty ? "/" : parent
            if directory != cachedParent {
                cachedParent = directory
                cachedNames = listings[directory] ?? []
                if listings[directory] == nil {
                    let work = DispatchWorkItem { [weak self] in
                        var all: [String] = []
                        try? DirectoryReader.forEachEntry(inDirectory: directory, detailed: true,
                            include: { _, type in type == DirectoryReader.vDIR || type == DirectoryReader.vLNK }) { item in
                            if item.isNavigable { all.append(item.name) }
                        }
                        all.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                        let names = all.map { (name: $0, lower: Array($0.lowercased().utf8)) }
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.listings[directory] = names
                            guard request == self.generation else { return }
                            self.cachedNames = names
                            self.recompute()
                        }
                    }
                    listingWork = work
                    Self.listingQueue.asyncAfter(deadline: .now() + 0.08, execute: work)
                }
            } else if let names = listings[directory] {
                cachedNames = names
            } else {
                // A cancelled request for this directory must be rescheduled.
                cachedParent = nil
                recompute()
                return
            }
            let needle = Array(prefix.utf8)
            let names = cachedNames.lazy.filter {
                (!$0.name.hasPrefix(".") || prefix.hasPrefix(".")) && $0.lower.starts(with: needle)
            }
            let base = parent == "/" ? "" : parent
            results = names.prefix(12).map { base + "/" + $0.name }
        } else if !raw.isEmpty {
            let paths = Prefs.recentFolders
            if paths != recentPaths {
                recentPaths = paths
                recentLowercase = paths.map { $0.lowercased() }
                recentBytes = recentLowercase.map { Array($0.utf8) }
            }
            let lowercase = raw.lowercased()
            let needle = Array(lowercase.utf8)
            let ascii = needle.allSatisfy { $0 < 128 }
            results = recentPaths.indices.lazy.filter {
                ascii ? self.fuzzyMatch(needle, self.recentBytes[$0])
                    : self.fuzzyMatchCharacters(lowercase, self.recentLowercase[$0])
            }.prefix(12).map { recentPaths[$0] }
        } else {
            results = Array(Prefs.recentFolders.prefix(12))
        }
        suggestions = results
        selected = 0
        onChange?()
    }

    /// Characters of `needle` appear in order in `haystack`.
    private func fuzzyMatch(_ needle: [UInt8], _ haystack: [UInt8]) -> Bool {
        var index = 0
        for byte in needle {
            while index < haystack.count && haystack[index] != byte { index += 1 }
            guard index < haystack.count else { return false }
            index += 1
        }
        return true
    }

    private func fuzzyMatchCharacters(_ needle: String, _ haystack: String) -> Bool {
        var index = haystack.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }

    func completeSelection() {
        guard selected < suggestions.count else { return }
        text = abbreviate(suggestions[selected]) + "/"
    }

    func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The folder to open: the typed path when it exists, else the highlighted suggestion.
    func destination() -> String? {
        let typed = expanded
        var isDirectory: ObjCBool = false
        if !text.trimmingCharacters(in: .whitespaces).isEmpty,
           FileManager.default.fileExists(atPath: typed, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? typed : (typed as NSString).deletingLastPathComponent
        }
        if selected < suggestions.count { return suggestions[selected] }
        return nil
    }
}

/// One suggestion: folder icon, name and where it is.
private final class GoToFolderCell: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let location = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [icon, name, location] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        location.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingHead
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            location.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            // A long name truncates in the middle instead of running off the row.
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            location.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            location.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { location.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor }
    }
}

/// The Go to Folder sheet: a path field with completion and a list of
/// matching folders. Return opens, Tab completes, ↑↓ choose, Esc cancels.
final class GoToFolderController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var current: GoToFolderController?

    private let model: GoToFolderModel
    private let panel: NSPanel
    private weak var parent: NSWindow?
    private let completion: (String) -> Void
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var tableHeight: NSLayoutConstraint!
    private static let rowHeight: CGFloat = 24

    static func present(on window: NSWindow, startingAt path: String, completion: @escaping (String) -> Void) {
        let controller = GoToFolderController(window: window, path: path, completion: completion)
        current = controller
        window.beginSheet(controller.panel) { _ in current = nil }
        controller.panel.makeFirstResponder(controller.field)
        controller.field.currentEditor()?.selectedRange = NSRange(location: (controller.field.stringValue as NSString).length, length: 0)
    }

    private init(window: NSWindow, path: String, completion: @escaping (String) -> Void) {
        model = GoToFolderModel(start: path)
        parent = window
        self.completion = completion
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                        styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        super.init()
        build()
        model.onChange = { [weak self] in self?.reload() }
        reload()
    }

    private func build() {
        let title = NSTextField(labelWithString: "Go to Folder")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        field.stringValue = model.text
        field.font = .systemFont(ofSize: 14)
        field.bezelStyle = .roundedBezel
        field.placeholderString = "Type a path, or part of a folder name"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = Self.rowHeight - 2
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(go)
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Tab completes · ↑↓ choose · Return opens")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let go = NSButton(title: "Go", target: self, action: #selector(go))
        go.keyEquivalent = "\r"
        let buttons = NSStackView(views: [hint, NSView(), cancel, go])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        title.translatesAutoresizingMaskIntoConstraints = false
        for view in [title, field, scroll, buttons] as [NSView] { content.addSubview(view) }
        tableHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            field.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            tableHeight,
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        panel.contentView = content
    }

    private func reload() {
        table.reloadData()
        let visible = min(model.suggestions.count, 8)
        tableHeight.constant = CGFloat(visible) * Self.rowHeight + (visible > 0 ? 8 : 0)
        if model.selected < model.suggestions.count {
            table.selectRowIndexes(IndexSet(integer: model.selected), byExtendingSelection: false)
            table.scrollRowToVisible(model.selected)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        if let content = panel.contentView {
            let size = content.fittingSize
            if abs(panel.frame.height - panel.frameRect(forContentRect: NSRect(origin: .zero, size: size)).height) > 0.5 {
                panel.setContentSize(size)
            }
        }
    }

    /// Moves the highlight only: the rows themselves are unchanged.
    private func selectSuggestion() {
        guard model.selected < model.suggestions.count else { return }
        table.selectRowIndexes(IndexSet(integer: model.selected), byExtendingSelection: false)
        table.scrollRowToVisible(model.selected)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("GoToFolderCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? GoToFolderCell
            ?? { let cell = GoToFolderCell(); cell.identifier = id; return cell }()
        let path = model.suggestions[row]
        cell.name.stringValue = FileManager.default.displayName(atPath: path)
        cell.location.stringValue = model.abbreviate((path as NSString).deletingLastPathComponent)
        cell.icon.image = IconCache.shared.cachedItemIcon(path: path) ?? IconCache.shared.genericFolder
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { model.selected = table.selectedRow }
    }

    // MARK: Field

    func controlTextDidChange(_ notification: Notification) {
        model.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            model.selected = min(model.selected + 1, max(0, model.suggestions.count - 1))
            selectSuggestion()
            return true
        case #selector(NSResponder.moveUp(_:)):
            model.selected = max(model.selected - 1, 0)
            selectSuggestion()
            return true
        case #selector(NSResponder.insertTab(_:)):
            model.completeSelection()
            field.stringValue = model.text
            field.currentEditor()?.selectedRange = NSRange(location: (model.text as NSString).length, length: 0)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            go()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    @objc private func go() {
        if table.clickedRow >= 0 { model.selected = table.clickedRow }
        guard let destination = model.destination() else {
            NSSound.beep()
            return
        }
        parent?.endSheet(panel)
        completion(destination)
    }

    @objc private func cancel() {
        parent?.endSheet(panel)
    }
}

/// "Connect to Server…" (⌘K): mounts smb://, afp://, nfs:// and webdav URLs.
enum ConnectToServer {
    static func present(on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Enter a server address, for example smb://nas.local/Share"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: UserDefaults.standard.string(forKey: "lastServer") ?? "smb://")
        // Rounded like the Go to Folder field, at the control's own height.
        field.bezelStyle = .roundedBezel
        field.placeholderString = "smb://server/share"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: field.intrinsicContentSize.height)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return }
            UserDefaults.standard.set(field.stringValue, forKey: "lastServer")
            NSWorkspace.shared.open(url)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}
