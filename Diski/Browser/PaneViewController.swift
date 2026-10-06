import AppKit
import UniformTypeIdentifiers

protocol PaneViewControllerDelegate: AnyObject {
    func paneDidChangeLocation(_ pane: PaneViewController)
    func paneDidChangeSelection(_ pane: PaneViewController)
    func paneDidChangeViewMode(_ pane: PaneViewController)
    /// Tab pressed: move focus to the other pane. Returns true when handled.
    func paneRequestsFocusSwitch(_ pane: PaneViewController) -> Bool
    func pane(_ pane: PaneViewController, openInNewTab path: String)
    func paneRequestsQuickLook(_ pane: PaneViewController)
    func paneRequestsInspector(_ pane: PaneViewController)
}

extension NSPasteboard.PasteboardType {
    /// Marks file URLs on the pasteboard as "cut" (paste moves instead of copies).
    static let diskiCut = NSPasteboard.PasteboardType("app.diski.cut")
}

/// One navigable browser pane: history, current folder, view mode, search,
/// and every file action. A window shows one pane, or two side by side.
final class PaneViewController: NSViewController, NSMenuItemValidation {
    weak var delegate: PaneViewControllerDelegate?

    private(set) var currentPath = ""
    private(set) var viewMode: ViewMode
    var arrangeOptions: ArrangeOptions
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private(set) var listing: DirectoryStore.Listing?
    private(set) var items: [FileItem] = []
    private(set) var content: FileViewController!

    private let contentContainer = NSView()
    let bottomBar = BottomBarView()
    private let message = PaneMessageView()
    private let activeIndicator = NSView()
    private var pendingSelection: Set<String> = []
    private var pendingRename: String?
    private var resortScheduled = false
    private var loadingToken = 0
    private var freeSpaceCache: (path: String, bytes: Int64?, at: Date)?

    // Search
    private(set) var searchText = ""
    private(set) var searchScope: SearchScope = .thisFolder
    private var searchEngine: SearchEngine?
    private var searchResults: [FileItem] = []
    private var searchTag: String?
    let scopeBar = SearchScopeBar()
    private var modeBeforeSearch: ViewMode?

    var isSearchResults: Bool { searchEngine != nil }
    var isActive = false {
        didSet { activeIndicator.isHidden = !(isActive && showsActiveIndicator) }
    }
    var showsActiveIndicator = false {
        didSet { activeIndicator.isHidden = !(isActive && showsActiveIndicator) }
    }

    init(path: String, viewMode: ViewMode) {
        self.viewMode = viewMode
        self.arrangeOptions = ArrangeOptions(sortKey: Prefs.sortKey, ascending: Prefs.sortAscending,
                                             foldersOnTop: Prefs.foldersOnTop, showHidden: Prefs.showHiddenFiles,
                                             filter: "")
        super.init(nibName: nil, bundle: nil)
        self.initialPath = path
    }

