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
    /// Spotlight results already read while the query gathers.
    private var gatheredCount = 0
    private var scheduledPaths = Set<String>()
    private var pendingResults: [FileItem] = []
    private var deliveryScheduled = false
    private var deliveryGeneration = 0
    private var lastDelivery = DispatchTime.now().uptimeNanoseconds
    private enum WalkStopped: Error { case stopped }
    /// Builds Spotlight result items (lstat, xattrs) off the main thread, in order.
    private let itemQueue = DispatchQueue(label: "app.diski.search.items", qos: .userInitiated)

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
        let matcher = NameMatcher(text)
        let limit = maxResults
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let condition = NSCondition()
            var stack = [base]
            var active = 0
            // Matches found so far (guarded by `condition`); the walk stops at `limit`.
            var total = 0
            var found: [FileItem] = []
            var lastFlush = Date()
            let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))

            func flush(force: Bool) {
                condition.lock()
                guard force || Date().timeIntervalSince(lastFlush) > 0.1, !found.isEmpty else {
                    condition.unlock()
                    return
                }
                let batch = found
                found = []
                lastFlush = Date()
                DispatchQueue.main.async {
                    guard !self.isCancelled else { return }
                    self.append(batch, done: false)
                }
                condition.unlock()
            }

            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                // One read buffer per worker thread, made at its first folder and reused for the rest.
                var buffer: DirectoryReader.Buffer?
                while true {
                    condition.lock()
                    while stack.isEmpty && active > 0 && total < limit && !self.isCancelled { condition.wait() }
                    if self.isCancelled || total >= limit || (stack.isEmpty && active == 0) {
                        condition.broadcast()
                        condition.unlock()
                        return
                    }
                    let directory = stack.removeLast()
                    active += 1
                    condition.unlock()

                    var subdirectories: [String] = []
                    var matches: [FileItem] = []
                    let reader = buffer ?? DirectoryReader.Buffer()
                    buffer = reader
                    var lastPublish = DispatchTime.now().uptimeNanoseconds
                    var visited = 0
                    var stopped = false
                    func publishMatches() {
                        condition.lock()
                        let remaining = max(0, limit - total)
                        found.append(contentsOf: matches.prefix(remaining))
                        total += min(remaining, matches.count)
                        stopped = total >= limit
                        condition.unlock()
                        matches.removeAll(keepingCapacity: true)
                        lastPublish = DispatchTime.now().uptimeNanoseconds
                        flush(force: false)
                    }
                    // Detailed entries retain Finder hidden flags and package boundaries.
                    try? DirectoryReader.forEachEntry(inDirectory: directory, detailed: true, buffer: reader,
                                                      include: { name, type in
                                                          visited += 1
                                                          if visited & 255 == 0 { stopped = stopped || self.isCancelled }
                                                          return stopped || type == DirectoryReader.vDIR || matcher.matches(cString: name)
                                                      }) { item in
                        if stopped || self.isCancelled { throw WalkStopped.stopped }
                        if !showHidden && item.isHidden { return }
                        if !item.isDirectoryOnDisk || matcher.matches(item) { matches.append(item) }
                        if item.type == .directory && !item.isMountPoint { subdirectories.append(item.path) }
                        if !matches.isEmpty && DispatchTime.now().uptimeNanoseconds - lastPublish >= 100_000_000 {
                            publishMatches()
                        }
                    }

                    publishMatches()
                    condition.lock()
                    stack.append(contentsOf: subdirectories)
                    active -= 1
                    condition.broadcast()
                    condition.unlock()
                    flush(force: false)
                }
            }
            flush(force: true)
            DispatchQueue.main.async {
                guard !self.isCancelled else { return }
                self.isRunning = false
                self.append([], done: true)
            }
        }
    }

    private func append(_ batch: [FileItem], done: Bool) {
        pendingResults.append(contentsOf: batch)
        if done {
            deliver(done: true)
        } else if !deliveryScheduled {
            deliveryScheduled = true
            deliveryGeneration += 1
            let generation = deliveryGeneration
            let elapsed = DispatchTime.now().uptimeNanoseconds - lastDelivery
            let delay = elapsed >= 100_000_000 ? 0 : Double(100_000_000 - elapsed) / 1_000_000_000
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isCancelled, self.deliveryScheduled, self.deliveryGeneration == generation else { return }
                self.deliver(done: false)
            }
        }
    }

    private func deliver(done: Bool) {
        deliveryScheduled = false
        deliveryGeneration += 1
        for item in pendingResults where results.count < maxResults {
            if seen.insert(item.path).inserted { results.append(item) }
        }
        pendingResults.removeAll(keepingCapacity: true)
        lastDelivery = DispatchTime.now().uptimeNanoseconds
        handler(results, done)
    }

    // MARK: Spotlight

    private func startSpotlight(predicate: NSPredicate, scopes: [Any]) {
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.1
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
        let total = min(query.resultCount, maxResults)
        // While gathering, results are only appended: read just the new ones.
        // Live updates and the final pass look at all of them.
        let first = (done || !isRunning) ? 0 : min(gatheredCount, total)
        var paths: [String] = []
        for index in first..<max(first, total) {
            if let item = query.result(at: index) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
               !seen.contains(path), scheduledPaths.insert(path).inserted {
                paths.append(path)
            }
        }
        gatheredCount = total
        query.enableUpdates()
        guard !paths.isEmpty || done else { return }
        // The serial queue keeps batches in order, so `done` always arrives last.
        itemQueue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            var items: [FileItem] = []
            var failedPaths: [String] = []
            items.reserveCapacity(paths.count)
            for path in paths {
                guard !self.isCancelled else { return }
                if let item = FileItem.make(path: path) { items.append(item) }
                else { failedPaths.append(path) }
            }
            DispatchQueue.main.async {
                guard !self.isCancelled else { return }
                for path in failedPaths { self.scheduledPaths.remove(path) }
                guard !items.isEmpty || done else { return }
                self.append(items, done: done)
            }
        }
    }
}
