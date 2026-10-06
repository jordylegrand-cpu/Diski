import AppKit
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var showHidden = Prefs.showHiddenFiles { didSet { Prefs.showHiddenFiles = showHidden } }
    @Published var foldersOnTop = Prefs.foldersOnTop { didSet { Prefs.foldersOnTop = foldersOnTop } }
    @Published var fullPathTitle = Prefs.showFullPathInTitle { didSet { Prefs.showFullPathInTitle = fullPathTitle } }
    @Published var returnOpens = Prefs.returnKeyOpens { didSet { Prefs.returnKeyOpens = returnOpens } }
    @Published var confirmEmptyTrash = Prefs.confirmEmptyTrash { didSet { Prefs.confirmEmptyTrash = confirmEmptyTrash } }
    @Published var toasts = Prefs.showOperationToasts { didSet { Prefs.showOperationToasts = toasts } }
    @Published var useClones = Prefs.useClones { didSet { Prefs.useClones = useClones } }
    @Published var streams = Prefs.copyStreamsSetting { didSet { Prefs.copyStreamsSetting = streams } }
    @Published var folderSizes = Prefs.calculateFolderSizes { didSet { Prefs.calculateFolderSizes = folderSizes } }
    @Published var thumbnails = Prefs.showThumbnailsInList { didSet { Prefs.showThumbnailsInList = thumbnails } }
    @Published var density = Prefs.rowDensity.rawValue { didSet { Prefs.rowDensity = RowDensity(rawValue: density) ?? .comfortable } }
    @Published var iconSize = Double(Prefs.iconSize) { didSet { Prefs.iconSize = CGFloat(iconSize) } }
    @Published var viewMode = Prefs.defaultViewMode.rawValue { didSet { Prefs.defaultViewMode = ViewMode(rawValue: viewMode) ?? .list } }
    @Published var newWindowPath = Prefs.newWindowPath { didSet { Prefs.newWindowPath = newWindowPath } }
    @Published var terminal = Prefs.terminalBundleID { didSet { Prefs.terminalBundleID = terminal } }
    @Published var benchmark = ""
    @Published var benchmarking = false

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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            speed.tabItem { Label("Speed", systemImage: "bolt") }
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
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
        }
        .formStyle(.grouped)
    }

    private var speed: some View {
        Form {
            Section {
                Toggle("Instant copies with APFS clones", isOn: $model.useClones)
                Text("Copies on the same APFS volume are cloned copy-on-write: they finish instantly and take no extra space until edited.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Parallel copy streams", selection: $model.streams) {
                    Text("Automatic").tag(0)
                    ForEach([1, 2, 4, 6, 8, 12, 16], id: \.self) { n in Text("\(n)").tag(n) }
                }
                Text("Folders with many files copy across drives several files at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }

    private var appearance: some View {
        Form {
            Picker("List row size", selection: $model.density) {
                ForEach(RowDensity.allCases, id: \.rawValue) { density in Text(density.title).tag(density.rawValue) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading) {
                Text("Icon size in icon view: \(Int(model.iconSize)) pt")
                Slider(value: $model.iconSize, in: 32...256)
            }
        }
        .formStyle(.grouped)
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView(model: SettingsModel()))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Diski Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }
}
