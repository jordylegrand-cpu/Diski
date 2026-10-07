import AppKit

/// View Options (⌘J): Finder's floating utility panel. It follows the active
/// browser window and shows the options of its current view.
final class ViewOptionsPanel: NSWindowController, NSWindowDelegate {
    static let shared = ViewOptionsPanel()

    private weak var pane: PaneViewController?
    private let stack = NSStackView()
    private var observers: [NSObjectProtocol] = []

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 400),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.titlebarSeparatorStyle = .none
        super.init(window: panel)
        panel.delegate = self
        stack.orientation = .vertical
        stack.alignment = .leading
        // 6 pt between rows of a group, 18 pt between groups (see rebuild()).
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 270),
        ])
        panel.contentView = content
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.window?.isVisible == true,
                  let browser = (note.object as? NSWindow)?.windowController as? BrowserWindowController else { return }
            self.attach(to: browser.activePane)
        })
        observers.append(center.addObserver(forName: Prefs.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.window?.isVisible == true, !self.isApplying else { return }
            self.rebuild()
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isApplying = false

    func toggle(for pane: PaneViewController) {
        if window?.isVisible == true, self.pane === pane {
            window?.orderOut(nil)
            return
        }
        attach(to: pane)
        if window?.isVisible != true { place(near: pane.view.window) }
        window?.orderFront(nil)
    }

    private static let positionKey = "DiskiViewOptionsTopLeft"

    /// Where the user last left it, else at the browser's top right corner.
    private func place(near browser: NSWindow?) {
        guard let window else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            let topLeft = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(topLeft) }) {
                window.setFrameTopLeftPoint(topLeft)
                return
            }
        }
        guard let browser, let screen = browser.screen ?? NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let x = min(browser.frame.maxX - window.frame.width - 16, visible.maxX - window.frame.width - 8)
        let y = min(browser.frame.maxY - 70, visible.maxY - 8)
        window.setFrameTopLeftPoint(NSPoint(x: max(visible.minX + 8, x).rounded(), y: y.rounded()))
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, window.isVisible, NSEvent.pressedMouseButtons != 0 else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: window.frame.minX, y: window.frame.maxY)),
                                  forKey: Self.positionKey)
    }

    /// Follows the active pane (window, tab, dual pane or view mode changes).
    func paneDidChange(_ pane: PaneViewController) {
        guard window?.isVisible == true else { return }
        attach(to: pane)
    }

    private func attach(to pane: PaneViewController) {
        self.pane = pane
        rebuild()
    }

    // MARK: Content

    private func rebuild() {
        guard let pane, let window else { return }
        window.title = pane.isSearchResults ? pane.displayTitle : FileManager.default.displayName(atPath: pane.displayedPath)
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }

        let mode = pane.viewMode
        let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for key in SortKey.allCases {
            sortPopup.addItem(withTitle: key.title)
            sortPopup.lastItem?.representedObject = key.rawValue
        }
        sortPopup.selectItem(at: SortKey.allCases.firstIndex(of: pane.arrangeOptions.sortKey) ?? 0)
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))
        let orderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        orderPopup.addItems(withTitles: ["Ascending", "Descending"])
        orderPopup.selectItem(at: pane.arrangeOptions.ascending ? 0 : 1)
        orderPopup.target = self
        orderPopup.action = #selector(orderChanged(_:))
        var rows: [[NSView]] = [[label("Sort By:"), sortPopup], [label("Order:"), orderPopup]]

        switch mode {
        case .list:
            let density = NSPopUpButton(frame: .zero, pullsDown: false)
            for option in RowDensity.allCases { density.addItem(withTitle: option.menuTitle) }
            density.selectItem(at: Prefs.rowDensity.rawValue)
            density.target = self
            density.action = #selector(densityChanged(_:))
            rows.append([label("Icon size:"), density])
        case .icons:
            // No tick marks, like Finder's; it takes the popups' column width.
            let slider = NSSlider(value: Double(Prefs.iconSize), minValue: 32, maxValue: 256,
                                  target: self, action: #selector(iconSizeChanged(_:)))
            rows.append([label("Icon size:"), slider])
            rows.append([NSGridCell.emptyContentView, valueLabel("\(Int(Prefs.iconSize)) × \(Int(Prefs.iconSize))")])
        default:
            break
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        // Every popup (and the slider) as wide as the widest one, like Finder's.
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        stack.addArrangedSubview(grid)
        stack.setCustomSpacing(12, after: grid)

        // Whitespace, not separator lines, sets the groups apart.
        let keepFoldersBox = checkbox("Keep folders on top", Prefs.foldersOnTop, #selector(toggleFoldersOnTop(_:)))
        stack.addArrangedSubview(keepFoldersBox)
        stack.setCustomSpacing(18, after: keepFoldersBox)

        if mode == .list {
            stack.addArrangedSubview(heading("Show Columns:"))
            let visible = Set(Prefs.listColumns)
            for column in ListColumn.allCases where column != .name {
                let box = checkbox(column.title, visible.contains(column.rawValue), #selector(toggleColumn(_:)))
                box.identifier = NSUserInterfaceItemIdentifier(column.rawValue)
                // 23 pt: the indented boxes start where the other checkboxes' titles do.
                let indent = NSStackView(views: [box])
                indent.edgeInsets = NSEdgeInsets(top: 0, left: 23, bottom: 0, right: 0)
                stack.addArrangedSubview(indent)
            }
            stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
        }

        stack.addArrangedSubview(checkbox("Calculate all sizes", Prefs.calculateFolderSizes, #selector(toggleSizes(_:))))
        if mode == .list || mode == .icons || mode == .columns {
            stack.addArrangedSubview(checkbox("Show icon preview", Prefs.showThumbnailsInList, #selector(togglePreviews(_:))))
        }
        stack.addArrangedSubview(checkbox("Show hidden files", Prefs.showHiddenFiles, #selector(toggleHidden(_:))))

        let defaults = NSButton(title: "Use as Defaults", target: self, action: #selector(useAsDefaults))
        defaults.bezelStyle = .push
        let centered = NSStackView(views: [defaults])
        centered.alignment = .centerX
        stack.addArrangedSubview(centered)
        centered.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        fit()
    }

    private func fit() {
        guard let window else { return }
        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: 270, height: stack.fittingSize.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        // The animator proxy resizes without blocking the main thread (and
        // the browser's own view switch with it).
        if window.isVisible {
            window.animator().setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func valueLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// Regular label text, like Finder's "Sort By:" (its panel has no bold text).
    private func heading(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func checkbox(_ title: String, _ on: Bool, _ action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.state = on ? .on : .off
        return box
    }

    // MARK: Actions

    private func applying(_ body: () -> Void) {
        isApplying = true
        body()
        isApplying = false
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        guard let pane, let raw = sender.selectedItem?.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        pane.setSort(key, ascending: key.defaultAscending)
        rebuild()
    }

    @objc private func orderChanged(_ sender: NSPopUpButton) {
        guard let pane else { return }
        pane.setSort(pane.arrangeOptions.sortKey, ascending: sender.indexOfSelectedItem == 0)
    }

    @objc private func densityChanged(_ sender: NSPopUpButton) {
        guard let density = RowDensity(rawValue: sender.indexOfSelectedItem) else { return }
        applying { Prefs.rowDensity = density }
    }

    @objc private func iconSizeChanged(_ sender: NSSlider) {
        // Multiples of 4 keep icons centred on whole points; unchanged sizes
        // post nothing (Prefs posts on every write).
        let size = CGFloat((sender.doubleValue / 4).rounded() * 4)
        guard size != Prefs.iconSize else { return }
        applying { Prefs.iconSize = size }
        if let grid = stack.arrangedSubviews.first as? NSGridView, grid.numberOfRows > 3,
           let value = grid.cell(atColumnIndex: 1, rowIndex: 3).contentView as? NSTextField {
            value.stringValue = "\(Int(size)) × \(Int(size))"
        }
    }

    @objc private func toggleFoldersOnTop(_ sender: NSButton) {
        applying { Prefs.foldersOnTop = sender.state == .on }
    }

    @objc private func toggleColumn(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        var columns = Prefs.listColumns
        if sender.state == .on {
            if !columns.contains(raw) { columns.append(raw) }
        } else {
            columns.removeAll { $0 == raw }
        }
        applying { Prefs.listColumns = columns }
    }

    @objc private func toggleSizes(_ sender: NSButton) {
        applying { Prefs.calculateFolderSizes = sender.state == .on }
    }

    @objc private func togglePreviews(_ sender: NSButton) {
        applying { Prefs.showThumbnailsInList = sender.state == .on }
    }

    @objc private func toggleHidden(_ sender: NSButton) {
        applying { Prefs.showHiddenFiles = sender.state == .on }
    }

    @objc private func useAsDefaults() {
        guard let pane else { return }
        applying {
            Prefs.defaultViewMode = pane.viewMode
            Prefs.sortKey = pane.arrangeOptions.sortKey
            Prefs.sortAscending = pane.arrangeOptions.ascending
        }
    }
}

private extension RowDensity {
    var menuTitle: String {
        switch self {
        case .compact: return "Small"
        case .regular: return "Medium"
        case .comfortable: return "Large"
        }
    }
}
