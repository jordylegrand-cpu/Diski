import Foundation

/// Searches that produce results over time.
/// * `recursive`: walks the current folder tree in parallel (no index needed,
///   finds hidden and freshly created files instantly).
/// * `spotlight`: queries the Spotlight index for the whole Mac.
/// * `tag`: Spotlight query for a Finder tag.
/// Result callbacks run on the main thread with the full result list so far.
final class SearchEngine: NSObject {
    typealias Handler = (_ results: [FileItem], _ done: Bool) -> Void

    private enum Kind {
        case recursive(base: String, text: String, showHidden: Bool)
        case spotlight(predicate: NSPredicate, scopes: [Any])
    }

    private let kind: Kind
    private let handler: Handler
    private(set) var isRunning = false
    private var cancelled = false
    private let lock = NSLock()
    private var query: NSMetadataQuery?
    private var results: [FileItem] = []
    private var seen = Set<String>()
    private let maxResults = 5000

    private init(kind: Kind, handler: @escaping Handler) {
        self.kind = kind
        self.handler = handler
    }

    static func recursive(base: String, text: String, showHidden: Bool, handler: @escaping Handler) -> SearchEngine {
        SearchEngine(kind: .recursive(base: base, text: text, showHidden: showHidden), handler: handler)
    }

    static func spotlight(text: String, handler: @escaping Handler) -> SearchEngine {
        let predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
        return SearchEngine(kind: .spotlight(predicate: predicate, scopes: [NSMetadataQueryLocalComputerScope]),
                            handler: handler)
    }

    static func tag(_ tag: String, handler: @escaping Handler) -> SearchEngine {
        let predicate = NSPredicate(format: "kMDItemUserTags == %@", tag)
        return SearchEngine(kind: .spotlight(predicate: predicate, scopes: [NSMetadataQueryLocalComputerScope]),
                            handler: handler)
    }

    /// Files opened in the last 30 days (Finder's Recents).
    static func recents(handler: @escaping Handler) -> SearchEngine {
        let since = Date().addingTimeInterval(-30 * 24 * 3600) as NSDate
        let predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@", since)
        return SearchEngine(kind: .spotlight(predicate: predicate, scopes: [NSMetadataQueryUserHomeScope]),
                            handler: handler)
    }

    func start() {
        isRunning = true
        switch kind {
        case let .recursive(base, text, showHidden):
            startRecursive(base: base, text: text, showHidden: showHidden)
        case let .spotlight(predicate, scopes):
            startSpotlight(predicate: predicate, scopes: scopes)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        isRunning = false
        if let query {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            self.query = nil
        }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    // MARK: Recursive walk

    private func startRecursive(base: String, text: String, showHidden: Bool) {
        let needle = text
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let condition = NSCondition()
            var stack = [base]
            var active = 0
            var found: [FileItem] = []
            var lastFlush = Date()
            let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))

            func flush(force: Bool) {
                condition.lock()
                guard force || Date().timeIntervalSince(lastFlush) > 0.15, !found.isEmpty else {
                    condition.unlock()
                    return
                }
                let batch = found
                found = []
                lastFlush = Date()
                condition.unlock()
                DispatchQueue.main.async {
                    guard !self.isCancelled else { return }
                    self.append(batch, done: false)
                }
            }

            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while true {
                    condition.lock()
                    while stack.isEmpty && active > 0 && !self.isCancelled { condition.wait() }
                    if self.isCancelled || (stack.isEmpty && active == 0) {
                        condition.broadcast()
                        condition.unlock()
                        return
                    }
                    let directory = stack.removeLast()
                    active += 1
                    condition.unlock()

                    var subdirectories: [String] = []
                    var matches: [FileItem] = []
                    try? DirectoryReader.forEachEntry(inDirectory: directory, detailed: true) { item in
                        if !showHidden && item.isHidden { return }
                        if ItemArranger.matches(item.name, filter: needle) { matches.append(item) }
                        if item.type == .directory && !item.isMountPoint { subdirectories.append(item.path) }
                    }

                    condition.lock()
                    stack.append(contentsOf: subdirectories)
                    found.append(contentsOf: matches)
                    active -= 1
                    condition.broadcast()
                    condition.unlock()
                    if !matches.isEmpty { flush(force: false) }
                }
            }
            flush(force: true)
            DispatchQueue.main.async {
                guard !self.isCancelled else { return }
                self.isRunning = false
                self.handler(self.results, true)
            }
        }
    }

    private func append(_ batch: [FileItem], done: Bool) {
        for item in batch where results.count < maxResults {
            if seen.insert(item.path).inserted { results.append(item) }
        }
        handler(results, done)
    }

    // MARK: Spotlight

    private func startSpotlight(predicate: NSPredicate, scopes: [Any]) {
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.2
        self.query = query
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(queryUpdated(_:)), name: .NSMetadataQueryDidUpdate, object: query)
        center.addObserver(self, selector: #selector(queryGathered(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        center.addObserver(self, selector: #selector(queryUpdated(_:)), name: .NSMetadataQueryGatheringProgress, object: query)
        if !query.start() {
            isRunning = false
            handler([], true)
        }
    }

    @objc private func queryUpdated(_ notification: Notification) {
        collectSpotlightResults(done: false)
    }

    @objc private func queryGathered(_ notification: Notification) {
        isRunning = false
        collectSpotlightResults(done: true)
    }

    private func collectSpotlightResults(done: Bool) {
        guard let query, !isCancelled else { return }
        query.disableUpdates()
        let count = min(query.resultCount, maxResults)
        var paths: [String] = []
        paths.reserveCapacity(count)
        for index in 0..<count {
            if let item = query.result(at: index) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                paths.append(path)
            }
        }
        query.enableUpdates()
        let newPaths = paths.filter { !seen.contains($0) }
        let items = newPaths.compactMap { FileItem.make(path: $0) }
        for item in items where seen.insert(item.path).inserted { results.append(item) }
        handler(results, done)
    }
}
