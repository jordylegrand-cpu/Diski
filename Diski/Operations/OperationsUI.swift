import AppKit
import UniformTypeIdentifiers

// MARK: - Operation row

/// One file operation, laid out like a row of Finder's Copy window:
/// the item's icon, "Copying “X” to “Y”", a progress bar with pause and
/// stop buttons, and "1.2 GB of 2.1 GB — 488 MB/s — About 2 seconds".
final class OperationRowView: NSView {
    let operation: FileOperation
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let detail = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let stopButton = NSButton()
    private var detailBelowBar: NSLayoutConstraint!
    private var detailBelowTitle: NSLayoutConstraint!
    /// Shared symbol images: update() runs ten times a second.
    private static let pauseImage = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "Pause")
    private static let resumeImage = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Resume")
    /// What update() last applied, so unchanged ticks touch nothing.
    private var shownPaused: Bool?
    private var shownDone: Bool?
    private var runningTitle: String?

    /// `compact` rows (the finished popover) hug their text; window rows
    /// keep Finder's 76 pt and centre the text block when it is shorter.
    init(operation: FileOperation, compact: Bool = false) {
        self.operation = operation
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 76))

        icon.image = Self.icon(for: operation)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        for button in [pauseButton, stopButton] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.contentTintColor = .tertiaryLabelColor
            button.target = self
        }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        stopButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop")?
            .withSymbolConfiguration(symbolConfig)
        stopButton.toolTip = "Stop"
        stopButton.action = #selector(stop)
        pauseButton.action = #selector(togglePause)
        pauseButton.symbolConfiguration = symbolConfig

        for view in [icon, title, bar, detail, pauseButton, stopButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        detailBelowBar = detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4)
        detailBelowTitle = detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        // The text block (title to detail) is centred on the row, like the
        // icon; the low-priority hug makes the row 13 pt taller than the
        // block on each side unless a minimum height holds it open.
        let block = NSLayoutGuide()
        addLayoutGuide(block)
        let hug = title.topAnchor.constraint(equalTo: topAnchor, constant: 13)
        hug.priority = .defaultLow
        var constraints: [NSLayoutConstraint] = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            title.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 13),
            block.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            block.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            block.topAnchor.constraint(equalTo: title.topAnchor),
            block.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            block.centerYAnchor.constraint(equalTo: centerYAnchor),
            hug,
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            pauseButton.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            pauseButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stopButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 4),
            stopButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -13),
            detailBelowBar,
        ]
        if !compact { constraints.append(heightAnchor.constraint(greaterThanOrEqualToConstant: 76)) }
        NSLayoutConstraint.activate(constraints)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func icon(for operation: FileOperation) -> NSImage {
        switch operation.kind {
        case .trash, .delete, .emptyTrash:
            return NSImage(named: NSImage.trashFullName) ?? NSWorkspace.shared.icon(forFile: FileOperationManager.trashURL.path)
        default:
            if operation.sources.count == 1 { return NSWorkspace.shared.icon(forFile: operation.sources[0].path) }
            return NSWorkspace.shared.icon(forFiles: operation.sources.map { $0.path }) ?? NSWorkspace.shared.icon(for: .data)
        }
    }

    func update() {
        let done = operation.state.isDone
        if done != shownDone {
            shownDone = done
            bar.isHidden = done
            pauseButton.isHidden = done
            stopButton.isHidden = done
            // Deactivate first, so the two never hold at the same time.
            if done {
                detailBelowBar.isActive = false
                detailBelowTitle.isActive = true
                bar.stopAnimation(nil)
            } else {
                detailBelowTitle.isActive = false
                detailBelowBar.isActive = true
            }
        }
        let newTitle: String
        if done {
            newTitle = finishedTitle
        } else {
            if runningTitle == nil { runningTitle = operation.title }
            newTitle = runningTitle ?? ""
            let snapshot = operation.snapshot
            let indeterminate = snapshot.scanning && snapshot.totalBytes == 0 && snapshot.totalItems == 0
            if bar.isIndeterminate != indeterminate {
                bar.isIndeterminate = indeterminate
                if indeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
            }
            if !indeterminate {
                let fraction = snapshot.totalBytes > 0
                    ? min(1, Double(snapshot.completedBytes) / Double(snapshot.totalBytes))
                    : (snapshot.totalItems > 0 ? min(1, Double(snapshot.completedItems) / Double(snapshot.totalItems)) : 0)
                if bar.doubleValue != fraction { bar.doubleValue = fraction }
            }
            let paused = operation.isPaused
            if paused != shownPaused {
                shownPaused = paused
                pauseButton.image = paused ? Self.resumeImage : Self.pauseImage
                pauseButton.toolTip = paused ? "Resume" : "Pause"
            }
        }
        // Unchanged strings are not reassigned: each assignment invalidates
        // the label's intrinsic size and costs a layout pass.
        if title.stringValue != newTitle { title.stringValue = newTitle }
        let text = detailText
        if detail.stringValue != text { detail.stringValue = text }
        let color: NSColor
        if case .failed = operation.state {
            color = .systemRed
        } else {
            color = .secondaryLabelColor
        }
        if detail.textColor != color { detail.textColor = color }
    }

    private var finishedTitle: String {
        let count = operation.sources.count
        let what = count == 1 ? "“\(operation.sources[0].lastPathComponent)”" : "\(count) items"
        let running = operation.title.prefix(1).lowercased() + String(operation.title.dropFirst())
        switch operation.state {
        case .failed: return "Couldn’t finish \(running)"
        case .cancelled: return "Stopped \(running)"
        default: break
        }
        switch operation.kind {
        case .copy, .move:
            let target = operation.destination.map { " to “\(FileManager.default.displayName(atPath: $0.path))”" } ?? ""
            return "\(operation.kind.pastTense) \(what)\(target)"
        case .emptyTrash:
            return "Emptied the Trash"
        case .trash:
            return "Moved \(what) to the Trash"
        default:
            return "\(operation.kind.pastTense) \(what)"
        }
    }

    private var detailText: String {
        let s = operation.snapshot
        switch operation.state {
        case .finished:
            let elapsed = (operation.finishedAt ?? Date()).timeIntervalSince(operation.startedAt)
            var parts = ["Done in \(Formatters.duration(elapsed))"]
            if s.instant && (operation.kind == .copy || operation.kind == .duplicate) {
                parts.append("instant APFS clone")
            } else if s.totalBytes > 0 && elapsed > 0.05 && operation.kind != .trash {
                parts.append("\(Formatters.rate(Double(s.totalBytes) / elapsed)) average")
            }
            if operation.kind == .trash { parts.append("⌘Z to undo") }
            return parts.joined(separator: " — ")
        case .failed(let message):
            return message
        case .cancelled:
            return "Stopped"
        default:
            var parts: [String] = []
            if s.totalBytes > 0 {
                parts.append("\(Formatters.size(s.completedBytes)) of \(Formatters.size(s.totalBytes))\(s.scanning ? "+" : "")")
            } else if s.totalItems > 0 {
                parts.append("\(s.completedItems.formatted()) of \(Formatters.count(s.totalItems, "item"))")
            } else {
                parts.append("Preparing…")
            }
            if operation.isPaused {
                parts.append("Paused")
            } else {
                let rate = Formatters.rate(operation.bytesPerSecond)
                if !rate.isEmpty { parts.append(rate) }
                if let remaining = operation.estimatedSecondsRemaining { parts.append(Formatters.remaining(remaining)) }
            }
            return parts.joined(separator: " — ")
        }
    }

    @objc private func togglePause() {
        operation.setPaused(!operation.isPaused)
        update()
    }

    @objc private func stop() {
        operation.cancel()
    }
}

