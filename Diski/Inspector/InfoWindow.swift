import AppKit
import UniformTypeIdentifiers

/// A document view whose subviews lay out from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A collapsible section of an Info window: a disclosure triangle, a bold
/// title ("General:") and the section's content, indented.
final class InfoSection: NSStackView {
    private let disclosure = NSButton()
    private let content: NSView
    var onToggle: (() -> Void)?

    init(title: String, content: NSView, expanded: Bool) {
        self.content = content
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.state = expanded ? .on : .off
        disclosure.target = self
        disclosure.action = #selector(toggle)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .semibold)
        label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleFromTitle)))
        let header = NSStackView(views: [disclosure, label])
        header.orientation = .horizontal
        header.spacing = 3
        addArrangedSubview(header)

        let indent = NSStackView(views: [content])
        indent.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 2, right: 0)
        indent.alignment = .leading
        addArrangedSubview(indent)
        indent.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        content.isHidden = !expanded
        indent.isHidden = !expanded
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleFromTitle() {
        disclosure.state = disclosure.state == .on ? .off : .on
        toggle()
    }

    @objc private func toggle() {
        let expanded = disclosure.state == .on
        content.isHidden = !expanded
        content.superview?.isHidden = !expanded
        onToggle?()
    }
}

/// Finder's Get Info window (⌘I): one native window per item with General,
/// More Info, Name & Extension, Open With, Preview and Sharing & Permissions.
final class InfoWindowController: NSWindowController, NSWindowDelegate, NSTokenFieldDelegate {
    private static var controllers: [String: InfoWindowController] = [:]
    private static let width: CGFloat = 290

    static func show(path: String) {
        if let existing = controllers[path] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let item = FileItem.make(path: path) else {
            NSSound.beep()
            return
        }
        let controller = InfoWindowController(item: item)
        controllers[path] = controller
        controller.place()
        controller.showWindow(nil)
        // Nothing is focused at first, like Finder's Info windows.
        controller.window?.makeFirstResponder(nil)
    }

    private var item: FileItem
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let headerSize = NSTextField(labelWithString: "")
    private let headerName = NSTextField(labelWithString: "")
    private var generalSize: NSTextField?
    private let nameField = NSTextField()
    private let hideExtension = NSButton(checkboxWithTitle: "Hide extension", target: nil, action: nil)
    private let locked = NSButton(checkboxWithTitle: "Locked", target: nil, action: nil)
    private let tagField = NSTokenField()
    private var moreInfoGrid = NSGridView()
    private var appPopup: NSPopUpButton?
    private var changeAll: NSButton?
    private var appURLs: [URL] = []
    private let previewLoader = ItemImageLoader()
    private var shownTags: [String] = []

