import AppKit
import CoreServices
import SwiftUI

struct InfoRow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let value: String
}

final class InspectorModel: ObservableObject {
    @Published var title = ""
    @Published var subtitle = ""
    @Published var image: NSImage?
    @Published var rows: [InfoRow] = []
    @Published var moreRows: [InfoRow] = []
    @Published var tags: [String] = []
    @Published var urls: [URL] = []
    @Published var compact = false
    @Published var hasContent = false
    @Published var showMore = false
    var onAddTag: ((String) -> Void)?
    var onRemoveTag: ((String) -> Void)?
}

/// The preview pane (Finder's "Show Preview"): big preview, name, facts, tags.
final class InspectorViewController: NSViewController {
    let model = InspectorModel()
    private var token = 0
    private var currentKey = ""
    /// The folder whose size is shown; recalculated when its contents change.
    private var sizedFolder: (item: FileItem, kind: String)?
    private var sizeRefreshScheduled = false

    var compact: Bool {
        get { model.compact }
        set { if model.compact != newValue { model.compact = newValue } }
    }

    override func loadView() {
        model.onAddTag = { [weak self] tag in self?.addTag(tag) }
        model.onRemoveTag = { [weak self] tag in self?.removeTag(tag) }
        let hosting = NSHostingView(rootView: InspectorView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        view = container

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(folderContentsDidChange(_:)),
                           name: DirectoryStore.folderContentsDidChange, object: nil)
        center.addObserver(self, selector: #selector(directoryDidUpdate(_:)),
                           name: DirectoryStore.didUpdate, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Shows `items`, or the folder at `folderPath` when nothing is selected.
    func show(items: [FileItem], folderPath: String?) {
        let key = items.map { "\($0.path)|\($0.modified)|\($0.labelIndex)" }.joined(separator: "\n") + "|" + (folderPath ?? "")
        guard key != currentKey else { return }
        currentKey = key
        token += 1
        let token = self.token
        sizedFolder = nil

        var subjects = items
        if subjects.isEmpty, let folderPath, let folder = FileItem.make(path: folderPath) {
            subjects = [folder]
        }
        guard !subjects.isEmpty else {
            model.hasContent = false
            model.urls = []
            return
        }
        model.hasContent = true
        model.urls = subjects.map { $0.url }
        model.showMore = false

        if subjects.count > 1 {
            describeMultiple(subjects, token: token)
        } else {
            describe(subjects[0], token: token)
        }
    }

    private func describeMultiple(_ items: [FileItem], token: Int) {
        model.title = "\(items.count) items"
        let total = items.reduce(Int64(0)) { $0 + max(0, $1.displaySize) }
        let folders = items.filter { $0.isDirectoryOnDisk }.count
        var parts: [String] = []
        if folders > 0 { parts.append(Formatters.count(folders, "folder")) }
        if items.count - folders > 0 { parts.append(Formatters.count(items.count - folders, "file")) }
        model.subtitle = parts.joined(separator: ", ") + (total > 0 ? " – " + Formatters.size(total) : "")
        model.image = IconCache.shared.immediateIcon(for: items[0])
        let modified = items.map { $0.modified }.max() ?? 0
        model.rows = [InfoRow(label: "Latest change", value: Formatters.longDate(Date(timeIntervalSince1970: modified)))]
        model.moreRows = []
        model.tags = []
    }

    private func describe(_ item: FileItem, token: Int) {
        model.title = item.name
        let kind = FileKinds.kind(for: item)
        let size = item.displaySize
        model.subtitle = size >= 0 ? "\(kind) – \(Formatters.size(size))" : kind
        model.image = IconCache.shared.cachedItemIcon(path: item.path) ?? IconCache.shared.immediateIcon(for: item)
        model.rows = [
            InfoRow(label: "Created", value: Formatters.longDate(item.createdDate)),
            InfoRow(label: "Modified", value: Formatters.longDate(item.modifiedDate)),
        ]
        model.moreRows = baseMoreRows(for: item, kind: kind)
        model.tags = []

        // Item artwork / thumbnail.
        if IconCache.shared.needsItemIcon(item) {
            IconCache.shared.loadItemIcon(for: item) { [weak self] icon in
                guard let self, token == self.token, !FileKinds.wantsThumbnail(item) else { return }
                self.model.image = icon
            }
        }
        if FileKinds.wantsThumbnail(item) {
            let scale = view.window?.backingScaleFactor ?? 2
            ThumbnailCache.shared.request(for: item, points: 256, scale: scale) { [weak self] image in
                guard let self, token == self.token, let image else { return }
                self.model.image = image
            }
        }

        // Folder size, computed in the background.
        if item.type == .directory || (item.type == .package && item.size < 0) {
            sizedFolder = (item, kind)
            if let cached = FolderSizer.shared.cached(item.path) {
                applyFolderSize(cached, to: item, kind: kind)
            } else {
                model.subtitle = "\(kind) – Calculating…"
                FolderSizer.shared.size(of: item.path, progress: { [weak self] bytes in
                    guard let self, token == self.token else { return }
                    self.model.subtitle = "\(kind) – \(Formatters.size(bytes))…"
                }, completion: { [weak self] result in
                    guard let self, token == self.token else { return }
                    item.computedFolderSize = result.bytes
                    self.applyFolderSize(result, to: item, kind: kind)
                })
            }
        }

        // Spotlight metadata and tags (cheap, but off the main thread).
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metadata = Self.metadata(for: url)
            let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            DispatchQueue.main.async {
                guard let self, token == self.token else { return }
                var rows = self.model.rows
                if let lastOpened = metadata.lastOpened {
                    rows.append(InfoRow(label: "Last opened", value: Formatters.longDate(lastOpened)))
                }
                if let dimensions = metadata.dimensions { rows.append(InfoRow(label: "Dimensions", value: dimensions)) }
                if let duration = metadata.duration { rows.append(InfoRow(label: "Duration", value: duration)) }
                self.model.rows = rows
                if let version = metadata.version {
                    self.model.moreRows.append(InfoRow(label: "Version", value: version))
                }
                if let whereFrom = metadata.whereFrom {
                    self.model.moreRows.append(InfoRow(label: "Where from", value: whereFrom))
                }
                self.model.tags = tags
            }
        }
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
        model.subtitle = "\(kind) – \(Formatters.size(result.bytes))"
        model.moreRows.removeAll { $0.label == "Size" || $0.label == "Contains" }
        model.moreRows.insert(InfoRow(label: "Size", value: Formatters.preciseSize(result.bytes)), at: 0)
        model.moreRows.insert(InfoRow(label: "Contains", value: Formatters.count(result.items, "item")), at: 1)
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
        if let added = item.addedDate { rows.append(InfoRow(label: "Added", value: Formatters.longDate(added))) }
        rows.append(InfoRow(label: "Permissions", value: Self.permissions(item.mode)))
        if item.isLocked { rows.append(InfoRow(label: "Locked", value: "Yes")) }
        if item.isHidden { rows.append(InfoRow(label: "Hidden", value: "Yes")) }
        return rows
    }

    private static func permissions(_ mode: UInt32) -> String {
        let chars = ["r", "w", "x"]
        var result = ""
        for shift in stride(from: 6, through: 0, by: -3) {
            for (bit, char) in chars.enumerated() {
                result += (mode >> UInt32(shift)) & (4 >> UInt32(bit)) != 0 ? char : "-"
            }
        }
        return result
    }

    struct Metadata {
        var lastOpened: Date?
        var dimensions: String?
        var duration: String?
        var version: String?
        var whereFrom: String?
    }

    private static func metadata(for url: URL) -> Metadata {
        var result = Metadata()
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return result }
        result.lastOpened = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        if let width = MDItemCopyAttribute(item, kMDItemPixelWidth) as? Int,
           let height = MDItemCopyAttribute(item, kMDItemPixelHeight) as? Int {
            result.dimensions = "\(width) × \(height)"
        }
        if let seconds = MDItemCopyAttribute(item, kMDItemDurationSeconds) as? Double, seconds > 0 {
            let total = Int(seconds.rounded())
            result.duration = total >= 3600
                ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60)
        }
        result.version = MDItemCopyAttribute(item, kMDItemVersion) as? String
        if let origins = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], let first = origins.first {
            result.whereFrom = first
        }
        return result
    }

    // MARK: Tag editing

    func addTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        for url in model.urls {
            var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            if !tags.contains(tag) {
                tags.append(tag)
                try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            }
        }
        if !model.tags.contains(tag) { model.tags.append(tag) }
        refreshListings()
    }

    func removeTag(_ tag: String) {
        for url in model.urls {
            var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            tags.removeAll { $0 == tag }
            try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        model.tags.removeAll { $0 == tag }
        refreshListings()
    }

    private func refreshListings() {
        let parents = Set(model.urls.map { DirectoryReader.normalized($0.deletingLastPathComponent().path) })
        DirectoryStore.shared.reload(paths: parents)
        currentKey = ""
    }
}