/// A hairline between rows, one device pixel thick.
final class HairlineView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        NSColor.separatorColor.setFill()
        // Snapped to a whole device pixel row: y=0 at 1x, 0.5 pt at 2x.
        let y = (bounds.midY * scale).rounded(.down) / scale
        NSRect(x: 0, y: y, width: bounds.width, height: 1 / scale).fill()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

// MARK: - Progress window

/// Finder's "Copy" window: a native window listing the running operations.
/// It opens by itself when an operation takes longer than a moment and
/// closes when everything is done.
final class ProgressWindowController: NSWindowController, NSWindowDelegate, NSPopoverDelegate {
    static let shared = ProgressWindowController()

    private let stack = NSStackView()
    private let content = NSView()
    /// Under the toolbar's progress item when a browser window shows one (like
    /// Safari's downloads); the panel is only for when there is no such item.
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        return popover
    }()
    private var closingPopover = false
    private var rows: [ObjectIdentifier: OperationRowView] = [:]
    /// Operations shown in the window; finished ones stay a moment with their result.
    private var shown: [FileOperation] = []
    private var lingering: Set<ObjectIdentifier> = []
    private var dismissedByUser = false
    /// Opened by the user: finished operations stay listed until it is closed.
    private var pinned = false
    private var pendingAutoShow: Set<ObjectIdentifier> = []

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 76),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        panel.title = "Copy"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.titlebarSeparatorStyle = .none
        super.init(window: panel)
        panel.delegate = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 460),
        ])
        panel.contentView = content

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(operationsChanged), name: FileOperationManager.didChange, object: nil)
        center.addObserver(self, selector: #selector(operationFinished(_:)), name: FileOperationManager.didFinish, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Whether the window was on screen while `operation` ran.
    func didShow(_ operation: FileOperation) -> Bool {
        rows[ObjectIdentifier(operation)] != nil && isOnScreen
    }

    private var isOnScreen: Bool { popover.isShown || window?.isVisible == true }

    /// The progress item of the frontmost browser window, if it shows one.
    private var toolbarAnchor: NSView? {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow] {
            if let browser = candidate?.windowController as? BrowserWindowController, let anchor = browser.operationsAnchor {
                return anchor
            }
        }
        return nil
    }

    private func show(anchor: NSView?) {
        guard let anchor else {
            if popover.isShown { closePopover() }
            if window?.contentView !== content { window?.contentView = content }
            resizeToFit()
            place()
            window?.orderFront(nil)
            return
        }
        if window?.isVisible == true { window?.orderOut(nil) }
        if window?.contentView === content { window?.contentView = NSView() }
        popover.contentSize = fittingContentSize
        if popover.isShown { return }
        let host = NSViewController()
        host.view = content
        popover.contentViewController = host
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func closePopover() {
        closingPopover = true
        popover.close()
        closingPopover = false
    }

    private var fittingContentSize: NSSize {
        content.layoutSubtreeIfNeeded()
        return NSSize(width: 460, height: max(76, stack.fittingSize.height))
    }

    func popoverDidClose(_ notification: Notification) {
        guard !closingPopover else { return }
        // Closed by a click elsewhere: like closing the window.
        dismissedByUser = !FileOperationManager.shared.activeOperations.isEmpty
        pinned = false
        lingering.removeAll()
        sync()
    }

    /// Shows the window with every running operation, and the results of the
    /// ones that just finished (toolbar button, Window menu).
    func present(anchor: NSView? = nil) {
        dismissedByUser = false
        pinned = true
        for operation in FileOperationManager.shared.operations where operation.state.isDone {
            lingering.insert(ObjectIdentifier(operation))
        }
        sync()
        if shown.isEmpty {
            pinned = false
            NSSound.beep()
            return
        }
        show(anchor: anchor ?? toolbarAnchor)
    }

    @objc private func operationsChanged() {
        let active = FileOperationManager.shared.activeOperations
        if active.isEmpty { dismissedByUser = false }
        // New operations open the window once they have run for half a second,
        // like Finder (instant clones and renames never show it).
        for operation in active where !pendingAutoShow.contains(ObjectIdentifier(operation))
            && rows[ObjectIdentifier(operation)] == nil {
            pendingAutoShow.insert(ObjectIdentifier(operation))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak operation] in
                guard let self, let operation, !operation.state.isDone, !self.dismissedByUser else { return }
                self.sync()
                if !self.isOnScreen { self.show(anchor: self.toolbarAnchor) }
            }
        }
        if isOnScreen { sync() }
    }

    @objc private func operationFinished(_ notification: Notification) {
        guard let operation = notification.object as? FileOperation else { return }
        let id = ObjectIdentifier(operation)
        pendingAutoShow.remove(id)
        guard let row = rows[id] else { return }
        row.update()
        lingering.insert(id)
        guard !pinned else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (operation.state == .finished ? 1.6 : 4)) { [weak self] in
            guard let self, !self.pinned else { return }
            self.lingering.remove(id)
            self.sync()
        }
    }

    /// Rebuilds the rows: running operations plus finished ones still lingering.
    private func sync() {
        let manager = FileOperationManager.shared
        // Finished operations leave the manager after a few seconds; a pinned
        // window keeps showing them.
        var wanted = manager.operations.filter { !$0.state.isDone || lingering.contains(ObjectIdentifier($0)) }
        if pinned {
            let listed = Set(wanted.map { ObjectIdentifier($0) })
            wanted = shown.filter { lingering.contains(ObjectIdentifier($0)) && !listed.contains(ObjectIdentifier($0)) } + wanted
        }
        if wanted.map({ ObjectIdentifier($0) }) != shown.map({ ObjectIdentifier($0) }) {
            shown = wanted
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            var kept: [ObjectIdentifier: OperationRowView] = [:]
            // No lines between rows: each row's padding separates them.
            for operation in wanted {
                let id = ObjectIdentifier(operation)
                let row = rows[id] ?? OperationRowView(operation: operation)
                kept[id] = row
                row.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row)
                if rows[id] == nil { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            }
            rows = kept
            window?.title = Self.title(for: wanted)
            resizeToFit()
        }
        for row in rows.values { row.update() }
        if wanted.isEmpty, isOnScreen {
            if popover.isShown { closePopover() }
            window?.orderOut(nil)
            dismissedByUser = false
        }
    }

    private func resizeToFit() {
        if popover.isShown {
            let size = fittingContentSize
            if popover.contentSize != size { popover.contentSize = size }
            return
        }
        guard let window, window.contentView === content else { return }
        let height = fittingContentSize.height
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 460, height: height)))
        // Grow and shrink downwards from the title bar.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        // The animator proxy resizes without blocking the main thread.
        if window.isVisible {
            window.animator().setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private static let positionKey = "DiskiProgressWindowTopLeft"

    /// Where the user last left the window, else centered over the browser
    /// near its top, like Finder's.
    private func place() {
        guard let window, !window.isVisible else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            let topLeft = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(topLeft) }) {
                window.setFrameTopLeftPoint(topLeft)
                return
            }
        }
        if let browser = NSApp.mainWindow ?? NSApp.keyWindow, browser !== window {
            let x = browser.frame.midX - window.frame.width / 2
            window.setFrameTopLeftPoint(NSPoint(x: x.rounded(), y: (browser.frame.maxY - 120).rounded()))
        } else {
            window.center()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, window.isVisible, window.inLiveResize == false,
              NSEvent.pressedMouseButtons != 0 else { return }
        // Only moves made by dragging the title bar are remembered.
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: window.frame.minX, y: window.frame.maxY)),
                                  forKey: Self.positionKey)
    }

    private static func title(for operations: [FileOperation]) -> String {
        let kinds = Set(operations.map { $0.kind.windowTitle })
        return kinds.count == 1 ? kinds.first! : "File Operations"
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissedByUser = !FileOperationManager.shared.activeOperations.isEmpty
        pinned = false
        lingering.removeAll()
        sender.orderOut(nil)
        sync()
        return false
    }
}

