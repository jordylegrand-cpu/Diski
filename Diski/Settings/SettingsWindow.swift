import AppKit
import SwiftUI

/// The Settings window's values. Each one writes through to Prefs only when
/// it differs (Prefs posts on every write), and changes made elsewhere
/// (⇧⌘., View Options) are read back while the window is open.
final class SettingsModel: ObservableObject {
    @Published var automaticUpdates = Prefs.automaticUpdates {
        didSet { if Prefs.automaticUpdates != automaticUpdates { Prefs.automaticUpdates = automaticUpdates } }
    }
    @Published var showHidden = Prefs.showHiddenFiles {
        didSet { if Prefs.showHiddenFiles != showHidden { Prefs.showHiddenFiles = showHidden } }
    }
    @Published var foldersOnTop = Prefs.foldersOnTop {
        didSet { if Prefs.foldersOnTop != foldersOnTop { Prefs.foldersOnTop = foldersOnTop } }
    }
    @Published var fullPathTitle = Prefs.showFullPathInTitle {
        didSet { if Prefs.showFullPathInTitle != fullPathTitle { Prefs.showFullPathInTitle = fullPathTitle } }
    }
    @Published var returnOpens = Prefs.returnKeyOpens {
        didSet { if Prefs.returnKeyOpens != returnOpens { Prefs.returnKeyOpens = returnOpens } }
    }
    @Published var confirmEmptyTrash = Prefs.confirmEmptyTrash {
        didSet { if Prefs.confirmEmptyTrash != confirmEmptyTrash { Prefs.confirmEmptyTrash = confirmEmptyTrash } }
    }
    @Published var toasts = Prefs.showOperationToasts {
        didSet { if Prefs.showOperationToasts != toasts { Prefs.showOperationToasts = toasts } }
    }
    @Published var useClones = Prefs.useClones {
        didSet { if Prefs.useClones != useClones { Prefs.useClones = useClones } }
    }
    @Published var streams = Prefs.copyStreamsSetting {
        didSet { if Prefs.copyStreamsSetting != streams { Prefs.copyStreamsSetting = streams } }
    }
    @Published var folderSizes = Prefs.calculateFolderSizes {
        didSet { if Prefs.calculateFolderSizes != folderSizes { Prefs.calculateFolderSizes = folderSizes } }
    }
    @Published var thumbnails = Prefs.showThumbnailsInList {
        didSet { if Prefs.showThumbnailsInList != thumbnails { Prefs.showThumbnailsInList = thumbnails } }
    }
    @Published var density = Prefs.rowDensity.rawValue {
        didSet {
            let value = RowDensity(rawValue: density) ?? .comfortable
            if Prefs.rowDensity != value { Prefs.rowDensity = value }
        }
    }
    /// The slider's raw value; Prefs gets it snapped to a multiple of 4 so
    /// icons centre on whole points.
    @Published var iconSize = Double(Prefs.iconSize) {
        didSet {
            let snapped = CGFloat((iconSize / 4).rounded() * 4)
            if Prefs.iconSize != snapped { Prefs.iconSize = snapped }
        }
    }
    @Published var viewMode = Prefs.defaultViewMode.rawValue {
        didSet {
            let value = ViewMode(rawValue: viewMode) ?? .list
            if Prefs.defaultViewMode != value { Prefs.defaultViewMode = value }
        }
    }
    @Published var newWindowPath = Prefs.newWindowPath {
        didSet { if Prefs.newWindowPath != newWindowPath { Prefs.newWindowPath = newWindowPath } }
    }
    @Published var terminal = Prefs.terminalBundleID {
        didSet { if Prefs.terminalBundleID != terminal { Prefs.terminalBundleID = terminal } }
    }
    @Published var benchmark = ""
    @Published var benchmarking = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: Prefs.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reads back what changed elsewhere. Only differing values are assigned,
    /// so the didSet write-throughs above never loop.
    private func refresh() {
        if automaticUpdates != Prefs.automaticUpdates { automaticUpdates = Prefs.automaticUpdates }
        if showHidden != Prefs.showHiddenFiles { showHidden = Prefs.showHiddenFiles }
        if foldersOnTop != Prefs.foldersOnTop { foldersOnTop = Prefs.foldersOnTop }
        if fullPathTitle != Prefs.showFullPathInTitle { fullPathTitle = Prefs.showFullPathInTitle }
        if returnOpens != Prefs.returnKeyOpens { returnOpens = Prefs.returnKeyOpens }
        if confirmEmptyTrash != Prefs.confirmEmptyTrash { confirmEmptyTrash = Prefs.confirmEmptyTrash }
        if toasts != Prefs.showOperationToasts { toasts = Prefs.showOperationToasts }
        if useClones != Prefs.useClones { useClones = Prefs.useClones }
        if streams != Prefs.copyStreamsSetting { streams = Prefs.copyStreamsSetting }
        if folderSizes != Prefs.calculateFolderSizes { folderSizes = Prefs.calculateFolderSizes }
        if thumbnails != Prefs.showThumbnailsInList { thumbnails = Prefs.showThumbnailsInList }
        if density != Prefs.rowDensity.rawValue { density = Prefs.rowDensity.rawValue }
        // Compared snapped, so a slider drag in progress is not pulled back.
        if CGFloat((iconSize / 4).rounded() * 4) != Prefs.iconSize { iconSize = Double(Prefs.iconSize) }
        if viewMode != Prefs.defaultViewMode.rawValue { viewMode = Prefs.defaultViewMode.rawValue }
        if newWindowPath != Prefs.newWindowPath { newWindowPath = Prefs.newWindowPath }
        if terminal != Prefs.terminalBundleID { terminal = Prefs.terminalBundleID }
    }

