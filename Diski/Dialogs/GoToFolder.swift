import AppKit
import SwiftUI

/// "Go to Folder" (⇧⌘G) with live path completion and fuzzy matching on
/// recently visited folders.
final class GoToFolderModel: ObservableObject {
    @Published var text: String {
        didSet { recompute() }
    }
    @Published var suggestions: [String] = []
    @Published var selected = 0

    init(start: String) {
        let home = NSHomeDirectory()
        if start.hasPrefix(home) {
            text = "~" + start.dropFirst(home.count) + "/"
        } else {
            text = start == "/" ? "/" : start + "/"
        }
        recompute()
    }

    var expanded: String {
        (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    func recompute() {
        let raw = text.trimmingCharacters(in: .whitespaces)
        var results: [String] = []
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let path = (raw as NSString).expandingTildeInPath
            let parent: String
            let prefix: String
            if raw.hasSuffix("/") {
                parent = path
                prefix = ""
            } else {
                parent = (path as NSString).deletingLastPathComponent
                prefix = (path as NSString).lastPathComponent.lowercased()
            }
            var names: [String] = []
            try? DirectoryReader.forEachEntry(inDirectory: parent.isEmpty ? "/" : parent, detailed: true) { item in
                guard item.isNavigable, !item.name.hasPrefix(".") || prefix.hasPrefix(".") else { return }
                if prefix.isEmpty || item.name.lowercased().hasPrefix(prefix) { names.append(item.name) }
            }
            names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            let base = parent == "/" ? "" : parent
            results = names.prefix(12).map { base + "/" + $0 }
        } else if !raw.isEmpty {
            let needle = raw.lowercased()
            results = Prefs.recentFolders.filter { fuzzyMatch(needle, $0.lowercased()) }.prefix(12).map { $0 }
        } else {
            results = Array(Prefs.recentFolders.prefix(12))
        }
        suggestions = results
        selected = 0
    }

    /// Characters of `needle` appear in order in `haystack`'s last components.
    private func fuzzyMatch(_ needle: String, _ haystack: String) -> Bool {
        var index = haystack.startIndex
        for char in needle {
            guard let found = haystack[index...].firstIndex(of: char) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }

    func completeSelection() {
        guard selected < suggestions.count else { return }
        text = abbreviate(suggestions[selected]) + "/"
    }

    func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The folder to open: the highlighted suggestion, else the typed path.
    func destination() -> String? {
        let typed = expanded
        var isDirectory: ObjCBool = false
        if !text.trimmingCharacters(in: .whitespaces).isEmpty,
           FileManager.default.fileExists(atPath: typed, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? typed : (typed as NSString).deletingLastPathComponent
        }
        if selected < suggestions.count { return suggestions[selected] }
        return nil
    }
}

struct GoToFolderView: View {
    @ObservedObject var model: GoToFolderModel
    let onGo: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.forward.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("Go to Folder").font(.system(size: 15, weight: .semibold))
            }
            TextField("Type a path, or part of a folder name", text: $model.text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(go)
                .onKeyPress(.downArrow) {
                    model.selected = min(model.selected + 1, max(0, model.suggestions.count - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.selected = max(model.selected - 1, 0)
                    return .handled
                }
                .onKeyPress(.tab) {
                    model.completeSelection()
                    return .handled
                }
            if !model.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, path in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.shared.genericFolder)
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 13))
                            Text(model.abbreviate((path as NSString).deletingLastPathComponent))
                                .font(.system(size: 11))
                                .foregroundStyle(index == model.selected ? Color.white.opacity(0.8) : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(index == model.selected ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(index == model.selected ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onGo(path) }
                        .onTapGesture { model.selected = index }
                    }
                }
            }
            HStack {
                Text("Tab completes · ↑↓ choose · Return opens")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Go", action: go).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { focused = true }
    }

    private func go() {
        if let destination = model.destination() {
            onGo(destination)
        } else {
            NSSound.beep()
        }
    }
}

enum GoToFolderController {
    static func present(on window: NSWindow, startingAt path: String, completion: @escaping (String) -> Void) {
        let model = GoToFolderModel(start: path)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        let view = GoToFolderView(model: model, onGo: { destination in
            window.endSheet(panel)
            completion(destination)
        }, onCancel: {
            window.endSheet(panel)
        })
        panel.contentViewController = NSHostingController(rootView: view)
        window.beginSheet(panel)
    }
}

/// "Connect to Server…" (⌘K): mounts smb://, afp://, nfs:// and webdav URLs.
enum ConnectToServer {
    static func present(on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Enter a server address, for example smb://nas.local/Share"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: UserDefaults.standard.string(forKey: "lastServer") ?? "smb://")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return }
            UserDefaults.standard.set(field.stringValue, forKey: "lastServer")
            NSWorkspace.shared.open(url)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}