    private var initialPath = ""

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        searchEngine?.cancel()
        if !currentPath.isEmpty { DirectoryStore.shared.endWatching(currentPath) }
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        message.translatesAutoresizingMaskIntoConstraints = false
        scopeBar.translatesAutoresizingMaskIntoConstraints = false
        activeIndicator.translatesAutoresizingMaskIntoConstraints = false
        activeIndicator.wantsLayer = true
        activeIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        activeIndicator.isHidden = true
        root.addSubview(contentContainer)
        root.addSubview(message)
        root.addSubview(bottomBar)
        root.addSubview(scopeBar)
        root.addSubview(activeIndicator)
        scopeBar.isHidden = true
        scopeBar.onVisibilityChange = { [weak self] visible in
            self?.contentContainer.additionalSafeAreaInsets = NSEdgeInsets(top: visible ? 40 : 0, left: 0, bottom: 0, right: 0)
        }
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: contentContainer.widthAnchor, constant: -40),
            scopeBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scopeBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            activeIndicator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            activeIndicator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            activeIndicator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            activeIndicator.heightAnchor.constraint(equalToConstant: 2),
        ])
        view = root

        bottomBar.onNavigate = { [weak self] url in self?.navigate(to: url.path) }
        bottomBar.dropOperation = { [weak self] info, path in self?.dragOperation(for: info, destination: path) ?? [] }
        bottomBar.performDrop = { [weak self] info, path in self?.performDrop(info, destination: path) ?? false }
        bottomBar.onIconSizeChange = { [weak self] size in
            Prefs.iconSize = size
            self?.content.appearanceSettingsDidChange()
        }
        scopeBar.onScopeChange = { [weak self] scope in self?.setSearchScope(scope) }

        installContent(for: viewMode)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(directoryDidUpdate(_:)), name: DirectoryStore.didUpdate, object: nil)
        center.addObserver(self, selector: #selector(prefsDidChange(_:)), name: Prefs.didChange, object: nil)
        center.addObserver(self, selector: #selector(operationDidFinish(_:)), name: FileOperationManager.didFinish, object: nil)
        center.addObserver(self, selector: #selector(pasteboardMayHaveChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        navigate(to: initialPath, recordHistory: false)
    }

    private func installContent(for mode: ViewMode) {
        content?.willDeactivate()
        content?.view.removeFromSuperview()
        content?.removeFromParent()
        let controller: FileViewController
        switch mode {
        case .list: controller = ListViewController()
        case .icons: controller = IconViewController()
        case .columns: controller = ColumnViewController()
        case .gallery: controller = GalleryViewController()
        }
        controller.pane = self
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        content = controller
        if let list = controller as? ListViewController { list.isFlat = isSearchResults }
        bottomBar.showsIconSizeSlider = mode == .icons
    }

    // MARK: - Navigation

    var displayTitle: String {
        if isSearchResults {
            if let tag = searchTag { return tag }
            return "Searching “\(searchText)”"
        }
        let path = displayedPath
        if Prefs.showFullPathInTitle { return path }
        return path == "/" ? (VolumeMonitor.shared.volume(containing: "/")?.name ?? "/")
            : FileManager.default.displayName(atPath: path)
    }

    /// The folder the title and path bar describe (column view: the deepest open column).
    var displayedPath: String {
        if let columns = content as? ColumnViewController { return columns.deepestPath }
        return currentPath
    }

    var canGoBack: Bool { !backStack.isEmpty || isSearchResults }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { displayedPath != "/" }

    func navigate(to rawPath: String, recordHistory: Bool = true, select paths: [String] = []) {
        var path = DirectoryReader.normalized((rawPath as NSString).expandingTildeInPath)
        // Follow symlinks to folders to their real location, like Finder.
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            path = DirectoryReader.normalized(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        if isSearchResults { endSearch(clearField: true) }
        if path == currentPath {
            if !paths.isEmpty { selectPaths(Set(paths), scroll: true) }
            return
        }
        if recordHistory && !currentPath.isEmpty {
            backStack.append(currentPath)
            if backStack.count > 200 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        setLocation(path, select: paths)
    }

    private func setLocation(_ path: String, select paths: [String]) {
        if !currentPath.isEmpty {
            DirectoryStore.shared.endWatching(currentPath)
            FolderSizer.shared.cancelJobs(inside: currentPath)
        }
        currentPath = path
        DirectoryStore.shared.beginWatching(path)
        pendingSelection = Set(paths)
        arrangeOptions.filter = ""
        let listing = DirectoryStore.shared.listing(for: path)
        self.listing = listing
        freeSpaceCache = nil
        loadingToken += 1
        if listing.isLoaded {
            showListing(reset: true)
        } else {
            let token = loadingToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, token == self.loadingToken, self.listing?.isLoaded == false else { return }
                self.items = []
                self.content.display(items: [], directory: path, changes: nil, reset: true)
                self.message.show(.loading)
            }
        }
        DirectoryStore.shared.load(path)
        Prefs.noteVisited(path)
        delegate?.paneDidChangeLocation(self)
        updateBottomBar()
    }

    @objc func goBack(_ sender: Any?) {
        if isSearchResults {
            endSearch(clearField: true)
            return
        }
        guard let previous = backStack.popLast() else { return }
        let from = currentPath
        forwardStack.append(from)
        setLocation(previous, select: [from])
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        setLocation(next, select: [])
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        let path = displayedPath
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        navigate(to: parent, select: [path])
    }

    @objc func goToPath(_ sender: Any?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String else { return }
        navigate(to: path)
    }

    /// Column view opened a deeper (or shallower) folder: adopt it as the
    /// current location without rebuilding the columns.
    func adoptColumnLocation(_ rawPath: String) {
        let path = DirectoryReader.normalized(rawPath)
        guard path != currentPath, !isSearchResults else { return }
        DirectoryStore.shared.endWatching(currentPath)
        currentPath = path
        DirectoryStore.shared.beginWatching(path)
        let listing = DirectoryStore.shared.listing(for: path)
        self.listing = listing
        items = arrange(listing.items)
        freeSpaceCache = nil
        updateMessage()
        updateBottomBar()
        delegate?.paneDidChangeLocation(self)
    }

    func backHistoryMenuItems() -> [String] { backStack.reversed() }
    func forwardHistoryMenuItems() -> [String] { forwardStack.reversed() }

    // MARK: - Displaying

    func arrange(_ items: [FileItem]) -> [FileItem] {
        ItemArranger.arrange(items, options: arrangeOptions)
    }

    private func showListing(reset: Bool) {
        guard let listing else { return }
        items = arrange(listing.items)
        content.display(items: items, directory: currentPath, changes: nil, reset: reset)
        applyPendingSelection()
        updateMessage()
        updateBottomBar()
        delegate?.paneDidChangeSelection(self)
    }

    @objc private func directoryDidUpdate(_ notification: Notification) {
        guard let updated = notification.object as? DirectoryStore.Listing, updated === listing, !isSearchResults else { return }
        let changes = notification.userInfo?["changes"] as? DirectoryStore.Changes
        if changes?.isInitialLoad == true {
            showListing(reset: true)
            return
        }
        items = arrange(updated.items)
        content.display(items: items, directory: currentPath, changes: changes, reset: false)
        applyPendingSelection()
        updateMessage()
        updateBottomBar()
        delegate?.paneDidChangeSelection(self)
    }

    /// Re-sorts after background folder sizes arrive (coalesced).
    func scheduleResort() {
        guard !resortScheduled else { return }
        resortScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.resortScheduled = false
            self.rearrange()
        }
    }

    func rearrange() {
        if isSearchResults {
            items = arrange(searchResults)
        } else if let listing {
            items = arrange(listing.items)
        }
        let selection = content.selectedItems
        content.display(items: items, directory: currentPath, changes: nil, reset: false)
        content.select(selection, scroll: false)
        updateMessage()
        updateBottomBar()
    }

    private func applyPendingSelection() {
        guard !pendingSelection.isEmpty else { return }
        let wanted = pendingSelection
        if selectPaths(wanted, scroll: true) {
            pendingSelection = []
            if let rename = pendingRename, wanted.contains(rename),
               let item = content.selectedItems.first(where: { $0.path == rename }) {
                pendingRename = nil
                DispatchQueue.main.async { self.content.beginRename(item) }
            }
        }
    }

    @discardableResult
    func selectPaths(_ paths: Set<String>, scroll: Bool) -> Bool {
        let matches = items.filter { paths.contains($0.path) }
        guard !matches.isEmpty else { return false }
        content.select(matches, scroll: scroll)
        return true
    }

    private func updateMessage() {
        if isSearchResults {
            if items.isEmpty {
                message.show(searchEngine?.isRunning == true ? .searching : .noResults(searchText))
            } else {
                message.show(.none)
            }
            return
        }
        guard let listing else { message.show(.none); return }
        if let error = listing.error {
            message.show(error.isPermissionDenied ? .permissionDenied : .error(error.localizedDescription))
        } else if !listing.isLoaded {
            message.show(.loading)
        } else if items.isEmpty {
            message.show(arrangeOptions.filter.isEmpty ? .empty : .noMatches(arrangeOptions.filter))
        } else {
            message.show(.none)
        }
    }

    // MARK: - Selection

    var selectedItems: [FileItem] { content?.selectedItems ?? [] }
    var selectedURLs: [URL] { selectedItems.map { $0.url } }

    func viewSelectionDidChange(_ view: FileViewController) {
        updateBottomBar()
        delegate?.paneDidChangeSelection(self)
        if view is ColumnViewController {
            delegate?.paneDidChangeLocation(self)
        }
    }

    func updateBottomBar() {
        guard isViewLoaded else { return }
        bottomBar.isHidden = !Prefs.showPathBar
        let selection = selectedItems
        if selection.count == 1 {
            bottomBar.setPath(selection[0].url)
        } else {
            bottomBar.setPath(URL(fileURLWithPath: displayedPath, isDirectory: true))
        }
        guard Prefs.showStatusInfo else {
            bottomBar.status.stringValue = ""
            return
        }
        var parts: [String] = []
        if selection.isEmpty {
            parts.append(Formatters.count(items.count, "item"))
        } else {
            parts.append("\(selection.count) of \(Formatters.count(items.count, "item")) selected")
            let total = selection.reduce(Int64(0)) { $0 + max(0, $1.displaySize) }
            if total > 0 { parts.append(Formatters.size(total)) }
        }
        if !isSearchResults, let free = freeSpace() {
            parts.append("\(Formatters.size(free)) available")
        }
        bottomBar.status.stringValue = parts.joined(separator: " · ")
    }

    private func freeSpace() -> Int64? {
        let path = currentPath
        if let cache = freeSpaceCache, cache.path == path, Date().timeIntervalSince(cache.at) < 10 { return cache.bytes }
        let bytes = VolumeMonitor.availableCapacity(forPath: path)
        freeSpaceCache = (path, bytes, Date())
        return bytes
    }

    // MARK: - View mode, sorting, filtering

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let selection = selectedItems
        viewMode = mode
        installContent(for: mode)
        content.display(items: items, directory: currentPath, changes: nil, reset: true)
        content.select(selection, scroll: true)
        content.focus()
        // A quick crossfade makes the switch feel smooth without slowing it down.
        let incoming = content.view
        incoming.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            incoming.animator().alphaValue = 1
        }
        updateBottomBar()
        delegate?.paneDidChangeViewMode(self)
        delegate?.paneDidChangeLocation(self)
    }

    @objc func switchViewMode(_ sender: Any?) {
        var tag = -1
        if let item = sender as? NSMenuItem { tag = item.tag }
        if let control = sender as? NSSegmentedControl { tag = control.selectedSegment }
        if let mode = ViewMode(rawValue: tag) { setViewMode(mode) }
    }

    func setSort(_ key: SortKey, ascending: Bool) {
        arrangeOptions.sortKey = key
        arrangeOptions.ascending = ascending
        Prefs.sortKey = key
        Prefs.sortAscending = ascending
        rearrange()
        (content as? ListViewController)?.syncSortIndicator()
    }

    @objc func sortBy(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let raw = item.representedObject as? String,
              let key = SortKey(rawValue: raw) else { return }
        if key == arrangeOptions.sortKey {
            setSort(key, ascending: !arrangeOptions.ascending)
        } else {
            setSort(key, ascending: key.defaultAscending)
        }
    }

    @objc func toggleFoldersOnTop(_ sender: Any?) {
        Prefs.foldersOnTop.toggle()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Prefs.showHiddenFiles.toggle()
    }

    @objc private func prefsDidChange(_ notification: Notification) {
        var changed = false
        if arrangeOptions.showHidden != Prefs.showHiddenFiles {
            arrangeOptions.showHidden = Prefs.showHiddenFiles
            changed = true
        }
        if arrangeOptions.foldersOnTop != Prefs.foldersOnTop {
            arrangeOptions.foldersOnTop = Prefs.foldersOnTop
            changed = true
        }
        if changed { rearrange() }
        content.appearanceSettingsDidChange()
        updateBottomBar()
        delegate?.paneDidChangeLocation(self)
    }

    // MARK: - Search & filter

    /// Called as the user types in the toolbar search field.
    func setSearchText(_ text: String) {
        searchText = text
        if text.isEmpty {
            endSearch(clearField: false)
            return
        }
        switch searchScope {
        case .thisFolder:
            searchEngine?.cancel()
            searchEngine = nil
            scopeBar.isHidden = false
            scopeBar.scope = .thisFolder
            arrangeOptions.filter = text
            rearrange()
        case .subfolders, .thisMac:
            startSearchEngine()
        }
        delegate?.paneDidChangeLocation(self)
    }

    func setSearchScope(_ scope: SearchScope) {
        searchScope = scope
        scopeBar.scope = scope
        if scope == .thisFolder {
            if isSearchResults {
                searchEngine?.cancel()
                searchEngine = nil
                restoreModeAfterSearch()
                showListing(reset: true)
            }
            arrangeOptions.filter = searchText
            rearrange()
        } else if !searchText.isEmpty {
            arrangeOptions.filter = ""
            startSearchEngine()
        }
        delegate?.paneDidChangeLocation(self)
    }

    /// Spotlight search for a Finder tag (sidebar Tags section).
    func showTag(_ tag: String) {
        searchTag = tag
        searchText = ""
        searchEngine?.cancel()
        enterResultsMode()
        let engine = SearchEngine.tag(tag) { [weak self] results, done in
            self?.receiveSearchResults(results, done: done)
        }
        searchEngine = engine
        engine.start()
        delegate?.paneDidChangeLocation(self)
    }

    private func startSearchEngine() {
        searchEngine?.cancel()
        searchTag = nil
        enterResultsMode()
        let engine: SearchEngine
        if searchScope == .thisMac {
            engine = SearchEngine.spotlight(text: searchText) { [weak self] results, done in
                self?.receiveSearchResults(results, done: done)
            }
        } else {
            engine = SearchEngine.recursive(base: currentPath, text: searchText, showHidden: arrangeOptions.showHidden) { [weak self] results, done in
                self?.receiveSearchResults(results, done: done)
            }
        }
        searchEngine = engine
        searchResults = []
        items = []
        content.display(items: [], directory: currentPath, changes: nil, reset: true)
        message.show(.searching)
        engine.start()
    }

    private func enterResultsMode() {
        scopeBar.isHidden = searchTag != nil
        scopeBar.scope = searchScope
        if viewMode == .columns || viewMode == .gallery {
            modeBeforeSearch = viewMode
            viewMode = .list
            installContent(for: .list)
        }
        (content as? ListViewController)?.isFlat = true
    }

    private func restoreModeAfterSearch() {
        (content as? ListViewController)?.isFlat = false
        if let mode = modeBeforeSearch {
            modeBeforeSearch = nil
            viewMode = mode
            installContent(for: mode)
            delegate?.paneDidChangeViewMode(self)
        }
    }

    private func receiveSearchResults(_ results: [FileItem], done: Bool) {
        searchResults = results
        let previous = items
        items = arrange(results)
        if previous.isEmpty || items.count < 2000 {
            let selection = content.selectedItems
            content.display(items: items, directory: currentPath, changes: nil, reset: previous.isEmpty)
            content.select(selection, scroll: false)
        }
        updateMessage()
        updateBottomBar()
    }

    func endSearch(clearField: Bool) {
        let wasResults = isSearchResults
        searchEngine?.cancel()
        searchEngine = nil
        searchTag = nil
        searchText = ""
        scopeBar.isHidden = true
        arrangeOptions.filter = ""
        if wasResults { restoreModeAfterSearch() }
        if clearField { NotificationCenter.default.post(name: .diskiClearSearchField, object: self) }
        if wasResults { showListing(reset: true) } else { rearrange() }
        delegate?.paneDidChangeLocation(self)
    }

    // MARK: - Opening

    func open(_ targets: [FileItem], inNewTab: Bool = false) {
        var files: [URL] = []
        var folders: [String] = []
        for item in targets {
            if item.isNavigable {
                folders.append(item.path)
            } else if item.isAlias, let resolved = try? URL(resolvingAliasFileAt: item.url) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue,
                   !FileKinds.isPackage(name: resolved.lastPathComponent, finderFlags: 0) {
                    folders.append(resolved.path)
                } else {
                    files.append(resolved)
                }
            } else {
                files.append(item.url)
            }
        }
        if folders.count == 1 && !inNewTab && files.isEmpty {
            navigate(to: folders[0])
        } else {
            for folder in folders { delegate?.pane(self, openInNewTab: folder) }
        }
        for url in files { NSWorkspace.shared.open(url) }
    }

    @objc func openSelection(_ sender: Any?) {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        open(selection)
    }

    @objc func openInNewTab(_ sender: Any?) {
        let folders = selectedItems.filter { $0.isNavigable }
        if folders.isEmpty {
            delegate?.pane(self, openInNewTab: displayedPath)
        } else {
            for folder in folders { delegate?.pane(self, openInNewTab: folder.path) }
        }
    }

    @objc func openWithApplication(_ sender: Any?) {
        guard let appURL = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openWithOther(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an application to open the selected items."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc func quickLook(_ sender: Any?) {
        delegate?.paneRequestsQuickLook(self)
    }

    /// ⌘I: a native Info window for each selected item (or this folder).
    @objc func getInfo(_ sender: Any?) {
        let targets = selectedItems.isEmpty ? [displayedPath] : selectedItems.map { $0.path }
        for path in targets.prefix(10) { InfoWindowController.show(path: path) }
    }

    @objc func showOriginal(_ sender: Any?) {
        guard let item = selectedItems.first else { return }
        var target: URL?
        if item.isAlias { target = try? URL(resolvingAliasFileAt: item.url) }
        if item.type == .symlink { target = item.url.resolvingSymlinksInPath() }
        if let target {
            navigate(to: target.deletingLastPathComponent().path, select: [target.path])
        } else {
            NSSound.beep()
        }
    }

    @objc func showInEnclosingFolder(_ sender: Any?) {
        guard let item = selectedItems.first else { return }
        navigate(to: item.parentPath, select: [item.path])
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = selectedURLs
        if urls.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: displayedPath))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    @objc func openInTerminal(_ sender: Any?) {
        var folder = displayedPath
        if let item = selectedItems.first, item.isNavigable { folder = item.path }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let workspace = NSWorkspace.shared
        let app = workspace.urlForApplication(withBundleIdentifier: Prefs.terminalBundleID)
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let app else { NSSound.beep(); return }
        workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Creating & renaming

    @objc func newFolder(_ sender: Any?) {
        guard !isSearchResults else { NSSound.beep(); return }
        let directory = URL(fileURLWithPath: content.targetDirectory, isDirectory: true)
        do {
            let folder = try FileOperationManager.shared.newFolder(in: directory)
            selectSoon(folder.path, rename: true)
        } catch {
            showError(error)
        }
    }

    @objc func newFolderWithSelection(_ sender: Any?) {
        let selection = selectedURLs
        guard !selection.isEmpty, !isSearchResults else { return }
        let directory = URL(fileURLWithPath: content.targetDirectory, isDirectory: true)
        do {
            let folder = try FileOperationManager.shared.newFolder(in: directory, containing: selection)
            selectSoon(folder.path, rename: true)
        } catch {
            showError(error)
        }
    }

    @objc func newFile(_ sender: Any?) {
        guard !isSearchResults else { NSSound.beep(); return }
        let directory = URL(fileURLWithPath: content.targetDirectory, isDirectory: true)
        do {
            let file = try FileOperationManager.shared.newFile(in: directory)
            selectSoon(file.path, rename: true)
        } catch {
            showError(error)
        }
    }

    /// Selects (and optionally starts renaming) an item once it appears.
    func selectSoon(_ path: String, rename: Bool) {
        pendingSelection = [path]
        pendingRename = rename ? path : nil
        applyPendingSelection()
    }

    @objc func renameSelection(_ sender: Any?) {
        let selection = selectedItems
        guard selection.count == 1, let item = selection.first else {
            if selection.count > 1 { NSSound.beep() }
            return
        }
        content.beginRename(item)
    }

    /// Returns false (after telling the user) when the rename failed.
    func commitRename(_ item: FileItem, to newName: String) -> Bool {
        do {
            let url = try FileOperationManager.shared.rename(item.url, to: newName)
            pendingSelection = [url.path]
            DirectoryStore.shared.reload(paths: [item.parentPath])
            return true
        } catch {
            showError(error)
            return false
        }
    }

    @objc func duplicateSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileOperationManager.shared.duplicate(urls)
    }

    @objc func makeAlias(_ sender: Any?) {
        let created = FileOperationManager.shared.makeAliases(for: selectedURLs)
        if let first = created.first { selectSoon(first.path, rename: false) }
    }

    @objc func makeSymbolicLink(_ sender: Any?) {
        FileOperationManager.shared.makeSymlinks(for: selectedURLs)
    }

    @objc func compress(_ sender: Any?) {
        FileOperationManager.shared.compress(selectedURLs)
    }

    // MARK: - Trash & delete

    var isShowingTrash: Bool {
        currentPath == FileOperationManager.trashURL.path || currentPath.hasSuffix("/.Trashes/\(getuid())")
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        if isShowingTrash {
            deleteImmediately(sender)
            return
        }
        trash(urls)
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Select the row after the deleted ones, like Finder.
        let selected = Set(urls.map { $0.path })
        if let last = items.lastIndex(where: { selected.contains($0.path) }) {
            let next = items[(last + 1)...].first { !selected.contains($0.path) }
                ?? items[..<last].last { !selected.contains($0.path) }
            if let next { pendingSelection = [next.path] }
        }
        FileOperationManager.shared.trash(urls)
    }

    @objc func deleteImmediately(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1
            ? "Are you sure you want to delete “\(urls[0].lastPathComponent)”?"
            : "Are you sure you want to delete these \(urls.count) items?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            FileOperationManager.shared.deleteImmediately(urls)
        }
    }

    @objc func putBackSelection(_ sender: Any?) {
        FileOperationManager.shared.putBack(selectedURLs)
    }

    @objc func emptyTrash(_ sender: Any?) {
        guard Prefs.confirmEmptyTrash, let window = view.window else {
            FileOperationManager.shared.emptyTrash()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { FileOperationManager.shared.emptyTrash() }
        }
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        writeToPasteboard(cut: false)
    }

    @objc func cut(_ sender: Any?) {
        guard !isSearchResults || !selectedItems.isEmpty else { return }
        writeToPasteboard(cut: true)
    }

    private static var cutPaths: Set<String> = []
    private static var cutChangeCount = -1

    func isCut(_ item: FileItem) -> Bool {
        guard !Self.cutPaths.isEmpty else { return false }
        return NSPasteboard.general.changeCount == Self.cutChangeCount && Self.cutPaths.contains(item.path)
    }

    @objc private func pasteboardMayHaveChanged() {
        if NSPasteboard.general.changeCount != Self.cutChangeCount && !Self.cutPaths.isEmpty {
            let previouslyCut = items.filter { Self.cutPaths.contains($0.path) }
            Self.cutPaths = []
            content.refresh(previouslyCut)
        }
    }

    private func writeToPasteboard(cut: Bool) {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(selection.map { $0.url as NSURL })
        pasteboard.setString(selection.map { $0.name }.joined(separator: "\n"), forType: .string)
        let previouslyCut = items.filter { Self.cutPaths.contains($0.path) }
        if cut {
            pasteboard.setString("1", forType: .diskiCut)
            Self.cutPaths = Set(selection.map { $0.path })
            Self.cutChangeCount = pasteboard.changeCount
            content.refresh(selection)
        } else {
            Self.cutPaths = []
        }
        content.refresh(previouslyCut)
    }

    @objc func paste(_ sender: Any?) {
        pasteItems(forceMove: false)
    }

    @objc func moveItemHere(_ sender: Any?) {
        pasteItems(forceMove: true)
    }

    private func pasteItems(forceMove: Bool) {
        guard !isSearchResults else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        let destination = URL(fileURLWithPath: content.targetDirectory, isDirectory: true)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty {
            do {
                if let created = try FileOperationManager.shared.pasteData(from: pasteboard, into: destination) {
                    selectSoon(created.path, rename: true)
                } else {
                    NSSound.beep()
                }
            } catch {
                showError(error)
            }
            return
        }
        let isCut = pasteboard.types?.contains(.diskiCut) == true
        if forceMove || isCut {
            FileOperationManager.shared.move(urls, to: destination)
            if isCut {
                pasteboard.clearContents()
                Self.cutPaths = []
            }
        } else {
            FileOperationManager.shared.copy(urls, to: destination)
        }
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = selectedItems.isEmpty ? [displayedPath] : selectedItems.map { $0.path }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func operationDidFinish(_ notification: Notification) {
        guard let operation = notification.object as? FileOperation else { return }
        // Copies, moves and deletions change the free space shown in the bar.
        freeSpaceCache = nil
        updateBottomBar()
        guard operation.state == .finished else { return }
        let here = DirectoryReader.normalized(content.targetDirectory)
        let created = operation.resultURLs.filter {
            DirectoryReader.normalized($0.deletingLastPathComponent().path) == here
        }
        if !created.isEmpty, operation.kind != .trash {
            pendingSelection = Set(created.map { $0.path })
            applyPendingSelection()
        }
    }

    // MARK: - Tags, sidebar, volumes

    @objc func applyTag(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let tagName = TagColors.names[item.tag]
        let urls = selectedURLs
        guard !urls.isEmpty, !tagName.isEmpty else { return }
        // Toggle: remove the tag if every selected item already has it.
        let allHave = urls.allSatisfy { (try? $0.resourceValues(forKeys: [.tagNamesKey]).tagNames)?.contains(tagName) == true }
        for url in urls {
            var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            if allHave {
                tags.removeAll { $0 == tagName }
            } else if !tags.contains(tagName) {
                tags.append(tagName)
            }
            try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        DirectoryStore.shared.reload(paths: Set(selectedItems.map { $0.parentPath }))
        delegate?.paneDidChangeSelection(self)
    }

    @objc func addToSidebar(_ sender: Any?) {
        let folders = selectedItems.filter { $0.isNavigable }.map { $0.path }
        let paths = folders.isEmpty ? [displayedPath] : folders
        var favorites = Prefs.favorites
        for path in paths where !favorites.contains(path) { favorites.append(path) }
        Prefs.favorites = favorites
    }

    @objc func eject(_ sender: Any?) {
        var target: VolumeInfo?
        if let item = selectedItems.first, item.isMountPoint {
            target = VolumeMonitor.shared.volume(containing: item.path)
        } else {
            target = VolumeMonitor.shared.volume(containing: displayedPath)
        }
        guard let volume = target, !volume.isRoot else { NSSound.beep(); return }
        if displayedPath.hasPrefix(volume.path) { navigate(to: NSHomeDirectory()) }
        VolumeMonitor.shared.eject(volume) { [weak self] error in
            if let error { self?.showError(error) }
        }
    }

    // MARK: - Drag and drop

    static let acceptedDragTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private func deviceID(_ path: String) -> dev_t {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_dev : -1
    }

    func dragOperation(for info: NSDraggingInfo, destination: String) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty {
            return pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) ? .copy : []
        }
        for url in urls {
            let path = DirectoryReader.normalized(url.path)
            if destination == path || destination.hasPrefix(path + "/") { return [] }
        }
        let mask = info.draggingSourceOperationMask
        if destination == FileOperationManager.trashURL.path { return mask.contains(.move) || mask.contains(.generic) ? .move : [] }
        if mask == .copy { return .copy }
        if mask == .link { return .link }
        if mask == .generic || mask == .move { return .move }
        let allSameFolder = urls.allSatisfy { DirectoryReader.normalized($0.deletingLastPathComponent().path) == destination }
        if allSameFolder { return [] }
        let sameVolume = deviceID(urls[0].deletingLastPathComponent().path) == deviceID(destination)
        if sameVolume && (mask.contains(.move) || mask.contains(.generic)) { return .move }
        if mask.contains(.copy) { return .copy }
        if mask.contains(.move) || mask.contains(.generic) { return .move }
        return mask.contains(.link) ? .link : []
    }

    func performDrop(_ info: NSDraggingInfo, destination: String) -> Bool {
        let operation = dragOperation(for: info, destination: destination)
        guard !operation.isEmpty else { return false }
        let destinationURL = URL(fileURLWithPath: destination, isDirectory: true)
        let pasteboard = info.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            if destination == FileOperationManager.trashURL.path {
                trash(urls)
            } else if operation == .copy {
                FileOperationManager.shared.copy(urls, to: destinationURL)
            } else if operation == .link {
                FileOperationManager.shared.makeAliases(for: urls, in: destinationURL)
            } else {
                FileOperationManager.shared.move(urls, to: destinationURL)
            }
            return true
        }
        guard let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                as? [NSFilePromiseReceiver], !receivers.isEmpty else { return false }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destinationURL, options: [:],
                                          operationQueue: Self.promiseQueue) { url, error in
                DispatchQueue.main.async {
                    if let error {
                        FileOperationManager.shared.presentError("A dropped item couldn’t be saved: \(error.localizedDescription)")
                    } else {
                        DirectoryStore.shared.reload(paths: [destination])
                        self.pendingSelection.insert(url.path)
                    }
                }
            }
        }
        return true
    }

    // MARK: - Keyboard

    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 36, 76: // Return, Enter
            guard flags.isEmpty else { return false }
            if Prefs.returnKeyOpens { openSelection(nil) } else { renameSelection(nil) }
            return true
        case 49: // Space
            guard flags.isEmpty, !typeSelecting else { return false }
            quickLook(nil)
            return true
        case 48: // Tab
            guard flags.isEmpty || flags == .shift else { return false }
            return delegate?.paneRequestsFocusSwitch(self) ?? false
        case 125: // Down arrow
            guard flags == .command else { return false }
            openSelection(nil)
            return true
        case 120: // F2
            renameSelection(nil)
            return true
        default:
            return false
        }
    }

    // MARK: - Context menu

    func populateContextMenu(_ menu: NSMenu, for targets: [FileItem]) {
        func add(_ title: String, _ action: Selector, symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }

        if targets.isEmpty {
            add("New Folder", #selector(newFolder(_:)), symbol: "folder.badge.plus")
            add("New Text File", #selector(newFile(_:)), symbol: "doc.badge.plus")
            menu.addItem(.separator())
            add("Get Info", #selector(getInfo(_:)), symbol: "info.circle")
            menu.addItem(.separator())
            add("Paste", #selector(paste(_:)), symbol: "doc.on.clipboard")
            menu.addItem(.separator())
            let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            let viewMenu = NSMenu()
            for mode in ViewMode.allCases {
                let entry = NSMenuItem(title: "as \(mode.title)", action: #selector(switchViewMode(_:)), keyEquivalent: "")
                entry.tag = mode.rawValue
                entry.target = self
                entry.state = mode == viewMode ? .on : .off
                viewMenu.addItem(entry)
            }
            viewItem.submenu = viewMenu
            menu.addItem(viewItem)
            menu.addItem(sortMenuItem())
            add(Prefs.showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files", #selector(toggleHiddenFiles(_:)), symbol: "eye")
            menu.addItem(.separator())
            add("Open in Terminal", #selector(openInTerminal(_:)), symbol: "terminal")
            add("Copy Path", #selector(copyPath(_:)), symbol: "link")
            if isShowingTrash {
                menu.addItem(.separator())
                add("Empty Trash…", #selector(emptyTrash(_:)), symbol: "trash.slash")
            }
            return
        }

        let single = targets.count == 1 ? targets[0] : nil
        add("Open", #selector(openSelection(_:)))
        if targets.contains(where: { !$0.isNavigable }) {
            menu.addItem(openWithMenuItem(for: targets))
        }
        if targets.contains(where: { $0.isNavigable }) {
            add("Open in New Tab", #selector(openInNewTab(_:)))
        }
        menu.addItem(.separator())
        if isShowingTrash {
            if targets.contains(where: { FileOperationManager.shared.canPutBack($0.url) }) {
                add("Put Back", #selector(putBackSelection(_:)), symbol: "arrow.uturn.backward")
            }
            add("Delete Immediately…", #selector(deleteImmediately(_:)), symbol: "trash.slash")
        } else {
            add("Move to Trash", #selector(moveToTrash(_:)), symbol: "trash")
        }
        menu.addItem(.separator())
        add("Get Info", #selector(getInfo(_:)), symbol: "info.circle")
        if single != nil { add("Rename", #selector(renameSelection(_:)), symbol: "pencil") }
        add(single.map { "Compress “\($0.name)”" } ?? "Compress \(targets.count) Items", #selector(compress(_:)), symbol: "archivebox")
        add("Duplicate", #selector(duplicateSelection(_:)), symbol: "plus.square.on.square")
        add("Make Alias", #selector(makeAlias(_:)), symbol: "arrowshape.turn.up.right")
        add("Quick Look", #selector(quickLook(_:)), symbol: "eye")
        if isSearchResults { add("Show in Enclosing Folder", #selector(showInEnclosingFolder(_:)), symbol: "folder") }
        if single?.isAlias == true || single?.type == .symlink { add("Show Original", #selector(showOriginal(_:)), symbol: "arrow.forward.circle") }
        menu.addItem(.separator())
        add("Copy", #selector(copy(_:)), symbol: "doc.on.doc")
        add("Cut", #selector(cut(_:)), symbol: "scissors")
        add("Copy Path", #selector(copyPath(_:)), symbol: "link")
        let picker = NSSharingServicePicker(items: targets.map { $0.url })
        let share = picker.standardShareMenuItem
        menu.addItem(share)
        menu.addItem(.separator())
        menu.addItem(tagsMenuItem())
        menu.addItem(.separator())
        if targets.contains(where: { $0.isNavigable }) || single == nil {
            add("New Folder with Selection", #selector(newFolderWithSelection(_:)), symbol: "folder.badge.plus")
        }
        add("Open in Terminal", #selector(openInTerminal(_:)), symbol: "terminal")
        add("Reveal in Finder", #selector(revealInFinder(_:)), symbol: "macwindow")
    }

    func sortMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for key in SortKey.allCases {
            let entry = NSMenuItem(title: key.title, action: #selector(sortBy(_:)), keyEquivalent: "")
            entry.representedObject = key.rawValue
            entry.target = self
            entry.state = key == arrangeOptions.sortKey ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let folders = NSMenuItem(title: "Keep Folders on Top", action: #selector(toggleFoldersOnTop(_:)), keyEquivalent: "")
        folders.target = self
        folders.state = Prefs.foldersOnTop ? .on : .off
        submenu.addItem(folders)
        item.submenu = submenu
        return item
    }

    func tagsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let submenu = NSMenu()
        for index in TagColors.sidebarOrder {
            let entry = NSMenuItem(title: TagColors.names[index], action: #selector(applyTag(_:)), keyEquivalent: "")
            entry.tag = index
            entry.target = self
            entry.image = Self.dotImage(TagColors.color(forLabel: index))
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    static func dotImage(_ color: NSColor, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func openWithMenuItem(for targets: [FileItem]) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if let first = targets.first(where: { !$0.isNavigable }) {
            let workspace = NSWorkspace.shared
            let defaultApp = workspace.urlForApplication(toOpen: first.url)
            var apps = workspace.urlsForApplications(toOpen: first.url)
            if let defaultApp {
                apps.removeAll { $0 == defaultApp }
                apps.insert(defaultApp, at: 0)
            }
            for (index, app) in apps.prefix(24).enumerated() {
                var title = FileManager.default.displayName(atPath: app.path)
                if title.hasSuffix(".app") { title = String(title.dropLast(4)) }
                if index == 0 && app == defaultApp { title += " (default)" }
                let entry = NSMenuItem(title: title, action: #selector(openWithApplication(_:)), keyEquivalent: "")
                entry.representedObject = app
                entry.target = self
                let icon = workspace.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
                submenu.addItem(entry)
                if index == 0 && app == defaultApp && apps.count > 1 { submenu.addItem(.separator()) }
            }
        }
        submenu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        submenu.addItem(other)
        item.submenu = submenu
        return item
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selection = selectedItems
        switch menuItem.action {
        case #selector(goBack(_:)): return canGoBack
        case #selector(goForward(_:)): return canGoForward
        case #selector(goToEnclosingFolder(_:)): return canGoUp && !isSearchResults
        case #selector(openSelection(_:)), #selector(quickLook(_:)), #selector(copy(_:)), #selector(cut(_:)),
             #selector(duplicateSelection(_:)), #selector(makeAlias(_:)), #selector(compress(_:)),
             #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)), #selector(makeSymbolicLink(_:)),
             #selector(applyTag(_:)):
            return !selection.isEmpty
        case #selector(renameSelection(_:)):
            return selection.count == 1
        case #selector(showOriginal(_:)):
            return selection.count == 1 && (selection[0].isAlias || selection[0].type == .symlink)
        case #selector(showInEnclosingFolder(_:)):
            return selection.count == 1 && isSearchResults
        case #selector(newFolder(_:)), #selector(newFile(_:)):
            return !isSearchResults
        case #selector(newFolderWithSelection(_:)):
            return !selection.isEmpty && !isSearchResults
        case #selector(paste(_:)), #selector(moveItemHere(_:)):
            let pasteboard = NSPasteboard.general
            if isSearchResults { return false }
            if menuItem.action == #selector(moveItemHere(_:)) {
                return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            }
            return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                || pasteboard.canReadObject(forClasses: [NSImage.self, NSString.self], options: nil)
        case #selector(putBackSelection(_:)):
            return isShowingTrash && selection.contains { FileOperationManager.shared.canPutBack($0.url) }
        case #selector(switchViewMode(_:)):
            menuItem.state = menuItem.tag == viewMode.rawValue ? .on : .off
            return !(isSearchResults && menuItem.tag == ViewMode.columns.rawValue)
        case #selector(toggleHiddenFiles(_:)):
            menuItem.title = Prefs.showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files"
            return true
        case #selector(toggleFoldersOnTop(_:)):
            menuItem.state = Prefs.foldersOnTop ? .on : .off
            return true
        case #selector(sortBy(_:)):
            if let raw = menuItem.representedObject as? String {
                menuItem.state = raw == arrangeOptions.sortKey.rawValue ? .on : .off
            }
            return true
        case #selector(eject(_:)):
            let volume = selection.first.flatMap { $0.isMountPoint ? VolumeMonitor.shared.volume(containing: $0.path) : nil }
                ?? VolumeMonitor.shared.volume(containing: displayedPath)
            return volume.map { !$0.isRoot && ($0.isEjectable || $0.isRemovable || !$0.isInternal) } ?? false
        default:
            return true
        }
    }

    // MARK: - Errors

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.localizedDescription
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension Notification.Name {
    static let diskiClearSearchField = Notification.Name("DiskiClearSearchField")
}
