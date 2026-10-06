import AppKit
import SwiftUI

// MARK: - Toast

/// A small Liquid Glass capsule that confirms what just happened.
final class ToastView: NSView {
    private let glass = NSGlassEffectView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 18
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        content.addSubview(icon)
        content.addSubview(label)
        glass.contentView = content
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            heightAnchor.constraint(equalToConstant: 36),
        ])
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, symbol: String) {
        generation += 1
        let current = generation
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.animator().alphaValue = 0
            }, completionHandler: {
                if self.generation == current { self.isHidden = true }
            })
        }
    }
}

// MARK: - Toolbar progress ring

final class OperationsToolbarView: NSView {
    var onClick: (() -> Void)?
    private var fraction: Double = 0
    private var running = false
    private var finished = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        toolTip = "File operations"
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(with operations: [FileOperation]) {
        let active = operations.filter { !$0.state.isDone }
        running = !active.isEmpty
        finished = !operations.isEmpty && active.isEmpty
        if running {
            let total = active.reduce(0.0) { $0 + $1.fractionCompleted }
            fraction = total / Double(active.count)
        } else {
            fraction = finished ? 1 : 0
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 6)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.5
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()
        if finished {
            NSColor.controlAccentColor.setStroke()
            track.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
            if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = check.size
                check.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                      width: size.width, height: size.height))
            }
            return
        }
        guard fraction > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
        arc.lineWidth = 2.5
        arc.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        arc.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - Operations popover

final class OperationsModel: ObservableObject {
    @Published var operations: [FileOperation] = []
    @Published var tick = 0
    private var observer: NSObjectProtocol?

    init() {
        operations = FileOperationManager.shared.operations
        observer = NotificationCenter.default.addObserver(forName: FileOperationManager.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            guard let self else { return }
            self.operations = FileOperationManager.shared.operations
            self.tick += 1
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

struct OperationsListView: View {
    @ObservedObject var model: OperationsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.operations.isEmpty {
                Text("No file operations")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ForEach(model.operations) { operation in
                    OperationRow(operation: operation, tick: model.tick)
                    if operation.id != model.operations.last?.id { Divider() }
                }
            }
        }
        .frame(width: 380)
        .padding(.vertical, 6)
    }
}

struct OperationRow: View {
    let operation: FileOperation
    let tick: Int

    var body: some View {
        let snapshot = operation.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(operation.state == .finished ? Color.green : Color.accentColor)
                Text(operation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !operation.state.isDone {
                    Button {
                        operation.setPaused(!operation.isPaused)
                    } label: {
                        Image(systemName: operation.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(operation.isPaused ? "Resume" : "Pause")
                    Button {
                        operation.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop")
                }
            }
            if !operation.state.isDone {
                ProgressView(value: snapshot.scanning && snapshot.totalBytes == 0 ? nil : operation.fractionCompleted)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            Text(detail(snapshot))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var symbol: String {
        switch operation.state {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        default:
            switch operation.kind {
            case .trash, .delete, .emptyTrash: return "trash"
            case .compress: return "archivebox"
            case .move: return "arrow.right.doc.on.clipboard"
            default: return "doc.on.doc"
            }
        }
    }

    private func detail(_ s: FileOperation.Snapshot) -> String {
        switch operation.state {
        case .finished:
            let elapsed = (operation.finishedAt ?? Date()).timeIntervalSince(operation.startedAt)
            var text = "Done in \(Formatters.duration(elapsed))"
            if s.instant && (operation.kind == .copy || operation.kind == .duplicate) { text += " · instant APFS clone" }
            else if s.totalBytes > 0 && elapsed > 0.05 { text += " · \(Formatters.rate(Double(s.totalBytes) / elapsed)) average" }
            return text
        case .failed(let message):
            return message
        case .cancelled:
            return "Stopped"
        case .paused:
            return "Paused"
        default:
            if operation.isPaused { return "Paused — \(Formatters.size(s.completedBytes)) of \(Formatters.size(s.totalBytes))" }
            var parts: [String] = []
            if s.totalBytes > 0 {
                parts.append("\(Formatters.size(s.completedBytes)) of \(Formatters.size(s.totalBytes))\(s.scanning ? "+" : "")")
            } else if s.totalItems > 0 {
                parts.append("\(s.completedItems) of \(s.totalItems) items")
            }
            let rate = Formatters.rate(operation.bytesPerSecond)
            if !rate.isEmpty { parts.append(rate) }
            if let remaining = operation.estimatedSecondsRemaining { parts.append(Formatters.remaining(remaining)) }
            if !s.currentName.isEmpty { parts.append(s.currentName) }
            return parts.joined(separator: " · ")
        }
    }
}

enum OperationsPopover {
    private static var popover: NSPopover?

    static func show(relativeTo view: NSView) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: OperationsListView(model: OperationsModel()))
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        self.popover = popover
    }
}

// MARK: - Conflict dialog

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

struct ConflictView: View {
    let incoming: ConflictItemInfo
    let existing: ConflictItemInfo
    let verb: String
    let onChoice: (ConflictResolution, Bool) -> Void
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: incoming.icon).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("An item named “\(incoming.url.lastPathComponent)” already exists in this location.")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Do you want to replace it with the one you’re \(verb)? The replaced item goes to the Trash, so you can get it back.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                card(title: "Existing", info: existing, other: incoming)
                Image(systemName: "arrow.left").foregroundStyle(.tertiary)
                card(title: "New", info: incoming, other: existing)
            }
            Toggle("Apply to all", isOn: $applyToAll)
                .toggleStyle(.checkbox)
            HStack {
                Button("Stop") { onChoice(.stop, false) }
                    .keyboardShortcut(.cancelAction)
                Button("Skip") { onChoice(.skip, applyToAll) }
                Spacer()
                if incoming.isDirectory && existing.isDirectory {
                    Button("Merge") { onChoice(.merge, applyToAll) }
                }
                Button("Replace") { onChoice(.replace, applyToAll) }
                Button("Keep Both") { onChoice(.keepBoth, applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func card(title: String, info: ConflictItemInfo, other: ConflictItemInfo) -> some View {
        let newer = (info.modified ?? .distantPast) > (other.modified ?? .distantPast)
        let larger = (info.size ?? 0) > (other.size ?? 0)
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(info.modified.map { Formatters.longDate($0) } ?? "--").font(.system(size: 11))
                if newer { Text("Newer").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor) }
            }
            HStack(spacing: 4) {
                Text(info.size.map { Formatters.size($0) } ?? (info.isDirectory ? "Folder" : "--")).font(.system(size: 11))
                if larger { Text("Larger").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

enum ConflictDialog {
    /// Presents the conflict sheet on the key window (or as a panel) and calls back on the main thread.
    static func present(source: URL, existing: URL, operation: FileOperation,
                        completion: @escaping (ConflictResolution, Bool) -> Void) {
        let verb: String
        switch operation.kind {
        case .move: verb = "moving"
        case .duplicate: verb = "duplicating"
        default: verb = "copying"
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 260),
                            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        var finished = false
        let view = ConflictView(incoming: ConflictItemInfo(url: source), existing: ConflictItemInfo(url: existing),
                                verb: verb) { resolution, all in
            guard !finished else { return }
            finished = true
            if let parent = panel.sheetParent {
                parent.endSheet(panel)
            } else {
                panel.orderOut(nil)
                NSApp.stopModal()
            }
            completion(resolution, all)
        }
        panel.contentViewController = NSHostingController(rootView: view)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            window.beginSheet(panel)
        } else {
            panel.center()
            NSApp.runModal(for: panel)
        }
    }
}