// MARK: - SwiftUI

struct InspectorView: View {
    @ObservedObject var model: InspectorModel
    @State private var newTag = ""

    var body: some View {
        Group {
            if model.hasContent {
                content
            } else {
                VStack {
                    Spacer()
                    Text("No Selection")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    section("Information")
                    ForEach(model.rows) { row in rowView(row) }
                    if model.showMore {
                        ForEach(model.moreRows) { row in rowView(row) }
                    }
                    section("Tags")
                    tagsView
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            moreButton
        }
    }

    @ViewBuilder
    private var header: some View {
        if model.compact {
            HStack(spacing: 10) {
                artwork.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 18)
        } else {
            artwork
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .padding(.top, 26)
                .padding(.bottom, 28)
            Text(model.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(model.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = model.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .animation(.easeOut(duration: 0.15), value: model.title)
        } else {
            Color.clear
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    private func rowView(_ row: InfoRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(row.value)
                .multilineTextAlignment(.trailing)
                .lineLimit(row.label == "Where" || row.label == "Where from" ? 3 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
        .padding(.vertical, 3.5)
    }

    private var tagsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.tags.isEmpty {
                FlowTags(tags: model.tags) { tag in
                    model.onRemoveTag?(tag)
                }
            }
            TextField("Add Tags…", text: $newTag)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .onSubmit {
                    model.onAddTag?(newTag)
                    newTag = ""
                }
        }
    }

    private var moreButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.showMore.toggle() }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: model.showMore ? "chevron.up.circle" : "ellipsis.circle")
                    .font(.system(size: 15))
                Text(model.showMore ? "Less" : "More…")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 12)
    }
}

/// Wrapping row of tag chips.
struct FlowTags: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(nsColor: TagColors.color(forTagName: tag) ?? .tertiaryLabelColor))
                        .frame(width: 9, height: 9)
                    Text(tag).font(.system(size: 12))
                    Button {
                        onRemove(tag)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
