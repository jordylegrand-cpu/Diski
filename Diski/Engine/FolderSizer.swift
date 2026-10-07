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
    /// Callers that asked while their folder's walk was already stale: they get
    /// that walk's result and then the one of a fresh walk.
    private var rerunWaiters: [String: [(Result) -> Void]] = [:]
    /// Walks not started yet, newest last (started first: the rows on screen
    /// now matter more than the ones scrolled past).
    private var pending: [(path: String, walk: Walk)] = []
    /// Two walks at a time; each walk is itself parallel.
    private var running = 0
    private let workQueue = DispatchQueue(label: "app.diski.foldersize", qos: .utility, attributes: .concurrent)
    /// Folders whose next walk waits a little because they keep changing.
    private var deferred = Set<String>()
    /// When the last walk of a slow folder ended and how long it took.
    private var lastWalks: [String: (end: Date, duration: TimeInterval)] = [:]
    private let maxAge: TimeInterval = 180

    func cached(_ path: String) -> Result? {
        guard let result = cache[path] else { return nil }
        if Date().timeIntervalSince(result.computedAt) > maxAge {
            cache.removeValue(forKey: path)
            return nil
        }
        return result
    }

    /// Whether an up-to-date walk of `path` is running or scheduled (a walk
    /// whose folder changed while it ran only counts once a rerun is queued).
    func isComputing(_ path: String) -> Bool {
        if deferred.contains(path) { return true }
        guard let walk = jobs[path] else { return false }
        return !walk.isStale || rerunWaiters[path] != nil
    }

    /// Computes (or returns the cached) size; `completion` runs on the main thread.
    func size(of path: String, progress: ((Int64) -> Void)? = nil, completion: @escaping (Result) -> Void) {
        if let result = cached(path) {
            completion(result)
            return
        }
        waiting[path, default: []].append(completion)
        if let running = jobs[path] {
            // A walk that went stale still finishes (a folder that keeps changing
            // would otherwise never get a size); a fresh walk follows it.
            if running.isStale { rerunWaiters[path, default: []].append(completion) }
            return
        }
        if deferred.contains(path) { return }
        schedule(path, progress: progress)
    }

    /// Starts a walk now, or after a pause of twice the last walk's duration
    /// (at most 10 s) for a slow folder that was just walked: a folder that
    /// keeps changing is walked about a third of the time instead of nonstop.
    private func schedule(_ path: String, progress: ((Int64) -> Void)?) {
        if let last = lastWalks[path] {
            let delay = last.end.addingTimeInterval(min(10, last.duration * 2)).timeIntervalSinceNow
            if delay > 0.02 {
                deferred.insert(path)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.deferred.remove(path) != nil, self.waiting[path] != nil else { return }
                    self.startWalk(path, progress: progress)
                }
                return
            }
        }
        startWalk(path, progress: progress)
    }

    private func startWalk(_ path: String, progress: ((Int64) -> Void)?) {
        let walk = Walk(root: path)
        jobs[path] = walk
        walk.onProgress = progress.map { callback in
            { bytes in DispatchQueue.main.async { callback(bytes) } }
        }
        pending.append((path: path, walk: walk))
        startPendingWalks()
    }

    private func startPendingWalks() {
        while running < 2, let next = pending.popLast() {
            // Cancelled or replaced walks are simply dropped here.
            guard jobs[next.path] === next.walk, !next.walk.isCancelled else { continue }
            running += 1
            let walk = next.walk, path = next.path, start = Date()
            workQueue.async { [weak self] in
                let (bytes, items) = walk.isCancelled ? (Int64(0), 0) : walk.run()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.running -= 1
                    self.finish(path, walk: walk, bytes: bytes, items: items,
                                duration: Date().timeIntervalSince(start))
                    self.startPendingWalks()
                }
            }
        }
    }

    private func finish(_ path: String, walk: Walk, bytes: Int64, items: Int, duration: TimeInterval) {
        guard jobs[path] === walk else { return }
        jobs.removeValue(forKey: path)
        guard !walk.isCancelled else {
            waiting[path] = nil
            rerunWaiters[path] = nil
            return
        }
        // Only slow folders are remembered (and so ever deferred).
        if duration >= 0.01 {
            lastWalks[path] = (end: Date(), duration: duration)
        } else {
            lastWalks.removeValue(forKey: path)
        }
        let result = Result(bytes: bytes, items: items, computedAt: Date())
        // A walk that raced with changes is still worth showing, but not caching.
        if !walk.isStale { cache[path] = result }
        for callback in waiting.removeValue(forKey: path) ?? [] { callback(result) }
        if let again = rerunWaiters.removeValue(forKey: path), !again.isEmpty {
            waiting[path, default: []].append(contentsOf: again)
            if jobs[path] == nil && !deferred.contains(path) { schedule(path, progress: nil) }
        }
    }

    /// Cancels pending and running walks of the direct children of `parent`
    /// (called when the user leaves a folder).
    func cancelJobs(inside parent: String) {
        let prefix = parent == "/" ? "/" : parent + "/"
        let candidates = Set(jobs.keys).union(deferred)
        for path in candidates where path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/") {
            cancel(path)
        }
    }

    func cancel(_ path: String) {
        jobs[path]?.cancel()
        jobs.removeValue(forKey: path)
        deferred.remove(path)
        waiting.removeValue(forKey: path)
        rerunWaiters.removeValue(forKey: path)
    }

    /// Drops cached sizes of every folder containing one of `changedPaths`, and
    /// marks walks of those folders that are still running as stale.
    func invalidate(changedPaths: [String]) {
        guard !cache.isEmpty || !jobs.isEmpty else { return }
        var seen = Set<String>()
        for changed in changedPaths {
            var path = changed.utf8.count > 1 && changed.utf8.last == UInt8(ascii: "/") ? String(changed.dropLast()) : changed
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
            // One read buffer per worker thread, made at its first folder and reused for the rest.
            var buffer: DirectoryReader.Buffer?
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
                let reader = buffer ?? DirectoryReader.Buffer()
                buffer = reader
                try? DirectoryReader.forEachRawEntry(inDirectory: directory, buffer: reader) { entry in
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
