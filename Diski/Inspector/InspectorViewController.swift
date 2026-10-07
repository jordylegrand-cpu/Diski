import AppKit

struct InfoRow: Equatable {
    let label: String
    let value: String
    /// A date's medium form ("Sep 20, 2026 at 8:17 PM"), shown when the long
    /// one in `value` doesn't fit.
    var compactValue: String? = nil
}

/// One label/value line of the preview pane's Information section.
final class InspectorRowView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for field in [label, value] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        value.alignment = .right
        value.maximumNumberOfLines = 1
        value.allowsExpansionToolTips = true
        // Below the split view's holding priority: long values truncate
        // instead of widening the pane.
        value.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(210), for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.firstBaselineAnchor.constraint(equalTo: value.firstBaselineAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            // One line each, 23 pt apart: Finder's row pitch.
            value.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: 16),
            heightAnchor.constraint(equalToConstant: 23),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rows are reused; unchanged strings aren't set again.
    func configure(_ row: InfoRow, text: String) {
        if label.stringValue != row.label { label.stringValue = row.label }
        if value.stringValue != text { value.stringValue = text }
        // A path keeps its enclosing folder; anything else (a download's host
        // and file name) keeps both ends.
        let mode: NSLineBreakMode = row.label == "Where" ? .byTruncatingHead : .byTruncatingMiddle
        if value.lineBreakMode != mode { value.lineBreakMode = mode }
    }
}