    private init(item: FileItem) {
        self.item = item
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: InfoWindowController.width, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(item.name) Info"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        build()
        loadAsyncFacts()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var url: URL { item.url }

    // MARK: Layout

    private func build() {
        guard let window else { return }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 18, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addFullWidth(header())
        tagField.placeholderString = "Add Tags…"
        tagField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tagField.tokenStyle = .rounded
        tagField.delegate = self
        tagField.translatesAutoresizingMaskIntoConstraints = false
        addFullWidth(tagField)

        addSection("General:", expanded: true, content: general())
        addSection("More Info:", expanded: true, content: moreInfo())
        addSection("Name & Extension:", expanded: false, content: nameAndExtension())
        if item.type == .file || (item.type == .package && !item.isApplication) {
            addSection("Open with:", expanded: true, content: openWith())
        }
        addSection("Preview:", expanded: true, content: preview())
        addSection("Sharing & Permissions:", expanded: false, content: permissions())

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        window.contentView = scrollView
        fitWindow(animate: false)
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }

    private func addSection(_ title: String, expanded: Bool, content: NSView) {
        let section = InfoSection(title: title, content: content, expanded: expanded)
        section.onToggle = { [weak self] in self?.fitWindow(animate: true) }
        stack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }

    private func header() -> NSView {
        let icon = NSImageView()
        icon.image = IconCache.shared.cachedItemIcon(path: item.path) ?? NSWorkspace.shared.icon(forFile: item.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        headerName.stringValue = item.name
        headerName.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        headerName.lineBreakMode = .byTruncatingMiddle
        headerName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let modified = NSTextField(labelWithString: "Modified: \(Formatters.longDate(item.modifiedDate))")
        modified.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modified.textColor = .secondaryLabelColor
        modified.lineBreakMode = .byTruncatingTail
        modified.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [headerName, modified])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        headerSize.font = .systemFont(ofSize: NSFont.systemFontSize)
        headerSize.stringValue = item.isDirectoryOnDisk ? "--" : Formatters.size(item.displaySize)
        headerSize.setContentHuggingPriority(.required, for: .horizontal)
        headerSize.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, text, headerSize])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    private static func gridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.alignment = .right
        return label
    }

    private static func gridValue(_ text: String, lines: Int = 1) -> NSTextField {
        let value = lines > 1 ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        value.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        value.isSelectable = true
        value.lineBreakMode = lines > 1 ? .byCharWrapping : .byTruncatingMiddle
        value.maximumNumberOfLines = lines
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.preferredMaxLayoutWidth = 170
        return value
    }

    private func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [Self.gridLabel($0.0), $0.1] })
        grid.rowSpacing = 4
        grid.columnSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        return grid
    }

    private func general() -> NSView {
        let kind = FileKinds.kind(for: item)
        let sizeValue = Self.gridValue(sizeDescription(nil), lines: 2)
        generalSize = sizeValue
        var rows: [(String, NSView)] = [
            ("Kind:", Self.gridValue(kind)),
            ("Size:", sizeValue),
            ("Where:", Self.gridValue(ItemMetadata.displayPath(item.parentPath), lines: 3)),
            ("Created:", Self.gridValue(Formatters.longDate(item.createdDate))),
            ("Modified:", Self.gridValue(Formatters.longDate(item.modifiedDate))),
        ]
        if item.type == .symlink, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) {
            rows.insert(("Original:", Self.gridValue(target, lines: 3)), at: 3)
        }
        let grid = self.grid(rows)
        locked.state = item.isLocked ? .on : .off
        locked.target = self
        locked.action = #selector(toggleLocked)
        locked.controlSize = .small
        locked.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let column = NSStackView(views: [grid, locked])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        if item.isMountPoint || item.path == "/" { locked.isHidden = true }
        return column
    }

    private func sizeDescription(_ result: FolderSizer.Result?) -> String {
        if item.isDirectoryOnDisk {
            guard let result else { return "Calculating…" }
            return "\(Formatters.preciseSize(result.bytes)) (\(Formatters.size(result.bytes)) on disk) for \(Formatters.count(result.items, "item"))"
        }
        let onDisk = item.allocatedSize > 0 ? " (\(Formatters.size(item.allocatedSize)) on disk)" : ""
        return Formatters.preciseSize(max(0, item.size)) + onDisk
    }

    private func moreInfo() -> NSView {
        moreInfoGrid = grid([("Last opened:", Self.gridValue("--"))])
        return moreInfoGrid
    }

    private func nameAndExtension() -> NSView {
        nameField.stringValue = item.name
        nameField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameField.controlSize = .small
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.translatesAutoresizingMaskIntoConstraints = false
        hideExtension.controlSize = .small
        hideExtension.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hideExtension.target = self
        hideExtension.action = #selector(toggleHiddenExtension)
        hideExtension.state = ((try? url.resourceValues(forKeys: [.hasHiddenExtensionKey]))?.hasHiddenExtension ?? false) ? .on : .off
        hideExtension.isHidden = (item.name as NSString).pathExtension.isEmpty
        let column = NSStackView(views: [nameField, hideExtension])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        nameField.widthAnchor.constraint(equalToConstant: Self.width - 32 - 18).isActive = true
        return column
    }

    private func openWith() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let preferred, !apps.contains(preferred) { apps.insert(preferred, at: 0) }
        appURLs = apps
        for app in apps {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let entry = NSMenuItem(title: app == preferred ? "\(name) (default)" : name, action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            popup.menu?.addItem(entry)
        }
        if apps.isEmpty {
            popup.addItem(withTitle: "No application available")
            popup.isEnabled = false
        }
        if let preferred, let index = apps.firstIndex(of: preferred) { popup.selectItem(at: index) }
        popup.target = self
        popup.action = #selector(appChosen)
        appPopup = popup

        let note = NSTextField(wrappingLabelWithString: "Use this application to open all documents like this one.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = Self.width - 32 - 18
        let button = NSButton(title: "Change All…", target: self, action: #selector(changeAllDocuments))
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.isEnabled = false
        changeAll = button
        let column = NSStackView(views: [popup, note, button])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        popup.widthAnchor.constraint(equalToConstant: Self.width - 32 - 18).isActive = true
        return column
    }

    private func preview() -> NSView {
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: Self.width - 32 - 18).isActive = true
        image.heightAnchor.constraint(equalToConstant: 180).isActive = true
        previewLoader.load(item, into: image, points: 180, thumbnails: true)
        return image
    }

    private func permissions() -> NSView {
        let canWrite = access(item.path, W_OK) == 0
        let canRead = access(item.path, R_OK) == 0
        let summary = NSTextField(labelWithString: canWrite && canRead ? "You can read and write"
                                  : canRead ? "You can only read" : "You have no access")
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        var st = stat()
        lstat(item.path, &st)
        let owner = getpwuid(st.st_uid).map { String(cString: $0.pointee.pw_name) } ?? "\(st.st_uid)"
        let group = getgrgid(st.st_gid).map { String(cString: $0.pointee.gr_name) } ?? "\(st.st_gid)"
        let mode = item.mode
        let you = owner == NSUserName() ? "\(owner) (Me)" : owner
        let rows: [[NSView]] = [
            [Self.gridLabel("Name"), Self.gridLabel("Privilege")],
            [Self.gridValue(you), Self.gridValue(ItemMetadata.privilege(mode, shift: 6))],
            [Self.gridValue(group), Self.gridValue(ItemMetadata.privilege(mode, shift: 3))],
            [Self.gridValue("everyone"), Self.gridValue(ItemMetadata.privilege(mode, shift: 0))],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 14
        for row in 0..<grid.numberOfRows {
            for column in 0..<2 { (grid.cell(atColumnIndex: column, rowIndex: row).contentView as? NSTextField)?.alignment = .left }
        }
        let column = NSStackView(views: [summary, grid])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        return column
    }

    // MARK: Facts that take a moment

    private func loadAsyncFacts() {
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metadata = ItemMetadata.load(url)
            DispatchQueue.main.async { self?.apply(metadata) }
        }
        if item.isDirectoryOnDisk {
            let path = item.path
            if let cached = FolderSizer.shared.cached(path) {
                applyFolderSize(cached)
            } else {
                FolderSizer.shared.size(of: path) { [weak self] result in self?.applyFolderSize(result) }
            }
        }
    }

    private func applyFolderSize(_ result: FolderSizer.Result) {
        headerSize.stringValue = Formatters.size(result.bytes)
        generalSize?.stringValue = sizeDescription(result)
        fitWindow(animate: false)
    }

    private func apply(_ metadata: ItemMetadata) {
        shownTags = metadata.tags
        tagField.objectValue = metadata.tags
        var rows: [(String, String)] = []
        if let added = item.addedDate { rows.append(("Added:", Formatters.longDate(added))) }
        rows.append(("Last opened:", metadata.lastOpened.map { Formatters.longDate($0) } ?? "--"))
        if let dimensions = metadata.dimensions { rows.append(("Dimensions:", dimensions)) }
        if let duration = metadata.duration { rows.append(("Duration:", duration)) }
        if let version = metadata.version { rows.append(("Version:", version)) }
        if let whereFrom = metadata.whereFrom { rows.append(("Where from:", whereFrom)) }
        while moreInfoGrid.numberOfRows > 0 { moreInfoGrid.removeRow(at: 0) }
        for (label, value) in rows {
            moreInfoGrid.addRow(with: [Self.gridLabel(label), Self.gridValue(value, lines: label == "Where from:" ? 3 : 1)])
        }
        fitWindow(animate: false)
    }

    // MARK: Window size

    private func fitWindow(animate: Bool) {
        guard let window else { return }
        stack.layoutSubtreeIfNeeded()
        let wanted = stack.fittingSize.height
        let limit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = min(wanted, limit - 60)
        let content = NSRect(x: 0, y: 0, width: Self.width, height: height)
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        // Keep the whole window on screen: move it up when it grows past the bottom.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    /// Cascades from the key window's top-left, like Finder's Info windows.
    fileprivate func place() {
        guard let window else { return }
        let others = Self.controllers.values.compactMap { $0 === self ? nil : $0.window }.filter { $0.isVisible }
        if let last = others.last {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else if let browser = NSApp.keyWindow ?? NSApp.mainWindow {
            window.setFrameTopLeftPoint(NSPoint(x: browser.frame.maxX - window.frame.width - 40,
                                                y: browser.frame.maxY - 60))
        } else {
            window.center()
        }
        fitWindow(animate: false)
    }

    // MARK: Actions

    @objc private func toggleLocked() {
        do {
            try ItemAttributes.setLocked(locked.state == .on, on: url)
        } catch {
            locked.state = locked.state == .on ? .off : .on
            _ = presentError(error)
        }
    }

    @objc private func toggleHiddenExtension() {
        do {
            try ItemAttributes.setHiddenExtension(hideExtension.state == .on, on: url)
        } catch {
            hideExtension.state = hideExtension.state == .on ? .off : .on
            _ = presentError(error)
        }
    }

    @objc private func appChosen() {
        guard let popup = appPopup, popup.indexOfSelectedItem < appURLs.count else { return }
        let chosen = appURLs[popup.indexOfSelectedItem]
        changeAll?.isEnabled = chosen != NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    @objc private func changeAllDocuments() {
        guard let window, let popup = appPopup, popup.indexOfSelectedItem < appURLs.count,
              let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return }
        let app = appURLs[popup.indexOfSelectedItem]
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to change all similar documents to open with “\(appName)”?"
        alert.informativeText = "This change will apply to all “\(type.localizedDescription ?? type.identifier)” documents."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                DispatchQueue.main.async {
                    if let error { _ = self?.presentError(error) } else { self?.changeAll?.isEnabled = false }
                }
            }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSControl else { return }
        if field === nameField {
            rename(to: nameField.stringValue)
        } else if field === tagField {
            let tags = (tagField.objectValue as? [Any] ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard tags != shownTags else { return }
            shownTags = tags
            ItemAttributes.setTags(tags, on: [url])
        }
    }

    private func rename(to newName: String) {
        guard newName != item.name else { return }
        do {
            let oldPath = item.path
            let renamed = try FileOperationManager.shared.rename(url, to: newName)
            DirectoryStore.shared.reload(paths: [DirectoryReader.normalized(renamed.deletingLastPathComponent().path)])
            if let fresh = FileItem.make(path: renamed.path) {
                item = fresh
                Self.controllers.removeValue(forKey: oldPath)
                Self.controllers[fresh.path] = self
                window?.title = "\(fresh.name) Info"
                headerName.stringValue = fresh.name
            }
        } catch {
            nameField.stringValue = item.name
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        previewLoader.cancel()
        Self.controllers.removeValue(forKey: item.path)
    }
}
