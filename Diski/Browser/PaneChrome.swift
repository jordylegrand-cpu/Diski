import AppKit

/// The bar along the bottom of a pane: Finder-style path bar on the left,
/// item count / selection size / free space on the right, and an icon-size
/// slider in icon view.
final class BottomBarView: NSView {
    let pathControl = NSPathControl()
    private let status = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 64, minValue: 32, maxValue: 256, target: nil, action: nil)
    var onNavigate: ((URL) -> Void)?
    var onIconSizeChange: ((CGFloat) -> Void)?
    /// Drops on the path's folders, like Finder: the operation a drag onto a
    /// folder would perform, and performing it.
    var dropOperation: ((NSDraggingInfo, String) -> NSDragOperation)?
    var performDrop: ((NSDraggingInfo, String) -> Bool)?
    private var dropHighlight: NSRect? {
        didSet { if dropHighlight != oldValue { needsDisplay = true } }
    }

    private var statusToSlider: NSLayoutConstraint!
    private var statusToEdge: NSLayoutConstraint!

    /// The (normalized) path shown, and the path of each component by index:
    /// NSPathControlItem.url is read-only, so clicks and drops map by index.
    private var shownPath: String?
    private var componentPaths: [String] = []
    private static var componentCache: [String: (title: String, image: NSImage)] = [:]
    /// Status texts from most to least detailed; the longest one that fits is shown.
    private var statusVariants: [String] = []

    var showsIconSizeSlider = false {
        didSet {
            slider.isHidden = !showsIconSizeSlider
            statusToSlider.isActive = showsIconSizeSlider
            statusToEdge.isActive = !showsIconSizeSlider
            fitStatus()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.backgroundColor = .clear
        pathControl.isEditable = false
        // Drops are handled by the bar (into the folder under the pointer), so
        // the control must not claim them to change its own URL.
        pathControl.unregisterDraggedTypes()
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        // Both stay below a split view's holding priority (250), so the bar
        // never decides how wide a pane is: the path yields first, then the status.
        pathControl.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(230), for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathControl.clipsToBounds = true

        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .mini
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isHidden = true
        slider.doubleValue = Double(Prefs.iconSize)

        // No separator line and no background: the bar sits on the content
        // like Finder's, 28 pt tall with its text on the bar's centre.
        addSubview(pathControl)
        addSubview(status)
        addSubview(slider)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            // The control draws its first icon 5 pt in: the art lands where Finder's does.
            pathControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: pathControl.trailingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 90),
        ])
        statusToSlider = status.trailingAnchor.constraint(equalTo: slider.leadingAnchor, constant: -10)
        statusToEdge = status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        statusToEdge.isActive = true
        // The bar, not the (read-only) path control, takes drops on path folders.
        registerForDraggedTypes(PaneViewController.acceptedDragTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Drops on path folders

    /// The folder in the path under a drag, and its frame in this view.
    private func dropFolder(for info: NSDraggingInfo) -> (path: String, frame: NSRect)? {
        guard let cell = pathControl.cell as? NSPathCell else { return nil }
        let point = pathControl.convert(info.draggingLocation, from: nil)
        guard pathControl.bounds.contains(point),
              let component = cell.pathComponentCell(at: point, withFrame: pathControl.bounds, in: pathControl),
              let i = cell.pathComponentCells.firstIndex(where: { $0 === component }), i < componentPaths.count
        else { return nil }
        let path = componentPaths[i]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              !NSWorkspace.shared.isFilePackage(atPath: path) else { return nil }
        let frame = cell.rect(of: component, withFrame: pathControl.bounds, in: pathControl)
        return (DirectoryReader.normalized(path), convert(frame, from: pathControl))
    }

    private func validateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let folder = dropFolder(for: info),
              let operation = dropOperation?(info, folder.path), !operation.isEmpty else {
            dropHighlight = nil
            return []
        }
        dropHighlight = folder.frame
        return operation
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { validateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { validateDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlight = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = nil
        guard let folder = dropFolder(for: sender) else { return false }
        return performDrop?(sender, folder.path) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let dropHighlight else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: dropHighlight.insetBy(dx: -4, dy: -1), xRadius: 5, yRadius: 5).fill()
    }

    /// Shows `url` from its volume down, like Finder ("Macintosh HD › Users › …";
    /// the control's own `url` setter starts at the home folder). `lastIcon`
    /// is the selected item's icon, so a selection change needs no icon lookup.
    func setPath(_ url: URL?, icon lastIcon: NSImage? = nil) {
        let normalized = url.map { DirectoryReader.normalized($0.path) }
        guard normalized != shownPath else { return }
        shownPath = normalized
        guard let path = normalized else { componentPaths = []; pathControl.pathItems = []; fitStatus(); return }
        let root = VolumeMonitor.shared.volume(containing: path)?.path ?? "/"
        var paths: [String] = []
        var current = path
        while true {
            paths.append(current)
            if current == root || current == "/" || current.isEmpty { break }
            current = (current as NSString).deletingLastPathComponent
        }
        paths.reverse()
        componentPaths = paths
        let lastIndex = paths.count - 1
        pathControl.pathItems = paths.enumerated().map { index, p in
            let item = NSPathControlItem()
            if index == lastIndex, index > 0, let lastIcon {
                // The selection: no NSWorkspace lookup and no cache entry per arrow key.
                item.title = FileManager.default.displayName(atPath: p)
                item.image = Self.sized(lastIcon)
            } else {
                let c = Self.component(for: p, isRoot: index == 0)
                item.title = c.title
                item.image = c.image
            }
            return item
        }
        // Items made by hand may not pick up the control's font; keep the native 11 pt.
        for cell in (pathControl.cell as? NSPathCell)?.pathComponentCells ?? [] { cell.font = pathControl.font }
        fitStatus()
    }

    private static func component(for path: String, isRoot: Bool) -> (title: String, image: NSImage) {
        if let hit = componentCache[path] { return hit }
        if componentCache.count > 256 { componentCache.removeAll() }
        let title = isRoot ? (VolumeMonitor.shared.volume(containing: path)?.name ?? FileManager.default.displayName(atPath: path))
                           : FileManager.default.displayName(atPath: path)
        let entry = (title: title, image: sized(NSWorkspace.shared.icon(forFile: path)))
        componentCache[path] = entry
        return entry
    }

    private static func sized(_ image: NSImage) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image   // never resize a shared image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    /// `variants` run from most to least detailed ("12 items, 4 GB available",
    /// "12 items"): the bar shows the longest that leaves the path its full width.
    func setStatus(_ variants: [String]) {
        guard variants != statusVariants else { return }
        statusVariants = variants
        fitStatus()
    }

    func syncIconSize(_ size: CGFloat) {
        if slider.doubleValue != Double(size) { slider.doubleValue = Double(size) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { fitStatus() }
    }

    private func fitStatus() {
        guard let shortest = statusVariants.last else {
            if !status.stringValue.isEmpty { status.stringValue = "" }
            return
        }
        let sliderRoom: CGFloat = showsIconSizeSlider ? 100 : 0   // 90 slider + 10 gap
        let room = bounds.width - 7 - 12 - 12 - sliderRoom - pathControl.intrinsicContentSize.width
        let font = status.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let chosen = statusVariants.first { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 4 <= room } ?? shortest
        if status.stringValue != chosen { status.stringValue = chosen }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let cell = sender.cell as? NSPathCell, let clicked = cell.clickedPathComponentCell,
              let i = cell.pathComponentCells.firstIndex(where: { $0 === clicked }), i < componentPaths.count
        else { return }
        let url = URL(fileURLWithPath: componentPaths[i])
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            onNavigate?(url)
        } else {
            onNavigate?(url.deletingLastPathComponent())
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        onIconSizeChange?(CGFloat(sender.doubleValue))
    }
}

/// Centered placeholder for empty folders, errors and search states.
final class PaneMessageView: NSView {
    enum Kind: Equatable {
        case none, loading, searching, empty
        case noMatches(String)
        case noResults(String)
        case permissionDenied
        case error(String)
    }

    private let stack = NSStackView()
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "Open Privacy Settings", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private(set) var kind: Kind = .none
    /// The detail's wrap width: narrower panes (dual pane) wrap it sooner
    /// instead of measuring at 320 pt and clipping the last line.
    var maxTextWidth: CGFloat = 320 {
        didSet { if detail.preferredMaxLayoutWidth != maxTextWidth { detail.preferredMaxLayoutWidth = maxTextWidth } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        symbol.contentTintColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        // Instructions to read, not disabled text: secondary, like any explanatory label.
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 320
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(openPrivacySettings)
        spinner.style = .spinning
        spinner.controlSize = .small
        for view in [spinner, symbol, title, detail, button] as [NSView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(14, after: detail)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        show(.none)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the button is interactive; clicks fall through to the file view.
        let hit = super.hitTest(point)
        if let hit, hit === button || hit.isDescendant(of: button) { return hit }
        return nil
    }

    func show(_ kind: Kind) {
        guard kind != self.kind || kind == .none else { return }
        self.kind = kind
        spinner.isHidden = true
        spinner.stopAnimation(nil)
        symbol.isHidden = false
        detail.isHidden = true
        button.isHidden = true
        isHidden = false
        switch kind {
        case .none:
            isHidden = true
        case .loading:
            symbol.isHidden = true
            title.stringValue = ""
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .searching:
            symbol.isHidden = true
            title.stringValue = "Searching…"
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .empty:
            symbol.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            title.stringValue = "This folder is empty"
        case .noMatches(let text):
            symbol.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
            title.stringValue = "No items match “\(text)”"
            detail.stringValue = "Choose Subfolders or This Mac above to search further."
            detail.isHidden = false
        case .noResults(let text):
            symbol.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            title.stringValue = text.isEmpty ? "No results" : "No results for “\(text)”"
        case .permissionDenied:
            symbol.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
            title.stringValue = "Diski can’t see this folder yet"
            detail.stringValue = "Give Diski Full Disk Access in System Settings › Privacy & Security, then come back."
            detail.isHidden = false
            button.isHidden = false
        case .error(let text):
            symbol.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            title.stringValue = "This folder couldn’t be opened"
            detail.stringValue = text
            detail.isHidden = false
        }
        title.isHidden = title.stringValue.isEmpty
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum SearchScope: Int {
    case thisFolder = 0, subfolders = 1, thisMac = 2
}

/// The scope switch shown above the results while searching: the native
/// segmented control on its own, without a capsule around its track.
final class SearchScopeBar: NSView {
    private let control = NSSegmentedControl(labels: ["This Folder", "Subfolders", "This Mac"],
                                             trackingMode: .selectOne, target: nil, action: nil)
    var onScopeChange: ((SearchScope) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    override var isHidden: Bool {
        didSet { if oldValue != isHidden { onVisibilityChange?(!isHidden) } }
    }

    var scope: SearchScope = .thisFolder {
        didSet { control.selectedSegment = scope.rawValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.segmentStyle = .automatic
        control.controlSize = .small
        control.selectedSegment = 0
        control.target = self
        control.action = #selector(changed(_:))
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed(_ sender: NSSegmentedControl) {
        guard let scope = SearchScope(rawValue: sender.selectedSegment) else { return }
        self.scope = scope
        onScopeChange?(scope)
    }
}
