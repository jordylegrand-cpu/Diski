import AppKit

struct InfoRow: Equatable {
    let label: String
    let value: String
}

/// One "label … value" line of the preview pane's Information section, with
/// a hairline above it like Finder's.
final class InspectorRowView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let line = HairlineView()

    init(_ row: InfoRow, separator: Bool) {
        super.init(frame: .zero)
        for field in [label, value] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        label.stringValue = row.label
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        value.stringValue = row.value
        value.alignment = .right
        value.isSelectable = true
        let multiline = row.label == "Where" || row.label == "Where from"
        value.maximumNumberOfLines = multiline ? 3 : 1
        value.lineBreakMode = multiline ? .byCharWrapping : .byTruncatingMiddle
        value.cell?.truncatesLastVisibleLine = true
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.isHidden = !separator
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.firstBaselineAnchor.constraint(equalTo: value.firstBaselineAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            value.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3.5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 21.5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The preview pane (Finder's "Show Preview"): big preview, name, kind and
/// size, the Information section, tags and More…. Plain AppKit on the
/// split view's native inspector pane.
final class InspectorViewController: NSViewController, NSTokenFieldDelegate {
    private var token = 0
    private var currentKey = ""
    /// The folder whose size is shown; recalculated when its contents change.
    private var sizedFolder: (item: FileItem, kind: String)?
    private var sizeRefreshScheduled = false
    private var urls: [URL] = []
    private var shownTags: [String] = []
    private var rows: [InfoRow] = []
    private var moreRows: [InfoRow] = []
    private var showsMore = false

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let previewBox = NSView()
    private let preview = NSImageView()
    private let compactPreview = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let compactHeader = NSStackView()
    private let infoHeader = InspectorViewController.sectionTitle("Information")
    private let rowsStack = NSStackView()
    private let tagsHeader = InspectorViewController.sectionTitle("Tags")
    private let tagField = NSTokenField()
    private let moreButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No Selection")
    private let imageLoader = ItemImageLoader()
    private let compactLoader = ItemImageLoader()
    private var previewHeight: NSLayoutConstraint!

    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            currentKey = ""
            if isViewLoaded { applyCompactLayout() }
        }
    }

    private static func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return field
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 600))

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(preview)
        previewHeight = previewBox.heightAnchor.constraint(equalToConstant: 260)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        compactPreview.imageScaling = .scaleProportionallyUpOrDown
        compactPreview.translatesAutoresizingMaskIntoConstraints = false
        compactPreview.widthAnchor.constraint(equalToConstant: 40).isActive = true
        compactPreview.heightAnchor.constraint(equalToConstant: 40).isActive = true
        compactHeader.orientation = .horizontal
        compactHeader.spacing = 10
        compactHeader.alignment = .centerY

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0

        tagField.placeholderString = "Add Tags…"
        tagField.font = .systemFont(ofSize: 12)
        tagField.isBordered = false
        tagField.drawsBackground = false
        tagField.focusRingType = .none
        tagField.tokenStyle = .rounded
        tagField.delegate = self
        (tagField.cell as? NSTokenFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: "Add Tags…", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor])

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 16, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [previewBox, compactHeader, titleLabel, subtitleLabel, infoHeader, rowsStack, tagsHeader, tagField] as [NSView] {
            stack.addArrangedSubview(view)
        }
        for view in [previewBox, rowsStack, tagField, titleLabel, subtitleLabel] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -21).isActive = true
        }
        stack.setCustomSpacing(2, after: titleLabel)
        stack.setCustomSpacing(8, after: subtitleLabel)
        stack.setCustomSpacing(3, after: infoHeader)
        stack.setCustomSpacing(12, after: rowsStack)
        stack.setCustomSpacing(2, after: tagsHeader)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        moreButton.isBordered = false
        moreButton.imagePosition = .imageAbove
        moreButton.imageHugsTitle = true
        moreButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        moreButton.contentTintColor = .secondaryLabelColor
        moreButton.target = self
        moreButton.action = #selector(toggleMore)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        updateMoreButton()

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(moreButton)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            preview.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            preview.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            {
                let fill = preview.widthAnchor.constraint(equalTo: previewBox.widthAnchor, constant: -14)
                fill.priority = .defaultHigh
                return fill
            }(),
            preview.widthAnchor.constraint(lessThanOrEqualToConstant: 256),
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor),
            previewHeight,
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: moreButton.topAnchor, constant: -6),
            moreButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            moreButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        applyCompactLayout()
        setHasContent(false)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(folderContentsDidChange(_:)),
                           name: DirectoryStore.folderContentsDidChange, object: nil)
        center.addObserver(self, selector: #selector(directoryDidUpdate(_:)),
                           name: DirectoryStore.didUpdate, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The preview area is a bit taller than wide, like Finder's.
        let height = compact ? 0 : min(320, max(160, (view.bounds.width * 1.27).rounded()))
        if previewHeight.constant != height { previewHeight.constant = height }
    }

    private func applyCompactLayout() {
        previewBox.isHidden = compact
        compactHeader.isHidden = !compact
        if compact {
            compactHeader.setViews([compactPreview, verticalTitles()], in: .leading)
            stack.edgeInsets.top = 16
        } else {
            for view in compactHeader.views { compactHeader.removeView(view) }
            if titleLabel.superview !== stack {
                stack.insertArrangedSubview(titleLabel, at: 2)
                stack.insertArrangedSubview(subtitleLabel, at: 3)
                titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -21).isActive = true
                subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -21).isActive = true
                stack.setCustomSpacing(2, after: titleLabel)
                stack.setCustomSpacing(8, after: subtitleLabel)
            }
            stack.edgeInsets.top = 0
        }
        stack.setCustomSpacing(16, after: compactHeader)
        view.needsLayout = true
    }

    private func verticalTitles() -> NSStackView {
        titleLabel.removeFromSuperview()
        subtitleLabel.removeFromSuperview()
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        return titles
    }

    private func setHasContent(_ hasContent: Bool) {
        scrollView.isHidden = !hasContent
        moreButton.isHidden = !hasContent
        emptyLabel.isHidden = hasContent
    }

    private func updateMoreButton() {
        moreButton.title = showsMore ? "Less" : "More…"
        moreButton.image = NSImage(systemSymbolName: showsMore ? "chevron.up.circle" : "ellipsis.circle",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    @objc private func toggleMore() {
        showsMore.toggle()
        updateMoreButton()
        rebuildRows()
    }

    private func setImage(_ image: NSImage?) {
        preview.image = image
        compactPreview.image = image
    }

    private func rebuildRows() {
        for view in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(view); view.removeFromSuperview() }
        let all = showsMore ? rows + moreRows : rows
        for (index, row) in all.enumerated() {
            let view = InspectorRowView(row, separator: index > 0)
            view.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        infoHeader.isHidden = all.isEmpty
    }

    private func setRows(_ newRows: [InfoRow]? = nil, more newMore: [InfoRow]? = nil) {
        if let newRows { rows = newRows }
        if let newMore { moreRows = newMore }
        rebuildRows()
    }

    // MARK: Showing items

    /// Shows `items`, or the folder at `folderPath` when nothing is selected.
    func show(items: [FileItem], folderPath: String?) {
        _ = view
        let key = items.map { "\($0.path)|\($0.modified)|\($0.labelIndex)" }.joined(separator: "\n") + "|" + (folderPath ?? "")
        guard key != currentKey else { return }
        currentKey = key
        token += 1
        let token = self.token
        sizedFolder = nil
        imageLoader.cancel()
        compactLoader.cancel()

        var subjects = items
        if subjects.isEmpty, let folderPath, let folder = FileItem.make(path: folderPath) {
            subjects = [folder]
        }
        guard !subjects.isEmpty else {
            urls = []
            setHasContent(false)
            return
        }
        setHasContent(true)
        urls = subjects.map { $0.url }
        if subjects.count > 1 {
            describeMultiple(subjects)
        } else {
            describe(subjects[0], token: token)
        }
    }

    private func describeMultiple(_ items: [FileItem]) {
        titleLabel.stringValue = "\(items.count) items"
        let total = items.reduce(Int64(0)) { $0 + max(0, $1.displaySize) }
        let folders = items.filter { $0.isDirectoryOnDisk }.count
        var parts: [String] = []
        if folders > 0 { parts.append(Formatters.count(folders, "folder")) }
        if items.count - folders > 0 { parts.append(Formatters.count(items.count - folders, "file")) }
        subtitleLabel.stringValue = parts.joined(separator: ", ") + (total > 0 ? " – " + Formatters.size(total) : "")
        setImage(NSWorkspace.shared.icon(forFiles: items.prefix(32).map { $0.path }) ?? IconCache.shared.immediateIcon(for: items[0]))
        let modified = items.map { $0.modified }.max() ?? 0
        setRows([InfoRow(label: "Latest change", value: Formatters.longDate(Date(timeIntervalSince1970: modified)))], more: [])
        setTags([])
    }

    private func describe(_ item: FileItem, token: Int) {
        titleLabel.stringValue = item.name
        let kind = FileKinds.kind(for: item)
        let size = item.displaySize
        subtitleLabel.stringValue = size >= 0 ? "\(kind) – \(Formatters.size(size))" : kind
        setImage(IconCache.shared.cachedItemIcon(path: item.path) ?? IconCache.shared.immediateIcon(for: item))
        setRows([
            InfoRow(label: "Created", value: Formatters.longDate(item.createdDate)),
            InfoRow(label: "Modified", value: Formatters.longDate(item.modifiedDate)),
        ], more: baseMoreRows(for: item, kind: kind))
        setTags([])

        // Artwork: the item's own icon, then a thumbnail for images, movies and documents.
        if compact {
            compactLoader.load(item, into: compactPreview, points: 40, thumbnails: true)
        } else {
            imageLoader.load(item, into: preview, points: min(256, max(64, preview.bounds.width)), thumbnails: true)
        }

        // Folder size, computed in the background.
        if item.type == .directory || (item.type == .package && item.size < 0) {
            sizedFolder = (item, kind)
            if let cached = FolderSizer.shared.cached(item.path) {
                applyFolderSize(cached, to: item, kind: kind)
            } else {
                subtitleLabel.stringValue = "\(kind) – Calculating…"
                FolderSizer.shared.size(of: item.path, progress: { [weak self] bytes in
                    guard let self, token == self.token else { return }
                    self.subtitleLabel.stringValue = "\(kind) – \(Formatters.size(bytes))…"
                }, completion: { [weak self] result in
                    guard let self, token == self.token else { return }
                    item.computedFolderSize = result.bytes
                    self.applyFolderSize(result, to: item, kind: kind)
                })
            }
        }

        // Spotlight metadata and tags (cheap, but off the main thread).
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metadata = ItemMetadata.load(url)
            DispatchQueue.main.async {
                guard let self, token == self.token else { return }
                var rows = self.rows
                if let lastOpened = metadata.lastOpened {
                    rows.append(InfoRow(label: "Last opened", value: Formatters.longDate(lastOpened)))
                }
                if let dimensions = metadata.dimensions { rows.append(InfoRow(label: "Dimensions", value: dimensions)) }
                if let duration = metadata.duration { rows.append(InfoRow(label: "Duration", value: duration)) }
                var more = self.moreRows
                if let version = metadata.version { more.append(InfoRow(label: "Version", value: version)) }
                if let whereFrom = metadata.whereFrom { more.append(InfoRow(label: "Where from", value: whereFrom)) }
                self.setRows(rows, more: more)
                self.setTags(metadata.tags)
            }
        }
    }

    private func setTags(_ tags: [String]) {
        shownTags = tags
        tagField.objectValue = tags
    }

    // MARK: Live folder size

    @objc private func folderContentsDidChange(_ notification: Notification) {
        guard let folder = sizedFolder?.item, let paths = notification.userInfo?["paths"] as? Set<String> else { return }
        let prefix = folder.path + "/"
        if paths.contains(folder.path) || paths.contains(where: { $0.hasPrefix(prefix) }) {
            scheduleSizeRefresh()
        }
    }

    @objc private func directoryDidUpdate(_ notification: Notification) {
        // Items added to or removed from the shown folder itself.
        guard let folder = sizedFolder?.item, let listing = notification.object as? DirectoryStore.Listing,
              listing.path == folder.path else { return }
        scheduleSizeRefresh()
    }

    /// Recalculates at most twice a second and keeps showing the old size meanwhile.
    private func scheduleSizeRefresh() {
        guard !sizeRefreshScheduled else { return }
        sizeRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.sizeRefreshScheduled = false
            guard let sized = self.sizedFolder else { return }
            let token = self.token
            FolderSizer.shared.size(of: sized.item.path) { [weak self] result in
                guard let self, token == self.token else { return }
                sized.item.computedFolderSize = result.bytes
                self.applyFolderSize(result, to: sized.item, kind: sized.kind)
            }
        }
    }

    private func applyFolderSize(_ result: FolderSizer.Result, to item: FileItem, kind: String) {
        subtitleLabel.stringValue = "\(kind) – \(Formatters.size(result.bytes))"
        var more = moreRows.filter { $0.label != "Size" && $0.label != "Contains" }
        more.insert(InfoRow(label: "Size", value: Formatters.preciseSize(result.bytes)), at: 0)
        more.insert(InfoRow(label: "Contains", value: Formatters.count(result.items, "item")), at: 1)
        setRows(more: more)
    }

    private func baseMoreRows(for item: FileItem, kind: String) -> [InfoRow] {
        var rows: [InfoRow] = []
        rows.append(InfoRow(label: "Kind", value: kind))
        if item.size >= 0 && item.type != .directory {
            rows.append(InfoRow(label: "Size", value: Formatters.preciseSize(item.size)))
            if item.allocatedSize > 0 {
                rows.append(InfoRow(label: "On disk", value: Formatters.size(item.allocatedSize)))
            }
        }
        rows.append(InfoRow(label: "Where", value: item.parentPath))
        if let added = item.addedDate { rows.append(InfoRow(label: "Added", value: Formatters.longDate(added))) }
        rows.append(InfoRow(label: "Permissions", value: ItemMetadata.permissions(item.mode)))
        if item.isLocked { rows.append(InfoRow(label: "Locked", value: "Yes")) }
        if item.isHidden { rows.append(InfoRow(label: "Hidden", value: "Yes")) }
        return rows
    }

    // MARK: Tag editing

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTokenField === tagField else { return }
        let tags = (tagField.objectValue as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard tags != shownTags, !urls.isEmpty else { return }
        // Tags removed here are removed from every selected item; added ones are added to all.
        let removed = Set(shownTags).subtracting(tags)
        let added = tags.filter { !shownTags.contains($0) }
        for url in urls {
            var current = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            current.removeAll { removed.contains($0) }
            for tag in added where !current.contains(tag) { current.append(tag) }
            try? (url as NSURL).setResourceValue(current, forKey: .tagNamesKey)
        }
        shownTags = tags
        ItemAttributes.reloadParents(of: urls)
        currentKey = ""
    }
}
