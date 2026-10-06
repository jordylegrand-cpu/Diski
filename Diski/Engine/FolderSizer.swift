import Foundation

/// Computes recursive folder sizes in the background with a small pool of
/// workers sharing one directory stack. Results are cached and invalidated by
/// file-system events.
final class FolderSizer {
    static let shared = FolderSizer()

    struct Result {
        let bytes: Int64
        let items: Int
        let computedAt: Date
    }

    /// Main-thread state.
    private var cache: [String: Result] = [:]
    private var jobs: [String: Walk] = [:]
    private var waiting: [String: [(Result) -> Void]] = [:]
    /// Two walks at a time; each walk is itself parallel.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.diski.foldersize"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var operations: [String: Operation] = [:]
    private let maxAge: TimeInterval = 180

    func cached(_ path: String) -> Result? {
        guard let result = cache[path] else { return nil }
        if Date().timeIntervalSince(result.computedAt) > maxAge {
            cache.removeValue(forKey: path)
            return nil
        }
        return result
    }

    /// Whether an up-to-date walk of `path` is running (a walk whose folder
    /// changed while it ran does not count).
    func isComputing(_ path: String) -> Bool { jobs[path].map { !$0.isStale } ?? false }

    /// Computes (or returns the cached) size; `completion` runs on the main thread.
    func size(of path: String, progress: ((Int64) -> Void)? = nil, completion: @escaping (Result) -> Void) {
        if let result = cached(path) {
            completion(result)
            return
        }
        waiting[path, default: []].append(completion)
        if let running = jobs[path] {
            guard running.isStale else { return }
            // The folder changed since this walk started: start over, keeping the waiters.
            running.cancel()
            operations.removeValue(forKey: path)?.cancel()
        }
        let walk = Walk(root: path)
        jobs[path] = walk
        walk.onProgress = progress.map { callback in
            { bytes in DispatchQueue.main.async { callback(bytes) } }
        }
        let operation = BlockOperation { [weak self] in
            let (bytes, items) = walk.isCancelled ? (0, 0) : walk.run()
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.jobs[path] === walk else { return }
                self.jobs.removeValue(forKey: path)
                self.operations.removeValue(forKey: path)
                guard !walk.isCancelled else {
                    self.waiting.removeValue(forKey: path)
                    return
                }
                let result = Result(bytes: bytes, items: items, computedAt: Date())
                // A walk that raced with changes is still worth showing, but not caching.
                if !walk.isStale { self.cache[path] = result }
                let callbacks = self.waiting.removeValue(forKey: path) ?? []
                for callback in callbacks { callback(result) }
            }
        }
        operations[path] = operation
        queue.addOperation(operation)
    }

    /// Cancels pending and running walks of the direct children of `parent`
    /// (called when the user leaves a folder).
    func cancelJobs(inside parent: String) {
        let prefix = parent == "/" ? "/" : parent + "/"
        for path in Array(jobs.keys) where path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/") {
            cancel(path)
        }
    }

    func cancel(_ path: String) {
        jobs[path]?.cancel()
        jobs.removeValue(forKey: path)
        operations.removeValue(forKey: path)?.cancel()
        waiting.removeValue(forKey: path)
    }

    /// Drops cached sizes of every folder containing one of `changedPaths`, and
    /// marks walks of those folders that are still running as stale.
    func invalidate(changedPaths: [String]) {
        guard !cache.isEmpty || !jobs.isEmpty else { return }
        var seen = Set<String>()
        for changed in changedPaths {
            var path = changed.count > 1 && changed.hasSuffix("/") ? String(changed.dropLast()) : changed
            // Walk up the ancestors: a few hash lookups per event instead of
            // comparing every event with every cached folder.
            while seen.insert(path).inserted {
                cache.removeValue(forKey: path)
                jobs[path]?.isStale = true
                guard let slash = path.lastIndex(of: "/") else { break }
                if slash == path.startIndex {
                    if path == "/" { break }
                    path = "/"
                } else {
                    path = String(path[..<slash])
                }
            }
        }
    }

    // MARK: - Parallel walk

    final class Walk {
        /// Set on the main thread when the folder changes while the walk runs.
        var isStale = false
        private let condition = NSCondition()
        private var stack: [String]
        private var active = 0
        private var bytes: Int64 = 0
        private var items = 0
        private var cancelled = false
        private var lastReport = Date.distantPast
        var onProgress: ((Int64) -> Void)?

        init(root: String) {
            stack = [root]
        }

        var isCancelled: Bool {
            condition.lock(); defer { condition.unlock() }
            return cancelled
        }

        func cancel() {
            condition.lock()
            cancelled = true
            condition.broadcast()
            condition.unlock()
        }

        func run() -> (Int64, Int) {
            let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
            DispatchQueue.concurrentPerform(iterations: workers) { _ in work() }
            return (bytes, items)
        }

        private func work() {
            while true {
                condition.lock()
                while stack.isEmpty && active > 0 && !cancelled {
                    condition.wait()
                }
                if cancelled || (stack.isEmpty && active == 0) {
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                let directory = stack.removeLast()
                active += 1
                condition.unlock()

                var subdirectories: [String] = []
                var localBytes: Int64 = 0
                var localItems = 0
                let prefix = directory == "/" ? "/" : directory + "/"
                try? DirectoryReader.forEachRawEntry(inDirectory: directory) { entry in
                    localItems += 1
                    if entry.isDirectory {
                        if !entry.isMountPoint { subdirectories.append(prefix + entry.nameString) }
                    } else if entry.size > 0 {
                        localBytes += entry.size
                    }
                }

                condition.lock()
                stack.append(contentsOf: subdirectories)
                bytes += localBytes
                items += localItems
                active -= 1
                var report: Int64? = nil
                if onProgress != nil, Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    report = bytes
                }
                condition.broadcast()
                condition.unlock()
                if let report { onProgress?(report) }
            }
        }
    }
}
