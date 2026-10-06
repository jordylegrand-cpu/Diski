import AppKit
import SwiftUI

/// View Options (⌘J): per-pane sorting plus the app-wide display settings.
final class ViewOptionsModel: ObservableObject {
    private weak var pane: PaneViewController?
    @Published var sortKey: String { didSet { applySort() } }
    @Published var ascending: Bool { didSet { applySort() } }
    @Published var foldersOnTop = Prefs.foldersOnTop { didSet { Prefs.foldersOnTop = foldersOnTop } }
    @Published var showHidden = Prefs.showHiddenFiles { didSet { Prefs.showHiddenFiles = showHidden } }
    @Published var folderSizes = Prefs.calculateFolderSizes { didSet { Prefs.calculateFolderSizes = folderSizes } }
    @Published var thumbnails = Prefs.showThumbnailsInList { didSet { Prefs.showThumbnailsInList = thumbnails } }
    @Published var density = Prefs.rowDensity.rawValue { didSet { Prefs.rowDensity = RowDensity(rawValue: density) ?? .comfortable } }
    @Published var iconSize = Double(Prefs.iconSize) { didSet { Prefs.iconSize = CGFloat(iconSize) } }
    let viewMode: ViewMode

    init(pane: PaneViewController) {
        self.pane = pane
        sortKey = pane.arrangeOptions.sortKey.rawValue
        ascending = pane.arrangeOptions.ascending
        viewMode = pane.viewMode
    }

    private func applySort() {
        guard let pane, let key = SortKey(rawValue: sortKey) else { return }
        if key != pane.arrangeOptions.sortKey || ascending != pane.arrangeOptions.ascending {
            pane.setSort(key, ascending: ascending)
        }
    }
}

struct ViewOptionsView: View {
    @ObservedObject var model: ViewOptionsModel

    var body: some View {
        Form {
            Section {
                Picker("Sort by", selection: $model.sortKey) {
                    ForEach(SortKey.allCases, id: \.rawValue) { key in Text(key.title).tag(key.rawValue) }
                }
                Picker("Order", selection: $model.ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Keep folders on top", isOn: $model.foldersOnTop)
            }
            Section {
                Toggle("Show hidden files", isOn: $model.showHidden)
                Toggle("Calculate folder sizes", isOn: $model.folderSizes)
                Toggle("Show thumbnails in lists", isOn: $model.thumbnails)
            }
            Section {
                if model.viewMode == .icons {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Icon size: \(Int(model.iconSize)) pt")
                        Slider(value: $model.iconSize, in: 32...256)
                    }
                } else {
                    Picker("Row size", selection: $model.density) {
                        ForEach(RowDensity.allCases, id: \.rawValue) { density in Text(density.title).tag(density.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
enum ViewOptionsPopover {
    private static var popover: NSPopover?

    static func toggle(for pane: PaneViewController, in window: NSWindow) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let anchor = window.contentView else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ViewOptionsView(model: ViewOptionsModel(pane: pane)))
        // Anchor under the toolbar, near its trailing edge.
        let safeTop = anchor.safeAreaInsets.top
        let rect = NSRect(x: anchor.bounds.maxX - 320, y: anchor.bounds.maxY - safeTop - 4, width: 1, height: 1)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
        self.popover = popover
    }
}