private extension FileOperation.Kind {
    var windowTitle: String {
        switch self {
        case .copy: return "Copy"
        case .move: return "Move"
        case .duplicate: return "Duplicate"
        case .trash: return "Move to Trash"
        case .delete: return "Delete"
        case .compress: return "Compress"
        case .emptyTrash: return "Empty Trash"
        }
    }
}

// MARK: - Toolbar progress item

/// The toolbar's progress item: a native circular progress indicator while
/// operations run and a checkmark briefly afterwards. Click it to open the
/// progress window.
final class OperationsToolbarView: NSView {
    var onClick: (() -> Void)?
    private let indicator = NSProgressIndicator()
    private let check = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        translatesAutoresizingMaskIntoConstraints = false
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.translatesAutoresizingMaskIntoConstraints = false
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        check.contentTintColor = .controlAccentColor
        check.translatesAutoresizingMaskIntoConstraints = false
        check.isHidden = true
        addSubview(indicator)
        addSubview(check)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.centerXAnchor.constraint(equalTo: centerXAnchor),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Show progress"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Progress")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(with operations: [FileOperation]) {
        let active = operations.filter { !$0.state.isDone }
        let finished = !operations.isEmpty && active.isEmpty
        // Called ten times a second: only real changes reach the views.
        if check.isHidden == finished { check.isHidden = !finished }
        if indicator.isHidden != finished { indicator.isHidden = finished }
        if !active.isEmpty {
            let fraction = active.reduce(0.0) { $0 + $1.fractionCompleted } / Double(active.count)
            let value = max(0.02, fraction)
            if abs(indicator.doubleValue - value) > 0.002 { indicator.doubleValue = value }
        }
    }

    // Acts on mouse-up inside, like a native button; a press dragged away does nothing.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    /// Not part of the toolbar's window-drag region, so the click arrives.
    override var mouseDownCanMoveWindow: Bool { false }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - Finished confirmation

