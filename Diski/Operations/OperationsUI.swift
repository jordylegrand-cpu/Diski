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

    init(operation: FileOperation) {
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
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            pauseButton.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            pauseButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stopButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 4),
            stopButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            detailBelowBar,
        ])
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
        bar.isHidden = done
        pauseButton.isHidden = done
        stopButton.isHidden = done
        detailBelowBar.isActive = !done
        detailBelowTitle.isActive = done
        if done {
            bar.stopAnimation(nil)
            title.stringValue = finishedTitle
        } else {
            title.stringValue = operation.title
            let snapshot = operation.snapshot
            let indeterminate = snapshot.scanning && snapshot.totalBytes == 0 && snapshot.totalItems == 0
            if bar.isIndeterminate != indeterminate {
                bar.isIndeterminate = indeterminate
                if indeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
            }
            if !indeterminate { bar.doubleValue = operation.fractionCompleted }
            let paused = operation.isPaused
            pauseButton.image = NSImage(systemSymbolName: paused ? "play.circle.fill" : "pause.circle.fill",
                                        accessibilityDescription: paused ? "Resume" : "Pause")
            pauseButton.toolTip = paused ? "Resume" : "Pause"
        }
        detail.stringValue = detailText
        if case .failed = operation.state {
            detail.textColor = .systemRed
        } else {
            detail.textColor = .secondaryLabelColor
        }
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
                parts.append("\(s.completedItems) of \(s.totalItems) items")
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
        NSRect(x: 0, y: bounds.midY - 0.5 / scale, width: bounds.width, height: 1 / scale).fill()
    }
}

// MARK: - Progress window

/// Finder's "Copy" window: a native window listing the running operations.
/// It opens by itself when an operation takes longer than a moment and
/// closes when everything is done.
final class ProgressWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ProgressWindowController()

    private let stack = NSStackView()
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
        super.init(window: panel)
        panel.delegate = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 460),
        ])
        panel.contentView = content
        panel.setFrameAutosaveName("DiskiProgressWindow")

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(operationsChanged), name: FileOperationManager.didChange, object: nil)
        center.addObserver(self, selector: #selector(operationFinished(_:)), name: FileOperationManager.didFinish, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Whether the window was on screen while `operation` ran.
    func didShow(_ operation: FileOperation) -> Bool {
        rows[ObjectIdentifier(operation)] != nil && window?.isVisible == true
    }

    /// Shows the window with every running operation, and the results of the
    /// ones that just finished (toolbar button, Window menu).
    func present() {
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
        place()
        window?.orderFront(nil)
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
                if self.window?.isVisible != true {
                    self.place()
                    self.window?.orderFront(nil)
                }
            }
        }
        if window?.isVisible == true { sync() }
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
            for (index, operation) in wanted.enumerated() {
                let id = ObjectIdentifier(operation)
                let row = rows[id] ?? OperationRowView(operation: operation)
                kept[id] = row
                if index > 0 {
                    let line = HairlineView()
                    line.translatesAutoresizingMaskIntoConstraints = false
                    stack.addArrangedSubview(line)
                    line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
                row.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            rows = kept
            window?.title = Self.title(for: wanted)
            resizeToFit()
        }
        for row in rows.values { row.update() }
        if wanted.isEmpty, window?.isVisible == true {
            window?.orderOut(nil)
            dismissedByUser = false
        }
    }

    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(76, stack.fittingSize.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 460, height: height)))
        // Grow and shrink downwards from the title bar.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    /// First appearance: centered horizontally over the browser, near its top.
    private func place() {
        guard let window, !window.isVisible else { return }
        if UserDefaults.standard.string(forKey: "NSWindow Frame DiskiProgressWindow") != nil { return }
        if let browser = NSApp.mainWindow ?? NSApp.keyWindow, browser !== window {
            let x = browser.frame.midX - window.frame.width / 2
            let y = browser.frame.maxY - 140 - window.frame.height
            window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        } else {
            window.center()
        }
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
        check.isHidden = !finished
        indicator.isHidden = finished
        if !active.isEmpty {
            let fraction = active.reduce(0.0) { $0 + $1.fractionCompleted } / Double(active.count)
            indicator.doubleValue = max(0.02, fraction)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

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
        let row = OperationRowView(operation: operation)
        row.frame = NSRect(x: 0, y: 0, width: 380, height: 60)
        row.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 380),
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
        alert.informativeText = "Do you want to replace it with the one you’re \(verb)? The replaced item goes to the Trash."
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
        alert.accessoryView = comparison(existing: current, incoming: incoming)

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

    /// Existing and new item side by side: modification date and size, with
    /// the newer and the larger one marked.
    private static func comparison(existing: ConflictItemInfo, incoming: ConflictItemInfo) -> NSView {
        func label(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.lineBreakMode = .byTruncatingTail
            return field
        }
        func column(_ title: String, _ info: ConflictItemInfo, _ other: ConflictItemInfo) -> NSStackView {
            let newer = (info.modified ?? .distantPast) > (other.modified ?? .distantPast)
            let larger = (info.size ?? 0) > (other.size ?? 0)
            var views: [NSView] = [label(title, weight: .semibold, color: .secondaryLabelColor)]
            views.append(label(info.modified.map { Formatters.listDate($0.timeIntervalSince1970, length: .short) } ?? "--"))
            views.append(label(info.size.map { Formatters.size($0) } ?? (info.isDirectory ? "Folder" : "--")))
            var marks: [String] = []
            if newer { marks.append("Newer") }
            if larger { marks.append("Larger") }
            views.append(label(marks.isEmpty ? " " : marks.joined(separator: " · "), size: 10, weight: .semibold,
                               color: .controlAccentColor))
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            return stack
        }
        let row = NSStackView(views: [column("Existing", existing, incoming), column("New", incoming, existing)])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 12
        row.frame = NSRect(x: 0, y: 0, width: 230, height: 64)
        return row
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