    func runBenchmark() {
        benchmarking = true
        benchmark = "Measuring…"
        let path = NSHomeDirectory() + "/Library"
        DispatchQueue.global(qos: .userInitiated).async {
            let rounds = 30
            var diskiTime = 0.0
            var foundationTime = 0.0
            var count = 0
            let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                          .creationDateKey, .isHiddenKey, .isPackageKey]
            for _ in 0..<rounds {
                let start = CFAbsoluteTimeGetCurrent()
                let items = (try? DirectoryReader.read(path: path)) ?? []
                diskiTime += CFAbsoluteTimeGetCurrent() - start
                count = items.count

                let start2 = CFAbsoluteTimeGetCurrent()
                let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                                         includingPropertiesForKeys: keys)) ?? []
                for url in urls { _ = try? url.resourceValues(forKeys: Set(keys)) }
                foundationTime += CFAbsoluteTimeGetCurrent() - start2
            }
            let diski = diskiTime / Double(rounds) * 1000
            let foundation = foundationTime / Double(rounds) * 1000
            let factor = diski > 0 ? foundation / diski : 0
            let text = String(format: "Listing ~/Library (%d items): Diski %.2f ms · FileManager %.2f ms · %.1f× faster",
                              count, diski, foundation, factor)
            DispatchQueue.main.async {
                self.benchmark = text
                self.benchmarking = false
            }
        }
    }
}

/// One pane of the Settings window. The panes are native toolbar tabs
/// (SettingsWindowController), so no tab box frames the grouped forms.
struct SettingsView: View {
    enum Page { case general, speed, appearance }

    @ObservedObject var model: SettingsModel
    let page: Page

    var body: some View {
        Group {
            switch page {
            case .general: general
            case .speed: speed
            case .appearance: appearance
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var general: some View {
        Form {
            Picker("New windows open", selection: $model.newWindowPath) {
                Text("Home").tag(NSHomeDirectory())
                Text("Desktop").tag(NSHomeDirectory() + "/Desktop")
                Text("Documents").tag(NSHomeDirectory() + "/Documents")
                Text("Downloads").tag(NSHomeDirectory() + "/Downloads")
                Text("Computer").tag("/")
            }
            Picker("Default view", selection: $model.viewMode) {
                ForEach(ViewMode.allCases, id: \.rawValue) { mode in Text(mode.title).tag(mode.rawValue) }
            }
            Picker("Return key", selection: $model.returnOpens) {
                Text("Renames the selection (like Finder)").tag(false)
                Text("Opens the selection").tag(true)
            }
            Toggle("Show the full path in the window title", isOn: $model.fullPathTitle)
            Toggle("Keep folders on top", isOn: $model.foldersOnTop)
            Toggle("Show hidden files", isOn: $model.showHidden)
            Toggle("Ask before emptying the Trash", isOn: $model.confirmEmptyTrash)
            Toggle("Show a confirmation after copying, moving and trashing", isOn: $model.toasts)
            Picker("Open in Terminal uses", selection: $model.terminal) {
                Text("Terminal").tag("com.apple.Terminal")
                Text("iTerm").tag("com.googlecode.iterm2")
                Text("Ghostty").tag("com.mitchellh.ghostty")
                Text("Warp").tag("dev.warp.Warp-Stable")
            }
            Section {
                Toggle(isOn: $model.automaticUpdates) {
                    Text("Keep Diski up to date")
                    Text("Checks GitHub for new releases and installs them when Diski relaunches or quits.")
                }
                LabeledContent("Version") {
                    HStack {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
                        Button("Check Now") { Updater.shared.checkNow(userInitiated: true) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var speed: some View {
        Form {
            Section {
                // The second Text is the grouped form's native secondary description.
                Toggle(isOn: $model.useClones) {
                    Text("Instant copies with APFS clones")
                    Text("Copies on the same APFS volume are cloned copy-on-write: they finish instantly and take no extra space until edited.")
                }
                Picker(selection: $model.streams) {
                    Text("Automatic").tag(0)
                    ForEach([1, 2, 4, 6, 8, 12, 16], id: \.self) { n in Text("\(n)").tag(n) }
                } label: {
                    Text("Parallel copy streams")
                    Text("Folders with many files copy across drives several files at a time.")
                }
            }
            Section {
                Toggle("Calculate folder sizes automatically", isOn: $model.folderSizes)
                Toggle("Show thumbnails in list view", isOn: $model.thumbnails)
            }
            Section("Speed test") {
                HStack {
                    Text(model.benchmark.isEmpty ? "Compare Diski’s folder reading with the system’s." : model.benchmark)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Run") { model.runBenchmark() }
                        .disabled(model.benchmarking)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var appearance: some View {
        Form {
            Picker("List row size", selection: $model.density) {
                ForEach(RowDensity.allCases, id: \.rawValue) { density in Text(density.title).tag(density.rawValue) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Icon size") {
                HStack {
                    Slider(value: $model.iconSize, in: 32...256)
                        .labelsHidden()
                    // The size icon view uses: the slider snapped to a multiple of 4.
                    Text("\(Int((model.iconSize / 4).rounded() * 4)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Settings (⌘,): native toolbar tabs, one hosted SwiftUI pane each; the
/// window takes the selected pane's title, like the system's settings windows.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let model = SettingsModel()
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let pages: [(SettingsView.Page, String, String)] = [
            (.general, "General", "gearshape"),
            (.speed, "Speed", "bolt"),
            (.appearance, "Appearance", "paintbrush"),
        ]
        for (page, title, symbol) in pages {
            let host = NSHostingController(rootView: SettingsView(model: model, page: page))
            host.sizingOptions = .preferredContentSize
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }
}
