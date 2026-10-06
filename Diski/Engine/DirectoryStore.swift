import Foundation

/// App-wide cache of directory listings.
///
/// * Listings are read in the background with `DirectoryReader` and cached,
///   so going back to a folder is instant.
/// * Directories in use are watched with FSEvents and re-read on change.
/// * Refreshes are merged into the existing listing: unchanged entries keep
///   their identity and changed ones are updated in place, so views can
///   animate inserts/removals and keep selection and expansion.
final class DirectoryStore {
    static let shared = DirectoryStore()
    /// Posted on the main thread. `object` is the `Listing`; userInfo["changes"] is `Changes`.
    static let didUpdate = Notification.Name("DiskiDirectoryDidUpdate")
    /// Posted on the main thread when something changed deeper inside folders
    /// listed in a watched directory, so views can refresh those folders' sizes.
    /// userInfo["paths"] is a `Set<String>` of the affected folders.
    static let folderContentsDidChange = Notification.Name("DiskiFolderContentsDidChange")

    struct Changes {
        var inserted: [FileItem] = []
        var removed: [FileItem] = []
        var updated: [FileItem] = []
        var isInitialLoad = false
        var isEmpty: Bool { inserted.isEmpty && removed.isEmpty && updated.isEmpty && !isInitialLoad }
    }

    final class Listing {
        let path: String
        fileprivate(set) var items: [FileItem] = []
        fileprivate(set) var isLoaded = false
        fileprivate(set) var isLoading = false
        fileprivate(set) var error: DirectoryReader.ReadError?
        fileprivate(set) var lastRead = Date.distantPast
        fileprivate var reloadQueued = false
        fileprivate var completions: [(Listing) -> Void] = []
        fileprivate var lastUsed = Date()

        init(path: String) { self.path = path }

        func item(named name: String) -> FileItem? {
            items.first { $0.name == name }
        }
    }

    private var listings: [String: Listing] = [:]
    private var watchCounts: [String: Int] = [:]
    private let watcher = DirectoryWatcher()
    private let readQueue = DispatchQueue(label: "app.diski.read", qos: .userInitiated, attributes: .concurrent)
    private let maxCachedListings = 96

    private init() {
        watcher.onChange = { [weak self] directories, rawPaths in
            FolderSizer.shared.invalidate(changedPaths: rawPaths)
            self?.reload(paths: directories)
            self?.noteNestedChanges(rawPaths)
        }
    }

    /// Finds the folders, listed in watched directories, that contain a changed
    /// path below their own level (a file written inside them changes their
    /// size without touching their own attributes). With `minimumDepth` 0 the
    /// changed paths count as changed folders themselves.
    func noteNestedChanges(_ rawPaths: [String], minimumDepth: Int = 1) {
        guard !watchCounts.isEmpty else { return }
        var folders = Set<String>()
        for raw in rawPaths {
            var child = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            var depth = 0
            while let slash = child.lastIndex(of: "/") {
                let parent = slash == child.startIndex ? "/" : String(child[..<slash])
                if depth >= minimumDepth && watchCounts[parent] != nil { folders.insert(child) }
                if parent == "/" || parent == child { break }
                child = parent
                depth += 1
            }
        }
        guard !folders.isEmpty else { return }
        NotificationCenter.default.post(name: Self.folderContentsDidChange, object: self, userInfo: ["paths": folders])
    }

    /// The (possibly not yet loaded) listing for `path`.
    func listing(for rawPath: String) -> Listing {
        let path = DirectoryReader.normalized(rawPath)
        if let listing = listings[path] {
            listing.lastUsed = Date()
            return listing
        }
        let listing = Listing(path: path)
        listings[path] = listing
        evictIfNeeded()
        return listing
    }

    /// Loads `path` if needed. `completion` runs on the main thread once the
    /// listing has content (immediately when it is already cached).
    func load(_ path: String, completion: ((Listing) -> Void)? = nil) {
        let listing = self.listing(for: path)
        if listing.isLoaded {
            completion?(listing)
            // Unwatched cached listings may be stale: refresh quietly.
            if watchCounts[listing.path] == nil && Date().timeIntervalSince(listing.lastRead) > 2 {
                read(listing)
            }
            return
        }
        if let completion { listing.completions.append(completion) }
        read(listing)
    }

