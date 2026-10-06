import AppKit

/// The bar along the bottom of a pane: Finder-style path bar on the left,
/// item count / selection size / free space on the right, and an icon-size
/// slider in icon view.
final class BottomBarView: NSView {
    let pathControl = NSPathControl()
    let status = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 64, minValue: 32, maxValue: 256, target: nil, action: nil)
    private let separator = NSBox()
    var onNavigate: ((URL) -> Void)?
    var onIconSizeChange: ((CGFloat) -> Void)?

    private var statusToSlider: NSLayoutConstraint!
    private var statusToEdge: NSLayoutConstraint!

    var showsIconSizeSlider = false {
        didSet {
            slider.isHidden = !showsIconSizeSlider
            statusToSlider.isActive = showsIconSizeSlider
            statusToEdge.isActive = !showsIconSizeSlider
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.backgroundColor = .clear
        pathControl.isEditable = false
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathControl.clipsToBounds = true

        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.lineBreakMode = .byTruncatingHead
        status.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(500), for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .mini
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isHidden = true
        slider.doubleValue = Double(Prefs.iconSize)

        addSubview(separator)
        addSubview(pathControl)
        addSubview(status)
        addSubview(slider)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            pathControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: pathControl.trailingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            slider.widthAnchor.constraint(equalToConstant: 90),
        ])
        statusToSlider = status.trailingAnchor.constraint(equalTo: slider.leadingAnchor, constant: -10)
        statusToEdge = status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        statusToEdge.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPath(_ url: URL) {
        if pathControl.url != url { pathControl.url = url }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url else { return }
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
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 320
        button.bezelStyle = .glass
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

/// Floating glass scope switch shown while searching.
final class SearchScopeBar: NSView {
    private let glass = NSGlassEffectView()
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
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 16
        control.translatesAutoresizingMaskIntoConstraints = false
        control.segmentStyle = .automatic
        control.controlSize = .small
        control.selectedSegment = 0
        control.target = self
        control.action = #selector(changed(_:))
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        glass.contentView = container
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            control.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed(_ sender: NSSegmentedControl) {
        guard let scope = SearchScope(rawValue: sender.selectedSegment) else { return }
        self.scope = scope
        onScopeChange?(scope)
    }
}