/// The preview pane (Finder's "Show Preview"): big preview, name, kind and
/// size, the Information section, tags and More…. Plain AppKit on the
/// split view's native inspector pane.
final class InspectorViewController: NSViewController, NSTokenFieldDelegate {
    /// Leading and trailing content inset, Finder's.
    private static let inset: CGFloat = 10
    /// Spotlight lookups and tag writes: one at a time, in order.
    private static let metadataQueue = DispatchQueue(label: "app.diski.inspector.metadata", qos: .userInitiated)
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()
    private static let rowFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    private var token = 0
    private var currentKey = ""
    /// What was asked for while the pane couldn't be seen; shown once it can.
    private var pending: (items: [FileItem], folderPath: String?)?
    private var metadataWork: DispatchWorkItem?
    private var selectionWork: DispatchWorkItem?
    /// The folder whose size is shown; recalculated when its contents change.
    private var sizedFolder: (item: FileItem, kind: String)?
    private var sizeRefreshScheduled = false
    private var urls: [URL] = []
    private var shownTags: [String] = []
    private var rows: [InfoRow] = []
    private var moreRows: [InfoRow] = []
    private var showsMore = false
    /// Row views, reused; the ones in `rowsStack` are always a prefix.
    private var rowViews: [InspectorRowView] = []
    private var shownRows: [InfoRow] = []
    private var shownFullDates = false
    /// Whether the date rows show the long form. One choice for all of them, like Finder.
    private var fullDates = false
    /// The rows `longDatesWidth` was measured for.
    private var measuredRows: [InfoRow] = []
    /// The narrowest Information width that fits every date row's long form.
    private var longDatesWidth: CGFloat = 0
    private var dateWidth: CGFloat = -1

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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        // A thumbnail's own size must never widen the pane.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            preview.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: axis)
            preview.setContentHuggingPriority(NSLayoutConstraint.Priority(100), for: axis)
        }
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(preview)
        previewHeight = previewBox.heightAnchor.constraint(equalToConstant: 260)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        titleLabel.allowsExpansionToolTips = true
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        subtitleLabel.allowsExpansionToolTips = true

        compactPreview.imageScaling = .scaleProportionallyUpOrDown
        compactPreview.translatesAutoresizingMaskIntoConstraints = false
        compactPreview.widthAnchor.constraint(equalToConstant: 48).isActive = true
        compactPreview.heightAnchor.constraint(equalToConstant: 48).isActive = true
        compactHeader.orientation = .horizontal
        compactHeader.spacing = 10
        compactHeader.alignment = .centerY

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        // Its width picks the date length (rowsFrameDidChange).
        rowsStack.postsFrameChangedNotifications = true

        tagField.placeholderString = "Add Tags…"
        tagField.font = .systemFont(ofSize: NSFont.systemFontSize)
        tagField.isBordered = false
        tagField.drawsBackground = false
        tagField.focusRingType = .none
        tagField.tokenStyle = .rounded
        tagField.delegate = self
        tagField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        (tagField.cell as? NSTokenFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: "Add Tags…", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                             .foregroundColor: NSColor.tertiaryLabelColor])

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: 16, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [previewBox, compactHeader, titleLabel, subtitleLabel, infoHeader, rowsStack, tagsHeader, tagField] as [NSView] {
            stack.addArrangedSubview(view)
        }
        for view in [previewBox, rowsStack, tagField, titleLabel, subtitleLabel] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
        }
        // Finder's rhythm, baseline to baseline: title → subtitle 19 pt,
        // subtitle → Information 25, Information → first row 22, rows 23
        // apart, last row → Tags 32, Tags → Add Tags… 22.
        stack.setCustomSpacing(15, after: previewBox)
        stack.setCustomSpacing(3, after: titleLabel)
        stack.setCustomSpacing(9, after: subtitleLabel)
        stack.setCustomSpacing(3, after: infoHeader)
        stack.setCustomSpacing(12, after: rowsStack)
        stack.setCustomSpacing(6, after: tagsHeader)

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
        // The symbol at the top edge, the title in the space below it.
        moreButton.imageHugsTitle = false
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
                let fill = preview.widthAnchor.constraint(equalTo: previewBox.widthAnchor)
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
            // Finder: 28 pt from the circle's centre to the title's baseline,
            // which sits 18 pt above the bottom.
            moreButton.heightAnchor.constraint(equalToConstant: 48),
            moreButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            // Centred in the visible area, not under the toolbar.
            emptyLabel.centerYAnchor.constraint(equalTo: root.safeAreaLayoutGuide.centerYAnchor),
        ])
        view = root
        applyCompactLayout()
        setHasContent(false)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(folderContentsDidChange(_:)),
                           name: DirectoryStore.folderContentsDidChange, object: nil)
        center.addObserver(self, selector: #selector(directoryDidUpdate(_:)),
                           name: DirectoryStore.didUpdate, object: nil)
        center.addObserver(self, selector: #selector(rowsFrameDidChange(_:)),
                           name: NSView.frameDidChangeNotification, object: rowsStack)
    }

    deinit {
        selectionWork?.cancel()
        metadataWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The preview area is a bit taller than wide, like Finder's.
        let height = compact ? 0 : min(320, max(160, (view.bounds.width * 1.27).rounded()))
        if previewHeight.constant != height { previewHeight.constant = height }
        // The pane has just appeared: show what was asked for while it was hidden.
        // Async, so the rows aren't rebuilt in the middle of this layout pass.
        if pending != nil, view.window != nil, view.bounds.width > 1, !view.isHiddenOrHasHiddenAncestor {
            DispatchQueue.main.async { [weak self] in
                guard let self, let request = self.pending else { return }
                self.show(items: request.items, folderPath: request.folderPath)
            }
        }
    }

    private func applyCompactLayout() {
        previewBox.isHidden = compact
        compactHeader.isHidden = !compact
        if compact {
            compactHeader.setViews([compactPreview, verticalTitles()], in: .leading)
            stack.edgeInsets.top = 20
        } else {
            for view in compactHeader.views { compactHeader.removeView(view) }
            if titleLabel.superview !== stack {
                stack.insertArrangedSubview(titleLabel, at: 2)
                stack.insertArrangedSubview(subtitleLabel, at: 3)
                titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
                subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
                stack.setCustomSpacing(3, after: titleLabel)
                stack.setCustomSpacing(9, after: subtitleLabel)
            }
            stack.edgeInsets.top = 0
        }
        stack.setCustomSpacing(20, after: compactHeader)
        view.needsLayout = true
    }

    private func verticalTitles() -> NSStackView {
        titleLabel.removeFromSuperview()
        subtitleLabel.removeFromSuperview()
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3
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

    /// Shows `rows` (and `moreRows`) in reused row views; an identical update
    /// changes nothing.
    private func rebuildRows() {
        let all = showsMore ? rows + moreRows : rows
        if infoHeader.isHidden != all.isEmpty { infoHeader.isHidden = all.isEmpty }
        chooseDateLength(all)
        guard all != shownRows || fullDates != shownFullDates else { return }
        shownRows = all
        shownFullDates = fullDates
        while rowViews.count < all.count {
            let row = InspectorRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            rowViews.append(row)
        }
        // Rows beyond `all` are removed, not hidden: a stack view detaches hidden
        // views, which would drop their width constraint. Removed rows are always
        // a suffix, so re-added ones keep their order.
        for (index, row) in rowViews.enumerated() {
            if index < all.count {
                let info = all[index]
                row.configure(info, text: fullDates ? info.value : (info.compactValue ?? info.value))
                if row.superview == nil {
                    rowsStack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                }
            } else if row.superview != nil {
                rowsStack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
        }
    }

    /// Like Finder, one length for all date rows: the long form ("September 20,
    /// 2026 at 8:17 PM") when every one of them fits, otherwise the medium one.
    private func chooseDateLength(_ all: [InfoRow]) {
        if all != measuredRows {
            measuredRows = all
            // Each field pads its text by 2 pt on both sides; 10 pt between them.
            longDatesWidth = all.reduce(CGFloat(0)) { width, row in
                row.compactValue == nil ? width : max(width, Self.textWidth(row.label) + Self.textWidth(row.value) + 18)
            }
        }
        let width = rowsStack.bounds.width
        // Not laid out yet: keep the last choice until rowsFrameDidChange.
        guard width > 0 else { return }
        fullDates = width >= longDatesWidth
    }

    private static func textWidth(_ string: String) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: rowFont]).width)
    }

    /// The pane got wider or narrower: the date rows may switch length.
    @objc private func rowsFrameDidChange(_ notification: Notification) {
        let width = rowsStack.bounds.width
        guard width != dateWidth else { return }
        dateWidth = width
        rebuildRows()
    }

    /// A date row: the long form, with the medium one for narrow panes.
    private func dateRow(_ label: String, _ date: Date) -> InfoRow {
        InfoRow(label: label, value: Self.fullDateFormatter.string(from: date), compactValue: Formatters.longDate(date))
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
        // Nothing is seen while the pane is collapsed or not laid out yet: keep
        // the request for viewDidLayout and drop the work in flight.
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 1 else {
            pending = (items: items, folderPath: folderPath)
            currentKey = ""
            token += 1
            sizedFolder = nil
            imageLoader.cancel()
            compactLoader.cancel()
            metadataWork?.cancel()
            selectionWork?.cancel()
            return
        }
        pending = nil
        // Covers every item without building one long string for a big selection.
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.path)
            hasher.combine(item.modified)
            hasher.combine(item.labelIndex)
        }
        let key = "\(items.count)|\(hasher.finalize())|" + (folderPath ?? "")
        guard key != currentKey else { return }
        currentKey = key
        token += 1
        let token = self.token
        sizedFolder = nil
        imageLoader.cancel()
        compactLoader.cancel()
        metadataWork?.cancel()
        selectionWork?.cancel()

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
        titleLabel.stringValue = Formatters.count(items.count, "item")
        let total = items.reduce(Int64(0)) { $0 + max(0, $1.displaySize) }
        // A folder still being sized would make the total too small.
        let sizeKnown = !items.contains { $0.displaySize < 0 }
        let folders = items.filter { $0.isDirectoryOnDisk }.count
        var parts: [String] = []
        if folders > 0 { parts.append(Formatters.count(folders, "folder")) }
        if items.count - folders > 0 { parts.append(Formatters.count(items.count - folders, "file")) }
        subtitleLabel.stringValue = parts.joined(separator: ", ") + (sizeKnown && total > 0 ? " - " + Formatters.size(total) : "")
        // Any two paths give the generic multiple-items icon.
        setImage(NSWorkspace.shared.icon(forFiles: items.prefix(2).map { $0.path }) ?? IconCache.shared.immediateIcon(for: items[0]))
        let modified = items.map { $0.modified }.max() ?? 0
        let latest = modified > 0 ? [dateRow("Latest change", Date(timeIntervalSince1970: modified))] : []
        setRows(latest, more: [])
        setTags([])
    }

    private func describe(_ item: FileItem, token: Int) {
        titleLabel.stringValue = item.displayName
        let kind = FileKinds.kind(for: item)
        let size = item.displaySize
        subtitleLabel.stringValue = size >= 0 ? "\(kind) - \(Formatters.size(size))" : kind
        setImage(IconCache.shared.cachedItemIcon(path: item.path) ?? IconCache.shared.immediateIcon(for: item))
        // An unknown date (0, e.g. no birth times on the volume) is left out, not shown as 1970.
        var base: [InfoRow] = []
        if item.created > 0 { base.append(dateRow("Created", item.createdDate)) }
        if item.modified > 0 { base.append(dateRow("Modified", item.modifiedDate)) }
        rows = base
        moreRows = baseMoreRows(for: item, kind: kind)
        // Facts looked up before show at once, so the Tags section doesn't jump
        // and tags don't blink; the lookup below refreshes them in place.
        let url = item.url
        if let cached = ItemMetadata.cached(url) {
            applyMetadata(cached)
        } else {
            rebuildRows()
            setTags([])
        }

        let selectionWork = DispatchWorkItem { [weak self] in
            guard let self, token == self.token else { return }
            self.loadPreviewAndSize(item, kind: kind, token: token)
        }
        self.selectionWork = selectionWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: selectionWork)

        // Spotlight metadata and tags, off the main thread. Lookups run one at a
        // time; a newer selection cancels one that hasn't started yet.
        metadataWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let metadata = ItemMetadata.load(url)
            DispatchQueue.main.async {
                guard let self, token == self.token else { return }
                self.applyMetadata(metadata)
            }
        }
        metadataWork = work
        Self.metadataQueue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func loadPreviewAndSize(_ item: FileItem, kind: String, token: Int) {
        // Artwork: the item's own icon, then a thumbnail for images, movies and documents.
        if compact {
            compactLoader.load(item, into: compactPreview, points: 48, thumbnails: true, iconMode: true)
        } else {
            // One size for every pane width (the preview is at most 256 pt wide),
            // also before the first layout.
            imageLoader.load(item, into: preview, points: 256, thumbnails: true)
        }

        // Folder size, computed in the background.
        if item.type == .directory || (item.type == .package && item.size < 0) {
            sizedFolder = (item, kind)
            if let cached = FolderSizer.shared.cached(item.path) {
                applyFolderSize(cached, to: item, kind: kind)
            } else {
                subtitleLabel.stringValue = "\(kind) - Calculating…"
                FolderSizer.shared.size(of: item.path, progress: { [weak self] bytes in
                    guard let self, token == self.token else { return }
                    self.subtitleLabel.stringValue = "\(kind) - \(Formatters.size(bytes))…"
                }, completion: { [weak self] result in
                    guard let self, token == self.token else { return }
                    item.computedFolderSize = result.bytes
                    self.applyFolderSize(result, to: item, kind: kind)
                })
            }
        }

    }

    /// Adds the Spotlight rows and tags. Applying again (cached, then fresh
    /// facts) replaces the earlier rows instead of adding them twice.
    private func applyMetadata(_ metadata: ItemMetadata) {
        var rows = self.rows.filter { !["Last opened", "Dimensions", "Duration"].contains($0.label) }
        if let lastOpened = metadata.lastOpened { rows.append(dateRow("Last opened", lastOpened)) }
        if let dimensions = metadata.dimensions { rows.append(InfoRow(label: "Dimensions", value: dimensions)) }
        if let duration = metadata.duration { rows.append(InfoRow(label: "Duration", value: duration)) }
        var more = moreRows.filter { $0.label != "Version" && $0.label != "Where from" }
        if let version = metadata.version { more.append(InfoRow(label: "Version", value: version)) }
        if let whereFrom = metadata.whereFrom { more.append(InfoRow(label: "Where from", value: whereFrom)) }
        setRows(rows, more: more)
        setTags(metadata.tags)
    }

    private func setTags(_ tags: [String]) {
        guard tags != shownTags || (tagField.objectValue as? [String]) != tags else { return }
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
        subtitleLabel.stringValue = "\(kind) - \(Formatters.size(result.bytes))"
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
        if let added = item.addedDate { rows.append(dateRow("Added", added)) }
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
        let targets = urls
        shownTags = tags
        currentKey = ""
        // Old tags must not come back from the cache before the write lands.
        ItemMetadata.invalidate(targets)
        // Off the main thread (many files, slow volumes), and on the lookups'
        // serial queue: edits can't race each other, and a later lookup reads
        // the new tags.
        Self.metadataQueue.async {
            for url in targets {
                var current = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                current.removeAll { removed.contains($0) }
                for tag in added where !current.contains(tag) { current.append(tag) }
                try? (url as NSURL).setResourceValue(current, forKey: .tagNamesKey)
            }
            DispatchQueue.main.async { ItemAttributes.reloadParents(of: targets) }
        }
    }
}