    /// Reads `path` synchronously on the calling thread (for small, local folders
    /// where waiting a frame would be visible). Returns the listing.
    @discardableResult
    func loadNow(_ path: String) -> Listing {
        let listing = self.listing(for: path)
        if listing.isLoaded { return listing }
        do {
            let items = try DirectoryReader.read(path: listing.path)
            apply(items: items, error: nil, to: listing)
        } catch let error as DirectoryReader.ReadError {
            apply(items: [], error: error, to: listing)
        } catch {
            apply(items: [], error: DirectoryReader.ReadError(path: listing.path, code: EIO), to: listing)
        }
        return listing
    }

    func reload(_ path: String, completion: ((Listing) -> Void)? = nil) {
        let listing = self.listing(for: path)
        if let completion { listing.completions.append(completion) }
        read(listing)
    }

    /// Re-reads the given directories if Diski has them cached.
    func reload(paths: Set<String>) {
        for path in paths {
            if let listing = listings[DirectoryReader.normalized(path)], listing.isLoaded || listing.isLoading {
                read(listing)
            }
        }
    }

    // MARK: Watching

    func beginWatching(_ rawPath: String) {
        let path = DirectoryReader.normalized(rawPath)
        watchCounts[path, default: 0] += 1
        if watchCounts[path] == 1 { updateWatcher() }
    }

    func endWatching(_ rawPath: String) {
        let path = DirectoryReader.normalized(rawPath)
        guard let count = watchCounts[path] else { return }
        if count <= 1 {
            watchCounts.removeValue(forKey: path)
            updateWatcher()
        } else {
            watchCounts[path] = count - 1
        }
    }

    private func updateWatcher() {
        watcher.watch(Set(watchCounts.keys))
    }

    // MARK: Reading

    private func read(_ listing: Listing) {
        if listing.isLoading {
            listing.reloadQueued = true
            return
        }
        listing.isLoading = true
        let path = listing.path
        readQueue.async { [weak self] in
            var items: [FileItem] = []
            var failure: DirectoryReader.ReadError?
            do {
                items = try DirectoryReader.read(path: path)
            } catch let error as DirectoryReader.ReadError {
                failure = error
            } catch {
                failure = DirectoryReader.ReadError(path: path, code: EIO)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                listing.isLoading = false
                self.apply(items: items, error: failure, to: listing)
                if listing.reloadQueued {
                    listing.reloadQueued = false
                    self.read(listing)
                }
            }
        }
    }

    private func apply(items newItems: [FileItem], error: DirectoryReader.ReadError?, to listing: Listing) {
        var changes = Changes()
        let wasLoaded = listing.isLoaded
        listing.error = error
        listing.lastRead = Date()

        if !wasLoaded {
            listing.items = newItems
            changes.isInitialLoad = true
        } else {
            var old: [String: FileItem] = [:]
            old.reserveCapacity(listing.items.count)
            for item in listing.items { old[item.name] = item }
            var merged: [FileItem] = []
            merged.reserveCapacity(newItems.count)
            for item in newItems {
                if let existing = old.removeValue(forKey: item.name) {
                    if existing.update(from: item) {
                        changes.updated.append(existing)
                        IconCache.shared.invalidate(path: existing.path)
                    }
                    merged.append(existing)
                } else {
                    merged.append(item)
                    changes.inserted.append(item)
                }
            }
            changes.removed = Array(old.values)
            listing.items = merged
        }
        listing.isLoaded = true

        let completions = listing.completions
        listing.completions = []
        for completion in completions { completion(listing) }
        if !changes.isEmpty {
            NotificationCenter.default.post(name: Self.didUpdate, object: listing, userInfo: ["changes": changes])
        }
    }

    private func evictIfNeeded() {
        guard listings.count > maxCachedListings else { return }
        let removable = listings.values
            .filter { watchCounts[$0.path] == nil && !$0.isLoading && $0.completions.isEmpty }
            .sorted { $0.lastUsed < $1.lastUsed }
        for listing in removable.prefix(listings.count - maxCachedListings) {
            listings.removeValue(forKey: listing.path)
        }
    }
}