/// A native popover under the toolbar's progress item confirming a finished
/// operation that was too quick for the progress window ("Copied “X” in
/// 0.01 s — instant APFS clone").
enum OperationFinishedPopover {
    private static var popover: NSPopover?
    private static var generation = 0

    static func show(_ operation: FileOperation, relativeTo view: NSView) {
        popover?.close()
        let controller = NSViewController()
        let row = OperationRowView(operation: operation, compact: true)
        row.translatesAutoresizingMaskIntoConstraints = false
        // As wide as the message (18 + icon + 12 + text + 18), within 240...380.
        let width = min(380, max(240, row.fittingSize.width.rounded(.up)))
        let container = NSView()
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: width),
        ])
        controller.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        self.popover = popover
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard current == generation else { return }
            popover.performClose(nil)
        }
    }
}

// MARK: - Conflicts

/// "An item named “X” already exists in this location." — a native alert
/// with Finder's choices, Merge for folders, Skip, and a side-by-side
/// comparison of the two items.
enum ConflictDialog {
    static func present(source: URL, existing: URL, operation: FileOperation,
                        completion: @escaping (ConflictResolution, Bool) -> Void) {
        let verb: String
        switch operation.kind {
        case .move: verb = "moving"
        case .duplicate: verb = "duplicating"
        default: verb = "copying"
        }
        let incoming = ConflictItemInfo(url: source)
        let current = ConflictItemInfo(url: existing)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = incoming.icon
        alert.messageText = "An item named “\(source.lastPathComponent)” already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you’re \(verb)? The replaced item goes to the Trash.\n\n"
            + describe("Existing", current, comparedTo: incoming) + "\n" + describe("New", incoming, comparedTo: current)
        var choices: [ConflictResolution] = [.keepBoth, .replace]
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        if incoming.isDirectory && current.isDirectory {
            alert.addButton(withTitle: "Merge")
            choices.append(.merge)
        }
        alert.addButton(withTitle: "Skip")
        choices.append(.skip)
        let stop = alert.addButton(withTitle: "Stop")
        stop.keyEquivalent = "\u{1b}"
        choices.append(.stop)
        if operation.sources.count > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to All"
        }

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let resolution = index >= 0 && index < choices.count ? choices[index] : .stop
            let all = alert.suppressionButton?.state == .on
            completion(resolution, resolution == .stop ? false : all)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil, !(window is NSPanel) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// "Existing: Today, 6:59 PM · 2.1 GB (newer)".
    private static func describe(_ title: String, _ info: ConflictItemInfo, comparedTo other: ConflictItemInfo) -> String {
        let date = info.modified.map { Formatters.listDate($0.timeIntervalSince1970, length: .medium) } ?? "--"
        let otherDate = other.modified.map { Formatters.listDate($0.timeIntervalSince1970, length: .medium) } ?? "--"
        let sizeText = info.size.map { Formatters.size($0) } ?? (info.isDirectory ? "Folder" : "--")
        let otherSizeText = other.size.map { Formatters.size($0) } ?? (other.isDirectory ? "Folder" : "--")
        let parts = [date, sizeText]
        // Marked only when the shown values differ too: "(newer)" next to two
        // identical times reads as a mistake.
        var marks: [String] = []
        if date != otherDate && (info.modified ?? .distantPast) > (other.modified ?? .distantPast) { marks.append("newer") }
        if sizeText != otherSizeText && (info.size ?? 0) > (other.size ?? 0) { marks.append("larger") }
        let suffix = marks.isEmpty ? "" : " (" + marks.joined(separator: ", ") + ")"
        return "\(title): " + parts.joined(separator: " · ") + suffix
    }
}

struct ConflictItemInfo {
    let url: URL
    let icon: NSImage
    let modified: Date?
    let size: Int64?
    let isDirectory: Bool

    init(url: URL) {
        self.url = url
        icon = NSWorkspace.shared.icon(forFile: url.path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .totalFileSizeKey, .isDirectoryKey])
        modified = values?.contentModificationDate
        size = values?.totalFileSize.map { Int64($0) }
        isDirectory = values?.isDirectory ?? false
    }
}
